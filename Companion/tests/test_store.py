# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""The store on both backends (#20): SQLite always, Postgres when a test database is given."""

import asyncio
import sqlite3
import threading
from datetime import UTC, date, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from companion.app import Settings, create_app
from companion.store import PhotoAsset, Store
from companion.worker import REFUSED_FOR, tick
from tests.test_worker import KEY, fake_adventurelog

NOW = datetime(2027, 3, 8, 9, 0, tzinfo=UTC)


def asset(asset_id: str, state: str = "done", image_id: str | None = "img-1") -> PhotoAsset:
    return PhotoAsset(
        "user-alex", "trip-1", asset_id, "2027-03-08T10:00:00+11:00", "2027-03-08",
        "stop-1", "location", "Wineglass Bay Lookout", image_id, state, None,
    )  # fmt: skip


def test_devices_and_activities(store_target):
    store = Store(store_target)
    phone = store.register("user-alex", "key-1", "production", "start-1")
    # Registering again with the same key is the same phone; a missing start token keeps the old one.
    again = store.register("user-alex", "key-1", "sandbox", None)
    assert again.id == phone.id and again.environment == "sandbox" and again.start_token == "start-1"
    other = store.register("user-sam", "key-2", "production", None)
    assert {d.id for d in store.devices()} == {phone.id, other.id}
    assert store.device_for_key("key-2") == other
    assert store.api_key_for("user-alex") == "key-1"

    store.save_token(phone.id, "trip-1", "row-1", "push-1")
    store.mark_start_sent(phone.id, "trip-1", "row-2")
    store.save_state(store.activity(phone.id, "trip-1", "row-1"), {"phase": "upcoming", "target": 1})
    activity = store.activity(phone.id, "trip-1", "row-1")
    assert activity.push_token == "push-1" and activity.last_state == {"phase": "upcoming", "target": 1}
    assert store.activity(phone.id, "trip-1", "row-2").start_sent is True
    assert [a.row_id for a in store.open_activities(phone.id)] == ["row-1", "row-2"]
    store.mark_ended(activity)
    assert [a.row_id for a in store.open_activities(phone.id)] == ["row-2"]
    # A new token for an ended activity opens it again.
    store.save_token(phone.id, "trip-1", "row-1", "push-2")
    assert store.activity(phone.id, "trip-1", "row-1").ended is False

    store.forget_start_token(phone.id)
    assert store.device(phone.id).start_token is None
    store.unregister(phone.id)
    assert store.device(phone.id) is None
    assert store.open_activities(phone.id) == [], "a phone's activities go with it"
    store.close()


def test_photos_and_flights(store_target):
    store = Store(store_target)
    store.save_photo_trip("user-alex", "trip-1", True, 5)
    assert [t.trip_id for t in store.photo_trips()] == ["trip-1"]
    store.save_photo_asset(asset("a1"))
    store.save_photo_asset(asset("a2", state="undone", image_id=None))
    store.save_photo_asset(asset("a3", state="undone", image_id="img-3"))
    store.save_photo_asset(asset("a1", state="failed"))  # the same photo again replaces it
    assert [(a.asset_id, a.state) for a in store.photo_assets("user-alex", "trip-1")] == [
        ("a1", "failed"), ("a2", "undone"), ("a3", "undone"),
    ]  # fmt: skip
    trip = store.photo_trip("user-alex", "trip-1")
    store.photo_trip_ran(trip, "2027-03-08T12:00:00Z", None, "album-1")
    assert store.photo_trip("user-alex", "trip-1").album_id == "album-1"
    # Off and on again: undone photos with nothing left to unlink may be matched again.
    store.save_photo_trip("user-alex", "trip-1", False, 5)
    store.save_photo_trip("user-alex", "trip-1", True, 0)
    assert [a.asset_id for a in store.photo_assets("user-alex", "trip-1")] == ["a1", "a3"]

    store.save_sidecar("user-alex", "trip-1", "a1", "/x.xmp", "<old/>", "h1")
    store.save_sidecar("user-alex", "trip-1", "a1", "/x.xmp", "<newer/>", "h2")
    assert store.sidecars("user-alex", "trip-1", "a1") == [{"path": "/x.xmp", "backup": "<old/>", "written_hash": "h2"}]
    store.forget_sidecar("user-alex", "trip-1", "a1", "/x.xmp")
    assert store.sidecars("user-alex", "trip-1", "a1") == []

    store.save_flight_status("aeroapi", "EX1501", "2027-03-08", {"gate": "3"}, "2027-03-08T06:00:00Z", 0)
    store.save_flight_status("aeroapi", "EX1501", "2027-03-08", None, "2027-03-08T06:15:00Z", 1)
    assert store.flight_status("aeroapi", "EX1501", "2027-03-08") == {
        "status": None, "fetched_at": "2027-03-08T06:15:00Z", "unchanged": 1,
    }  # fmt: skip
    store.add_flight_units("aeroapi", date(2027, 3, 7), 3)
    store.add_flight_units("aeroapi", date(2027, 3, 8), 2)
    store.add_flight_units("aeroapi", date(2027, 3, 8), 1)
    store.add_flight_units("aeroapi", date(2027, 2, 28), 9)
    assert store.flight_units("aeroapi", date(2027, 3, 8)) == (3, 6)
    store.close()


