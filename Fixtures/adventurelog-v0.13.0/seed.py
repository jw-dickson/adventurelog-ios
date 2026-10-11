#!/usr/bin/env python3
"""
Seed an AdventureLog instance with the synthetic "Tasmania road trip" fixture trip,
using ONLY the public REST API (same write paths a native client would use).

Usage:
    BASE_URL=http://127.0.0.1:8000 API_KEY=al_... python3 seed.py

Optional env:
    GUEST_API_KEY   API key of a second user. If set, the collection is shared
                    with that user (invite via owner key, accept via GUEST key).
    GUEST_USERNAME  username of that second user (default: guest). Must have
                    public_profile=true or the share endpoint returns 404.
    FIXTURES_DIR    where request/response pairs are written (default: dir of
                    this script). Writes requests/*.json, responses/*.json and
                    seed_state.json (ids of everything created).

Stdlib only (python3.9+). Every POST/PATCH body is saved to
requests/<resource>__<action>__<slug>.json and the server's reply to
responses/<resource>__<action>_response__<slug>.json.

Datetime convention used for writes (mirrors frontend/src/lib/dateUtils.ts
toUTCDatetime): the wall-clock time in the event's IANA zone is converted to a
UTC ISO-8601 string with a trailing "Z", and the IANA zone name is sent
separately in `timezone` / `start_timezone` / `end_timezone`.
"""
import json
import os
import struct
import sys
import uuid
import zlib
import urllib.request
import urllib.error
from datetime import datetime
from zoneinfo import ZoneInfo

BASE_URL = os.environ.get("BASE_URL", "http://127.0.0.1:8000").rstrip("/")
API_KEY = os.environ.get("API_KEY")
GUEST_API_KEY = os.environ.get("GUEST_API_KEY")
GUEST_USERNAME = os.environ.get("GUEST_USERNAME", "guest")
OUT = os.environ.get("FIXTURES_DIR", os.path.dirname(os.path.abspath(__file__)))

if not API_KEY:
    sys.exit("API_KEY env var is required")

os.makedirs(os.path.join(OUT, "requests"), exist_ok=True)
os.makedirs(os.path.join(OUT, "responses"), exist_ok=True)

HBA = "Australia/Hobart"
SYD = "Australia/Sydney"
LA = "America/Los_Angeles"
DEN = "America/Denver"


def utc(local: str, tz: str) -> str:
    """'2027-03-07T11:00' in Australia/Hobart -> '2027-03-07T00:00:00Z'."""
    dt = datetime.fromisoformat(local).replace(tzinfo=ZoneInfo(tz))
    return dt.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%SZ")


def _dump(path, obj):
    """Overwrite path with indented JSON text; propagate file and serialization errors."""
    with open(path, "w") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")


def call(method, path, body=None, key=None, raw_body=None, content_type="application/json",
         expect=(200, 201, 204)):
    """Send a request and return (status, body), with body decoded as JSON, text, or None.

    raw_body takes precedence over JSON body; a falsey key uses API_KEY.
    HTTPError responses are handled like successful responses, but a status
    outside expect raises SystemExit. Non-JSON responses become text; transport,
    serialization, and UTF-8 decoding errors propagate.
    """
    url = BASE_URL + path
    data = None
    headers = {"X-API-Key": key or API_KEY, "Accept": "application/json"}
    if raw_body is not None:
        data = raw_body
        headers["Content-Type"] = content_type
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as r:
            status, text = r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read().decode()
    try:
        parsed = json.loads(text) if text else None
    except ValueError:
        parsed = text
    if status not in expect:
        sys.exit(f"{method} {path} -> {status}: {text[:2000]}")
    return status, parsed


def write(resource, action, slug, method, path, body, key=None, **kw):
    """Perform a write, record request and response fixtures, and return the response body.

    Propagate call's errors (including SystemExit for unexpected status) and file
    errors. The server write occurs before fixture files are saved.
    """
    status, resp = call(method, path, body, key=key, **kw)
    req_rec = {"method": method, "path": path, "body": body}
    _dump(os.path.join(OUT, "requests", f"{resource}__{action}__{slug}.json"), req_rec)
    _dump(os.path.join(OUT, "responses", f"{resource}__{action}_response__{slug}.json"),
          {"status": status, "body": resp})
    print(f"{method} {path} -> {status}  ({resource}/{slug})")
    return resp


