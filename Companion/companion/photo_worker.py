# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Photos to the trip (Stage 6): every few minutes, for each trip it's turned on for, find the
trip's new raw photos in Immich, write the stop each was taken at into its sidecar, and tell
Immich to read the sidecars again.

The sidecars are Lightroom Classic's (`IMG_0001.xmp` beside `IMG_0001.ARW`), in a folder the
companion has mounted read-write. Before a sidecar is changed for the first time, a copy of it is
kept, and a day's changes can be undone. The companion never writes outside the folders it's
given, never follows a symlink, and never touches the photos themselves.
"""

from __future__ import annotations

import hashlib
import logging
import os
from dataclasses import dataclass, replace
from datetime import UTC, datetime, time, timedelta
from pathlib import Path, PurePosixPath
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from . import photos
from .adventurelog import AdventureLog, AdventureLogError
from .immich import Immich, ImmichError
from .store import PhotoAsset, PhotoTrip, Store

log = logging.getLogger("companion")

# At most this many new photos per trip each pass, so a first run over a big trip doesn't hold
# up everything else; the next pass carries on.
BATCH = 400


class PhotoSetupError(ValueError):
    """The photo settings are incomplete or wrong; the message says which."""


@dataclass(frozen=True)
class PhotoSettings:
    immich_url: str
    immich_api_key: str
    camera_zone: str
    # (where Immich sees the library, where the companion sees it), longest first
    paths: tuple[tuple[str, Path], ...]
    backups: Path
    links_per_stop: int = 3

    @classmethod
    def from_env(cls, env: dict[str, str]) -> PhotoSettings | None:
        """None when photos aren't set up; an error when they're half set up."""
        names = ("IMMICH_URL", "IMMICH_API_KEY", "PHOTO_PATHS", "CAMERA_ZONE")
        given = [name for name in names if env.get(name)]
        if not given:
            return None
        missing = [name for name in names if not env.get(name)]
        if missing:
            raise PhotoSetupError(f"Photos need {', '.join(missing)} as well as {', '.join(given)}.")
        try:
            ZoneInfo(env["CAMERA_ZONE"])
        except (ZoneInfoNotFoundError, ValueError) as error:
            raise PhotoSetupError(f"CAMERA_ZONE isn't a time zone name like Europe/London: {error}") from error
        paths = []
        for pair in env["PHOTO_PATHS"].split(";"):
            if not pair.strip():
                continue
            immich_side, sep, companion_side = pair.partition("=")
            if not sep or not immich_side.strip() or not companion_side.strip():
                raise PhotoSetupError("PHOTO_PATHS is a list of immich-path=companion-path, separated by ';'.")
            root = Path(companion_side.strip())
            if not root.is_absolute():
                raise PhotoSetupError(f"{root} in PHOTO_PATHS must be an absolute path.")
            paths.append((immich_side.strip().rstrip("/"), root))
        if not paths:
            raise PhotoSetupError("PHOTO_PATHS has no folders in it.")
        return cls(
            immich_url=env["IMMICH_URL"],
            immich_api_key=env["IMMICH_API_KEY"],
            camera_zone=env["CAMERA_ZONE"],
            paths=tuple(sorted(paths, key=lambda p: len(p[0]), reverse=True)),
            backups=Path(env.get("PHOTO_BACKUPS", "/data/sidecar-backups")),
            links_per_stop=int(env.get("PHOTO_LINKS_PER_STOP", "3")),
        )

    def local(self, immich_path: str) -> tuple[Path, Path] | None:
        """Where the companion finds a photo Immich has at `immich_path`, and the root it's
        under; None when it's outside every mapped folder or tries to climb out of one."""
        for prefix, root in self.paths:
            if immich_path == prefix or immich_path.startswith(prefix + "/"):
                relative = PurePosixPath(immich_path[len(prefix) :].lstrip("/"))
                if any(part in ("..", "") for part in relative.parts):
                    return None
                return root / relative, root
        return None


