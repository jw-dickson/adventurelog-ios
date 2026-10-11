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
