# AdventureLog API: notes for the iOS client

Every fixture here was captured from a real AdventureLog backend (v0.13.0) seeded by `seed.py`.
Each claim below either cites the backend file it comes from or names the fixture where it was seen.
Backend paths are relative to `backend/server/` in an AdventureLog checkout at the commit below.

- **Git commit:** `5673ef5bb5aaa96081bc250ef1d16da8b45977e3`
- **Version string:** `v0.13.0`. This is `ADVENTURELOG_RELEASE_VERSION` in `main/settings.py`. The server shows it only in the export payload (`responses/collections__export_metadata.json`, written by `adventures/views/collection_view.py` `export_collection`). No version endpoint exists. The swagger `info.version` is always `"v1"`.
- **Captured:** 2026-10-11 UTC. `status`/`days_until_start` depend on the date the capture ran.
- **The trip is synthetic.** `seed.py` builds a made-up Tasmania road trip (5–23 Mar 2027) for two made-up users, Alex Example and Sam Example. Places are public landmarks; every business, booking reference, flight number and link is invented. It keeps the cases the client must handle: a date-line crossing that skips a date, legs with a different zone at each end, a timed item at exactly 00:00Z, an all-day visit, a multi-day car hire, trip-wide items and an item on no day.

## 1. Base paths and routing
| Prefix | What | Source |
|---|---|---|
| `/api/` | DRF routers: `locations, collections, transportations, notes, checklists, images, categories, lodging, visits, itineraries, itinerary-days, calendar, ics-calendar, search, stats, tags, attachments, trails, activities, ...` | `adventures/urls.py`, `main/urls.py` |
| `/api/` | world travel: `countries/`, `regions/`, `<cc>/regions/` ... | `worldtravel/urls.py` |
| `/auth/` | user endpoints: `user-metadata/`, `current-user/`, `update-user/` (PATCH), `users/`, `user/<username>/`, `api-keys/`, `is-registration-disabled/` ... | `main/urls.py`, `users/views.py`, `cloud/views.py` |
| `/auth/browser/v1/...`, `/auth/app/v1/...` | allauth headless (session login). The client does not need these when it uses API keys | `main/urls.py` |
| `/docs/?format=openapi` | drf_yasg Swagger 2.0 JSON | `main/urls.py` |
| `/media/<path>` | protected media. Accepts `X-API-Key` (`main/views.py` `_resolve_user`) | |
| `/health/`, `/public-url/` | unauthenticated | `main/views.py` |

- **Trailing slash is required.** A `GET /api/categories` with no slash returns `301` to the slash URL. A `POST` with no slash returned `500`, because Django's APPEND_SLASH cannot redirect a POST. Always send the trailing `/`.
- Router actions use these exact paths: `/api/collections/all/`, `/shared/`, `/archived/`, `/invites/`, `/{id}/share/{user_uuid}/`, `/{id}/accept-invite/`, `/{id}/unshare/{uuid}/`, `/{id}/leave/`, `/{id}/export/`; `/api/itineraries/reorder/`, `/api/itineraries/auto-generate/`; `/api/notes/all/`; `/api/locations/all/`, `/pins/`; `/api/images/{id}/toggle_primary/` (underscore); `/api/calendar/events/`; `/api/ics-calendar/generate/`; `/api/tags/types/`; `/api/stats/dashboard/`.

## 2. Auth
- Send `X-API-Key: al_<token>`. `Authorization: Api-Key al_<token>` also works (both verified, 200). Source: `users/authentication.py`.
- How keys are made: `APIKey.generate(user, name)` returns `al_` + `secrets.token_urlsafe(32)`. The database stores only a PBKDF2-SHA256 hash (600k iterations, salted with `SECRET_KEY`). The raw key is returned once, by `POST /auth/api-keys/` with `{"name": "..."}` (`users/models.py`, `users/views.py` `APIKeyListCreateView`). Changing `SECRET_KEY` invalidates every key. `GET /auth/api-keys/` lists `id`, `name`, `key_prefix`, `created_at` and `last_used_at`, never the key (`responses/auth__api-keys.json`).
- An invalid key gets `401 {"detail":"Invalid or expired API key."}` with `WWW-Authenticate: Api-Key` (`errors/401__bad_api_key.json`).
- A missing key gets `401 {"detail":"Authentication credentials were not provided."}` on views using `IsAuthenticated` (`errors/401__no_auth_list_categories.json`). Some views answer differently:
  - `GET /api/collections/` with no auth returns **400** `{"error":"User is not authenticated"}` (`collection_view.py` `list`).
  - Views using `IsOwnerOrSharedWithFullAccess` let anonymous GETs through to public objects.
