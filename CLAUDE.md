# Notes for Claude sessions working in this repo

This repository is public. Nothing personal goes into it: not in code, fixtures, tests, docs, screenshots, commit messages or PR text.

- **No real people or trips.** Use the synthetic fixture trip (Tasmania, March 2027) and its made-up users. Never commit real names, real trip names, places or dates, booking or reservation numbers, or flight numbers taken from someone's plans.
- **No identifying setup details.** Leave out Apple team ids, bundle ids, server hostnames, home-network names, machine or runner names, usernames and local paths under a home folder. Write "the signing xcconfig (outside the repo)" rather than its path and contents.
- **Screenshots** come from the seeded synthetic trip or the offline UI-test seed, never from a real account.
- **Fixtures** are regenerated with `Fixtures/adventurelog-v0.13.0/seed.py` and `capture.py` against a disposable server, never a real one.
- **Before every push:** search your diff for names, dates and hosts that came from outside the synthetic data. If something slips in, stop and say so rather than committing on top of it.
