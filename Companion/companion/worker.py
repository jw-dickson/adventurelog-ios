# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Every few minutes: work out each phone's Live Activity and push what changed.

- A window opened and the phone gave a push-to-start token: start the activity, so it appears
  without the app being opened.
- The activity is running and its times changed in AdventureLog (a moved flight): update it.
- Its time came, or the item was skipped, deleted or moved out of the window: end it.
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from . import planner
from .adventurelog import AdventureLog, AdventureLogError
from .apns import APNs, TokenGone
from .store import Store

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


async def tick(store: Store, adventurelog: AdventureLog, apns: APNs | None, now: datetime | None = None) -> None:
    now = now or datetime.now(timezone.utc)
    for device in store.devices():
        try:
            trips = await adventurelog.current_trips(device.api_key, now.date())
        except AdventureLogError as error:
            log.warning("device %s: %s", device.id, error)
            continue
        plans = [p for trip in trips if (p := planner.current(trip, now))]
        plan = min(plans, key=lambda p: p.end) if plans else None

        # End whatever no longer matches the plan.
        for activity in store.open_activities(device.id):
            if plan is not None and activity.key == plan.key:
                continue
            if activity.push_token and apns:
                try:
                    await apns.end(activity.push_token, device.environment, activity.last_state or {}, int(now.timestamp()))
                except TokenGone:
                    pass
            store.mark_ended(activity)

        if plan is None:
            continue
        activity = store.activity(device.id, *plan.key)
        if activity and activity.push_token and not activity.ended:
            if activity.last_state != plan.state and apns:
                try:
                    await apns.update(activity.push_token, device.environment, plan.state, int(plan.end.timestamp()))
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