- API-key requests skip CSRF (`adventures/middleware.py` `DisableCSRFForAPIKeyMiddleware`). **Do not send a `sessionid` cookie together with the key.** If the cookie is present, CSRF is enforced again.
- "Who am I": use `GET /auth/user-metadata/` (`responses/auth__user-metadata.json`) or `GET /auth/current-user/`, which returns `{user, subscription, has_access, cloud_mode}` (`responses/auth__current-user.json`). The user object identifies people by `uuid`. It contains no integer `pk` (`users/serializers.py`).
- In CLOUD_MODE only, `/api/*` can return `402 {"detail":"Subscription required.","code":"subscription_required"}` (`cloud/middleware.py`).

## 3. IDs
- **Content IDs are UUID strings:** Collection, Location, Visit, Transportation, Lodging, Note, Checklist, ChecklistItem, Category, ContentImage, itinerary item, itinerary day (`adventures/models.py`).
- **Users are referenced by `uuid`**, never by integer pk. Every `user` field on content is the owner's uuid string (`main/utils.py` `CustomModelSerializer`). `collection.shared_with` is a list of user uuids.
- Exceptions:
  - `Location.user` in full (non-nested) responses is a **whole user object**, not a uuid string (`serializers.py` `LocationSerializer.to_representation`; see `responses/locations__detail.json`).
  - Nested locations, the ones inside `collections/{id}/?nested=true`, have no `user` field at all.
- **`itinerary[].content_type` is an integer** (a Django ContentType pk). It is install-specific. The values seen here were `checklist=16, note=19, transportation=20, lodging=23, location=24`, and they were the same on a second fresh database. **Do not hard-code them.** Use `item.type` or `object_name` (string model names) instead.
- When writing an itinerary item, send `content_type` as a **string**: `"location"`, `"transportation"`, `"lodging"`, `"note"`, `"checklist"` or `"visit"` (`views/itinerary_view.py` `create`).
- A pk that is not a UUID gives `404 {"detail":"Not found."}` (`errors/404__non_uuid_pk.json`).

## 4. Pagination
- **Only `GET /api/collections/` and `GET /api/locations/` paginate.** They use `PageNumberPagination`: `page_size` defaults to 25, the query param is `page_size`, the maximum is 1000, and pages are selected with `page` (`adventures/utils/pagination.py`). Envelope:
  `{"count": Int, "next": String?, "previous": String?, "results": [...]}`. `next`/`previous` are absolute URLs built from `PUBLIC_URL` (`errors/pagination__locations_page_size_2_page_*.json`).
- A page past the end returns `404 {"detail":"Invalid page."}` (`errors/404__pagination_page_out_of_range.json`).
- **Every other list is a bare JSON array with no pagination:** itineraries, itinerary-days, visits, transportations, lodging, checklists, categories, images, `notes/all/`, `collections/all|shared|archived/`, `locations/all/`, `locations/pins/`.
- `GET /api/notes/` returns **403** `{"detail":"Listing all notes is not allowed."}` by design. Use `/api/notes/all/` (`views/note_view.py`).
- **No query-string filters exist.** `filterset_fields` is declared, but django-filter is not installed or configured. For example, `GET /api/itinerary-days/?collection=<random uuid>` still returned all 3 days. Filter on the client, or load trips through `GET /api/collections/{id}/`.
- Sorting on `collections/` and `locations/` uses `order_by` and `order_direction`. The `asc`/`desc` semantics are inverted for some keys (`collection_view.py` `apply_sorting`). Don't rely on them.

