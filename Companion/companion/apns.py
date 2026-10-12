# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Live Activity pushes through Apple's push service (token-based auth, HTTP/2)."""

from __future__ import annotations

import time
from dataclasses import dataclass

import httpx
import jwt

HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}
ATTRIBUTES_TYPE = "TripActivityAttributes"


class TokenGone(Exception):
    """Apple says the token is no longer valid (the activity ended or the app was removed)."""


@dataclass
class APNsConfig:
    key_id: str
    team_id: str
    private_key: str  # contents of the .p8 file
    bundle_id: str


class APNs:
    def __init__(self, config: APNsConfig, transport: httpx.AsyncBaseTransport | None = None):
        self.config = config
        self._client = httpx.AsyncClient(http2=transport is None, transport=transport, timeout=20)
        self._jwt: tuple[str, float] | None = None

    async def close(self) -> None:
        await self._client.aclose()

    def _bearer(self) -> str:
        # Apple accepts a token for an hour and refuses ones refreshed more than every 20 minutes.
        if self._jwt is None or time.time() - self._jwt[1] > 50 * 60:
            issued = time.time()
            token = jwt.encode(
                {"iss": self.config.team_id, "iat": int(issued)},
                self.config.private_key,
                algorithm="ES256",
                headers={"kid": self.config.key_id},
            )
            self._jwt = (token, issued)
        return self._jwt[0]

    async def send(self, token: str, environment: str, aps: dict, priority: int = 10) -> None:
        response = await self._client.post(
            f"{HOSTS[environment]}/3/device/{token}",
            json={"aps": {"timestamp": int(time.time()), **aps}},
            headers={
                "authorization": f"bearer {self._bearer()}",
                "apns-push-type": "liveactivity",
                "apns-topic": f"{self.config.bundle_id}.push-type.liveactivity",
                "apns-priority": str(priority),
            },
        )
        if response.status_code == 410 or (response.status_code == 400 and "BadDeviceToken" in response.text):
            raise TokenGone(response.text)
        response.raise_for_status()

    # The three Live Activity events.

    async def start(self, token: str, environment: str, info: dict, state: dict, alert: dict) -> None:
        await self.send(
            token,
            environment,
            {
                "event": "start",
                "content-state": state,
                "attributes-type": ATTRIBUTES_TYPE,
                "attributes": {"info": info},
                "alert": alert,
            },
        )

    async def update(self, token: str, environment: str, state: dict, stale_at: int, alert: dict | None = None) -> None:
        """A quiet update, or with `alert` one that lights the screen (a delay, a gate change)."""
        aps = {"event": "update", "content-state": state, "stale-date": stale_at}
        if alert:
            aps["alert"] = alert
        await self.send(token, environment, aps, priority=10 if alert else 5)

    async def end(self, token: str, environment: str, state: dict, dismiss_at: int) -> None:
        await self.send(token, environment, {"event": "end", "content-state": state, "dismissal-date": dismiss_at})