def tiny_png(w=64, h=40, rgb=(30, 110, 160)) -> bytes:
    """Return a solid RGB PNG with pixel dimensions w by h and 8-bit color channels."""
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def multipart(fields: dict, files: dict):
    """Return multipart body bytes and the Content-Type including its generated boundary.

    files maps field names to (filename, content bytes, content type) tuples;
    ordinary field values are formatted as text.
    """
    boundary = "----wayfarer" + uuid.uuid4().hex
    out = b""
    for k, v in fields.items():
        out += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n").encode()
    for k, (fname, content, ctype) in files.items():
        out += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"; filename=\"{fname}\"\r\n"
                f"Content-Type: {ctype}\r\n\r\n").encode() + content + b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return out, f"multipart/form-data; boundary={boundary}"


state = {"base_url": BASE_URL}

# The trip is synthetic: places are public landmarks, every business, booking reference, flight
# and link is made up. It keeps the shapes the client must handle: a date-line crossing that skips
# a calendar date, legs with different zones at each end, an item at exactly 00:00Z that is not
# all-day, an all-day visit, a multi-day car hire, trip-wide items and an item on no day.

# ---------------------------------------------------------------- collection
coll = write("collections", "create", "trip", "POST", "/api/collections/", {
    "name": "Tasmania Road Trip 2027",
    "description": "Hobart → Freycinet → Cradle Mountain → Strahan, by car.\n\n"
                   "Planning doc: [shared notes](https://example.com/trip-plan)",
    "start_date": "2027-03-05",
    "end_date": "2027-03-23",
    "is_public": False,
    "link": "https://example.com/tasmania",
})
cid = coll["id"]
state["collection_id"] = cid

write("collections", "update", "trip", "PATCH", f"/api/collections/{cid}/", {
    "description": coll["description"] + "\n\nTimezone for most of the trip: Australia/Hobart (AEDT, UTC+11).",
})

# ---------------------------------------------------------------- categories
cat_view = write("categories", "create", "viewpoint", "POST", "/api/categories/", {
    "name": "viewpoint", "display_name": "Viewpoint", "icon": "🔭",
})
state["category_viewpoint_id"] = cat_view["id"]

# ---------------------------------------------------------------- itinerary days
days = {}
for date, name, desc in [
    ("2027-03-05", "D0 · Travel day (DEN → LAX → SYD)",
     "Cross the date line overnight; 6 Mar does not exist for us."),
    ("2027-03-07", "D1 · Hobart", "Land early, recover, gentle city day."),
    ("2027-03-08", "D2 · Hobart → Freycinet", "Collect the rental car, drive the east coast, sunset cruise."),
]:
    d = write("itinerary-days", "create", date, "POST", "/api/itinerary-days/", {
        "collection": cid, "date": date, "name": name, "description": desc,
    })
    days[date] = d["id"]
state["itinerary_day_ids"] = days
write("itinerary-days", "update", "2027-03-08", "PATCH", f"/api/itinerary-days/{days['2027-03-08']}/", {
    "description": "Collect the rental car at 09:00, drive the Tasman Hwy (~3 h), sunset cruise in the evening.",
})

# ---------------------------------------------------------------- transportations
T = {}
def transport(slug, body):
    """Create a transportation, record fixtures and its ID in T, and return its body.

    Supplied fields override the default collection and privacy settings.
    Errors from write or a response without an ID propagate.
    """
    body = {"collection": cid, "is_public": False, **body}
    t = write("transportations", "create", slug, "POST", "/api/transportations/", body)
    T[slug] = t["id"]
    return t

