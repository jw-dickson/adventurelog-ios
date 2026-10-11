# AdventureLog for iOS

A native iOS app for [AdventureLog](https://github.com/seanmorley15/AdventureLog), the self-hosted travel tracker and trip planner. It talks to your own AdventureLog server and is built to carry a trip on the road: offline first, times shown in each place's own time zone, and (in later stages) reminders, route logging and Live Activities.

> **Status: Stage 3 — reminders and tracking.** Leave-by and heads-up reminders, worked out on the phone. On trip days you agree to, the app records your route and stops and shows the day against the plan in the Log tab, with a GPX export; the route stays on the phone. Stage 2: Sign in with your AdventureLog account or your server's single sign-on and carry your trips offline: Today's next stop with a leave-by time, each day's timeline, item details, notes, checklists and a map. Tick checklist items, edit notes, and reorder or move items between days, with or without a signal. Changes sync when your server can be reached, including on trips shared with you. See [the build plan](docs/PLAN.md).

## Requirements

- An AdventureLog server, **v0.13.0 or later**, and an account on it
- Xcode 16 or later, iOS 18 Simulator or device
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Getting started

```bash
make bootstrap      # installs XcodeGen if needed, generates tokens and AdventureLog.xcodeproj
make test-packages  # fast logic tests on macOS against real AdventureLog fixtures
make run            # build and launch in the newest iPhone simulator
```

Then enter your server address (the one you open AdventureLog at in a browser) and sign in with your AdventureLog username and password, or with your server's single sign-on (Authentik or another OpenID Connect provider, GitHub). The app makes its own API key for the phone, so it keeps working offline; signing out revokes it. There is no field for pasting a key.

If a single sign-on proxy (forward auth) sits in front of your server, the app can't see the server's sign-in options or use a password. Tap **Sign in with single sign-on**: the server's own pages open in the app, go through the proxy's sign-on like a browser would, and the app signs in when they finish. Every redirect in that chain has to be `https`.

To run the end-to-end UI test against a live server seeded with the sample trip:

```bash
BASE_URL=http://127.0.0.1:8000 API_KEY=al_… python3 Fixtures/adventurelog-v0.13.0/seed.py
AL_TEST_SERVER=http://127.0.0.1:8000 AL_TEST_API_KEY=al_… make test-ui
```

## Layout

| Path | What |
| --- | --- |
| `App/` | The SwiftUI app |
| `Packages/AdventureLogKit` | Models, API client, time-zone rules, day-by-day trip assembly, Today, and the outbox that syncs edits. No UI. |
| `Packages/ALStore` | Keychain credentials, offline trip snapshots and photos, and this phone's unsent edits |
| `Packages/ALDesign` | Design tokens generated from `Design/tokens.json`, and shared components |
| `Fixtures/adventurelog-v0.13.0` | Real API responses from AdventureLog v0.13.0, the seed script, and [notes on the API's rules](Fixtures/adventurelog-v0.13.0/README.md) |
| `Design/` | The design system's tokens; see [Design/README.md](Design/README.md) |
| `project.yml` | XcodeGen spec; the `.xcodeproj` is generated, not committed |

## Design

The app follows the **AdventureLog iOS design system**: AdventureLog's own light and dark theme colours and radii, Apple's type, controls and SF Symbols. `Tokens.swift` is generated from it, never edited by hand.

## Signing your own build

Simulator builds need no signing. For a device or TestFlight, copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig` and set your team id and bundle id.

## License

GPL-3.0, the same as AdventureLog. See [LICENSE](LICENSE).