def test_a_failed_unit_of_work_changes_nothing(store_target):
    store = Store(store_target)
    with pytest.raises(RuntimeError), store._db() as db:
        db.run("insert into flight_units (provider, day, units) values (?, ?, ?)", ("aeroapi", "2027-03-08", 4))
        raise RuntimeError("halfway")
    assert store.flight_units("aeroapi", date(2027, 3, 8)) == (0, 0)
    store.close()


def test_state_survives_a_restart(store_target):
    first = Store(store_target)
    phone = first.register("user-alex", "key-1", "production", None)
    first.close()
    second = Store(store_target)  # creating the tables again is harmless
    assert second.device_for_key("key-1").id == phone.id
    second.close()


def test_one_companion_polls_at_a_time(store_target):
    """Two companions on one database: the lease goes to one, and to the other once it lapses."""
    a, b = Store(store_target), Store(store_target)
    assert a.take_lease("poller", "a", NOW, 900)
    assert not b.take_lease("poller", "b", NOW + timedelta(minutes=5), 900)
    assert a.take_lease("poller", "a", NOW + timedelta(minutes=5), 900), "the holder renews"
    assert not b.take_lease("poller", "b", NOW + timedelta(minutes=19), 900)
    assert b.take_lease("poller", "b", NOW + timedelta(minutes=20), 900), "a lapsed lease can be taken"
    assert not a.take_lease("poller", "a", NOW + timedelta(minutes=21), 900)
    a.close()
    b.close()


