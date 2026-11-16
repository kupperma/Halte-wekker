# Haltewekker travel overhaul — phases 1 and 2 (design)

Date: 2026-11-16 · App today: 0.18.3 (build 87) · This work ships as **0.19.0 (build 88)**.
Concepts shown to the user: https://claude.ai/artifact/U5ZswH2Pn22Yi5Z8WCTDv8 — the user picked **Concept C, "Live around you"**.

## 1. Intent — why

The user's words: the app should have "a clear focus and goal it will achieve and … do that better than the competition. Atm it's kinda a jack of all master of none." It must be "an improved 9292 or NS app": a travel app with built-in alarms for your school schedule, that instantly detects you're on a bus or train, with its notifications and trip comparison, and the alarm that wakes you while travelling. "Users at this moment land on the start page and just get confused and overwhelmed by the amount of info." Apple Maps and Google Maps keep what's important big and put the rest further away or behind menus; the start page should start with the map, showing **train stations, bus stops and moving buses and trains** instead of shops. Take inspiration from Apple and Google, never copy them. Follow the design rules from the two videos (`.superpowers/redesign/rules.md`, the 40 rules). The old Haltewekker look (station backdrop, paper sheets, metro map) is let go.

Audience: today the owner (a BUas student commuting Veghel → Den Bosch/Eindhoven → Breda → BUas). **Eventually anyone, the target audience being uni/college students** — not in this work, but nothing built now may make that harder.

## 2. Goals

Phase 1 — the home, search and your day (Concept C):
1. A map-first home: the real map with only stations, stops and live vehicles; search and quick places at the top; weather chip and follow-me button; swipeable cards with the live departures of the stops around you at the bottom.
2. Pull those cards up into a sheet with **Your day** (wake-up alarm, when to leave, the rides, classes, the way home, as one timeline, per day) and **Coming up** (school dates: breaks, project weeks, exams, as the school-schedule source knows them).
3. **Plan a trip** from your location (default) or anywhere, to anywhere; "Leave now ▾" opens the time and options (today's planned-trip screen: Leave at / Be there by); results as swipeable option cards with the comparison (fastest, most room to change, latest that's still in time, tight changes flagged); **Go** starts today's hands-free Fastest trip with its wake-up alarm.
4. Settings holds the map options (map style, live vehicles on/off), your places, and everything that leaves the home screen.
5. Out of the app (back burner): the Recomp (weight-loss) feature's screens and the workout tracker. The Recomp data stays stored, untouched, so it can come back. The weather stays (home chip; tap for the detail, incl. what to wear).

Phase 2 — the travel screens in the same look:
6. Fastest trip (Go), the ride screen, the alarm, the arrival/change screens and change bar, the stop/vehicle detail pages (train/bus page, live bus sheet), the platform alert and the morning screen — same information and behaviour, redesigned: one main thing per screen, big where it matters.

## 3. Non-goals

- Onboarding, accounts or setup for other users (phase 3+). No App Store work.
- Any change to how trips are planned, matched, followed or alarmed (TripManager, GoStore, LiveStore, Planner, SchoolAlarm, Net, VehicleMatch logic). This is a UI overhaul over the existing logic; only small read-only hooks the new screens need may be added.
- New data sources, HealthKit, a Watch app, widgets beyond keeping today's Live Activity working.
- Restoring Recomp or workouts.

## 4. Anti-goals (a failure even if it "works")

