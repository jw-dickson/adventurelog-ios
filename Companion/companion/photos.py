# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Photos to the trip (Stage 6): which stop each photo was taken at, and the keywords and place it
gets in its XMP sidecar.

Everything here is pure: the trip's JSON and a photo's time in, a match and a sidecar out. The
worker (`photo_worker.py`) finds the photos in Immich and writes the files.

A raw photo's sidecar is shared by Lightroom Classic (which reads `dc:subject` and
`lr:hierarchicalSubject` as keywords) and Immich (which reads `digiKam:TagsList`, then
`lr:HierarchicalSubject`), so the keywords go into all three. Only fields this module adds are
touched: Lightroom's develop settings and anything else already in the file stay as they were.
"""

from __future__ import annotations

import contextlib
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from io import BytesIO
from zoneinfo import ZoneInfo

RAW_EXTENSIONS = {
    "3fr", "arw", "cr2", "cr3", "dng", "erf", "iiq", "kdc", "mrw", "nef", "nrw",
    "orf", "pef", "raf", "rw2", "rwl", "sr2", "srf", "srw", "x3f",
}  # fmt: skip

# A photo up to this long before a stop or after it still belongs to it (arriving, leaving).
MARGIN = timedelta(minutes=15)
# How much of a stay's check-in and check-out ends claims photos (see `Stop.holds`).
STAY_ENDS = timedelta(hours=2)
# Longer than this is a hire or a pass, not something a photo was taken at (the car hire).
LONGEST_STOP = timedelta(hours=24)
KEYWORD_ROOT = "Trips"

# Kinds in the order a photo prefers them when windows overlap: a place inside a day tour, a
# drive rather than the hotel it set out from.
PRIORITY = {"location": 0, "transportation": 1, "lodging": 2}


def parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        moment = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment.astimezone(UTC) if moment.tzinfo else moment.replace(tzinfo=UTC)


def _name(value) -> str | None:
    """AdventureLog sends some places as names and some as objects with a name."""
    if isinstance(value, dict):
        value = value.get("name") or value.get("display_name")
    text = str(value).strip() if value is not None else ""
    return text or None


@dataclass(frozen=True)
class Stop:
    """One timed item of a trip day, as a window a photo can fall in."""

    item_id: str
    kind: str  # location, transportation, lodging
    title: str
    day: date
    day_label: str
    start: datetime
    end: datetime
    category: str | None = None
    city: str | None = None
    region: str | None = None
    country: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    zone: str | None = None  # the IANA zone the stop's times are written in

    def holds(self, moment: datetime) -> bool:
        if not self.start - MARGIN <= moment <= self.end + MARGIN:
            return False
        if self.kind != "lodging":
            return True
        # A stay spans the whole day out, so only its ends count: arriving and settling in, and
        # the morning before leaving. Photos in between belong to the day, not the hotel.
        return moment <= self.start + STAY_ENDS or moment >= self.end - STAY_ENDS


@dataclass(frozen=True)
class TripDay:
    date: date
    label: str


@dataclass(frozen=True)
class Trip:
    id: str
    name: str
    days: list[TripDay]
    stops: list[Stop]
    zone: str | None = None

    def day_for(self, moment: datetime) -> TripDay | None:
        """The trip day a moment falls on, in the zone of the stop nearest in time."""
        if not self.days:
            return None
        zone = _zone_info(self.zone_at(moment))
        local = moment.astimezone(zone).date() if zone else moment.date()
        return next((d for d in self.days if d.date == local), None)

    def zone_at(self, moment: datetime) -> str | None:
        timed = [s for s in self.stops if s.kind != "lodging"] or self.stops
        if not timed:
            return self.zone
        nearest = min(timed, key=lambda s: min(abs(s.start - moment), abs(s.end - moment)))
        return nearest.zone or self.zone


def day_label(day: date, name: str | None) -> str:
    """'2027-03-08 · D2 · Hobart → Freycinet': sorts by date in a keyword list."""
    return f"{day.isoformat()} · {name}" if name else day.isoformat()


def trip_from(collection: dict) -> Trip:
    """The trip's timed stops from AdventureLog's collection JSON (its itinerary rows)."""
    items: dict[tuple[str, str], dict] = {}
    for kind, key in (("location", "locations"), ("transportation", "transportations"), ("lodging", "lodging")):
        for item in collection.get(key) or []:
            items[(kind, str(item.get("id")))] = item
    names = {str(d.get("date")): _name(d.get("name")) for d in collection.get("itinerary_days") or []}

    days: dict[date, TripDay] = {}
    first, last = _date(collection.get("start_date")), _date(collection.get("end_date"))
    if first and last:
        current = first
        while current <= last:
            days[current] = TripDay(current, day_label(current, names.get(current.isoformat())))
            current += timedelta(days=1)

    stops: list[Stop] = []
    for row in collection.get("itinerary") or []:
        kind = (row.get("item") or {}).get("type") or row.get("object_name")
        item = items.get((str(kind), str((row.get("item") or {}).get("id") or row.get("object_id"))))
        row_day = _date(row.get("date"))
        if item is None or row_day is None:
            continue
        start, end = _window(kind, item, row)
        if start is None or (kind != "lodging" and end is not None and end - start > LONGEST_STOP):
            continue
        day = days.get(row_day) or TripDay(row_day, day_label(row_day, names.get(row_day.isoformat())))
        days.setdefault(row_day, day)
        latitude, longitude = item.get("latitude"), item.get("longitude")
        if kind == "transportation":
            latitude, longitude = item.get("origin_latitude"), item.get("origin_longitude")
        category = item.get("category")
        stop = Stop(
            item_id=str(item.get("id")),
            kind=str(kind),
            title=_name(item.get("name")) or "Untitled",
            day=row_day,
            day_label=day.label,
            start=start,
            end=end or start,
            category=_name(category) if not isinstance(category, dict) else _name(category.get("display_name")),
            city=_name(item.get("city")),
            region=_name(item.get("region")),
            country=_name(item.get("country")),
            latitude=_float(latitude),
            longitude=_float(longitude),
            zone=_zone_for(kind, item),
        )
        stops.append(stop)
    stops.sort(key=lambda s: (s.start, PRIORITY.get(s.kind, 9)))
    zones = [s.zone for s in stops if s.zone]
    return Trip(
        id=str(collection.get("id")),
        name=_name(collection.get("name")) or "Trip",
        days=sorted(days.values(), key=lambda d: d.date),
        stops=stops,
        zone=zones[0] if zones else None,
    )


def _date(value) -> date | None:
    try:
        return date.fromisoformat(str(value)[:10]) if value else None
    except ValueError:
        return None


def _float(value) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _window(kind, item: dict, row: dict) -> tuple[datetime | None, datetime | None]:
    start, end = parse_time(row.get("start_datetime")), parse_time(row.get("end_datetime"))
    if start:
        return start, end
    if kind == "transportation":
        return parse_time(item.get("date")), parse_time(item.get("end_date"))
    if kind == "lodging":
        return parse_time(item.get("check_in")), parse_time(item.get("check_out"))
    visits = sorted((v for v in item.get("visits") or [] if v.get("start_date")), key=lambda v: v["start_date"])
    for visit in visits:
        visit_start = parse_time(visit.get("start_date"))
        if visit_start is None:
            continue
        # The visit on the row's day, in the visit's own zone (a morning in Hobart is the day
        # before in UTC).
        zone = _zone_info(visit.get("timezone"))
        local = visit_start.astimezone(zone).date() if zone else visit_start.date()
        if local.isoformat() == str(row.get("date")):
            return visit_start, parse_time(visit.get("end_date"))
    return None, None


def _zone_info(name: str | None) -> ZoneInfo | None:
    try:
        return ZoneInfo(name) if name else None
    except (ValueError, KeyError):
        return None


def _zone_for(kind, item: dict) -> str | None:
    if kind == "transportation":
        return item.get("start_timezone") or item.get("end_timezone")
    if kind == "lodging":
        return item.get("timezone")
    for visit in item.get("visits") or []:
        if visit.get("timezone"):
            return visit["timezone"]
    return None


# Photo time


def photo_time(asset: dict, camera_zone: str, offset_minutes: int = 0) -> datetime | None:
    """When an Immich photo was really taken.

    With a zone in its EXIF (OffsetTimeOriginal), Immich's `dateTimeOriginal` is right. Without
    one, Immich has only the camera's clock, which for this workflow is set to home time:
    `localDateTime` is that clock reading, read here in `camera_zone`. `offset_minutes` corrects a
    camera clock that drifted (positive when the camera was behind).
    """
    exif = asset.get("exifInfo") or {}
    if exif.get("timeZone"):
        moment = parse_time(exif.get("dateTimeOriginal") or asset.get("fileCreatedAt"))
    else:
        wall = str(asset.get("localDateTime") or exif.get("dateTimeOriginal") or "")
        try:
            naive = datetime.fromisoformat(wall.replace("Z", "+00:00")).replace(tzinfo=None)
        except ValueError:
            return None
        moment = naive.replace(tzinfo=ZoneInfo(camera_zone)).astimezone(UTC)
    if moment is None:
        return None
    return moment + timedelta(minutes=offset_minutes)


def is_raw(asset: dict) -> bool:
    name = str(asset.get("originalFileName") or asset.get("originalPath") or "")
    return name.rsplit(".", 1)[-1].lower() in RAW_EXTENSIONS if "." in name else False


# Matching


@dataclass(frozen=True)
class Match:
    day: TripDay
    stop: Stop | None
    keywords: list[str] = field(default_factory=list)  # flat (dc:subject)
    hierarchy: list[str] = field(default_factory=list)  # "Trips|Trip|Day|Place" (lr:hierarchicalSubject)


def match(trip: Trip, moment: datetime) -> Match | None:
    """The stop a photo taken at `moment` belongs to, or just its day; nil outside the trip."""
    day = trip.day_for(moment)
    candidates = [s for s in trip.stops if s.holds(moment)]
    if day is None and not candidates:
        return None
    # A stay only when nothing else holds the photo; then inside a window beats the margin
    # around it, a place beats a journey, and a short window beats a long one.
    candidates.sort(
        key=lambda s: (
            s.kind == "lodging",
            not (s.start <= moment <= s.end),
            PRIORITY.get(s.kind, 9),
            s.end - s.start,
        )
    )
    stop = candidates[0] if candidates else None
    if day is None and stop is not None:
        day = next((d for d in trip.days if d.date == stop.day), TripDay(stop.day, stop.day_label))
    if day is None:
        return None
    return Match(day=day, stop=stop, keywords=flat_keywords(trip, day, stop), hierarchy=hierarchy(trip, day, stop))


def _clean(part: str) -> str:
    """Keyword levels can't hold Lightroom's '|' or digiKam's '/'."""
    return re.sub(r"\s*[|/]\s*", " - ", part).strip()


