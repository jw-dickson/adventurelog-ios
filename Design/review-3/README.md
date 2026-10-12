# Design review 3: the full app, before the freeze

Simulator snapshots of every screen in the app after Stage 5, beside the mockups they were built from. They come from the synthetic "Tasmania Road Trip 2027" offline seed, at 18:00 on Mon 8 Mar 2027 in Tasmania, with a recorded day. Each screen is shown in light, dark and the largest accessibility text size (Dynamic Type XXL).

The `GalleryUITests` suite captured them on GitHub's macOS runner with the gallery job, which puts named PNGs on the `gallery` branch (see [Getting new snapshots](#getting-new-snapshots)). The Simulator's region is the US, so times read "6:30 PM" and dates "Mon, Mar 8". Under an Australian or British region they read "18:30" and "Mon 8 Mar".

Mockups and snapshots differ in device size and in the data shown, so compare layout and components, not exact positions. The keyboard tip on the XXL Add a note snapshot ("Speed up your typing…") is the Simulator's first-run prompt, not the app.

| Screen | Mockup | Light | Dark | XXL |
| --- | --- | --- | --- | --- |
| Sign in | ![](../review-1/01-sign-in.png) | ![](01-sign-in-light.png) | [dark](01-sign-in-dark.png) | [XXL](01-sign-in-xxl.png) |
| Today | ![](../review-1/02-today.png) | ![](02-today-light.png) | [dark](02-today-dark.png) · mockup: [dark](../review-1/10-today-dark.png) | [XXL](02-today-xxl.png) |
| Trip · day | ![](../review-1/03-trip-day.png) | ![](03-trip-day-light.png) | [dark](03-trip-day-dark.png) · mockup: [dark](../review-1/11-trip-day-dark.png) | [XXL](03-trip-day-xxl.png) |
| Trip · travel day | no mockup | ![](03c-travel-day-light.png) | [dark](03c-travel-day-dark.png) | [XXL](03c-travel-day-xxl.png) |
| Trip · whole trip | no mockup | ![](03b-whole-trip-light.png) | [dark](03b-whole-trip-dark.png) | [XXL](03b-whole-trip-xxl.png) |
| Item detail | ![](../review-1/04-item-detail.png) | ![](04-item-detail-light.png) | [dark](04-item-detail-dark.png) | [XXL](04-item-detail-xxl.png) |
| Map | ![](../review-1/05-map.png) | ![](05-map-light.png) | [dark](05-map-dark.png) | [XXL](05-map-xxl.png) |
| Trips | ![](../review-1/06-trips.png) | ![](06-trips-light.png) | [dark](06-trips-dark.png) | [XXL](06-trips-xxl.png) |
| Log | ![](../review-1/07-log.png) | ![](07-log-light.png) | [dark](07-log-dark.png) | [XXL](07-log-xxl.png) |
| Replan | ![](../review-1/08-replan.png) | ![](08-replan-light.png) | [dark](08-replan-dark.png) | [XXL](08-replan-xxl.png) |
| Reminders and Live Activities | no mockup | ![](10-reminders-light.png) | [dark](10-reminders-dark.png) | [XXL](10-reminders-xxl.png) |
| Add a note | ![](../editing/02-add-a-note.png) | ![](e02-add-a-note-light.png) | [dark](e02-add-a-note-dark.png) | [XXL](e02-add-a-note-xxl.png) |
| Edit a place | ![](../editing/04-edit-place.png) | ![](e04-edit-place-light.png) | [dark](e04-edit-place-dark.png) · mockup: [dark](../editing/10-edit-place-dark.png) | [XXL](e04-edit-place-xxl.png) |
| Add to a day | ![](../editing/07-add-to-day.png) | ![](e07-add-to-day-light.png) | [dark](e07-add-to-day-dark.png) | [XXL](e07-add-to-day-xxl.png) |
| New note | ![](../editing/08-new-note.png) | ![](e08-new-note-light.png) | [dark](e08-new-note-dark.png) | [XXL](e08-new-note-xxl.png) |

Not in the gallery:

- **Lock Screen and Dynamic Island** (review 1, 09). A UI test can't photograph a Live Activity. Check these on a phone, as in Handoffs 6 and 9.
- **Editing a flight, removing from a day, and a conflict** (editing 05, 06, 09). They need a flight day, a confirmation or a second phone. The UI tests cover the flows (`OfflineEditingUITests`), and the sheets share the place editor's layout.
- **Asking Claude** in the replan sheet only appears with a companion that has an Anthropic key, so it isn't in the offline seed.

## Fixed for this review

Review 2's follow-ups:

