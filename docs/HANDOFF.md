# Handoff

The cloud session writes code but cannot compile Swift. The Mac session builds, tests in the Simulator, runs CI and ships TestFlight; a server session deploys server pieces. Each handoff lives here: what changed, what to run, what "done" looks like, and what to send back. Append results under the handoff; don't rewrite earlier ones.

---

## Handoff 1 · Stage 0 → Mac session (2026-10-10)

**Branch:** `stage-0-foundations`. **Goal:** first green build, the self-hosted runner registered, and a merged PR.

### What changed

Everything in the repo is new. It already **builds and passes on GitHub-hosted macOS** (PR #1, `ci`: 44 package tests, project generation, Simulator UI tests). Five fixes came out of that first compile and are on the branch: `Category` renamed `LocationCategory` (collides with the Objective-C runtime), Swift Testing macros that cannot nest, and a double trailing slash in request URLs that the URL tests caught.

What's left for the Mac is what GitHub's machines can't do: your Xcode, a live server, the self-hosted runner and signing.

### 1. Build and test locally

```bash
git clone https://github.com/jw-dickson/adventurelog-ios && cd adventurelog-ios
git checkout stage-0-foundations
make bootstrap
make test-packages        # AdventureLogKit, ALStore, ALDesign on macOS
make run                  # launches on the newest iPhone simulator
```

**Done when:** all package tests pass; the app opens to "Connect to your AdventureLog" in light and dark (toggle with ⇧⌘A in the Simulator); the account menu's "Design tokens" screen renders.

### 2. End to end against a real server

Use a disposable AdventureLog v0.13.0 (Docker on the Mac with the upstream `docker-compose.yml`, or another disposable test instance), then seed the sample trip:

```bash
BASE_URL=http://127.0.0.1:8015 API_KEY=al_… python3 Fixtures/adventurelog-v0.13.0/seed.py
AL_TEST_SERVER=http://127.0.0.1:8015 AL_TEST_API_KEY=al_… make test-ui
```

**Done when:** `testSignsInAndShowsTheSeededTrip` passes, and by hand: sign in, open "Tasmania Road Trip 2027" (the synthetic seed trip), see 19 days with the LAX → SYD flight on 5 Mar arriving "+2 days", then turn off the Mac's network and reopen the trip from the saved copy.

Create the API key in AdventureLog's settings (API keys). Don't use your real trips for UI tests; `seed.py` creates a new collection each run.

### 3–5. Self-hosted runner, repository settings, signing

Done, and kept out of this public repository on purpose. The maintainer's private repo runs a self-hosted Mac that checks out this repo: a nightly full Simulator suite (including the live-server test) and a manual TestFlight workflow. This repo keeps only the GitHub-hosted `ci` workflow, which runs on every pull request. One repository setting stays here: Actions → General → Fork pull request workflows: require approval for all outside collaborators.

### 6. Pull request

Open `stage-0-foundations` → `main`. **Done when:** `ci` is green and the PR is merged. The first TestFlight build was uploaded early to prove signing (manual dispatch from the private repo).

### Send back

Append under "Results" below: compile fixes made (file and one line each), test results, a light and a dark screenshot of sign-in and of the trip outline, and anything that surprised you about the server or the Simulator.

### Results

**Mac session, 2026-10-10 to 2026-10-11 (complete)**

Step 1 (Xcode 27.0, iOS 27.0 simulator):
- `make test-packages`: AdventureLogKit 44, ALStore 2, ALDesign 3, all pass.
- `make run` builds and launches (`app.adventurelog.ios.dev`).
- Screenshots: `docs/screenshots/signin-{light,dark}.png`, and the trip outline against the synthetic seed in `outline-{light,dark}.png`.

Step 2 (disposable AdventureLog v0.13.0 in Docker, compose project `al-ios-test`, port 18015; stop with `docker compose -p al-ios-test down -v`):
- `make test-ui` against it: 3 tests, 0 failures, including `testSignsInAndShowsTheSeededTrip`.
- By hand (scripted through a throwaway XCUITest): the seeded trip opens and its overnight flight shows "arrives 5:00 AM +2 days". With the server container stopped, a fresh launch reopens the trip "Tasmania Road Trip 2027" from the saved copy (`docs/screenshots/outline-offline.png`). Full UI suite on the new seed: 7 tests, 0 failures.
- The test API key lives in a mode-600 file outside the repo, not in the repo.
- Not seen: the "Design tokens" screen (account menu); the UI test hooks don't reach it.

Fixes made (one line each):
- `scripts/simulator.sh`: boot no longer fails when `open -a Simulator` can't open (the runner has no GUI Simulator.app).
- `Makefile`, `scripts/simulator.sh`: Simulator builds are ad-hoc signed instead of `CODE_SIGNING_ALLOWED=NO`. An unsigned build has no entitlements, so the Keychain write fails with -34018 and sign-in never completes. CI still uses unsigned builds; that is fine because the UI tests use in-memory storage (`-ALResetState YES`).
- `Packages/ALStore/.../Credentials.swift`: `KeychainError` is a `LocalizedError`, so the sign-in screen shows "A required entitlement is not present. (-34018)" instead of "ALStore.KeychainError error 1".

Surprises:
- The upstream v0.13.0 `docker-compose.yml` pins nothing (`:latest`) and the example `.env` sets no `SECRET_KEY`. Without it API-key creation crashes. I pinned `v0.13.0` and added a random `SECRET_KEY`.
- The AIO container serves `/api` through the SvelteKit frontend, which answers URLs with a trailing slash with `308` to the slash-less form. `URLSession` follows that for the app; `seed.py` (urllib) can't replay a POST, so I ran the seed inside the container against Django on `127.0.0.1:8000`. The app's client was verified only through the frontend port.
- Layout nit: "11:00 AM" wraps to "11:00 A / M" in the outline's time column (see the last screenshot rows).
- No offline indicator is visible in the outline when the server is down; it just shows the saved copy.
- A Simulator build plus UI tests needs about 3 GB; the disk filled once at ~4 GB free. UI tests take 1.5–2.5 min. A screenshot right after `simctl launch` catches the launch screen; wait ~8 s.

Steps 3–5: done. Self-hosted CI and TestFlight signing live in a private maintainer repo (see above). The first TestFlight build uploaded successfully on 2026-10-11.

Open items from this handoff: the outline's time column wraps long 12-hour times in the Stage 0 view (tracked in a GitHub issue), and there is no offline indicator when the server is unreachable.
- The Simulator keeps the Keychain session and saved trips between runs (only `-ALResetState YES` is in-memory). A test that expects the sign-in screen after a signed-in run needs `xcrun simctl uninstall <udid> app.adventurelog.ios.dev` and `xcrun simctl keychain <udid> reset` first.

---

## Handoff 2 · Stage 2 → Mac session (2026-10-11)

**Branch:** `stage-2-today-sync`. **Goal:** Stage 2's exit checks on a real Simulator against the disposable test server: offline edits reach the server on reconnect, and two Simulators on one trip converge.

### What changed

- **Today tab** (first tab, Design/review-1 02 and 10). It shows the day header, a Next card with the leave-by time and Navigate / Notes / Skip, then Later today and Earlier. The leave-by time counts from the previous stop. It uses Apple Maps' drive time when it can, and a straight-line estimate offline and in UI tests. Skip stays on the phone.
- **Edits:**
  - checklist items tick on tap in item detail;
  - notes have Edit;
  - the Trip tab has Reorder (a drag list for the day or the trip-wide list);
  - each row has "Move to another day…".
- **Sync:**
  - edits show at once and go through the outbox (`AdventureLogKit/Sync`), stored on the phone in `ALStore/DeviceStateStore`;
  - "N changes waiting to sync" and "N changes need a look" appear under the trip;
  - conflicting note edits ask which version to keep;
  - signing out with unsent changes asks first.
- **How it works:** see "How Stage 2 syncs" in [PLAN.md](PLAN.md).
- **New server finding:** a checklist PATCH without `items` deletes every item. It's in the fixtures README §7. The app always sends the whole list.

The cloud session can't compile Swift. Hosted CI is the first compile.

### 1. Tests

```bash
git fetch && git checkout stage-2-today-sync
make test-packages     # new: SyncTests (fake server with AdventureLog's quirks, two-phone convergence), TodayPlanTests, DeviceStateStoreTests
make test-ui           # new: OfflineEditingUITests; the gallery now includes 02-today
```

### 2. Offline edits reach the server on reconnect

Use the disposable test server with the synthetic seed. Never use a real account.

1. Sign in on one Simulator, open "Tasmania Road Trip 2027", then stop the server container.
2. Make these edits:
   - tick "Check the spare tyre" in Car pickup;
   - edit "Trip essentials";
   - move "Sunset cruise" to 7 Mar.
3. Check the trip shows "3 changes waiting to sync".
4. Start the server again. Within a few seconds the line should clear, and the web UI should show all three changes.

**Done when:** all three changes are on the server and Car pickup still has 5 items.

### 3. Two Simulators converge

Boot a second Simulator signed in as the seed's guest user, with the guest key from `seed.py`'s environment. That user is a collaborator on the trip.

1. With both offline (server stopped), make different edits on each:
   - each ticks a different Car pickup item;
   - each moves a different row;
   - both edit "Hobart day tips".
2. Start the server and bring each app to the front in turn.

**Done when:**
- both show the same trip after a pull to refresh;
- both ticks and both moves are kept;
- the second phone to sync is asked to keep its version or theirs for "Hobart day tips", and after choosing, both phones show the chosen text.

### 4. Writes through the frontend port

Handoff 1 found that the AIO container's frontend answers `/api/...` with a `308` to the URL without the slash. GETs worked through it. Repeat step 2 against the frontend port and note whether PATCH and POST survive the redirect with the API key. If they don't, record the status codes. The client may need to hold on to the method and headers.

### 5. Gallery

Run `make gallery` and put `02-today-{light,dark,xxl}` beside `Design/review-1/02-today.png` and `10-today-dark.png` for design review 2.

### Send back

Append under "Results":
- compile fixes, one line each;
- test counts;
- steps 2–4: done or not, with anything that surprised you;
- the Today screenshots.

### Results

---

## Handoff 3 · Sign in with an account (2026-10-11)

**Branch:** `native-sign-in` (on top of Stage 2). **Goal:** sign in without pasting an API key.

### What changed

- **The sign-in screen** asks for the server, then a username (or email) and password, with a code step when two-factor is on. It also shows a "Continue with …" button for each provider the server offers, such as Authentik.
- **Provider sign-in** runs the server's own pages in an in-app web view, which keeps nothing once it closes. When the server's session appears, the app takes it.
- **The key:** either way, the app then makes an API key named "AdventureLog iOS · <date>" with that session, ends the session, and keeps the key. Signing out revokes it.
- **"Use an API key instead"** kept the old way. Removed afterwards (issue #9): see Handoff 3b.
- Endpoints and findings are in the fixtures README §2.

### Check on the Mac

1. On the disposable test server, set a password for the seed admin. Then run `AL_TEST_SERVER=… AL_TEST_USERNAME=admin AL_TEST_PASSWORD=… make test-ui`. `testSignsInWithAPassword` should pass, and the server's API keys page should list "AdventureLog iOS · <date>".
2. Turn on TOTP for that user in the web UI and sign in again. The app should ask for the code.
3. Sign out. The key disappears from the server's list.
4. Provider sign-in can only be tried against a server with a provider configured. Note what happens at the end of the flow: whether the sheet closes by itself and the app signs in.

### Results

---

## Handoff 4 · Stage 3a, reminders (2026-10-11)

**Branch:** `stage-3a-reminders`. **Goal:** reminders fire on a real phone at the right local times.

### What changed

- **Leave-by and heads-up notifications** are worked out from the plan on the phone; see "How Stage 3 reminds" in [PLAN.md](PLAN.md).
- **Turning them on:** Today offers them once, and the account menu has a Reminders screen.
- **Background refresh** (`app.adventurelog.refresh`) keeps the 48-hour window rolling.
- **Kit tests** replay 8 Mar of the seed trip in 15-minute steps. Each of the day's six reminders fires once, at its Tasmanian time.

### Check on a device (TestFlight)

1. Turn reminders on. In AdventureLog, add a timed place today, an hour from now, after another place with a position. Pull to refresh.
   - A heads-up should arrive 15 minutes before it starts.
   - A leave-by should arrive at the time in its own text ("Leave by …"). That time comes from `ReminderPlanner` (straight-line estimate plus a buffer), so it can be a few minutes earlier than the leave-by on Today, which uses Apple Maps' drive time and no buffer.
2. Change the phone's time zone in Settings. The pending reminders should still fire at the same moments.
3. Leave the app in the background overnight, then open Settings › General › Background App Refresh and confirm AdventureLog is on. The next day's reminders should arrive without opening the app.

### Results

---

## Handoff 3b · Sign in only through the login flow (issue #9, 2026-10-11)

**Branch:** `sign-in-login-flow` (off main). **Goal:** single sign-on works on a server behind a forward-auth proxy, and there is no way to paste a key.

### What changed

- **No API-key field.** The sign-in screen offers a password (where the server allows it) and single sign-on. The app still makes and keeps its own key after signing in. UI tests can still pass a key with `-ALServerURL` and `-ALAPIKey`, which signs straight in.
- **"Sign in with single sign-on"** is always there when the server lists no providers. It opens the server's own address in the web sheet, so a sign-on proxy in front of it runs first, then AdventureLog's own provider sign-in, as in a browser. Listed providers still get their own "Continue with …" buttons.
- **A proxy's login page isn't an error.** Behind forward auth, requests without a session or key are redirected to the proxy's login page. The app recognises a redirect to something that isn't JSON. Provider discovery then counts as "none listed", the password fields are hidden, and the screen says the server signs in through single sign-on. A password attempt that meets the proxy says the same instead of showing a parse error.

### Check on a device (TestFlight)

1. Enter the address of a server behind forward auth. The password fields should disappear and **Sign in with single sign-on** should be the main button, with no error.
2. Tap it. The proxy's sign-on and then AdventureLog's should run in the sheet. When they finish, the sheet closes and the app opens on Today. AdventureLog's API keys page should list "AdventureLog iOS · <date>".
3. Sign out and back in once more, to check that the second sign-in also completes.

### Results

---

## Handoff 5 · Stage 3b, tracking (2026-10-11)

**Branch:** `stage-3b-tracking`. **Goal:** a real drive is recorded, its stops match the plan, and the phone stays quiet when it should.

### What changed

- **Tracking** on trip days after one opt-in per trip; see "How Stage 3 tracks" in [PLAN.md](PLAN.md). The Info.plist gains the two location usage descriptions and the `location` background mode.
- **The Log tab** (Design/review-1, 07) without Photos and XMP, which are Stage 6. **The Map tab** draws the recorded route and unplanned stops.
- **Kit tests** replay a made-up drive for 8 Mar of the seed trip and check the stops, each row of the log and the distance. UI tests seed the same drive offline (`AL_SEED_TRACK`) and check the Log tab, and that nothing records before the person agrees.

### 1. Simulator replay

Points carry the real time, so this needs a trip with a day today rather than a pinned clock.

1. On the disposable test server, make a one-day trip for today with two places: "Car hire" at -42.85, 147.5 at the current time, and "Holiday park" (a stay) at -42.1247, 148.2861 about half an hour later.
2. Run the app in the Simulator, sign in, open the trip and choose **Record trip days** on Today. Allow location "While Using".
3. Run `scripts/replay-drive.sh` (about 30 minutes). It stays at the car hire, drives to a point that isn't in the plan, stays there, then drives to the holiday park and stays.
4. Open the Log tab. Expect: the car hire done, an unplanned stop, the holiday park done or late, the distance driven around 110 km, and the route on the Map tab. Share **GPX track** to Files and check it opens.

### 2. On a device (TestFlight)

1. On a day with a trip, agree to tracking and lock the phone for a short drive with a stop of 10 minutes or more. The location indicator should show while it records.
2. Open the Log: the drive and the stop should be there. A planned place you reached should show as done, with your arrival time.
3. Turn the switch off on the Log tab. The location indicator should go away within a few seconds.
4. The next morning after the trip's last day, open the app: nothing should be recording.
5. Note how much battery the day used (Settings › Battery) for the next stage's tuning.

### Send back

- The Log and Map screenshots from step 1 (synthetic places only) and whether the stop detection matched.
- Anything wrong with background recording on the device, and the battery figure.

### Results

---

## Handoff 6 · Stage 4a, Live Activities (2026-10-11)

**Branch:** `stage-4a-live-activities`. **Goal:** every Live Activity state renders, in the Simulator and on a phone.

### What changed

- **A widget extension** (`Widgets/`, target `AdventureLogWidgets`) draws the Live Activity's Lock Screen card and Dynamic Island. See "How Stage 4 shows Live Activities" in [PLAN.md](PLAN.md).
- **The app** starts, updates and ends it (`App/Sources/LiveActivities.swift`). Reminders has a switch for it.
- **Kit tests** check the Sydney connection against the mockup, boarding, the first flight, a booked tour and skipping. They also decode every push payload in `Fixtures/live-activity/`.

### Before the next TestFlight build

The extension needs its own bundle id, the app's id plus `.widgets`, in App Store Connect and in the signing setup outside the repo. Without it, archiving fails.

### 1. Simulator

1. Make the synthetic trip's EX 1501 window current: run the app with `-ALNow 2027-03-06T18:03:00Z` on a Simulator whose clock you don't change. Open the app and go to the Home Screen: the Live Activity should be on the Lock Screen, showing "Connection · SYD" and "EX 1501 to Hobart". Because the Simulator's real clock isn't 2027, the countdown reads days.
2. In Xcode, open `Widgets/TripLiveActivity.swift` and check the previews: upcoming, boarding and cancelled. On this branch they are how the pushed states get checked: the app starts its activity without a push token, so pushes can't reach it.
3. The payloads in `Fixtures/live-activity/` need an activity started with a push token. Stage 4b starts one that way once a companion address is set in Reminders; from then on, push each in turn with `xcrun simctl push booted app.adventurelog.ios.dev <file>` and check the Lock Screen and the Dynamic Island (iPhone 15 Pro or later). If `simctl` refuses Live Activity payloads on this Xcode, note it; the companion's sandbox push covers the same states.

### 2. On a device (TestFlight)

1. On the day of a real flight or booked tour in AdventureLog, open the app inside the window. The activity should appear and count down. It should end at departure without the app being opened again, provided the phone ran it in the background at least once in between.
2. Turn the switch off in Reminders: the activity goes away.

### Results

---

## Handoff 7 · Stage 4b, the companion service (2026-10-11)

**Branch:** `stage-4b-companion`. **Goal:** a push from your companion reaches a TestFlight build, and the Live Activity starts and ends without opening the app.

### What changed

- **`Companion/`:** the service in Python and FastAPI, with a Dockerfile and setup in its README. Its tests run on Linux in CI.
- **The app:** Reminders has a companion address field. The app registers and hands over push tokens, and unregisters on sign-out.
- **Signing:** the app now has the Push Notifications entitlement (`App/AdventureLog.entitlements`).

### 1. Apple Developer account

1. Turn on Push Notifications for the app's App ID. The widget extension's id needs no capability.
2. Create an APNs auth key (Keys › +, Apple Push Notifications service) and download the `.p8`. Keep it outside the repo.

### 2. Run the companion

1. Build and run it next to AdventureLog as in `Companion/README.md`: `ADVENTURELOG_URL`, the key file, key id, team id and bundle id.
2. Put it behind your reverse proxy on HTTPS. Its requests carry the API key, so the forward-auth bypass for `X-API-Key` that AdventureLog's `/api/` uses needs to cover the companion too.
3. `GET /healthz` should say `"pushes": true`.

### 3. On a phone

1. In the app, open Reminders, enter the companion's address and wait for "Connected".
2. Add a flight to a trip that departs about 3 h 10 min from now. Lock the phone and don't open the app. Within five minutes of the window opening, the Live Activity should appear by itself. At departure it should end.
3. Change the flight's time in AdventureLog while the activity is showing. Within five minutes, the countdown should move.
4. Sign out: the companion's database should no longer list the phone.

A build from Xcode registers as `sandbox`, and TestFlight builds as `production`. Test with the build you'll use.

### Results

## Handoff 8 · Editing trip items (2026-10-11)

**Branch:** `item-editing`. **Goal:** change a place, journey or stay from the phone on the road, including with no signal. Issue #22; mockups in [Design/editing](../Design/editing/README.md), signed off 11 Oct 2026.

### What changed

- **Item detail:** **Edit** in the toolbar for places, journeys and stays, and **Add a note** under the notes.
- **Edit sheet:** name, times in the item's own zone, notes, address, link, flight number or booking reference. **Remove from** the day at the bottom.
- **Trip day:** a **+** menu with a new note on the day or a trip-wide note.
- **Sync issues:** a clash on a field shows both values with Keep mine and Keep server's.
- **Kit:** `TripEdit.editItem`, `appendNote`, `addNote` and `removeRow`, with tests against the fake server (`ItemEditTests`). See "How item edits sync" in [PLAN.md](PLAN.md).

### 1. Simulator

1. In the offline seed, open Trip, tap Sunset cruise, then **Add a note**: the line shows under the notes with the time, and "Saved on this phone, waiting to sync" appears.
2. **Edit**: change the name and move the start; the end moves with it. Save, and check Today and the day timeline.
3. On the day, tap **+** → New note; it goes at the end of the day.

### 2. On a device (TestFlight)

1. On a real trip, add a note to an item with the phone in flight mode, then turn the network back on. The note should reach AdventureLog's web page.
2. Edit a time in the app and the same item's notes on the web at the same time. Saving should keep the web's notes, save your time, and ask about nothing; if you change the same field in both places it should ask.
3. Remove something from a day: on the web it should show as unscheduled, with its visit kept.

## Handoff 9 · The push-to-start token (2026-10-11)

**Branch:** `live-activity-start-token`. **Goal:** the companion gets the phone's push-to-start token, so it can start a Live Activity while the app is closed. Issue #24.

### What changed

- At launch, on registering, and whenever the app comes to the front, the app reads iOS's current push-to-start token (`Activity.pushToStartToken`) as well as watching for new ones. The stream alone may not replay a token iOS issued earlier.
- The app registers for remote notifications at launch. Some iOS versions only issue a push-to-start token after that. The device token itself isn't used.
- The companion's register reply says whether it holds a start token (`canStart`). Reminders shows "Connected" when it does, and "Connected · activities start when you open the app" when it doesn't.
- The app logs, privately, when iOS issues a start token and when it registers (Console.app, subsystem `AdventureLog`, category `companion`).

### 1. Check the build

1. In the TestFlight build, `aps-environment` should be `production`: `codesign -d --entitlements :- AdventureLog.app` on the exported app. The App ID needs Push Notifications turned on.

### 2. On a phone (TestFlight)

1. Open the app, then Reminders. The companion line should say "Connected" with no suffix. If it still says "activities start when you open the app", connect the phone to the Mac, open Console.app, filter on subsystem `AdventureLog`, and reopen the app. Note whether "iOS issued a push-to-start token" appears.
2. On the companion, the device row should now have a `start_token`.
3. Repeat Handoff 7's step 3.2 (a flight about 3 h 10 min out, phone locked, app closed): the activity should appear by itself.

### Results

## Handoff 10 · Stage 5a, the replan assistant (2026-10-11)

**Branch:** `stage-5a-replan`. **Goal:** when you're running late, Today proposes a revised rest-of-today that keeps booked items, and applying it saves ordinary edits.

### What changed

- **Kit:** `AdventureLogKit/Replan`: the planner, the checker, sun times, the situation (from the plan, the log and the last position), the sheet's text, and how a proposal becomes edits. Golden scenarios in `ReplanTests`. See "How Stage 5 replans" in [PLAN.md](PLAN.md).
- **Today:** a **Replan today** button (wand) in the toolbar, and a "You're 48 min behind" card while recording.
- **Sheet:** the proposal per Design/review-1, 08, with "How late are you?" choices when the phone isn't recording.
- **Notification:** while recording in the background, once per late stop and at most every 90 minutes; tapping it opens the sheet. It needs notification permission (turning on reminders asks for it).

### 1. Simulator

1. In the offline seed (18:00 on Mon 8 Mar), tap the wand on Today. Pick **45 min**: Sunset cruise moves 18:30 → 19:15. Apply, and Today's next card says "in 1 h 15 min".
2. While `scripts/replay-drive.sh` runs on a recorded trip day (Handoff 5), open the sheet: it should say "From where you are now" and work out the delay from the replayed position. Once that's 30 minutes or more, Today shows the card.

### 2. On a device (TestFlight)

1. On a trip day with recording on, fall half an hour behind a planned place with the app in the background. One notification should arrive; tapping it should open the sheet on Today.
2. Apply a proposal with the phone in flight mode, then go back online: the new times should reach AdventureLog's web page, and a place moved to tomorrow should show on that day.
3. Check that a booked item (tagged booked) is listed first with a lock and keeps its time.

### Results