def hierarchy(trip: Trip, day: TripDay, stop: Stop | None) -> list[str]:
    path = [KEYWORD_ROOT, _clean(trip.name), _clean(day.label)]
    if stop is not None:
        path.append(_clean(stop.title))
    return ["|".join(path)]


def flat_keywords(trip: Trip, day: TripDay, stop: Stop | None) -> list[str]:
    words = [KEYWORD_ROOT, trip.name, day.label]
    if stop is not None:
        words += [stop.title, stop.category, stop.city, stop.region, stop.country]
    seen: list[str] = []
    for word in words:
        if word and _clean(word) not in seen:
            seen.append(_clean(word))
    return seen


# XMP sidecars

NS = {
    "x": "adobe:ns:meta/",
    "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "dc": "http://purl.org/dc/elements/1.1/",
    "lr": "http://ns.adobe.com/lightroom/1.0/",
    "digiKam": "http://www.digikam.org/ns/1.0/",
    "exif": "http://ns.adobe.com/exif/1.0/",
    "photoshop": "http://ns.adobe.com/photoshop/1.0/",
    "Iptc4xmpCore": "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/",
}
EMPTY_SIDECAR = (
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
    '<rdf:Description rdf:about=""/></rdf:RDF></x:xmpmeta>'
)


class SidecarError(Exception):
    """The file isn't XMP this module can safely add to."""