- **The time column cut "11:00" short** (issue 7). It is now as wide as the widest time the phone's region writes ("10:58 PM" or "22:58"). It is the same width on every row, so the rail stays straight. A list with no times in it, such as the trip-wide notes, keeps the narrow column.
- **Today at XXL.** The date joins the line under the title instead of sitting in a tile beside it, so the title gets the full width. The Overnight and booked badges go one under the other when they don't fit side by side.
- **Sign in at XXL.** The server address wraps instead of being cut short.
- **The car hire on Today.** It no longer shows "361 h". Its return date stays under the start time, because overnight flights and stays use that line for the date they end, and dropping it would hide when the hire ends.

Asked for during the review:

- **Photos in the timeline.** A place, stay or journey with a photo shows it as a rounded square at the right of its card, in Trip and Today. At XXL it's a strip across the top of the card instead, so the title keeps the full width. Photos come from the copy saved on the phone, so they show offline.
- **Where the clock changes.** Every time on the timeline is in its own place's zone, so on a travel day the times jump. A line on the rail now says where the clock changes and by how much. It sits after a flight that lands in another zone ("Now on Sydney time · clocks go forward 19 h"), or between two items in different zones. It compares the clocks at that moment, so daylight saving counts. Places that keep the same clock, like Sydney and Hobart, show nothing. The sample trip's travel day shows "back 1 h" after Denver → Los Angeles and "forward 19 h" after Los Angeles → Sydney.
- **The trip's cover on Whole trip.** This is the cover chosen in AdventureLog, or else the first place with a photo, which is what AdventureLog's own trip list shows. The sample trip has only one tiny photo, so for these snapshots the gallery gives the lookout, the cruise, the holiday park and the trip plain drawn pictures (`scripts/gallery-photos.py`). The fixture itself is unchanged.

Found while collecting these:

- **Log** used a narrower time column of its own, which wrapped "8:55 AM" onto two lines. It now shares the timeline's.
- **Replan.** Apply changes and Not now are the same width, as in the mockup, and one under the other at XXL, where they read "Appl…" and "Not n…". A proposal that only moves things later now says so ("Sunset cruise starts later.") instead of having no sentence.
- **Editing at XXL.** "Starts" and "Ends" sit above the date and time instead of breaking into "St / art / s", and a long name wraps. On Add a note, the line under the field is never cut short when the keyboard is up.
- **Reminders** rows used the system's white instead of the surface colour every other form uses.

## The checklist

From [`../README.md`](../README.md). This is my pass through it; the sign-off is yours.

- **Only design-system tokens and components.** Yes, apart from system controls: the date and time pickers, toggles, the segmented control, the keyboard and the tab bar. The tab bar is the system's: a bar on Today, Trip, Map and Log, and floating where iOS draws it that way.
- **One primary action per screen.** Yes: Navigate on Today and item detail, Sign in, Apply changes. Editing sheets put Save or Add in the navigation bar.
- **Ochre only on booked, fixed items.** Yes. Booked badges, the booking reference and booked timeline dots use it. Log's "Late" uses the warning colour, which is a different token.
- **Every status has a word and a symbol.** The timeline dots differ by fill and colour, and each card says what it is ("Booked", "3 of 5 done"). Log badges are words. Replan rows have a mark and a sentence.
- **Times in the place's own zone.** Yes. The editor names the zone in its header. It shows "GMT+11, HOBART" where the mockup shows "AEDT", because iOS only gives a short name like AEDT for the phone's own region. Spelling out GMT+11 is unambiguous, so I've left it.
- **XXL without truncating titles.** Screen and item titles wrap everywhere. What's still cut at XXL is the system's: navigation-bar titles ("Tasmania Road Trip 2…") and the last lateness chip, which scrolls sideways. The floating tab bar covers the bottom of each screen until it's scrolled, as everywhere in iOS.
- **VoiceOver labels on every control.** Every control has a label or text, and each timeline row reads as one element. The hidden sizing text in the time column is hidden from VoiceOver. A full VoiceOver pass on a phone is still to do.
- **Reads as AdventureLog with the logo covered.** The colours, radii and type come from AdventureLog's own theme. With the mark on Sign in covered, the screen still reads as AdventureLog. The mark is the image that came in with Stage 0. It is the only raster artwork in the app, and next to the flat UI it looks dated, which is worth a look while signing off.

## For you to decide

1. Sign off, or list what to change before the freeze.
2. The car hire's return date under its time (kept, for the reason above), or a time only, as the mockups show for single-day items.
3. "GMT+11" in the editor's zone header, or a lookup table for the short names of common zones.
4. The mark on Sign in: keep it, or swap in a flat version.

## Getting new snapshots

Actions › ci › Run workflow, choose the branch, and tick "Capture the screenshot gallery". When it finishes, the `gallery` branch holds one commit of named PNGs, replaced each run:

```bash
git fetch origin gallery
mkdir -p Design/review-N
git archive origin/gallery | tar -x -C Design/review-N --exclude=README.md
```

On a Mac, `make gallery` puts the same screenshots in `build/gallery`.
