# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Matching photos to the sample trip's stops, and the sidecars they get (Stage 6)."""

from __future__ import annotations

import json
import xml.etree.ElementTree as ET
from datetime import UTC, datetime
from pathlib import Path

import pytest

from companion import photos

ROOT = Path(__file__).resolve().parents[2]
TRIP = json.loads((ROOT / "Fixtures/adventurelog-v0.13.0/responses/collections__detail.json").read_text())
LIGHTROOM = (Path(__file__).parent / "sidecars/lightroom.xmp").read_bytes()
# The sample trip sets out from Denver, so that's the camera's home clock in these tests.
HOME = "America/Denver"


def at(text: str) -> datetime:
    return datetime.fromisoformat(text).astimezone(UTC)


def asset(local: str, name: str = "DSC01234.ARW", zone: str | None = None, original: str | None = None) -> dict:
    """An Immich asset as /search/metadata returns it: `localDateTime` is the camera's clock."""
    return {
        "id": "asset-1",
        "originalFileName": name,
        "originalPath": f"/library/2027/{name}",
        "localDateTime": f"{local}.000Z",
        "fileCreatedAt": f"{local}.000Z",
        "exifInfo": {"timeZone": zone, "dateTimeOriginal": original},
    }


@pytest.fixture(scope="module")
def trip() -> photos.Trip:
    return photos.trip_from(TRIP)


def test_the_trip_has_its_timed_stops_and_every_day(trip):
    titles = [s.title for s in trip.stops]
    assert "Wineglass Bay Lookout" in titles and "Example Air EX 7 LAX → SYD" in titles
    assert "Car hire (Hobart → Hobart)" not in titles, "a fortnight's hire isn't a place a photo was taken"
    assert "Dove Lake Circuit" not in titles, "not on the itinerary"
    assert trip.days[0].label == "2027-03-05 · D0 · Travel day (DEN → LAX → SYD)"
    assert trip.days[-1].label == "2027-03-23"
    assert len(trip.days) == 19
    lookout = next(s for s in trip.stops if s.title == "Wineglass Bay Lookout")
    assert lookout.zone == "Australia/Hobart"
    assert lookout.category == "Viewpoint"
    assert lookout.day.isoformat() == "2027-03-08"


def test_a_home_clock_photo_is_read_in_the_home_zone():
    # 22:15 on 7 Mar in Denver (MST, UTC−7) is 05:15 UTC on 8 Mar: 16:15 at the lookout.
    moment = photos.photo_time(asset("2027-03-07T22:15:00"), HOME)
    assert moment == at("2027-03-08T05:15:00+00:00")
    # A camera running 3 minutes slow.
    assert photos.photo_time(asset("2027-03-07T22:15:00"), HOME, offset_minutes=3) == at("2027-03-08T05:18:00+00:00")


def test_a_photo_with_its_own_zone_uses_it():
    # OffsetTimeOriginal was set, so Immich's dateTimeOriginal is already the real moment.
    moment = photos.photo_time(asset("2027-03-08T16:15:00", zone="UTC+11", original="2027-03-08T05:15:00.000Z"), HOME)
    assert moment == at("2027-03-08T05:15:00+00:00")


def test_raw_files_only():
    assert photos.is_raw({"originalFileName": "DSC01234.ARW"})
    assert photos.is_raw({"originalFileName": "_A7R0001.dng"})
    assert not photos.is_raw({"originalFileName": "IMG_0001.HEIC"})
    assert not photos.is_raw({"originalFileName": "README"})


def test_a_photo_at_the_lookout(trip):
    found = photos.match(trip, at("2027-03-08T05:15:00+00:00"))
    assert found and found.stop and found.stop.title == "Wineglass Bay Lookout"
    assert found.hierarchy == [
        "Trips|Tasmania Road Trip 2027|2027-03-08 · D2 · Hobart → Freycinet|Wineglass Bay Lookout"
    ]
    assert found.keywords == [
        "Trips",
        "Tasmania Road Trip 2027",
        "2027-03-08 · D2 · Hobart → Freycinet",
        "Wineglass Bay Lookout",
        "Viewpoint",
    ]


def test_a_few_minutes_either_side_still_counts(trip):
    found = photos.match(trip, at("2027-03-08T05:40:00+00:00"))  # ten minutes after leaving
    assert found and found.stop and found.stop.title == "Wineglass Bay Lookout"


def test_a_place_on_a_drive_day_beats_the_stay(trip):
    # 15:05 local on 8 Mar: an hour after checking in at the holiday park, at the lookout.
    found = photos.match(trip, at("2027-03-08T05:05:00+00:00"))
    assert found and found.stop and found.stop.kind == "location"


def test_arriving_at_the_stay(trip):
    found = photos.match(trip, at("2027-03-08T04:30:00+00:00"))
    assert found and found.stop and found.stop.title == "Bay Holiday Park"


def test_between_stops_is_just_the_day(trip):
    # 18:30 local on 8 Mar: after the lookout, before the cruise, mid-afternoon at the stay.
    found = photos.match(trip, at("2027-03-08T07:00:00+00:00"))
    assert found and found.stop is None
    assert found.day.label == "2027-03-08 · D2 · Hobart → Freycinet"
    assert found.hierarchy == ["Trips|Tasmania Road Trip 2027|2027-03-08 · D2 · Hobart → Freycinet"]