def _q(prefix: str, name: str) -> str:
    return f"{{{NS[prefix]}}}{name}"


def _register(xml: bytes) -> None:
    """Keep the file's own prefixes (crs:, xmp:, …) when it's written back."""
    for _event, (prefix, uri) in ET.iterparse(BytesIO(xml), events=("start-ns",)):
        if prefix:
            with contextlib.suppress(ValueError):  # ElementTree reserves "ns0"-style prefixes
                ET.register_namespace(prefix, uri)
    for prefix, uri in NS.items():
        ET.register_namespace(prefix, uri)


def gps_value(value: float, positive: str, negative: str) -> str:
    """XMP's GPS form: degrees, decimal minutes and a direction ('42,9.000000S')."""
    direction = positive if value >= 0 else negative
    value = abs(value)
    degrees = int(value)
    minutes = (value - degrees) * 60
    return f"{degrees},{minutes:.6f}{direction}"


@dataclass(frozen=True)
class SidecarUpdate:
    keywords: list[str]
    hierarchy: list[str]
    city: str | None = None
    region: str | None = None
    country: str | None = None
    place: str | None = None
    latitude: float | None = None
    longitude: float | None = None


def update_for(match: Match, latitude: float | None = None, longitude: float | None = None) -> SidecarUpdate:
    stop = match.stop
    return SidecarUpdate(
        keywords=match.keywords,
        hierarchy=match.hierarchy,
        city=stop.city if stop else None,
        region=stop.region if stop else None,
        country=stop.country if stop else None,
        # Lightroom's Sublocation: the place's own name.
        place=stop.title if stop and stop.kind == "location" else None,
        latitude=latitude,
        longitude=longitude,
    )