- Anything that makes an alarm late or missed, slows on-board detection, or adds Transitous load beyond what 0.18.1's politeness allows (Net.Polite: 4 in flight, 2 background, 429 pause).
- A home screen that again shows everything at once (Hick's law: fewer choices).
- A live map that drains the battery or freezes the launch (0.18.3 just fixed both).
- Copying Apple's, Google's or NS's look or wording; using another organisation's brand (the BUas design system is not used).
- New hard-coding of the owner's places, lines or school (the existing Veghel/BUas defaults stay where they are, but every new surface reads places and schedule from a store, never literals).

## 5. Constraints

- iOS 17, SwiftUI, MapKit for SwiftUI (`Map`, `MapCameraPosition`, `MapStyle`, `Annotation`); XcodeGen (`ios/project.yml`); unsigned CI build, sideloaded on a free Apple ID → **no new entitlements or capabilities**.
- No local Xcode: CI (Xcode 26, Swift 5 language mode) is the only compiler; pure logic goes in Foundation-only files in the hostless test target with unit tests; tests never touch the network, the real clock or real Caches, and never depend on sleep ordering.
- Field-log privacy unchanged (no coordinates, place names or query strings).
- The design rules (`.superpowers/redesign/rules.md`): one main thing per screen, big near targets for frequent actions, ≥ 44 pt hit areas, tabular numbers for every time/countdown, contrast ≥ WCAG AA, one accent colour, consistent icons (SF Symbols), radius rule (inner = outer − padding), specific headings, loading states, short eased animation for useful feedback only, no filler badges or embellishment.
- Dynamic Type and VoiceOver work on every new screen.
- Git: build on branch `claude/cool-mendel-odsmk9` (now carrying main 0.18.3; the workout tracker is kept in its history at a4539f2). Merge to main when done.

## 6. What exists today (to build on)

- `RootView` (Screens.swift) switches by trip phase: `HomeView` (idle), `GoView` (Fastest trip open), `RideView`, `AlarmView`, `ArrivalView` (transfer/finished, `ChangeBar` while browsing), with overlays for the platform alert, the morning screen and in-app notice banners. It forces `.preferredColorScheme(.dark)`.
- `HomeView` (Screens.swift ~93–1430): the station stage (`HomeStage` stills, Map.swift), the trip list (`TripRow`), boards ("Near you", `LiveStore.loadNear` + NearPick), the school alarm card (`SchoolAlarmCard`), Be-there-by pass (`ArrivePass`), tags (`NoticeBell`, `OutfitTag`, `RecompTag`), sheets (`PlanSheet`, `LiveSettingsSheet`, `StartSheet`, `StopSheet`, Recomp…), and four 30 s refresh loops (live times, planner + autoGo, school alarm + watched trains, weather) staggered in 0.18.3.
- Data the new home needs already exists: `LiveStore` (next trips, near boards and stops, `destination(dir)`), `Transit.liveVehicles(min:max:)` (vehicles in a box, used by `LiveAllSheet`), `/v1/map/stops`, `SchoolAlarm` (next class day, leave/alarm times, the trip), `Planner` (planned trip, Be there by), `GoStore` (Fastest trip), `OutfitStore` (weather), `Risk` (miss chance, comparison), `NearPick`, `StopsStore`, `WatchStore`/`LineWatch`, `Notices`.
- Places today: `Place.veghel`, `.buas`, `.breda`, `.denBosch`, `.eindhoven` (Model.swift) and `StopsStore.shared.veghel`; trip direction `.toSchool`/`.home`.

## 7. Approaches (considered; the user handed over the how)

1. **New screens beside the old, behind one switch (chosen).** Build the new home, plan, day sheet and (phase 2) travel screens as new views over the same stores; `RootView` shows the new ones when Settings → "New look" is on (on by default in 0.19.0). The old views stay one release as a fallback, then go in 0.20. Trade-off: two UI paths for a while; but the daily-use app always has a working way back, and every phase can ship.
2. Rewrite `HomeView` in place. Less code at the end, but no fallback while it's new, and its 1,300 lines tie loops, sheets and auto-open behaviour together — easy to break autoGo or the school alarm unnoticed.
3. Reskin the existing screens step by step. Safest per change, but the station-stage structure fights a map-first layout; it would end as approach 2 slowly.

## 8. Design — phase 1

### 8.1 Look (the new design system)
- System font (SF Pro / SF Pro Rounded for big numbers), tabular numbers everywhere a time or count shows.
- Follows the phone's light/dark setting (drop the forced dark); the map style follows too.
- Colours (light; the builder derives dark): text #14171A, secondary #5B636B, surfaces #FFFFFF / #F6F7F9 / #F1F3F5, **one accent: green #0E7A55** (on white 5.0:1), warning/late #A84219, mode colours for line pills: **train #2B3A55**, **bus #D9542B** (tram/metro/ferry: the builder picks two more of like lightness), your-location blue as the system's.
- Shapes: cards 22–24 pt radius, chips 20 pt, buttons ≥ 44 pt (main CTA 56 pt), shadows soft and few.
- Tokens live in one Swift file (`Design.swift`: colours, fonts, radii, spacing) and every new view uses only those.

### 8.2 Home (Concept C, artboard C1)
- **Map** full screen: `Map` with `.mapStyle(<Settings style>(pointsOfInterest: .excludingAll))`, user location shown.
  - **Stations and stops** as our own annotations: stations (rail) larger with a train glyph and name; bus stops small dots, names from zoom ≥ ~15; from `/v1/map/stops` for the visible area (Polite background lane, refreshed on camera idle, at most every 20 s, cached by tile).
  - **Live vehicles** (Settings toggle, on by default): pills with line and direction, from `Transit.liveVehicles` for the visible box, only while the home is on screen and the app is active, at most every 15 s, at most 60 drawn (nearest first), positions interpolated between refreshes with the 0.18.2 no-catch-up times; off below ~13 zoom, in Low Power Mode, and when the toggle is off.
  - **Follow me**: a 48 pt button; on = camera follows your location; any pan/zoom by hand turns it off; tap again to re-centre and follow.
- **Top:** a search field ("Search anywhere" → Plan, To focused) and a row of quick-place chips: Home, School (with travel time now, e.g. "Home · 44 min"), the user's pinned places, and "+" (add a place). Chips come from a Places store (§8.6).
- **Weather chip** (temperature + condition icon, from `OutfitStore`) under the search row on the right; tap → a small weather sheet (today, the walk, what to wear — the existing outfit text).
- **Bottom: departure cards**, swipeable (one stop per card; the nearest first): the station you're near and the 1–2 nearest stops by name (`NearPick`), each with its next 3 departures (line pill, destination, platform for trains, minutes until — live, late in #A84219 with "+4"). Swiping a card moves the map to that stop; tapping a departure opens its detail (today's train/bus page; phase 2 restyles it). Loading: skeleton rows; offline/saved: "as of HH:mm".
- **Next-trip nudge:** when a planned or school trip is due (today's `autoGo` window), a single card replaces the first departure card: "Leave in 9 min · 306 19:04" with **Go** — the hands-free screen still opens by itself as today.
- Notice bell and the old tags leave the home; notices move to the Your-day sheet's top (only when there is one) and to Settings → Notifications.

### 8.3 Your day sheet (artboard C3, reached by dragging the cards up)
- A sheet with detents: peek (the departure cards), large (Your day).
- **Your day** for a selected day (‹ day › switcher; today/tomorrow by default — tomorrow after the last class ends): a vertical timeline — wake-up alarm (time + on/off switch, `SchoolAlarm`), leave (time + the rides, compact), first class (time, until), leave for home (time, home around). A day without classes says so.
- **Coming up**: the next 2–5 school dates (breaks, project weeks, exams, cancelled days) from the schedule source; "No dates known" when it has none.
- **Watching**: active watched trains/line watches with their state, if any.

### 8.4 Plan a trip (artboard C2)
- From (default "My location") / To fields with a swap button; tapping a field opens a search list (stops, stations, places, recent).
- **"Leave now ▾"** opens time and options = today's `PlanSheet` content (Leave at / Be there by, the date) in the new look; **"Options"** holds what the planner already supports (nothing new).
- Results as swipeable option cards over a route preview on the map: times, duration, legs as pills, one comparison label each (Fastest / Most room to change / Latest still in time / Fewest changes), a tight change flagged in #A84219 with the minutes (0.18.3's grade-aware room).
- **Go · wake me before <stop>** (56 pt) opens the hands-free Fastest trip (`GoStore.open`) for that destination/deadline; for a later departure it becomes **Remind me** (today's planned trip with its leave reminder).

### 8.5 Settings
- Map: style (Standard, Muted, Satellite, Hybrid), live vehicles on/off.
- Places: Home, School and pinned places (name, stop or address); the school schedule source (today's); alarms (today's); notifications (today's notice log); "New look" switch; diagnostics/field log (today's).
- Recomp and workout entries removed.

### 8.6 Places store (small, generic)
- `Places` (Foundation-only, in the test target): ordered list of `{id, name, kind: home|school|custom, coordinate, stopIds}`; seeded once from today's defaults (Home = `StopsStore.veghel`/Veghel, School = `Place.buas`); quick chips and Plan's suggestions read it. Today's trip direction and schedule keep working as before; nothing else moves to it in this work.

### 8.7 Removal
- Recomp: remove its entry points (tag, sheets, scan, kcal notifications scheduling, `recomp-kcal-*` handling stays harmless) from the app UI; keep `RecompStore` data untouched on disk; keep its pure files and tests compiling (or drop them from the test target — the builder's call, data must stay readable later).
- Workouts: not on main; nothing to remove.

## 9. Design — phase 2 (same look, same behaviour)

- **Fastest trip (GoView):** the map with your way, one big "leave in / go now" card, the comparison of the next options, the "I'm on it" control, the watching state. Everything it does today stays.
- **Ride:** the big countdown to your stop, the next stop and the ones after, speed/distance small, the change ahead with its room (grade-aware), the music card, hold-to-end.
- **Alarm** and **arrival/change** (and the change bar while browsing): one clear action each.
- **Train/bus pages, live bus sheet, platform alert, morning screen:** the same content in the new components.
- Live Activity: unchanged in phase 2 (its look can follow later).

## 10. How it's built (decided)

- New views live in new files (`HomeMap.swift`, `DepartureCards.swift`, `DaySheet.swift`, `PlanTrip.swift`, `Design.swift`, phase 2: `GoNew.swift`, `RideNew.swift`, …); `RootView` picks old/new by the "New look" switch; stores are shared, not duplicated.
- Pure helpers with tests: departure-card grouping/ordering, the day timeline builder (from SchoolAlarm + trip), quick-chip ordering and travel-time label, vehicle selection for drawing (nearest N in a box, refresh gating by zoom/active/low power), Places seeding and decoding.
- Requests: every new fetch goes through `Transit`/`Net` (Polite), background lane unless someone is waiting on screen; refreshes gated by visibility.
- Ships as 0.19.0 / 88 after phase 2 (phase 1 may ship on its own as 0.19.0 if the user wants it sooner).

## 11. Left to the builder

Exact spacing and type sizes within the rules; the dark palette; SF Symbol choices; animation details (sheet, card swipe, follow); empty/loading/error copy; the annotation clustering threshold; how the weather sheet and the search list look; whether old views are kept as files or behind `#if` for the fallback release.
