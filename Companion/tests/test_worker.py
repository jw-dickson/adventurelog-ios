# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""A day of pushes for the synthetic trip, against fake AdventureLog and APNs servers."""

import asyncio
import json
from datetime import UTC, datetime
from pathlib import Path

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from companion.adventurelog import AdventureLog
from companion.apns import APNs, APNsConfig
from companion.store import Store
from companion.worker import tick

ROOT = Path(__file__).resolve().parents[2]
RESPONSES = ROOT / "Fixtures/adventurelog-v0.13.0/responses"
KEY = "al_synthetic_key"


def at(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(UTC)


def fake_adventurelog(keys: frozenset[str] = frozenset({KEY}), extra: list[dict] = ()) -> AdventureLog:
    trip = json.loads((RESPONSES / "collections__detail.json").read_text())

    def handler(request: httpx.Request) -> httpx.Response:
        if request.headers.get("X-API-Key") not in keys:
            return httpx.Response(401, json={"detail": "Invalid API key."})
        path = request.url.path
        if path == "/auth/user-metadata/":
            return httpx.Response(200, json={"uuid": "user-alex", "username": "alex"})
        if path == "/api/collections/all/":
            return httpx.Response(
                200, json=[*extra, {"id": trip["id"], "start_date": trip["start_date"], "end_date": trip["end_date"]}]
            )
        if path == "/api/collections/shared/":
            return httpx.Response(200, json=[])
        if path == f"/api/collections/{trip['id']}/":
            return httpx.Response(200, json=trip)
        return httpx.Response(404, json={"detail": "Not found."})

    return AdventureLog("https://adventurelog.example", transport=httpx.MockTransport(handler))


class FakeAPNs:
    def __init__(self, gone: set[str] = frozenset(), failing: set[str] = frozenset()):
        self.sent: list[tuple[str, dict, dict]] = []
        self.gone = gone
        self.failing = failing
        key = (
            ec.generate_private_key(ec.SECP256R1())
            .private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
            .decode()
        )
        self.client = APNs(
            APNsConfig("KEYID12345", "TEAMID1234", key, "app.adventurelog.ios.dev"),
            transport=httpx.MockTransport(self.handle),
        )

    def handle(self, request: httpx.Request) -> httpx.Response:
        token = request.url.path.rsplit("/", 1)[-1]
        if token in self.gone:
            return httpx.Response(410, json={"reason": "Unregistered"})
        if token in self.failing:
            return httpx.Response(500, json={"reason": "InternalServerError"})
        self.sent.append((token, dict(request.headers), json.loads(request.content)))
        return httpx.Response(200)


def run(coro):
    return asyncio.run(coro)


def test_a_flight_starts_by_push_updates_at_boarding_and_ends_at_departure(tmp_path):
    store = Store(tmp_path / "c.sqlite")
    device = store.register("user-alex", KEY, "sandbox", "start-token")
    adventurelog, apns = fake_adventurelog(), FakeAPNs()

    # 05:03 in Sydney: the window for EX 1501 is open, so the companion starts the activity.
    run(tick(store, adventurelog, apns.client, at("2027-03-06T18:03:00Z")))
    assert len(apns.sent) == 1
    token, headers, body = apns.sent[0]
    assert token == "start-token"
    assert headers["apns-push-type"] == "liveactivity"
    assert headers["apns-topic"] == "app.adventurelog.ios.dev.push-type.liveactivity"
    assert headers["authorization"].startswith("bearer ")
    aps = body["aps"]
    assert aps["event"] == "start" and aps["attributes-type"] == "TripActivityAttributes"
    assert aps["attributes"]["info"]["title"] == "EX 1501 to Hobart"
    assert aps["content-state"]["phase"] == "upcoming"
    assert aps["alert"] == {"title": "EX 1501 to Hobart", "body": "Boards 06:15 · departs 07:00"}

    # The next pass sends nothing new.
    run(tick(store, adventurelog, apns.client, at("2027-03-06T18:08:00Z")))
    assert len(apns.sent) == 1

    # The phone reports the activity's own token; boarding moves the countdown to departure.
    store.save_token(
        device.id, aps["attributes"]["info"]["tripID"], aps["attributes"]["info"]["rowID"], "activity-token"
    )
    run(tick(store, adventurelog, apns.client, at("2027-03-06T19:30:00Z")))
    token, _, body = apns.sent[-1]
    assert token == "activity-token" and body["aps"]["event"] == "update"
    assert body["aps"]["content-state"]["phase"] == "boarding"

    # Departure: the activity ends.
    run(tick(store, adventurelog, apns.client, at("2027-03-06T20:01:00Z")))
    token, _, body = apns.sent[-1]
    assert token == "activity-token" and body["aps"]["event"] == "end"
    assert store.open_activities(device.id) == []


def test_a_dead_start_token_is_forgotten(tmp_path):
    store = Store(tmp_path / "c.sqlite")
    device = store.register("user-alex", KEY, "sandbox", "old-token")
    apns = FakeAPNs(gone={"old-token"})
    run(tick(store, fake_adventurelog(), apns.client, at("2027-03-06T18:03:00Z")))
    assert store.device(device.id).start_token is None


def test_nothing_is_sent_outside_a_window_or_without_tokens(tmp_path):
    store = Store(tmp_path / "c.sqlite")
    store.register("user-alex", KEY, "sandbox", None)
    apns = FakeAPNs()
    run(tick(store, fake_adventurelog(), apns.client, at("2027-03-06T18:03:00Z")))  # no start token
    store.register("user-alex", KEY, "sandbox", "start-token")
    run(tick(store, fake_adventurelog(), apns.client, at("2027-03-06T22:00:00Z")))  # between windows
    assert apns.sent == []


def test_one_phone_failing_does_not_stop_the_others(tmp_path):
    store = Store(tmp_path / "c.sqlite")
    store.register("user-alex", "al_first_key", "sandbox", "broken-token")
    store.register("user-alex", KEY, "sandbox", "start-token")
    apns = FakeAPNs(failing={"broken-token"})
    adventurelog = fake_adventurelog(keys=frozenset({"al_first_key", KEY}))
    run(tick(store, adventurelog, apns.client, at("2027-03-06T18:03:00Z")))
    assert [token for token, _, _ in apns.sent] == ["start-token"]


def test_a_trip_with_a_malformed_date_is_skipped(tmp_path):
    bad = [
        {"id": "bad", "start_date": "someday", "end_date": "2027-03-10"},
        {"id": "none", "start_date": None, "end_date": None},
    ]
    trips = run(fake_adventurelog(extra=bad).current_trips(KEY, at("2027-03-06T18:03:00Z").date()))
    assert len(trips) == 1 and trips[0]["id"] != "bad"
