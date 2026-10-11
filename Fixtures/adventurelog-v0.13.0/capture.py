#!/usr/bin/env python3
"""
Capture read-side fixtures (GET responses, errors, schema) from an AdventureLog
instance that has been seeded with seed.py.

Usage:
    BASE_URL=... API_KEY=... python3 capture.py
    BASE_URL=... API_KEY=... GUEST_API_KEY=... python3 capture.py   # adds the second-user captures

Reads seed_state.json (written by seed.py) for object ids. Writes
responses/*.json, errors/*.json, openapi/*.json, responses/ics-calendar__generate.ics.
Each JSON fixture is the raw response body; a sidecar in responses/_meta.json
records method, path, status and content-type for every capture.
"""
import json
import os
import re
import sys
import urllib.request
import urllib.error

BASE_URL = os.environ.get("BASE_URL", "http://127.0.0.1:8000").rstrip("/")
API_KEY = os.environ["API_KEY"]
GUEST_API_KEY = os.environ.get("GUEST_API_KEY")
OUT = os.environ.get("FIXTURES_DIR", os.path.dirname(os.path.abspath(__file__)))
S = json.load(open(os.path.join(OUT, "seed_state.json")))
for d in ("responses", "errors", "openapi"):
    os.makedirs(os.path.join(OUT, d), exist_ok=True)

META_PATH = os.path.join(OUT, "responses", "_meta.json")
# Start from the previous sidecar so skipped or failed captures keep their entries.
META = json.load(open(META_PATH)) if os.path.exists(META_PATH) else {}
FAILED = []


def get(path, key=API_KEY, method="GET", body=None, headers=None):
    """Request BASE_URL + path and return status, content type, bytes, and headers.

    A falsey key omits authentication unless supplied in headers. HTTP errors
    become response tuples; transport, body-encoding, and read errors propagate.
    """
    h = {"Accept": "application/json"}
    if key:
        h["X-API-Key"] = key
    if headers:
        h.update(headers)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE_URL + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.headers.get("Content-Type", ""), r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), e.read(), dict(e.headers)


def expected_status(name):
    """The status a capture must return: the leading `NNN__` or `quirk_NNN__` in its name, else 200."""
    m = re.match(r"(?:quirk_)?(\d{3})__", name)
    return int(m.group(1)) if m else 200


def save(folder, name, path, key=API_KEY, method="GET", body=None, headers=None, raw_ext=None, expect=None):
    """Capture a response under OUT, update META, and return the HTTP status.

    The status must equal `expect` (default: expected_status(name)); otherwise the
    existing fixture is left alone and the capture is recorded in FAILED. With
    raw_ext, write bytes using that extension; otherwise write JSON, wrapping
    non-JSON text in _non_json_body (up to 4,000 characters). Expected HTTP error
    responses are saved too. Request and file-write errors propagate.
    """
    status, ctype, content, hdrs = get(path, key, method, body, headers)
    fname = f"{name}.{raw_ext}" if raw_ext else f"{name}.json"
    want = expect if expect is not None else expected_status(name)
    if status != want:
        FAILED.append(f"{folder}/{fname}")
        print(f"FAILED {status} (expected {want}) {method} {path} -> {folder}/{fname} not written")
        return status
    fp = os.path.join(OUT, folder, fname)
    if raw_ext:
        open(fp, "wb").write(content)
    else:
        try:
            obj = json.loads(content) if content else None
        except ValueError:
            obj = {"_non_json_body": content.decode(errors="replace")[:4000]}
        with open(fp, "w") as f:
            json.dump(obj, f, indent=2, ensure_ascii=False)
            f.write("\n")
    rec = {"method": method, "path": path, "status": status, "content_type": ctype,
           "auth": "admin" if key == API_KEY else ("guest" if key and key == GUEST_API_KEY else (key and "bad-key" or "none"))}
    if body is not None:
        rec["request_body"] = body
    if "WWW-Authenticate" in hdrs:
        rec["www_authenticate"] = hdrs["WWW-Authenticate"]
    META[f"{folder}/{fname}"] = rec
    print(f"{status} {method} {path} -> {folder}/{fname}")
    return status


cid = S["collection_id"]
LOC, VIS, T, L = S["location_ids"], S["visit_ids"], S["transportation_ids"], S["lodging_ids"]
N, C, IT, DAYS = S["note_ids"], S["checklist_ids"], S["itinerary_item_ids"], S["itinerary_day_ids"]

