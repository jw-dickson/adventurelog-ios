# Design

`tokens.json` is exported from the **AdventureLog iOS** design system in Claude Design. It holds:

- AdventureLog's own `light` and `dark` theme colours, exactly as in `frontend/tailwind.config.js` (v0.13.0), plus accessible text and on-fill variants where AdventureLog's pairs fall below 4.5:1 contrast (for example its dark primary button text is 3.4:1, so the app uses `on-primary`);
- the iOS type ramp, mapped onto Dynamic Type text styles;
- AdventureLog's spacing and corner radii (8 / 16 / pill).

`scripts/gen-tokens.py` turns it into `Packages/ALDesign/Sources/ALDesign/Tokens.swift`. CI fails if the two drift apart.

To change a token: change it in the design system, export `tokens.json` here, run `make tokens`, and commit both files together.

## Review gates

Screens are reviewed three times against the design system: mockups before code (review 1), Simulator snapshots after the MVP (review 2), and the full app before the feature freeze (review 3). The checklist:

- uses only design-system tokens and components
- one primary action per screen
- ochre (`accent`) only on booked, fixed items
- every status has a word and a symbol, never colour alone
- times shown in the place's own time zone
- works at Dynamic Type XXL without truncating titles
- VoiceOver labels on every control
- reads as AdventureLog when the logo is covered