transport("flight_den_lax", {
    "type": "plane", "name": "Example Air EX 101 DEN → LAX", "flight_number": "EX101",
    "from_location": "Denver International Airport (DEN)", "to_location": "Los Angeles International Airport (LAX)",
    "start_code": "DEN", "end_code": "LAX",
    "date": utc("2027-03-05T13:00", DEN), "end_date": utc("2027-03-05T14:40", LA),
    "start_timezone": DEN, "end_timezone": LA,
    "origin_latitude": 39.8561, "origin_longitude": -104.6737,
    "destination_latitude": 33.9416, "destination_longitude": -118.4085,
    "price": "149.00", "price_currency": "USD",
})
transport("flight_lax_syd", {
    "type": "plane", "name": "Example Air EX 7 LAX → SYD", "flight_number": "EX7",
    "description": "Overnight. Crosses the International Date Line — departs 5 Mar, arrives 7 Mar.",
    "from_location": "Los Angeles International Airport (LAX)", "to_location": "Sydney Airport (SYD)",
    "start_code": "LAX", "end_code": "SYD",
    "date": utc("2027-03-05T19:10", LA), "end_date": utc("2027-03-07T05:00", SYD),
    "start_timezone": LA, "end_timezone": SYD,
    "origin_latitude": 33.9416, "origin_longitude": -118.4085,
    "destination_latitude": -33.9399, "destination_longitude": 151.1753,
    "price": "1350.00", "price_currency": "USD",
    "link": "https://example.com/flights",
})
transport("flight_syd_hba", {
    "type": "plane", "name": "Example Air EX 1501 SYD → HBA", "flight_number": "EX1501",
    "from_location": "Sydney Airport (SYD)", "to_location": "Hobart Airport (HBA)",
    "start_code": "SYD", "end_code": "HBA",
    "date": utc("2027-03-07T07:00", SYD), "end_date": utc("2027-03-07T08:50", HBA),
    "start_timezone": SYD, "end_timezone": HBA,
    "origin_latitude": -33.9399, "origin_longitude": 151.1753,
    "destination_latitude": -42.8361, "destination_longitude": 147.5103,
})
transport("taxi_airport_hotel", {
    "type": "car", "name": "Taxi: HBA airport → Harbourside Hotel",
    "from_location": "Hobart Airport", "to_location": "Harbourside Hotel, 1 Example Quay",
    "date": utc("2027-03-07T09:15", HBA), "end_date": utc("2027-03-07T09:45", HBA),
    "start_timezone": HBA, "end_timezone": HBA,
    "origin_latitude": -42.8361, "origin_longitude": 147.5103,
    "destination_latitude": -42.8826, "destination_longitude": 147.3326,
    "price": "55.00", "price_currency": "AUD",
})
transport("car_hire", {
    "type": "car", "name": "Car hire (Hobart → Hobart)",
    "description": "Compact SUV, unlimited km. Pick-up 8 Mar 09:00, drop-off 23 Mar 10:00.",
    "from_location": "Car rental desk, 10 Example St, Hobart",
    "to_location": "Car rental desk, 10 Example St, Hobart",
    "date": utc("2027-03-08T09:00", HBA), "end_date": utc("2027-03-23T10:00", HBA),
    "start_timezone": HBA, "end_timezone": HBA,
    "origin_latitude": -42.8500, "origin_longitude": 147.5000,
    "destination_latitude": -42.8500, "destination_longitude": 147.5000,
    "price": "2900.00", "price_currency": "AUD",
})
transport("drive_hobart_freycinet", {
    "type": "car", "name": "Drive Hobart → Freycinet",
    "description": "Tasman Hwy via Swansea. ~190 km. Stop for lunch in Swansea.",
    "from_location": "Hobart", "to_location": "Coles Bay",
    "date": utc("2027-03-08T11:00", HBA), "end_date": utc("2027-03-08T14:30", HBA),
    "start_timezone": HBA, "end_timezone": HBA,
    "origin_latitude": -42.8821, "origin_longitude": 147.3272,
    "destination_latitude": -42.1247, "destination_longitude": 148.2861,
})
write("transportations", "update", "flight_syd_hba", "PATCH", f"/api/transportations/{T['flight_syd_hba']}/", {
    "description": "Domestic connection. Re-check bags at SYD after customs.", "price": "189.00", "price_currency": "AUD",
})
state["transportation_ids"] = T

