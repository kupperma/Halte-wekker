# Haltewekker for Android: plan

The Android version of Haltewekker, built from the iOS app (`ios/`, SwiftUI) as the reference. It lives in
`android/` (one Gradle project), with this plan in `docs/android/`. The iOS app and the relay are not changed by it.

Status: **A1 (0.1.0, version code 1) built.** A2 to A4 are planned below.

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
| Background | Foreground service (type `location`) for rides; AlarmManager for the backup alarm; WorkManager from A2 | See "How each iOS feature maps". |

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
- `profile/` — `Profile`, `Settings`, `Store`, `SchoolCatalog` (search ported from `SchoolCatalog.swift`).
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
| Background refresh (BGTask) | WorkManager, from A2 (the school alarm plans the morning's trip). A1 has no background work at all: the home's loops run only while it is in front (`repeatOnLifecycle(STARTED)`), the ride's only during a ride. |
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

### A2 — school alarm, calendar timetable, setup polish (0.2.x)

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

## Calls made (the user can correct)

- Package `nl.haltewekker`, application id `nl.haltewekker.android` (debug builds `.debug`, so both can be installed).
- OkHttp over Ktor; SharedPreferences over DataStore; MapLibre + OpenFreeMap over osmdroid.
- One universal APK for ARM phones (arm64-v8a, armeabi-v7a; no x86), native libraries compressed: about 15 MB.
- No R8 minification in A1: it can't be checked on a device from CI; it comes with A2's device pass.
- The backup alarm by time is **on** by default on Android (off on iOS): Android phones differ more in how they treat
  background GPS, and an early alarm is better than none.
- Rides start by hand ("I'm on it") only; auto-start waits for A2 (it needs background location).
- The ride's own matching is the simpler rule above; the full `choose` state machine is not ported yet.
- Trains on the home map are NS's own positions (labelled with NS's type, SPR or IC), not joined to Transitous trips
  (Transitous's map gives no train numbers); buses and trams are Transitous trips, at their OVapi positions when fresh.
- English UI text, as the iOS app.
