# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Live flight status for a flight's Live Activity (#39; design in docs/FLIGHT-STATUS.md).

Optional: with no provider key nothing is looked up and the activity runs on AdventureLog's times,
as before. With one, the companion asks the provider about flights inside their Live Activity
window, on a schedule that tightens near departure, under monthly and daily caps on what the
provider bills. What it learns is only laid over the activity: nothing is written to AdventureLog.
"""

from __future__ import annotations

import logging
import re
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime, timedelta
from typing import Protocol
from zoneinfo import ZoneInfo

import httpx

log = logging.getLogger("companion")

# Polling (see the design note).
WINDOW = timedelta(hours=3)
LAST_HOUR = timedelta(hours=1)
EARLY_GAP = timedelta(minutes=15)
LATE_GAP = timedelta(minutes=5)
EARLY_GAP_MAX = timedelta(minutes=30)
LATE_GAP_MAX = timedelta(minutes=15)
NOT_FOUND_GAP = timedelta(hours=1)
# A leg further than this from AdventureLog's departure isn't the planned flight.
MATCH_WITHIN = timedelta(hours=6)
# Delays smaller than this are noise: not shown, not alerted.
NOTABLE_DELAY = timedelta(minutes=15)
BOARDING_BEFORE = timedelta(minutes=45)
# A cancelled flight's activity stays this long past the scheduled departure, then ends.
CANCELLED_FOR = timedelta(hours=1)


@dataclass(frozen=True)
class FlightStatus:
    """What a provider said about one flight, reduced to what the activity shows."""

    scheduled: datetime | None = None
    estimated: datetime | None = None
    gate: str | None = None
    terminal: str | None = None
    boarding: bool = False
    cancelled: bool = False
    departed: bool = False

    def to_json(self) -> dict:
        data = asdict(self)
        for key in ("scheduled", "estimated"):
            data[key] = data[key].isoformat() if data[key] else None
        return data

    @classmethod
    def from_json(cls, data: dict) -> FlightStatus:
        values = dict(data)
        for key in ("scheduled", "estimated"):
            values[key] = _time(values.get(key))
        return cls(**{k: v for k, v in values.items() if k in cls.__dataclass_fields__})


@dataclass(frozen=True)
class Flight:
    """A flight from the trip, as the companion asks about it."""

    number: str
    origin: str | None
    departure: datetime  # AdventureLog's, UTC
    zone: str

    @property
    def local_date(self) -> date:
        try:
            return self.departure.astimezone(ZoneInfo(self.zone)).date()
        except (KeyError, ValueError):
            return self.departure.date()


def normalize_number(number: str | None) -> str | None:
    """'ex 0101' → 'EX101'; None for something that isn't a flight number."""
    if not number:
        return None
    text = re.sub(r"[\s\-]", "", number).upper()
    match = re.fullmatch(r"([A-Z]{3}|[A-Z0-9]{2})(\d{1,4})([A-Z]?)", text)
    if not match:
        return None
    airline, digits, suffix = match.groups()
    return f"{airline}{digits.lstrip('0') or '0'}{suffix}"


def _time(value) -> datetime | None:
    """ISO times, and AeroDataBox's '2027-03-06 20:00Z' / '2027-03-06 20:00+11:00'."""
    if not value:
        return None
    text = str(value).strip().replace(" ", "T", 1).replace("Z", "+00:00")
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    return moment.astimezone(UTC) if moment.tzinfo else moment.replace(tzinfo=UTC)


def pick(legs: list[tuple[str | None, datetime | None, FlightStatus]], flight: Flight) -> FlightStatus | None:
    """The leg that is the planned flight: same origin when known, scheduled nearest the plan,
    within six hours of it."""
    best: tuple[timedelta, FlightStatus] | None = None
    for origin, scheduled, status in legs:
        if flight.origin and origin and origin.upper() != flight.origin.upper():
            continue
        if scheduled is None:
            continue
        gap = abs(scheduled - flight.departure)
        if gap <= MATCH_WITHIN and (best is None or gap < best[0]):
            best = (gap, status)
    return best[1] if best else None


