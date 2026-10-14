# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""The companion's HTTP API, for the AdventureLog iOS app.

The phone authenticates with the AdventureLog API key it already holds (`X-API-Key`); the companion
checks it against the AdventureLog server it is configured for, so there are no separate accounts.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import time
import uuid
from datetime import UTC, date, datetime
from typing import Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Path
from pydantic import BaseModel, Field, field_validator

from . import photo_worker
from .adventurelog import AdventureLog, AdventureLogError
from .apns import APNs, APNsConfig
from .claude import DEFAULT_MODEL, Claude, ClaudeError
from .flight_status import FlightStatusService, FlightStatusSettings
from .immich import Immich, ImmichError
from .photo_worker import PhotoSettings
from .store import Device, Store
from .worker import tick

log = logging.getLogger("companion")

# Replan asks (Stage 5b): more than any day holds is refused before it reaches Claude.
MAX_REPLAN_STOPS = 60
MAX_REPLAN_CHANGES = 40
MAX_REPLAN_BYTES = 100_000


class Settings:
    """Read from the environment; see Companion/README.md."""

    def __init__(self, env: dict[str, str] | None = None):
        env = os.environ if env is None else env
        self.adventurelog_url = env.get("ADVENTURELOG_URL", "")
        # Postgres when a URL is given (#20), else the SQLite file.
        self.database = env.get("COMPANION_DATABASE_URL") or env.get("COMPANION_DB", "/data/companion.sqlite")
        self.poll_seconds = int(env.get("COMPANION_POLL_SECONDS", "300"))
        # Optional (Stage 5b): replan asks go to Claude with this key.
        self.anthropic_api_key = env.get("ANTHROPIC_API_KEY") or None
        self.anthropic_model = env.get("ANTHROPIC_MODEL") or DEFAULT_MODEL
        self.replan_asks_per_hour = int(env.get("COMPANION_REPLAN_ASKS_PER_HOUR", "20"))
        # Optional (Stage 6): photos to the trip, with Immich and the Lightroom library mounted.
        self.photos = PhotoSettings.from_env(env)
        # Optional (#39): live flight status on flight Live Activities.
        self.flight_status = FlightStatusSettings.from_env(env)
        key_path = env.get("APNS_KEY_PATH")
        self.apns = None
        if key_path and env.get("APNS_KEY_ID") and env.get("APNS_TEAM_ID") and env.get("APNS_BUNDLE_ID"):
            with open(key_path) as handle:
                self.apns = APNsConfig(
                    key_id=env["APNS_KEY_ID"],
                    team_id=env["APNS_TEAM_ID"],
                    private_key=handle.read(),
                    bundle_id=env["APNS_BUNDLE_ID"],
                )


class Registration(BaseModel):
    environment: Literal["production", "sandbox"] = "production"
    start_token: str | None = Field(default=None, alias="startToken")


class ReplanAsk(BaseModel):
    situation: dict
    ask: str = Field(max_length=500)
    proposal: dict | None = None
    trip_days: list[str] = Field(default_factory=list, alias="tripDays", max_length=400)

    @field_validator("situation")
    @classmethod
    def a_days_worth(cls, situation: dict) -> dict:
        """No more than a day could hold, since all of it goes to a billed API."""
        stops = situation.get("stops")
        if not isinstance(stops, list) or len(stops) > MAX_REPLAN_STOPS:
            raise ValueError(f"situation.stops must be a list of at most {MAX_REPLAN_STOPS} stops")
        if len(json.dumps(situation)) > MAX_REPLAN_BYTES:
            raise ValueError("situation is too large")
        return situation

    @field_validator("proposal")
    @classmethod
    def a_proposals_worth(cls, proposal: dict | None) -> dict | None:
        if proposal is None:
            return None
        changes = proposal.get("changes", [])
        if not isinstance(changes, list) or len(changes) > MAX_REPLAN_CHANGES:
            raise ValueError(f"proposal.changes must be a list of at most {MAX_REPLAN_CHANGES} changes")
        if len(json.dumps(proposal)) > MAX_REPLAN_BYTES:
            raise ValueError("proposal is too large")
        return proposal


