# Haltewekker for Android: plan

The Android version of Haltewekker, built from the iOS app (`ios/`, SwiftUI) as the reference. It lives in
`android/` (one Gradle project), with this plan in `docs/android/`. The iOS app and the relay are not changed by it.

Status: **A1 (0.1.0, version code 1), A2 (0.2.0, version code 2), A3 (0.3.0, version code 3: Friends), A4 (0.4.0, version code 4: Friends extras and shared ride logs) A5 (0.5.0, version code 5: Friends map first, the seat picker, the test friend) and A5.1 (0.5.1, version code 6: 1st class in the seat picker) A6 (0.6.0, version code 7: iOS 0.32–0.37) and A7 (0.7.0, version code 8: the A6 leftovers, iOS 0.37.1, 0.38, 0.39.1) built.**

## Architecture

| Part | Choice | Why |
|---|---|---|
| Language | Kotlin 2.1 (JVM 17) | The platform's language; close enough to Swift that the pure logic ports line for line. |
| UI | Jetpack Compose, Material 3 | Declarative like SwiftUI. Themed with the iOS new look's tokens (below), not the Material defaults. |
| Build | Gradle 8.14 (Kotlin DSL), version catalog `gradle/libs.versions.toml`, AGP 8.9 | Standard, reproducible on Linux CI. |
| Min / target SDK | 26 (Android 8.0) / 35 | 26 gives notification channels, adaptive icons, `java.time` and `VibrationEffect` without shims; covers nearly every phone in use. |
| Network | OkHttp 4.12 (`data/Net.kt`) | Small, no reflection, ETag/304 by hand like `RealPositionsStore`. Ktor was the alternative; OkHttp is lighter for plain GETs. |
| JSON | kotlinx.serialization (`JsonElement` read defensively, `core/Js.kt`) | Transitous's answers are read like the iOS code reads them (`as? String`): a missing or odd value is null, never a crash. Our own state (`Profile`, `Settings`, the ride) is `@Serializable`. |
| Protobuf | Hand-written reader (`live/RealPositions.kt`, `ProtoReader`) | A port of iOS `ProtoReader`: no protobuf library, never crashes on a cut-short or odd feed. |
| Map | MapLibre Android 11.8 with OpenFreeMap vector tiles (`https://tiles.openfreemap.org/styles/liberty`) | OpenStreetMap-based, no API key, no Google Play services. Vehicles, stops and you are one GeoJSON source drawn by data-driven circle and label layers. osmdroid was the alternative (raster tiles, against OSM's tile policy for apps). |
| Location | `android.location.LocationManager` (GPS and network providers) | No Google Play services dependency: works on any Android phone, including de-Googled ones. |
| Storage | SharedPreferences with JSON (`profile/Profile.kt`, `ride/RideState.kt`) | A few small documents; DataStore would add a library for no gain at this size. |
| Background | Foreground service (type `location`) for rides and auto-start's look; AlarmManager for the backup alarm and the school alarm (`setAlarmClock`); WorkManager 2.9 for planning the school week; platform proximity alerts for auto-start | See "How each iOS feature maps". |

Packages (`android/app/src/main/java/nl/haltewekker/`):

- `core/` — `Geo` (flat-earth metres, bearings, projections onto a path: a port of `Geo.swift`), `Polyline`, JSON and
  ISO-time helpers. Times are seconds since 1970 as `Double`, like Swift's `TimeInterval`, so the rules port 1:1.
- `data/` — models (`Ride`, `DoorTrip`, `BoardDeparture`, `NearStop`, `PlaceHit`, `VehicleSegment`, `VehicleKind`),
  `TransitParse` (pure parsing of `/v5/plan`, `/v6/stoptimes`, `/v1/geocode`, `/v1/map/stops`, `/v1/map/trips`,
  `/v5/trip`), `Transit` (the requests, with the iOS 45 s plan memo), `Net`.
- `live/` — `RealPositions` (OVapi GTFS-RT vehicle positions, NS through the relay `/ns/vehicles`), `LiveFeeds`
  (fetch on demand, at most every 30 s, ETag, backoff 60…300 s).
- `match/` — `VehicleMatch` (judge, rank, decide; `Joined` with its GPS anchor), `ChooseGPS`, `OnBoardRules`,
  `OnBoardBackoff`: the iOS matcher with its numbers.
- `ride/` — `WakeRules` and `RideGPS` (pure), `RideState`/`RideStore`, `RideService`, `AlarmPlayer`, `AudioRoute`,
  `Notifications`, `AlarmActivity`, `AlarmReceiver`, `OnBoardLook`.
- `profile/` — `Profile`, `Settings`, `Store`, `SchoolCatalog` (search ported from `SchoolCatalog.swift`), `SetupBackup`
  and `SetupLogic` (pure), `TestSetup`.
- `school/` (A2) — `ManualWeek`, `SchoolHints`, `Timetable`, `SchoolSkip`, `SchoolPlan` (pure); `Calendars`
  (CalendarContract), `SchoolAlarm` (the store and the plan), `WakeAlarm`, `WakeReceiver`, `WakeService`, `WakeActivity`.
- `auto/` (A2) — `AutoRules`, `TripResume` (pure); `Regions` (proximity alerts), `RegionReceiver`, `AutoStart`, `ResumeStore`.
- `work/` (A2) — `Works`, `PlanWorker`, `CalendarWorker`, `BootReceiver`.
- `friends/` (A3) — the formats and rules, pure and tested: `FriendJson` (sorted keys, plain numbers, base64url),
  `FriendCrypto` (Bouncy Castle), `FriendKeys` (BIP-39, identity, card, `RelaySign`, `FriendLink`, names), `FriendBox`
  (kinds, payload, seal/open, vault), `FriendBook`, `FriendInbox`, `FriendTravel` (`TravelState`, `TravelAge`,
  `TravelShareRules`, `TravelWords`, `CoachMap`), `FriendChat`, `FriendGroup`, `TripCard` (`TripTake`, words),
  `FriendTimetable`, `FriendCompare`, `FriendRides` (shared rides, meet halfway, `RequestBudget`); the platform side:
  `FriendRelay` (OkHttp), `FriendSecrets` (Keystore), `FriendStore`, `FriendChats`, `FriendTimetables`,
  `FriendTravelShare`, `FriendWork`, `NSTrains` (NS codes, the train drawing).
- `ui/friends/` (A3) — the Friends screens, the scanner (CameraX + ZXing), the ride's friends card, the home button;
  (A4) `FriendExtrasUi` (the extras' cards, the live link card, Settings › Help improve Haltewekker).
- `friends/` (A4) — `FriendExtras` (wait, delay, buddy, campus), `FriendExtrasB` (free together, scores, the board,
  rides together, `DoorScore`), `LiveLink` (state, keys, AES-GCM lock, rules, words), pure and tested; the platform side:
  `FriendExtrasStore`, `FriendTogetherStore` (with `ScoreLog`, your own door-to-door trips), `LiveLinkStore`/`LiveRelay`.
- `logs/` (A4) — `FieldLog` (the ride's `match`/`ride` lines, iOS `FieldFormat` wording), `LogShare` (scrubbing, batches,
  rules, gzip; pure and tested), `LogShareStore`.
- `map/` — `LiveMap` (MapLibre in Compose).
- `ui/` — theme, components, `HomeModel`, `Locator`, `MainActivity` and the screens.

### Theme (iOS `Design.swift`, `DesignShared.swift`)

`ui/theme/Theme.kt` holds the same tokens, light and dark: text `#14171A`/`#ECEEF0`, secondary `#5B636B`/`#A3ABB3`,
surface `#FFFFFF`/`#1C1F23`, surface2 `#F6F7F9`/`#24282D`, surface3 `#F1F3F5`/`#2C3137`, divider, page
`#F1F3F5`/`#111417`, the one accent `#0E7A55` (as text in dark `#4CC792`), warning `#A84219`/`#FF8A5C`. Vehicle
colours (set C1): **bus `#E0632E`, intercity `#3B44B0`, sprinter `#0A93B5`**, tram/metro `#6B3FA0`. Card radius
24 dp, chips 20, fields 16, pills 6; buttons 44 dp (quiet) and 56 dp (big); a hold-to-confirm button for ending a ride
(iOS `DSHoldButton`). The Material 3 colour scheme is built from these tokens. The launcher icon is the iOS one
(rings on the accent green) as an adaptive vector icon with a monochrome layer (themed icons).

## How each iOS feature maps

| iOS | Android |
|---|---|
| CoreLocation with background updates during a ride | `RideService`: a foreground service of type `location`, started from the app when you tap "I'm on it". Location while in use is enough for it; "all the time" is explained and optional (for auto-start, later). GPS every 2 s; far from the stop on a confirmed vehicle every 25 s and 75 m (`RideGPS`, as iOS 0.20.7). |
| Wake-up alarm (`TripManager.ring`, `AlarmSound`) | Distance-based as iOS: rings `busKm` (2 km) or `trainKm` (5 km) before the last stop of each leg; inside it within 20 s of the leg's start it stays awake silently (`RideGuards.wakeAtStart`); awake, at 450 m it chimes "you're there" and goes on to the next leg. Sound: the announcement by text-to-speech, then the alarm ringtone on repeat, vibration. |
| AlarmKit / time-sensitive notification | A notification on a high-importance channel with a **full-screen intent** to `AlarmActivity` (shows over the lock screen, turns the screen on; a volume key stops it). |
| The backup alarm by time | `AlarmManager.setExactAndAllowWhileIdle` (RTC_WAKEUP) at the leg's (live) arrival less the time the wake distance takes (at least 2 min), so it rings when GPS never got you close. `USE_EXACT_ALARM` on Android 13+ (an alarm-clock function), `SCHEDULE_EXACT_ALARM` on 12 (asked in the permissions card), inexact `setAndAllowWhileIdle` as the fallback. |
| "Sound only with headphones" (0.24.3) | `AudioRoute.privateOutput` (wired, USB, Bluetooth A2DP/SCO/LE, hearing aid). Headphones in: plays as media (Android's alarm stream also comes out of the speaker). None and the setting on: vibrates only, out loud on the alarm stream after 60 s. Setting off: out loud. |
| Live Activity / Dynamic Island | The foreground service's **ongoing notification**: line and stop, what's left, the arrival (count-down chronometer), the leg's progress bar, "Stop alarm" and "End trip" actions. (Android 16's promoted "Live Updates" style is a later polish.) |
| Background refresh (BGTask) | WorkManager (A2), only while the school alarm is on: hourly with a network, once more 75 min before the next alarm, and on a calendar change (content-URI trigger). The home's loops still run only while it is in front, the ride's only during a ride. |
| AlarmKit school alarm (`WakeAlarm`) | `AlarmManager.setAlarmClock` per school day (status-bar alarm icon, rings in Doze), `WakeService` (foreground, `systemExempted` on 14+, else `mediaPlayback`) plays the alarm out loud on the alarm stream, `WakeActivity` over the lock screen with Stop / Open. |
| EventKit (`EKEventStore`) | `CalendarContract.Instances` with READ_CALENDAR, only the picked calendars. |
| Region monitoring (`CLCircularRegion`) | `LocationManager.addProximityAlert` (platform, low-power; no Play services), needs location "all the time". |
| Thrift (0.20.7) | Feeds fetched on demand, at most every 30 s, with ETag; the plan memo; rough GPS on long rides; the map's vehicles move on locally between fetches (no network); nothing when idle. |
| On-board matching (`VehicleMatch`, `ChooseGPS`, `OnBoardRules`) | Ported with their numbers and tests (below). The ride looks every 15 s while it doesn't know your vehicle, then the live arrival every 60 s. |
| Fastest trip (`GoNew`) | `PlanScreen`: from where you are (or home) to school, home or a searched place; plans again every 40 s (20 s within 12 minutes of leaving, `GoPace`). |
| Setup (`SetupFlow`) | `SetupScreen`: school from the bundled list, home by location or search, home stops, permissions. |
| `Schools.json` | The same file: the build copies `ios/App/Schools.json` into the APK's assets (one list for both apps). |
| Sideloading (Sideloadly, SideStore) | GitHub releases with `Haltewekker.apk` (Obtainium tracks them). |

## On-board matching: what was ported

Ported as pure Kotlin, with the iOS tests' scenarios:

- `VehicleMatch`: `Fix`, `TimedPiece`, `VehicleTrack.group`, `Evidence`, the hard tests (`judge`: enough fixes, on its
  path, its way, a possible speed, not standing, moving with you, near its times), `judgeAll` with the prefilter,
  `rank` (planned −45 s), `decide` (hysteresis), the joined path with its own GPS anchor, `timesOnly`.
- `ChooseGPS`: `passedByGPS`, `noteGPSFits`, `soften`, `roadsParted`, `gpsBest`, `gpsLook`.
- `OnBoardRules`: `rank` with the train GPS edge, `best` (a timetable never beats a GPS fit; timetable-only only at
  vehicle speed), `movingByTrack`, `lookDue`, `mayAutoStart`; `OnBoardBackoff`.

Not ported in A1: the long `VehicleMatch.choose` state machine (`ChoiceLook`), `byRoad`, `MatchRules` lanes, `HandLock`,
`RideGuards`' change rules and the "same bus?" re-checks. The ride uses a simpler rule on top of the ported ones: the
best by `OnBoardRules.best` (the planned trip ranked 45 s better) or the `ChooseGPS` run's leader, the same one in two
looks in a row. "I'm on it" (by hand) always wins. The alarm never depends on matching: it rings by your distance to
the stop.

## Tests

JUnit, run by CI before every build (`./gradlew testReleaseUnitTest`):

- `GeoTest` — metres, bearings, projections, passes, polyline decoding.
- `TransitParseTest` — a saved Transitous plan (Utrecht → Breda, 2026-11-19), stoptimes, geocode, map stops,
  `keepUseful`, train labels and vehicle kinds.
- `RealPositionsTest` — the iOS protobuf tests (hand-built feeds, unknown fields, every truncation, garbage), a real
  OVapi feed excerpt, keys, service dates and freshness, NS train parsing, backoff.
- `VehicleMatchTest` — the iOS scenarios S1, S1b, S2, S3, S4, S6, zero-length pieces, tolerance, rank and decide.
- `OnBoardRulesTest` — the iOS `OnBoardRulesTests`, the track tests, `lookDue`, the backoff, the GPS run.
- `WakeRulesTest` — the alarm distance rule, arrival, headphones-only, the backup time, texts, `RideGPS`.
- `SchoolCatalogTest` — the shared `Schools.json` and its search.
- (A3) `FriendVectorTest` (every spec test vector), `FriendLogicTest`, `FriendCompareTest`, `FriendLiveInteropTest` (live, opt-in): see "As built A3".
- (A4) `FriendExtrasVectorTest`, `FriendExtrasTest`, `FriendExtrasBTest`, `FriendLiveTest`, `LogShareTest`,
  `LiveLinkInteropTest` (live, opt-in): see "As built A4".
- (A5) `SeatMapTest` (the 0.31 seat vector byte for byte, older coaches, decks, windows, words, map framing, routes,
  Ride along), `TestFriendTest` (the bot's rules), `TestFriendLiveTest` (live, opt-in): see "As built A5".
- (A5.1) `SeatClassTest` (1st class from 11 real NS compositions, the table, the words, the seat box unchanged): see
  "As built A5.1".
- (A6) `WakeRuleTest`, `DeadReckonTest`, `GPSShareTest`, `SettingsIndexTest`, `TrainRulesTest`, `AdvanceTest`,
  `HabitsTest` (with ChangeOdds), `DailyRankTest` (with the board's rule and the 0.35 scores vector), `StudentOVTest`,
  `TravelHelpTest`, `RailWorksTest`, `OVFietsRainTest`, `StopBoardCoreTest` (with IntentActions), `TravelYearTest`,
  `MotionRulesTest`: the iOS tests of 0.32–0.37, vector for vector: see "As built A6".

## CI and releases (`.github/workflows/android.yml`)

On pushes touching `android/**` or the workflow (main and `claude/**`), on ubuntu-latest with JDK 17 and the Gradle
cache: unit tests, then `assembleRelease`, the signature checked with `apksigner`, the APK uploaded as a run artifact.
On main only: a versioned release `android-v<versionName>` (made once per version, kept to fall back to) and the
rolling `latest-android` (a pre-release, replaced each time), both with `Haltewekker.apk`. The iOS releases are
pre-releases, so the newest `android-v…` is the repository's "Latest" release: Obtainium (add the repository URL; it
picks the `.apk` asset) sees each new Android version as an update.

**Signing.** Updates must be signed by the same key every time. The workflow signs with the keystore from the
repository secrets `ANDROID_KEYSTORE_B64` (the keystore file, base64), `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` when they are set. Without them it signs with a debug key (kept between
runs in the Actions cache) and the release says "Test build (unsigned key — reinstall needed later)". The keystore is
never in the repository (`android/.gitignore` ignores `*.jks`, `*.keystore`, `signing.properties`). Locally, a
`android/signing.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`) or the `HW_KEYSTORE_*`
variables do the same.

**Versions.** `versionName` and `versionCode` in `android/app/build.gradle.kts`. Every release that should reach phones
needs a higher `versionCode` (Android refuses a lower or equal one as an update) and a new `versionName` (the versioned
release is made once per name).

## Releases

### A1 — core travel (0.1.0, code 1) — built

- First-run setup: school (bundled list, campus pick), home ("use my location" or a Transitous search), up to three
  home stops (`SetupLogic.stopChoices`), the permissions card. Saved profile.
- Home: the map with you, nearby stops and live vehicles (Transitous's map pieces; OVapi positions for buses and trams
  where fresh; NS's own train positions through the relay, else trains by their times), the next trip to school or home
  (before noon to school, after it home; a pick sticks 3 hours), departures around you (your home stops when at home).
- Fastest trip / plan: to school, home or any searched place; options; details per leg; start the ride.
- Ride: "I'm on it" starts it; the foreground location service; the wake-up alarm per leg (distance-based, the
  distance adjustable per leg); the alarm screen (full-screen intent, sound, vibration, announcement); headphones-only;
  "You're at your stop" with the next leg; the backup alarm by time; the ongoing notification with ETA; on-board
  matching and the live arrival.
- Permissions: location (fine; background explained, optional), notifications (13+), exact alarms (12), full-screen
  intent (14+), battery optimisation (recommended).
- Settings: wake distances, the alarm switches, real positions, rough GPS on long rides, set up again.

### A2 — school alarm, calendar timetable, setup polish (0.2.0, code 2) — built (as planned below; "As built A2" says how)

- The school alarm (iOS `School.swift`, `Morning.swift`): the first class from the calendar (`CalendarContract`, the
  calendars you pick, `SchoolHints`) or a manual week (`ManualWeek`); WorkManager plans the morning's trip the evening
  before and again early; an exact alarm (AlarmManager `setAlarmClock`, shown in the status bar) for when to get up and
  when to leave; the full-screen alarm screen reused.
- Setup polish: the timetable step, a setup backup/restore (`SetupBackup`), corridor detection (`ProfileLogic`),
  editing places in Settings, the home stops board picker.
- Fastest trip's earlier ways and boarding further along (`earlierWays`, `BoardAt`), "Time to go" notification.
- Start a ride by itself on leaving a station (needs background location; `OnBoardRules.mayAutoStart`), resume a trip
  ended at a change (`TripResume`).
- Release build with R8 (minified) once there's a device test pass; Android 16 "Live Updates" notification style.

### A3 — Friends 0.25–0.28 (0.3.0, code 3) — built (as planned below; "As built A3" says how)

From the platform-neutral spec `docs/superpowers/specs/2026-11-18-friends-design.md`, its "As built" sections taken
byte for byte, and its test vectors as JUnit tests before any screen:

- 0.25: seed and BIP-39 backup code, HKDF keys, Ed25519 signing and X25519 agreement, account id, friend card, link and
  QR, signed relay requests, boxes (ChaCha20-Poly1305). Crypto from Bouncy Castle (pure Java), since Android's own
  Ed25519 is API 33+ and X25519 API 31+ while the app starts at 26. Keys in the Android Keystore-wrapped storage,
  excluded from backups.
- 0.26: sharing a trip (`travel` box), relay routes, the friend list, the coach map.
- 0.27: chats (`g` header, kinds, fan-out, fetching without push), "Take this trip".
- 0.28: timetables and areas, the vault, Compare and shared rides, Meet halfway, the request budget.
- An `android/` test module mirrors `FriendVectorTests`, `FriendTravelVectorTests`, `FriendChatVectorTests`,
  `FriendTimetableTests`; a phone with each app must read the other's boxes.

### A4 — Friends extras 0.29–0.30 and log sharing (0.4.0, code 4) — built ("As built A4" says how)

- 0.29: "Wait for me", the delay alarm for shared rides, the wake-up buddy, who's on campus.
- 0.30: free time together, the live link (`/live/<token>#<key>`), the leaderboard with friends, rides together.
- Log sharing (`LogShare`, `docs/logs-export.md`): the field log and a share sheet, for tuning the matcher from Android
  rides.

### A5 — Friends map first, the seat picker, the test friend (0.5.0, code 5) — built ("As built A5" says how)

- iOS 0.30.1's test friend, iOS 0.31's "Map first" Friends, a friend's page on the map, the seat (`coach.seat`) and the
  whole-train / side-view seat picker.

### A5.1 — 1st class in the seat picker (0.5.1, code 6) — built ("As built A5.1" says how)

- iOS 0.31.1's 1st class in the seat picker, from NS's drawings, per coach and per deck.

### A6 — iOS 0.32 to 0.37 (0.6.0, code 7) — built ("As built A6" says how)

- 0.32 sharing GPS points, 0.32.1 Settings in topics with search, 0.33 wake by time and motion, 0.34 same-track trains,
  old bus GPS, tunnels, habits and change reliability, 0.35 the leaderboard's rule, today's best and worst, your year
  in travel, 0.36 check-out, student OV, money back, works, last way home, 0.37 OV-fiets, rain, the widget, shortcuts.

### A7 — the A6 leftovers, iOS 0.37.1, 0.38, 0.39.1 (0.7.0, code 8) — built ("As built A7" says how)

- The ride's full choice between vehicles (`choose`), same-track trains, check-out between train companies, works
  "leave N min earlier", the trip's notes on the ride; 0.37.1 watch-friendly alarm notifications; 0.38 picking the one
  you're on (departure moment, usual line, bus stops, ask sooner); 0.39.1 the wrong bus, a miss at the change, the
  timetable start, another line at your stop.

## As built A7 (0.7.0, version code 8): the A6 leftovers, iOS 0.37.1, 0.38, 0.39.1

From `docs/android-todo.md` and the iOS rules and tests. The iOS app and the relay were not changed.

**Choosing (iOS 0.26.1 – 0.39.1, `match/Choose.kt`, `ride/RideChoice.kt`).** `VehicleMatch.choose` (with `prune`,
`verdict`, `offRoad`, `top`, `sameChoice`, `ChoiceLook`, `ChoiceRun` for iOS's `inout` misses / switch state / GPS run)
and `ChooseGPS.departLook`, `farByGPS`, `gpsRescue`, `nudged`, tested with the iOS `ChooseGPSTests` (the 2026-11-18/19
logs). The ride's look (`OnBoardLook`) now returns the others that fit within a minute of the one it takes; then the
ride chooses between them (at most 3) every 12 s: each candidate's own trip answer as its track (a piece per stop to
stop on its road, `RideChoice.track`), its own GPS (OVapi; NS by train number, with its previous fix when seen), the
train stopping pattern (`TrainRules.outByStops`), the one that left the stop with you, the bus stopping pattern and
your usual line as nudges, today's road check for the one shown. Log lines as iOS (`choose · …`, `depart · …`,
`choose · bus stop pattern · …`, `choose · usual line · …`, `ask · still tied …`, `rivals · …`, `switch · …`). A train
that goes on to a later leg's stop in time takes the trip with it (`TrainRules.stayOn`, a "Stay on to …" note). On a
confirmed train every 2 minutes the rivals look (`TrainRules.rivals`: every train on your track by its NS position;
their numbers from their trip answers). The ask ("305 or 306?", "IC to Breda or IC to Eindhoven?") is a ride-screen
card and a notification with two buttons; the answer is a pick by hand. The ride screen says "Checking: Bus 305 or Bus
306…" meanwhile. Nothing here rings or stops the alarm.

**Picking the one you're on (0.38, `match/PickRules.kt`).** `DepartMatch`, `UsualLine` (in `HabitBook.lines`, the
Settings row "Your usual lines", reset with the others), `BusStops`, `AskSooner`, tested (`PickRulesTest`). Getting
on: 30 s off the one that alone left your stop with you; your usual line within 15 s of the best wins unless the
best is the planned one. Learned: +1 for a ride it found itself and you rode 2 min or more to the leg's end (0.39.1:
only on the planned line), +2 for an answer or "I'm on it", −1 for the other line it had.