## 5. Loading a trip day by day (what the web app does)
- The web page `frontend/src/routes/collections/[id]/+page.server.ts` makes **one** call: `GET /api/collections/{id}/`. The response (`responses/collections__detail.json`) includes:
  - `locations[]` (full, each with `visits[]`), `transportations[]`, `lodging[]`, `notes[]` and `checklists[]` (each with `items[]`), all scoped to this collection.
  - `itinerary[]`: the placement rows, added by `collection_view.py` `retrieve`.
  - `itinerary_days[]`: per-date metadata `{id, collection, date, name, description}` (`CollectionItineraryDay`, unique on `(collection, date)`).
  - `collaborators[]`: owner plus shared users, with `is_owner` and `is_current_user`. `shared_with[]` holds uuids.
- `PATCH`/`PUT /api/collections/{id}/` responses do **not** include `itinerary` or `itinerary_days`. Only `retrieve` adds them. Re-GET after editing.
- `?nested=true` removes `transportations/notes/checklists/lodging` and slims the locations (no visits, user, collections or geo). The page doesn't use this, so avoid it (`responses/collections__detail_nested.json`).
- **Itinerary row shape** (`serializers.py` `CollectionItineraryItemSerializer`):
  `{id, collection, content_type:Int, object_id, item:{id,type}, date:"YYYY-MM-DD"|null, is_global:Bool, order:Int, start_datetime, end_datetime, created_at, object_name}`.
  To resolve a row, match `object_id` against the matching array in the collection (`frontend/.../CollectionItineraryPlanner.svelte` `resolveItineraryItem`).
- **Ordering:** sort rows **within one date** by `order` ascending, starting at 0. Uniqueness is enforced per `(collection, date, order)` for dated rows and per `(collection, order)` for global rows (`models.py` `CollectionItineraryItem.Meta.constraints`).
  - On create, if the requested `order` is at or below the current max for that day, the server sets `order = max+1` (`itinerary_view.py` `create`).
  - Gaps are possible.
- **The day list** runs from `collection.start_date` to `collection.end_date` inclusive, one entry per calendar date. Dates with no rows are still shown (`groupItemsByDay`).
  - The planner day key is the itinerary row's `date`, a plain date string. **It is not derived from item datetimes.**
  - Example: the LAX→SYD flight sits on day `2027-03-05` even though its `end_datetime` is `2027-03-06T18:00:00Z`.
  - There is no row or day-meta for 2027-03-06, so a client shows that date as empty.
- **Trip-wide / global items:** these are rows with `is_global: true` and `date: null` (`errors/400__itinerary_both_date_and_global.json` shows the XOR is enforced).
- **"Unscheduled":** a collection item with no itinerary row at all. In the seed, "Dove Lake Circuit" is in `locations[]` with a dated all-day visit on 2027-03-10 but has **no** itinerary row. The planner only shows rows.
- **One object can have several rows.** For example, a location placed on two days gets two rows with the same `object_id`.
- `start_datetime`/`end_datetime` on a row are copied from the linked object (`models.py` properties):
  - transportation: `date`/`end_date`
  - lodging: `check_in`/`check_out`
  - note/checklist: `date` (a **date-only** string like `"2027-03-07"`, so the type differs per row)
  - **location rows: always `null`**, because `Location` has no date fields. Get times from `location.visits[]`.
  - A field that is a datetime in one row can be a date in another, so decode `start_datetime` as a String and parse it based on `item.type`.

### Writes for the itinerary (all captured in `requests/` with matching `responses/`)
- **Place an item on a day:**
  `POST /api/itineraries/ {"collection", "content_type":"location", "object_id", "date":"2027-03-07", "order":3}` returns a 201 row.
  - Global form: `{"collection", "content_type", "object_id", "is_global":true, "order":0}`.
  - `date` must fall inside the collection's start/end range, otherwise 400 (`errors/400__itinerary_date_outside_collection.json`).
  - Optional `update_item_date: true` also moves the underlying object's dates to that day (it can create or modify a Visit for locations; see `itinerary_view.py`). The seed does not use it.
