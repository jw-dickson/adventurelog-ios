# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Registered phones, their Live Activities and the photos matched to trips, in one SQLite file.

The file holds each phone's AdventureLog API key (the companion polls with it), so keep it on a
volume only the companion can read. Signing out on the phone unregisters it.
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path

SCHEMA = """
create table if not exists devices (
    id text primary key,
    user_id text not null,
    api_key text not null unique,
    environment text not null default 'production',
    start_token text,
    created_at text not null default (datetime('now'))
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


class Store:
    def __init__(self, path: str | Path):
        self.db = sqlite3.connect(str(path), check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("pragma foreign_keys = on")
        self.db.executescript(SCHEMA)

    # Devices

    def register(self, user_id: str, api_key: str, environment: str, start_token: str | None) -> Device:
        row = self.db.execute("select id from devices where api_key = ?", (api_key,)).fetchone()
        device_id = row["id"] if row else str(uuid.uuid4())
        self.db.execute(
            """insert into devices (id, user_id, api_key, environment, start_token) values (?, ?, ?, ?, ?)
               on conflict(id) do update set environment = excluded.environment,
               start_token = coalesce(excluded.start_token, devices.start_token)""",
            (device_id, user_id, api_key, environment, start_token),
        )
        self.db.commit()
        return self.device(device_id)

    def device(self, device_id: str) -> Device | None:
        row = self.db.execute("select * from devices where id = ?", (device_id,)).fetchone()
        return (
            Device(row["id"], row["user_id"], row["api_key"], row["environment"], row["start_token"]) if row else None
        )

    def device_for_key(self, api_key: str) -> Device | None:
        row = self.db.execute("select id from devices where api_key = ?", (api_key,)).fetchone()
        return self.device(row["id"]) if row else None

    def devices(self) -> list[Device]:
        return [self.device(r["id"]) for r in self.db.execute("select id from devices")]

    def unregister(self, device_id: str) -> None:
        self.db.execute("delete from devices where id = ?", (device_id,))
        self.db.commit()

    def forget_start_token(self, device_id: str) -> None:
        self.db.execute("update devices set start_token = null where id = ?", (device_id,))
        self.db.commit()

    # Activities

    def activity(self, device_id: str, trip_id: str, row_id: str) -> Activity | None:
        row = self.db.execute(
            "select * from activities where device_id = ? and trip_id = ? and row_id = ?", (device_id, trip_id, row_id)
        ).fetchone()
        return self._activity(row) if row else None

    def open_activities(self, device_id: str) -> list[Activity]:
        rows = self.db.execute("select * from activities where device_id = ? and ended = 0", (device_id,))
        return [self._activity(r) for r in rows]

    def save_token(self, device_id: str, trip_id: str, row_id: str, push_token: str) -> None:
        """The phone started (or iOS started for it) the activity and has a token for updates."""
        self.db.execute(
            """insert into activities (device_id, trip_id, row_id, push_token) values (?, ?, ?, ?)
               on conflict(device_id, trip_id, row_id) do update set push_token = excluded.push_token, ended = 0""",
            (device_id, trip_id, row_id, push_token),
        )
        self.db.commit()

    def mark_start_sent(self, device_id: str, trip_id: str, row_id: str) -> None:
        self.db.execute(
            """insert into activities (device_id, trip_id, row_id, start_sent) values (?, ?, ?, 1)
               on conflict(device_id, trip_id, row_id) do update set start_sent = 1""",
            (device_id, trip_id, row_id),
        )
        self.db.commit()

    def save_state(self, activity: Activity, state: dict) -> None:
        self.db.execute(
            "update activities set last_state = ? where device_id = ? and trip_id = ? and row_id = ?",
            (json.dumps(state, sort_keys=True), activity.device_id, activity.trip_id, activity.row_id),
        )
        self.db.commit()

    def mark_ended(self, activity: Activity) -> None:
        self.db.execute(
            "update activities set ended = 1 where device_id = ? and trip_id = ? and row_id = ?",
            (activity.device_id, activity.trip_id, activity.row_id),
        )
        self.db.commit()

    # Photos (Stage 6)

    def api_key_for(self, user_id: str) -> str | None:
        """A key to reach AdventureLog as this person: any of their registered phones'."""
        row = self.db.execute("select api_key from devices where user_id = ? limit 1", (user_id,)).fetchone()
        return row["api_key"] if row else None

    def photo_trip(self, user_id: str, trip_id: str) -> PhotoTrip:
        row = self.db.execute(
            "select * from photo_trips where user_id = ? and trip_id = ?", (user_id, trip_id)
        ).fetchone()
        return self._photo_trip(row) if row else PhotoTrip(user_id, trip_id, False, 0, None, None, None)

    def photo_trips(self) -> list[PhotoTrip]:
        return [self._photo_trip(r) for r in self.db.execute("select * from photo_trips where enabled = 1")]

    def save_photo_trip(self, user_id: str, trip_id: str, enabled: bool, camera_offset_minutes: int) -> PhotoTrip:
        self.db.execute(
            """insert into photo_trips (user_id, trip_id, enabled, camera_offset_minutes) values (?, ?, ?, ?)
               on conflict(user_id, trip_id) do update set enabled = excluded.enabled,
               camera_offset_minutes = excluded.camera_offset_minutes""",
            (user_id, trip_id, int(enabled), camera_offset_minutes),
        )
        self.db.commit()
        return self.photo_trip(user_id, trip_id)

    def photo_trip_ran(self, trip: PhotoTrip, when: str, error: str | None, album_id: str | None) -> None:
        self.db.execute(
            "update photo_trips set last_run = ?, last_error = ?, album_id = ? where user_id = ? and trip_id = ?",
            (when, error, album_id, trip.user_id, trip.trip_id),
        )
        self.db.commit()

    def photo_assets(self, user_id: str, trip_id: str) -> list[PhotoAsset]:
        rows = self.db.execute(
            "select * from photo_assets where user_id = ? and trip_id = ? order by taken_at", (user_id, trip_id)
        )
        return [PhotoAsset(**dict(r)) for r in rows]

    def save_photo_asset(self, asset: PhotoAsset) -> None:
        self.db.execute(
            """insert or replace into photo_assets
               (user_id, trip_id, asset_id, taken_at, day, stop_id, stop_kind, stop_title, image_id, state, detail)
               values (:user_id, :trip_id, :asset_id, :taken_at, :day, :stop_id, :stop_kind, :stop_title,
                       :image_id, :state, :detail)""",
            asdict(asset),
        )
        self.db.commit()

    def sidecars(self, user_id: str, trip_id: str, asset_id: str) -> list[dict]:
        rows = self.db.execute(
            "select path, backup, written_hash from photo_sidecars where user_id = ? and trip_id = ? and asset_id = ?",
            (user_id, trip_id, asset_id),
        )
        return [dict(r) for r in rows]

    def save_sidecar(
        self, user_id: str, trip_id: str, asset_id: str, path: str, backup: str | None, written_hash: str
    ) -> None:
        """The first backup of a file is kept: writing it again only updates the hash."""
        self.db.execute(
            """insert into photo_sidecars (user_id, trip_id, asset_id, path, backup, written_hash)
               values (?, ?, ?, ?, ?, ?)
               on conflict(user_id, trip_id, asset_id, path) do update set written_hash = excluded.written_hash""",
            (user_id, trip_id, asset_id, path, backup, written_hash),
        )
        self.db.commit()

    def forget_sidecar(self, user_id: str, trip_id: str, asset_id: str, path: str) -> None:
        self.db.execute(
            "delete from photo_sidecars where user_id = ? and trip_id = ? and asset_id = ? and path = ?",
            (user_id, trip_id, asset_id, path),
        )
        self.db.commit()

    @staticmethod
    def _photo_trip(row) -> PhotoTrip:
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
    def _activity(row) -> Activity:
        return Activity(
            row["device_id"],
            row["trip_id"],
            row["row_id"],
            row["push_token"],
            bool(row["start_sent"]),
            json.loads(row["last_state"]) if row["last_state"] else None,
            bool(row["ended"]),
        )
