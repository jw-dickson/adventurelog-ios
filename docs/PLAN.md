# Build plan

The app is built in stages. Each ends in something that runs in the Simulator and passes its exit checks in CI; screens are reviewed against the design system before they are coded and again on real renders.

| Stage | Delivers | Exit checks |
| --- | --- | --- |
| **0 · Foundations** | Repo, XcodeGen project, `AdventureLogKit` (models, client, time rules, trip assembly), `ALStore` (Keychain, offline snapshots), `ALDesign` (generated tokens), fixtures from a real server, CI | Package tests green; app launches to sign-in in the Simulator; hosted CI green on a PR |
| **Design review 1** ✅ | Mockups of every MVP screen built from design-system components ([`Design/review-1`](../Design/review-1/README.md)) | Signed off 11 Oct 2026 |
| **1 · Read-only offline client** | Sign-in, trip list (owned and shared), day timeline, item detail, trip-wide notes and checklists, map with pins, offline pack | Browse a seeded trip with the network off; snapshot tests light, dark and Dynamic Type XXL |
| **2 · Today, editing, sync** | Today tab, checklist ticks, note edits, reorder and move between days, outbox with retry, conflicts, shared-trip rules | Offline edits reach the server on reconnect; two Simulators on one trip converge |
| **Design review 2** ✅ | Simulator snapshot gallery beside the mockups ([`Design/review-2`](../Design/review-2/README.md)) | Signed off 11 Oct 2026; first TestFlight build |
| **3 · Reminders and tracking** | Leave-by and heads-up reminders, rolling geofence window, background tracking, stop detection, plan-vs-actual write-back, GPX capture | A replayed drive fires the right reminders in the trip's zone and detects the planned stops |
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

## Testing without a device

Every outside dependency comes through a protocol the tests replace: the network (a stub server and real fixtures), the clock (`-ALNow`), Core Location (recorded GPX replayed in tests and with `simctl location`), and push (`simctl push` payloads). Physical-device checks (background wake-ups, battery, cellular push) happen on TestFlight builds from design review 2 onward.

## CI

- `ci.yml` — every PR and push, GitHub-hosted macOS, no secrets: tokens check, package tests, Simulator UI tests.
- Self-hosted work (nightly full Simulator suite against a live test server, and TestFlight uploads) lives in the maintainer's private repository, which checks out this one. Nothing here can trigger code on the maintainer's machine.