- **Reorder, or move between days:**
  `POST /api/itineraries/reorder/ {"items":[{"id","date","order"}, ...]}` returns 200 with the updated rows (a bare array).
  - To move to global: `{"id","is_global":true,"date":null,"order"}`. To move back: `{"id","is_global":false,"date":"YYYY-MM-DD","order"}`.
  - The web app sends **every row of every day plus every global row** each time (`saveReorderedItems`). Sending only the changed rows also works if the result keeps orders unique (see `requests/itineraries__reorder__d1_restore.json`).
  - The server writes in two phases to avoid constraint collisions (`adventures/utils/itinerary.py`).
  - Captured payloads:
    - swap within a day: `itineraries__reorder__d1_swap.json`
    - move D1→D2: `itineraries__reorder__move_note_d1_to_d2.json`
    - move back: `itineraries__reorder__move_note_back_to_d1.json`
    - to and from global: `itineraries__reorder__to_global.json`, `itineraries__reorder__from_global_back_to_d1.json`
  - An empty `items` list gives `400 {"items":"This field is required and must not be empty."}`. That error value is a string, not a list.
  - **Quirk:** reorder never changes the underlying object's own date. After moving the D1 note to D2 by reorder, `note.date` is still `2027-03-07`.
- **Remove from a day:** `DELETE /api/itineraries/{id}/`. For location rows this **also deletes the location's visits that start on that date** unless you add `?preserve_visits=true` (`itinerary_view.py` `destroy`).
- **Day metadata:** `POST /api/itinerary-days/ {"collection","date","name","description"}`, then `PATCH /api/itinerary-days/{id}/`. On PATCH, `collection` and `date` are silently ignored (`serializers.py` `CollectionItineraryDaySerializer.update`).
- Changing a collection's start/end dates **deletes** itinerary rows and day-meta outside the new range (`collection_view.py` `_cleanup_out_of_range_itinerary_items`).

## 6. Dates, times and time zones (observed)
- **The server has one convention:** every `DateTimeField` is stored and returned in **UTC with a `Z` suffix**: `"2027-03-06T03:10:00Z"`. Microseconds appear when they are non-zero, for example `created_at: "2026-10-11T01:08:01.590527Z"`, and also on user-supplied values that had them. Parse both `...SSZ` and `...SS.ffffffZ` (`settings.USE_TZ=True`, `TIME_ZONE='UTC'`).
- **The IANA zone is stored separately, as a display hint.** The server does no tz math with it.
  - Visit: `timezone`. Lodging: `timezone` (one zone for both check-in and check-out).
  - Transportation: `start_timezone` and `end_timezone`, one per endpoint.
  - The value must be one of `adventures/utils/timezones.py` `TIMEZONES`, otherwise 400 `"\"Mars/Olympus\" is not a valid choice."` (`errors/400__visit_bad_datetime.json`). All of these fields are nullable.
- **Writes accept any ISO-8601 with an offset or `Z`**, and are normalised to UTC. Example: the sunset cruise visit sent as `2027-03-08T18:30:00+11:00`, returned as `2027-03-08T07:30:00Z` (`responses/visits__create_response__cruise.json`).
  - A **naive** string (no offset) is treated as **UTC**: `"2027-03-13T09:00:00"` came back as `"2027-03-13T09:00:00Z"` (`utils/datetime_utils.py` `ensure_aware_utc`). Always send an offset or `Z`.
  - The web client converts the user's wall clock in the item's zone to UTC with `Z` and sends the zone name separately (`frontend/src/lib/dateUtils.ts` `toUTCDatetime`).
- **Date-line example** (`responses/transportations__detail.json`), EX7 LAX→SYD:
  - Departs 2027-03-05 19:10 America/Los_Angeles, stored `date: "2027-03-06T03:10:00Z"`, `start_timezone: "America/Los_Angeles"`.
  - Arrives 2027-03-07 05:00 Australia/Sydney, stored `end_date: "2027-03-06T18:00:00Z"`, `end_timezone: "Australia/Sydney"`.
  - `travel_duration_minutes: 770`.
  - To show local times, convert each endpoint with its own zone.
