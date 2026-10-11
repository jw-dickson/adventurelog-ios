# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""The companion's HTTP API, for the AdventureLog iOS app.

The phone authenticates with the AdventureLog API key it already holds (`X-API-Key`); the companion
checks it against the AdventureLog server it is configured for, so there are no separate accounts.
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import time
from typing import Literal

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from .adventurelog import AdventureLog, AdventureLogError
from .apns import APNs, APNsConfig
from .store import Device, Store
from .worker import tick

log = logging.getLogger("companion")


class Settings:
    """Read from the environment; see Companion/README.md."""

    def __init__(self, env: dict[str, str] | None = None):
        env = os.environ if env is None else env
        self.adventurelog_url = env.get("ADVENTURELOG_URL", "")
        self.database = env.get("COMPANION_DB", "/data/companion.sqlite")
        self.poll_seconds = int(env.get("COMPANION_POLL_SECONDS", "300"))
        key_path = env.get("APNS_KEY_PATH")
        self.apns = None
        if key_path and env.get("APNS_KEY_ID") and env.get("APNS_TEAM_ID") and env.get("APNS_BUNDLE_ID"):
            with open(key_path) as handle:
                self.apns = APNsConfig(key_id=env["APNS_KEY_ID"], team_id=env["APNS_TEAM_ID"],
                                       private_key=handle.read(), bundle_id=env["APNS_BUNDLE_ID"])


class Registration(BaseModel):
    environment: Literal["production", "sandbox"] = "production"
    start_token: str | None = Field(default=None, alias="startToken")


class ActivityToken(BaseModel):
    trip_id: str = Field(alias="tripID")
    row_id: str = Field(alias="rowID")
    push_token: str = Field(alias="pushToken")


def create_app(settings: Settings | None = None, adventurelog: AdventureLog | None = None,
               apns: APNs | None = None, run_worker: bool = True) -> FastAPI:
    settings = settings or Settings()
    store = Store(settings.database)
    adventurelog = adventurelog or AdventureLog(settings.adventurelog_url)
    if apns is None and settings.apns:
        apns = APNs(settings.apns)
    verified: dict[str, tuple[str, float]] = {}

    async def poll_forever():
        while True:
            try:
                await tick(store, adventurelog, apns)
            except Exception:  # keep polling whatever one pass hits
                log.exception("poll failed")
            await asyncio.sleep(settings.poll_seconds)

    @contextlib.asynccontextmanager
    async def lifespan(_app: FastAPI):
        task = asyncio.create_task(poll_forever()) if run_worker else None
        if apns is None:
            log.warning("APNs is not configured: the companion will not send pushes.")
        yield
        if task:
            task.cancel()

    app = FastAPI(title="AdventureLog companion", lifespan=lifespan)
    app.state.store = store

    async def user_for(x_api_key: str = Header(...)) -> str:
        """The AdventureLog user the key belongs to, checked at most every ten minutes."""
        cached = verified.get(x_api_key)
        if cached and time.time() - cached[1] < 600:
            return cached[0]
        try:
            user = await adventurelog.user(x_api_key)
        except AdventureLogError as error:
            raise HTTPException(status_code=401, detail=str(error)) from error
        user_id = str(user.get("uuid") or user.get("id") or user.get("username"))
        verified[x_api_key] = (user_id, time.time())
        return user_id

    def device_for(x_api_key: str = Header(...), _user: str = Depends(user_for)) -> Device:
        device = store.device_for_key(x_api_key)
        if device is None:
            raise HTTPException(status_code=404, detail="This phone isn't registered.")
        return device

    @app.get("/healthz")
    async def health():
        return {"ok": True, "pushes": apns is not None}

    @app.post("/v1/devices")
    async def register(body: Registration, x_api_key: str = Header(...), user: str = Depends(user_for)):
        device = store.register(user, x_api_key, body.environment, body.start_token)
        return {"id": device.id}

    @app.delete("/v1/devices", status_code=204)
    async def unregister(device: Device = Depends(device_for)):
        store.unregister(device.id)

    @app.put("/v1/activities", status_code=204)
    async def activity_token(body: ActivityToken, device: Device = Depends(device_for)):
        store.save_token(device.id, body.trip_id, body.row_id, body.push_token)

    return app
