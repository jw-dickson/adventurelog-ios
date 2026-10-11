# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""The same expectations as LiveActivityTests.swift, on the same synthetic trip."""
import json
from datetime import datetime, timezone
from pathlib import Path

from companion import planner

ROOT = Path(__file__).resolve().parents[2]
TRIP = json.loads((ROOT / "Fixtures/adventurelog-v0.13.0/responses/collections__detail.json").read_text())


def at(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc)


def stamp(text: str) -> int:
    return int(at(text).timestamp())


def test_the_sydney_connection_matches_the_mockup():
    plan = planner.current(TRIP, at("2027-03-06T18:03:00Z"))
    assert plan is not None
    assert plan.info["kind"] == "flight"
    assert plan.info["eyebrow"] == "Connection · SYD"
    assert plan.info["title"] == "EX 1501 to Hobart"
    assert plan.info["detail"] == "Domestic connection. Re-check bags at SYD after customs."
    assert plan.info["zoneIdentifier"] == "Australia/Sydney"
    assert plan.info["windowStart"] == stamp("2027-03-06T17:00:00Z")
    assert plan.state == {"phase": "upcoming", "target": stamp("2027-03-06T19:15:00Z"),
                          "departure": stamp("2027-03-06T20:00:00Z")}
    assert plan.end == at("2027-03-06T20:00:00Z")


def test_boarding_then_the_activity_ends():
    plan = planner.current(TRIP, at("2027-03-06T19:30:00Z"))
    assert plan is not None and plan.state["phase"] == "boarding"
    assert planner.current(TRIP, at("2027-03-06T20:00:00Z")) is None


def test_the_first_flight_is_not_a_connection():
    plan = planner.current(TRIP, at("2027-03-05T18:00:00Z"))
    assert plan is not None
    assert plan.info["eyebrow"] == "Flight · DEN"
    assert plan.info["title"] == "EX 101 to Los Angeles"


def test_a_booked_tour_gets_an_hour_and_unbooked_places_none():
    plan = planner.current(TRIP, at("2027-03-06T23:30:00Z"))
    assert plan is not None
    assert (plan.info["kind"], plan.info["eyebrow"], plan.info["title"]) == ("tour", "Booked tour", "Harbour kayak tour")
    assert plan.state["target"] == stamp("2027-03-07T00:00:00Z")
    assert planner.current(TRIP, at("2027-03-06T22:59:00Z")) is None
    assert planner.current(TRIP, at("2027-03-08T04:30:00Z")) is None


def test_states_match_the_push_fixtures():
    """The payloads the app's tests decode use the same field names and Unix seconds."""
    payload = json.loads((ROOT / "Fixtures/live-activity/1-upcoming-gate.apns").read_text())
    pushed = payload["aps"]["content-state"]
    plan = planner.current(TRIP, at("2027-03-06T18:03:00Z"))
    assert {k: pushed[k] for k in plan.state} == plan.state


def test_airport_names_become_cities():
    assert planner.city("Hobart Airport (HBA)") == "Hobart"
    assert planner.city("Los Angeles International Airport (LAX)") == "Los Angeles"
    assert planner.city("Gatwick") == "Gatwick"
    assert planner.city("  ") is None
