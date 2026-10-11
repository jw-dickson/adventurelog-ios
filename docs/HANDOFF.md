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

### 3. Register the self-hosted runner

Runners on a personal account belong to one repository, so add a second instance:

1. GitHub → `adventurelog-ios` → Settings → Actions → Runners → New self-hosted runner → macOS, ARM64.
2. Install into its own folder with the labels `self-hosted,macOS,ARM64`.
3. Install it as a **LaunchAgent** so it shares the logged-in GUI session the signing keychain needs.
4. `brew install xcodegen` if the runner's shell doesn't already see it.

### 4. Repository settings

- Actions → General → Fork pull request workflows: **require approval for all outside collaborators**.
- Environments → new `testflight`, required reviewer: you.
- Secrets: `CI_SIGNING_KEYCHAIN_PASSWORD`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_P8`, `SIGN_XCCONFIG` (a **path** on the runner, see 5), `AL_TEST_API_KEY` (required by `simulator`).
- Variables: `AL_TEST_SERVER` (the seeded test server; required by `simulator`, which fails preflight without it and without `AL_TEST_API_KEY`. The GitHub-hosted `ci` lane doesn't use either.)

### 5. App Store Connect and signing

1. Register a bundle id under your team, e.g. `com.example.adventurelog` (your choice; it is not committed).
2. Create the app record. **The App Store name "AdventureLog" is already taken by an unrelated app**, so name the record something like "AdventureLog Trips"; the home-screen name stays "AdventureLog" (`CFBundleDisplayName`).
3. On the runner, keep the signing xcconfig outside the repo (`chmod 600`) with your `DEVELOPMENT_TEAM` and `AL_BUNDLE_ID`, and set the `SIGN_XCCONFIG` secret to its **absolute** path. Don't use `~`: the workflow quotes the value, so `~` is never expanded and the file check fails.

### 6. Pull request

Open `stage-0-foundations` → `main`. **Done when:** `ci` is green (it already is); after merging, `simulator` (self-hosted) is green on `main`. Leave `testflight` for design review 2 unless you want to prove signing early (manual dispatch).

### Send back

Append under "Results" below: compile fixes made (file and one line each), test results, a light and a dark screenshot of sign-in and of the trip outline, and anything that surprised you about the server or the Simulator.

### Results

**Mac session, 2026-10-10 (in progress: steps 1–3 done, 4–6 partly done)**

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

Step 3 (runner): registered and online with labels `self-hosted,macOS,ARM64`, in its own folder with its own LaunchAgent. Made by copying another runner's binaries without `_work`/credentials; delete the copied `.runner_migrated` or `config.sh` refuses with "already configured". Its PATH includes `/opt/homebrew/bin` (xcodegen is found).

Step 4 (repo settings): fork-PR approval is now `all_external_contributors`; environment `testflight` exists with the repo owner as required reviewer. Secrets are not set yet (pending the signing inputs).

Step 5: the signing xcconfig (mode 600, outside the repo) is written with the team id and bundle id. The App Store Connect bundle id and the "AdventureLog Trips" app record are still to be created by hand.
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
- **"Use an API key instead"** keeps the old way.
- Endpoints and findings are in the fixtures README §2.

### Check on the Mac

1. On the disposable test server, set a password for the seed admin. Then run `AL_TEST_SERVER=… AL_TEST_USERNAME=admin AL_TEST_PASSWORD=… make test-ui`. `testSignsInWithAPassword` should pass, and the server's API keys page should list "AdventureLog iOS · <date>".
2. Turn on TOTP for that user in the web UI and sign in again. The app should ask for the code.
3. Sign out. The key disappears from the server's list.
4. Provider sign-in can only be tried against a server with a provider configured. Note what happens at the end of the flow: whether the sheet closes by itself and the app signs in.

### Results