- **All-day convention:** an all-day value is **UTC midnight** (`T00:00:00Z`) on the calendar date. All-day visits use the same midnight for both start and end (`responses/locations__detail_allday_visit.json`; `utils/datetime_utils.py` `normalize_all_day_visit_dates`).
  - Older data can have an end of `T23:59:59Z`. The visit serializer normalises it to midnight when written.
  - The frontend checks all-day with `isAllDay` (regex on `T00:00:00(.0+)?(Z|+00:00)`) in `frontend/src/lib/index.ts`.
  - `TransportationSerializer.travel_duration_minutes` is `null` when both ends are midnight.
- **⚠ Midnight collision:** any timed event that happens to fall at exactly 00:00:00 UTC is treated as all-day by the server. In AEDT, 00:00Z is **11:00 local**.
  - The kayak tour visit (11:00 to 11:45 AEDT, so `2027-03-07T00:00:00Z` to `00:45:00Z`) comes back from `/api/calendar/events/` with `"all_day": true` (`responses/calendar__events_range.json`; `services/calendar_events.py` uses `is_midnight_utc(start)`).
  - The ICS export does the same.
  - The visit serializer only rewrites the end time if the end is also midnight or 23:59:59 (`normalize_all_day_visit_dates`).
  - The client should decide "all day" from **start and end both at midnight** (the frontend's `isVisitAllDay`), not from the start alone.
- **Date-only fields** are `"YYYY-MM-DD"` with no zone: `collection.start_date/end_date`, `note.date`, `checklist.date`, itinerary `date`, `itinerary_days[].date`. These are calendar dates in the trip's local sense. Do **not** convert them through UTC.
- `/api/calendar/events/` returns `{events:[...], count}`. Each event has `start`/`end` (UTC `Z` datetimes, or `YYYY-MM-DD` for notes, checklists and collections), plus `all_day`, `timezone`, `type`, `resource_id`, `collection_id` and `url` (a frontend path). Optional query params: `start`, `end` (YYYY-MM-DD) and `types` (comma list).
- `/api/ics-calendar/generate/` returns `text/calendar`. Timed events are written as UTC `DTSTART:20261212T220000Z`; all-day ones as `VALUE=DATE` (`responses/ics-calendar__generate.ics`).

## 7. Resource shapes and nullability (observed in fixtures)
- **Location** (`responses/locations__detail.json`):
  - Nullable: `description`, `rating` (Float), `tags` ([String]), `location` (address text), `link`, `latitude`/`longitude` (Float), `price`.
  - `price` is a **String decimal** (`"95.00"`) or `null`. `price_currency` is always present and defaults to `"USD"` even when `price` is null.
  - `category` is an object `{id,name,display_name,icon,num_locations}` and is never null: the server falls back to a per-user `general` category (`models.py` `Location.save`).
  - Write `category` as an object `{name, display_name, icon}`. The server reuses the user's category with the same (lowercased) name, or creates one.
  - `collections` is a [uuid] list and is writable.
  - `country`, `region` and `city` were `null` in every capture. Reverse geocoding happens in a background thread and needs Nominatim or Google, which the capture environment blocked. Expect real objects on an instance with network access.
  - `is_visited` is computed: true if any visit has started on or before today (`utils/get_is_visited.py`).
  - Arrays always present: `visits[]` (full Visit objects), `images[]`, `attachments[]`, `trails[]`.
- **Visit** (`responses/visits__detail.json`): `{id, location, start_date, end_date, timezone, notes, activities[], created_at, updated_at}`.
  - If `end_date` is omitted on create, it is set to `start_date`.
  - `PATCH /api/locations/{id}/` with `visits:[...]` **replaces every visit**. Use `/api/visits/` for single edits.
- **Transportation** (`responses/transportations__detail.json`):
  - `type` is one of `car|plane|train|bus|boat|bike|walking|other` (required).
  - Nullable: `flight_number`, `from_location`/`to_location` (text), `start_code`/`end_code`, the four `origin_*`/`destination_*` coordinates, both timezones, `collection`.
  - `distance` is computed in km (Float). It was `0.0` when origin equals destination, and is null without coordinates.
  - `travel_duration_minutes` is computed (Int?).
  - `price`/`price_currency` work as for Location.
- **Lodging** (`responses/lodging__detail.json`):
  - `type` is one of `hotel|hostel|resort|bnb|campground|cabin|apartment|house|villa|motel|other` (default `other`).
  - Fields: `check_in`/`check_out` (UTC), `timezone`, `reservation_number`, `price`/`price_currency`, `latitude`/`longitude`, `location` (address).
  - **Quirk:** the API accepts `check_out` earlier than `check_in` and returns 201 (`errors/quirk_201__lodging_checkout_before_checkin_accepted.json`), because `Model.clean()` is never called. The client must validate this itself.
- **Note** (`responses/notes__detail.json`): `content` is markdown text (nullable), `links` is [String] (nullable), `date` is `YYYY-MM-DD` or null.
- **Checklist** (`responses/checklists__detail.json`):
  - Each entry in `items[]` is `{id, user, name, is_checked, checklist, created_at, updated_at}`.
  - `items` is **required on create**, even if empty (`errors/400__checklist_missing_items.json`).
  - **Quirk:** a PATCH that includes `items` **replaces the whole set**. Items you leave out are deleted, and items without an `id` are created.
  - **Quirk:** item ids can change. The ids in the create response (`checklists__create_response__car_pickup.json`) were all different after the first PATCH, even though that PATCH sent those ids back. Probable cause: `ChecklistItemSerializer` does not declare `id` as writable, so the ids are dropped and every item is recreated (`serializers.py` `ChecklistSerializer.update`). After that PATCH, the ids in the response and in later GETs matched. Always use the ids from the latest response.
- **Collection list** (`responses/collections__list.json`, the "UltraSlim" serializer):
  - Fields: `id, user(uuid), name, description, is_public, start_date, end_date, is_archived, link, created_at, updated_at, location_images[], location_count, shared_with[], collaborators[], status, days_until_start, primary_image`.
  - `status` is `folder|upcoming|in_progress|completed`, computed from the server's local date.
  - `days_until_start` is an Int, or null if the trip has no start or has already started.
  - `link` is accepted as any string; invalid URLs are silently set to `null`.
- **Image** (`responses/images__detail.json`):
  - `image` is an absolute URL built from `PUBLIC_URL` + `/media/...`. Images are re-encoded to `.webp`.
  - Upload with `POST /api/images/` as `multipart/form-data`, fields `image` (file), `content_type` (one of `location|transportation|note|lodging|visit`) and `object_id`.
  - The `is_primary` form field is **ignored**. Use `POST /api/images/{id}/toggle_primary/`, which returns `{"success": ...}`, or 400 if the image is already primary.
  - Fetching the media URL needs `X-API-Key` for private content.
- **Errors** come in three shapes. Decode all of them leniently:
  - DRF validation: `{"field": ["msg", ...]}`
  - DRF exceptions: `{"detail": "msg"}`
  - hand-written errors: `{"error": "msg"}`
  - Some 400s use a plain string where DRF would use a list (`errors/400__reorder_empty.json`).

## 8. Permissions observed
- **Objects owned by another user and not shared:** the API returns **404**, not 403, for both GET and PATCH. The object is simply not in the querysets (`errors/404__other_users_private_location.json`, `errors/404__other_users_location_patch.json`).
- **403 cases:**
  - Linking someone else's object into an itinerary: `{"error":"User does not have permission to access this content"}`.
  - A shared user deleting the owner's location: `{"detail":"Only the owner can delete this location."}`.
  - `GET /api/notes/`.
- **Shared users** (guest, via `share/{uuid}/` then `accept-invite/`):
  - can read the collection (`responses/collections__detail__as_guest.json`, where `collaborators[].is_current_user` flips);
  - can create and edit items inside it. Items created by guest in admin's collection are **owned by the collection owner** (`perform_create` saves `user=collection.user` for transportation, note, checklist and lodging);
  - **must re-send `collection` when PATCHing** a transportation, lodging, note or checklist. If `collection` is missing from the body, the view treats it as None, reads that as "remove from collection", and returns 403 `{"detail":"You cannot remove the collection as you are not the owner."}`. With `collection` included, the PATCH returns 200 (`views/note_view.py` and the other views' `partial_update`; `errors/403__shared_user_patch_note_without_collection.json`, `responses/notes__update_as_shared_user_with_collection.json`). For the owner, a PATCH without `collection` is harmless. Safest: always include `collection`.
  - **cannot** PATCH the collection itself. That returns **404**, because the update queryset is owner-only (`errors/404__shared_user_patch_collection.json`).
  - Shared trips appear in `GET /api/collections/shared/`, **not** in `GET /api/collections/`, which lists only owned, non-archived trips.
- **Sharing needs the target user to have `public_profile=true`**, otherwise `share/{uuid}/` returns 404 (`collection_view.py` `share`). User uuids come from `GET /auth/users/`, which lists public users only.

## 9. Other server quirks
- `POST` to an action with no body is fine (`share`, `accept-invite`, `toggle_primary`).
- `GET /api/tags/` returns 404. The real route is `/api/tags/types/`.
- `GET /api/checklists/` and `/api/transportations/` and `/api/lodging/` list only objects **owned** by the caller, so items in trips shared with you don't appear. Read shared items through the collection detail.
- `/api/visits/` lists visits for locations you own **or** that sit in collections you own or share.
- Swagger (`openapi/swagger.json`) is drf_yasg **Swagger 2.0**:
  - it describes `Basic` auth only, so ignore that and use the API key;
  - many request and response schemas are generic or wrong (for example, `reorder` claims it takes a single item and returns 201);
  - fetch it with `Accept: */*` or `application/openapi+json`. With `Accept: application/json` it returns **406**.
  - Treat the fixtures as the source of truth, not the spec.
- DRF's own OpenAPI generator (`manage.py generateschema`) **crashes** on this codebase with `AttributeError: 'NoneType' object has no attribute 'query_params'` in `CollectionViewSet.get_serializer_context`, so no DRF-native schema was captured.
- `/api/search/?q=` returns `{query,total,limit,offset,results:[{type,id,title,subtitle,url,score,meta}],facets}`. It also takes `types`, `limit` and `offset` (`views/global_search_view.py`). The `url` in each result is a frontend path.

## 10. Fixture layout
- `requests/<resource>__<create|update|reorder|share|accept_invite|toggle_primary>__<slug>.json`: `{method, path, body}` exactly as sent by `seed.py`.
- `responses/<resource>__<action>_response__<slug>.json`: `{status, body}` for each of those writes.
- `responses/<resource>__<list|detail|...>.json`: raw GET bodies. `responses/_meta.json` records method, path, status, content type and which identity was used (admin, guest, bad-key or none) for every GET and error capture.
- `errors/`: raw bodies for the 400, 401, 403 and 404 cases and the pagination examples. File names start with the HTTP status. One file starts `quirk_201__` because the server wrongly accepted the request.
- `openapi/swagger.json`.
- `seed_state.json`: the ids of everything the seed created.

## 11. Regenerating against another instance (e.g. homelab)
With a second user (Guest), for the sharing and permission fixtures:
```bash
BASE_URL=https://adventurelog.example API_KEY=al_... GUEST_API_KEY=al_... GUEST_USERNAME=guest \
  FIXTURES_DIR=/tmp/fx python3 seed.py        # creates the trip via REST only (stdlib, py3.9+)
BASE_URL=https://adventurelog.example API_KEY=al_... GUEST_API_KEY=al_... \
  FIXTURES_DIR=/tmp/fx python3 capture.py
```
Single user only (the Guest fixtures are skipped and keep their existing files):
```bash
BASE_URL=https://adventurelog.example API_KEY=al_... FIXTURES_DIR=/tmp/fx python3 seed.py
BASE_URL=https://adventurelog.example API_KEY=al_... FIXTURES_DIR=/tmp/fx python3 capture.py
```
- `seed.py` is not idempotent. Each run creates a new trip.
- `capture.py` checks every capture's status against the status in its file name (200 unless the name starts with one, e.g. `404__`; `notes__list` expects 403). A mismatch leaves that fixture untouched and the script exits 1 instead of printing `done`.
- `seed.py` and `capture.py` were checked against a second, freshly migrated database on port 8001: both completed with the same statuses.
- `capture.py` creates a throwaway private location for the second user and a throwaway bad lodging, and deletes both again.