def merge_sidecar(existing: bytes | None, update: SidecarUpdate) -> bytes:
    """The sidecar with the trip's keywords and place added; everything already there is kept.

    Keywords are added to what's there. Place fields and GPS are only filled in where the file
    has none: a photo the camera geotagged keeps its own position. Running it twice changes
    nothing the second time.
    """
    source = existing if existing and existing.strip() else EMPTY_SIDECAR.encode()
    # An `<?xpacket?>` wrapper (and anything else outside the root) is kept as it was.
    text = source.decode("utf-8", errors="strict")
    head, body, tail = _split_root(text)
    try:
        _register(body.encode())
        root = ET.fromstring(body)
    except ET.ParseError as error:
        raise SidecarError(f"not XML: {error}") from error
    if root.tag != _q("x", "xmpmeta") and root.tag != _q("rdf", "RDF"):
        raise SidecarError(f"not XMP: the root is {root.tag}")
    rdf = root if root.tag == _q("rdf", "RDF") else root.find(_q("rdf", "RDF"))
    if rdf is None:
        raise SidecarError("no rdf:RDF in the sidecar")
    descriptions = rdf.findall(_q("rdf", "Description"))
    if not descriptions:
        descriptions = [ET.SubElement(rdf, _q("rdf", "Description"), {_q("rdf", "about"): ""})]

    _add_to_array(descriptions, _q("dc", "subject"), "Bag", update.keywords)
    _add_to_array(descriptions, _q("lr", "hierarchicalSubject"), "Bag", update.hierarchy)
    _add_to_array(descriptions, _q("digiKam", "TagsList"), "Seq", [h.replace("|", "/") for h in update.hierarchy])
    _fill(descriptions, _q("photoshop", "City"), update.city)
    _fill(descriptions, _q("photoshop", "State"), update.region)
    _fill(descriptions, _q("photoshop", "Country"), update.country)
    _fill(descriptions, _q("Iptc4xmpCore", "Location"), update.place)
    located = _has(descriptions, _q("exif", "GPSLatitude")) or _has(descriptions, _q("exif", "GPSLongitude"))
    if update.latitude is not None and update.longitude is not None and not located:
        _fill(descriptions, _q("exif", "GPSLatitude"), gps_value(update.latitude, "N", "S"))
        _fill(descriptions, _q("exif", "GPSLongitude"), gps_value(update.longitude, "E", "W"))

    out = BytesIO()
    ET.ElementTree(root).write(out, encoding="utf-8", xml_declaration=False)
    return (head + out.getvalue().decode("utf-8") + tail).encode("utf-8")


def _split_root(text: str) -> tuple[str, str, str]:
    """What comes before the root element (an xpacket, a comment), the root, and what follows."""
    opening = re.search(r"<(?![?!])", text)
    if opening is None:
        raise SidecarError("no XML element in the sidecar")
    last = text.rfind("</")
    root_end = text.index(">", last) + 1 if last > opening.start() else text.rfind(">") + 1
    return text[: opening.start()], text[opening.start() : root_end], text[root_end:]


def _has(descriptions: list[ET.Element], tag: str) -> bool:
    """Set in any of the file's descriptions, as an attribute or an element."""
    return any(tag in d.attrib or d.find(tag) is not None for d in descriptions)


def _fill(descriptions: list[ET.Element], tag: str, value: str | None) -> None:
    if value and not _has(descriptions, tag):
        ET.SubElement(descriptions[0], tag).text = value


def _add_to_array(descriptions: list[ET.Element], tag: str, kind: str, values: list[str]) -> None:
    if not values:
        return
    holder = next((h for d in descriptions if (h := d.find(tag)) is not None), None)
    if holder is None:
        holder = ET.SubElement(descriptions[0], tag)
    array = next((child for child in holder if child.tag.startswith(f"{{{NS['rdf']}}}")), None)
    if array is None:
        array = ET.SubElement(holder, _q("rdf", kind))
    present = {(li.text or "").strip() for li in array.findall(_q("rdf", "li"))}
    for value in values:
        if value not in present:
            ET.SubElement(array, _q("rdf", "li")).text = value
            present.add(value)


def sidecar_paths(photo_path: str) -> list[str]:
    """Where a photo's sidecars are: Lightroom's `IMG.xmp`, and `IMG.ARW.xmp` if Immich made one."""
    stem = photo_path.rsplit(".", 1)[0] if "." in photo_path.rsplit("/", 1)[-1] else photo_path
    return [f"{stem}.xmp", f"{photo_path}.xmp"]
