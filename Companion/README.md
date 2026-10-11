# AdventureLog companion

A small self-hosted service that sends the AdventureLog iOS app its Live Activity pushes:

- **Starts** the Live Activity for a flight (three hours before departure) or a booked tour (an
  hour before), so it appears on the Lock Screen without opening the app.
- **Updates** it when the times change in AdventureLog, and when boarding starts.
- **Ends** it at departure, or when the item is skipped, moved or deleted.

It decides what to show with the same rules as the app (`companion/planner.py`, a port of
`LiveActivityPlanner`; both are tested against the same synthetic trip). It keeps no trip data: it
reads the trips from AdventureLog on every pass.

## How the phone talks to it

The phone authenticates with the AdventureLog API key it already holds (`X-API-Key`). The
companion checks the key against the AdventureLog server it's configured for, so there are no
separate accounts, and it keeps the key to read that person's trips.

| Call | What it does |
| --- | --- |
| `POST /v1/devices` | Registers the phone: `{"environment": "production" or "sandbox", "startToken": "…"}`. The start token is the app's Live Activity push-to-start token. |
| `PUT /v1/activities` | Gives the companion a running activity's push token: `{"tripID", "rowID", "pushToken"}`. |
| `DELETE /v1/devices` | Unregisters the phone (the app does this on sign-out). |
| `GET /healthz` | `{"ok": true, "pushes": true}` when APNs is configured. |

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
| `COMPANION_DB` | The SQLite file, `/data/companion.sqlite` by default. It holds each phone's API key: keep the volume private. |
| `COMPANION_POLL_SECONDS` | How often it checks, 300 by default. |

Builds from Xcode push through Apple's sandbox, and TestFlight and App Store builds through
production. The app says which when it registers.

## Developing

```bash
cd Companion
pip install -e '.[test]'
pytest
```