def _hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _inside(path: Path, root: Path) -> bool:
    """Inside the root once symlinks are resolved, and not a symlink itself."""
    if path.is_symlink():
        return False
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        return False
    return True


def _write_atomically(path: Path, data: bytes) -> None:
    """Whole or not at all: Lightroom never sees half a sidecar. The file keeps its mode."""
    temporary = path.with_name(f".{path.name}.companion")
    mode = path.stat().st_mode & 0o777 if path.exists() else None
    with open(temporary, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    if mode is not None:
        os.chmod(temporary, mode)
    os.replace(temporary, path)


class SidecarWriter:
    """Writes and restores one person's sidecars for one trip, keeping backups."""

    def __init__(self, settings: PhotoSettings, store: Store, user_id: str, trip_id: str):
        self.settings, self.store, self.user_id, self.trip_id = settings, store, user_id, trip_id

    def targets(self, immich_path: str) -> tuple[list[Path], Path]:
        """The sidecars to write: Lightroom's `IMG.xmp` always (made if missing), and Immich's
        `IMG.ARW.xmp` only when it's already there."""
        found = self.settings.local(immich_path)
        if found is None:
            raise OSError(f"{immich_path} isn't under a folder in PHOTO_PATHS")
        photo, root = found
        if not photo.is_file():
            raise OSError(f"the photo isn't at {photo}; check PHOTO_PATHS")
        lightroom, immich = (Path(p) for p in photos.sidecar_paths(str(photo)))
        targets = [lightroom] + ([immich] if immich.exists() else [])
        for target in targets:
            if not _inside(target, root):
                raise OSError(f"{target.name} is a link or outside {root}; left alone")
        return targets, root

    def write(self, asset_id: str, immich_path: str, update: photos.SidecarUpdate) -> int:
        """Adds the update to the photo's sidecars; how many files changed."""
        targets, _root = self.targets(immich_path)
        recorded = {r["path"]: r for r in self.store.sidecars(self.user_id, self.trip_id, asset_id)}
        changed = 0
        for target in targets:
            existing = target.read_bytes() if target.exists() else None
            merged = photos.merge_sidecar(existing, update)
            if merged == existing:
                continue
            record = recorded.get(str(target))
            backup = record["backup"] if record else self._backup(asset_id, target, existing)
            # Lightroom may have saved to it while this one was merging: then leave it for the
            # next pass rather than write over that save. (This narrows the window; nothing on
            # a shared folder can close it.)
            if (target.read_bytes() if target.exists() else None) != existing:
                raise OSError(f"{target.name} changed while it was being updated; left for the next pass")
            _write_atomically(target, merged)
            self.store.save_sidecar(self.user_id, self.trip_id, asset_id, str(target), backup, _hash(merged))
            changed += 1
        return changed

    def _backup(self, asset_id: str, target: Path, existing: bytes | None) -> str | None:
        if existing is None:
            return None
        folder = self.settings.backups / self.trip_id / asset_id
        folder.mkdir(parents=True, exist_ok=True)
        backup = folder / f"{target.name}.{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}"
        backup.write_bytes(existing)
        return str(backup)

    def restore(self, asset_id: str) -> bool:
        """Puts the photo's sidecars back as they were. False, changing nothing, when one has
        been changed since (Lightroom saved its own metadata to it, say)."""
        records = self.store.sidecars(self.user_id, self.trip_id, asset_id)
        for record in records:
            path = Path(record["path"])
            if path.is_symlink() or not path.exists() or _hash(path.read_bytes()) != record["written_hash"]:
                return False
        for record in records:
            path = Path(record["path"])
            if record["backup"]:
                _write_atomically(path, Path(record["backup"]).read_bytes())
            else:
                path.unlink()
            self.store.forget_sidecar(self.user_id, self.trip_id, asset_id, record["path"])
        return True


async def run(
    store: Store,
    adventurelog: AdventureLog,
    immich: Immich,
    settings: PhotoSettings,
    now: datetime | None = None,
) -> None:
    """One pass over every trip with photos turned on."""
    now = now or datetime.now(UTC)
    for trip in store.photo_trips():
        error = None
        album_id = trip.album_id
        try:
            album_id = await run_trip(trip, store, adventurelog, immich, settings)
        except (AdventureLogError, ImmichError, OSError) as failure:
            error = str(failure)
            log.warning("photos for trip %s: %s", trip.trip_id, failure)
        except Exception:  # one trip's surprise mustn't stop the others
            error = "Something went wrong; the companion's log has the details."
            log.exception("photos for trip %s", trip.trip_id)
        store.photo_trip_ran(trip, now.isoformat(), error, album_id)


async def run_trip(
    setting: PhotoTrip, store: Store, adventurelog: AdventureLog, immich: Immich, settings: PhotoSettings
) -> str | None:
    """Matches the trip's new photos; returns the trip's Immich album."""
    api_key = store.api_key_for(setting.user_id)
    if api_key is None:
        raise AdventureLogError("No phone is signed in for this person, so the trip can't be read.")
    collection = await adventurelog.trip(api_key, setting.trip_id)
    trip = photos.trip_from(collection)
    if not trip.days:
        return setting.album_id
    # Immich dates photos without a zone as if their clock were UTC, so search a wide window and
    # let the matching decide.
    after = datetime.combine(trip.days[0].date, time.min, UTC) - timedelta(days=2)
    before = datetime.combine(trip.days[-1].date, time.max, UTC) + timedelta(days=2)
    known = {a.asset_id: a for a in store.photo_assets(setting.user_id, setting.trip_id)}
    writer = SidecarWriter(settings, store, setting.user_id, setting.trip_id)

    written: list[str] = []
    # Saved as done only once Immich has been told, so a failure there is retried next pass
    # (writing a sidecar again changes nothing).
    finished: list[PhotoAsset] = []
    for asset in await immich.photos_taken(after, before):
        if len(written) >= BATCH:
            break
        asset_id = str(asset.get("id"))
        previous = known.get(asset_id)
        if previous and previous.state in ("done", "undone"):
            continue
        if not photos.is_raw(asset):
            continue
        moment = photos.photo_time(asset, settings.camera_zone, setting.camera_offset_minutes)
        found = photos.match(trip, moment) if moment else None
        if found is None:
            continue
        stop = found.stop
        latitude = stop.latitude if stop and stop.kind == "location" else None
        longitude = stop.longitude if stop and stop.kind == "location" else None
        record = PhotoAsset(
            user_id=setting.user_id,
            trip_id=setting.trip_id,
            asset_id=asset_id,
            taken_at=moment.isoformat(),
            day=found.day.date.isoformat(),
            stop_id=stop.item_id if stop else None,
            stop_kind=stop.kind if stop else None,
            stop_title=stop.title if stop else None,
            image_id=None,
            state="done",
            detail=None,
        )
        try:
            writer.write(asset_id, str(asset.get("originalPath") or ""), photos.update_for(found, latitude, longitude))
            written.append(asset_id)
            finished.append(record)
        except (OSError, photos.SidecarError, UnicodeDecodeError) as error:
            store.save_photo_asset(replace(record, state="failed", detail=str(error)))

    album_id = setting.album_id
    if written:
        await immich.refresh_metadata(written)
        if not album_id or not await immich.album_exists(album_id):
            album_id = await immich.create_album(trip.name, "Photos matched to the trip by the AdventureLog companion.")
        await immich.add_to_album(album_id, written)
    for record in finished:
        store.save_photo_asset(record)
    await link_photos(setting, store, adventurelog, api_key, collection, settings.links_per_stop)
    return album_id


async def link_photos(
    setting: PhotoTrip, store: Store, adventurelog: AdventureLog, api_key: str, collection: dict, per_stop: int
) -> None:
    """A few of each place's photos on the place in AdventureLog, spread across the visit."""
    on_item = {
        str(item.get("id")): {str(i.get("immich_id")) for i in item.get("images") or [] if i.get("immich_id")}
        for item in collection.get("locations") or []
    }
    by_stop: dict[str, list[PhotoAsset]] = {}
    for asset in store.photo_assets(setting.user_id, setting.trip_id):
        if asset.state == "done" and asset.stop_kind == "location" and asset.stop_id in on_item:
            by_stop.setdefault(asset.stop_id, []).append(asset)
    for stop_id, assets in by_stop.items():
        linked = [a for a in assets if a.image_id]
        waiting = [a for a in assets if not a.image_id and a.asset_id not in on_item[stop_id]]
        for asset in _spread(waiting, per_stop - len(linked)):
            image_id = await adventurelog.link_photo(api_key, "location", stop_id, asset.asset_id)
            store.save_photo_asset(replace(asset, image_id=image_id))


def _spread(items: list, count: int) -> list:
    """`count` of the items, evenly spaced from first to last."""
    if count <= 0 or not items:
        return []
    if count >= len(items):
        return list(items)
    if count == 1:
        return [items[len(items) // 2]]
    step = (len(items) - 1) / (count - 1)
    return [items[round(i * step)] for i in range(count)]


async def undo_day(
    user_id: str,
    trip_id: str,
    day: str,
    store: Store,
    adventurelog: AdventureLog,
    immich: Immich | None,
    settings: PhotoSettings,
) -> dict:
    """Puts a day's sidecars back, unlinks its photos from AdventureLog and the album. Photos
    whose sidecar changed since are left as they are and counted.

    The sidecars are the record: a photo is undone once its files are back. What follows (the
    AdventureLog link, Immich's refresh and the album) is done again by the next undo of the
    day if it fails, so asking again finishes the job."""
    setting = store.photo_trip(user_id, trip_id)
    api_key = store.api_key_for(user_id)
    writer = SidecarWriter(settings, store, user_id, trip_id)
    restored = 0
    kept = 0
    for asset in store.photo_assets(user_id, trip_id):
        if asset.day != day or asset.state not in ("done", "failed"):
            continue
        if not writer.restore(asset.asset_id):
            kept += 1
            continue
        store.save_photo_asset(replace(asset, state="undone", detail=None))
        restored += 1
    undone = [a for a in store.photo_assets(user_id, trip_id) if a.day == day and a.state == "undone"]
    for asset in undone:
        if asset.image_id and api_key:
            try:
                await adventurelog.unlink_photo(api_key, asset.image_id)
            except AdventureLogError as error:
                log.warning("unlinking %s: %s", asset.image_id, error)
                continue  # kept, so the next undo tries again
            store.save_photo_asset(replace(asset, image_id=None))
    if undone and immich:
        ids = [a.asset_id for a in undone]
        await immich.refresh_metadata(ids)
        if setting.album_id:
            await immich.remove_from_album(setting.album_id, ids)
    return {"restored": restored, "kept": kept}


def summary(store: Store, user_id: str, trip_id: str) -> dict:
    """What the app's Photos screen shows: the trip's setting and each day's matches."""
    setting = store.photo_trip(user_id, trip_id)
    days: dict[str, dict] = {}
    for asset in store.photo_assets(user_id, trip_id):
        day = days.setdefault(asset.day, {"date": asset.day, "photos": 0, "undone": 0, "failed": 0, "stops": {}})
        if asset.state == "done":
            day["photos"] += 1
            title = asset.stop_title or ""
            day["stops"][title] = day["stops"].get(title, 0) + 1
        elif asset.state in ("undone", "failed"):
            day[asset.state] += 1
    return {
        "enabled": setting.enabled,
        "cameraOffsetMinutes": setting.camera_offset_minutes,
        "lastRun": setting.last_run,
        "lastError": setting.last_error,
        "days": [
            {
                "date": d["date"],
                "photos": d["photos"],
                "undone": d["undone"],
                "failed": d["failed"],
                # The day's own photos (no stop) are listed with an empty title.
                "stops": [{"title": t, "photos": n} for t, n in d["stops"].items()],
            }
            for d in sorted(days.values(), key=lambda d: d["date"])
        ],
    }
