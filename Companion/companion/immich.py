# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""The few Immich calls the photo matcher makes (Stage 6), with the companion's own Immich API key.

The key needs `asset.read`, `job.create`, `album.create`, `album.read` and `albumAsset.create`
(and `albumAsset.delete` for undo). It never needs to upload or delete assets.
"""

from __future__ import annotations

from datetime import datetime

import httpx

PAGE_SIZE = 250


class ImmichError(Exception):
    """Immich refused the key or couldn't be reached."""


class Immich:
    def __init__(self, base_url: str, api_key: str, transport: httpx.AsyncBaseTransport | None = None):
        base = base_url.rstrip("/")
        if not base.endswith("/api"):
            base += "/api"
        self._client = httpx.AsyncClient(
            base_url=base + "/",
            transport=transport,
            timeout=30,
            headers={"Accept": "application/json", "x-api-key": api_key},
        )

    async def close(self) -> None:
        await self._client.aclose()

    async def _call(self, method: str, path: str, body: dict | None = None):
        try:
            response = await self._client.request(method, path, json=body)
        except httpx.HTTPError as error:
            raise ImmichError(f"Immich can't be reached: {error}") from error
        if response.status_code in (401, 403):
            raise ImmichError(f"Immich refused the key for {path}.")
        if response.status_code >= 400:
            raise ImmichError(f"Immich answered {response.status_code} for {path}.")
        if response.status_code == 204 or not response.content:
            return None
        try:
            return response.json()
        except ValueError as error:
            raise ImmichError(f"Immich sent something other than JSON for {path}.") from error

    async def photos_taken(self, after: datetime, before: datetime, limit: int = 5000) -> list[dict]:
        """Photos Immich dates between the two moments, with their EXIF, oldest first."""
        found: list[dict] = []
        page: int | None = 1
        while page and len(found) < limit:
            result = await self._call(
                "POST",
                "search/metadata",
                {
                    "takenAfter": after.isoformat(),
                    "takenBefore": before.isoformat(),
                    "type": "IMAGE",
                    "withExif": True,
                    "order": "asc",
                    "page": page,
                    "size": PAGE_SIZE,
                },
            )
            assets = (result or {}).get("assets") or {}
            found += assets.get("items") or []
            next_page = assets.get("nextPage")
            page = int(next_page) if next_page else None
        return found[:limit]

    async def refresh_metadata(self, asset_ids: list[str]) -> None:
        """Have Immich read the photos' sidecars again, so its tags and places catch up."""
        for start in range(0, len(asset_ids), 500):
            await self._call(
                "POST", "assets/jobs", {"assetIds": asset_ids[start : start + 500], "name": "refresh-metadata"}
            )

    async def create_album(self, name: str, description: str) -> str:
        album = await self._call("POST", "albums", {"albumName": name, "description": description})
        return str(album["id"])

    async def album_exists(self, album_id: str) -> bool:
        try:
            await self._call("GET", f"albums/{album_id}?withoutAssets=true")
        except ImmichError:
            return False
        return True

    async def add_to_album(self, album_id: str, asset_ids: list[str]) -> None:
        for start in range(0, len(asset_ids), 500):
            await self._call("PUT", f"albums/{album_id}/assets", {"ids": asset_ids[start : start + 500]})

    async def remove_from_album(self, album_id: str, asset_ids: list[str]) -> None:
        for start in range(0, len(asset_ids), 500):
            await self._call("DELETE", f"albums/{album_id}/assets", {"ids": asset_ids[start : start + 500]})