def test_on_the_plane(trip):
    found = photos.match(trip, at("2027-03-06T10:00:00+00:00"))
    assert found and found.stop and found.stop.title == "Example Air EX 7 LAX → SYD"


def test_the_day_is_the_local_one(trip):
    # 09:30 on 7 Mar in Hobart is 22:30 on 6 Mar in UTC.
    found = photos.match(trip, at("2027-03-06T22:30:00+00:00"))
    assert found and found.day.date.isoformat() == "2027-03-07"


def test_outside_the_trip(trip):
    assert photos.match(trip, at("2027-04-20T05:00:00+00:00")) is None


def test_keyword_levels_never_hold_separators():
    trip = photos.Trip("t", "Coast / hills | 2027", [photos.TripDay(datetime(2027, 3, 8).date(), "D2")], [])
    found = photos.match(trip, at("2027-03-08T05:00:00+00:00"))
    assert found and found.hierarchy == ["Trips|Coast - hills - 2027|D2"]


# Sidecars


def parse(xml: bytes) -> ET.Element:
    return ET.fromstring(xml[xml.index(b"<x:xmpmeta") :])


def values(root: ET.Element, prefix: str, name: str) -> list[str]:
    holder = root.find(f".//{{{photos.NS[prefix]}}}{name}")
    return [li.text for li in holder.iter(f"{{{photos.NS['rdf']}}}li")] if holder is not None else []


def lookout_update(trip) -> photos.SidecarUpdate:
    found = photos.match(trip, at("2027-03-08T05:15:00+00:00"))
    return photos.update_for(found, latitude=-42.15, longitude=148.30)


def test_a_lightroom_sidecar_keeps_its_edits(trip):
    merged = photos.merge_sidecar(LIGHTROOM, lookout_update(trip))
    root = parse(merged)
    description = root.find(f".//{{{photos.NS['rdf']}}}Description")
    crs = "http://ns.adobe.com/camera-raw-settings/1.0/"
    assert description.get(f"{{{crs}}}Exposure2012") == "+0.35"
    assert description.get(f"{{{crs}}}Shadows2012") == "+42"
    assert description.get("{http://ns.adobe.com/xap/1.0/}Rating") == "3"
    assert values(root, "rdf", "Seq") == ["0, 0", "255, 255"], "the tone curve is untouched"
    assert b"crs:Exposure2012" in merged, "Lightroom's own prefixes are kept"
    # The keyword already there stays, and the trip's are added.
    assert values(root, "dc", "subject")[0] == "coast"
    assert "Wineglass Bay Lookout" in values(root, "dc", "subject")
    assert values(root, "lr", "hierarchicalSubject") == [
        "Trips|Tasmania Road Trip 2027|2027-03-08 · D2 · Hobart → Freycinet|Wineglass Bay Lookout"
    ]
    assert values(root, "digiKam", "TagsList") == [
        "Trips/Tasmania Road Trip 2027/2027-03-08 · D2 · Hobart → Freycinet/Wineglass Bay Lookout"
    ]
    assert root.find(f".//{{{photos.NS['Iptc4xmpCore']}}}Location").text == "Wineglass Bay Lookout"
    assert root.find(f".//{{{photos.NS['exif']}}}GPSLatitude").text == "42,9.000000S"


def test_merging_twice_changes_nothing(trip):
    once = photos.merge_sidecar(LIGHTROOM, lookout_update(trip))
    assert photos.merge_sidecar(once, lookout_update(trip)) == once


def test_a_geotagged_photo_keeps_its_position(trip):
    tagged = LIGHTROOM.replace(
        b'xmp:Rating="3"', b'xmp:Rating="3" exif:GPSLatitude="10,0.0N" exif:GPSLongitude="20,0.0E"'
    )
    tagged = tagged.replace(b"xmlns:xmp=", b'xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:xmp=')
    root = parse(photos.merge_sidecar(tagged, lookout_update(trip)))
    description = root.find(f".//{{{photos.NS['rdf']}}}Description")
    assert description.get(f"{{{photos.NS['exif']}}}GPSLatitude") == "10,0.0N"
    assert root.find(f".//{{{photos.NS['exif']}}}GPSLatitude") is None


def test_a_new_sidecar(trip):
    root = parse(photos.merge_sidecar(None, lookout_update(trip)))
    assert "Tasmania Road Trip 2027" in values(root, "dc", "subject")


def test_an_xpacket_wrapper_is_kept(trip):
    wrapped = b'<?xpacket begin="\xef\xbb\xbf" id="W5M0MpCehiHzreSzNTczkc9d"?>\n' + LIGHTROOM + b'\n<?xpacket end="w"?>'
    merged = photos.merge_sidecar(wrapped, lookout_update(trip))
    assert merged.startswith(b"<?xpacket begin=")
    assert merged.rstrip().endswith(b'<?xpacket end="w"?>')


def test_not_a_sidecar():
    with pytest.raises(photos.SidecarError):
        photos.merge_sidecar(b"<html><body/></html>", photos.SidecarUpdate(["a"], ["a"]))
    with pytest.raises(photos.SidecarError):
        photos.merge_sidecar(b"<x:xmpmeta", photos.SidecarUpdate(["a"], ["a"]))


def test_where_the_sidecars_are():
    assert photos.sidecar_paths("/photos/2027/DSC01234.ARW") == [
        "/photos/2027/DSC01234.xmp",
        "/photos/2027/DSC01234.ARW.xmp",
    ]