R = "responses"
# --- collections
save(R, "collections__list", "/api/collections/")
save(R, "collections__detail", f"/api/collections/{cid}/")
save(R, "collections__detail_nested", f"/api/collections/{cid}/?nested=true")
save(R, "collections__all", "/api/collections/all/")
if GUEST_API_KEY:
    save(R, "collections__shared__as_guest", "/api/collections/shared/", key=GUEST_API_KEY)
    save(R, "collections__detail__as_guest", f"/api/collections/{cid}/", key=GUEST_API_KEY)
save(R, "collections__invites", "/api/collections/invites/")
save(R, "collections__archived", "/api/collections/archived/")
# --- itinerary
save(R, "itineraries__list", "/api/itineraries/")
save(R, "itineraries__detail", f"/api/itineraries/{IT['d1_museum']}/")
save(R, "itineraries__detail_global", f"/api/itineraries/{IT['global_note']}/")
save(R, "itinerary-days__list", "/api/itinerary-days/")
save(R, "itinerary-days__detail", f"/api/itinerary-days/{DAYS['2027-03-08']}/")
# --- locations / visits
save(R, "locations__list", "/api/locations/")
save(R, "locations__list_page_size_2", "/api/locations/?page_size=2")
save(R, "locations__detail", f"/api/locations/{LOC['museum']}/")
save(R, "locations__detail_allday_visit", f"/api/locations/{LOC['dove_lake']}/")
save(R, "locations__all", "/api/locations/all/")
save(R, "locations__pins", "/api/locations/pins/")
save(R, "visits__list", "/api/visits/")
save(R, "visits__detail", f"/api/visits/{VIS['cruise']}/")
# --- transportations / lodging / notes / checklists
save(R, "transportations__list", "/api/transportations/")
save(R, "transportations__detail", f"/api/transportations/{T['flight_lax_syd']}/")
save(R, "lodging__list", "/api/lodging/")
save(R, "lodging__detail", f"/api/lodging/{L['hotel']}/")
save(R, "notes__list", "/api/notes/", expect=403)  # NB: server returns 403 by design
save(R, "notes__all", "/api/notes/all/")
save(R, "notes__detail", f"/api/notes/{N['d1_tips']}/")
save(R, "checklists__list", "/api/checklists/")
save(R, "checklists__detail", f"/api/checklists/{C['car_pickup']}/")
# --- categories / images
save(R, "categories__list", "/api/categories/")
save(R, "categories__detail", f"/api/categories/{S['category_viewpoint_id']}/")
save(R, "images__list", "/api/images/")
if S.get("image_id"):
    save(R, "images__detail", f"/api/images/{S['image_id']}/")
# --- calendar / search / ics
save(R, "calendar__events", "/api/calendar/events/")
save(R, "calendar__events_range", "/api/calendar/events/?start=2027-03-07&end=2027-03-08")
save(R, "search__list", "/api/search/?q=hobart")
save(R, "search__list_freycinet", "/api/search/?q=freycinet")
save(R, "ics-calendar__generate", "/api/ics-calendar/generate/", raw_ext="ics")
# --- user / auth
save(R, "auth__user-metadata", "/auth/user-metadata/")
save(R, "auth__current-user", "/auth/current-user/")
save(R, "auth__users", "/auth/users/")
save(R, "auth__api-keys", "/auth/api-keys/")
save(R, "auth__is-registration-disabled", "/auth/is-registration-disabled/", key=None)
save(R, "public-url", "/public-url/", key=None)
save(R, "health", "/health/", key=None)
save(R, "stats__dashboard", "/api/stats/dashboard/")
save(R, "tags__types", "/api/tags/types/")
# --- errors
E = "errors"
save(E, "401__bad_api_key", "/api/collections/", key="al_this-is-not-a-valid-key")
save(E, "401__no_auth_list_categories", "/api/categories/", key=None)
save(E, "400__collections_list_no_auth", "/api/collections/", key=None)
save(E, "403__notes_list_not_allowed", "/api/notes/")
if GUEST_API_KEY:
    # guest owns a private location; admin must not read it.
    status, _, content, _ = get("/api/locations/", key=GUEST_API_KEY, method="POST",
                                body={"name": "Guest's private spot", "is_public": False,
                                      "latitude": -41.4400, "longitude": 147.1400})
    kloc = json.loads(content)["id"]
    save(E, "404__other_users_private_location", f"/api/locations/{kloc}/")
    # Non-shared object of another user: queryset filtering => 404, not 403.
    save(E, "404__other_users_location_patch", f"/api/locations/{kloc}/", method="PATCH", body={"name": "hijack"})
    # Shared user writing the collection itself: update queryset is owner-only => 404.
    save(E, "404__shared_user_patch_collection", f"/api/collections/{cid}/", key=GUEST_API_KEY,
         method="PATCH", body={"name": "Guest renamed it"})
    # Shared user deleting the owner's location in the shared trip => 403 (PermissionDenied).
    save(E, "403__shared_user_delete_owners_location", f"/api/locations/{LOC['kayak']}/", key=GUEST_API_KEY,
         method="DELETE")
    # QUIRK: shared user PATCHing a trip item without re-sending `collection` -> 403
    # (partial_update treats an absent collection as "remove from collection").
    save(E, "403__shared_user_patch_note_without_collection", f"/api/notes/{N['trip_essentials']}/",
         key=GUEST_API_KEY, method="PATCH", body={"name": "Trip essentials"})
    save(R, "notes__update_as_shared_user_with_collection", f"/api/notes/{N['trip_essentials']}/",
         key=GUEST_API_KEY, method="PATCH", body={"collection": cid, "name": "Trip essentials"})
    save(E, "403__itinerary_create_for_other_users_object", "/api/itineraries/", method="POST",
         body={"collection": cid, "content_type": "location", "object_id": kloc, "date": "2027-03-09", "order": 0})
