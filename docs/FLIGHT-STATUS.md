# Live flight status: design note (#23)

A flight's Live Activity knows only what is typed into AdventureLog: the scheduled times and the flight number. This note looks at feeding it real status (delays, gate changes, boarding, cancellations) and recommends how. Prices and terms were checked on 12 Oct 2026 and change often, so check them again before relying on them.

## Recommendation

- **Run it in the companion.** It already polls every few minutes, holds the keys, and pushes `update` and `end` to the activity. The phone can't poll while it's closed, and iOS gives an app no background time on a timer.
- **Two providers behind one small interface.** Turn it on with `FLIGHT_STATUS_PROVIDER` and `FLIGHT_STATUS_API_KEY`. With no key, nothing is looked up and everything behaves as it does today.
  - **FlightAware AeroAPI, Personal tier**, as the default suggestion for a self-hoster. It has no monthly minimum and gives a free monthly allowance (up to $5), which a trip's flights stay well inside. Its terms allow personal use, which fits someone running their own companion with their own key.
  - **AeroDataBox** as the alternative. It's cheap, with gate, terminal and revised times in its flight status. Its free tier is for non-commercial use with attribution; paid plans start at a few dollars a month.
- **Overlay only. Nothing is written back to AdventureLog.** The plan stays the plan (see below).
- **Only flights in their Live Activity window are looked up** (from three hours before departure until arrival), with a monthly cap.

## Providers compared

| | FlightAware AeroAPI | AeroDataBox | Aviationstack | Free ADS-B (OpenSky) | Flighty |
| --- | --- | --- | --- | --- | --- |
| What it gives | Scheduled, estimated and actual gate and runway times, delays, status, gates and terminals, codeshares | Scheduled, revised and predicted times, status, gate, terminal, check-in desk, baggage belt | Status and schedules | Live positions only: no schedules, gates or delays | An app, not a data source |
| Cost to a self-hoster | Personal tier: no minimum, up to $5 a month free, then per result set. A forum post from Nov 2025 says flight lookups were billed at $0.005 each, against $0.001 in the docs | Free (RapidAPI, 400 units a month, non-commercial, attribution); Pro about $8 a month for 5,000 units; endpoints cost 1, 2 or 6 units by tier | Free 100 requests a month (non-commercial); then $49.99 a month | Free, non-commercial | — |
| Terms | Personal tier: "personal or academic purposes only". Alerts (pushed changes) need Standard, at a $100 a month minimum | Caching for 7 days on lower plans; no reselling | Free plan for personal use | Non-commercial | No API. Calendar Export keeps a calendar event's time and gate up to date |
| Fit | Best data, free in practice for one person | Cheapest paid option; gate data depends on the airport | Too dear for what it adds | Could show "in the air" later; not needed now | See below |

**Why not Flighty.** Flighty has no API, and on iOS one app can't read another's data. Its Calendar Export does keep each flight's calendar event current, including the time and gate. The phone could read that with calendar permission (EventKit), but only while the app runs, so it can't move a Lock Screen countdown while the app is closed. It's worth noting as a free, phone-only extra later. It isn't the feed.

**Why not Wallet boarding passes.** An app can only read passes of its own pass types. An airline's `.pkpass` isn't readable.

## How it would work

### Matching a flight

AdventureLog's journey has `flight_number` ("EX101"), `start_code` (the origin's IATA code), `date` (departure, UTC) and `start_timezone`. To match:

