# Contributing

Thanks for helping. A few rules keep the app correct and consistent.

## Ground rules

- **The server is the contract.** Model changes start from a captured response in `Fixtures/`. When AdventureLog releases a new version, re-run `seed.py` and `capture.py` against it into a new `Fixtures/adventurelog-vX.Y.Z/` folder and update tests there.
- **Never derive a day from a time.** An itinerary row's day is its own `date`. Show every time in the item's own time zone (`TripTime`), never the device's.
- **Design comes from the design system.** Colours, type, spacing and radii come from `ALColor`, `ALFont`, `ALSpace` and `ALRadius`. If you need a value that isn't there, propose it in the design system first; `Tokens.swift` is generated.
- **No runtime dependencies.** Test-only dependencies are fine when they earn their place.
- **Every file starts with the GPL header** used throughout the repo.

## Before you open a pull request

```bash
make generate
make test-packages
make test-ui
```

CI runs the same on GitHub-hosted macOS for every pull request. The maintainer's own self-hosted jobs (nightly full Simulator suite, TestFlight) run from a separate private repository and never on pull requests.

## Commit style

Short imperative subject ("Show arrival offsets on flights"), a body that says why when it isn't obvious.