save(E, "404__collection_not_found", "/api/collections/00000000-0000-4000-8000-000000000000/")
save(E, "404__non_uuid_pk", "/api/locations/not-a-uuid/")
save(E, "400__transportation_missing_required", "/api/transportations/", method="POST",
     body={"collection": cid, "name": ""})
save(E, "400__visit_bad_datetime", "/api/visits/", method="POST",
     body={"location": LOC["kayak"], "start_date": "07/03/2027 10am", "timezone": "Mars/Olympus"})
save(E, "400__itinerary_both_date_and_global", "/api/itineraries/", method="POST",
     body={"collection": cid, "content_type": "note", "object_id": N["trip_essentials"],
           "date": "2027-03-07", "is_global": True, "order": 0})
save(E, "400__itinerary_date_outside_collection", "/api/itineraries/", method="POST",
     body={"collection": cid, "content_type": "note", "object_id": N["trip_essentials"],
           "date": "2027-03-29", "order": 0})
save(E, "400__reorder_empty", "/api/itineraries/reorder/", method="POST", body={"items": []})
save(E, "400__checklist_missing_items", "/api/checklists/", method="POST",
     body={"collection": cid, "name": "no items key"})
# QUIRK: the API does NOT reject check_out < check_in (model.clean() is never called) -> 201.
st = save(E, "quirk_201__lodging_checkout_before_checkin_accepted", "/api/lodging/", method="POST",
          body={"collection": cid, "name": "bad", "type": "hotel",
                "check_in": "2027-03-13T02:00:00Z", "check_out": "2027-03-12T02:00:00Z"})
if st == 201:  # clean up so it doesn't pollute the trip
    bad = json.load(open(os.path.join(OUT, E, "quirk_201__lodging_checkout_before_checkin_accepted.json")))
    get(f"/api/lodging/{bad['id']}/", method="DELETE")
save(E, "pagination__locations_page_size_2_page_1", "/api/locations/?page_size=2")
save(E, "pagination__locations_page_size_2_page_2", "/api/locations/?page_size=2&page=2")
save(E, "pagination__collections_page_size_1", "/api/collections/?page_size=1")
save(E, "404__pagination_page_out_of_range", "/api/locations/?page_size=2&page=99")
if GUEST_API_KEY:
    get(f"/api/locations/{kloc}/", key=GUEST_API_KEY, method="DELETE")  # cleanup
# --- export: a zip; keep only its metadata.json
status, _, content, _ = get(f"/api/collections/{cid}/export/")
if status == 200:
    import io, zipfile
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        with open(os.path.join(OUT, R, "collections__export_metadata.json"), "w") as f:
            json.dump(json.loads(archive.read("metadata.json")), f, indent=2)
            f.write("\n")
else:
    FAILED.append(f"{R}/collections__export_metadata.json ({status})")
# --- schema
save("openapi", "swagger", "/docs/?format=openapi", headers={"Accept": "*/*"})

with open(META_PATH, "w") as f:
    json.dump(META, f, indent=2)
    f.write("\n")
if FAILED:
    print(f"{len(FAILED)} capture(s) returned an unexpected status and were not written:", *FAILED, sep="\n  ")
    sys.exit(1)
print("done")