class PhotoSetting(BaseModel):
    enabled: bool
    # A camera clock that drifted: minutes to add to its times (positive when it ran slow).
    camera_offset_minutes: int = Field(default=0, alias="cameraOffsetMinutes", ge=-1440, le=1440)


class PhotoUndo(BaseModel):
    day: date = Field(alias="date")


class ActivityToken(BaseModel):
    trip_id: str = Field(alias="tripID")
    row_id: str = Field(alias="rowID")
    push_token: str = Field(alias="pushToken")


def create_app(
    settings: Settings | None = None,
    adventurelog: AdventureLog | None = None,
    apns: APNs | None = None,
    run_worker: bool = True,
    claude: Claude | None = None,
    immich: Immich | None = None,
    flights: FlightStatusService | None = None,
) -> FastAPI:
    settings = settings or Settings()
    store = Store(settings.database)
    adventurelog = adventurelog or AdventureLog(settings.adventurelog_url)
    if apns is None and settings.apns:
        apns = APNs(settings.apns)
    if claude is None and settings.anthropic_api_key:
        claude = Claude(settings.anthropic_api_key, settings.anthropic_model)
    photo_settings = settings.photos
    if flights is None and settings.flight_status:
        flights = FlightStatusService(settings.flight_status, store)
    if immich is None and photo_settings:
        immich = Immich(photo_settings.immich_url, photo_settings.immich_api_key)
    verified: dict[str, tuple[str, float]] = {}
    # Replan asks per user in the last hour, so a stuck phone can't run up the Claude bill.
    asks: dict[str, list[float]] = {}

    # Several companions can share one Postgres database; only the one holding the lease polls, and
    # another takes over if it stops renewing. With SQLite there's one, and it always holds it.
    holder = str(uuid.uuid4())

    async def poll_forever():
        while True:
            try:
                leading = store.take_lease("poller", holder, datetime.now(UTC), settings.poll_seconds * 3)
            except Exception:
                log.exception("couldn't reach the database")
                leading = False
            if not leading:
                await asyncio.sleep(settings.poll_seconds)
                continue
            try:
                await tick(store, adventurelog, apns, flights=flights)
            except Exception:  # keep polling whatever one pass hits
                log.exception("poll failed")
            if photo_settings and immich:
                try:
                    await photo_worker.run(store, adventurelog, immich, photo_settings)
                except Exception:
                    log.exception("photo pass failed")
            await asyncio.sleep(settings.poll_seconds)

    @contextlib.asynccontextmanager
    async def lifespan(_app: FastAPI):
        task = asyncio.create_task(poll_forever()) if run_worker else None
        if apns is None:
            log.warning("APNs is not configured: the companion will not send pushes.")
        yield
        if task:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        store.close()

    app = FastAPI(title="AdventureLog companion", lifespan=lifespan)
    app.state.store = store
    app.state.photo_settings = photo_settings

    async def user_for(x_api_key: str = Header(...)) -> str:
        """The AdventureLog user the key belongs to, checked at most every ten minutes."""
        now = time.time()
        # Drop expired entries so keys that stop being used don't pile up.
        for key in [key for key, (_, checked) in verified.items() if now - checked >= 600]:
            del verified[key]
        cached = verified.get(x_api_key)
        if cached:
            return cached[0]
        try:
            user = await adventurelog.user(x_api_key)
        except AdventureLogError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        user_id = str(user.get("uuid") or user.get("id") or user.get("username"))
        verified[x_api_key] = (user_id, now)
        return user_id

    def device_for(x_api_key: str = Header(...), _user: str = Depends(user_for)) -> Device:
        device = store.device_for_key(x_api_key)
        if device is None:
            raise HTTPException(status_code=404, detail="This phone isn't registered.")
        return device

    @app.get("/healthz")
    async def health():
        return {
            "ok": True,
            "pushes": apns is not None,
            "replan": claude is not None,
            "photos": photo_settings is not None,
            "flightStatus": flights is not None,
            "storage": store.kind,
        }

    @app.post("/v1/devices")
    async def register(body: Registration, x_api_key: str = Header(...), user: str = Depends(user_for)):
        device = store.register(user, x_api_key, body.environment, body.start_token)
        # Tells the app whether it can start activities while the app is closed (#24).
        return {"id": device.id, "canStart": device.start_token is not None}

    @app.delete("/v1/devices", status_code=204)
    async def unregister(device: Device = Depends(device_for)):
        store.unregister(device.id)

    @app.post("/v1/replan")
    async def replan(body: ReplanAsk, user: str = Depends(user_for)):
        """Claude's take on the rest of today, from what the person asked (Stage 5b)."""
        if claude is None:
            raise HTTPException(status_code=503, detail="Claude isn't set up on this companion.")
        if not body.ask.strip():
            raise HTTPException(status_code=400, detail="Say what you'd like changed.")
        now = time.time()
        # Forget people whose asks are all over an hour old.
        for who in [who for who, moments in asks.items() if all(now - moment >= 3600 for moment in moments)]:
            del asks[who]
        recent = [moment for moment in asks.get(user, []) if now - moment < 3600]
        if len(recent) >= settings.replan_asks_per_hour:
            raise HTTPException(status_code=429, detail="That's a lot of asks this hour. Try again later.")
        asks[user] = [*recent, now]
        try:
            return await claude.replan(body.situation, body.ask.strip(), body.proposal, body.trip_days)
        except ClaudeError as error:
            raise HTTPException(status_code=502, detail=str(error)) from error

    async def trip_for(
        trip_id: str = Path(...), x_api_key: str = Header(...), user: str = Depends(user_for)
    ) -> tuple[str, str]:
        """(person, trip) once AdventureLog confirms the key can see the trip."""
        try:
            trip_id = str(uuid.UUID(trip_id))
        except ValueError as error:
            raise HTTPException(status_code=404, detail="There's no such trip.") from error
        try:
            await adventurelog.trip(x_api_key, trip_id)
        except AdventureLogError as error:
            raise HTTPException(status_code=404, detail="That trip can't be found with this key.") from error
        return user, trip_id

    def photos_ready() -> PhotoSettings:
        if photo_settings is None or immich is None:
            raise HTTPException(status_code=503, detail="Photos aren't set up on this companion.")
        return photo_settings

    @app.get("/v1/trips/{trip_id}/photos")
    async def trip_photos(owner: tuple[str, str] = Depends(trip_for), _ready: PhotoSettings = Depends(photos_ready)):
        """The trip's photo setting and what's been matched, day by day (Stage 6)."""
        return photo_worker.summary(store, *owner)

    @app.put("/v1/trips/{trip_id}/photos")
    async def set_trip_photos(
        body: PhotoSetting,
        owner: tuple[str, str] = Depends(trip_for),
        _ready: PhotoSettings = Depends(photos_ready),
    ):
        store.save_photo_trip(*owner, body.enabled, body.camera_offset_minutes)
        return photo_worker.summary(store, *owner)

    @app.post("/v1/trips/{trip_id}/photos/undo")
    async def undo_trip_photos(
        body: PhotoUndo,
        owner: tuple[str, str] = Depends(trip_for),
        ready: PhotoSettings = Depends(photos_ready),
    ):
        """Puts back a day's sidecars and unlinks its photos. The day's photos aren't matched
        again unless the trip is turned off and on."""
        try:
            result = await photo_worker.undo_day(*owner, body.day.isoformat(), store, adventurelog, immich, ready)
        except (ImmichError, OSError) as error:
            raise HTTPException(status_code=502, detail=str(error)) from error
        return {**result, **photo_worker.summary(store, *owner)}

    @app.put("/v1/activities", status_code=204)
    async def activity_token(body: ActivityToken, device: Device = Depends(device_for)):
        store.save_token(device.id, body.trip_id, body.row_id, body.push_token)

    return app