# Providers


class ProviderError(Exception):
    """The provider refused the key, or couldn't be reached."""


class Provider(Protocol):
    name: str
    units_per_lookup: int
    default_monthly_units: int

    async def lookup(self, flight: Flight) -> FlightStatus | None: ...


class _HTTPProvider:
    def __init__(self, base_url: str, headers: dict, transport: httpx.AsyncBaseTransport | None = None):
        self._client = httpx.AsyncClient(base_url=base_url, headers=headers, transport=transport, timeout=20)

    async def _get(self, path: str, params: dict | None = None):
        try:
            response = await self._client.get(path, params=params)
        except httpx.HTTPError as error:
            raise ProviderError(f"can't be reached: {error}") from error
        if response.status_code == 404 or response.status_code == 204:
            return None
        if response.status_code in (401, 403):
            raise ProviderError("refused the key")
        if response.status_code == 429:
            raise ProviderError("rate-limited")
        if response.status_code >= 400:
            raise ProviderError(f"answered {response.status_code}")
        try:
            return response.json()
        except ValueError as error:
            raise ProviderError("sent something other than JSON") from error


class AeroAPI(_HTTPProvider):
    """FlightAware AeroAPI v4: `/flights/{ident}`, billed per result set (one page)."""

    name = "aeroapi"
    units_per_lookup = 1
    default_monthly_units = 800

    def __init__(self, api_key: str, transport: httpx.AsyncBaseTransport | None = None):
        super().__init__("https://aeroapi.flightaware.com/aeroapi/", {"x-apikey": api_key}, transport)

    async def lookup(self, flight: Flight) -> FlightStatus | None:
        # One page around the planned departure, so the answer is one result set.
        params = {
            "ident_type": "designator",
            "start": (flight.departure - MATCH_WITHIN).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "end": (flight.departure + MATCH_WITHIN).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "max_pages": 1,
        }
        data = await self._get(f"flights/{flight.number}", params)
        legs = []
        for item in (data or {}).get("flights") or []:
            origin = (item.get("origin") or {}).get("code_iata")
            scheduled = _time(item.get("scheduled_out")) or _time(item.get("scheduled_off"))
            status_text = str(item.get("status") or "").lower()
            status = FlightStatus(
                scheduled=scheduled,
                estimated=_time(item.get("estimated_out")) or _time(item.get("estimated_off")),
                gate=item.get("gate_origin") or None,
                terminal=item.get("terminal_origin") or None,
                boarding="boarding" in status_text,
                cancelled=bool(item.get("cancelled")) or "cancel" in status_text,
                departed=bool(item.get("actual_out") or item.get("actual_off")),
            )
            legs.append((origin, scheduled, status))
        return pick(legs, flight)


class AeroDataBox(_HTTPProvider):
    """AeroDataBox: flight status by number and local date, a Tier 2 endpoint (2 units)."""

    name = "aerodatabox"
    units_per_lookup = 2
    default_monthly_units = 360

    def __init__(self, api_key: str, host: str | None = None, transport: httpx.AsyncBaseTransport | None = None):
        host = host or "aerodatabox.p.rapidapi.com"
        headers = (
            {"x-rapidapi-key": api_key, "x-rapidapi-host": host}
            if "rapidapi" in host
            else {"x-api-market-key": api_key}
        )
        super().__init__(f"https://{host}/", headers, transport)

    async def lookup(self, flight: Flight) -> FlightStatus | None:
        # Without the flight-plan add-on, which can double the cost.
        params = {
            "withAircraftImage": "false",
            "withLocation": "false",
            "withFlightPlan": "false",
            "dateLocalRole": "Departure",
        }
        data = await self._get(f"flights/number/{flight.number}/{flight.local_date.isoformat()}", params)
        legs = []
        for item in data if isinstance(data, list) else []:
            departure = item.get("departure") or {}
            origin = (departure.get("airport") or {}).get("iata")
            scheduled = _time((departure.get("scheduledTime") or {}).get("utc"))
            estimated = _time((departure.get("revisedTime") or {}).get("utc")) or _time(
                (departure.get("predictedTime") or {}).get("utc")
            )
            status_text = str(item.get("status") or "").lower()
            status = FlightStatus(
                scheduled=scheduled,
                estimated=estimated,
                gate=departure.get("gate") or None,
                terminal=departure.get("terminal") or None,
                boarding=status_text in ("boarding", "gateclosed"),
                cancelled=status_text.startswith("cancel"),
                departed=status_text in ("departed", "enroute", "approaching", "arrived", "diverted")
                or bool((departure.get("runwayTime") or {}).get("utc")),
            )
            legs.append((origin, scheduled, status))
        return pick(legs, flight)


