# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""A pass over the sample trip's photos, against a stand-in Immich and AdventureLog and a
throwaway library folder (Stage 6)."""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from companion import photo_worker
from companion.adventurelog import AdventureLog
from companion.app import Settings, create_app
from companion.immich import Immich
from companion.photo_worker import PhotoSettings, PhotoSetupError
from companion.store import Store
from tests.test_worker import KEY, RESPONSES

TRIP = json.loads((RESPONSES / "collections__detail.json").read_text())
LOOKOUT = "9e20f3bd-847e-45fb-bb94-6921d7a64e3d"
LIGHTROOM = (Path(__file__).parent / "sidecars/lightroom.xmp").read_bytes()
USER = "user-alex"
# Where the stand-in Immich says the library is; the test maps it to a temporary folder.
IMMICH_ROOT = "/mnt/library"


def run(coro):
    return asyncio.run(coro)


def asset(asset_id: str, local: str, name: str) -> dict:
    """The camera's clock is on Denver time, the sample trip's home."""
    return {
        "id": asset_id,
        "originalFileName": name,
        "originalPath": f"{IMMICH_ROOT}/2027/03/{name}",
        "localDateTime": f"{local}.000Z",
        "fileCreatedAt": f"{local}.000Z",
        "exifInfo": {"timeZone": None},
    }


ASSETS = [
    # 16:05–16:25 on 8 Mar at the lookout (05:05–05:25 UTC).
    asset("a1", "2027-03-07T22:05:00", "DSC00001.ARW"),
    asset("a2", "2027-03-07T22:10:00", "DSC00002.ARW"),
    asset("a3", "2027-03-07T22:15:00", "DSC00003.ARW"),
    asset("a4", "2027-03-07T22:25:00", "DSC00004.ARW"),
    asset("phone", "2027-03-07T22:12:00", "IMG_0001.HEIC"),
    # On the sunset cruise (08:00 UTC).
    asset("c1", "2027-03-08T01:00:00", "DSC00005.ARW"),
    # Between the two: just the day.
    asset("d1", "2027-03-08T00:00:00", "DSC00006.ARW"),
    # Long after the trip.
    asset("late", "2027-04-20T10:00:00", "DSC00007.ARW"),
]


class FakeImmich:
    def __init__(self, assets: list[dict]):
        self.assets = assets
        self.refreshed: list[str] = []
        self.albums: dict[str, list[str]] = {}
        self.client = Immich("https://immich.example", "immich-key", transport=httpx.MockTransport(self.handle))

    def handle(self, request: httpx.Request) -> httpx.Response:
        assert request.headers["x-api-key"] == "immich-key"
        path = request.url.path
        body = json.loads(request.content) if request.content else {}
        if path == "/api/search/metadata":
            assert body["withExif"] is True
            size, page = body["size"], body["page"]
            items = self.assets[(page - 1) * size : page * size]
            more = len(self.assets) > page * size
            return httpx.Response(200, json={"assets": {"items": items, "nextPage": str(page + 1) if more else None}})
        if path == "/api/assets/jobs":
            assert body["name"] == "refresh-metadata"
            self.refreshed += body["assetIds"]
            return httpx.Response(204)
        if path == "/api/albums" and request.method == "POST":
            album_id = f"album-{len(self.albums) + 1}"
            self.albums[album_id] = []
            return httpx.Response(201, json={"id": album_id, "albumName": body["albumName"]})
        if path.startswith("/api/albums/"):
            album_id = path.split("/")[3]
            if album_id not in self.albums:
                return httpx.Response(404)
            if request.method == "PUT":
                self.albums[album_id] += body["ids"]
            elif request.method == "DELETE":
                self.albums[album_id] = [a for a in self.albums[album_id] if a not in body["ids"]]
            return httpx.Response(200, json=[])
        return httpx.Response(404)


class FakeAdventureLog:
    def __init__(self):
        self.links: dict[str, tuple[str, str, str]] = {}
        self.client = AdventureLog("https://adventurelog.example", transport=httpx.MockTransport(self.handle))

    def handle(self, request: httpx.Request) -> httpx.Response:
        if request.headers.get("X-API-Key") != KEY:
            return httpx.Response(401)
        path = request.url.path
        if path == "/auth/user-metadata/":
            return httpx.Response(200, json={"uuid": USER})
        if path == f"/api/collections/{TRIP['id']}/":
            return httpx.Response(200, json=TRIP)
        if path == "/api/images/" and request.method == "POST":
            body = json.loads(request.content)
            image_id = f"image-{len(self.links) + 1}"
            self.links[image_id] = (body["content_type"], body["object_id"], body["immich_id"])
            return httpx.Response(201, json={"id": image_id})
        if path.startswith("/api/images/") and request.method == "DELETE":
            self.links.pop(path.split("/")[3], None)
            return httpx.Response(204)
        return httpx.Response(404)


@pytest.fixture
def library(tmp_path) -> Path:
    folder = tmp_path / "library" / "2027" / "03"
    folder.mkdir(parents=True)
    for item in ASSETS:
        (folder / item["originalFileName"]).write_bytes(b"raw")
    # Lightroom has already written a sidecar, with edits, for the first photo.
    (folder / "DSC00001.xmp").write_bytes(LIGHTROOM)
    os.chmod(folder / "DSC00001.xmp", 0o640)
    return folder


def settings(tmp_path) -> PhotoSettings:
    return PhotoSettings.from_env(
        {
            "IMMICH_URL": "https://immich.example",
            "IMMICH_API_KEY": "immich-key",
            "PHOTO_PATHS": f"{IMMICH_ROOT}={tmp_path / 'library'}",
            "CAMERA_ZONE": "America/Denver",
            "PHOTO_BACKUPS": str(tmp_path / "backups"),
        }
    )


def setup(tmp_path, assets=ASSETS):
    store = Store(tmp_path / "c.sqlite")
    store.register(USER, KEY, "sandbox", None)
    store.save_photo_trip(USER, TRIP["id"], True, 0)
    return store, FakeAdventureLog(), FakeImmich(assets), settings(tmp_path)


def test_a_pass_writes_the_sidecars_and_links_a_few(tmp_path, library):
    store, adventurelog, immich, config = setup(tmp_path)
    run(photo_worker.run(store, adventurelog.client, immich.client, config))

    first = (library / "DSC00001.xmp").read_text()
    assert 'crs:Exposure2012="+0.35"' in first, "Lightroom's edits are kept"
    assert "Trips|Tasmania Road Trip 2027|2027-03-08 · D2 · Hobart → Freycinet|Wineglass Bay Lookout" in first
    assert oct(os.stat(library / "DSC00001.xmp").st_mode & 0o777) == "0o640"
    assert "Sunset cruise" in (library / "DSC00005.xmp").read_text()
    day_only = (library / "DSC00006.xmp").read_text()
    assert "2027-03-08 · D2 · Hobart → Freycinet</rdf:li>" in day_only and "Lookout" not in day_only
    assert not (library / "DSC00007.xmp").exists(), "outside the trip"
    assert not (library / "IMG_0001.xmp").exists(), "only raw photos"
    assert not list(library.glob("*.ARW.xmp")), "Immich's form is only written when it's there"

    # The one file that was there is backed up; the new ones need no backup.
    backups = list((tmp_path / "backups").rglob("*"))
    assert [b.read_bytes() for b in backups if b.is_file()] == [LIGHTROOM]

    assert sorted(immich.refreshed) == ["a1", "a2", "a3", "a4", "c1", "d1"]
    assert list(immich.albums.values()) == [immich.refreshed]
    # Three of the lookout's four photos, first, middle and last; one of the cruise's.
    lookout = sorted(i for kind, item, i in adventurelog.links.values() if item == LOOKOUT)
    assert lookout == ["a1", "a3", "a4"]
    assert len(adventurelog.links) == 4
    trip = store.photo_trip(USER, TRIP["id"])
    assert trip.last_error is None and trip.album_id == "album-1"

    # A second pass changes nothing.
    before = {p.name: p.read_bytes() for p in library.iterdir()}
    run(photo_worker.run(store, adventurelog.client, immich.client, config))
    assert {p.name: p.read_bytes() for p in library.iterdir()} == before
    assert len(immich.refreshed) == 6 and len(adventurelog.links) == 4


def test_immichs_own_sidecar_is_kept_in_step(tmp_path, library):
    (library / "DSC00002.ARW.xmp").write_bytes(LIGHTROOM)
    store, adventurelog, immich, config = setup(tmp_path, ASSETS[1:2])
    run(photo_worker.run(store, adventurelog.client, immich.client, config))
    assert "Wineglass Bay Lookout" in (library / "DSC00002.ARW.xmp").read_text()
    assert "Wineglass Bay Lookout" in (library / "DSC00002.xmp").read_text()


def test_undoing_a_day(tmp_path, library):
    store, adventurelog, immich, config = setup(tmp_path)
    run(photo_worker.run(store, adventurelog.client, immich.client, config))
    # Lightroom saves its own metadata over one photo's sidecar afterwards.
    (library / "DSC00003.xmp").write_text((library / "DSC00003.xmp").read_text() + "\n")

    result = run(
        photo_worker.undo_day(USER, TRIP["id"], "2027-03-08", store, adventurelog.client, immich.client, config)
    )
    assert result["restored"] == 5 and result["kept"] == 1
    assert (library / "DSC00001.xmp").read_bytes() == LIGHTROOM, "put back as it was"
    assert not (library / "DSC00005.xmp").exists(), "made by the companion, so removed"
    assert (library / "DSC00003.xmp").exists(), "changed since, so left alone"
    assert [link[2] for link in adventurelog.links.values()] == ["a3"], "only the kept photo stays linked"
    assert immich.albums["album-1"] == ["a3"]

    # Undone photos aren't matched again.
    run(photo_worker.run(store, adventurelog.client, immich.client, config))
    assert not (library / "DSC00005.xmp").exists()
    summary = photo_worker.summary(store, USER, TRIP["id"])
    assert summary["days"] == [{"date": "2027-03-08", "photos": 1, "undone": 5, "failed": 0, "stops": [
        {"title": "Wineglass Bay Lookout", "photos": 1}
    ]}]  # fmt: skip


def test_a_photo_outside_the_library_or_behind_a_link_is_left_alone(tmp_path, library):
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    (outside / "target.xmp").write_bytes(LIGHTROOM)
    (library / "DSC00002.xmp").symlink_to(outside / "target.xmp")
    climbing = asset("x1", "2027-03-07T22:10:00", "DSC00002.ARW")
    climbing["id"], climbing["originalPath"] = "x2", f"{IMMICH_ROOT}/../etc/DSC00009.ARW"
    stranger = asset("x3", "2027-03-07T22:10:00", "DSC00002.ARW")
    stranger["originalPath"] = "/somewhere/else/DSC00002.ARW"
    store, adventurelog, immich, config = setup(tmp_path, [ASSETS[1], climbing, stranger])

    run(photo_worker.run(store, adventurelog.client, immich.client, config))
    assert (outside / "target.xmp").read_bytes() == LIGHTROOM
    failed = {a.asset_id: a.detail for a in store.photo_assets(USER, TRIP["id"]) if a.state == "failed"}
    assert set(failed) == {"a2", "x2", "x3"}
    assert "link" in failed["a2"]
    assert immich.refreshed == [] and adventurelog.links == {}


def test_a_broken_sidecar_is_not_overwritten(tmp_path, library):
    (library / "DSC00002.xmp").write_text("<x:xmpmeta xmlns:x='adobe:ns:meta/'><half")
    store, adventurelog, immich, config = setup(tmp_path, ASSETS[1:2])
    run(photo_worker.run(store, adventurelog.client, immich.client, config))
    assert (library / "DSC00002.xmp").read_text().endswith("<half")
    assert store.photo_assets(USER, TRIP["id"])[0].state == "failed"


def test_a_slow_camera_clock(tmp_path, library):
    # A camera 40 minutes slow put the lookout photos 40 minutes early: before arriving at 05:00.
    early = [asset("e1", "2027-03-07T21:25:00", "DSC00001.ARW")]
    store, adventurelog, immich, config = setup(tmp_path, early)
    store.save_photo_trip(USER, TRIP["id"], True, 40)
    run(photo_worker.run(store, adventurelog.client, immich.client, config))
    assert "Wineglass Bay Lookout" in (library / "DSC00001.xmp").read_text()


def test_settings():
    assert PhotoSettings.from_env({}) is None
    with pytest.raises(PhotoSetupError, match="PHOTO_PATHS, CAMERA_ZONE"):
        PhotoSettings.from_env({"IMMICH_URL": "https://immich.example", "IMMICH_API_KEY": "k"})
    base = {"IMMICH_URL": "u", "IMMICH_API_KEY": "k", "PHOTO_PATHS": "/a=/b"}
    with pytest.raises(PhotoSetupError, match="CAMERA_ZONE"):
        PhotoSettings.from_env({**base, "CAMERA_ZONE": "Mars/Olympus"})
    with pytest.raises(PhotoSetupError, match="absolute"):
        PhotoSettings.from_env({**base, "CAMERA_ZONE": "UTC", "PHOTO_PATHS": "/a=b"})
    config = PhotoSettings.from_env({**base, "CAMERA_ZONE": "UTC", "PHOTO_PATHS": "/a=/b;/a/c=/d"})
    assert config.local("/a/c/x.ARW") == (Path("/d/x.ARW"), Path("/d")), "the longest prefix wins"
    assert config.local("/a/x.ARW") == (Path("/b/x.ARW"), Path("/b"))
    assert config.local("/ab/x.ARW") is None
    assert config.local("/a/../x.ARW") is None


def test_the_api(tmp_path, library):
    env = {
        "ADVENTURELOG_URL": "https://adventurelog.example",
        "COMPANION_DB": str(tmp_path / "api.sqlite"),
        "IMMICH_URL": "https://immich.example",
        "IMMICH_API_KEY": "immich-key",
        "PHOTO_PATHS": f"{IMMICH_ROOT}={tmp_path / 'library'}",
        "CAMERA_ZONE": "America/Denver",
        "PHOTO_BACKUPS": str(tmp_path / "backups"),
    }
    adventurelog, immich = FakeAdventureLog(), FakeImmich(ASSETS)
    app = create_app(Settings(env), adventurelog=adventurelog.client, immich=immich.client, run_worker=False)
    headers = {"X-API-Key": KEY}
    with TestClient(app) as api:
        assert api.get("/healthz").json()["photos"] is True
        path = f"/v1/trips/{TRIP['id']}/photos"
        assert api.get(path, headers=headers).json()["enabled"] is False
        assert api.get("/v1/trips/not-a-trip/photos", headers=headers).status_code == 404
        assert api.get(f"/v1/trips/{'0' * 8}-0000-0000-0000-{'0' * 12}/photos", headers=headers).status_code == 404
        assert api.put(path, json={"enabled": True, "cameraOffsetMinutes": 5000}, headers=headers).status_code == 422
        turned_on = api.put(path, json={"enabled": True, "cameraOffsetMinutes": 2}, headers=headers).json()
        assert turned_on["enabled"] is True and turned_on["cameraOffsetMinutes"] == 2

        store = api.app.state.store
        store.register(USER, KEY, "sandbox", None)
        run(photo_worker.run(store, adventurelog.client, immich.client, app.state.photo_settings))
        days = api.get(path, headers=headers).json()["days"]
        assert days[0]["date"] == "2027-03-08" and days[0]["photos"] == 6

        undone = api.post(f"{path}/undo", json={"date": "2027-03-08"}, headers=headers).json()
        assert undone["restored"] == 6 and undone["days"][0]["undone"] == 6
        assert api.get(path, headers={"X-API-Key": "wrong"}).status_code == 401


def test_without_photos_set_up(tmp_path):
    env = {"ADVENTURELOG_URL": "https://adventurelog.example", "COMPANION_DB": str(tmp_path / "c.sqlite")}
    app = create_app(Settings(env), adventurelog=FakeAdventureLog().client, run_worker=False)
    with TestClient(app) as api:
        reply = api.get(f"/v1/trips/{TRIP['id']}/photos", headers={"X-API-Key": KEY})
        assert reply.status_code == 503
