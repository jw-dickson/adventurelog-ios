# Build plan

The app is built in stages. Each ends in something that runs in the Simulator and passes its exit checks in CI; screens are reviewed against the design system before they are coded and again on real renders.

| Stage | Delivers | Exit checks |
| --- | --- | --- |
| **0 · Foundations** | Repo, XcodeGen project, `AdventureLogKit` (models, client, time rules, trip assembly), `ALStore` (Keychain, offline snapshots), `ALDesign` (generated tokens), fixtures from a real server, CI | Package tests green; app launches to sign-in in the Simulator; hosted CI green on a PR |
| **Design review 1** ✅ | Mockups of every MVP screen built from design-system components ([`Design/review-1`](../Design/review-1/README.md)) | Signed off 11 Oct 2026 |
| **1 · Read-only offline client** | Sign-in, trip list (owned and shared), day timeline, item detail, trip-wide notes and checklists, map with pins, offline pack | Browse a seeded trip with the network off; snapshot tests light, dark and Dynamic Type XXL |
| **2 · Today, editing, sync** | Today tab, checklist ticks, note edits, reorder and move between days, outbox with retry, conflicts, shared-trip rules | Offline edits reach the server on reconnect; two Simulators on one trip converge |
| **Design review 2** ✅ | Simulator snapshot gallery beside the mockups ([`Design/review-2`](../Design/review-2/README.md)) | Signed off 11 Oct 2026; first TestFlight build |
| **Editing items** *(issue #22, [`Design/editing`](../Design/editing/README.md))* | Notes, times and details of places, journeys and stays; quick timestamped notes; new notes on a day; remove from a day | Item edits made offline reach the server; a clash on one field asks without losing the others |
| **3 · Reminders and tracking** *(3a reminders, 3b tracking)* | Leave-by and heads-up reminders, rolling geofence window, background tracking, stop detection, plan vs actual on the phone (server write-back decided later), GPX capture, the Log tab | A replayed drive fires the right reminders in the trip's zone and detects the planned stops |
| **4 · Companion service and Live Activities** *(optional module)* | Self-hosted companion: device registration, APNs, track ingest, fixed/flexible flags; Live Activities for connections and booked tours | `simctl push` payloads render every state; a server push reaches a TestFlight build |
| **5 · Replan assistant** *(optional module)* | Proposes a revised day around booked items; the user accepts, edits or dismisses | Golden scenarios produce valid proposals; a UI test accepts one end to end |
| **Design review 3, freeze** | Full-app review | Fixes only after this point |
| **6 · Photo export** *(optional module)* | Per-day GPX and XMP keywords for Lightroom Classic | Round-trip on a sample catalogue |

## How Stage 2 syncs

Edits are kept on the phone first and sent when the server can be reached: a ticked checklist item, a note's new text, a row moved to another position or day. Skipping something on Today stays on the phone.

- **The saved copy is always the server's.** Unsent edits live in an outbox next to it (`ALStore/DeviceStateStore`), and what the app shows is the saved copy with the outbox replayed on top. A refresh can't overwrite an unsent edit.
- **Edits are intents, replayed when sent.** Each edit is re-applied to the server's current copy just before it is sent (`AdventureLogKit/Sync/EditSender`), so two phones don't undo each other:
  - A tick fetches the checklist, changes that one item and saves the whole list. AdventureLog replaces every item on each save and gives each a new id, so items are found by name and position, not id. Items added elsewhere in the meantime survive.
  - A move fetches the trip's rows, puts the row at its place among the rows the server has now, and sends only the rows whose order or day changed.
  - A note edit remembers the text it started from. If the server's text is still that, it is saved. If someone else changed it, the person chooses which version to keep.
- **In order, with retry.** Edits go one at a time, in the order they were made. A send that fails because the server can't be reached waits 5 s, then 10, 20… up to 5 minutes. It goes again as soon as the network comes back, the app comes to the front, or the person pulls to refresh. An edit whose item was deleted elsewhere is dropped with a notice; if it was note text, the text can be copied. The server refusing an edit is listed for a retry or discard.
- **Shared trips.** Every PATCH carries the trip's `collection`, which AdventureLog requires from collaborators. Collaborators can tick, edit notes and reorder like the owner. Changing the trip itself (name, dates, sharing) stays with the owner and isn't in the app.
- **Converging.** After sending, the app fetches the trip again. It also refreshes the open trip every two minutes while it's on screen, and when the app comes to the front, so a second phone's changes show up.

## How item edits sync

Item edits use the same outbox as Stage 2 (above): saved on the phone, replayed onto the server's current copy when sent.

- **Fields remember where they started.** An edit to a place, journey or stay carries each changed field's starting value and new value (`TripEdit.EditItem`). When it's sent, a field the server still has at its starting value is saved; one that already has the new value is done; one someone else changed is a clash. The fields that don't clash are saved straight away, and the person picks *Keep mine* or *Keep server's* for the rest.
- **A place lives in two objects.** Its name, address, link and general notes are on the location; the times and notes for this trip's visit are on the visit, which is edited with `PATCH /api/visits/{id}/`. A PATCH to the location never sends `visits`, which would replace every visit.
- **Quick notes never clash.** *Add a note* appends a line stamped with the time in the item's zone (`TripEdit.AppendNote`). When sent, it goes after whatever the server's notes say; sending it twice doesn't add it twice.
- **New notes have a local id until they're sent** (`local-…`). Editing, moving or removing one before it's sent changes what will be added instead of queueing an edit the server couldn't apply. Sending creates the note and then its row at the end of the day; a resend after a lost answer finds the note it already made.
- **Removing from a day** deletes the row with `preserve_visits=true`, so a place keeps its visit and moves to Not on a day.
- **Collaborators** can edit items like the owner; every journey and stay PATCH carries `collection`. The trip itself (name, dates, sharing) stays out of the app.
- **Not yet:** adding places (needs place search), photos and attachments.

## How Stage 3 reminds

Reminders are worked out on the phone from the trip's plan (`AdventureLogKit/Trip/Reminders.swift`), so they arrive with no signal. Each one is a local notification at a UTC instant, so it fires at the right moment in whatever zone the phone is in, and its text shows times in the item's own zone.

- **Leave by:** for a timed place, stay or leg, counted from the previous stop that day.
  - Travel time is the straight-line estimate Today uses: 1.3× the distance at 50 km/h, rounded up to 5 minutes.
  - On top of that comes a buffer: 5 minutes, 10 for booked items, 90 at the airport for flights.
  - There's no leave-by when the previous stop is within 300 m.
- **Heads-up:** before something starts. The default is 15 minutes, an hour for booked items and three hours for flights; all three can be changed. A heads-up within 10 minutes of the leave-by is dropped.
- **A rolling window:** only the next 48 hours, at most 60 reminders across every saved trip, because iOS keeps 64 pending per app.
  - The window is recalculated whenever a trip changes, a row is skipped or the app comes to the front.
  - A background refresh every few hours does the same and fetches the trip again.
  - Each reminder's id includes its time, so a moved reminder replaces the old one.
- **Turning them on:** reminders are off until the person turns them on, from Today's offer or the account menu, which asks for notification permission. The settings stay on the phone.

## How Stage 3 tracks

Tracking is off until the person agrees, once per trip, from Today's offer or the switch on the Log tab. After that it runs only on that trip's days. Everything it records stays on the phone: it is never sent to the server, it is excluded from backups and it is deleted on sign-out.

- **Recording** (`App/Sources/LocationTracker.swift`): iOS's live location updates with a background activity session, so "While Using" permission is enough and iOS shows the location indicator while it runs. A point is kept when the phone has moved 25 m or a minute has passed, and points less accurate than 100 m are dropped. Points are written in batches to an append-only file per trip (`ALStore/TrackStore`).
- **Geofences:** the day's places and stays still to come, at most 15 of iOS's 20, each with a 150 m circle (250 m for a stay). Journeys aren't watched, because their ends are other places. Arriving and leaving are recorded as events; the list is recalculated when the trip changes or a row is skipped.
- **Stopping:** recording stops when the trip has no day today (the first point after midnight on the last day stops it), when the person turns it off, or when location permission is refused.
- **Stops** (`AdventureLogKit/Tracking/Track.swift`): a stop is at least 5 minutes within 80 m. A gap with no points at walking pace or slower, like a parked car the phone stopped reporting from, still counts as staying.
- **Plan vs what happened** (`AdventureLogKit/Tracking/TripLog.swift`):
  - A geofence event is the most direct evidence. Otherwise a place or stay is visited by the nearest stop in time within its circle.
  - A journey is done when the phone left a stop near its start and later stopped near its end; its time is the time on the road.
  - More than 10 minutes after the planned start is late. An hour after the start with no visit is missed. Skipped rows show as skipped.
  - A stop of 10 minutes or more that matches nothing in the plan shows as an unplanned stop.
- **The Log tab:** Today (or a day picked from Trip) shows distance driven against the plan's ground travel, how much of the plan was done, and each item with its planned and actual times. Trip lists every day so far. GPX exports the route for a day or the trip, one segment per day, with visited and unplanned stops as waypoints. The Map tab draws the day's route over the planned line.

## How Stage 4 shows Live Activities

Stage 4a runs on the phone alone; 4b adds the companion service in `Companion/` (Python, FastAPI), which sends pushes.

- **What gets one:** a flight, from three hours before departure, and a booked tour (a place tagged booked, fixed or reserved), from an hour before it starts. When two overlap, the sooner one wins. Skipped rows get none. The choice is `LiveActivityPlanner` in AdventureLogKit.
- **What it shows** (Design/review-1, 09): "Connection · SYD" when the flight follows another flight into the same airport, else "Flight · DEN" or "Booked tour"; the title ("EX 1501 to Hobart"); the first line of the notes; and a countdown in system timer text, so it ticks without updates. A flight counts down to boarding (45 minutes before departure), then to departure. A three-part bar fills in ochre over the wait. It always uses the dark live palette.
- **When it starts and ends:** iOS only lets an app start a Live Activity while it's open. So it starts when AdventureLog is open, or running for tracking, inside the window. It updates, and ends at departure or at the tour's start, whenever the app runs, including background refresh. Push-to-start from the companion (4b) removes the need to open the app.
- **Pushes:** the content state is `LiveActivityState`, with times as Unix seconds. A push can set a note ("Gate 23", "Delayed 25 min"), move the times, mark it cancelled, or end it. When the phone recalculates it keeps a pushed note, and it never lifts a cancellation. `Fixtures/live-activity/` has a payload for every state.
- **Turning it off:** Reminders has a Live Activities switch, and iOS has its own in Settings.
- **The companion (4b):** set its address in Reminders. The phone registers with the AdventureLog API key it already holds, plus iOS's push-to-start token, and hands over each activity's push token. Every five minutes the companion reads that person's current trips from AdventureLog and works out the same activity with a Python port of the planner (`Companion/companion/planner.py`); both versions are tested against the synthetic trip. It starts the activity by push when the window opens, so the app needn't be opened. It updates it when the times change or boarding starts, and ends it at departure. Sign-out unregisters the phone before the key is revoked. Setup is in `Companion/README.md`.

## Testing without a device

Every outside dependency comes through a protocol the tests replace: the network (a stub server and real fixtures), the clock (`-ALNow`), Core Location (recorded GPX replayed in tests and with `simctl location`), and push (`simctl push` payloads). Physical-device checks (background wake-ups, battery, cellular push) happen on TestFlight builds from design review 2 onward.

## CI

- `ci.yml` — GitHub-hosted macOS, no secrets.
  - Every pull request push and every push to main: tokens check and package tests.
  - Every pull request and push: the companion service's tests, on Linux.
  - Pull requests with changes outside `docs/`, `Design/`, `Companion/`, `*.md` or `LICENSE`: Simulator UI tests on one Simulator, in a job beside the package tests. (Two at once was tried: on the hosted runners each cloned Simulator took minutes per test.) A push to main skips them, because the pull request already ran them on that code.
  - The screenshot gallery (light, dark, XXL) runs only on request: Actions › ci › Run workflow with "Capture the screenshot gallery" ticked, or `make gallery` on a Mac.
- Self-hosted work (nightly full Simulator suite against a live test server, and TestFlight uploads) lives in the maintainer's private repository, which checks out this one. Nothing here can trigger code on the maintainer's machine.