# ---------------------------------------------------------------- lodging
L = {}
hotel = write("lodging", "create", "hotel", "POST", "/api/lodging/", {
    "collection": cid, "is_public": False, "type": "hotel",
    "name": "Harbourside Hotel", "location": "1 Example Quay, Hobart TAS 7000",
    "description": "Early check-in requested (red-eye arrival).",
    "check_in": utc("2027-03-07T14:00", HBA), "check_out": utc("2027-03-08T10:00", HBA), "timezone": HBA,
    "reservation_number": "HH-40123", "price": "320.00", "price_currency": "AUD",
    "latitude": -42.8826, "longitude": 147.3326, "link": "https://example.com/harbourside", "rating": 4.5,
})
L["hotel"] = hotel["id"]
camp = write("lodging", "create", "campground", "POST", "/api/lodging/", {
    "collection": cid, "is_public": False, "type": "campground",
    "name": "Bay Holiday Park", "location": "1 Example Rd, Coles Bay TAS 7215",
    "description": "Powered site, bay view.",
    "check_in": utc("2027-03-08T15:00", HBA), "check_out": utc("2027-03-09T10:00", HBA), "timezone": HBA,
    "reservation_number": "BHP-0042", "price": "58.00", "price_currency": "AUD",
    "latitude": -42.1247, "longitude": 148.2861,
})
L["campground"] = camp["id"]
write("lodging", "update", "campground", "PATCH", f"/api/lodging/{L['campground']}/", {
    "description": "Powered site #14, bay view. Quiet hours 22:00–07:00.",
})
state["lodging_ids"] = L

# ---------------------------------------------------------------- locations + visits
LOC, VIS = {}, {}
def location(slug, body):
    """Create a location, record fixtures and its ID in LOC, and return its body.

    Supplied fields override the default collection and privacy settings.
    Errors from write or a response without an ID propagate.
    """
    body = {"collections": [cid], "is_public": False, **body}
    loc = write("locations", "create", slug, "POST", "/api/locations/", body)
    LOC[slug] = loc["id"]
    return loc

def visit(slug, body):
    """Create a visit, record fixtures and its ID in VIS, and return its body.

    Errors from write or a response without an ID propagate.
    """
    v = write("visits", "create", slug, "POST", "/api/visits/", body)
    VIS[slug] = v["id"]
    return v

location("museum", {
    "name": "Tasmanian Museum and Art Gallery",
    "location": "Dunn Place, Hobart",
    "description": "Free entry. Don't miss the **natural history** galleries.",
    "latitude": -42.8822, "longitude": 147.3317,
    "category": {"name": "museum", "display_name": "Museum", "icon": "🏛️"},
    "tags": ["art", "indoor", "free"], "link": "https://example.com/museum",
})
visit("museum", {"location": LOC["museum"], "timezone": HBA,
                 "start_date": utc("2027-03-07T13:00", HBA), "end_date": utc("2027-03-07T14:30", HBA),
                 "notes": "Arrive after lunch; café on site."})
location("kayak", {
    "name": "Harbour kayak tour",
    "location": "Brooke Street Pier, Hobart",
    "description": "45-minute paddle along the waterfront.",
    "latitude": -42.8846, "longitude": 147.3343,
    "category": {"name": "activity", "display_name": "Activity", "icon": "🛶"},
    "tags": ["outdoor", "water"], "price": "95.00", "price_currency": "AUD",
    "link": "https://example.com/kayak",
})
# 11:00 AEDT is exactly 00:00Z: a timed visit that starts at UTC midnight and is not all-day.
visit("kayak", {"location": LOC["kayak"], "timezone": HBA,
                "start_date": utc("2027-03-07T11:00", HBA), "end_date": utc("2027-03-07T11:45", HBA)})
location("lookout", {
    "name": "Wineglass Bay Lookout",
    "location": "Freycinet National Park",
    "description": "Steep 1.5 km walk up from the car park. Go early or late.",
    "latitude": -42.1500, "longitude": 148.2900,
    # Existing category referenced by name (serializer resolves user's category by name).
    "category": {"name": "viewpoint", "display_name": "Viewpoint", "icon": "🔭"},
    "tags": ["walk", "photo"],
})
visit("lookout", {"location": LOC["lookout"], "timezone": HBA,
                  "start_date": utc("2027-03-08T16:00", HBA), "end_date": utc("2027-03-08T16:30", HBA)})