def test_threads_can_share_the_store(store_target):
    """The API's sync dependencies run in a threadpool beside the poller (#20)."""
    store = Store(store_target)
    phone = store.register("user-alex", "key-1", "production", None)
    errors: list[BaseException] = []

    def work(n: int) -> None:
        try:
            for i in range(40):
                store.device_for_key("key-1")
                store.save_token(phone.id, "trip-1", f"row-{n}-{i}", "push")
                store.open_activities(phone.id)
        except BaseException as error:  # noqa: BLE001 - collected for the assertion
            errors.append(error)

    threads = [threading.Thread(target=work, args=(n,)) for n in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert errors == []
    assert len(store.open_activities(phone.id)) == 8 * 40
    store.close()


def test_a_key_refused_for_a_day_is_unregistered(store_target):
    store = Store(store_target)
    phone = store.register("user-alex", KEY, "production", None)
    refusing = fake_adventurelog(keys=frozenset())
    asyncio.run(tick(store, refusing, None, now=NOW))
    assert store.key_refused(phone.id, NOW + timedelta(minutes=5)) == (NOW, False)
    asyncio.run(tick(store, refusing, None, now=NOW + REFUSED_FOR - timedelta(minutes=5)))
    assert store.device(phone.id) is not None

    # A success in between starts the count again.
    asyncio.run(tick(store, fake_adventurelog(), None, now=NOW + REFUSED_FOR - timedelta(minutes=1)))
    asyncio.run(tick(store, refusing, None, now=NOW + REFUSED_FOR))
    assert store.device(phone.id) is not None
    asyncio.run(tick(store, refusing, None, now=NOW + 2 * REFUSED_FOR))
    assert store.device(phone.id) is None
    store.close()


def test_the_api_runs_on_either_backend(store_target):
    key = "COMPANION_DATABASE_URL" if store_target.startswith("postgres") else "COMPANION_DB"
    settings = Settings({"ADVENTURELOG_URL": "https://adventurelog.example", key: store_target})
    app = create_app(settings, adventurelog=fake_adventurelog(), run_worker=False)
    with TestClient(app) as api:
        assert api.get("/healthz").json()["storage"] == ("postgres" if key == "COMPANION_DATABASE_URL" else "sqlite")
        headers = {"X-API-Key": KEY}
        assert api.post("/v1/devices", json={"environment": "sandbox"}, headers=headers).status_code == 200
        assert app.state.store.device_for_key(KEY).environment == "sandbox"
        assert api.delete("/v1/devices", headers=headers).status_code == 204
        assert app.state.store.device_for_key(KEY) is None


def test_a_file_from_before_still_opens(tmp_path):
    """SQLite files made before #20 had a default on created_at; they keep working."""
    path = tmp_path / "old.sqlite"
    with sqlite3.connect(path) as old:
        old.execute(
            """create table devices (id text primary key, user_id text not null, api_key text not null unique,
               environment text not null default 'production', start_token text,
               created_at text not null default (datetime('now')))"""
        )
        old.execute("insert into devices (id, user_id, api_key) values ('d1', 'user-alex', 'key-1')")
    store = Store(path)
    assert store.device_for_key("key-1").id == "d1"
    assert store.register("user-sam", "key-2", "production", None).user_id == "user-sam"
    assert len(store.devices()) == 2
    store.close()


def test_a_sqlite_file_can_be_copied_across(tmp_path, store_target):
    from companion.migrate import copy

    source = tmp_path / "from.sqlite"
    old = Store(source)
    phone = old.register("user-alex", "key-1", "production", "start-1")
    old.save_token(phone.id, "trip-1", "row-1", "push-1")
    old.save_photo_trip("user-alex", "trip-1", True, 5)
    old.save_photo_asset(asset("a1"))
    old.save_sidecar("user-alex", "trip-1", "a1", "/x.xmp", "<old/>", "h1")
    old.add_flight_units("aeroapi", date(2027, 3, 8), 2)
    old.close()

    target = store_target if store_target.startswith("postgres") else str(tmp_path / "to.sqlite")
    counts = copy(str(source), target)
    assert counts["devices"] == 1 and counts["photo_sidecars"] == 1
    assert copy(str(source), target) == counts, "running it again changes nothing"
    new = Store(target)
    assert new.device_for_key("key-1").start_token == "start-1"
    assert new.activity(phone.id, "trip-1", "row-1").push_token == "push-1"
    assert new.photo_trip("user-alex", "trip-1").camera_offset_minutes == 5
    assert [a.asset_id for a in new.photo_assets("user-alex", "trip-1")] == ["a1"]
    assert new.sidecars("user-alex", "trip-1", "a1")[0]["backup"] == "<old/>"
    assert new.flight_units("aeroapi", date(2027, 3, 8)) == (2, 2)
    new.close()


def test_a_pass_stops_when_its_lease_is_lost():
    """The lease is renewed while a pass runs, and a pass that loses it starts nothing more."""
    from companion.app import run_while_leading

    started: list[int] = []
    answers = iter([True, True, False])
    renewals: list[bool] = []

    def renew() -> bool:
        renewals.append(answer := next(answers))
        return answer

    async def long_pass():
        for step in range(100):
            started.append(step)
            await asyncio.sleep(0.01)

    assert asyncio.run(run_while_leading(long_pass(), renew, 0.03)) is False
    assert renewals == [True, True, False]
    assert len(started) < 100

    async def short_pass():
        started.clear()
        started.append(0)

    assert asyncio.run(run_while_leading(short_pass(), lambda: False, 1)) is True, "a pass that ends first is done"


def test_shutting_down_stops_a_running_pass():
    from companion.app import run_while_leading

    stopped = []

    async def long_pass():
        try:
            await asyncio.sleep(10)
        finally:
            stopped.append(True)

    async def poller_then_shutdown():
        poller = asyncio.ensure_future(run_while_leading(long_pass(), lambda: True, 5))
        await asyncio.sleep(0.05)
        poller.cancel()
        with pytest.raises(asyncio.CancelledError):
            await poller
        # Checked here, before asyncio.run would cancel anything left over.
        assert stopped == [True], "the pass was cancelled and waited for before the poller ended"

    asyncio.run(poller_then_shutdown())