**0.39.1 (`ride/WrongBus.kt`, `ride/ChangeGuide.kt`).** `TimetableStart` (a found timetable-only planned one before
2 min ahead of its departure or 20 min after: not taken, `wait · not by its timetable …`), `WrongBus` (runs of fits by
its own GPS, noted on every look; once a ride a card "You’re on the 154 to Schijndel, not your 306" with the planner's
way on and a `wrongbus-<start>` notification; "Pick again" forgets the vehicle and looks again), `OtherAtStop` (the
stop's board once a minute while you wait within 150 m for your bus; `otherbus-<trip>`), and `ChangeGuide` with
`MissRule` ported and tested (shown from A8). `NoticeExpiry` has `ready-`, `wrongbus-`, `otherbus-`, `heads-up-`.

**Alarm notifications (0.37.1 `WristNotice`, 0.42.1 `AlarmStop`, `ride/WristNotice.kt`, `ride/StopReceiver.kt`).**
Short titles with the stop first ("Get off at Breda · 2 min", the backup "Get off at Breda soon", "You’re at Breda"),
the trip's group (`trip-<start>`) and the wake-up's (`wake-<day>`), a public version with the title for a hidden lock
screen, and Stop alarm as a broadcast to `StopReceiver` (not an activity: never asks to unlock, never opens the app;
Wear OS shows the action): it stops the sound at once and hands the rest to the ride (as Stop in the app); with no
ride running it only takes the alarm's notifications away. The repeat `alarm-again` 30 s after it rang while it still
rings. Swiping the ringing alarm away also stops it. Settings › Trips & alarm says it works from a Wear OS watch.

**A6 leftovers.** Check-out between train companies (`Ride.agency` from Transitous's `agencyName`); dead reckoning by
the vehicle's own fresh GPS (≤ 2 min, on its road, moved on at its speed) before your own pace; works "Leave N min
earlier" (Transitous asked again for up to 3 school days with works, arrive by, against the median door-to-door of the
other days; on the home's card and the evening-before notification); the trip's notes (student OV, rain, OV-fiets) for
what's left of the trip on the ride screen.

### Calls made in A7 (the user can correct)

- A found vehicle with others within a minute of it starts a choice (iOS: those that fit about as well).
- "Pick again" on the wrong-bus card looks again (Android has no "I'm actually on…" list yet).
- Another line at your stop only for a planned bus leg (no own routes on Android).
- Still open from A6: the `Risk` ranking, motion (no Play-Services-free activity recognition), the year as a picture,
  Settings' search scrolling, the widget's lock-screen sizes, OV-fiets in a station's sheet, planned trips' stations
  for works, the home map's vehicles at their seen pace (replaced by A8's real GPS first).

## As built A6 (0.6.0, version code 7): iOS 0.32 – 0.37

From `docs/android-todo.md` (the iOS builders' checklist), `docs/logs-export.md` › For Android (parity), the friends
spec's "As built (0.35)" and the iOS code and tests. The iOS app and the relay were not changed. Every pure rule is a
port with its iOS test vectors (the Tests list above); the alarm's safety rules come first.

**Wake by time (0.33, `ride/WakeRule.kt`).** `WakeBy`/`WakeSettings` (in `Settings.wake`; by time, 3 min a train, 2 a
bus, 1–10), `SpeedSmoother` (30 s, known after 20 s, forgotten after 90 s), `RouteLeft`, `WakeRule.decide` (the distance
rule first, as always; by time only 300 m or more from the leg's first stop, within the minutes at 160/100 km/h, by the
stop's live arrival while ≤ 150 s old and possible, else the distance left along the road at your smoothed speed of 4
m/s or more), `says`, `gpsWakeMetres` (the far GPS tier keeps clear of its reach). The ride: the vehicle's own trip
answer (asked every minute for the live arrival, `OnBoardLook.wakeTrip`) gives the road from where you got on to your
stop (`WakeRoad.cut`) and the live arrival; within 20 s of a leg's start either rule wakes silently; the ring line says
which rule (`ring · by time 3 min (live) · …`), the alarm notification "… in about 3 min".

**Tunnels and dead zones (0.34, `ride/DeadReckon.kt`).** With the vehicle known, a step every 5 s; once the newest good
fix (≤ 100 m) is 15 s old (and under 15 min) the place goes on along that road (else the straight line from where you
got on to your stop) at the vehicle's pace (the distance left over the time to its arrival, else your last speed; never
over 160/100 km/h), never back, never past your stop; the ongoing notification says "no GPS here: following its route".
**Only the time rule rings on it** (`DeadReckon.decide` / `mayRing`); a good fix ends it. Log: `reckon · …`,
`ring · reckoned (pace) · by time …`. (The vehicle's own fresh GPS isn't used for it yet: see the todo.)

**GPS points (0.32, `logs/GPSShare.kt`).** `Maker` ("Nana"), `SharedFix`, `GPSShareQueue` (the running trip, then the
trimmed points waiting; `files/gpsshare.json`), `GPSShareRules` (one per 3 s, ≤ 150 m, rounding, the tag, 6000 a trip,
20 000 waiting, 500 m trimmed at both ends and around Home, School and your home stops, 600 KB an upload and 4 MB a day
on their own budget), `ShareAsk` (the texts, "this phone"). `LogShareStore` gains the second switch (`gpsShare.on`),
the queue from the ride's own fixes (`heard`, no GPS of its own), trimming when the trip ends, `fixes` and `tz` on the
put only with points, dropping sent points after a 200 only, clearing the queue when switched off, and the question
(`share.asked.v1`): a setup step "Help improve Haltewekker" before All set (both off; summary row "Nothing shared" …)
and a one-time card on the home and at the top of Settings ("Not now", "Choose…"), never in a test setup.

**Settings (0.32.1, `profile/SettingsIndex.kt`, `ui/screens/SettingsScreen.kt`, `ui/SettingsIcons.kt`).** The nine
topics in two lists with thin grey outline icons (Material Symbols Outlined, weight 200, the paths inlined: no icon
library), a "you" card (school, home, friends) and a search over every setting (the iOS search, ranks and folding; the
entries are this app's own settings). A result opens its topic's page.

**Same-track trains (0.34, `match/TrainRules.kt`).** `rivals`, the stopping pattern (`seen`, `outByStops`), `ask`,
`askTitle`, `stayOn`, ported and tested (with the 2026-11-19 cause reproduced on the app's own matcher). Not wired into
the ride yet: Android's ride uses the simpler matcher of A1 (no `choose` state machine, no candidates to rule out or to
ask between): see the todo.

**Old bus GPS (0.34, `live/Advance.kt`, `match/VehicleMatch.kt`).** `Advance` (iOS `RealPositions` Leg / snap /
observedSpeed / lateness / advance / place / ageSlack), tested; the matcher's GPS anchor now moves on at the speed it was
seen going for up to 2 minutes, and an older fix gets more room (`ageSlack`). The home map's vehicles still move on as
before (A1's own interpolation).

**Habits and change reliability (0.34, `travel/Habits.kt`, `HabitStore`).** `HabitBook`, `Habits`, `ChangeBook`,
`ChangeOdds`, tested. The ride notes your walks (to the first stop, across a change), your change time (getting off to
within 50 m of the next ride's stop), the stops you get on at and the stop each trip was planned from, and per change
whether you made it (`ChangeOdds.made`, the boarded train's departure from its trip answer; `change · made it · …`).
The planner gets your walking speed as `pedestrianSpeed`; Fastest trip and the home's card say "this change worked on 9
of 10 days". Settings › Trips & alarm › Learned from your rides shows the three values and "Reset what it learned".
Android has no `Risk` ranking, so the change time and the preferred-stop bonus aren't used in a ranking yet.

**The leaderboard (0.35, `friends/DailyRank.kt`).** `ScoreRules.board` (a planned trip from near Home to near School or
back, from its first leg; where you were if that fix was ≤ 10 min old, else its first stop), `ScoreRules.decode` (entry
by entry), `worse`; going on with a trip ended by hand keeps its start (`ResumeOffer` carries it). `ScoreTrip` gains
`plan`, `lateLine`, `late` (the ride latest at your stop). `DayTrip`, `DailyRank` (rows, words, usual), the `scores`
box's `today` (the 0.35 vector byte for byte; sent within 5 minutes of a new trip today, `ScoresRules.due(soon)`), the
test friend's trip today; "Today" on top of the Leaderboard with friends and a small "Today's trips" card on Friends.

**Your year in travel (0.35, `travel/TravelYear.kt`).** `RideRecord` (each leg kept in `no_backup/travel.json`, never
sent), `TravelLog`, `TravelYear` (stats, CO₂, cards, seasonal), tested; Settings › Advanced › Your year in travel and the
home's card in December or in the two weeks after a year of rides ("Not now" puts it away for that year). Shared as
text without places (`shareSub`), not as a picture.

**0.36 (`travel/StudentOV.kt`, `TravelHelp.kt`, `RailWorks.kt`, `TravelStores.kt`).** All ported with their tests.
Student OV: Settings › Trips & alarm (none / weekday free / weekend free); the line under a trip on Fastest trip and the
home's card, with the relay's `/ns/price` (once a day per station pair). Check-out: a minute after you get off where it's
due ("Did you check out?"), taken back when two fixes in that minute are at 7 m/s or the next leg found the vehicle you
got off; trains' companies aren't known on Android (Transitous's `agencyName` isn't parsed), so two trains are one.
Money back: once, after a trip whose trains got you there ≥ 30 min late, the notification opens NS's claim page. Works:
the relay's `/ns/disruptions?stations=…` at most every 4 hours while the home is on screen, for your home ⇄ school
stations (the NS stations nearest Home and School), today and the next 7 days; the home's card for today or tomorrow and
a notification at 19:30 the evening before (an inexact AlarmManager broadcast, `TravelNotesReceiver`), without the
"leave N min earlier" (no replan). Last way home: after 20:00 and > 3 km from Home, asked "arrive by" 04:00 … midnight
(at most hourly or after 1 km), the home's card and a notification 30 min before it leaves.

**0.37 (`travel/OVFietsRain.kt`, `widget/`).** OV-fiets (the relay's `/ns/ovfiets`, 5 min) on the trip's notes for the
station where its last train gets in (when a bus or a walk of ≥ 5 min follows). Rain advice (Open-Meteo hourly
`precipitation`, 30 min) from 3 h before a trip to 5 min after: "Rain at 08:00 — take bus 305 at 07:41 …" from the
other ways on the list, else "bring an umbrella". The widget (`StopWidget`, RemoteViews, no Glance, no Play services):
"Next departures" from a stop picked when it's added (`StopWidgetConfig`: your home stops or a search), Transitous
`/v6/stoptimes` asked by the widget, `StopBoardCore.timeline` (the list moves up just after each departure leaves, by an
inexact alarm to itself; asked again every 12 min, sooner when it runs short, ≥ 5 min apart, 30 min with nothing
leaving), "07:41 (+2)", "07:41 cancelled", tap: the app with that stop's departures (`haltewekker://stop?…`). App
shortcuts (dynamic, long-press the icon): When's my bus? (the home stop within 600 m of home or with no fix, else the
nearest; shown and said with text-to-speech), Plan to school, Plan home, Wake me at a stop (Fastest trip to a searched
place: Android has no single-stop alarm), Start my trip (I'm on it when the next trip leaves within 3 min or left in
the last 15, else Fastest trip). Nothing over a running trip (`IntentActions`).

**Motion (0.33, `motion/MotionRules.kt`, `StepMotion.kt`).** `MotionRules` ported with its tests. Android has no
Activity Recognition without Google Play services, so "Use motion to notice rides faster" (off by default; Settings ›
Trips & alarm; the Physical activity permission on Android 10+) listens to the hardware step detector only while a trip
runs (batched, on the sensor hub) and says "walking" (6 steps in 12 s, no gap over 4 s): walking under 43 km/h isn't a
vehicle (`movingLikeVehicle`). No "automotive" and no "stationary": the sooner looks, the rough GPS while waiting and
the far tier's earlier start stay as before. The alarm never depends on it.

### Calls made in A6 (the user can correct)

- The wake by time is on by default (as iOS); the distance rule and the backup alarm are unchanged and still ring.
- A test setup asks the sharing question too but never changes what your own phone shares.
- Settings' search opens the topic's page (no scroll to the row).
- The widget is RemoteViews with its own alarms rather than Glance (no extra library); one size that stretches.
- Shortcuts are dynamic (`ShortcutManagerCompat`), not a static `shortcuts.xml`, so the debug build's own app id works.
- Your year in travel is shared as text, not a picture.
- Works use the NS stations nearest Home and School (no planned trips' stations yet).

## As built A5.1 (0.5.1, version code 6): 1st class in the seat picker

The spec's "As built (0.31.1)" (the per-drawing, per-coach, per-deck table, the rules, the words and the test
vectors), from the iOS reference (`SeatClass.swift`, `SeatMap.swift`, `SeatPicker.swift`, `SeatClassTests.swift`). No new
box kind, no relay change, nothing new in the seat: whether a coach or a window is 1st class is worked out on the phone
from the train, never sent. The iOS app and the relay were not changed.

**Where it comes from (`friends/SeatClass.kt`).** `NSTrains.parse` now also keeps each unit's drawing's name (the file
name of `afbeelding`, lower case, without ".png": `icng_B_8.png` → `icng_b_8`) and its 1st-class seats
(`zitplaatsen.zitplaatsEersteKlas`; null when not said) in `TrainDrawing.drawings` / `firstSeats`. The table (19
drawings: VIRM, VIRMm1/2, DDZ, ICM, ICNG, ICNG-B, SLT, SNG, NS Flirt; each its coach edges and per coach its 1st-class
parts `[a, b]` on the upper, lower or every deck) is the spec's, value for value. A drawing not in the table is found
from the unit's type (Roman numerals to digits, joined with "_", else with "nsr_" in front: "VIRMm1 VI" → `virmm1_6`,
"Flirt 3" → `nsr_flirt_3`). A unit with 0 1st-class seats has none (Keolis); a drawing not in the table (ICE, GTW,
Arriva…) or a unit whose coaches NS counts differently from its drawing: not known. The guess (no NS) knows none.

**The rules (`SeatMap.train`, `SeatMap.isFirst`).** Each picker coach (`CoachMap.spots`) gets the unit its middle falls
in, its place in that unit from the left and the table's parts for it (`SeatMap.Coach.first`: empty none, null not
known; `kind` SECOND / PART / FIRST). All 1st class: a part on every deck from ≤ .02 to ≥ .98; part: any part. A window
(11 a row, `(i + 0.5) / 11`) is 1st class when its middle is inside a part on its row's deck (a single-deck coach's row
takes every part), or the coach is all 1st class. Your pick (or a friend's) is 1st class when its coach is all 1st
class or its window (scaled to 11) is; a coach without a window in a part-1st coach is not. `TrainDrawing.seatTrain`
builds the picker's train the same way everywhere (the picker, a friend's coach note, the tests).

**The picker (`ui/friends/SeatPicker.kt`).** Side view: 1st-class windows darker gold glass in a 2 dp gold frame, a gold
"1" badge on the first (left) window of each run, per deck (not where someone sits); a coach that's all 1st class has a
cream body and a gold "1st class" tag at its bottom left. Train strip: an all-1st coach is gold (deeper when open) with
a "1" badge by its number; a part-1st coach has a gold bar along its bottom where any deck has 1st class
(`SeatClass.span`). Under it the legend "[1] = 1st class (about here)" ("= 1st class (about here) · gold coach: all 1st
class" when there's one; "= 1st class · gold coach: all 1st class" with only those), read by TalkBack as "1st class is
marked with a 1, about where it is; gold coaches are all 1st class". A train from NS where no coach is known to have 1st
class and some aren't known: "Where 1st class is in this train isn’t known." Colours as iOS `FirstClassLook` (NS's
yellow, light and dark). TalkBack: "Coach 3 of 8, 1st class", "Coach 2 of 10, from the front, two decks, part 1st
class", a window "…, window 5 from the back, 1st class".

**Words.** Your seat (ride screen): "Coach 2 of 10 · upper deck · 5th window from the back · 1st class" when your pick
is (the picker tells the card through `onMineFirst`). A friend's page: "Sam is in coach 3 of 8 · 1st class", from NS's
drawing of their train at the station their coach is counted at (`coach.at`).

**Checks.** `SeatClassTest`, the iOS `SeatClassTests` with the same 11 real compositions as fixtures (read through the
app's own `NSTrains.parse`): IC 3078 `2p2pp22pp2`, IC 2280 `2pp22p2pp2`, SPR 4982 `p22pp2222p`, IC 678 `2p2`, IC 2685
`22122212`, IC 1783 `p2p2`, SPR 5683 `p22`, IC 1184 `22pp2`, IC 9583 `22pppp22`, ICE 120 `????????`, Keolis 8581 `222`;
the windows per deck (VIRMm1 IV upper 6–7 / lower 5–7, ICM 3 5–9, DDZ 4 upper 2–5 / lower 2–3, VIRM IV lower only
5–7); your seat and its words; the seat box byte for byte unchanged
(`{"at":"UT","front":true,"n":2,"of":10,"seat":{"deck":"upper","of":11,"w":5}}`); TalkBack words and the legend; the
drawing names; the table well formed; the unit zones (SNG 3 at one end only); the strip's bar.

### Calls made in A5.1 (the user can correct)

- Android has no "1st class near A, D" platform line (A3's coach map has no 1st-class zones), so the spec's unit
  zones (`SeatClass.unitZones`) are ported and tested but not shown anywhere yet.
- "Rides with you" on the ride card ("Sam is on this train · coach 3 of 6 …") stays without "· 1st class", as iOS.

## As built A5 (0.5.0, version code 5): Friends map first, the seat picker, the test friend

The spec's "As built (0.30.1)" (the test friend, with its note for Android) and "As built (0.31)" (the seat, the
picker, the map's framing, Ride along, map first), from the iOS reference (`FriendsMapViews.swift`, `FriendPage.swift`,
`SeatPicker.swift`, `SeatMap.swift`, `MapFrame.swift`, `TestFriendBrain.swift`, `TestFriendBot.swift`,
`TestFriendViews.swift`) and the approved mockups (FriendsF2, WagonW6). No new box kind, no relay change,
`KINDS_VERSION` stays 6. The iOS app and the relay were not changed.

**The seat (`TravelState.Seat`, `friends/SeatMap.kt`).** `coach` gains an optional `seat` `{"deck","w","of"}` (all three
required when it's there; `deck` "upper" | "lower" | "none", anything else reads as "none"; `w` 1-based from the back of
the coach when the coach counts from the front, else from the left of NS's drawing; `of` 11). An older app (A3/A4, iOS
0.26–0.30) skips it; without a seat the coach encodes exactly as 0.26. A seat with `of` outside 1–40 or `w` outside
1–`of` is dropped (the coach stays); another `of` is scaled (rounded up). Words: "Coach 3 of 6 · upper deck · 8th window
from the back"; TalkBack per window: "Coach 3, upper deck, window 8 from the back". It goes out with the next `travel`
state, at once when it changes (the share key now includes the seat).

**The train (`SeatMap.train`).** From the relay's `/ns/train` (as A3's coach map): `NSTrains.parse` now also keeps each
unit's type (`materieeldelen[].type`, else `materieelType`, else the drawing's file name). Two decks: VIRM/VIRMm, DDZ/NID
(DD-IRM), DD-AR/mDDM; one deck: SNG, SLT, FLIRT, SGM, GTW, ICM, ICNG, ICR, ICE and the international trains; unknown: by
the line. Without NS: its length (`lengte`), else the friend's `of`, else 6 coaches, front on the right, an IC/ICD
double-deck, anything else single; "this is a guess". At most 16 coaches.

**The seat picker (`ui/friends/SeatPicker.kt`).** Compose `Canvas`: the whole train in a row (first and last coach shaped
like noses, numbers from the front, a dot where you or a friend sit, "Double-deck IC · from the platform",
"Driving to Breda →"); tap a coach and its side view opens below (doors at both ends, 11 windows a row, two rows on a
double-deck coach, the line's colour stripe, wheels); a friend's face sits in their window. Every coach and window is a
Compose node with a TalkBack label, role and selected state ("Coach 3 of 6, from the front, two decks"; "…, your
seat"). Yours to set on the ride screen ("Your seat", replacing A3's coach strip, while riding a train) and on a friend's
page when a leg of yours takes that train (`FriendTravelShare.boarding`); else theirs to look at. Tapping your window again
takes the window away (the coach stays); "Take it away" takes both.

**The map (`map/FriendsMap.kt`, `friends/MapFrame.kt`, `friends/FriendRoutes.kt`).** One MapLibre view (OpenFreeMap
liberty) with three GeoJSON sources: routes (a line layer, the vehicle's colour, faded when stale), stops (where a friend
got on, grey; where they get off, the accent; named) and faces (a symbol layer; each face a bitmap made on the phone:
the picture or the initials in a circle ringed in the vehicle's colour, IC indigo, Sprinter cyan, bus orange; campus
friends at your school ringed in the accent, side by side). Tapping a face opens that friend's page. The camera is
always `MapFrame.fit` (the friend's position, from and to; ×1.35, at least 1.6 km, widened to the map's shape, moved up
out of the sheet), set when the map lays out, when its size changes and whenever a point or the sheet's share changes;
nobody on the map: your Home and School; nothing at all: the Netherlands. A friend's route is the bit of their vehicle's
live trip shape (Transitous `/v5/trip`, asked once per trip id) between where they got on and get off, else a straight
line through where they are. The map's credits sit top right, under Done (the sheet covers the bottom).

**Friends (with an account).** The map full screen, "…" (Name and picture, Backup code, Delete my friends account) and
Done floating over it, and a custom sheet (`MapSheet`: a handle to drag or tap, "Show more" / "Show less" for TalkBack;
360 dp down, 92 % up): "Friends" and "+ Add" (Show my code, Scan, Send my link, paste a link, the test friend), the two
one-time questions (trips, timetable) as cards, requests, a card per friend in a row (travelling first, then on campus,
then the rest: face, name, "IC 3512 to Breda", "arrives 08:43"), Chats · N (every chat, every group, every friend, New
group), Groups, Compare (a group or a friend, then A3's Compare and Meet halfway), what's going on now (A4's waits for
you, your wait, on campus, delays, free together, the live link while a trip runs), More (you; Your trips; Your
timetable; Extras = A4's At school card; Requests you sent), the leaderboard, the live link's idle line and when it last
checked. Without an account: A3's page, unchanged.

**A friend's page.** Travelling with a place to frame: the map on their trip, "‹ Friends", and a sheet (400 dp): face
ringed in the vehicle's colour, name (and "TEST"), the line pill and "3512 to Breda · 08:43", a green chat button with
the count of new lines; the age when stale; "From … · leg 1 of 2", where the trip ends; the seat picker (a train, not
changing; the drawing at the coach's `at`, else your boarding station, else the NS station within 600 m of where they got
on); "Sam is in coach 3 of 6 · upper deck · 8th window from the back" and, on the same train as you, "Taking this train
too? Wait near B, at the front end of the platform." (else "Coach 3 from the front"); tiles Compare · Ride along (their
vehicle as a card: `TripTake.rideAlong`, taken as A3's "Take this trip") · Wait for me (while they wait or change); then
the test friend's controls, A4's on campus / wake-up buddy / rides together, what they see, Remove. Not travelling: the
same as a plain page with "Friends since …".

**The test friend (`TestFriendBrain.kt` pure, `TestFriendEngine.kt` plain JVM, `TestFriendBot.kt`).** A real second
Friends account made on this phone: its own random seed and device id, its own `/f/v1/register`, kept in its own file
`files/friends/testfriend.json` (not backed up, apart from the Keystore entries of yours), talking only through the live
relay with the very boxes a friend's phone sends, read with `FriendInbox.process` on its own book and groups; its relay
calls carry no log label (Android's relay calls never go in the field log). Its brain runs only inside `FriendStore`'s
own checks: right after your waiting boxes went (`TestFriendBot.check()` in `syncNow`), it sends what it has waiting,
reads one page of its mailbox, accepts you, says hello and shares its timetable (`TestFriendBrain.timetable`) and area
(again after 20 h), answers every line from you (one-to-one, or yours in a group), trip cards ("I’m in" + "See you on
the …"), your waits ("I’ll wait"), marks your lines read, says hello in groups once, acks, moves its pretend trip
(`travel` through the state routes, ttl 360, every ≥ 20 s, a coach 3 of 6 with a window: an IC's upper deck 8th, a
Sprinter's 6th; taken back at the end with "Made it to …!") and its wait on, and sends again, so its answers arrive in
that same check. Its controls (its page: travel, wait, campus, scores, rode together, buddy) each change what it keeps
and run a check at once; all of it on the Friends lane, one thing at a time. Adding: Settings › Friends or the empty
friend list's card or "+ Add"; it registers and sends a `request` (note "A test friend made on your phone…") with its
picture (a 256 px JPEG drawn on the phone: two test tubes on violet to teal, "TEST"). Removing (its page or Settings):
your side removes it, its chat goes, it sends `gleave` to each group, takes back its state and leaves the relay (tried
again at the next check without a network), then its file goes; also when you remove it as a friend or your own account
is deleted or moved. Never in your backup: the vault goes through `TestFriendBrain.scrub`. Its "TEST" tag shows on its
card, its page, the requests and the chat and compare lists.

**Checks.** `SeatMapTest`: the 0.31 vector (`n` = `vector-31`) byte for byte, parsed back and rebuilt byte for byte,
its words; read as 0.26's coach (the seat skipped); a coach without a seat encodes as 0.26
(`{"at":"EHV","front":true,"n":3,"of":6}`); an old coach reads with no seat; odd decks, windows out of range; the decks
from NS's types and a parsed `/ns/train` answer; the trains with and without NS; the windows both ways (the left window
is `w` 1 with the front on the right, the right window with the front on the left; 16 of 22 is the 8th of 11); the card
words, Ride along, the map's framing (Best to 's-Hertogenbosch never framed on Limburg), missing places, the route.
A4's 0.26 travel vector (`vector-2`, a coach without a seat) still passes byte for byte. `TestFriendTest`: the iOS
TestFriendTests (replies, trip card, timetable near yours, scores, buddy, the pretend trip by time and by distance, the
fallback Sprinter, the wait, the scrubbed vault). `TestFriendLiveTest` (`HW_LIVE_RELAY=1`): the app's own
`TestFriendEngine` registers on the live relay, sends a throwaway account its request, is accepted, says hello and
shares a timetable, answers "Hello" and marks it read, puts a pretend train's state with its seat through the state
routes, and leaves; passed from the build container on 2026-11-19.

### Calls made in A5 (the user can correct)

- The sheet is a custom draggable Compose sheet (not Material 3's `BottomSheetScaffold`): it peeks at a fixed 360 dp
  (400 on a friend's page) so `MapFrame.fit` knows exactly what it covers; no pull-to-refresh (Friends checks every
  30 s while open and at once on opening).
- Faces are bitmaps in a MapLibre symbol layer (made on the phone, re-made when a picture changes), not Compose views
  over the map: they stay glued to the map while it pans. TalkBack reads the map as "Map of friends: …"; every friend is
  also a card in the sheet.
- Material icons are the core set only (no extended icons library): Chats an envelope, Groups a face, Compare a
  calendar, Ride along an arrow, Wait for me a place pin.
- A friend's page uses its seat picker only for a train that isn't changing; the ride screen's "Your seat" shows while
  riding a train (A3 showed the coach strip on every train leg).
- The coach you set now carries `at` (your boarding station) even when it counts from the front, as iOS 0.31 does.
- "Extras" in More is A4's At school card (the wake-up buddy switch stays on each friend's page).
- The test friend's "Pretend I'm travelling" asks Transitous for a real departure as iOS does (`/v1/map/stops`,
  `/v6/stoptimes`, `/v5/trip`); without an answer, the Sprinter to the next station.
- A box from someone the bot doesn't know yet (a group line before its list) is let go, not kept for a week as yours
  are: it's a test bot.

## As built A4 (0.4.0, version code 4): Friends extras and shared ride logs

Everything in the spec's "As built (0.29)" and "(0.30)" byte for byte, so the extras work between an Android phone and
an iPhone through the same live relay, and the relay's live-link page decrypts links made on Android; plus iOS 0.28.1's
opt-in "Share ride logs" (`docs/logs-export.md`, `ios/App/LogShare*.swift`) with the same scrubbing. The iOS app and the
relay were not changed.

**Formats.** The five box kinds `wait`, `delay`, `buddy`, `campus` (0.29) and `scores` (0.30) are read and written
(`KINDS_VERSION` 6, as iOS 0.30, so the mailbox is read once more from the start and the boxes A3 left on the relay are
read now). Slots and ttls as the spec: `wait` 900 s, `delay` 3 h, `buddy` 36 h, `campus` until − now (60 s – 10 h; off
3600), `scores` 14 days. A `wait` comes one-to-one or in a group (`g`); the answers `"wait"` / `"next"` are kept with
their `re` (an A3 phone showed them as text). Every box goes through `FriendStore.queueBox` (one payload, `n` and `t`,
locked per person, replacing what's waiting in that slot). The vault's `extras` is now typed (`{"campus","buddy","free",
"scores"}`, the switches only); an iOS vault A3 kept as it came is handed to the extras once.

**Checks (no new loops).** All of it runs inside `FriendStore`'s existing checks (app to the front ≤ every 20 s, 30 s
while Friends is open, 8 s in a chat, the ride's once-a-minute tick, the WorkManager `friends-refresh` about hourly):
`FriendExtrasStore.take`/`FriendTogetherStore.take` with each batch, then `due` (a wait on its way, at school, your
buddy plan, the buddy watch, the delay look at most every 2 minutes, scores at most once a minute, free time). The live
link and the ride history ride on `RideService`'s network tick (through `FriendTravelShare.tick`) and on a leg, stage or
vehicle change (2 s debounce). Region events (`AutoStart.onRegion`) tell the extras first: School's region (with
"at school" on, `AutoRules.withCampus` makes it tell on leaving too; `exitStartsTrip` keeps that exit from starting a
trip) and leaving home (the buddy's "left").

**Wait for me.** From a trip card you're in whose shared ride leaves within the hour (its first stop and shared ride), a
friend's page while they wait or change (their stop, no ride), or the ride screen while not on board ("Running late?" →
pick a friend or a group; the leg's stop and planned ride). Position: the ride's last fix (≤ 90 s, < 300 m), else the
phone's last known fix (no location is asked for just for this). Friends' waits: "Waiting for you to wait" on Friends
and on top of the chat, "I’ll wait" / "Take the next one with you" (one planner question, `WaitNext`, a trip card with the
answer), a banner or a notification for the first box of a wait.

**Delay alarm.** Shared rides by `DelayAlarm.shared` (your trip's rides with friends' `travel` states on that vehicle,
and trip cards from the last 24 h you're in); lateness from Transitous `/v5/trip` (the parse now reads each stop's
`scheduledDeparture` and `cancelled`, and a leg's `cancelled`/`tripCancelled`); told once per vehicle (and again at 2+
minutes more), the next ride all of you can take (≤ 4 planner questions), a `delay` box to the others. Shown as "Rides
with friends" on Friends and "Delays on your rides" on the ride screen.

**Wake-up buddy.** "Tell Sam if I haven’t left yet" on a friend's page (off by default). Your plan: the school alarm's
next planned day (leave, its first ride) within 24 h, else your shared timetable and area's way to the next first class
(Compare's cached question, asked at most once a day); `left` on a trip start, on leaving a home region, or at a check
> 400 m from Home from an hour before leaving. Watching: `BuddyRules`, once per friend per day, a notification that
opens their chat.

**On campus.** "Show friends when I'm at school" (Friends › At school, off by default): inside by School's region or the
last fix (≤ 10 min, 350 m in, 500 m out), posted once per stay to all friends, taken back on leaving, off, or after 10 h.
"On campus now" on Friends; "At BUas since 09:05" on the friend's page (the school's short name from `Schools.json`).

**Free together today.** `FreeToday` from your timetable (as read for sharing, or read without sending at most every
30 min) and friends' shared ones; on Friends; the morning note (off by default) once a day 06:00–11:00 as a notification
(a banner in front).

**Leaderboard with friends.** The Android app has no leaderboard of its own, so `ScoreLog` keeps your door-to-door
trips (iOS `DoorScore`: started within 2.5 km of Home and ended within 1.5 km of School, or back; ridden from the first
leg; minutes from starting the ride to the last stop, one decimal, ≥ 5; at most 300). "Share my scores" (off by
default) sends `ScoresRules.build` by the spec's rules. The board on Friends: This month / All time per route, your own
row always, "Most rides together this month".

**Rides together.** On the ride's tick, on board (a vehicle known, not waiting or changing) with friends whose `travel`
state rides that trip, or who are in on a card for it: one record per vehicle per day (Friends/together.json, 400 days,
1000 at most, friends only). A friend's page: "You rode together 14 times this month" and the last 10.

**Live link.** `LiveKeys` (32 random bytes each, `SecureRandom`), token = b64u(SHA-256("hw-live-token-v1" ‖ secret)[0..16)),
link `…/live/<token>#k=<b64u(key)>` (relay 0.30.1's form, which the page reads besides 0.30's `#<key>`; Android
parses both), AES-256-GCM from `javax.crypto` (every Android version the app runs on), AAD
`hw-live-v1\n<token>`, the state's JSON sorted with plain numbers. `LiveLinkStore`: made from the ride screen (also
without a friends account; the name is your friends name or the one typed last), sent with the share sheet or copied
("Copy link", which the page names when an app cut a link short); puts by
`LiveRules` (55 s, or ≥ 6 s after a change; `until` now + 30 min, never past 4 h), "Arrived" at the last stop (15 min,
tried again once after 6 s), ended when the ride ends otherwise, on "Stop sharing" or after 4 h (again at the next tick
or start when the network was away). Lateness: the live arrival against the planned one while riding, the departure's
delay while waiting or changing. Kept in `files/friends/live.json`.

**Share ride logs** (Settings › Help improve Haltewekker, off by default). Android had no field log: `FieldLog` now keeps
the ride's lines worded as iOS's `FieldFormat` (`start · hand · bus 305·7821 · its stop 180 m from you · leg 1/3`,
`detect …`, `wake`, `ring`, `arrive`, `hand pick`, `end`; 200 match / 100 ride lines, `files/fieldlog.json`, written at
most every 30 s), never coordinates or place names. `LogScrub` (the same patterns and name rules: Home and School by
their names and the home stops, people and account ids from Friends) on every line; `LogShareRules` (200 KB a time, 2 MB
a day, an hour apart, a minute after a trip; never during a trip); gzipped (`Deflater` raw + the same gzip member) to
`/logs/v1/put` with the app field `0.4.0 (4) Android`; a random install id and secret (not the Friends account);
"What’s sent" shows your newest line as it would go; "Delete what I sent" (`/logs/v1/delete`, then a new id). Uploads
after a ride ends (3 s later) and when the app comes to the front (at most hourly); not with Data Saver on a metered
network, not in battery saver.

**Tests** (JUnit; 176 in all, two skipped in CI: the live checks):
- `FriendVectorTest` now rebuilds all 17 vector payloads byte for byte (the 0.29/0.30 kinds included) and reads the
  wait's answer as a wait answer.
- `FriendExtrasVectorTest` — **every 0.29/0.30 vector passes**: the wait, campus, buddy, delay and scores payloads made
  here from values (not from the parsed bytes) equal the spec's, the signatures equal Node's (deterministic Ed25519), the
  wait, campus and scores boxes lock byte for byte (ephPub, box) and open to the same values; the wait's answer payload.
- `FriendExtrasTest` (iOS `FriendExtrasTests`: wait ids, validity, phase, eta, due, words, age, next; the delay's tell,
  watch, read, next together, shared rides, card riders, words; the buddy's plan, alert, moving, due, words; campus
  inside, decide, seen, words; the campus region; the inbox reading all four and the answer), `FriendExtrasBTest` (iOS
  `FriendExtrasBTests`: free together and the note, scores build/valid/due, the board, the scores box from a friend only,
  riders and the ride history).
- `FriendLiveTest` — the live-link vector: token `2x1Ot-EFfLIivv_lmStBuw`, the link, the state's exact JSON, the
  AES-GCM data byte for byte, opening, another token or key refused; the link made as `#k=<key>` and both forms parsed;
  the page's words and the posting rules.
- `LogShareTest` (iOS `LogShareTests`: real lines kept, public stops kept, places/people/ids/coordinates/links/addresses
  out, one line ≤ 2000, the batch, the line format, the budget, when, the install id, the put's four fields, CRC-32,
  gzip).
- `LiveLinkInteropTest` — `HW_LIVE_RELAY=1 ./gradlew testReleaseUnitTest --tests nl.haltewekker.LiveLinkInteropTest`: a
  throwaway link made by the Android code path (`LiveKeys`, `LiveRules.state`, `LiveCrypto.lock`, `LiveRelay.put`),
  fetched with `/live/v1/get?t=<token>` as the page does, opened with only the link's token and fragment key, then
  `/live/v1/end` (the relay then answers 410). Passed from the build container on 2026-11-19, with both the `#<key>`
  and the `#k=<key>` links.

### Calls made in A4 (the user can correct)

- Defaults as iOS: buddy (nobody), at school, share my scores, the morning note and Share ride logs all off.
- The delay alarm reads lateness from Transitous `/v5/trip` only (Android has no NS departure board client yet; iOS
  asks NS first for a numbered train at an NS station).
- Positions for the extras are the ride's last fix or the phone's last known fix; the app doesn't switch GPS on just for
  a wait or "at school" (iOS asks for one fix while in front).
- The leaderboard with friends feeds on a new `ScoreLog` of door-to-door Home↔School trips (Android has no own
  leaderboard and no corridor routes); its board lives on Friends, not in Settings.
- Ride logs: Android's own `FieldLog`, with the ride's lines worded as iOS's; its matcher is the simpler A1 rule, so the
  `detect` lines are fewer and simpler than iOS's. "Low Data Mode" is Android's Data Saver on a metered network; "Low
  Power Mode" is battery saver. The app field says `… Android` so exports tell the two apps apart.
- Notifications for the extras go on the existing "Friends" channel (a banner while the app is in front), with
  `friends-wait-…`, `friends-delay-…`, `friends-buddy-…`, `friends-free` tags.
- A live link ended at a 4xx other than 410 isn't retried (only a network failure is), so a broken request can't loop.

## As built A3 (0.3.0, version code 3): Friends

Everything in the spec's "As built (0.25)" to "(0.28)" byte for byte, so an Android phone and an iPhone are friends,
chat, share trips and compare timetables through the same live relay. The iOS app and the relay were not changed.

**Formats and crypto** (`friends/`). Bouncy Castle 1.78.1's lightweight API (`bcprov-jdk18on`, pure Java) for Ed25519,
X25519, HKDF-SHA256 and ChaCha20-Poly1305; SHA-256 from the platform. The seed → `sign`/`agree`/`vault` keys, the account
id, the card and its packed `k`, BIP-39 (any case, any separators, the first four letters), signed requests (`HW1`
canonical string), boxes (`0x01 ‖ ephPub ‖ nonce ‖ ChaCha20-Poly1305(sig ‖ payload)`, AAD the recipient's account,
HKDF salt `haltewekker-box-v1`, info ephPub ‖ recipient agreeKey) and the vault (`hw-vault-v1\n` + account). JSON is
written as iOS writes it: keys sorted, numbers plain (`1800000000`, `51.44306`, never `1.8E9`), nulls left out, UTF-8;
read in any order with unknown keys ignored. Signatures are always checked over the bytes received. Kinds read:
`request`, `accept`, `unfriend`, `profile`, `picture`, `travel`, `message`, `trip`, `seen`, `group`, `gpicture`,
`gleave`, `timetable`, `area` (`KINDS_VERSION` 4, as iOS 0.28). iOS 0.29/0.30's kinds (`wait`, `delay`, `buddy`,
`campus`, `scores`) open fine but are left on the relay unacknowledged, as the spec says for a kind not known (A4 reads
them); an `answer` this version doesn't know (0.29's "wait") reads as the plain text it carries.

**Account and storage.** The seed and device id are locked with an AES-256-GCM key in the Android Keystore and kept in
`noBackupFilesDir/friends-keys` (never in a backup; a phone whose Keystore refuses keeps them as a plain file there,
as iOS falls back to a protected file). The list, the pending queue, groups, chats, timetables and pictures are JSON
files in `files/friends/` (the backup rules include only `haltewekker.xml`, so they aren't backed up). The vault holds
`book`, `picture`, `groups`, `timetable` and keeps an iOS 0.29 vault's `extras` as it came, so a restore here and a
backup from here don't lose it. Restore on Android of an account made on an iPhone (or the other way) works: same seed,
same keys, the other phone gets 409 and is signed out.

**Relay** (`FriendRelay`): every 0.25/0.26 route (`register`, `send` ≤ 20, `inbox`, `ack`, `drop`, `block`,
`vault/put|get`, `state/put|get|clear`, `leave`), OkHttp with no retries of its own (a nonce works once), 409 → signed
out (keys forgotten, a banner says so), 404 `unknown_account` → registered again, a 4xx refusal lets that box go.

**Checks (no push):** the app to the front (≤ every 20 s), every 30 s while Friends is open, every 8 s while a chat is
open (friends' trips every 30 s of those), the ride's network tick (`RideService.tickLoop` calls
`FriendTravelShare.tick`: a whole check at most once a minute), and a WorkManager periodic check (`friends-refresh`,
about hourly with a network, only while there's an account with someone in the list). Lines fetched in the
background: one notification per chat (`friends-chat-<chat>`, channel "Friends"), tapping opens that chat; in front:
the in-app banner (none for the chat on screen).

**Screens** (`ui/friends/`): the home's round Friends button over the map (next to Settings) with a badge for requests
and unread lines, and Settings › Friends. Friends: make an account (a name) or restore (12 words), the backup code shown
once; the one-time screens (trips, then timetable); Travelling now (a map of friends' last fixes, a row each); requests
(accept, decline, block); chats (recent, groups, New group); your friends; waiting for an answer (take back); Add a
friend (Show my code = QR, ZXing, error correction M; Scan a code = CameraX + ZXing on the camera's Y plane, no Play
services; Send my link = the share sheet; paste a link); Your trips / Share my timetable switches; You (name, picture
from the photo picker, cropped square, 256 px JPEG ≤ 40 KB; backup code; delete the account). A friend's page: their
trip, the coach hint when you're on the same train ("Wait near B, at the front end of the platform", from NS's drawing
at *your* boarding station), Message, Compare timetables, "Show my trips to …", "Share my timetable with …", Remove.
A chat: lines, quick replies ("On the 305" while you ride), trip cards with "Take this trip" / "I'm in" / "Can't", how
far your last line got (waiting, sent, delivered, read; "n of m" in a group). A group's page: picture, name, members
(the admin adds, removes, renames, sets the picture), Compare, Leave, "Share my timetable with this group". Compare:
today to Sunday and next week, everyone's day, free time together, "Every class" of the open day, To school / Home rides
together with who's missing, Meet halfway with "Send to …". Links: `haltewekker://friend?…` and (for phones where you
let the app open it) `https://haltewekker-relay.tsfaw1.workers.dev/add`; the relay's /add page opens the app link.

**Travelling now** (`FriendTravelShare`): reads `RideStore` (debounced 2 s) and the ride's tick, never changes the
ride. Confirmed on board = started by hand (not auto-start), "I'm on it" (`BY_HAND`) or matched by GPS (`BY_GPS`; not
`BY_TIMES`). Stage: no vehicle yet and the leg not left (a minute's slack) is `waiting` (first leg) or `change`; else
`riding`. Sent every 55 s on the tick and at once on a new leg, vehicle, stage or coach; taken back with
`state/clear` when the trip ends (again at the next check if that failed). The ride state now keeps its last fix
(`lastLat`/`lastLon`, 5 decimals) for `pos`; Home goes as `{"name":"Home"}`. The ride screen gets a Friends card: the
one-time question once on board, friends on the same vehicle, and on an NS train the coach picker (relay
`/ns/train?num=&station=`; numbered from the front when NS gives `rijrichting`, else from the left at that station).
NS station codes come from the iOS app's `NSStations.json`, copied into the assets at build time like `Schools.json`.

**Timetables and areas** (`FriendTimetables`): calendar users send every non-all-day, non-cancelled event (≤ 12 h) of
the calendars picked for the school alarm, with the location as room; week users one class per school day (first class
to the end time, title). The area: the setup's home stops (non-rail, within 3 km), else three nearest non-rail stops
within 1.2 km (one `/v1/map/stops` question, remembered until Home moves 300 m), the NS station nearest Home within
5 km, the school (its name, 5 decimals, its first stop id) and the school alarm's "be there N min early". The send rules
are `TimetableShareRules` (FNV-1a 64 fingerprint over the sorted JSON, 3 h / 20 h / 7 days, `off` boxes to whoever
shouldn't have it any more).

**Take this trip** (`TripTaker`): gone → says so; within the hour → your way: the card's rides when you're within 600 m
of its first stop (or have no fix), else the planner from here (arrive by the card's time) picking the option with the
shared ride's trip id, else onto the shared ride at a stop of its route within walking distance (< 900 m, leaving > 2
min from now); shown with "I'm on it: start the ride". Later (today/tomorrow to School/Home, or anything else): the
planner's ways there by the card's time with the friend's ride first. Taking it answers "I'm in". "Send to a friend"
sits under Fastest trip's opened trip.

**Tests** (JUnit; 111 in all, one skipped in CI: the live check):
- `FriendVectorTest` — **every test vector in the spec passes**: Sam's, Lou's and Kim's keys, account ids, vault key and
  `k`; Sam's backup code (and typed back loosely; a wrong checksum refused); the request (0.25), travel (0.26), message,
  group list, Kim's fan-out to Lou and to Sam, trip card (0.27), timetable and area (0.28) boxes: signature (Node's
  deterministic Ed25519, the same bytes), ephPub, box key and the box byte for byte, and opening it on the other side;
  the 0.29/0.30 wait, campus and scores boxes open too (and are read as unknown kinds); the payloads of the 12 known
  ones are rebuilt from the parsed box byte for byte; the answer payloads; the signed inbox request and the signed
  `state/put` (body SHA-256 and signature); the vault byte for byte; Kim's group line opening only with the list's card.
- `FriendLogicTest` — links and names, request/accept/rename/remove through real boxes, unknown kinds kept, groups (the
  list before the lines in one batch, orphans kept and read later, leave and admin hand-over, a non-friend's list
  refused), chats (delivery, marks due, answers, cleaning, quick replies), travel rules, words and freshness, the coach
  map, Take this trip's ways and words, timetable/area cleaning and send rules, your week's classes.
- `FriendCompareTest` — the iOS `FriendCompareTests` with the spec's worked example (Monday 18 January 2027).
- `FriendLiveInteropTest` — `HW_LIVE_RELAY=1 ./gradlew testReleaseUnitTest --tests nl.haltewekker.FriendLiveInteropTest`:
  an account made by the Android code and an "iOS-style" one written in the test from the spec alone with the JDK's
  own crypto (SunEC Ed25519/X25519, the JDK's ChaCha20-Poly1305, HMAC HKDF, none of the app's code) register on the
  live relay, exchange a request, an accept and a line (the Android side reads them with `FriendInbox`), a travel state
  each way through the state routes, Android's vault round trip, then both `/f/v1/leave`. Passed from the build
  container on 2026-11-19 (about 6 s). CI skips it (no network test in CI).

### Calls made in A3 (the user can correct)

- Bouncy Castle (`bcprov`, about 5 MB more in the APK, now about 20 MB) over Tink or hand-written curves: well known,
  pure Java, works from API 26. ZXing core for QR in both directions, CameraX for the camera: no Play services.
- The friend list and chats as JSON files (not SharedPreferences), the secrets Keystore-wrapped in `noBackupFilesDir`.
- Friends' entry: a round button with a badge on the home map next to Settings (Android's home has no bottom bar), plus
  Settings › Friends. The Friends screens use their own back stack inside one top-level screen.
- "Waiting at the stop" / "at a change" are inferred (no vehicle yet and the leg hasn't left), since the Android ride
  has no explicit waiting state; an auto-started ride is shared only once the ride matched its vehicle by GPS.
- Take this trip doesn't make a Be-there-by plan with a reminder (Android has none yet): for later trips it shows the
  ways there by the card's time, the friend's ride first, and you start the ride from Fastest trip or the card when it's
  time. Meet halfway and the ride's "onto their ride" use Transitous `/v5/trip` stops without pickup rules (Android's
  parse doesn't read `pickupType`): every stop counts as one you may board at.
- The WorkManager check is its own periodic work (hourly, network), on whenever there's someone in the list, not only
  with the school alarm on.
- No read-mark switch, chats not in the vault (as iOS 0.27). Friends' pictures aren't in the vault (as iOS 0.25).
- R8 stays off (no device test pass yet), so no keep rules were needed for kotlinx.serialization or Bouncy Castle.

## As built A2 (0.2.0, version code 2)

**School alarm** (iOS `School.swift`, `ManualWeek.swift`, `SchoolHints.swift`, `DayTimeline.swift` `SchoolSkip`).

- Where the first classes come from is the profile's `schedule` (`CALENDARS`, `MANUAL`, `NONE`) with `week`
  (`ManualWeek`, iOS weekday numbers 1 Sunday … 7 Saturday, start, optional end and title, the same cleaning rules).
  The school alarm's settings are `SchoolConfig` (`school.v1`: on, calendar ids, at school N min early (0–45, default
  10), wake N min before leaving (15–150, default 60)); the planned week is `school.week.v1` (`Planned`, with the trip
  kept so Your day can show it after a restart); skipped days `school.skip`.
- Calendars: `Calendars.list` and `events` (`Instances`, each repeat apart); the first class of each Amsterdam day,
  not all-day, not cancelled (status or a title with cancelled/geannuleerd/vervalt), `Timetable.firstClasses`. The
  calendars that look like a timetable (`SchoolHints`: the timetable apps' names and the school's own short and full
  names of 4+ letters, in the name and account, else in 60 events' notes and rooms) are marked and picked when none is.
- `SchoolPlan.plan` is iOS's plan as a pure function: classes in, the week and alarm operations out. Per day: a rung
  alarm is never touched; a class within 20 minutes is left; due when moved, forced, or 14 min (within 36 h) / 6 h old;
  Transitous `/v5/plan` from Home to School arriving by "be there" (6 itineraries, 4 transfers); the trip that leaves
  the latest and arrives within a minute of "be there", fewer changes on a tie; alarm = leave − wake minutes;
  `SchoolSkip.decide` (skipped: clear; the same minute: keep; else set, only when more than a minute ahead). No answer
  keeps what it had. Notifications "School alarm tomorrow 07:10" for new alarms and "moved to …" for a move of 5+ min.
- The alarm: `setAlarmClock` (exact; 12 without the exact-alarm right: `setAndAllowWhileIdle`, said in Settings). On
  firing `WakeReceiver` checks the day is still on and its alarm still this one (−10…+30 min), then `WakeService`
  rings out loud (also with headphones in: it's a wake-up at home) with the full-screen `WakeActivity`: the time, "Time
  to get up", "Leave 07:42 for your 08:30 Design", **Stop** and **Open**. Open stops the alarm *before* opening Your
  day (the notification's Open goes to the app with `stopWake`, which stops it as it opens; opening the app at all
  stops a ringing school alarm, as iOS 0.24.6). A volume key stops it. Not stopped after 10 min: quiet, and "Did you get
  up? Leave by …". Settings has "Test the alarm: it rings in 1 minute" and shows the phone's next alarm clock.
- Restart, update, clock or time-zone change: `BootReceiver` sets the week's alarms again from what was planned (no
  network), re-registers the proximity alerts and asks WorkManager for a plan.
- **Your day** (`DayScreen`, the alarm's Open and the home's school card): the next school day's class and room,
  ALARM / LEAVE / AT SCHOOL, "Good morning" after the alarm, the trip's legs, "I'm on it" within 90 min of leaving,
  "Wake me this day" (that day only; back on: set at once from the trip it has, then planned again), the week with a
  switch per day, Plan again. The morning screen's drawn backgrounds and photos are not ported.

**Auto-start** (iOS `RoleRegions` off the corridor, `RegionLook`, `TripManager.leftRegion`/`autoStartDoor`,
`TripResume`).

- Regions (`AutoRules.wanted`): School (350 m; exit for auto-start, entry for auto-home) and the home stops, merged
  within 150 m, at most three (350 m; Home itself without stops). Registered as platform proximity alerts (mutable
  PendingIntents, one per region) only with fine **and** background location; set again at each app start, Settings,
  setup Done and boot. Settings › Trips by themselves explains why "all the time" is needed and asks for it.
- Leaving one (no ride, auto-start on, not within 20 min of a ride ending in that region unless at vehicle speed):
  `RideService` starts in a *look* mode (foreground, location, notification "Looking for your bus or train" with Stop
  looking), GPS every 3 s, ten looks 35 s apart with A1's `OnBoardLook` (no planned leg: timetable-only fits only at
  vehicle speed; the same one twice). Found and not blocked (a trip you ended by hand stays blocked 2 h): the trip to
  the other place whose ride is that vehicle, planned from the region left (15 min before leaving), else from here;
  started at that ride, the vehicle known by GPS, "Trip started by itself". Nothing found: GPS off again. If Android
  refuses the background start (battery limits), a notification asks you to open the app.
- Reaching School switches the home's next trip to Home, once a day.
- **Continue your trip**: ending a trip by hand before its last leg stores the leg to go on with (`TripResume.leg`; on
  Android "at a change" is a later leg without a vehicle yet); the home offers it for 30 min while you move like a
  vehicle (`movingByTrack` on the home's fixes) or within 1 km of that leg's stop.

**Setup** (iOS `SetupFlow`, `SetupLogic`, `SetupBackup`): Welcome, School, Home, Stops near home, **Your timetable**
(a calendar on the phone with the picker; a roster link turned into `webcal://` and handed to the calendar app, with
ICSx⁵ or Google Calendar's "From URL" suggested and the link copied when no app takes it, then the picker; the same
times every week with a day editor (start, end, title); later), **Mornings** (be there N min early, wake N min before
leaving, school alarm on/off), Allow the alarms, **All set** (a summary, each line opens its step). Set up again starts
from what you have. **Test the setup as a new user** (Settings): `SetupBackup` keeps the stored values of the profile,
the school alarm's settings, week and skipped days, the auto-start's memory and Continue your trip (`setup.backup.v1`,
written with `commit`), the setup opens empty; Cancel drops it, Done makes the test live (the home and Settings say
so), "Back to my own" cancels the test's alarms and puts every value back exactly (a key that wasn't there removed),
then sets your own alarms again; a test that never reached Done is put back at the next launch.

**Ride bar and notifications**: the ride made smaller (iOS 0.26.1 `RideBar`): the ride screen's ↓ goes to the home,
which shows a bar over the map (line pill, "Bus 305 to Uden", the countdown in min (or the distance), the leg, how the
wake-up stands); tap opens it full; the alarm always opens it full. Old notifications (iOS `NoticeExpiry`): every
non-ongoing one is posted with a tag and `setTimeoutAfter` by its kind (arrived 10 min, trip started by itself 10,
the missed school alarm 90, school alarm news 12 h), and a sweep at each app open and background plan takes off any
left over.

**Tests** (JUnit, 81 in all): `SchoolTimetableTest` (the week's rules, lessons across summer time, weekday numbers,
words, JSON with an iOS 0.23 week, first classes, hints), `SchoolPlanTest` (the trip, the alarm, moving, a class gone,
no answer, rung, skipped, past, due), `AutoRulesTest` (regions, merging, roles, the walk-away rule, blocked trips,
TripResume), `SetupBackupTest` (round trip, launch step, odd stored values, roster links, notice expiry, ride bar).

### Calls made in A2 (the user can correct)

- The school alarm rings **out loud** (alarm stream), not by the headphones rule: it's a wake-up at home, as iOS
  AlarmKit's. It rings 10 minutes at most.
- Home to School is planned from Home itself (iOS uses where you are when within 6 km of Home); no `earlierWays`/`Risk`
  safer-change pick yet (the latest trip in time wins).
- Roster links: Android has no built-in webcal subscription; the link goes to whichever app takes `webcal:` (ICSx⁵,
  some calendar apps), and the app reads the calendar that app makes. Fetching the iCal file in the app itself is a
  later option.
- Auto-start uses the platform's proximity alerts (no Play services); "all the time" location is required, and
  "No battery limits" is recommended so Android lets it start from the background.
- Auto-start's look runs inside `RideService` (one location foreground service) rather than a separate service.
- Auto-start and auto-home default on, as iOS, but do nothing until background location is allowed.
- Not in A2 (moved on): Fastest trip's earlier ways and boarding further along, the "Time to go" notification, R8,
  Android 16 Live Updates, editing places one by one in Settings (Set up again starts from what you have), the morning
  screen's pictures.

## Calls made (the user can correct)

- Package `nl.haltewekker`, application id `nl.haltewekker.android` (debug builds `.debug`, so both can be installed).
- OkHttp over Ktor; SharedPreferences over DataStore; MapLibre + OpenFreeMap over osmdroid.
- One universal APK for ARM phones (arm64-v8a, armeabi-v7a; no x86), native libraries compressed: about 15 MB.
- No R8 minification in A1: it can't be checked on a device from CI; it comes with A2's device pass.
- The backup alarm by time is **on** by default on Android (off on iOS): Android phones differ more in how they treat
  background GPS, and an early alarm is better than none.
- A1: rides started by hand ("I'm on it") only; A2 added auto-start (it needs background location).
- The ride's own matching is the simpler rule above; the full `choose` state machine is not ported yet.
- Trains on the home map are NS's own positions (labelled with NS's type, SPR or IC), not joined to Transitous trips
  (Transitous's map gives no train numbers); buses and trams are Transitous trips, at their OVapi positions when fresh.
- English UI text, as the iOS app.
