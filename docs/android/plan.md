# Haltewekker for Android: plan

The Android version of Haltewekker, built from the iOS app (`ios/`, SwiftUI) as the reference. It lives in
`android/` (one Gradle project), with this plan in `docs/android/`. The iOS app and the relay are not changed by it.

Status: **A1 (0.1.0, version code 1) and A2 (0.2.0, version code 2) built.** A3 and A4 are planned below.

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

### A3 — Friends 0.25–0.28 (0.3.x)

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

### A4 — Friends extras 0.29–0.30 and log sharing (0.4.x)

- 0.29: "Wait for me", the delay alarm for shared rides, the wake-up buddy, who's on campus.
- 0.30: free time together, the live link (`/live/<token>#<key>`), the leaderboard with friends, rides together.
- Log sharing (`LogShare`, `docs/logs-export.md`): the field log and a share sheet, for tuning the matcher from Android
  rides.

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