@dataclass(frozen=True)
class FlightStatusSettings:
    provider: str
    api_key: str
    monthly_units: int
    daily_units: int
    host: str | None = None

    @classmethod
    def from_env(cls, env: dict[str, str]) -> FlightStatusSettings | None:
        provider = (env.get("FLIGHT_STATUS_PROVIDER") or "").strip().lower()
        key = env.get("FLIGHT_STATUS_API_KEY") or ""
        if not provider and not key:
            return None
        if provider not in ("aeroapi", "aerodatabox"):
            raise ValueError("FLIGHT_STATUS_PROVIDER is aeroapi or aerodatabox.")
        if not key:
            raise ValueError("FLIGHT_STATUS_PROVIDER needs FLIGHT_STATUS_API_KEY.")
        default = AeroAPI.default_monthly_units if provider == "aeroapi" else AeroDataBox.default_monthly_units
        monthly = int(env.get("FLIGHT_STATUS_MONTHLY_UNITS") or default)
        daily = int(env.get("FLIGHT_STATUS_DAILY_UNITS") or max(1, monthly // 4))
        return cls(provider, key, monthly, daily, env.get("FLIGHT_STATUS_API_HOST") or None)

    def make_provider(self, transport: httpx.AsyncBaseTransport | None = None) -> Provider:
        if self.provider == "aeroapi":
            return AeroAPI(self.api_key, transport)
        return AeroDataBox(self.api_key, self.host, transport)


# When to ask


def gap(flight_departure: datetime, now: datetime, unchanged: int) -> timedelta:
    """How long to wait after a lookup: 15 min until the last hour, then 5, doubling (to a cap)
    while the answer doesn't change."""
    late = flight_departure - now <= LAST_HOUR
    base, cap = (LATE_GAP, LATE_GAP_MAX) if late else (EARLY_GAP, EARLY_GAP_MAX)
    wait = base
    for _ in range(unchanged // 3):
        wait = min(wait * 2, cap)
    return wait


def in_window(scheduled: datetime, departure: datetime, now: datetime) -> bool:
    """From three hours before the planned departure (when the activity starts) until the
    flight's latest known departure."""
    return scheduled - WINDOW <= now < departure


# What the activity shows


def apply(
    plan_state: dict, scheduled: datetime, status: FlightStatus | None, now: datetime
) -> tuple[dict, datetime] | None:
    """The activity's state and end with the provider's answer laid over AdventureLog's times.

    None when the flight has left (the activity ends). Times never move before the schedule.
    """
    if status is None:
        return plan_state, scheduled
    if status.departed:
        return None
    if status.cancelled:
        state = {**plan_state, "phase": "cancelled", "note": "Cancelled"}
        return state, scheduled + CANCELLED_FOR
    departure = max(scheduled, status.estimated or scheduled)
    target = departure - BOARDING_BEFORE
    notes = []
    delay = departure - scheduled
    if delay >= NOTABLE_DELAY:
        notes.append(f"Delayed {_duration(delay)}")
    if status.terminal and status.gate:
        notes.append(f"Terminal {status.terminal} · Gate {status.gate}")
    elif status.gate:
        notes.append(f"Gate {status.gate}")
    elif status.terminal:
        notes.append(f"Terminal {status.terminal}")
    state = {
        **plan_state,
        "phase": "boarding" if status.boarding or now >= target else "upcoming",
        "target": int(target.timestamp()),
        "departure": int(departure.timestamp()),
    }
    state.pop("note", None)
    if notes:
        state["note"] = " · ".join(notes)
    if now >= departure:
        return None
    return state, departure


def _duration(delta: timedelta) -> str:
    minutes = int(delta.total_seconds() // 60)
    if minutes < 60:
        return f"{minutes} min"
    hours, rest = divmod(minutes, 60)
    return f"{hours} h {rest} min" if rest else f"{hours} h"


def alert_for(title: str, before: dict | None, after: dict, zone: str) -> dict | None:
    """A sounding alert when the change matters: a delay that moved by 15 min or more, a gate
    change, boarding, or a cancellation. Quiet updates otherwise."""
    if before is None:
        return None
    clock = datetime.fromtimestamp(after["departure"], ZoneInfo(zone)).strftime("%H:%M")
    if after.get("phase") == "cancelled" and before.get("phase") != "cancelled":
        return {"title": f"{title} cancelled", "body": "Check with the airline for your new flight."}
    if abs(after["departure"] - before.get("departure", after["departure"])) >= NOTABLE_DELAY.total_seconds():
        later = after["departure"] > before["departure"]
        return {"title": f"{title} {'delayed' if later else 'leaves sooner'}", "body": f"Now departs {clock}."}
    gate_before, gate_after = _gate(before.get("note")), _gate(after.get("note"))
    if gate_before and gate_after and gate_before != gate_after:
        return {"title": f"{title}: gate change", "body": f"Now gate {gate_after}, departs {clock}."}
    if after.get("phase") == "boarding" and before.get("phase") != "boarding" and gate_after:
        return {"title": f"{title} is boarding", "body": f"Gate {gate_after}, departs {clock}."}
    return None


def _gate(note: str | None) -> str | None:
    match = re.search(r"Gate (\S+)", note or "")
    return match.group(1) if match else None


# The service: cache, schedule and budget around a provider


class FlightStatusService:
    def __init__(self, settings: FlightStatusSettings, store, provider: Provider | None = None):
        self.settings = settings
        self.store = store
        self.provider = provider or settings.make_provider()

    def _budget(self, now: datetime) -> float:
        """The larger share of the monthly and daily caps already billed, 0 to 1+."""
        day, month = self.store.flight_units(self.settings.provider, now.date())
        return max(month / max(self.settings.monthly_units, 1), day / max(self.settings.daily_units, 1))

    async def status(self, flight: Flight, now: datetime) -> FlightStatus | None:
        """The latest answer for the flight, asking the provider first if it's due and the budget
        allows. None when nothing is known (not found, or never asked)."""
        key = (self.provider.name, flight.number, flight.local_date.isoformat())
        cached = self.store.flight_status(*key)
        known = FlightStatus.from_json(cached["status"]) if cached and cached["status"] else None
        departure = max(flight.departure, (known.estimated if known and known.estimated else flight.departure))
        if known and (known.departed or known.cancelled):
            return known
        if not in_window(flight.departure, departure, now):
            return known
        if cached:
            fetched = _time(cached["fetched_at"])
            wait = NOT_FOUND_GAP if cached["status"] is None else gap(departure, now, cached["unchanged"])
            if fetched and now - fetched < wait:
                return known
        share = self._budget(now)
        if share >= 1 or (share >= 0.9 and departure - now > LAST_HOUR):
            return known
        try:
            fresh = await self.provider.lookup(flight)
        except ProviderError as error:
            log.warning("flight status for %s: %s", flight.number, error)
            return known
        self.store.add_flight_units(self.settings.provider, now.date(), self.provider.units_per_lookup)
        unchanged = (cached["unchanged"] + 1) if cached and known == fresh else 0
        self.store.save_flight_status(*key, fresh.to_json() if fresh else None, now.isoformat(), unchanged)
        return fresh if fresh else known
