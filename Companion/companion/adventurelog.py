# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""The few AdventureLog calls the companion makes, with the API key the phone registered."""

from __future__ import annotations

import contextlib
from datetime import date, timedelta

import httpx


class AdventureLogError(Exception):
    """The server refused the key or couldn't be reached."""


class AdventureLogNotFound(AdventureLogError):
    """The server has no such thing (or won't show it to this key)."""


class AdventureLog:
    def __init__(self, base_url: str, transport: httpx.AsyncBaseTransport | None = None):
        self.base_url = base_url.rstrip("/") + "/"
        self._client = httpx.AsyncClient(
            base_url=self.base_url, transport=transport, timeout=20, headers={"Accept": "application/json"}
        )

    async def close(self) -> None:
        await self._client.aclose()

    async def _get(self, path: str, api_key: str):
        return await self._send("GET", path, api_key)

    async def _send(self, method: str, path: str, api_key: str, body: dict | None = None):
        try:
            response = await self._client.request(method, path, headers={"X-API-Key": api_key}, json=body)
        except httpx.HTTPError as error:
            raise AdventureLogError(f"AdventureLog can't be reached: {error}") from error
        if response.status_code in (401, 403):
            raise AdventureLogError("AdventureLog refused the API key.")
        if response.status_code == 404:
            raise AdventureLogNotFound(f"AdventureLog has nothing at {path}.")
        if response.status_code >= 400:
            raise AdventureLogError(f"AdventureLog answered {response.status_code} for {path}.")
        if response.status_code == 204 or not response.content:
            return None
        try:
            return response.json()
        except ValueError as error:
            raise AdventureLogError(f"AdventureLog sent something other than JSON for {path}.") from error

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
            try:
                # A date, or a datetime whose first ten characters are its date.
                first, last = date.fromisoformat(str(start)[:10]), date.fromisoformat(str(end)[:10])
            except ValueError:
                continue  # one malformed trip mustn't stop the rest
            if first - timedelta(days=1) <= today <= last + timedelta(days=1):
                trips.append(await self._get(f"api/collections/{summary['id']}/", api_key))
        return trips

    async def trip(self, api_key: str, trip_id: str) -> dict:
        """One trip in full; also how the companion checks the key can see it."""
        return await self._get(f"api/collections/{trip_id}/", api_key)

    async def link_photo(self, api_key: str, kind: str, item_id: str, immich_id: str) -> str:
        """Show an Immich photo on a place (or stay, or journey) in AdventureLog. Nothing is
        copied: AdventureLog serves it through its own Immich integration."""
        image = await self._send(
            "POST", "api/images/", api_key, {"content_type": kind, "object_id": item_id, "immich_id": immich_id}
        )
        return str((image or {}).get("id"))

    async def unlink_photo(self, api_key: str, image_id: str) -> None:
        """Already gone (removed in AdventureLog by hand) counts as done."""
        with contextlib.suppress(AdventureLogNotFound):
            await self._send("DELETE", f"api/images/{image_id}/", api_key)
