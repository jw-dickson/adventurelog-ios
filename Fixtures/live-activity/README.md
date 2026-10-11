# Live Activity push payloads

Every state of the flight Live Activity, for `xcrun simctl push` and as the reference for what the
companion service sends (Stage 4b). The example is EX 1501, Sydney to Hobart, on 6 Mar 2027 in the
synthetic trip: boarding 06:15, departure 07:00 Sydney time.

`content-state` is `LiveActivityState` in AdventureLogKit. Its times are Unix seconds, and the Kit
tests decode every file here, so a payload can't drift from the app.

| File | State |
| --- | --- |
| `1-upcoming-gate.apns` | Counting down to boarding, with the gate |
| `2-delayed.apns` | Delayed: both times move, with an alert |
| `3-boarding.apns` | Boarding: counts down to departure |
| `4-cancelled.apns` | Cancelled, with the rebooking |
| `5-end.apns` | Ends the activity after departure |

To try one, start the activity in the Simulator first (see Handoff 6 in `docs/HANDOFF.md`), then:

```bash
xcrun simctl push booted app.adventurelog.ios.dev Fixtures/live-activity/2-delayed.apns
```

`Simulator Target Bundle` is the default Debug bundle id; change it if yours differs. The
timestamps are in 2027, so the countdowns read days rather than minutes; the layout is what's being
checked.
