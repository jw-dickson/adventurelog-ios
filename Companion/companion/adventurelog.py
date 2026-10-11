# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""The few AdventureLog calls the companion makes, with the API key the phone registered."""
from __future__ import annotations

from datetime import date, timedelta

import httpx


class AdventureLogError(Exception):
    """The server refused the key or couldn't be reached."""


class AdventureLog:
    def __init__(self, base_url: str, transport: httpx.AsyncBaseTransport | None = None):
        self.base_url = base_url.rstrip("/") + "/"
        self._client = httpx.AsyncClient(base_url=self.base_url, transport=transport, timeout=20,
                                         headers={"Accept": "application/json"})

    async def close(self) -> None:
        await self._client.aclose()

    async def _get(self, path: str, api_key: str):
        try:
            response = await self._client.get(path, headers={"X-API-Key": api_key})
        except httpx.HTTPError as error:
            raise AdventureLogError(f"AdventureLog can't be reached: {error}") from error
        if response.status_code in (401, 403):
            raise AdventureLogError("AdventureLog refused the API key.")
        if response.status_code >= 400:
            raise AdventureLogError(f"AdventureLog answered {response.status_code} for {path}.")
        return response.json()

    async def user(self, api_key: str) -> dict:
        """Who the key belongs to; also how a registration is checked."""
        return await self._get("auth/user-metadata/", api_key)

    async def current_trips(self, api_key: str, today: date) -> list[dict]:
        """Full details of the trips happening around today (a day either side, for zones)."""
        owned = await self._get("api/collections/all/", api_key)
        shared = await self._get("api/collections/shared/", api_key)
        trips = []
        for summary in [*owned, *shared]:
            start, end = summary.get("start_date"), summary.get("end_date")
            if not start or not end:
                continue
            if date.fromisoformat(start) - timedelta(days=1) <= today <= date.fromisoformat(end) + timedelta(days=1):
                trips.append(await self._get(f"api/collections/{summary['id']}/", api_key))
        return trips