location("cruise", {
    "name": "Sunset cruise",
    "location": "Coles Bay jetty",
    "description": "Two hours around the bay. Runs when the sea is calm.",
    "latitude": -42.1210, "longitude": 148.2830,
    "category": {"name": "tour", "display_name": "Tour", "icon": "🚤"},
    "tags": ["boat", "evening"], "rating": 5,
})
# Sent with an explicit +11:00 offset (instead of Z) to show the server normalises to UTC.
visit("cruise", {"location": LOC["cruise"], "timezone": HBA,
                 "start_date": "2027-03-08T18:30:00+11:00", "end_date": "2027-03-08T20:30:00+11:00",
                 "notes": "Bring a jacket — it gets cold on the water."})
location("dove_lake", {
    "name": "Dove Lake Circuit",
    "location": "Cradle Mountain",
    "description": "Unscheduled on the itinerary on purpose (appears only in collection.locations).",
    "latitude": -41.6600, "longitude": 145.9600,
    "category": {"name": "hiking", "display_name": "Hiking", "icon": "🥾"},
    "tags": ["hike"],
})
# All-day visit: UTC-midnight start/end (frontend toUTCDatetime(allDay=true)).
visit("dove_lake_allday", {"location": LOC["dove_lake"], "timezone": HBA,
                           "start_date": "2027-03-10T00:00:00Z", "end_date": "2027-03-10T00:00:00Z"})
write("locations", "update", "kayak", "PATCH", f"/api/locations/{LOC['kayak']}/", {
    "rating": 4.0, "tags": ["outdoor", "water", "booked"],
})
write("visits", "update", "kayak", "PATCH", f"/api/visits/{VIS['kayak']}/", {
    "notes": "Booked 11:00 slot, ref KAY-1001.",
})
state["location_ids"], state["visit_ids"] = LOC, VIS

# ---------------------------------------------------------------- image
png = tiny_png()
body, ctype = multipart({"content_type": "location", "object_id": LOC["museum"], "is_primary": "true"},
                        {"image": ("museum.png", png, "image/png")})
status, img = call("POST", "/api/images/", raw_body=body, content_type=ctype)
_dump(os.path.join(OUT, "requests", "images__create__museum.json"),
      {"method": "POST", "path": "/api/images/", "content_type": "multipart/form-data",
       "fields": {"content_type": "location", "object_id": LOC["museum"], "is_primary": "true",
                  "image": "<binary PNG file, filename museum.png>"}})
_dump(os.path.join(OUT, "responses", "images__create_response__museum.json"), {"status": status, "body": img})
print(f"POST /api/images/ -> {status}")
state["image_id"] = img.get("id") if isinstance(img, dict) else None
# NOTE: `is_primary` in the upload form is ignored by the server; use toggle_primary.
if state["image_id"]:
    write("images", "toggle_primary", "museum", "POST", f"/api/images/{state['image_id']}/toggle_primary/", None)

# ---------------------------------------------------------------- notes
N = {}
N["d1_tips"] = write("notes", "create", "d1_tips", "POST", "/api/notes/", {
    "collection": cid, "is_public": False, "name": "Hobart day tips", "date": "2027-03-07",
    "content": "## Jet-lag plan\n- Stay up until 21:00\n- Coffee on the waterfront\n\n"
               "Ferry: [harbour ferry](https://example.com/ferry)",
    "links": ["https://example.com/ferry"],
})["id"]
N["trip_essentials"] = write("notes", "create", "trip_essentials", "POST", "/api/notes/", {
    "collection": cid, "is_public": False, "name": "Trip essentials", "date": None,
    "content": "# Essentials\n1. Visa sorted ✅\n2. Rental car bond: A$500 hold\n"
               "3. Emergency: **000**\n\nSee [park alerts](https://example.com/park-alerts)",
    "links": ["https://example.com/park-alerts"],
})["id"]
write("notes", "update", "d1_tips", "PATCH", f"/api/notes/{N['d1_tips']}/", {
    "content": "## Jet-lag plan\n- Stay up until 21:00\n- Coffee on the waterfront\n- Early night\n\n"
               "Ferry: [harbour ferry](https://example.com/ferry)",
})
state["note_ids"] = N

