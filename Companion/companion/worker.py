# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Every few minutes: work out each phone's Live Activity and push what changed.

- A window opened and the phone gave a push-to-start token: start the activity, so it appears
  without the app being opened.
- The activity is running and its times changed in AdventureLog (a moved flight): update it.
- Its time came, or the item was skipped, deleted or moved out of the window: end it.
"""

from __future__ import annotations

import contextlib
import logging
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

from . import planner
from .adventurelog import AdventureLog, AdventureLogError, AdventureLogRefused
from .apns import APNs, TokenGone
from .flight_status import Flight, FlightStatusService, alert_for, apply, normalize_number
from .store import Device, Store

log = logging.getLogger("companion")


def _clock(stamp: int, zone: str) -> str:
    return datetime.fromtimestamp(stamp, ZoneInfo(zone)).strftime("%H:%M")


def start_alert(plan: planner.Plan) -> dict:
    info, state = plan.info, plan.state
    if info["kind"] == "flight":
        body = f"Boards {_clock(state['target'], info['zoneIdentifier'])} · departs {_clock(state['departure'], info['zoneIdentifier'])}"
    else:
        body = f"Starts {_clock(state['target'], info['zoneIdentifier'])}"
    return {"title": info["title"], "body": body}


# A delayed flight's status is still looked at this long after its planned departure.
DELAY_HORIZON = timedelta(hours=12)
# A phone whose key AdventureLog has refused at every poll for this long is unregistered (#20): the
# key was deleted or its user removed. If it was only a server misconfiguration, the phone
# registers again the next time the app opens.
REFUSED_FOR = timedelta(hours=24)


async def tick(
    store: Store,
    adventurelog: AdventureLog,
    apns: APNs | None,
    now: datetime | None = None,
    flights: FlightStatusService | None = None,
) -> None:
    now = now or datetime.now(UTC)
    for device in store.devices():
        # One phone's failure (AdventureLog down for that key, APNs refusing a push) is logged
        # and the pass goes on to the next phone.
        try:
            await _tick_device(device, store, adventurelog, apns, now, flights)
        except Exception:
            log.exception("device %s", device.id)


async def flight_adjuster(trips: list[dict], now: datetime, flights: FlightStatusService | None):
    """Live status for the flights near now, as a planner `adjust` (#39); None without a provider."""
    if flights is None:
        return None
    known: dict[tuple[str, str], tuple] = {}
    for trip in trips:
        for plan in planner.candidates(trip):
            number = normalize_number((plan.flight or {}).get("number"))
            if not number or not (plan.window_start <= now < plan.flight["departure"] + DELAY_HORIZON):
                continue
            flight = Flight(number, plan.flight["origin"], plan.flight["departure"], plan.flight["zone"])
            known[plan.key] = (await flights.status(flight, now), plan.flight["departure"])

    def adjust(plan: planner.Plan) -> planner.Plan | None:
        if plan.key not in known:
            return plan
        status, scheduled = known[plan.key]
        result = apply(plan.state, scheduled, status, now)
        if result is None:
            return None
        state, end = result
        return replace(plan, state=state, end=end)

    return adjust


async def _tick_device(
    device: Device,
    store: Store,
    adventurelog: AdventureLog,
    apns: APNs | None,
    now: datetime,
    flights: FlightStatusService | None = None,
) -> None:
    try:
        trips = await adventurelog.current_trips(device.api_key, now.date())
    except AdventureLogRefused as error:
        since, first = store.key_refused(device.id, now)
        if now - since >= REFUSED_FOR:
            log.warning("device %s: AdventureLog has refused its key since %s; unregistered it", device.id, since)
            store.unregister(device.id)
        elif first:
            log.warning("device %s: %s", device.id, error)
        else:
            log.debug("device %s: %s (since %s)", device.id, error, since)
        return
    except AdventureLogError as error:
        log.warning("device %s: %s", device.id, error)
        return
    store.key_accepted(device.id)
    adjust = await flight_adjuster(trips, now, flights)
    plans = [p for trip in trips if (p := planner.current(trip, now, adjust))]
    plan = min(plans, key=lambda p: p.end) if plans else None

    # End whatever no longer matches the plan.
    for activity in store.open_activities(device.id):
        if plan is not None and activity.key == plan.key:
            continue
        if activity.push_token and apns:
            with contextlib.suppress(TokenGone):
                await apns.end(activity.push_token, device.environment, activity.last_state or {}, int(now.timestamp()))
        store.mark_ended(activity)

    if plan is None:
        return
    activity = store.activity(device.id, *plan.key)
    if activity and activity.push_token and not activity.ended:
        if activity.last_state != plan.state and apns:
            alert = None
            if flights and plan.info["kind"] == "flight":
                alert = alert_for(plan.info["title"], activity.last_state, plan.state, plan.info["zoneIdentifier"])
            try:
                await apns.update(activity.push_token, device.environment, plan.state, int(plan.end.timestamp()), alert)
                store.save_state(activity, plan.state)
            except TokenGone:
                store.mark_ended(activity)
    elif not (activity and activity.start_sent) and device.start_token and apns:
        try:
            await apns.start(device.start_token, device.environment, plan.info, plan.state, start_alert(plan))
            store.mark_start_sent(device.id, *plan.key)
            started = store.activity(device.id, *plan.key)
            if started:
                store.save_state(started, plan.state)
        except TokenGone:
            store.forget_start_token(device.id)
