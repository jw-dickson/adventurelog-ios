# Build plan

The app is built in stages. Each ends in something that runs in the Simulator and passes its exit checks in CI; screens are reviewed against the design system before they are coded and again on real renders.

| Stage | Delivers | Exit checks |
| --- | --- | --- |
| **0 · Foundations** | Repo, XcodeGen project, `AdventureLogKit` (models, client, time rules, trip assembly), `ALStore` (Keychain, offline snapshots), `ALDesign` (generated tokens), fixtures from a real server, CI | Package tests green; app launches to sign-in in the Simulator; hosted CI green on a PR |
| **Design review 1** ✅ | Mockups of every MVP screen built from design-system components ([`Design/review-1`](../Design/review-1/README.md)) | Signed off 11 Oct 2026 |
| **1 · Read-only offline client** | Sign-in, trip list (owned and shared), day timeline, item detail, trip-wide notes and checklists, map with pins, offline pack | Browse a seeded trip with the network off; snapshot tests light, dark and Dynamic Type XXL |
| **2 · Today, editing, sync** | Today tab, checklist ticks, note edits, reorder and move between days, outbox with retry, conflicts, shared-trip rules | Offline edits reach the server on reconnect; two Simulators on one trip converge |
| **Design review 2** | Simulator snapshot gallery beside the mockups | Signed off; first TestFlight build |
| **3 · Reminders and tracking** | Leave-by and heads-up reminders, rolling geofence window, background tracking, stop detection, plan-vs-actual write-back, GPX capture | A replayed drive fires the right reminders in the trip's zone and detects the planned stops |
| **4 · Companion service and Live Activities** *(optional module)* | Self-hosted companion: device registration, APNs, track ingest, fixed/flexible flags; Live Activities for connections and booked tours | `simctl push` payloads render every state; a server push reaches a TestFlight build |
| **5 · Replan assistant** *(optional module)* | Proposes a revised day around booked items; the user accepts, edits or dismisses | Golden scenarios produce valid proposals; a UI test accepts one end to end |
| **Design review 3, freeze** | Full-app review | Fixes only after this point |
| **6 · Photo export** *(optional module)* | Per-day GPX and XMP keywords for Lightroom Classic | Round-trip on a sample catalogue |

## Testing without a device

Every outside dependency comes through a protocol the tests replace: the network (a stub server and real fixtures), the clock (`-ALNow`), Core Location (recorded GPX replayed in tests and with `simctl location`), and push (`simctl push` payloads). Physical-device checks (background wake-ups, battery, cellular push) happen on TestFlight builds from design review 2 onward.

## CI

- `ci.yml` — every PR and push, GitHub-hosted macOS, no secrets: tokens check, package tests, Simulator UI tests.
- `simulator.yml` — pushes to `main` on the maintainer's self-hosted Mac: full suite against a live test server.
- `testflight.yml` — manual, self-hosted, behind a protected environment.

Self-hosted jobs never run on pull requests and skip themselves outside the maintainer's repository.
