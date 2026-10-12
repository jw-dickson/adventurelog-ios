# AdventureLog companion

A small self-hosted service that sends the AdventureLog iOS app its Live Activity pushes:

- **Starts** the Live Activity for a flight (three hours before departure) or a booked tour (an
  hour before), so it appears on the Lock Screen without opening the app.
- **Updates** it when the times change in AdventureLog, and when boarding starts.
- **Ends** it at departure, or when the item is skipped, moved or deleted.

Two optional modules: replan asks to Claude (Stage 5b), and photos to the trip (Stage 6), which
matches raw photos in Immich to the trip's stops and writes the stop into each photo's XMP sidecar
for Lightroom Classic and Immich to read. See [Photos to the trip](#photos-to-the-trip).

It decides what to show with the same rules as the app (`companion/planner.py`, a port of
`LiveActivityPlanner`; both are tested against the same synthetic trip). It reads the trips from
AdventureLog on every pass and keeps no trip details; its database holds each phone's API key and
push tokens, and for each Live Activity the trip and item ids and the last state it sent.

## How the phone talks to it

The phone authenticates with the AdventureLog API key it already holds (`X-API-Key`). The
companion checks the key against the AdventureLog server it's configured for, so there are no
separate accounts, and it keeps the key to read that person's trips.

| Call | What it does |
| --- | --- |
| `POST /v1/devices` | Registers the phone: `{"environment": "production" or "sandbox", "startToken": "…"}`. The start token is the app's Live Activity push-to-start token. Answers `{"id", "canStart"}`: `canStart` says whether it holds a start token, so it can start activities while the app is closed. A registration without a token keeps the one already held. |
| `PUT /v1/activities` | Gives the companion a running activity's push token: `{"tripID", "rowID", "pushToken"}`. |
| `DELETE /v1/devices` | Unregisters the phone (the app does this on sign-out). |
| `POST /v1/replan` | Optional (Stage 5b): the replan sheet's "Ask for a different plan". Body: `{"situation", "ask", "proposal", "tripDays"}`, the phone's `Replan.Situation` and proposal with times as ISO-8601. Answers a proposal in the same format, from Claude, which the phone checks before showing. `503` when Claude isn't set up, `429` past the hourly limit, `502` when Claude fails. |
| `GET /v1/trips/{id}/photos` | Optional (Stage 6): the trip's photo setting and what's been matched, by day: `{"enabled", "cameraOffsetMinutes", "lastRun", "lastError", "days": [{"date", "photos", "undone", "failed", "stops": [{"title", "photos"}]}]}`. A stop with an empty title is the day's photos taken between stops. `503` when photos aren't set up, `404` when the key can't see the trip. |
| `PUT /v1/trips/{id}/photos` | Turns photos on or off for the trip: `{"enabled", "cameraOffsetMinutes"}`. The offset (−1440 to 1440) is added to the camera's times, for a clock that ran slow (positive) or fast. Answers the same as `GET`. |
| `POST /v1/trips/{id}/photos/undo` | Puts back a day's sidecars and unlinks its photos: `{"date": "2027-03-08"}`. Answers `{"restored", "kept"}` and the `GET` summary. A photo whose sidecar changed since the companion wrote it is kept as it is. Undone photos aren't matched again. |
| `GET /healthz` | `{"ok": true, "pushes": true, "replan": true, "photos": true}`: `pushes` when APNs is configured, `replan` when Claude is, `photos` when Immich and the library are. |

Push payloads match `Fixtures/live-activity/` at the repository root: `content-state` is the app's
`LiveActivityState`, with times in Unix seconds.

## Running it

It runs as one container next to AdventureLog. Put it behind the same reverse proxy, on HTTPS.

```yaml
services:
  adventurelog-companion:
    image: adventurelog-companion   # docker build -f Companion/Dockerfile -t adventurelog-companion .
    restart: unless-stopped
    environment:
      ADVENTURELOG_URL: https://adventurelog.example.com
      APNS_KEY_PATH: /run/secrets/apns.p8
      APNS_KEY_ID: <key id>
      APNS_TEAM_ID: <team id>
      APNS_BUNDLE_ID: <the app's bundle id>
    secrets: [apns.p8]
    volumes:
      - companion-data:/data
secrets:
  apns.p8:
    file: ./apns.p8
volumes:
  companion-data:
```

| Variable | |
| --- | --- |
| `ADVENTURELOG_URL` | The AdventureLog server whose keys it accepts and whose trips it reads. It needs to reach `/api/` and `/auth/` with an API key. |
| `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID` | An APNs auth key (`.p8`) from the Apple Developer account. Without them it runs but sends nothing. |
| `APNS_BUNDLE_ID` | The app's bundle id; pushes go to `<bundle id>.push-type.liveactivity`. |
| `ANTHROPIC_API_KEY` | Optional. With it, replan asks go to Claude (Anthropic's API, billed to this key). Without it the phone hides the ask box; its own replan works either way. |
| `ANTHROPIC_MODEL` | Optional; the default is `claude-sonnet-5-5`. |
| `COMPANION_REPLAN_ASKS_PER_HOUR` | Optional; asks allowed per person per hour, 20 by default. |
| `COMPANION_DB` | The SQLite file, `/data/companion.sqlite` by default. It holds each phone's API key: keep the volume private. |
| `COMPANION_POLL_SECONDS` | How often it checks, 300 by default. |

| `IMMICH_URL`, `IMMICH_API_KEY` | Optional (Stage 6), with the three below. The Immich server holding the photos, and an API key with `asset.read`, `job.create`, `album.create`, `album.read`, `albumAsset.create` and `albumAsset.delete`. |
| `PHOTO_PATHS` | Where the photo library is mounted: `immich-path=companion-path`, several separated by `;`. For example `/mnt/photos=/photos` when Immich sees the library at `/mnt/photos` and the companion has it mounted read-write at `/photos`. The companion writes only under these folders. |
| `CAMERA_ZONE` | The zone the camera's clock is set to, such as `Europe/London`, for photos whose EXIF has no time zone. Leave the camera on home time while travelling. |
| `PHOTO_BACKUPS` | Optional; where the original of each changed sidecar is kept, `/data/sidecar-backups` by default. |
| `PHOTO_LINKS_PER_STOP` | Optional; how many of each place's photos are shown on it in AdventureLog, 3 by default. |

Replan asks send Anthropic the rest of that day's plan (titles, times, places, which items are
booked) and the words typed. Nothing about the ask is stored on the companion.

Builds from Xcode push through Apple's sandbox, and TestFlight and App Store builds through
production. The app says which when it registers.

## Photos to the trip

Turned on per trip from the app (Stage 6b) or with `PUT /v1/trips/{id}/photos`. On each pass, for
each trip that's on, the companion:

1. Asks Immich for the trip's photos, a couple of days either side of its dates. Only raw files
   (ARW, CR3, NEF, DNG, RAF and the rest) are used; phone photos and JPEGs are left alone.
2. Works out when each was taken. A photo whose EXIF has a time zone uses it. Otherwise the
   camera's clock is read in `CAMERA_ZONE`, plus the trip's camera offset.
3. Matches it to the trip: a place during its visit, a journey while it's under way, a stay only
   in the two hours after check-in and before check-out, give or take 15 minutes. Anything else
   in the trip's dates goes to its day. Hires and passes longer than a day aren't stops.
4. Adds to its sidecar, `IMG_0001.xmp` beside `IMG_0001.ARW` (Lightroom Classic's name; made if
   there isn't one):
   - keywords in `dc:subject`: Trips, the trip, the day, the stop, its category and place;
   - a keyword path in `lr:hierarchicalSubject` (`Trips|Tasmania Road Trip 2027|2027-03-08 · D2 · Hobart → Freycinet|Wineglass Bay Lookout`) and the same in Immich's `digiKam:TagsList`;
   - the place's name, city, region and country, and its position, where the file has none.

   Everything else in the file is kept as it was, including Lightroom's develop settings. If
   Immich has its own `IMG_0001.ARW.xmp`, that gets the same additions.
5. Tells Immich to read the sidecars again (`refresh-metadata`), puts the photos in an album
   named after the trip, and shows three of each place's photos on it in AdventureLog, spread
   across the visit. AdventureLog shows them through its own Immich integration, so that has to
   be set up in AdventureLog's settings, pointing at the same Immich.

**Safety.** The first time a sidecar is changed, a copy of it is kept under `PHOTO_BACKUPS`. Files
are replaced whole, keeping their permissions. The companion never follows a symlink, never writes
outside `PHOTO_PATHS`, and never changes the photos. A sidecar it can't read as XMP is left alone
and the photo is listed as failed. Undo puts a day back from the copies, unless a file has
changed since the companion wrote it.

**Lightroom Classic.** Lightroom keeps metadata in its catalogue, and only reads a sidecar when
asked. Read Metadata from Files replaces the catalogue's metadata, develop settings included,
with the file's. So before turning photos on for a trip:

1. In Lightroom Classic, turn on Catalog Settings › Metadata › **Automatically write changes into
   XMP**, or select the trip's photos and choose Metadata › **Save Metadata to Files**. Then the
   sidecars hold your current edits, and the companion keeps them.
2. After a pass, select the trip's photos and choose Metadata › **Read Metadata from Files**. The
   keywords show up under Trips in the Keyword List.

Run the companion as the user that owns the library (Compose's `user:`), so new sidecars belong
to that user too; the data volume then needs to be writable by that user.

```yaml
    user: "<library owner's uid>:<gid>"
    environment:
      IMMICH_URL: https://immich.example.com
      IMMICH_API_KEY: <key>
      PHOTO_PATHS: /mnt/photos=/photos
      CAMERA_ZONE: Europe/London
    volumes:
      - companion-data:/data
      - /path/to/lightroom/library:/photos     # read-write
```

## Developing

```bash
cd Companion
pip install -e '.[test]'
pytest
```
