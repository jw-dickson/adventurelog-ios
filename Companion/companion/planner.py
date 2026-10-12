# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Which flight or booked tour should have a Live Activity now.

A port of `LiveActivityPlanner` in AdventureLogKit, working on AdventureLog's collection JSON. The
tests check it against the same synthetic trip and the same times as the Swift tests, so the
companion and the phone agree on what to show.

Times in the output are Unix seconds, matching `LiveActivityInfo` and `LiveActivityState`.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

FLIGHT_LEAD = timedelta(hours=3)
TOUR_LEAD = timedelta(hours=1)
BOARDING_BEFORE = timedelta(minutes=45)
BOOKED_TAGS = {"booked", "fixed", "reserved"}


@dataclass(frozen=True)
class Plan:
    """One Live Activity: its fixed attributes, its current state and when it ends."""

    info: dict
    state: dict
    end: datetime
    window_start: datetime = field(compare=False)

    @property
    def key(self) -> tuple[str, str]:
        return (self.info["tripID"], self.info["rowID"])


def parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def _blank(value) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def city(airport: str | None) -> str | None:
    """'Hobart Airport (HBA)' → 'Hobart'; 'Los Angeles International Airport (LAX)' → 'Los Angeles'."""
    name = _blank(airport)
    if not name:
        return None
    name = re.sub(r"\s*\([A-Z]{3}\)$", "", name)
    for suffix in (" International Airport", " Airport"):
        if name.endswith(suffix):
            name = name[: -len(suffix)]
            break
    return _blank(name)


def flight_title(leg: dict) -> str | None:
    number = _blank(leg.get("flight_number"))
    if not number:
        return None
    spaced = re.sub(r"^([A-Za-z]{2,3})\s*(\d+)$", r"\1 \2", number)
    place = city(leg.get("to_location")) or _blank(leg.get("end_code"))
    return f"{spaced} to {place}" if place else spaced


def first_line(text: str | None) -> str | None:
    if not text:
        return None
    for line in str(text).splitlines():
        if line.strip():
            return line.strip()
    return None


def _visit_on(location: dict, day: str) -> dict | None:
    """The location's timed visit on the itinerary row's date (in the visit's own zone)."""
    for visit in location.get("visits") or []:
        start = parse_time(visit.get("start_date"))
        if not start:
            continue
        zone = ZoneInfo(visit.get("timezone") or "UTC")
        local = start.astimezone(zone)
        if local.date().isoformat() != day:
            continue
        end = parse_time(visit.get("end_date"))
        all_day = (
            local.hour == 0 and local.minute == 0 and (end is None or end.astimezone(zone).strftime("%H:%M") == "23:59")
        )
        return None if all_day else visit
    return None


def candidates(trip: dict) -> list[Plan]:
    trip_id = trip["id"]
    transport = {t["id"]: t for t in trip.get("transportations") or []}
    locations = {loc["id"]: loc for loc in trip.get("locations") or []}
    rows = sorted(
        (r for r in trip.get("itinerary") or [] if r.get("date") and not r.get("is_global")),
        key=lambda r: (r["date"], r.get("order", 0)),
    )

    plans: list[Plan] = []
    seen: set[str] = set()
    earlier_flights: list[dict] = []
    for row in rows:
        item_id = row.get("object_id") or (row.get("item") or {}).get("id")
        kind = (row.get("item") or {}).get("type") or row.get("object_name")
        if kind == "transportation" and item_id in transport:
            leg = transport[item_id]
            if leg.get("type") != "plane":
                continue
            if item_id in seen:
                continue
            seen.add(item_id)
            start = parse_time(leg.get("date"))
            if not start:
                earlier_flights.append(leg)
                continue
            origin = _blank(leg.get("start_code")) or _blank(leg.get("from_location"))
            connecting = any(
                _blank(prev.get("end_code"))
                and prev.get("end_code") == leg.get("start_code")
                and (arrival := parse_time(prev.get("end_date"))) is not None
                and (start - arrival) < timedelta(hours=12)
                for prev in earlier_flights
            )
            earlier_flights.append(leg)
            eyebrow = " · ".join(x for x in ("Connection" if connecting else "Flight", origin) if x)
            window = start - FLIGHT_LEAD
            info = {
                "tripID": trip_id,
                "rowID": row["id"],
                "kind": "flight",
                "eyebrow": eyebrow,
                "title": flight_title(leg) or leg.get("name") or "Flight",
                "detail": first_line(leg.get("description")),
                "zoneIdentifier": leg.get("start_timezone") or "UTC",
                "windowStart": int(window.timestamp()),
            }
            state = {
                "phase": "upcoming",
                "target": int((start - BOARDING_BEFORE).timestamp()),
                "departure": int(start.timestamp()),
            }
            plans.append(Plan(info=info, state=state, end=start, window_start=window))
        elif kind == "location" and item_id in locations:
            place = locations[item_id]
            tags = {str(t).lower() for t in place.get("tags") or []}
            if not tags & BOOKED_TAGS or item_id in seen:
                continue
            visit = _visit_on(place, row["date"])
            if not visit:
                continue
            seen.add(item_id)
            start = parse_time(visit["start_date"])
            window = start - TOUR_LEAD
            notes = "\n\n".join(x for x in (_blank(place.get("description")), _blank(visit.get("notes"))) if x)
            info = {
                "tripID": trip_id,
                "rowID": row["id"],
                "kind": "tour",
                "eyebrow": "Booked tour",
                "title": place.get("name") or "Tour",
                "detail": first_line(notes),
                "zoneIdentifier": visit.get("timezone") or "UTC",
                "windowStart": int(window.timestamp()),
            }
            stamp = int(start.timestamp())
            plans.append(
                Plan(
                    info=info,
                    state={"phase": "upcoming", "target": stamp, "departure": stamp},
                    end=start,
                    window_start=window,
                )
            )
    for plan in plans:
        # Drop absent optional fields, as the Swift encoder does.
        for key in ("detail",):
            if plan.info.get(key) is None:
                plan.info.pop(key, None)
    return plans


def current(trip: dict, now: datetime) -> Plan | None:
    """The activity that should be showing at `now`, if any. The sooner-ending one wins."""
    live = [p for p in candidates(trip) if p.window_start <= now < p.end]
    if not live:
        return None
    plan = min(live, key=lambda p: p.end)
    if plan.info["kind"] == "flight" and now.timestamp() >= plan.state["target"]:
        plan = Plan(
            info=plan.info, state={**plan.state, "phase": "boarding"}, end=plan.end, window_start=plan.window_start
        )
    return plan