# ---------------------------------------------------------------- checklists
C = {}
pickup = write("checklists", "create", "car_pickup", "POST", "/api/checklists/", {
    "collection": cid, "is_public": False, "name": "Car pickup", "date": "2027-03-08",
    "items": [
        {"name": "Driver licences + IDP", "is_checked": True},
        {"name": "Photograph existing damage", "is_checked": False},
        {"name": "Check the spare tyre", "is_checked": False},
        {"name": "Download offline maps", "is_checked": True},
    ],
})
C["car_pickup"] = pickup["id"]
C["packing"] = write("checklists", "create", "packing", "POST", "/api/checklists/", {
    "collection": cid, "is_public": False, "name": "Packing list", "date": None,
    "items": [
        {"name": "Warm layers", "is_checked": True},
        {"name": "Rain shell", "is_checked": True},
        {"name": "Sunscreen", "is_checked": False},
        {"name": "Plug adapters (Type I)", "is_checked": False},
    ],
})["id"]
# NOTE: PATCH with `items` REPLACES the item set: items omitted are deleted
# (adventures/serializers.py ChecklistSerializer.update). Item `id`s are read-only in the item
# serializer, so every item is recreated with a NEW id on this PATCH (observed).
items = pickup["items"]
patched_items = [{"id": it["id"], "name": it["name"],
                  "is_checked": True if it["name"].startswith("Photograph") else it["is_checked"]} for it in items]
patched_items.append({"name": "Note the fuel level", "is_checked": False})
write("checklists", "update", "car_pickup", "PATCH", f"/api/checklists/{C['car_pickup']}/", {
    "items": patched_items,
})
state["checklist_ids"] = C

# ---------------------------------------------------------------- itinerary items
IT = {}
def itin(slug, content_type, object_id, date=None, order=0, is_global=False):
    """Create an itinerary row, record fixtures and its ID in IT, and return its body.

    content_type is the model name. is_global omits date from the request;
    otherwise date is sent even when None. Errors from write or a response
    without an ID propagate.
    """
    body = {"collection": cid, "content_type": content_type, "object_id": object_id, "order": order}
    if is_global:
        body["is_global"] = True
    else:
        body["date"] = date
    r = write("itineraries", "create", slug, "POST", "/api/itineraries/", body)
    IT[slug] = r["id"]
    return r

D0, D1, D2 = "2027-03-05", "2027-03-07", "2027-03-08"
itin("d0_flight_den_lax", "transportation", T["flight_den_lax"], D0, 0)
itin("d0_flight_lax_syd", "transportation", T["flight_lax_syd"], D0, 1)
itin("d1_flight_syd_hba", "transportation", T["flight_syd_hba"], D1, 0)
itin("d1_taxi", "transportation", T["taxi_airport_hotel"], D1, 1)
itin("d1_hotel", "lodging", L["hotel"], D1, 2)
itin("d1_museum", "location", LOC["museum"], D1, 3)
itin("d1_kayak", "location", LOC["kayak"], D1, 4)
itin("d1_note", "note", N["d1_tips"], D1, 5)
itin("d2_car", "transportation", T["car_hire"], D2, 0)
itin("d2_checklist", "checklist", C["car_pickup"], D2, 1)
itin("d2_drive", "transportation", T["drive_hobart_freycinet"], D2, 2)
itin("d2_campground", "lodging", L["campground"], D2, 3)
itin("d2_lookout", "location", LOC["lookout"], D2, 4)
itin("d2_cruise", "location", LOC["cruise"], D2, 5)
itin("global_note", "note", N["trip_essentials"], is_global=True, order=0)
itin("global_checklist", "checklist", C["packing"], is_global=True, order=1)
state["itinerary_item_ids"] = IT

