# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Live flight status on the sample trip's EX 1501 (#39), against stand-in providers: never a live call."""

from __future__ import annotations

import asyncio
import copy
import json
from datetime import UTC, datetime
from pathlib import Path

import httpx
import pytest

from companion import flight_status as fs
from companion.flight_status import (
    AeroAPI,
    AeroDataBox,
    Flight,
    FlightStatus,
    FlightStatusService,
    FlightStatusSettings,
)
from companion.store import Store
from companion.worker import tick
from tests.test_worker import KEY, FakeAPNs, fake_adventurelog

HERE = Path(__file__).parent / "flight_status"
AEROAPI = json.loads((HERE / "aeroapi-delayed.json").read_text())
AERODATABOX = json.loads((HERE / "aerodatabox-delayed.json").read_text())
EX1501 = Flight("EX1501", "SYD", datetime(2027, 3, 6, 20, 0, tzinfo=UTC), "Australia/Sydney")


def run(coro):
    return asyncio.run(coro)


def at(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


class FakeProvider:
    """Answers like AeroAPI or AeroDataBox from a JSON body, and counts the calls."""

    def __init__(self, kind: str, body, status: int = 200):
        self.body, self.status, self.calls = body, status, []
        transport = httpx.MockTransport(self.handle)
        self.client = AeroAPI("key", transport) if kind == "aeroapi" else AeroDataBox("key", transport=transport)

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        if self.status != 200:
            return httpx.Response(self.status, json={"title": "nope"})
        return httpx.Response(200, json=self.body)


def test_flight_numbers_are_tidied():
    assert fs.normalize_number("ex 0101") == "EX101"
    assert fs.normalize_number("EX-1501") == "EX1501"
    assert fs.normalize_number("EXA1501") == "EXA1501"
    assert fs.normalize_number("9X 12") == "9X12"
    assert fs.normalize_number("Car hire") is None
    assert fs.normalize_number(None) is None


def test_aeroapi_answer():
    provider = FakeProvider("aeroapi", AEROAPI)
    status = run(provider.client.lookup(EX1501))
    assert status == FlightStatus(
        scheduled=at("2027-03-06T20:00:00Z"),
        estimated=at("2027-03-06T20:25:00Z"),
        gate="23",
        terminal="2",
    )
    request = provider.calls[0]
    assert request.url.path == "/aeroapi/flights/EX1501"
    assert request.headers["x-apikey"] == "key"
    assert request.url.params["max_pages"] == "1", "one result set per lookup"


def test_aerodatabox_answer():
    provider = FakeProvider("aerodatabox", AERODATABOX)
    status = run(provider.client.lookup(EX1501))
    assert status.estimated == at("2027-03-06T20:25:00Z") and status.gate == "23" and status.terminal == "2"
    request = provider.calls[0]
    assert request.url.path == "/flights/number/EX1501/2027-03-07", "the local date at the origin"
    assert request.url.params["withFlightPlan"] == "false", "the flight plan would double the cost"
    assert request.headers["x-rapidapi-host"] == "aerodatabox.p.rapidapi.com"


def test_the_planned_leg_is_picked():
    # Same number from another airport, and the next day's: neither is the planned flight.
    body = copy.deepcopy(AEROAPI)
    body["flights"][0]["origin"]["code_iata"] = "MEL"
    assert run(FakeProvider("aeroapi", body).client.lookup(EX1501)) is None
    assert run(FakeProvider("aerodatabox", []).client.lookup(EX1501)) is None
    assert run(FakeProvider("aerodatabox", None, status=404).client.lookup(EX1501)) is None


def test_states_from_answers():
    plan = {"phase": "upcoming", "target": 1804361400, "departure": 1804363200}
    scheduled = at("2027-03-06T20:00:00Z")
    now = at("2027-03-06T18:30:00Z")
    delayed = FlightStatus(scheduled=scheduled, estimated=at("2027-03-06T20:25:00Z"), gate="23", terminal="2")
    state, end = fs.apply(plan, scheduled, delayed, now)
    assert state == {
        "phase": "upcoming",
        "target": int(at("2027-03-06T19:40:00Z").timestamp()),
        "departure": int(at("2027-03-06T20:25:00Z").timestamp()),
        "note": "Delayed 25 min · Terminal 2 · Gate 23",
    }
    assert end == at("2027-03-06T20:25:00Z"), "the activity stays until the new departure"

    # Small slips aren't news; earlier than the schedule never shows.
    on_time = FlightStatus(scheduled=scheduled, estimated=at("2027-03-06T19:50:00Z"), gate="23")
    state, end = fs.apply(plan, scheduled, on_time, now)
    assert state["note"] == "Gate 23" and state["departure"] == plan["departure"] and end == scheduled

    boarding = FlightStatus(scheduled=scheduled, gate="23", boarding=True)
    assert fs.apply(plan, scheduled, boarding, now)[0]["phase"] == "boarding"

    state, end = fs.apply(plan, scheduled, FlightStatus(cancelled=True), now)
    assert state["phase"] == "cancelled" and state["note"] == "Cancelled"
    assert end == at("2027-03-06T21:00:00Z")

    assert fs.apply(plan, scheduled, FlightStatus(departed=True), now) is None
    assert fs.apply(plan, scheduled, None, now) == (plan, scheduled), "nothing known: AdventureLog's times"


def test_alerts_only_for_changes_that_matter():
    before = {"phase": "upcoming", "target": 1804361400, "departure": 1804363200, "note": "Gate 23"}
    zone = "Australia/Sydney"
    assert fs.alert_for("EX 1501 to Hobart", None, before, zone) is None
    later = {**before, "departure": before["departure"] + 25 * 60, "note": "Delayed 25 min · Gate 23"}
    assert fs.alert_for("EX 1501 to Hobart", before, later, zone) == {
        "title": "EX 1501 to Hobart delayed",
        "body": "Now departs 07:25.",
    }
    slightly = {**before, "departure": before["departure"] + 5 * 60}
    assert fs.alert_for("EX 1501 to Hobart", before, slightly, zone) is None
    moved = {**before, "note": "Gate 25"}
    assert fs.alert_for("EX 1501 to Hobart", before, moved, zone)["title"] == "EX 1501 to Hobart: gate change"
    boarding = {**before, "phase": "boarding"}
    assert fs.alert_for("EX 1501 to Hobart", before, boarding, zone)["title"] == "EX 1501 to Hobart is boarding"
    cancelled = {**before, "phase": "cancelled", "note": "Cancelled"}
    assert "cancelled" in fs.alert_for("EX 1501 to Hobart", before, cancelled, zone)["title"]


def service(tmp_path, kind="aeroapi", body=None, monthly=800, daily=200, status=200):
    store = Store(tmp_path / "c.sqlite")
    provider = FakeProvider(kind, AEROAPI if body is None else body, status)
    settings = FlightStatusSettings(kind, "key", monthly, daily)
    return FlightStatusService(settings, store, provider.client), provider, store


def test_lookups_follow_the_schedule(tmp_path):
    flights, provider, _store = service(tmp_path)
    # Before the window: nothing asked.
    assert run(flights.status(EX1501, at("2027-03-06T16:30:00Z"))) is None
    assert provider.calls == []
    # Window open (3 h before): asked, then not again for 15 minutes.
    assert run(flights.status(EX1501, at("2027-03-06T17:05:00Z"))).gate == "23"
    run(flights.status(EX1501, at("2027-03-06T17:15:00Z")))
    assert len(provider.calls) == 1
    run(flights.status(EX1501, at("2027-03-06T17:21:00Z")))
    assert len(provider.calls) == 2
    # The last hour before the (delayed) departure: every 5 minutes.
    run(flights.status(EX1501, at("2027-03-06T19:30:00Z")))
    run(flights.status(EX1501, at("2027-03-06T19:33:00Z")))
    run(flights.status(EX1501, at("2027-03-06T19:36:00Z")))
    assert len(provider.calls) == 4


def test_an_unchanging_answer_backs_off(tmp_path):
    flights, provider, _store = service(tmp_path)
    moment = at("2027-03-06T17:05:00Z")
    times = []
    while moment < at("2027-03-06T19:00:00Z"):
        before = len(provider.calls)
        run(flights.status(EX1501, moment))
        if len(provider.calls) > before:
            times.append(moment.strftime("%H:%M"))
        moment = (
            moment.replace(minute=moment.minute + 1)
            if moment.minute < 59
            else moment.replace(hour=moment.hour + 1, minute=0)
        )
    # 15-minute gaps, then 30 once it hasn't changed three times running.
    assert times[:5] == ["17:05", "17:20", "17:35", "17:50", "18:20"]


def test_the_caps_hold(tmp_path):
    flights, provider, store = service(tmp_path, kind="aerodatabox", body=AERODATABOX, monthly=10, daily=6)
    # Two units a lookup: the daily cap of 6 allows 3 early lookups; at 90% only the last hour.
    for minute in ("17:05", "17:21", "17:37", "17:53", "18:09"):
        run(flights.status(EX1501, at(f"2027-03-06T{minute}:00Z")))
    assert len(provider.calls) == 3
    assert store.flight_units("aerodatabox", at("2027-03-06T00:00:00Z").date()) == (6, 6)
    run(flights.status(EX1501, at("2027-03-06T19:30:00Z")))
    assert len(provider.calls) == 3, "the daily cap is spent"


def test_not_found_is_asked_again_hourly(tmp_path):
    flights, provider, _store = service(tmp_path, body={"flights": []})
    assert run(flights.status(EX1501, at("2027-03-06T17:05:00Z"))) is None
    run(flights.status(EX1501, at("2027-03-06T17:30:00Z")))
    assert len(provider.calls) == 1
    run(flights.status(EX1501, at("2027-03-06T18:06:00Z")))
    assert len(provider.calls) == 2


def test_a_provider_failure_keeps_the_last_answer(tmp_path):
    flights, provider, _store = service(tmp_path)
    run(flights.status(EX1501, at("2027-03-06T17:05:00Z")))
    provider.status = 503
    assert run(flights.status(EX1501, at("2027-03-06T17:25:00Z"))).gate == "23"


def test_settings():
    assert FlightStatusSettings.from_env({}) is None
    settings = FlightStatusSettings.from_env({"FLIGHT_STATUS_PROVIDER": "AeroDataBox", "FLIGHT_STATUS_API_KEY": "k"})
    assert (settings.monthly_units, settings.daily_units) == (360, 90)
    assert (
        FlightStatusSettings.from_env({"FLIGHT_STATUS_PROVIDER": "aeroapi", "FLIGHT_STATUS_API_KEY": "k"}).monthly_units
        == 800
    )
    with pytest.raises(ValueError):
        FlightStatusSettings.from_env({"FLIGHT_STATUS_PROVIDER": "aeroapi"})
    with pytest.raises(ValueError):
        FlightStatusSettings.from_env({"FLIGHT_STATUS_PROVIDER": "radar", "FLIGHT_STATUS_API_KEY": "k"})


def test_a_delay_reaches_the_live_activity(tmp_path):
    """The whole path: the companion starts EX 1501's activity, learns of a 25-minute delay and a
    gate, updates the activity with an alert, keeps it past the old departure, and ends it when the
    flight leaves."""
    store = Store(tmp_path / "c.sqlite")
    device = store.register("user-alex", KEY, "sandbox", "start-token")
    adventurelog, apns = fake_adventurelog(), FakeAPNs()
    on_time = copy.deepcopy(AEROAPI)
    on_time["flights"][0].update(estimated_out="2027-03-06T20:00:00Z", gate_origin=None, terminal_origin=None)
    provider = FakeProvider("aeroapi", on_time)
    flights = FlightStatusService(FlightStatusSettings("aeroapi", "key", 800, 200), store, provider.client)

    run(tick(store, adventurelog, apns.client, at("2027-03-06T18:03:00Z"), flights))
    aps = apns.sent[-1][2]["aps"]
    assert aps["event"] == "start" and "note" not in aps["content-state"]
    info = aps["attributes"]["info"]
    store.save_token(device.id, info["tripID"], info["rowID"], "activity-token")
    store.save_state(store.activity(device.id, info["tripID"], info["rowID"]), aps["content-state"])

    # 20 minutes on, the airline posts a delay and a gate.
    provider.body = AEROAPI
    run(tick(store, adventurelog, apns.client, at("2027-03-06T18:23:00Z"), flights))
    token, headers, body = apns.sent[-1]
    assert token == "activity-token" and body["aps"]["event"] == "update"
    assert body["aps"]["content-state"]["note"] == "Delayed 25 min · Terminal 2 · Gate 23"
    assert body["aps"]["content-state"]["departure"] == int(at("2027-03-06T20:25:00Z").timestamp())
    assert body["aps"]["alert"] == {"title": "EX 1501 to Hobart delayed", "body": "Now departs 07:25."}
    assert headers["apns-priority"] == "10"

    # Past the old departure, the activity is still there, boarding.
    run(tick(store, adventurelog, apns.client, at("2027-03-06T20:05:00Z"), flights))
    assert apns.sent[-1][2]["aps"]["event"] == "update"
    assert apns.sent[-1][2]["aps"]["content-state"]["phase"] == "boarding"
    assert store.open_activities(device.id)

    # It leaves: the activity ends.
    left = copy.deepcopy(AEROAPI)
    left["flights"][0]["actual_out"] = "2027-03-06T20:24:00Z"
    provider.body = left
    run(tick(store, adventurelog, apns.client, at("2027-03-06T20:24:00Z"), flights))
    assert apns.sent[-1][2]["aps"]["event"] == "end"
    assert store.open_activities(device.id) == []


def test_without_a_provider_nothing_changes(tmp_path):
    store = Store(tmp_path / "c.sqlite")
    store.register("user-alex", KEY, "sandbox", "start-token")
    apns = FakeAPNs()
    run(tick(store, fake_adventurelog(), apns.client, at("2027-03-06T18:03:00Z")))
    assert apns.sent[-1][2]["aps"]["content-state"] == {
        "phase": "upcoming",
        "target": int(at("2027-03-06T19:15:00Z").timestamp()),
        "departure": int(at("2027-03-06T20:00:00Z").timestamp()),
    }
