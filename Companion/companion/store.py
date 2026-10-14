# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Registered phones, their Live Activities and the photos matched to trips.

Kept in one SQLite file by default (`COMPANION_DB`), or in Postgres when `COMPANION_DATABASE_URL`
is set (#20), for setups whose volumes are on network storage, where SQLite can't lock safely, or
that run more than one companion. Both get the same tables and the same SQL: it is written once,
with `?` and `:name` placeholders, and turned into Postgres's `%s` and `%(name)s` there.

The store holds each phone's AdventureLog API key (the companion polls with it), so keep the file
on a volume only the companion can read, or the database for the companion alone. Signing out on
the phone unregisters it.
"""

from __future__ import annotations

import contextlib
import json
import re
import sqlite3
import threading
import uuid
from collections.abc import Iterator
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime
from pathlib import Path

SCHEMA = """
create table if not exists devices (
    id text primary key,
    user_id text not null,
    api_key text not null unique,
    environment text not null default 'production',
    start_token text,
    created_at text not null
);
create table if not exists activities (
    device_id text not null references devices(id) on delete cascade,
    trip_id text not null,
    row_id text not null,
    push_token text,
    start_sent integer not null default 0,
    last_state text,
    ended integer not null default 0,
    primary key (device_id, trip_id, row_id)
);
-- Photos to the trip (Stage 6). Per person, not per phone: the photos are theirs.
create table if not exists photo_trips (
    user_id text not null,
    trip_id text not null,
    enabled integer not null default 0,
    camera_offset_minutes integer not null default 0,
    album_id text,
    last_run text,
    last_error text,
    primary key (user_id, trip_id)
);
create table if not exists photo_assets (
    user_id text not null,
    trip_id text not null,
    asset_id text not null,
    taken_at text not null,
    day text not null,
    stop_id text,
    stop_kind text,
    stop_title text,
    image_id text,           -- the AdventureLog image linking it to the stop, if one was made
    state text not null,     -- done, undone, failed, unmatched
    detail text,
    primary key (user_id, trip_id, asset_id)
);
-- Live flight status (#39): the provider's last answer per flight and day, shared by everyone
-- on that flight, and what the provider billed per day.
create table if not exists flight_status (
    provider text not null,
    number text not null,
    local_date text not null,
    status text,             -- JSON; null when the provider didn't find the flight
    fetched_at text not null,
    unchanged integer not null default 0,
    primary key (provider, number, local_date)
);
create table if not exists flight_units (
    provider text not null,
    day text not null,
    units integer not null default 0,
    primary key (provider, day)
);
-- Every sidecar written, with a copy of what was there before (null: there was no file), and a
-- hash of what was written, so undo can tell whether Lightroom has changed it since.
create table if not exists photo_sidecars (
    user_id text not null,
    trip_id text not null,
    asset_id text not null,
    path text not null,
    backup text,
    written_hash text not null,
    primary key (user_id, trip_id, asset_id, path)
);
-- Which companion runs the poller, when several share one database (#20).
create table if not exists leases (
    name text primary key,
    holder text not null,
    expires_at text not null
);
-- Since when AdventureLog has refused a phone's key, so one revoked for good is dropped (#20).
create table if not exists refused_keys (
    device_id text primary key references devices(id) on delete cascade,
    since text not null
);
"""


@dataclass
class Device:
    id: str
    user_id: str
    api_key: str
    environment: str
    start_token: str | None


@dataclass
class Activity:
    device_id: str
    trip_id: str
    row_id: str
    push_token: str | None
    start_sent: bool
    last_state: dict | None
    ended: bool

    @property
    def key(self) -> tuple[str, str]:
        return (self.trip_id, self.row_id)


@dataclass
class PhotoTrip:
    user_id: str
    trip_id: str
    enabled: bool
    camera_offset_minutes: int
    album_id: str | None
    last_run: str | None
    last_error: str | None


@dataclass
class PhotoAsset:
    user_id: str
    trip_id: str
    asset_id: str
    taken_at: str
    day: str
    stop_id: str | None
    stop_kind: str | None
    stop_title: str | None
    image_id: str | None
    state: str
    detail: str | None


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


class _Session:
    """One unit of work: every statement in it commits together, or none does."""

    def __init__(self, cursor, postgres: bool):
        self._cursor = cursor
        self._postgres = postgres

    def _sql(self, sql: str) -> str:
        if not self._postgres:
            return sql
        sql = re.sub(r"(?<![:\w]):([a-z_]+)", r"%(\1)s", sql)
        return sql.replace("?", "%s")

    def run(self, sql: str, params=()) -> None:
        self._cursor.execute(self._sql(sql), params)

    def rows(self, sql: str, params=()) -> list[dict]:
        self._cursor.execute(self._sql(sql), params)
        return [dict(row) for row in self._cursor.fetchall()]

    def one(self, sql: str, params=()) -> dict | None:
        rows = self.rows(sql, params)
        return rows[0] if rows else None


class _SQLite:
    """One connection, used by one caller at a time. The API's sync dependencies run in
    FastAPI's threadpool while the poller runs on the event loop, so the lock is what keeps them
    from using the connection at once."""

    postgres = False

    def __init__(self, path: str):
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._db.row_factory = sqlite3.Row
        self._db.execute("pragma foreign_keys = on")
        self._lock = threading.RLock()
        self._depth = 0

    @contextlib.contextmanager
    def session(self) -> Iterator[_Session]:
        with self._lock:
            outer = self._depth == 0
            if outer:
                self._db.execute("begin immediate")
            self._depth += 1
            try:
                yield _Session(self._db.cursor(), postgres=False)
            except BaseException:
                self._depth -= 1
                if outer:
                    self._db.execute("rollback")
                raise
            self._depth -= 1
            if outer:
                self._db.execute("commit")

    def create(self, schema: str) -> None:
        with self._lock:
            self._db.executescript(schema)

    def close(self) -> None:
        self._db.close()


class _Postgres:
    """A small pool: each unit of work borrows its own connection, so threads never share one."""

    postgres = True
    # Any number, the same in every companion: one of them creates the tables at a time.
    SCHEMA_LOCK = 0x41_4C_43_4F

    def __init__(self, url: str):
        try:
            from psycopg.rows import dict_row
            from psycopg_pool import ConnectionPool
        except ImportError as error:  # pragma: no cover - the image always has it
            raise RuntimeError(
                "COMPANION_DATABASE_URL needs the Postgres driver: pip install 'adventurelog-companion[postgres]'"
            ) from error
        self._pool = ConnectionPool(url, min_size=1, max_size=4, kwargs={"row_factory": dict_row}, open=True)
        self._local = threading.local()

    @contextlib.contextmanager
    def session(self) -> Iterator[_Session]:
        current = getattr(self._local, "session", None)
        if current is not None:  # already inside one on this thread: join it
            yield current
            return
        with self._pool.connection() as connection, connection.cursor() as cursor:
            # Leaving the pool's block commits, or rolls back on an exception.
            self._local.session = _Session(cursor, postgres=True)
            try:
                yield self._local.session
            finally:
                self._local.session = None

    def create(self, schema: str) -> None:
        with self.session() as db:
            db.run("select pg_advisory_xact_lock(?)", (self.SCHEMA_LOCK,))
            # One statement at a time; comments go first, since one can hold a semicolon.
            for statement in re.sub(r"--[^\n]*", "", schema).split(";"):
                if statement.strip():
                    db.run(statement)

    def close(self) -> None:
        self._pool.close()


class Store:
    """`target` is a SQLite file path, or a `postgresql://` URL."""

    def __init__(self, target: str | Path):
        target = str(target)
        if target.startswith(("postgresql://", "postgres://")):
            self._backend = _Postgres(target)
        else:
            self._backend = _SQLite(target)
        self._backend.create(SCHEMA)

    @property
    def kind(self) -> str:
        return "postgres" if self._backend.postgres else "sqlite"

    def _db(self):
        return self._backend.session()

    def close(self) -> None:
        self._backend.close()

    # Devices

    def register(self, user_id: str, api_key: str, environment: str, start_token: str | None) -> Device:
        with self._db() as db:
            row = db.one("select id from devices where api_key = ?", (api_key,))
            device_id = row["id"] if row else str(uuid.uuid4())
            db.run(
                """insert into devices (id, user_id, api_key, environment, start_token, created_at)
                   values (?, ?, ?, ?, ?, ?)
                   on conflict(id) do update set environment = excluded.environment,
                   start_token = coalesce(excluded.start_token, devices.start_token)""",
                (device_id, user_id, api_key, environment, start_token, _now()),
            )
            # Registering again (the app opened) means the key works.
            db.run("delete from refused_keys where device_id = ?", (device_id,))
            return self.device(device_id)

    def device(self, device_id: str) -> Device | None:
        with self._db() as db:
            row = db.one("select * from devices where id = ?", (device_id,))
        return (
            Device(row["id"], row["user_id"], row["api_key"], row["environment"], row["start_token"]) if row else None
        )

    def device_for_key(self, api_key: str) -> Device | None:
        with self._db() as db:
            row = db.one("select id from devices where api_key = ?", (api_key,))
        return self.device(row["id"]) if row else None

    def devices(self) -> list[Device]:
        with self._db() as db:
            rows = db.rows("select * from devices order by created_at, id")
        return [Device(r["id"], r["user_id"], r["api_key"], r["environment"], r["start_token"]) for r in rows]

    def unregister(self, device_id: str) -> None:
        with self._db() as db:
            db.run("delete from devices where id = ?", (device_id,))

    def forget_start_token(self, device_id: str) -> None:
        with self._db() as db:
            db.run("update devices set start_token = null where id = ?", (device_id,))

    def key_refused(self, device_id: str, now: datetime) -> tuple[datetime, bool]:
        """AdventureLog refused this phone's key again. Returns since when it has, without a
        success in between, and whether this is the first time."""
        with self._db() as db:
            row = db.one("select since from refused_keys where device_id = ?", (device_id,))
            if row:
                return datetime.fromisoformat(row["since"]), False
            db.run(
                "insert into refused_keys (device_id, since) values (?, ?) on conflict(device_id) do nothing",
                (device_id, now.astimezone(UTC).isoformat(timespec="seconds")),
            )
        return now, True

    def key_accepted(self, device_id: str) -> None:
        with self._db() as db:
            db.run("delete from refused_keys where device_id = ?", (device_id,))

    # Leases

    def take_lease(self, name: str, holder: str, now: datetime, seconds: int) -> bool:
        """Takes or renews `name` for `holder` until `seconds` from now. False while another
        holder's lease hasn't run out, so only one of several companions runs the poller."""
        stamp = now.astimezone(UTC).isoformat(timespec="seconds")
        until = datetime.fromtimestamp(now.timestamp() + seconds, UTC).isoformat(timespec="seconds")
        with self._db() as db:
            db.run(
                """insert into leases (name, holder, expires_at) values (?, ?, ?)
                   on conflict(name) do update set holder = excluded.holder, expires_at = excluded.expires_at
                   where leases.holder = excluded.holder or leases.expires_at <= ?""",
                (name, holder, until, stamp),
            )
            row = db.one("select holder from leases where name = ?", (name,))
        return row is not None and row["holder"] == holder

    # Activities

    def activity(self, device_id: str, trip_id: str, row_id: str) -> Activity | None:
        with self._db() as db:
            row = db.one(
                "select * from activities where device_id = ? and trip_id = ? and row_id = ?",
                (device_id, trip_id, row_id),
            )
        return self._activity(row) if row else None

    def open_activities(self, device_id: str) -> list[Activity]:
        with self._db() as db:
            rows = db.rows(
                "select * from activities where device_id = ? and ended = 0 order by trip_id, row_id", (device_id,)
            )
        return [self._activity(r) for r in rows]

    def save_token(self, device_id: str, trip_id: str, row_id: str, push_token: str) -> None:
        """The phone started (or iOS started for it) the activity and has a token for updates."""
        with self._db() as db:
            db.run(
                """insert into activities (device_id, trip_id, row_id, push_token) values (?, ?, ?, ?)
                   on conflict(device_id, trip_id, row_id) do update set push_token = excluded.push_token, ended = 0""",
                (device_id, trip_id, row_id, push_token),
            )

    def mark_start_sent(self, device_id: str, trip_id: str, row_id: str) -> None:
        with self._db() as db:
            db.run(
                """insert into activities (device_id, trip_id, row_id, start_sent) values (?, ?, ?, 1)
                   on conflict(device_id, trip_id, row_id) do update set start_sent = 1""",
                (device_id, trip_id, row_id),
            )

    def save_state(self, activity: Activity, state: dict) -> None:
        with self._db() as db:
            db.run(
                "update activities set last_state = ? where device_id = ? and trip_id = ? and row_id = ?",
                (json.dumps(state, sort_keys=True), activity.device_id, activity.trip_id, activity.row_id),
            )

    def mark_ended(self, activity: Activity) -> None:
        with self._db() as db:
            db.run(
                "update activities set ended = 1 where device_id = ? and trip_id = ? and row_id = ?",
                (activity.device_id, activity.trip_id, activity.row_id),
            )

    # Photos (Stage 6)

    def api_key_for(self, user_id: str) -> str | None:
        """A key to reach AdventureLog as this person: any of their registered phones'."""
        with self._db() as db:
            row = db.one("select api_key from devices where user_id = ? order by created_at, id limit 1", (user_id,))
        return row["api_key"] if row else None

    def photo_trip(self, user_id: str, trip_id: str) -> PhotoTrip:
        with self._db() as db:
            row = db.one("select * from photo_trips where user_id = ? and trip_id = ?", (user_id, trip_id))
        return self._photo_trip(row) if row else PhotoTrip(user_id, trip_id, False, 0, None, None, None)

    def photo_trips(self) -> list[PhotoTrip]:
        with self._db() as db:
            rows = db.rows("select * from photo_trips where enabled = 1 order by user_id, trip_id")
        return [self._photo_trip(r) for r in rows]

    def save_photo_trip(self, user_id: str, trip_id: str, enabled: bool, camera_offset_minutes: int) -> PhotoTrip:
        """Turning a trip back on (off, then on) lets undone photos be matched again, so a day
        can be redone with a new camera offset. One still waiting to be unlinked in AdventureLog
        stays until it is."""
        with self._db() as db:
            if enabled and not self.photo_trip(user_id, trip_id).enabled:
                db.run(
                    """delete from photo_assets where user_id = ? and trip_id = ? and state = 'undone'
                       and image_id is null""",
                    (user_id, trip_id),
                )
            db.run(
                """insert into photo_trips (user_id, trip_id, enabled, camera_offset_minutes) values (?, ?, ?, ?)
                   on conflict(user_id, trip_id) do update set enabled = excluded.enabled,
                   camera_offset_minutes = excluded.camera_offset_minutes""",
                (user_id, trip_id, int(enabled), camera_offset_minutes),
            )
            return self.photo_trip(user_id, trip_id)

    def photo_trip_ran(self, trip: PhotoTrip, when: str, error: str | None, album_id: str | None) -> None:
        with self._db() as db:
            db.run(
                "update photo_trips set last_run = ?, last_error = ?, album_id = ? where user_id = ? and trip_id = ?",
                (when, error, album_id, trip.user_id, trip.trip_id),
            )

    def photo_assets(self, user_id: str, trip_id: str) -> list[PhotoAsset]:
        with self._db() as db:
            rows = db.rows(
                "select * from photo_assets where user_id = ? and trip_id = ? order by taken_at, asset_id",
                (user_id, trip_id),
            )
        return [PhotoAsset(**r) for r in rows]

    def save_photo_asset(self, asset: PhotoAsset) -> None:
        with self._db() as db:
            db.run(
                """insert into photo_assets
                   (user_id, trip_id, asset_id, taken_at, day, stop_id, stop_kind, stop_title, image_id, state, detail)
                   values (:user_id, :trip_id, :asset_id, :taken_at, :day, :stop_id, :stop_kind, :stop_title,
                           :image_id, :state, :detail)
                   on conflict(user_id, trip_id, asset_id) do update set taken_at = excluded.taken_at,
                   day = excluded.day, stop_id = excluded.stop_id, stop_kind = excluded.stop_kind,
                   stop_title = excluded.stop_title, image_id = excluded.image_id, state = excluded.state,
                   detail = excluded.detail""",
                asdict(asset),
            )

    def sidecars(self, user_id: str, trip_id: str, asset_id: str) -> list[dict]:
        with self._db() as db:
            return db.rows(
                """select path, backup, written_hash from photo_sidecars
                   where user_id = ? and trip_id = ? and asset_id = ? order by path""",
                (user_id, trip_id, asset_id),
            )

    def save_sidecar(
        self, user_id: str, trip_id: str, asset_id: str, path: str, backup: str | None, written_hash: str
    ) -> None:
        """The first backup of a file is kept: writing it again only updates the hash."""
        with self._db() as db:
            db.run(
                """insert into photo_sidecars (user_id, trip_id, asset_id, path, backup, written_hash)
                   values (?, ?, ?, ?, ?, ?)
                   on conflict(user_id, trip_id, asset_id, path) do update set written_hash = excluded.written_hash""",
                (user_id, trip_id, asset_id, path, backup, written_hash),
            )

    def forget_sidecar(self, user_id: str, trip_id: str, asset_id: str, path: str) -> None:
        with self._db() as db:
            db.run(
                "delete from photo_sidecars where user_id = ? and trip_id = ? and asset_id = ? and path = ?",
                (user_id, trip_id, asset_id, path),
            )

    # Flight status (#39)

    def flight_status(self, provider: str, number: str, local_date: str) -> dict | None:
        with self._db() as db:
            row = db.one(
                "select * from flight_status where provider = ? and number = ? and local_date = ?",
                (provider, number, local_date),
            )
        if row is None:
            return None
        return {
            "status": json.loads(row["status"]) if row["status"] else None,
            "fetched_at": row["fetched_at"],
            "unchanged": row["unchanged"],
        }

    def save_flight_status(
        self, provider: str, number: str, local_date: str, status: dict | None, fetched_at: str, unchanged: int
    ) -> None:
        with self._db() as db:
            db.run(
                """insert into flight_status (provider, number, local_date, status, fetched_at, unchanged)
                   values (?, ?, ?, ?, ?, ?)
                   on conflict(provider, number, local_date) do update set status = excluded.status,
                   fetched_at = excluded.fetched_at, unchanged = excluded.unchanged""",
                (
                    provider,
                    number,
                    local_date,
                    json.dumps(status, sort_keys=True) if status else None,
                    fetched_at,
                    unchanged,
                ),
            )

    def add_flight_units(self, provider: str, day: date, units: int) -> None:
        with self._db() as db:
            db.run(
                """insert into flight_units (provider, day, units) values (?, ?, ?)
                   on conflict(provider, day) do update set units = flight_units.units + excluded.units""",
                (provider, day.isoformat(), units),
            )

    def flight_units(self, provider: str, day: date) -> tuple[int, int]:
        """What the provider billed on that day, and in that day's month so far."""
        with self._db() as db:
            today = db.one("select units from flight_units where provider = ? and day = ?", (provider, day.isoformat()))
            month = db.one(
                "select coalesce(sum(units), 0) as units from flight_units where provider = ? and day like ?",
                (provider, f"{day.isoformat()[:7]}-%"),
            )
        return (today["units"] if today else 0, int(month["units"]))

    @staticmethod
    def _photo_trip(row: dict) -> PhotoTrip:
        return PhotoTrip(
            row["user_id"],
            row["trip_id"],
            bool(row["enabled"]),
            row["camera_offset_minutes"],
            row["album_id"],
            row["last_run"],
            row["last_error"],
        )

    @staticmethod
    def _activity(row: dict) -> Activity:
        return Activity(
            row["device_id"],
            row["trip_id"],
            row["row_id"],
            row["push_token"],
            bool(row["start_sent"]),
            json.loads(row["last_state"]) if row["last_state"] else None,
            bool(row["ended"]),
        )
