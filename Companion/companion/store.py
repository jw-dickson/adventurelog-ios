# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Registered phones and their Live Activities, in one SQLite file.

The file holds each phone's AdventureLog API key (the companion polls with it), so keep it on a
volume only the companion can read. Signing out on the phone unregisters it.
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from dataclasses import dataclass
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
