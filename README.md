# AdventureLog for iOS

A native iOS app for [AdventureLog](https://github.com/seanmorley15/AdventureLog), the self-hosted travel tracker and trip planner. It talks to your own AdventureLog server and is built to carry a trip on the road: offline first, times shown in each place's own time zone, and (in later stages) reminders, route logging and Live Activities.

> **Status: Stage 0 — foundations.** Sign in with an API key, list your collections, and browse a trip day by day, online or offline. Screens are pre-design scaffolds until design review 1. See [the build plan](docs/PLAN.md).

## Requirements

- An AdventureLog server, **v0.13.0 or later**, and an API key from its settings
- Xcode 16 or later, iOS 18 Simulator or device
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Getting started

```bash
make bootstrap      # installs XcodeGen if needed, generates tokens and AdventureLog.xcodeproj
make test-packages  # fast logic tests on macOS against real AdventureLog fixtures
make run            # build and launch in the newest iPhone simulator
```

Then enter your server address (the one you open AdventureLog at in a browser) and an API key.

To run the end-to-end UI test against a live server seeded with the sample trip:

```bash
BASE_URL=http://127.0.0.1:8000 API_KEY=al_… python3 Fixtures/adventurelog-v0.13.0/seed.py
AL_TEST_SERVER=http://127.0.0.1:8000 AL_TEST_API_KEY=al_… make test-ui
```

## Layout

| Path | What |
| --- | --- |
| `App/` | The SwiftUI app |
| `Packages/AdventureLogKit` | Models, API client, time-zone rules and day-by-day trip assembly. No UI. |
| `Packages/ALStore` | Keychain credentials and offline trip snapshots (SwiftData cache and outbox from Stage 1) |
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