# Reorder within D1: swap museum (3) and kayak (4). Payload mirrors
# CollectionItineraryPlanner.svelte saveReorderedItems().
write("itineraries", "reorder", "d1_swap", "POST", "/api/itineraries/reorder/", {"items": [
    {"id": IT["d1_flight_syd_hba"], "date": D1, "order": 0},
    {"id": IT["d1_taxi"], "date": D1, "order": 1},
    {"id": IT["d1_hotel"], "date": D1, "order": 2},
    {"id": IT["d1_kayak"], "date": D1, "order": 3},
    {"id": IT["d1_museum"], "date": D1, "order": 4},
    {"id": IT["d1_note"], "date": D1, "order": 5},
]})
# Restore original order (so detail fixtures show museum before kayak).
write("itineraries", "reorder", "d1_restore", "POST", "/api/itineraries/reorder/", {"items": [
    {"id": IT["d1_museum"], "date": D1, "order": 3},
    {"id": IT["d1_kayak"], "date": D1, "order": 4},
]})
# Move an item between days (drag D1 note onto D2 at index 0); the client sends
# the full new ordering of BOTH affected days.
write("itineraries", "reorder", "move_note_d1_to_d2", "POST", "/api/itineraries/reorder/", {"items": [
    {"id": IT["d1_flight_syd_hba"], "date": D1, "order": 0},
    {"id": IT["d1_taxi"], "date": D1, "order": 1},
    {"id": IT["d1_hotel"], "date": D1, "order": 2},
    {"id": IT["d1_museum"], "date": D1, "order": 3},
    {"id": IT["d1_kayak"], "date": D1, "order": 4},
    {"id": IT["d1_note"], "date": D2, "order": 0},
    {"id": IT["d2_car"], "date": D2, "order": 1},
    {"id": IT["d2_checklist"], "date": D2, "order": 2},
    {"id": IT["d2_drive"], "date": D2, "order": 3},
    {"id": IT["d2_campground"], "date": D2, "order": 4},
    {"id": IT["d2_lookout"], "date": D2, "order": 5},
    {"id": IT["d2_cruise"], "date": D2, "order": 6},
]})
# ...and move it back to D1 (final seeded state).
write("itineraries", "reorder", "move_note_back_to_d1", "POST", "/api/itineraries/reorder/", {"items": [
    {"id": IT["d1_note"], "date": D1, "order": 5},
    {"id": IT["d2_car"], "date": D2, "order": 0},
    {"id": IT["d2_checklist"], "date": D2, "order": 1},
    {"id": IT["d2_drive"], "date": D2, "order": 2},
    {"id": IT["d2_campground"], "date": D2, "order": 3},
    {"id": IT["d2_lookout"], "date": D2, "order": 4},
    {"id": IT["d2_cruise"], "date": D2, "order": 5},
]})
# Move a dated item to trip-wide (global) and back, via reorder.
write("itineraries", "reorder", "to_global", "POST", "/api/itineraries/reorder/", {"items": [
    {"id": IT["global_note"], "is_global": True, "date": None, "order": 0},
    {"id": IT["global_checklist"], "is_global": True, "date": None, "order": 1},
    {"id": IT["d1_note"], "is_global": True, "date": None, "order": 2},
]})
write("itineraries", "reorder", "from_global_back_to_d1", "POST", "/api/itineraries/reorder/", {"items": [
    {"id": IT["d1_note"], "is_global": False, "date": D1, "order": 5},
]})

# ---------------------------------------------------------------- share with guest
if GUEST_API_KEY:
    _, users = call("GET", "/auth/users/")
    guest = next((u for u in users if u.get("username") == GUEST_USERNAME), None)
    if not guest:
        sys.exit(f"user {GUEST_USERNAME!r} not found in /auth/users/ (needs public_profile=true)")
    state["guest_uuid"] = guest["uuid"]
    write("collections", "share", "guest", "POST", f"/api/collections/{cid}/share/{guest['uuid']}/", None)
    write("collections", "accept_invite", "guest", "POST", f"/api/collections/{cid}/accept-invite/", None,
          key=GUEST_API_KEY)
else:
    print("GUEST_API_KEY not set: skipping share step")

_dump(os.path.join(OUT, "seed_state.json"), state)
print("done; state written to seed_state.json")
