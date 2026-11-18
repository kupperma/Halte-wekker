# Setup for any student: implementation plan

**Goal:** Haltewekker works for any university or college student in the Netherlands, with their own school, home,
places and timetable. Today it works for one commute, Veghel ⇄ BUas by bus and NS train. The current user keeps
working with zero setup. Their data becomes their saved profile, and the setup screen never appears for them.

**Status:** 0.22.0 and 0.23.0 built (see their "As built" notes); the rest is plan. Line numbers are at HEAD `6790c74` (0.20.9) and will move as steps land. Find each spot by the
function named.

**Verification:** there is no local Swift toolchain. As in the earlier plans, verify each step with a push to the work
branch and read the "Build iPhone app" run. Expect `** TEST SUCCEEDED **` and `BUILD SUCCEEDED`.

---

## 1. Audit: what is specific to this one user

The code has 321 lines that mention BUas, Veghel or Breda in `ios/App`, `ios/Shared` and `ios/Widget`, plus 109 more
in `ios/Tests`. 76 of the 321 are only comments. The real coupling is smaller than the count suggests, but it sits
deeper. Five `Place` constants are used as identities all over the app (about 110 code references), and they support a
**fixed two-route corridor model**.

### 1.1 Places (the constants everything compares against)

| What | Where |
|---|---|
| `Place.veghel` (2 OpenOV stop ids, 51.6137/5.5474), `.denBosch` and `.eindhoven` (DELFI ids), `.breda` (stoparea 17911), `.buas` (coordinate id `"51.5907,4.7932"`), `Place.all` | `App/Model.swift:16-31` |
| `Place ==` compares **only `key`**. Keys `"veghel"`, `"buas"`, `"bd"`, `"ht"` and `"ehv"` are stored in saved data: `kmMem` (`"bus:veghel"`), `lastMode`, Scores ideal keys `"c:veghel>ht"`, region ids, `NextTrip` dest keys and `PlanKey` | `Model.swift:13`, `TripManager.swift:205`, `Stops.swift:76`, `Scores.swift:52`, `TripManager.swift:2434-2440` |
| `RoutePlan.all` holds the two fixed routes (via Den Bosch, via Eindhoven). `legs(_:)` hardcodes bus Veghel→hub, then train hub→Breda | `Model.swift:136-151` |
| `Direction.word` is `"BREDA"` | `Model.swift:72` |
| `Fmt.place` maps `"END"`/`"START"` (Transitous's name for a coordinate end) to `"BUas"`, and collapses Veghel, Den Bosch, Eindhoven and Breda names | `Model.swift:204-213` |
| `StopsStore.defaultBoard`: Veghel Busstation + Bolkenplein. `defaultLines` are `305, 306, 158`. `veghel` is built from the board stops. `mode(for:)` returns bus for veghel and buas | `Stops.swift:28-29, 53-57, 76` |
| `PlacesStore.seed()` is seeded from `Place.veghel`/`Place.buas`. `place(_:)` maps Home or School back to the constants only when they are within 400 m of them, so a moved Home or School is **not** used by the trip direction, the school alarm or Plan | `PlacesStore.swift:17-23, 47-62` |
| `NearMe.places`: coordinates copied a second time, with keys. `atSchool` uses `places["buas"]!` | `Near.swift:10-16, 98-101` |
| Map start region, demo start point and region fallback all fall back to Veghel | `HomeMap.swift:265`, `Go.swift:863`, `TripManager.swift:932` |
| Stop search is biased to Veghel (`place=` Veghel coordinate) | `Transit.swift:229-231` |
| Outfit "at home" means within 5 km of Veghel | `Outfit.swift:235-240` |
| Reset everything re-seeds BUas/Veghel | `HomeMap.swift:52-58`, `Stops.swift:80-83`, `PlacesStore.swift:41` |

### 1.2 School schedule source

- **There is no BUas API and no roster URL.** `SchoolAlarm` reads EventKit calendars that the user picks
  (`school.cals`). In practice that is the calendar TimeEdit syncs into. This part is already generic. Any calendar
  subscribed on the iPhone works: an iCal link, Google, Outlook or MyTimetable. (`School.swift:149-188`)
- `looksLikeSchool` has hardcoded hints: `"timeedit", "buas", "rooster", "breda university", "school", "timetable"`,
  and in event text `"timeedit", "buas", "hopmansstraat"`, which is BUas's street. (`School.swift:155-164`)
- The planning target is hardcoded: `Transit.plan(from: homeStart(), to: .buas, …)`. (`School.swift:260`)
- `homeStart()` remembers a position "at home" only when it is within 6 km of Veghel. (`School.swift:349-359`)
- `earlyMinutes` (default 10) and `wakeMinutes` (default 60) already exist. The arrival buffer is
  `school.early`. (`School.swift:29-32, 79-80`)
- UI copy says "From your TimeEdit timetable", "At BUas … before class", "AT BUAS" and "Pick only the calendar TimeEdit
  fills". (`School.swift:517, 534, 540, 582, 615, 625, 649`)
- Permission strings in `project.yml:33-35` say "school timetable" and are already generic.

### 1.3 Transit specifics: corridor stops, lines and stations

- **Home panels** are fixed planner jobs: Eindhoven/Den Bosch→Breda by rail, Breda→BUas by bus, hubs→Veghel by bus,
  plus the Veghel board. The panel enums are named `buas` and `toVeghel`. (`Live.swift:29-30, 599, 612-660, 743-756`)
- **Direction guess and the start point:** Veghel within 2500 m counts as home. Going home, the BUas campus within
  500 m counts as school. (`Live.swift:470-474`, `Live.swift:377 destination()`)
- `Transit.nextTrips(dir)` plans veghel⇄buas. (`Transit.swift:560-561`)
- `DoorTrip.via` returns `"Den Bosch"` or `"Eindhoven"` only, and the old home maps it back to a fixed route.
  (`Transit.swift:64`, `Screens.swift:733, 928, 1075, 1202`, `PlanTrip.swift:733`)
- **TripManager:**
  - `guessFromPlace`: near Veghel 5 km means to school; near Breda or BUas 6 km means home. (`:252-256`)
  - `finalName` returns `"Breda"`, which is also the Live Activity's `finalName`. (`:204`)
  - On a fixed route, the first leg watches both hubs. (`:1374, 1418-1425, 2334`)
  - Auto-start regions are `Place.all` minus buas, at 350 m around Veghel and 300 m around stations, plus a `"school"`
    region at BUas. (`:2429-2441`)
  - `autoStartTrip` recognises trips by station-name words ("hertogenbosch", "eindhoven", "breda", "veghel").
    (`:2493-2510`)
  - The school region entry fires `maybeAutoHome(BUas)`. (`:799`)
  - The preview Live Activity says "Bus 306 to Veghel", "Intercity to Breda" and "bus 3 to BUas". (`:2709-2715`)
- **Friend's train planner:** trains Eindhoven/Den Bosch⇄Breda, buses Veghel→hub and Breda→BUas.
  `PlanOption.station` reads `from == .breda`. (`Planner.swift:4-48, 113-126, 205-210, 255-272`)
- **NS:** `NSStore.code` knows only `ehv→EHV, ht→HT, bd→BD`. Platforms, crowding and train size therefore only appear
  for those three stations. (`NS.swift:72, 232-284`)
- **Relay:** the relay URL `https://haltewekker-relay.tsfaw1.workers.dev` is hardcoded at `NS.swift:71`. `relay/worker.js`
  itself is generic: station codes are only regex-validated and no place is sent. Its NS key is one person's free key.
- How steady each line is: hardcoded lines `306, 305, 158, 1, IC, SPR` and the corridor station ids.
  (`SteadyScreen.swift:17, 59`)
- Line colours for 306, 305 and 158. These are cosmetic and harmless. (`Paper.swift:27-34`)
- The metro map is hand-drawn: Breda–Tilburg–Boxtel–Den Bosch/Eindhoven, the 305/306 to Veghel, and the "306 ♥"
  sticker. (`Map.swift:116, 176-239, 267-289`)
- The scoreboard only scores fixed routes, with keys `c:veghel>ht` etc. and the label "to Breda". (`Scores.swift:22, 50-56`,
  `TripManager.swift:480`)

### 1.4 UI text that names the places

These are all derivable from the profile:

- `Components.swift:214, 235, 252-254`; `Boards.swift:474`; `DetailsNew.swift:256`; `Morning.swift:304`;
  `NextTripHome` (destName)
- Plan sheet: "To Breda", "Leave Veghel at", "Be at BUas by", "your Veghel stops", friend's train copy.
  (`Features.swift:213-223, 333, 365, 387-420, 462`)
- Stop list "Your home stop"/"Your school stop". (`Features.swift:581`)
- Placeholders: "Breda Nassausingel", "Veghel Bolkenplein", "305, 306, 158", and "Back to Veghel Busstation and
  Bolkenplein". (`Features.swift:628, 705, 722, 725`)
- Destination menus "To school (BUas)"/"Home (Veghel)". (`Go.swift:1050-1051`, `GoNew.swift:84-85`, `Screens.swift:463-464`)
- Old home copy. (`Screens.swift:406, 420, 440-444, 548, 738, 954-961, 1251-1257, 1283-1289, 1328-1355, 1412, 1591, 2130,
  2179, 2236`; `RideNew.swift:78, 611, 649`)
- Labels built from `a.out ? "BUas" : "home"`. (`HomeLoops.swift:115-121, 166-195`; `Screens.swift:25, 339-372`)
- Settings footer: "Your trip direction and the school alarm still use today’s home and school".
  (`SettingsNew.swift:109`)
- Toasts: "You’re in Veghel, so it’s set to going to Breda", "You’re at BUas, so it switched to Home".
  (`TripManager.swift:256, 271`)

### 1.5 Mostly names only, no logic

The task listed these files as suspects. They are fine.

- `Shared/Theme.swift`: `.toBreda` is a palette name. It can be renamed later or left alone.
- `Shared/TripAttributes.swift` and `Widget/TripLiveActivity.swift`: examples in comments only. The values come from
  `TripManager`.
- `RideGuards.swift`, `Power.swift`, `OutfitWords.swift` and `Watch.swift`: names appear in comments only. The logic
  takes names and coordinates as parameters.
- `Morning.swift:19`: the "Breda" backdrop is a picture choice.
- `Demo.swift` and `Go.swift:854-919` (the demo): pretend lines 300/306 and "Breda" as the target. These are cosmetic.

### 1.6 Tests

- 109 mentions, all **fixtures** for generic logic: NearPick, OutfitWords, RideGuards' Breda/Den Bosch track geometry,
  StopLabel, Snapshot, Power `RegionSpec(id: "veghel")` and RideAhead "change at Breda". None of them needs changing.
- `NextTripTests` uses dest keys `"buas"`/`"veghel"`. They stay valid because the plan keeps those keys (see 3.1).
- `BatteryLogTests:254` asserts that no "Veghel"/"Breda"/coordinates leak into the log. Keep it.

### 1.7 Biggest blockers

1. `Place.veghel` and `.buas` are compile-time constants used as identities (keys) in saved data, comparisons and
   nonisolated `@Sendable` planner closures. They cannot simply become a `@MainActor` store read.
2. A fixed corridor model (`RoutePlan.all`, the home panels, the friend's train, auto-start by station-name words, the
   scoreboard and the metro map) assumes bus → one of two hubs → train to Breda → bus to campus.
3. `PlacesStore.place(_:)` honours an edited Home or School only for the chips and Plan. The school alarm, direction,
   live trips and Fastest trip ignore it.
4. The old "station look" home (`Screens.swift`, `Map.swift`, `Boards.swift`) is the most corridor-bound code.
5. NS enrichment only knows 3 station codes, and the relay runs on one person's NS key.

What helps: the new look's core flows are already **door to door**. These are Fastest trip (`GoStore.open(to:)`), the
school alarm's `Transit.plan(from:to:arriveBy:)`, live "from here" trips, `RoutePlan.from(DoorTrip)` for rides, and
`LiveStore.onBoardTrips`. Pointed at another Home and School, they work.

---

## 2. Design decisions

1. **Keep the role keys.** Home stays `key "veghel"` and School stays `key "buas"` as internal role ids. Name, ids,
   coordinate and spoken name come from the profile. Saved data, `NextTripTests` and every `p == .veghel` comparison
   keep their meaning as role checks. When a role's location moves by more than 400 m, the caches keyed by that role
   are cleared (3.1, step 6).
2. **PlacesStore stays the store of places.** `places.v1` already holds Home, School and pinned places, and it is
   decoded leniently and tested. A new small `profile.v1` holds the rest:
   - school catalog id and campus
   - `corridor`
   - schedule source
   - manual week
   - `setupDone`
   - `version`
   
   No second copy of coordinates is kept.
3. **Corridor is optional.** Write `Profile.corridor: Corridor?`. The legacy value `.veghelBreda` turns on every fixed
   feature listed in 1.3. When it is nil, the app runs door to door only. Corridor features are hidden, not broken.
   Detect the corridor with a pure function: Home within 6 km of Veghel **and** School within 400 m of BUas means
   `.veghelBreda`. A reinstall that picks BUas and a Veghel home therefore gets everything back.
4. **Non-corridor profiles always use the new look.** The "New look" switch (`NewLookSwitch`, `Screens.swift:2286`)
   is shown only when `corridor != nil`. This avoids generalising the old station home.
5. **Schedule sources**, in order of preference:
   - (a) A calendar already on the iPhone (today's flow).
   - (b) A pasted roster or iCal link. The app turns it into `webcal://` and opens it, iOS shows its own *Subscribe*
     dialog, and the app then auto-picks the new subscribed calendar (`EKCalendar.type == .subscription`, found by
     diffing ids before and after). This needs no ICS parser and no background fetching code.
   - (c) Fixed weekday times (`ManualWeek`).
   - (d) "Later".
   
   An in-app ICS fetcher is explicitly not planned (see 4).
6. **Thread safety for roles.** `Place.home` and `Place.school` are `static var`s that read a
   `RoleSnapshot` behind an `OSAllocatedUnfairLock`. `PlacesStore` and `StopsStore` update it on every `persist()`.
   This makes them safe in the `@Sendable` closures in `Planner.swift:205` and `Live.swift:639`.

---

## 3. Steps (each one shippable, behaviour unchanged for the current user)

Global rules:

- Trip, alarm, wake-at-stop and Live Activity behaviour does not change.
- For the legacy profile, every replaced string and every `Place` must be **byte-identical** to today's.
- Each new pure file is Foundation-only and is appended to `HaltewekkerTests → sources:` in `ios/project.yml`.

### 3.1 Release 0.22.0: profile under the hood (no visible change for the current user)

1. **`App/Profile.swift`** (pure, Foundation only). It contains:
   - `struct Profile: Codable`: `version`, `setupDone`, `schoolCatalogId?`, `corridor: Corridor?`,
     `schedule: ScheduleSource` (`.calendars` | `.manual(ManualWeek)` | `.none`) and `calendarHints: [String]`.
   - Postel decoding, as in `SavedPlace`.
   - `enum Corridor: String, Codable { case veghelBreda }`
   - `ProfileLogic.legacy(places:)`
   - `ProfileLogic.isExistingUser(keys: Set<String>)`. It returns true if any of these keys exists: `places.v1`,
     `school.on`, `dir`, `boardStops`, `savedStops`, `trips`, `kmMem`, `sound`, `ui.newLook`, `customDest`,
     `noticeLog`.
   - `ProfileLogic.corridor(home: GeoPoint, school: GeoPoint) -> Corridor?`
   - `ProfileLogic.load(data:existing:) -> Profile`. An existing user gets the legacy profile with `setupDone = true`,
     `corridor = .veghelBreda` and `calendarHints = ["timeedit", "buas", "breda university", "hopmansstraat"]`.
     A fresh install gets `setupDone = false`.
2. **`ProfileStore`** (`@MainActor`, in `PlacesStore.swift` or a new `ProfileStore.swift`). It is loaded first, from
   `HaltewekkerApp.init()` before anything touches `PlacesStore.shared`. This matters because `PlacesStore.init`
   persists the seed at once (`PlacesStore.swift:13`), and that would make a fresh install look like an existing user.
   In 0.22.0 a fresh install still gets the legacy profile, so nothing changes yet. Only the flag is recorded.
3. **Role places.** In `Model.swift`:
   - `Place.veghel` becomes `static var home: Place { RoleSnapshot.current.home }` and `Place.buas` becomes
     `static var school`, with keys `"veghel"` and `"buas"` kept.
   - Keep `static let legacyVeghel` and `legacyBuas` with today's exact values. For the legacy profile the snapshot
     returns exactly these. Do the rename mechanically (`.veghel` → `.home`, `.buas` → `.school` on `Place`) in its
     own commit.
   - Move `.denBosch`, `.eindhoven` and `.breda` into `Corridor.veghelBreda.stations` (the hubs and the school
     station). `Place.all` becomes `[home, school] + (corridor?.stations ?? [])`.
   - `StopsStore.veghel` becomes `StopsStore.homePlace`. `defaultBoard` and `defaultLines` come from the profile:
     the legacy value, or the board stops chosen in setup with an empty line list.
4. **PlacesStore ↔ roles.** `PlacesStore.place(_:)` always returns the role `Place` for Home and School. The 400 m
   legacy test moves into `RoleSnapshot`: legacy corridor and still near means the exact legacy constant; otherwise
   the place is built from the `SavedPlace`. `direction(of:)` then works for any Home or School. `reset()` re-seeds
   from the profile, not from the constants. Remove the `SettingsNew.swift:109` caveat.
5. **Point the generic code at the roles.** This is a mechanical change. For legacy it keeps the same values:
   - `NearMe.places` and `atSchool` (`Near.swift`)
   - `SchoolAlarm.homeStart` (6 km around `Place.home`) and the planning target (`School.swift:260, 349-359`)
   - `Live.swift:470-474` radii
   - `Transit.findStops` bias (`place=` is the last fix, or else Home)
   - `HomeMap.swift:265` and `Outfit.swift:235-240`
   - `TripManager.guessFromPlace` (role-based; keep the corridor's `near(.breda, 6000)` only when the corridor is on)
   - `maybeAutoHome`/the school region (`TripManager.swift:799, 2434`)
   - `Fmt.place` `"END"`/`"START"` → `RoleSnapshot.current.school.short`
   - `TripManager.finalName` (`"Breda"` only for a corridor fixed route, else `Place.school.short`)
6. **When a role moves.** If Home or School moves more than 400 m, `RoleMove.clear(role:)` removes:
   - `school.homeLat` and `school.homeLon`
   - `kmMem` entries ending `:veghel` or `:buas`
   - `lastMode[role]`
   - the SnapshotStore answers (`prune(olderThan: 0)`)
   
   It also forces a replan of `school.week` (`SchoolAlarm.refresh(force: true)`) and re-registers regions
   (`updateWatching(force: true)`), and recomputes `profile.corridor`.
7. **Gate the corridor features** on `profile.corridor != nil` (all true for legacy):
   - `RoutePlan.all` (empty without a corridor) and `DoorTrip.via` (hub names from the corridor)
   - LiveStore panels: without a corridor, only the `.board` path (home board stops) runs, as the new look already
     does for `need == .board`
   - Plan sheet mode 2 "Friend’s train" (hidden)
   - `autoStartTrip` and the station regions (without a corridor: none in 0.22.0, a generic version in 0.24.0)
   - Scores
   - the Map tab and metro map
   - `SteadyScreen` station ids
   - the "New look" switch
8. **Strings from the profile.** Add a pure `RoleWords` with `schoolShort`, `homeTown` and `toSchoolWord`. For legacy
   these are "BUas", "Veghel" and "Breda", the same as today. Replace the strings listed in 1.2 and 1.4. For example,
   `"At BUas"` becomes `"At \(RoleWords.schoolShort)"`, and "From your TimeEdit timetable" becomes "From your school
   timetable" (legacy keeps "TimeEdit" through `calendarHints.first`).

**Size:** M–L. About 25 files touched, mostly mechanical. Roughly 700–900 changed lines, 2 new files and about 150
lines of tests.

**As built (0.22.0, build 101).** Where the code made the plan above change:

- **Files.** `Place` lives in `Model.swift`, which the test target can't compile, so the pure part of the roles is
  `App/RoleLogic.swift` (`RolePlace`, `RoleInputs`, `Roles`, `RoleLogic`, and `Corridor.veghelBreda.stations`/`hubs`)
  and the lock is `App/RoleSnapshot.swift` (app only; it also bridges `RolePlace` → `Place`). `Place.legacyVeghel`,
  `.legacyBuas`, `.denBosch`, `.eindhoven` and `.breda` are built from those constants, which the tests check field
  by field. The store is `App/ProfileStore.swift`. `Profile.schedule` needs a type, so a minimal
  `App/ManualWeek.swift` (one first-class time per weekday, Postel) exists now; `lessons(from:days:tz:)` is 0.23.
- **The snapshot never reads a store.** `PlacesStore`, `StopsStore` and `ProfileStore` hand it their part on load and
  on every save (`setPlaces`, `setBoard`, `setProfile`), so no store's init waits on another's. `HaltewekkerApp.init`
  touches `ProfileStore`, then `PlacesStore` and `StopsStore`, so a background wake-up for the school alarm plans
  with your roles too.
- **Home's ids.** `Place.homeBoard` (and `StopsStore.homePlace`, 0.21's `StopsStore.veghel`) puts the board's stops in
  place of Home's ids only for the legacy Home. A Home of your own plans from its own stops, because after a move the
  board may still be in Veghel. The live board shows `StopsStore.boardIds` (the board's stops, or Home's when there
  are none). `defaultBoard`/`defaultLines` are today's on the corridor and empty off it.
- **`Place.all` keeps 0.21's order** on the corridor (`home, ht, ehv, bd, school`), as the stop lists show it; off it,
  `[home, school]`.
- **Stop search stays biased to Home**, not the last fix: a last-fix bias would change the current user's results.
- **Migration also clears.** The first launch with profiles compares an earlier version's Home and School with
  today's; one already moved in 0.21's Your places (which nothing used then) gets the same `RoleMove` clearing as a
  move. `ProfileLogic.load(data:existing:places:)` takes the places, so the legacy corridor is the one they are on.
- **`RoleMove`** clears `school.homeLat`/`homeLon` only when Home moves (they are where it last saw you at home). The
  live copies follow a `rolesMoved` notification (`TripManager.kmMem` and the regions, `LiveStore`'s lists);
  `StopsStore.forgetModes` and `SchoolAlarm.refresh(force:now:)` are called directly.
- **Reset everything**: on the corridor back to today's seed (from the constants, never the roles); off it Home and
  School stay and only the pinned places go.
- **Strings.** The old station look, the metro map and the scoreboard are only reachable on the corridor (the switch
  is hidden and `RootView` forces the new look off it), so their copy is unchanged. Shared and new-look copy reads
  `RoleWords.current` (school alarm, Plan sheet, Be there by passes, destination menus, toasts, notification bodies).
  Also gated: the Leaderboard link and "Back to Veghel Busstation and Bolkenplein".
- A saved profile with no `setupDone` reads as set up.

### 3.2 Release 0.23.0: first-run setup

The new look throughout: `DS` tokens, `DSPrimaryButton`, `DSQuietButton`, `DSHeader`, `DSNote`, and grouped forms as
in `SettingsNew.swift` and `OutfitNew.swift`. Fresh installs get `setupDone = false` from this release on.

**Presenting it:** a `.fullScreenCover` in `RootView` (`Screens.swift:4`) shows `SetupFlow` when `!profile.setupDone`
and `trip.phase == .idle`. It never shows for a legacy profile, because `setupDone` is already true. Settings ›
"Your school and home" › "Set up again" reopens it, pre-filled. "Reset everything" keeps the profile.

**Screens** (new file `App/SetupFlow.swift`, about 500 lines; step logic in pure `SetupLogic`):

1. **Welcome.** One line on what the app does (wakes you at your stop and for your first class), and *Start*.
2. **School** (required):
   - A search field over a bundled `App/Schools.json`, about 60 entries: the 14 research universities, the main
     universities of applied sciences, and the larger MBO colleges. Each entry has `id`, `name`, `short`, `aliases`,
     `campuses: [{name, city, lat, lon}]`.
   - Under the list: "Search an address, stop or station" (`Transit.findStops` and a geocode without `type=STOP`).
   - Several campuses mean a campus pick.
   - The result becomes the School `SavedPlace`, with `stopIds` empty so trips plan to the coordinate, as BUas does
     today. Set `profile.schoolCatalogId`.
3. **Home** (required): "Use where I am now" (when-in-use location) or search. Then pick 1–3 nearby stops
   (`Transit.nearStops`) as the home board. These are Home's `stopIds` and `StopsStore.boardStops`, with lines empty
   meaning all buses.
4. **Other places** (optional): add with `PlaceSearchSheet` (`SettingsNew.swift:115`). Suggestions: "Work", "Sports",
   "Station".
5. **Timetable** (optional). Four choices:
   - *On this iPhone*: request EventKit access, then `SchoolCalendarsView`, using hints from `calendarHints` plus the
     school's `short`/`name`.
   - *I have a roster link*: paste an `http(s)`/`webcal` URL, `SetupLogic.webcalURL(_:)` normalises it, then
     `UIApplication.open`. On return, `SetupLogic.newSubscription(before:after:)` picks the new calendar. If none
     appeared, a note says "Add it in Settings › Calendar › Accounts, then pick it here".
   - *Same times every week*: a weekday grid with a first-class time per day (a `ManualWeek`).
   - *Later*.
6. **Arrival:** "Be there N min before class" (`earlyMinutes`, 0–45) and "Wake me N min before I leave"
   (`wakeMinutes`). A "Wake me for school" toggle asks for AlarmKit or notifications here, in context.
7. **Done:** a summary card (school, home, stops, timetable), "Try a pretend trip" (the existing demo) and *Open the
   map*.

**Test option (asked for by the user, 2026-11-18):** Settings › "Your school and home" › **"Test the setup as a new
user"**. It lets the current user run the real first-run flow without losing their own setup:

- Before the flow opens, snapshot everything setup can change into one `SetupBackup` (the profile, PlacesStore's
  places, `StopsStore.boardStops`, the school calendar picks, `earlyMinutes`/`wakeMinutes`, the manual week). It is
  stored under its own key (`setup.backup.v1`), so a crash mid-test can't lose it.
- The flow then runs exactly as for a fresh install, starting from an empty profile with `setupDone = false`, so the
  user sees what a new student sees (welcome, empty fields, permission asks in context).
- On *Done*, the test profile becomes live, so the user can really try trips, the school alarm and the board with
  the other school/home. A slim banner on the home ("Test setup · Back to my own") stays until they go back.
- **"Back to my own"** (banner, and in Settings) restores the backup exactly and deletes it. Caches that depend on
  places (plans, kmMem, region ids) are cleared on both switch and restore.
- Cancelling the flow at any step restores right away. "Set up again" (the real one) is unchanged and makes no
  backup.
- Never start the test while a trip is running (`trip.phase != .idle` → the button is disabled with a note).
- Pure logic, unit tested: `SetupBackup` round-trip (encode → restore gives identical stored values) and "restore
  after a partial test".

**Other work in this release:**

- `SchoolAlarm.firstClasses()` branches on `profile.schedule`: `.calendars` (today's code), `.manual` →
  `ManualWeek.lessons(from:days:tz:)` or `.none`. For `.manual`, `schoolEvents` makes start-only events, so Your day
  shows no class end. Skipped days (`SchoolSkip`) work unchanged. Holidays use the same "turn this day off".
- `looksLikeSchool` becomes a pure `SchoolHints.matches(title:source:eventText:hints:)`. It takes generic hints
  (`timeedit`, `mytimetable`, `xedule`, `untis`, `rooster`, `lesrooster`, `timetable`, `school`) plus the profile's
  hints and the school name. Legacy hints equal today's list.
- A tool script `ios/tools/schools.js` builds `Schools.json` by geocoding each campus with Transitous `/v1/geocode`.
  A person checks the output; do not type coordinates by hand.

**Size:** L. About 1,300–1,600 lines: about 500 setup UI, about 250 pure logic, the JSON, the tool and about 250 lines
of tests.

**As built (0.23.0, build 102).** Where the code made the plan above change:

- **Files.** The UI is `App/SetupFlow.swift` (the steps, `PlaceFinderSheet`, `ManualWeekEditor`, the test banner and
  Settings' "Your school and home"); `App/SetupStore.swift` (app only) decides when it shows and saves Done. The pure
  parts are `SetupLogic.swift` (steps, `SetupDraft`, `webcalURL`, `newSubscription`, the home board's stop choices and
  what Done saves), `SetupBackup.swift`, `SchoolHints.swift`, `SchoolCatalog.swift` and `ManualWeek.lessons`, each in
  the test target with `Schools.json`.
- **Nothing is saved until Done.** Every step edits a `SetupDraft`; Done writes the profile, then the board, then the
  places (`PlacesStore.replaceAll`, so a Home or School that moved clears what was learnt for it, as any move does),
  then the school alarm's calendars, times and on/off. So Cancel ("Set up again") and End test change nothing, and a
  new install that quits mid-way simply sees the setup again.
- **The test's backup** (`setup.backup.v1`) is the stored values of the keys setup writes (`profile.v1`, `places.v1`,
  `boardStops`, `boardLines`, `school.on`/`cals`/`early`/`wake`) and the ones learnt for Home and School (`kmMem`,
  `lastMode`, `school.homeLat`/`homeLon`), a missing key kept as missing. It is taken before the flow opens. Done marks
  it `live`. A backup that isn't live at launch (the app stopped during the flow, or while Done saved) is put back
  before any store starts; a live one waits for "Back to my own". Plan differs: on going back, the learnt values are
  **restored**, not cleared (clearing would lose the current user's wake distances); the saved answers are cleared and
  `rolesMoved` re-registers the regions and reloads `kmMem` on both switch and restore, and the school week is planned
  again. Going live clears what was learnt for both roles. While a test runs, the school alarm follows the test setup.
- **Behind the first-run cover** the home isn't drawn (a plain page), so nothing plans for the placeholder places of
  a new install. The cover waits for `trip.phase == .idle`; the test banner sits in the top safe area of `RootView`,
  over either home, only while idle and Fastest trip is closed. Settings' entry is in both looks.
- **School.** A catalog pick saves the campus coordinate with no stop ids, `schoolCatalogId`, `campus`, and the
  calendar hints `[short, name]`. A search pick (an address, place or stop, `Transit.findPlaces`: the geocoder with no
  type) keeps a name you can edit. BUas from the list with a Veghel home gives the corridor back.
- **Home's stops** come from `/v1/map/stops` around home grouped by stop area (a bus station's platforms are one
  choice, by its parent id) or by name; the nearest is picked to start with. They are Home's `stopIds` and the board,
  lines empty. "Set up again" leaves the board and lines alone unless you change the stops or Home.
- **Schools.json: 78 schools, 117 campuses**, every coordinate from Transitous by `ios/tools/schools.js` (seed
  `schools-seed.json`; `schools-review.txt` lists each match for a person to check). Horizon College and ROC Friese
  Poort are left out (nothing matched); their students use the address search.
- **SchoolHints**: the legacy profile's hints give 0.22's two lists exactly (names, and event text); any other profile
  gets the generic words plus its own hints of 4 letters or more ("UU" would match too much).
- **ManualWeek** for Your day: start-only events (`ComingUp.Event.startOnly`), left out of the classes' end and of
  Coming up. Settings › School alarm shows "Your week" (editable) or, with no timetable, the two ways to set one.
- **Permissions** use the existing paths and Info.plist strings: when-in-use location through `NearMe.locate(ask:)`,
  calendar through `SchoolAlarm.askCalendarAccess`, AlarmKit or notifications through `WakeAlarm.requestPermission`.
  No new entitlement or usage string.

### 3.3 Release 0.24.0: works well anywhere (door to door polish)

- **Generic auto-start.** Without a corridor, region-watch Home's board stops (350 m, exit) and School (entry for
  auto-home, exit for auto-start). On exit, `matchVehicle` → `LiveStore.onBoardTrips(here, to: dest, tripId:)` →
  `RoutePlan.from`, the same path Go uses (`Go.swift:808`, `TripManager.swift:2077`). The destination is the role you
  are not at. A pure `RoleRegions.wanted(profile:places:autoStart:autoHome:) -> [RegionSpec]` reuses `RegionPlan.same`.
- **NS for any station.** A bundled `NSStations.json` (code, UIC, name), generated by a tool through a new relay
  passthrough `/ns/stations`. `NSCodes.code(forStopId:)` reads the UIC out of DELFI ids (`000008400319` → `8400319`)
  and falls back to the name. `NSStore.code(_:)` uses it, so platforms and crowding appear at every NS station.
- **Home "next to school" panel.** Without a corridor, the old trains/campus-bus panels are replaced by the next 4
  door-to-door trips (`Transit.nextTrips` with roles) under the home board.
- **Scoreboard for door-to-door trips**, keyed `home→school` and `school→home`. Corridor profiles keep their keys.
- **Plan sheet:**
  - "Be there by" and "Leave at" use role names.
  - "Friend’s train" becomes "A train’s time" between the station nearest Home and the one nearest School (pure
    `NearestStation.pick`), or stays hidden when either side has no rail within 5 km.
- Live Activity preview text (`TripManager.swift:2709-2715`) and the demo use role names.

**Size:** M. About 700–900 lines, plus the relay route and the tool.

### 3.4 Optional later: a corridor for others

Generalise `Corridor` from a single case to data: home stops, 1–3 hub stations, the school station and the last-mile
mode. Setup could then offer "Your usual change stations", derived from the most common change in the last 10 planned
trips. This depends on the 0.24 field results, so it is **not** in the release split.

---

## 4. What stays BUas-only, or can't be generalised yet

| Stays | Why |
|---|---|
| Metro map (`Map.swift`), station and board artwork (`Media/map-*.jpg`, `board-*.jpg`), "306 ♥" sticker, the old station-look home | Hand-drawn for this corridor. Generic users get the map-first new home. |
| Fixed routes via Den Bosch/Eindhoven, watching both hubs on leg 1, auto-start by station-name words, corridor panels, friend's train with two hubs | They rely on known hubs and name matching that were field-tested on this line. Generalising them without field data risks false auto-starts. Planned door-to-door versions are in 0.24 and 3.4. |
| Line colours 305/306/158 and the steadiness lines (`Paper.swift`, `SteadyScreen.swift`) | Cosmetic. Others get the default mode colours, and steadiness is learnt per line anyway. |
| Relay and NS key (`NS.swift:71`) | One personal free NS key on one Cloudflare worker. Fine for a few students. A public release needs its own relay or rate limit and a key policy. Not code work here. |
| Transitous load | Volunteer-run. The existing budgets (`Net.swift`) are per device, so many users scale linearly. Keep the request diet; no change planned. |
| In-app ICS fetching | iOS subscriptions already refresh and parse ICS, handle time zones and RRULE, and keep the URL out of the app. A fetcher would need background refresh, parsing and secret storage. Note: iOS refreshes subscribed calendars on its own schedule, so a roster change can arrive late. The UI says so. |
| `Europe/Amsterdam` time zone and English copy | The app targets the Netherlands. Dutch copy is a separate project. |

---

## 5. Pure logic with unit tests (append each file to `HaltewekkerTests → sources` in `ios/project.yml`)

| File | Tests |
|---|---|
| `App/Profile.swift` | Legacy detection from key sets (fresh → setup; any listed key → legacy). Postel decoding (unknown schedule → `.none`, missing corridor → nil). `corridor(home:school:)` at the 6 km and 400 m edges. A legacy profile round-trips. |
| `App/RoleSnapshot.swift` (pure part: `RoleLogic`) | **The legacy home and school equal `legacyVeghel` and `legacyBuas` field by field** (name, short, ids, coordinate, spoken). A Home moved 401 m gives a profile-built place with key `"veghel"`. Board ids replace Home's ids. |
| `App/RoleMove.swift` | Which keys to clear for a given move (`kmMem` filter, lastMode). Under 400 m: nothing is cleared. |
| `App/RoleWords.swift` | Legacy strings are exactly "BUas", "Veghel", "Breda", "At BUas 08:41". A generic profile gives "At Fontys 08:41". `END`/`START` mapping. |
| `App/ManualWeek.swift` | The next 8 days of lessons across a DST change (last Sunday of October), a day with no class, and a time before now today being skipped. |
| `App/SchoolHints.swift` | The legacy hint list matches today's cases (TimeEdit, BUas, Hopmansstraat). Generic hints are case- and diacritic-insensitive. |
| `App/SetupLogic.swift` | `webcalURL` (`https`→`webcal`, `webcal` kept, junk → nil, whitespace trimmed). `newSubscription(before:after:)`. Step order and `canFinish` (school and home required). |
| `App/SchoolCatalog.swift` | `Schools.json` decodes. Search by alias ("tue", "Fontys Venlo"), diacritics ("Hogeschool Inholland"), and campus pick when there are several. Every campus is inside the NL bounding box. |
| `App/NSCodes.swift` (0.24) | UIC parsing from DELFI ids. Unknown id → name fallback → nil. |
| `App/RoleRegions.swift` (0.24) | Corridor → today's exact `RegionSpec` list (ids, radii, entry/exit). No corridor → home stops plus school. |

Existing fixtures that name Veghel, Breda or BUas stay as they are.

---

## 6. Release split

| Release | Content | Rough size | Current user sees |
|---|---|---|---|
| **0.22.0** | Profile, roles, migration, generic code pointed at the roles, corridor gating, strings from the profile, role-move cache clearing | M–L, about 800 lines and about 150 test lines | Nothing, except that an edited Home or School in Your places now drives everything |
| **0.23.0** | Setup flow, school catalog, calendar/link/manual timetable, arrival buffer, "Set up again" | L, about 1,500 lines | Nothing (`setupDone` is already true). New installs see the setup |
| **0.24.0** | Generic auto-start, NS stations table and relay route, generic home panel and scoreboard, Plan sheet and Live Activity text | M, about 800 lines | Platforms and crowding at more stations |
| later | Corridor as data (3.4) | M | Not planned yet |

**Ship gate for each release:** run the legacy profile through the existing test suite plus the new equality tests,
then do one real Veghel → BUas morning: the school alarm, Fastest trip, wake-at-stop, the Live Activity, and an
auto-start from the Veghel stops.