1. Tidy the number: upper case, no spaces, no leading zeros after the airline code ("ex 0101" → "EX101"). Two-character airline codes are IATA, three are ICAO; both providers look up either.
2. Ask the provider for that number on the local departure date at the origin.
3. Pick the leg whose origin IATA code is `start_code` and whose scheduled departure is within 6 hours of AdventureLog's. That handles multi-leg flight numbers and a plan that's slightly off.
4. Codeshares: both providers answer a marketing number with the operating flight. Keep whatever the provider calls the operating flight for the note ("Operated by …" isn't needed on the Lock Screen).
5. No match (not yet scheduled, a typo, a charter): store "not found" for that flight and day, try again at most every hour, and change nothing. The activity runs as it does today.

Cache results by `(provider, flight number, local date)`, so two people on the same flight cost one lookup.

### When to ask

| From | To | Every |
| --- | --- | --- |
| 3 h before departure (window opens) | 1 h before | 15 min |
| 1 h before | estimated departure | 5 min |
| Departure | estimated arrival | 30 min, to catch a diversion or the landing |

If the answer hasn't changed three times running, double the gap, but never past 15 minutes in the last hour. Stop at landing, or at the activity's end, or when the flight is cancelled. `FLIGHT_STATUS_MONTHLY_LIMIT` (300 by default) caps lookups. At 90% of the cap only the last hour is polled, and at 100% nothing is.

**Volume:** about 8 + 12 + 4 ≈ 24 lookups a flight. A trip with six flights is about 150 lookups.
- **AeroAPI:** at the $0.005 billed in that forum post, about $0.75, inside the free $5.
- **AeroDataBox:** the flight-status endpoint's tier isn't stated on its pricing page. At 2 units a lookup it would be about 300 units: inside the free 400 for one trip a month, and comfortably inside Pro.

### What changes on the Live Activity

`LiveActivityState` already has what's needed (`phase`, `target`, `departure`, `note`), and `Fixtures/live-activity/` already has delayed, boarding and cancelled payloads.

| Provider says | Pushed state | Alert |
| --- | --- | --- |
| Estimated departure later by 15 min or more | `departure` = estimated departure; `target` = it minus the boarding lead (45 min); note "Delayed 25 min" plus the gate if known | "EX 1501 delayed", once per change of 15 min or more |
| Earlier again (delay cut) | Times move back, never before the schedule | Only if it moves by 15 min or more |
| Gate or terminal known or changed | Note "Gate 23" (or "Terminal 3 · Gate 23") | On a change after one was known |
| Boarding (AeroDataBox status, or AeroAPI's estimated gate departure under 45 min away) | `phase` boarding | "EX 1501 is boarding" |
| Cancelled | `phase` cancelled, note "Cancelled" | Yes. The activity stays until the scheduled departure plus an hour, then ends |
| Departed (actual gate or runway departure) | End | No |
| Diverted | Note "Diverted to …" until it ends | Yes |

**A change on the phone is needed too.** Today the phone keeps a pushed note but puts back its own times, and it ends the activity at the scheduled departure. With live status it has to keep a pushed later `departure` and `target`, and keep the activity until the pushed departure (`LiveActivityController.show`, and the companion planner's `end`). Without that, a delayed flight's countdown would jump back to the schedule whenever the app opens.

### Why overlay only

- AdventureLog holds the plan: what was booked. Estimates move every few minutes, and writing each one back would fill the trip's history and fight with edits made on the phone or the web (the outbox's conflict checks would see the server change under them).
- The Log already compares plan with what happened from the phone's route. Actual departure and arrival times from the provider could be kept for the Log later, on the companion.
- Overlaying is reversible: turn the key off and nothing in the trip has changed.

### Config

| Variable | |
| --- | --- |
| `FLIGHT_STATUS_PROVIDER` | `aeroapi` or `aerodatabox`. Unset: no lookups. |
| `FLIGHT_STATUS_API_KEY` | The provider's key (AeroAPI's `x-apikey`, or AeroDataBox's RapidAPI or direct key). |
| `FLIGHT_STATUS_MONTHLY_LIMIT` | Lookups a month, 300 by default. |

`GET /healthz` gains `"flightStatus": true`, so Reminders can say what the companion adds.

### Testing

- **Recorded answers, never live calls, in CI:** hand-written JSON in each provider's shape for the synthetic trip's flights ("EX 1501", "EX 7"), covering on time, delayed, gate change, boarding, cancelled, diverted and not found.
- **Golden tests:** provider answer → `LiveActivityState`, and the same payloads as `Fixtures/live-activity/` where they overlap.
- **Budget tests:** the schedule above for a flight produces the expected number of lookups, the cap holds, and no key means no lookups.
- **On a device:** a test trip with a real flight a few hours out, as for Live Activities in Handoff 7.

## Not now

- Pushed alerts from the provider (AeroAPI alerts need the $100 a month tier; AeroDataBox's Flight Alert API needs a public webhook to the companion). Polling inside the window is cheap enough.
- Positions in the air (ADS-B), and inbound-aircraft delay prediction.
- Reading Flighty's calendar events on the phone.

## Sources

- [FlightAware AeroAPI tiers](https://www.flightaware.com/commercial/aeroapi/)
- [AeroAPI billing thread, Nov 2025](https://discussions.flightaware.com/t/aeroapi-billing-actual-vs-documentation/99742)
- [AeroDataBox pricing](https://aerodatabox.com/pricing) and [Flight Alert API](https://aerodatabox.com/flight-alert-api-2026/)
- [Aviationstack pricing](https://aviationstack.com/pricing)
- [Flighty Calendar Export](https://flighty.com/help/calendar-export)
