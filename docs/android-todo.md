# Android: what iOS has that Android still needs

The rules and numbers for each are in [logs-export.md](logs-export.md) › For Android (parity), with the iOS files and
their tests.

## iOS 0.42.9 (less battery and data on long rides)

Field logs of long door-to-door trips showed the best GPS for almost the whole ride (also long train legs far from the
stop and long waits at a change), a Live Activity update about once a minute, and long-distance coaches far away
judged on every look. Rules and numbers in
[logs-export.md](logs-export.md) › "Less battery and data on long rides (0.42.9)"; shared vectors
`docs/battery-vectors.json`.

- [x] **Rough GPS far from the stop** (`RideAccuracy`): 100 m and a fix every 300 m on a confirmed vehicle while the
      nearest you can be is beyond the wake distance + 2 km (+ 30 s at top speed) and the stop is more than 6 minutes
      off; the best in a leg's first 2 minutes, a bus's last 3 km, on doubt, in the backstop region. **Android 0.10.7:**
      `ride/RideSaver.kt` (`RideSaverTest`, every vector), `RideService.gpsTier` on each fix and each tick: the network
      provider every 20 s and the passive one, no GPS chip (only without a network provider, once a minute). Android
      has no repeated "still the same one?" look: found by GPS counts as confirmed (fresh).
- [x] **Rough GPS while you wait at a change** (`ChangeWait`): stood 3 minutes, until 3 minutes before the next ride.
      **Android 0.10.7:** after a leg with no vehicle yet, the stand from `noteWaitAnchor`, the next ride's departure.
- [x] **Live Activity cadence** (`ActivityCadence`). **Android 0.10.7:** the ongoing ride notification (`notifyRide`).
- [x] **The trip's live times every 2 minutes far away, 45 s near** (`RideNet`). **Android 0.10.7:** the tick's
      arrival look.
- [x] **Candidate prefilter** (`CandidatePrefilter`). **Android 0.10.7:** `OnBoardLook.look`.
- [x] **Smaller plans** (`detailedLegs=false`). **Android 0.10.7:** `Transit.plan(detailed = false)` for the ride's
      own plans (the home map still draws the shapes it gets).
- [ ] Android: a Battery & data screen with the ride cost (iOS `BatteryLog`): Android has no battery log yet.
- [ ] Android: a repeated "still the same one?" look, so the rough tier can expire and look again as on iOS.
## iOS 0.42.9 (which side you get out)

The request "I would like the app to also show which side you get out of the train". The relay's new
`/rail/v1/side?station=BD&track=4&from=<lat,lon>&at=<lat,lon>` (`relay/rail.js`, tests `relay/test-rail.mjs`) says
whether the platform of that track is on the left or the right of a train going from the stop before to the station,
`both`, or `unknown`, with `confidence` high/low. It's worked out from OpenStreetMap (map data © OpenStreetMap
contributors, ODbL): the platforms whose ref is the track (`railway=platform`/`platform_edge`, in the Netherlands one
area per side of an island), the nearest rail to each, and the sign of (the way the train goes) × (platform − rail);
one area for both sides of an island, or a train across the track: unknown. Overpass is asked once per station (a box
400 m around it) and the trimmed platforms and rails are kept 30 days in the Durable Object `Rail`; on the trimmed OSM
data of 's-Hertogenbosch, Eindhoven, Breda and Tilburg (`relay/test-rail/`) every numbered platform gets a side, the two
sides of each island opposite, and 's-Hertogenbosch 1 (at the station hall, east) "right" going north. Rules in
`ios/App/DoorSide.swift` (tests `DoorSideTests`, vectors `docs/door-side-vectors.json`), asked by `DoorSideStore`
from `TripManager.noteRideDetails` (the leg's own train trip, its platform at your stop and the stop before; again only
when those change, never while the alarm rings, a failed one again after 5 min).

- [x] **"Exit on the left · platform 4".** Under "your stop" in Stops ahead, in the change card ("Get off at Den
      Bosch: exit on the left · platform 3"), on the alarm screen, in the wake alarm's and the get-ready notification's
      text, and on the lock screen's ride line ("platform 4 · exit on the left"). "Exit on both sides", "(estimate)" when
      the relay isn't sure; nothing when it doesn't know. **Android 0.10.6:** `ride/DoorSide.kt` (`DoorSideTest`, the same
      vectors), `TripStop.track` from the trip answer, `RideService.doorLook` on the ride's minute tick, `RideState.doorSide`
      in the ride card, the change card, the ride notification, the alarm and the get-ready notification.

## iOS 0.42.8

Three field reports on the planner's ways: "The new screen doesn't account for delayed time" (Breda 14:37: Fastest
trip "Bus 5 … 14:41 +3", the stop's sheet "5 14:38 live"), "The app missed this one" (Breda 14:48: the 14:38 IC to
Eindhoven, 10 min late, still at platform 3, never offered) and "it says it's a 10-minute walk. It's more like 3–4
minutes … it recommends taking the bus near my home to then take the other bus". Rules in `ios/App/NearbyLive.swift`
and `ios/App/PlanFix.swift` (`LiveKeep`, `WalkFirst`; tests `NearbyLiveTests`, `PlanFixTests`), the wiring in
`NearbyStore.freshen`, `NearbyDetail`, `NearbyViews`, `Transit.tripsFrom`/`keepUseful`/`walkFixed`/`nsLive`,
`GoStore.nextOnes`, `PlanTrip`.

- [x] **The stops around you by live times.** A way's legs are freshened by newer live times of the same trips (by trip
      id, at any of their stops: the delay applies to the leg's own timetable times): the stop's board
      (`/v6/stoptimes`, all of it, not only "Also from here") and Fastest trip's own ways (each time it updates). Only
      an update newer than the way's own answer counts, only live ones; the same one twice changes nothing more. The
      ranking, the colours, Fastest/Surest (by live arrival: the same arrival, fewer changes, then the later one), the
      leave-in and the whole-trip bars follow. Times shown "14:41 +3" with the planned 14:38 struck through and grey;
      "live" only with live times ("timetable" without); the list row says "· leaves 14:41 +3". Tags never wrap
      (one line, fixed size; the row's other text gives way). **Android 0.10.5:** `travel/NearbyLive.kt`
      (`NearbyLiveTest`, every iOS vector), `NearbyStore.freshen`/`fresh` from the stop's board, `TimeRow` with the
      struck planned time, tags on one line. (Android's Fastest trip doesn't feed the nearby view yet.)
- [x] **A late departure still to leave is kept.** Ways are kept by their live departure (no more than 30 s ago, not
      cancelled, set off at most 90 s ago), never the timetable time; at a station the planner is asked from 15 minutes
      back (3 more ways), the rest 2 minutes back; Plan's "now" from 15 minutes back too. At a station NS's board (relay
      `/ns/departures`) moves a train of the answer to its live time by train number, and a way whose changes it no
      longer makes (room ≥ the walk, ≥ 1 min) goes. Fastest trip's next ones: the five there soonest, shown by live
      departure. **Android 0.10.5:** `data/PlanFix.kt` `LiveKeep` (`PlanFixTest`), `TransitParse.keepUseful` by live
      departure, `Transit.tripsFrom` and the plan screens from 15 minutes back. NS's board merge: not on Android yet.
- [x] **Walks by their distance, no silly hop first.** The first walk is timed by its distance (the planner's foot
      route `distance`, or the straight line × 1.3 when that route is over twice the straight line) at the speed it
      was planned with (yours after 5 walks, else 1.2 m/s), never longer than the planner's minutes; a first ride of 6
      minutes or less is swapped for walking straight to the next ride's stop when that makes the same ride (a minute
      to spare) and the walk is no more than 1.3 × the hop (Fastest trip, the stops around you). Logged once per plan:
      `walk · planner 10 min (780 m) · yours 4 min (1.35 m/s) · used yours`. **Android 0.10.5:** `WalkFirst` (same
      vectors), in `keepUseful` (Fastest trip, the plan screens) and `NearbyStore.place`.
## iOS 0.42.7 (Listening now)

Sharing the song you listen to while you travel, with friends and on your live link. Rules, the relay route and the
vectors in [the friends spec](superpowers/specs/2026-11-18-friends-design.md) › "As built: Listening now"; the shared
vectors `docs/music-vectors.json` are checked by the relay, iOS and Android alike.

- [x] **Settings › Friends › "Share what I’m listening to"** (off), From, Who sees it, "Check what’s playing".
      iOS: Apple Music or Last.fm (Spotify via Last.fm). **Android 0.10.4:** `friends/MusicShare.kt` (`MusicShareTest`,
      every vector), `MusicShareStore` (any music app's media session through Notification access, the
      `MusicListener` service in the manifest; or Last.fm), `ui/friends/MusicShareUi.kt`'s card.
- [x] **Out with the existing puts**: the travel state's `music` and payload v2's `music`, looked at on the ride's tick
      (≤ every 30 s), dropped when paused or 10 minutes old, gone at the trip's end. **Android 0.10.4:**
      `FriendTravelShare.build`/`tick`, `LiveLinkStore.state`, `LiveRules.key`.
- [x] **A friend's page**: the "LISTENING NOW" strip, "💬 Message" and "🎧 Listen too". **Android 0.10.4:**
      `FriendListeningStrip` on `FriendMapPage`. (Android's own live-link view doesn't show the card yet; the page does.)
- [ ] Android: the card in the app's own live-link view (`LiveViewScreen`), drawn in its dark colours.

## iOS 0.42.6

From the field report "The alarm went off when I was already on a trip to school. I was meeting friends earlier, so I
left two hours earlier and set my own alarm. Maybe add a change-arrival-time option?". Rules in
`ios/App/SchoolArrive.swift` (`SchoolArrive`, `OnTheWay`; tests `SchoolArriveTests`), the wiring in
`ios/App/School.swift` (`checkOnTheWay`, `setArrival`, `alarmFor`) and `ios/App/ArriveViews.swift`; the log lines in
[logs-export.md](logs-export.md) › 0.42.6.

- [x] **Never ring when you're already going.** Today's school wake-up (still to ring) is skipped when (a) a trip toward
      school (your fixed route to school, or its last stop within 1.5 km of school) started this morning (from 03:00)
      and either runs or you're not back home (a fix ≤ 15 min old within 500 m of home rings again), (b) you got to
      school today (the school region, a trip to school that reached its last stop, or a fresh fix within 400 m),
      (c) a trip or ride started this morning and you left home's region this morning or a fresh fix is more than
      1 km from home. Moving around at home without a trip or ride never skips it; a trip that started before 03:00
      doesn't count. iOS cancels the AlarmKit alarm and the `wake-<day>-0…2` notifications, on a trip start, a region,
      the trip's position (each minute) and every plan (background refresh too); a quiet notification says "No school
      alarm today · You're already on the way (trip 07:12)", and the day's switch on Your day turns it back on (not
      skipped again that day). **Android 0.10.2:** `school/SchoolArrive.kt` `OnTheWay` (`SchoolArriveTest`, every iOS
      vector); a ride's start and end from `RideStore.set`, home's exit and school's entry from `AutoStart.onRegion`,
      every plan, and `WakeReceiver` checks once more as the alarm goes off (decided as if still to come).
- [x] **"Be there at …" per day.** Your day / Your week (and the school alarm's card): the day's be-there time (default
      the timetable's: first class minus how early), a time picker, "1 h earlier", "2 h earlier", "30 min later" (from
      the timetable's), "No alarm this day", "Reset to timetable"; shows "Changed: be there 09:00 (class 11:00)". Per
      date (yyyy-MM-dd, `school.arrive`), gone after its day; whole minutes, the timetable's own minute is no change,
      more than 12 h from the class is refused. Planning arrives by it at once (and in the background); with no answer
      from the planner right after a change, the old trip moves by the change (leave and arrival shifted, planned again
      at the next chance). The alarm's label and the wake-up notification: "Time to get up · be there 09:00", "Leave
      07:50 to be there 09:00 (class 11:00)" (as before when the day isn't changed); a new label alone sets the alarm
      again while it's more than 5 min ahead. Siri / Shortcuts: "Be at school at a time" for the next school day.
      **Android 0.10.2:** `SchoolArrive` and `SchoolPlan.plan(arrive = …)` (the same shift and relabel), `DayScreen`'s
      "Be there at" row (time picker, the quick choices, no alarm this day, reset), the home card's changed line.
      No Siri on Android.
## iOS 0.42.5 (the live link: the whole trip, messages back)

The live-trip page was redone (relay 2026-11-27) and both apps send it the whole trip. Rules, routes and the vector in
[the friends spec](superpowers/specs/2026-11-18-friends-design.md) › "As built (relay 2026-11-27, iOS 0.42.5, Android
0.10.1)"; the shared vector `docs/live-link-vectors.json` is checked by the page's script, iOS and Android alike.

- [x] **Payload v2**: the legs (rides and walks, line colours, platforms, the coach you shared), the leg you're on, its
      stops and road (≤ 200 points, encoded), the next stop, the vehicle's own GPS first (`pos.src`), the face colour,
      `inbox`, and a reserved `music` (nil). The v1 keys stay. **Android 0.10.1:** `friends/LiveTripV2.kt`
      (`LiveTripV2Test`, byte for byte against the vector), built in `LiveLinkStore.state` from the ride, the saved copy
      of its ride (`RideCacheStore.saved`) and OVapi/NS fixes.
- [x] **Messages back**: the page's (and another app's) messages read on the ride's tick when a put says there's one
      (`mseq`), a notification "💬 Kim: On my way" (`livemsg-<seq>`, 60 min, channel "Live link messages"), on the live
      link card with "Reply"; seen once shown (`/live/v1/ack`). **Android 0.10.1:** `LiveMessages`, `LiveLinkStore.inbox`,
      `markSeen`, `reply`.
- [x] **Open a live link in the app**: `haltewekker://live/<token>#k=…` (the page's "Open in Haltewekker"), the https
      link, pasted in Friends, or shared as text; the trip with its map and a message box that sends your own name and
      friends account. **Android 0.10.1:** `friends/LiveView.kt`, `ui/friends/LiveViewScreen.kt`, the manifest's filters.

## Android 0.10.1 (Android only)

- [x] **No "Did you check out?" unless you turn it on**: off by default, turned off once for every install
      (`Settings.migrated`, `CheckOutOffTest`), Settings › Trips & alarm › "Check-out reminder" turns it on again; a
      pending one checks the switch before it goes, and a left-over one is taken off when the app starts. (iOS: 0.42.4.)
- [x] **Every train of the trip is watched for a new platform or a cancellation** (`ride/PlatformWatch.kt`,
      `PlatformWatchTest`): each train leg from the one you're on or wait for (also at a change), leaving within 3 h,
      seeded with the planner's planned platform, NS's board at most once a minute; told at once (quiet while the ride
      sleeps, with sound when awake; channel "Platform changes", `platform-…`, 20 min); the leg gets the new platform
      (the change card, the ride's notification). (iOS: 0.42.4.)
## iOS 0.42.4

From the field report of 27 November ("The on-board detection became worse with the new update. I got on the bus at
Veghel busstation and expected it to start a trip the moment I got on"): Fastest trip watched the 09:52 305 from
Biezendijk; you got on an earlier 305 at the bus station, a stop or two before it, and the trip never started while the
screen kept saying "Go to Veghel, Biezendijk · 2 min walk" with you on the bus past it. Rules in `ios/App/WaitStart.swift`
(tests `WaitStartTests`); the iOS wiring in `GoStore.checkBoarding` (`ios/App/Go.swift`) and
`TripManager.boardedHere`; the log lines in [logs-export.md](logs-export.md) › 0.42.4.

What was wrong on iOS (check the same on Android's wait state, `RideService`/`RideChoice`):
- A bus that wasn't among the ways on screen (an earlier 305) needed the same best fit on two looks in a row **and** a
  second, independent on-board look (no planned-ride nudge, no stop-departure nudge, sometimes a single fix) to agree on
  exactly that trip. With the 305 and the 306 on the same road out of Veghel the best flipped between them, and one look
  without an answer started the count again: it never started.
- Nothing was looked at while the bus stood at a stop (your GPS speed under 3.5 m/s at that moment).
- The screen only took "you're moving" from 8 m/s: a bus through town is slower, so it went on planning a walk back to
  the stop it had passed (and the stops-around-you overview searched again every 250 m on the bus, its requests queued
  in front of the look at what you're on). Motion & Fitness's live updates belonged to the home screen and stopped
  while Fastest trip was open.

- [x] **Moving like a bus or train while waiting** (`WaitStart.moving`/`movingRule`): 30 s at 6 m/s or more in the last
      2 minutes (a step's speed is the GPS's own, else the distance over the time when it's more than the fixes'
      accuracy; a gap over 30 s says nothing), so a stop on the way still counts; 10 s with Motion & Fitness saying
      automotive; never while it says walking, running or cycling under 12 m/s; standing (no step at speed, speed < 2)
      is "standing".
      **Android 0.10.3:** `ride/WaitStart.kt` `moving`/`movingRule` (`WaitStartTest`, every iOS vector); no Play
      Services, so no "automotive": by speed only, the step detector's walking (when "Use motion" is on) is "afoot".
- [x] **Each look** (every 6 s; the 4/8/15/30 s back-off only after 3 minutes at speed with nothing on its way to
      starting): the matcher's 4 best; for those within `close` (60 s) of the best, whether the trip takes you on
      (`WaitStart.reaches`: one of its stops from the one nearest to you on, not passed over 2 min ago, within 600 m of
      the watched ride's stop, a later ride's boarding stop of any way on screen, or the destination; kept 2 min per
      trip). Looks are counted per trip while it stays within `close` of the best (the 305 counts on while the 306 is
      best for a look). The pick among those that take you on: the watched ride, then any ride of its line (another
      departure), then the best fit. Looks needed: by its own GPS (≤ 90 s old) 1 for the watched ride or its line when
      under `oneLookWatched` (20 s), else 2; by its times alone 1 for the watched ride that close, 2 for its line, 3 for
      another line.
      **Android 0.10.3:** `WaitStart.step`/`needed`/`reaches` with these numbers (`RULES`: 20 s, 60 s), the looks by
      `RideService`'s watching (`WaitWatch.nextLook`: 6 s, the back-off after 3 min at bus speed) and `WaitLook` (the
      live map's vehicles, their own GPS, the 4 best, stops kept 2 min). No request while you stand.
- [x] **Start on the vehicle found** (any departure of the line, any line that gets you there): the way on screen that
      rides it, else plan on from it (from its next stop at its time there: an earlier bus can mean an earlier train);
      another line more than 30 min slower than the watched way: not started ("a long way round"). The leg starts where
      you got on (`WaitStart.repoint`): of its trip's stops up to the one nearest to you, the one nearest to where you
      started moving at bus speed (a run with a slower fix before it, within 400 m), unless that's within 150 m of the
      planned stop; the ride's time there; where you get off and the rest stay. During a ride too (a vehicle found after
      "I'm on it"), never when that would make the leg short (no alarm) where it wasn't.
      **Android 0.10.3:** `RideService.startOn` (the way on screen, else `planOn` from its next stop at its time, else
      from here; "a long way round", "its stop is where you are"), `boardedFrom` (`repoint`), `boardOn` (the ride with
      the vehicle known, the close ones still chosen between); during a ride `boardedHere` on the first leg, never
      making a normal leg short.
- [x] **The planned ride's time (`TimetableStart`, 2 min before its live departure) never holds a vehicle that was
      found**: it holds only a start by the timetable alone.
      **Android 0.10.3:** already so: `TimetableStart` held only a find by the timetable alone (`!f.live`); the watching
      never asks it.
- [x] **Sure of one that doesn't take you on** (none within `close` does, the best by its own GPS for 75 s,
      `WrongBus.gpsFor`): the wrong-bus notification "You’re on the 154 to Schijndel, not your 305" · "It doesn’t go to
      <destination>. Get off at the next stop, and plan again from there." once for that trip.
      **Android 0.10.3:** `WaitStart.step`'s `WrongBus` call, told once per trip as a notification (`wrongbus-wait-…`;
      no ride screen yet).
- [x] **The look belongs to the watching, not to a screen**: it runs while Fastest trip watches whatever is in front
      (the cards, the stops around you, a sheet, the home) and with the phone locked; Motion & Fitness live while it
      watches; the stops-around-you overview closes (and doesn't search) once you're at bus speed. A log line when the
      watching starts and stops, and why.
      **Android 0.10.3:** Android had no watching at all; now `RideService` (`ACTION_WATCH`, a location foreground
      service, nothing new in the manifest) watches what Fastest trip puts in `WaitStore`, whatever screen is in front
      and with the phone locked, until back from Fastest trip, a trip starts, you're there, the trip has gone or 3 hours
      (`WaitWatch`, `WaitWatchTest`); at bus speed (`WaitStore.atVehicleSpeed`) the stops around you close and don't
      search. The log lines as iOS.
- [x] **The check-out reminder ("Did you check out?", the `checkout-` notifications, also between train companies) is
      off for everyone** (from the request "Stop giving the 'Did you check out?' notification, it's useless"): off by
      default, and existing users moved to off once (iOS: `notes.checkOut` set to false under the one-time flag
      `notes.checkOut.off-0.42.4`, `CheckOut.atLaunch`, tests in `TravelHelpTests`); the switch stays in Settings › Trips
      & alarm ("Check-out reminder", off) and in the settings search for anyone who wants it back. While it's off nothing
      is scheduled, and pending ones are taken away at launch and when it's turned off. **Android 0.10.1:** see "Android
      0.10.1" above (`Settings.migrated`, `CheckOutOffTest`).
- [x] **Every train of the trip is watched for a platform change** (from "The platform changed but it didn't send a
      notification"; `ios/App/PlatformWatch.swift`, tests `PlatformWatchTests`, wiring in `WatchStore`). On iOS only a
      first ride that was a train was ever watched (bus 305 → Intercity at Eindhoven: never), and only for a Be there by
      plan. Now: each train ride of the trip you're on (from its plan, again after every replan) and of the way Fastest
      trip watches, from an NS station, leaving within 3 h (up to 10 min after its planned time), by station code +
      train number + planned time. A new watch starts from the plan's platform (else NS's live one): a change against it
      is told, also one made before NS's first answer; with none, NS's own planned platform is what it was ("5" and
      "5b" are the same platform). Asleep on the ride: the notification at once without sound (time sensitive), the
      card and the chime once awake. The change card and the lock screen take the new platform at once. Checked at most
      once a minute while riding, at a change and while Fastest trip watches. Android: check whether its platform watch
      has the same first-ride limit (and the silent first fill). **Android 0.10.1:** it had no platform watch at all;
      now `ride/PlatformWatch.kt` with these rules (10 min behind, "5" = "5b", NS's planned as what it was), see above.
- [x] **"Walk there" opens the walk with arrows at once** (on the Go to card, at a change, on the boards): Android's
      `WalkScreen` directly, no map sheet with the turns first; Apple Maps (Android: the maps app) stays in the guide.
      **Android 0.10.3:** `WalkThere` is one "Walk there" button that opens `WalkScreen`; "Open in maps" is inside it.

## iOS 0.42.3

From a field log of 27 November. Rules in `ios/App/MissCall.swift` (with `ChangeGuide.swift`) and
`ios/App/ShortLeg.swift` (tests `MissCallTests`, `ShortLegTests`), `RideGuards.plannedNextAmong`,
`RealPositions.noMatchReason`; the log lines in [logs-export.md](logs-export.md) › 0.42.3.

- [x] **At a change, a next ride without a live time and without its own GPS is never called missed** before its time
      + 3 min, and never while you're within 150 m of its stop: from its time on the change guide says "Should be
      leaving now · Look out for it", quietly. With a live time but no GPS: a minute's grace, then "May have left ·
      Look out for it" (near its stop: look out) until 3 min, then missed. Its own fresh GPS (≤ 90 s) decides first:
      at or before the stop (40 m slack) not missed; 150 m or more past it, within a minute of its time or later,
      missed. **Android 0.9.0:** `ride/ChangeGuide.kt` `MissCall` (`MissCallTest`, every iOS vector); the ride's change guide passes the next ride's live flag (its stop's board) and your distance to its stop. **Android 0.9.1:** its own GPS too (`MissCall.seenOnRoad`: its trip asked every 2 min, OVapi by trip or NS by number, ≤ 3 min old, put on its road against its stop).
- [x] **A miss is told only once it held for a minute** (looks in between say "May have left"); a told miss that a
      later look takes back is logged, never told again for that look. **Android 0.9.0:** `MissCall.step` in `RideService.updateChangeGuide`; a take-back is logged (`change · miss taken back · …`).
- [x] **On the way (still on the ride into the change)**: missed only when your arrival (live or GPS) plus the change
      time you need is more than 1 min after the next ride's live departure, and the ride you're on has fresh data
      (its own GPS ≤ 90 s or live times asked ≤ 2 min ago); else "Tight — run" (or nothing). The slow-bus notification
      says "You'll likely miss" under the same rule, else "Tight change". **Android 0.9.0:** `MissCall.onTheWay` through `ChangeGuide.call`; fresh = the ride's vehicle known, or a fix and a live arrival ≤ 2 min old. The slow-bus notification's wording not changed (Android has none of its own).
- [x] **The ride offered instead continues from the change**: never the ride you're on or got off (by trip), never its
      line again (unless the next leg is on that line), and when its boarding place is known, within 500 m of the next
      leg's stop or where you get off. None left: on the way "Tight — run" (no "You'll miss"); at the change "You'll
      likely miss the 08:12". **Android 0.9.0:** `MissCall.sane` (feeding = the ride you're on, change places = the next leg's stop and where you get off).
- [x] **A leg shorter than the wake distance (or 800 m) doesn't ring** when the wake rule fires: awake without the
      alarm; a quiet "Get off at the next stop" notification once, not in its first minute, when the stop before yours
      is reached by its times, or 90 s before it's in, or (no times) halfway from where it started; the announcement at
      the stop only after the first minute and within half the way it started from (200–450 m). Dead reckoning the
      same. **Android 0.9.0:** the rules only (`ShortLeg`, `ShortLegTest` vectors in `MissCallTest`); **Android 0.9.1:** wired (`ride/LegAlarm.kt`, applied by `RideService.onLocation`/`reckonStep`; `LegAlarmTest` runs whole synthetic legs): the quiet word is a silent notification (`Notifications.quiet`), the stop before yours by the vehicle's trip; `quietLeg` and `legStartMetres` kept in the ride's state.
- [x] **Nothing rings in a leg's first minute**: within 20 s a firing wake rule wakes it silently (as before), from
      20 to 60 s it waits; a normal leg rings at the next fix after that (the alarm always rings for a normal leg). **Android 0.9.0:** rule ported (`ShortLeg.onFire`). **Android 0.9.1:** wired (`LegAlarm.fix`, `ring · held` in the log); Android's leg starts when the previous one ended (at the change), as before.
- [x] **On the planned next ride without the leg ending** (going away from this leg's stop, the "wrong way" look finds
      among the vehicles on your road, or the one you're on board, the ride the next leg was planned with): end this leg
      and start the next one on it ("next leg"), plan kept, alarm armed, no choice to pick from. Before, it planned the
      rest again from it ("wrong way") and asked to pick between it and another train on the same track. **Android 0.9.0:** `NextLegGuard.plannedNextAmong` ported and tested. **Android 0.9.1:** wired (`LegAlarm.onRoad`): going away from this leg's stop (800 m / 2 km further than you've been, moving ≥ 5 m/s) it looks at what's on your road (the matcher's look, the next leg's ride first); also when the ride's own look finds the next leg's planned ride by its own GPS, or a choice settles on it. Android has no "wrong way" plan again: neither found, it looks again after another stretch.
- [x] **OVapi positions**: the match is by OVapi's own trip_id (after `nl-OpenOV_` in the Transitous id), checked
      against the live feed: no id-format problem; trips missing at night simply aren't in the feed (not started yet,
      or their bus sends nothing) and go by their times. Log which key found nothing and whether its journey had
      begun (start time from the Transitous id, 24:00+ the next day). **Android 0.9.0:** `RealPositions.noMatchReason`/`startTime`/`dataset` ported and tested (the key was already OVapi's own trip_id); **Android 0.9.1:** the log line (`vehicle shown · … · no gps: no ovapi match for trip_id … (started 22:40) · by times`, `RealPositions.noGPSReason`).
## iOS 0.42.2

**Android 0.9.0:** the rules of 0.42.0 and 0.42.2 are ported with every iOS vector (`travel/Nearby.kt`: `NearbyTest` holds `NearbyRankTests` and `NearbySearchTests`; `travel/TripTimeline.kt`: `TripTimelineTest`). **Android 0.10.0:** the view is built (`ui/screens/NearbyScreen.kt`, `travel/NearbyStore.kt`), with the 0.42.2 fetch design.

From the field report at 23:10 in Veghel ("No bus or train from the stops within 1.6 km in this time" with buses every
half hour and the classic Fastest trip showing a way: "That's not possible") and the requests "Could you add how many
minutes are between my gaps" and "What's up with all the numbers". The field log showed why: 0.42.0 planned every stop
on its own, about 70 `/v5/plan` requests in 3 minutes (12 at once, again on every switch of the time to leave), most
of them timed out in the Transitous queue, two 429s, 150–210 KB each. Rules in `ios/App/NearbyRank.swift` (tests
`NearbyRankTests`, `NearbySearchTests`) and `ios/App/TripTimeline.swift` (tests `TripTimelineTests`); the iOS wiring in
`ios/App/NearbyStore.swift`, `NearbyViews.swift`, `NearbyDetail.swift`, `Transit.planPage`.

- [x] **One plan per search, from where you are.** `/v5/plan` from your coordinate to the destination (its stop, or its
      spot when it has several), `numItineraries` 8, `maxItineraries` 12, `searchWindow` 3600, `maxTransfers` 3, `maxPreTransitTime` = the
      walk to 1.6 km (straight × 1.3 at 1.2 m/s, minutes up: 1740 s; at most 2700 s), `detailedTransfers=false`, your
      walking speed once learned. The planner walks to every stop around by itself. Each itinerary goes with the stop its
      first ride leaves from (`Nearby.groupIndex`: one of the stops around with its id, else a bus stop of its name
      within 300 m, else the nearest within 120 m, a station 400 m); a stop that's none of them is added with its own
      circle (`Nearby.newGroup`; a name already taken gets `@<id>`). Its walk is the planner's own walk from your spot. **Android 0.10.0:** `NearbyStore.search` (`Transit.planPage`); the planner's own walk; Android's destination is the place's `planId`.
- [x] **A second plan only when needed** (`Nearby.nextPlan`, two per search at most): fewer than 3 stops have a way and
      there's a `nextPageCursor` (the next page, `maxPreTransitTime` for 3 km, so 2700 s), or the first got no answer
      (asked once more, the same wider walk, no cursor). Never while Transitous asks to slow down (after a 429). **Android 0.10.0:** `NearbyStore.search`/`more` with `Nearby.nextPlan`; `Transit.cooling` stops it.
- [x] **The stops around** (`/v1/map/stops`, 1 km, kept 10 min) are only drawn (8 at most, as 0.42.0); the ones with no
      way from the plan are grey dots. **Tap one**: its own plan (from its first id, at when you can be there, 5
      itineraries; one stop at a time), and its next departures (`/v6/stoptimes`, 16, from when you can be there; kept a
      minute) of the same lines and headsigns as its ways, under "Also from here". A failed one: "Couldn’t check this stop
      just now (the planner is busy or didn’t answer)." with Try again. **Android 0.10.0:** `Transit.nearStops` (kept 10 min), `Nearby.groups`; grey dots; a tap plans that stop and asks its board (`NearbyStore.stop`, kept a minute; "Try again" when it failed).
- [x] **At most 2 requests at once from this screen**; nothing re-fired or cancelled by the time switch. **Android 0.10.0:** its own `Semaphore(2)`, all in `Polite`'s background lane.
- [x] **Leave now / In 10 / In 20 filter what's in** (no new plan); one second after the last switch, the next page only
      when fewer than 3 stops have a ranked way for that time and the search has a plan left. Asked again after 5
      minutes on screen (what's shown stays), or when you moved 250 m or the destination changed. **Android 0.10.0:** chips filter locally; `NearbyStore.more` a second after the last switch; asked again after 5 min or 250 m.
- [x] **The window** (`Nearby.shown`): a way counts when you leave your door at or after the time you set off (its
      departure less your walk, counted once; 30 s grace), with no upper bound: every way leaving your door within 35
      minutes, and at least the next 2 of a stop however late (tonight's last, or tomorrow's first). **Ranked** (tags,
      colours, the legend) only when it leaves your door within those 35 minutes, waits at most 90 minutes anywhere (before
      the first ride or at a change) and is there within 3 hours of setting off (`Nearby.ranked`); the others are drawn
      grey, tagged "later", with their day ("tomorrow", a weekday; nil today and the night after until 04:00). **Android 0.10.0:** `Nearby.shown`/`ranked`/`best` on `NearbyStore.dep` (door = the trip's start); later ones grey with their day.
- [x] **Fastest trip's own ways are always in**, with their stop, in every window; nothing for that time: its stop is
      shown with its way from now ("Nothing found yet for that time: this is your trip’s way…"). **Android 0.10.0:** the PlanScreen's own trips are the seed; the status line says so.
- [x] **What the screen says** (`Nearby.statusLine`): "No bus or train from the stops within 1.6 km in this time…" only
      when the planner answered and your trip has no way either; no answer: "Couldn’t check the stops around you just now
      (no answer in time / the planner is busy). Your trip has the fastest way."; some in: "Couldn’t check every stop
      just now (…): these are the ones in."; stops tapped that failed: "Couldn’t check N stops just now (…). Tap one to try
      again." **Android 0.10.0:** `Nearby.statusLine` under the map ("1.6 km").
- [x] **Surest only at 70 % on time or more** (`Nearby.surestAt`), on the list and in a stop's sheet; else no Surest. **Android 0.10.0:** `Nearby.tags`/`surestOf`; how sure on Android: your own rides from the travel log (≥ 4), else a rough model (live delay at the end, rush hours, room at each change). No `DelayBook`/`Steady` on Android yet.
- [x] **Overnight ways apart.** In a stop's sheet the late ones (as above) get their own group, "Tomorrow morning" (there
      tomorrow before noon) or "Later · Sat", on their own time axis; never Fastest or Surest. **Android 0.10.0:** `Nearby.split`/`laterTitle` in the stop sheet, on Times and Whole trip.
- [x] **Circles that would overlap are one** (`Nearby.merge`): closer than 40 pt at the map's zoom, the earliest there
      is drawn (at its own place) with "+N"; grey dots under a circle are left out. **Android 0.10.0:** `Nearby.merge` at the map's zoom (40 dp in metres), "+N" on the circle's bitmap.
- [x] **Whole trip rows** (`TripTimeline`): the time axis ticks every 10/15/30 min, 1/2/3/6 h, the smallest step with
      labels 56 pt apart, the start and end always, none closer (`tickStep`, `ticks(width:)`). Each row's leave and arrive
      times always, moved apart around the row's middle when the row is short (`ends`, 40 pt a time, 6 pt between). Every
      gap labelled with its minutes (`gapLabels`): the walk to the first stop "🚶 2" (with a wait: "🚶2 + 1 wait"), each
      change "6 min" or "🚶3 + 5 wait", the last walk "🚶 4"; centred on the gap when it fits (6 + 6.5 pt a character,
      14 the walker, 4 pt spare), else under the bar with a tick, in the first of two rows where it overlaps nothing (left
      out when neither has room). A change under 3 min red, under your learned change time yellow. Each ride's own
      minutes inside its bar ("41 min") when they fit (8 pt spare). **Android 0.10.0:** `TripTimeline` rows drawn with Compose (ticks, ends, gap labels with tones, ride minutes); gold = fastest, green = surest, tap selects.
- [x] **Field log** (`.net`): one line per search, see [logs-export.md](logs-export.md) › Fastest trip, zoomed out
      (0.42.2). **Android 0.10.0:** `nearby · …` and `nearby stop · …` lines (`Nearby.logLine`/`stopLogLine`) in the net log.

## iOS 0.42.1

From the request "Make it so you can stop the alarm without unlocking my phone". Rules in `ios/App/AlarmStop.swift`
(tests `AlarmStopTests`); the iOS wiring in `ios/App/AlarmResponder.swift`.

Android 0.7.0 has a start of it: `AlarmStop` ported (its tests in `WristNoticeTest`), Stop alarm on the alarm, its
repeat, arriving, the ongoing ride notification while it rings and the school wake-up as a broadcast (`StopReceiver`,
no unlocking, no app), and the alarm and wake-up titles public on the lock screen. The rest (heads-up, a stop with no
trip engine handing its answers on, the adaptive wake-up's "answered") comes with 0.8.0.

- [x] **Stop alarm works on the lock screen, never asks to unlock and never opens the app.** For the trip alarm, its
      repeat, the heads-up, arriving and the backup notification, and the school wake-up's notification fallback.
      Android: the ringing alarm as a full-screen-intent notification (`USE_FULL_SCREEN_INTENT`, `setFullScreenIntent`,
      `CATEGORY_ALARM`, shown over the lock screen with `setShowWhenLocked`/`setTurnScreenOn` on its activity) with a
      **Stop alarm** action whose `PendingIntent` goes to a `BroadcastReceiver` (not an activity, so the keyguard isn't
      asked for: no `requestDismissKeyguard`), and the same action on the ongoing ride notification while it rings
      (iOS: the Live Activity's big Stop alarm button; the Dynamic Island shows a bell while it rings). **Android 0.7.0–0.8.0:** the alarm (full-screen intent, `CATEGORY_ALARM`, `AlarmActivity` with `setShowWhenLocked`/`setTurnScreenOn`), its repeat, arriving, the ongoing ride notification while it rings and the school wake-up: Stop alarm is a broadcast to `StopReceiver`. Android has no heads-up variant of the alarm.
- [x] **A stop from the lock screen is the same as Stop in the app**: the sound, the buzz, the out-loud-after-60-s of
      "Sound only with headphones", the 30 s repeat; the ring counts as answered for the adaptive wake-up (when you
      stopped it); with "Ring at the stop" the leg goes to awake (and rings again at the stop), else the leg is done;
      the backup was already off since the ring. Still on? and the backup behave as after an in-app stop. **Android 0.8.0:** the receiver hands it to the ride (`ACTION_STOP_ALARM`), so the adaptive wake-up counts it too.
- [x] **What each answer stops** (`AlarmStop.plan`): a school wake-up notification (`wake-<day>-<n>`) takes that day's
      three away (pending and shown) whatever you did with it; its Stop alarm also stops a real alarm still ringing.
      Stop alarm on any trip notification stops the trip alarm; tapping or swiping away the ringing alarm's own
      notification (or its repeat) does too. Anything else (Still on?, which train, a friend's message) goes to the trip
      engine as before. **Android 0.7.0:** `AlarmStop.plan` (tests in `WristNoticeTest`).
- [x] **Works when the app wasn't running**: the receiver must not need the trip engine. With no trip engine nothing
      rings (it plays the sound), so it only takes the alarm's notifications off the lock screen (`alarm`,
      `alarm-again`, `backup`, `heads-up-true/false` shown; the backup still to come stays) and makes the ride
      notification stop saying it rings; answers meant for the trip engine are kept and handed to it when it starts. **Android 0.7.0:** with no ride running the receiver only takes the alarm's notifications off.
- [x] The alarm and wake-up notifications show their title on the lock screen even with previews hidden
      (Android: `VISIBILITY_PUBLIC` for these, or a public version with the title). **Android 0.7.0:** `VISIBILITY_PUBLIC` and a public version with the title.
- [x] Not done on purpose: stopping with a volume or power button (iOS has no public way; on Android it's possible but
      keep it the same: Stop alarm only). (Android keeps A1's volume key on the full-screen alarm screen itself.)

## iOS 0.42.0

From the field report ("At a friend's place going home to Centrum it showed one bus, unclear what other routes would come
out at about the same time"). Fastest trip, zoomed out (concept N5, with N4's whole-trip timelines). Rules in
`ios/App/NearbyRank.swift` (tests `NearbyRankTests`) and `ios/App/TripTimeline.swift` (tests `TripTimelineTests`).

- [x] **Fastest trip opens on the stops around you.** Not on board, not a planned (Be there by / class) trip, not the demo:
      a map of every bus stop and train station you could walk to, each planned to the destination. Candidate stops from
      Transitous `/v1/map/stops` in a square of 1 km (then 1.6, 2.2, 3 km while fewer than 3 stops have a way); one entry
      per station (`parentId`); same-name stops within 300 m are one stop (both sides of the road, up to 2 ids); at most 8
      stops and 12 plans per step, 12 stops and 20 plans in all; the 2 nearest stations always among them. Each stop
      planned (`/v5/plan`, from its id, to the destination's stop, or its spot when it has several; 5 itineraries, at
      most 3 transfers) from when you can be there; drawn as each answer comes in; Fastest trip's own trips are put
      with their stops too. Every request through the normal Transitous limiter (a few at a time, pause on 429). The
      whole answer is kept 1 minute per place (~200 m), destination and leave time; asked again after 3 minutes on screen. **Android 0.10.0:** `ui/screens/NearbyScreen.kt` `NearbyView`, opened first in Fastest trip (PlanScreen) when no ride runs; the 0.42.2 fetch design above (one plan from you), not the 0.42.0 per-stop plans. Android has no demo or planned (Be there by) Fastest trip.
- [x] **Walk**: straight line × 1.3 at 1.2 m/s, whole minutes up (`Nearby.plannedWalk`), shown at your learned speed
      with 2 min spare (`WalkPlan`, as 0.40). A departure counts when you make it setting off at the window start
      (30 s grace) and it leaves within 35 minutes after that (plus the walk). **Android 0.10.0:** the planner's own walk; `Nearby.plannedWalk` for stops without a way.
- [x] **Leave now / In 10 min / In 20 min** switch (the window's start), re-planned. **Android 0.10.0:** filters what's in (0.42.2), no new plan.
- [x] **Circles**: colour by the stop's earliest arrival you make: green `#3DD598` → `#C9D45A` → `#E8A33D` → red `#E86F5A`,
      between the earliest and latest (at least 8 min apart), minutes inside; legend "arrive 18:44 … 18:58". **Ring** =
      how sure: solid at ≥ 85 % on time, dashed under, thin grey when it only goes by the time of day. Map framed on
      you and the stops with a way (×1.4, at least 600 m). **Android 0.10.0:** bitmaps per circle (fill, minutes to arrival, ring solid / dashed / thin grey), the legend's gradient; framed by `Nearby.frame`.
- [x] **How sure** (`Nearby.sure`): on time = less than 3 min late at the destination. Your own rides on the trip's last
      line to its last stop (the app's delay book from your rides; ≥ 4 rides, the last 20): the share on time, "usually
      +N min" (median, when ≥ 1); else the model's chance (time of day, the line's live delays now and what was seen):
      "on time about NN% (by live times)" or "(by the time of day)"; either times the chance of making each change.
      Clamped to 1–99 %. **Android 0.10.0:** see Surest above (own rides from the travel log, else a rough model).
- [x] **Tags**: Fastest = earliest arrival (tie: shorter walk, then later departure); Surest = highest on-time % (tie:
      earlier arrival), the fastest itself when it's as sure; Slower = 5 min or more after the fastest. List order:
      fastest, surest, then by arrival. Row: stop, walk, line chips, leaves, big arrival, on time NN%. **Android 0.10.0:** `Nearby.tags`, `Nearby.ordered` for the list.
- [x] **A stop tapped**: a half sheet (the map above still usable): walk, tag, "Arrive X: on time NN% of your last N
      rides · usually +1 min" (only what's backed; else "by live times"); Times (next 6 departures you make: line, time,
      live / +N / timetable / cancelled, arrive) or **Whole trip**: each departure as a timeline on one shared axis
      (start rounded down, end up to 5 min, at least 20 min; ticks every 10 / 15 / 30 min): walk (dotted), wait (thin),
      rides in their line colour (bright live, faint timetable), change stations under it (left out when closer than
      0.16 of the axis to the one before or to the trip's end times), leave and arrive times at its ends; gold border =
      fastest, green = surest; tap selects. **On the line now**: the next 3 vehicles of those departures with their own
      GPS age ("GPS 20 s"), "in 9 min · 4 stops" (stops to go by the fix on its road; dropped once past your stop),
      drawn on the map with the first one's road. **Go · leave in N min** makes it your trip (as From <stop>). **Android 0.10.0:** the sheet below the map (the map stays usable): Times / Whole trip, "On the line now" (OVapi / NS fixes, drawn on the map; stops to go not counted on Android), "Also from here" (`/v6/stoptimes` of its lines), "Go · leave in N min" (the way first and chosen in Fastest trip's cards) and Walk there.
- [x] "Your trip" (top right) or "Your trip and other times" shows Fastest trip's cards as before; "All stops around
      you" on them goes back. **Android 0.10.0:** "Your trip and other times" / "All stops around you".

## iOS 0.41.0

From the user ("When you're walking towards the station, like in Google Maps, have the arrow: turn right here, turn left
here … instead of just the text and the button to Google Maps (keep the button)"). Walking turn by turn to the stop or
platform. Rules in `ios/App/WalkGuide.swift` (tests `WalkGuideTests`); the map, GPS, buzzes and voice in
`ios/App/WalkGuideView.swift`.

- [x] **Walk with arrows.** The walk sheet ("Walk there" on the Go to card, at a change, from the boards) has a "Walk with
      arrows" button above the Apple Maps one (which stays). It opens a full-screen map that follows you (heading up,
      or north up with a toggle), the route drawn with the walked part dimmed, and a big card on top: the arrow and
      "In 40 m · turn right onto Hoogstraat", the turn after it small. Below: "4 min · 320 m to go" and, with a ride to
      catch, "Your bus leaves in 6 min · you’ll make it" / "walk a bit faster" / "hurry, it’s tight" (your own walking
      speed once learned, else 1.2 m/s; fine with a minute spare, faster when 25 % quicker makes it). **Android 0.9.0:** `travel/WalkGuide.kt` ported with every iOS vector (`WalkGuideTest`), plus OSRM's maneuver type/modifier as the arrow (`Turn.of`, the shape rule as the fallback). The screen, the OSRM foot route fetch, buzzes and voice are not built yet. **Android 0.10.0:** `ui/screens/WalkScreen.kt` (`WalkThere`: "Walk with arrows" above "Open in maps", on Fastest trip's chosen card, at a change on the ride screen, in a nearby stop's sheet), full screen over the app (`WalkNav`); heading up / north up and voice toggles remembered.
- [x] **The route and its arrows.** Apple's walking directions (MapKit `MKDirections`, free) give steps with words (in
      the phone's language), a length and a shape, but no turn type. The arrow comes from the shape: the direction over
      the 12 m into a step's start against the 12 m out of it: under 20° straight, under 45° slight, under 120° a turn,
      under 165° sharp, else a U-turn; a straight shape whose words say left or right is a slight turn that way. Steps
      without words join their neighbour; the first is the start, the last the stop (one is added when the last turns).
      **Android has no MapKit:** use OSM-based foot routing instead, to decide later: the public OSRM `foot` profile
      (its steps carry a maneuver type and modifier, so the arrow can come from those, the shape rule as a fallback;
      the public demo server is for light use only), Valhalla (pedestrian costing, e.g. a hosted instance), or the
      GraphHopper free tier (key needed, a daily quota). Google's Directions API is paid. **Android 0.10.0:** OSRM's public foot profile (`travel/WalkRoute.kt`: routing.openstreetmap.de, steps with maneuvers → `WalkGuide.Turn.of`, words built from the maneuver and street name in English), asked at most every 20 s, kept per place, only the two coordinates sent.
- [x] **Following it.** GPS at best accuracy (3 m filter) only while the screen is in front; off in the background and
      when it closes. Each fix (accuracy 65 m or better) is placed on the route (the pass nearest to the last place, so
      a route that doubles back doesn't jump); the step moves on within 15 m of its turn or once past it, never back,
      and not while off the route. A buzz at 30 m before a turn (not on steps under 40 m), two strong ones at the turn.
      More than 40 m off for 10 s: a new route from where you are, at most every 20 s. Within 25 m of the stop: "You’re
      here · Platform 4", a success buzz, and after 2.5 s it closes back to the Go to card (which then says you're here). **Android 0.10.0:** `LocationManager` GPS + network (1 s, 3 m) only while the screen is started; `WalkGuide.locate`/`warn`/`offRoute`/`arrived`; buzzes by `Vibrator`; "You’re here · Platform 4" then it closes (the Go to card doesn't say you're there on Android).
- [x] **Spoken turns** only with headphones in (the alarm's headphones rule), on its own audio session (never the trip's),
      not while the alarm rings, with a speaker toggle (remembered). "In 30 metres, turn right onto Hoogstraat". **Android 0.10.0:** Android `TextToSpeech` of its own, only with headphones in (`AudioRoute.privateOutput`), never while the trip alarm or the school wake-up rings, speaker toggle remembered.
- [ ] **Lock screen.** During a trip (walking at a change) the Live Activity's change line shows the next turn
      ("→ 40 m · Hoogstraat", the stop's platform for the last one) after a "you'll miss it" line; a new optional
      `walkTurn` in the state (an older state still decodes). Sent per turn (at the new step and at the 30 m buzz), not
      per metre. Android: the same line in the ongoing trip notification.
- [ ] The battery log has a new GPS reason "walking with arrows". **Android 0.10.0:** no battery log on Android; the field log says `walk · with arrows to … · gps on (walking with arrows)` and `walk · closed · gps off`. The lock-screen turn line (above) is not built yet.

## iOS 0.40.3

From the field report ("The buses and trains on the map aren't usually using their GPS locations, while waiting or
travelling … it's nicer when you see the bus actually arrive and it's actually there, even if it lags a little, than a
simulated bus that 'should arrive right now at my station' but isn't there yet"; a screenshot of Fastest trip's map at
Breda platform 4 with the IC 19:38 "in 9 min" drawn at the station). Causes: 0.40.1's fusion counted a fix 1 up to 20 s
old but 0.15 at 120 s while OVapi's fixes are mostly 25–90 s old (median about 60 s), so the bus was drawn about half by
its times, its "GPS" part itself moved on by age × speed, and it rolled on to 35 m before your stop while stuck in
traffic; the home map never asked for NS's train positions (and its next-trip pieces start at your stop, so a fix
before it was off the road known and the train was drawn by its times at your station); Fastest trip's stop pin
("IC · 19:38" with a train icon) looked like the train itself. Rules in `ios/App/RealFirst.swift` (tests
`RealFirstTests`); `BusFusion` is kept as the ghost. Log line in [logs-export.md](logs-export.md) › The vehicle you wait
for or ride on the map (0.40.3).

- [x] **Real GPS first** for the bus or train you wait for (Fastest trip's map, the live sheet, the home map's next-trip
      vehicle) or ride, in metres along its road:
      - at its **last fix itself**, put on its road when within 60 m of it (else at the fix's own place); fixes up to
        180 s old; label "· GPS 40 s" (its age; "2 min" from 100 s);
      - **moved on** only while its last two fixes (or the feed's own speed) had it going ≥ 2 m/s and the feed doesn't
        say it stands at a stop: at most 20 s × that speed (≤ 30 m/s), never past the next stop it must stop at (a
        train: every stop; a bus: a timing point, your stop, its last), never within 35 m of your stop while its fix
        is further than that; no pull from its times;
      - a new fix **glides** from where it was drawn to its new place over 2 s (smoothstep), forward or back; moves of
        ≤ 25 m between steps are drawn as they are; no step for 20 s: drawn at once;
      - the **estimate** (0.40.1's fused place, unchanged) is a small hollow translucent dot without a label, only when
        it's more than 150 m further on than the vehicle; never closer than 100 m to your stop unless it's due there
        within 30 s; none once the vehicle is past your stop;
      - **"Arriving"** (within 80 m before your stop), **"Waiting · leaves 17:42"** (within 35 m, leaving more than
        60 s from now) and **"It's at your stop"** only by a fix ≤ 90 s old; drawn at the stop then. Without it the
        sheet says "Your stop is next · 300 m";
      - a fix off the road known: drawn at the fix when it's no further from your stop than 40 m/s × the time to its
        live time there + 3 km; else not this journey;
      - **no usable GPS**: by its times (0.40.1's `byTimes`) along its road before your stop, labelled "· by times",
        60 % opacity, not closer than 35 m to your stop before its live departure there; its stops starting at your
        stop and not left there yet (the road before it not known, or its trip starts there): not drawn, "No live
        position" under the stop pin;
      - the home map's next-trip vehicle by its **whole trip** (`/trip` every 30 s), not only the map's pieces of it;
      - **NS positions** asked for wherever a train you wait for or ride is drawn (Fastest trip, the live sheet, the home
        map while the next trip's first ride or the ride is a train), matched by train number;
      - **on board**: the vehicle is drawn where your phone is (fix ≤ 30 s old, ±100 m), also in its live sheet. **Android 0.8.1:** `live/RealFirst.kt` (`RealFirstTest`, every iOS vector) and `live/WaitVehicle.kt` (the glue): the home map's next-trip bus or train by its whole trip (`/v5/trip` every 30 s), OVapi by trip, NS by train number, placed and glided every second, "GPS 40 s" / "by times" (60 %) under it, the ghost a small hollow dot, "Arriving" / "Waiting · leaves …" / "It’s at your stop" on the next-trip card, "No live position" under the stop pin; on board (the ride's vehicle known) drawn where your phone is; `vehicle shown · …` in the log once a minute. Android's Fastest trip has no map of its own and there is no live sheet: the home map is where it's drawn.
- [x] Fastest trip's stop pin is a stop, not a vehicle: a person-waiting icon, light pill with the line's colour as text
      and border ("IC · 19:38"). **Android 0.8.1:** the stop pin on the home map (your next trip's stop): a light pill with a person drawn in the line's colour, "IC · 19:38".
- [x] Settings › Map › **Bus position**: Real GPS (default) / Estimated (0.40.1's fused place, no ghost).
      The on-board matcher keeps its raw GPS (unchanged). Vectors in `ios/Tests/RealFirstTests.swift`. **Android 0.8.1:** `Settings.busPosition` ("real"/"estimated"), Settings › Map & home › Bus position, searchable.
## iOS 0.40.2

From the field report ("The Friends tab pops up a new map, which is annoying, and you can't swipe to leave"; "It's hard
to get out of the calendar screen, you can't swipe"). UI only, no new rules.

- [x] **Friends over the home map, not a second map.** iOS 0.31 opened Friends as a full-height sheet holding a map of its
      own with a hand-made pull-up panel (and a friend's page as another map with another panel): a swipe down moved
      that map instead of closing it. Now (as search since 0.40.0) Friends is a sheet over the home map: half the screen
      first, the map above it usable; pulled up, full height; swiped down (or Done), closed. While it's open the home map
      draws the friends' faces (ringed in their vehicle's colour, faded when stale), their routes, and with a friend's
      page open just that friend with where they got on (dot) and get off (flag); it's framed on them in the half the
      sheet leaves free and goes back where it was when Friends closes. A face tapped on the map opens their page in
      the sheet. The home's own buttons and cards hide while it's open (one sheet at a time); a stop or vehicle tap on
      the map does nothing then. Chats and the list's pages open full height; a friend's page stays half. Opened from
      Settings (away from the home map): the same sheet full height, and a friend's page heads with a small map of their
      trip. Android: Friends as a bottom sheet (half, expanded) over the home map with the same pins; system back (and
      the predictive back gesture) closes it and steps back through its pages. **Android 0.8.1:** Friends is a sheet over the home map (`MapSheet` half / full, swiped down or Done to close): the home map draws the faces, their routes, and on a friend's page that friend with where they got on and get off (`FriendsOverMap`), framed above the sheet and back where it was when it closes; a face tapped on the map opens their page; the home's buttons and cards hide meanwhile; other pages (chats, groups, compare…) open full height over it; from Settings it opens full height. System back steps back through its pages, then closes it.
- [x] **Your week is a sheet.** It was drawn over the map (both home styles) with only a small map button to leave. Now a
      full-height sheet with the grabber, swiped down or its × to close (like Your day). Android: Your week as a sheet or
      a screen that system back closes. **Android 0.8.0:** a screen system back closes (as all screens over the home).
- [x] **The one-time questions** ("Show friends your trips?", "Compare timetables with friends?") can be swiped away or
      left with "Not now" (top left) until answered; not answered stays off and is asked again the next time Friends
      opens (once per opening). Android: system back on them = "Not now". **Android 0.8.1:** "Not now" (and back, which closes Friends) leaves them unanswered: off, asked again the next time Friends opens.
- [x] Android sweep: every screen that opens over another (Friends and its pages, Your week, Your day, the school
      calendar picker, Your week in Settings, Compare and a day of it, the consent screens) handles system back /
      predictive back and has a visible close or back control; only the first-run setup and the backup code just made
      hold back. **Android 0.8.0:** a root back handler on every screen over the home (the screens' own first), `enableOnBackInvokedCallback` for the predictive gesture.

## iOS 0.40.1

From the field report of 26 November ("Where the bus was on the map wasn't matching the actual position until about the
end. It teleported when the time changed"): 0.40.0's `WaitMarker` moved a bus drawn within 150 m of your stop to where
its times put it while its time there was more than 2 min off, so it jumped with every new live time. Replaced by one
fused position (`ios/App/BusFusion.swift`, tests `BusFusionTests` and `WaitMarkerTests`). Log line in
[logs-export.md](logs-export.md) › The bus you wait for on the map (0.40.1).

- [x] The bus you wait for (Fastest trip's map, the live sheet, the home map's next-trip bus): in metres along its road,
      - **by its GPS**: its last fix on the road (not moved on), moved on by now − fix time (at most 180 s) at the speed
        seen between its last two fixes (no less than half, no more than 1.5× the timetable's speed of the piece it's
        on; the timetable's when not known); a fix within 35 m of a stop, not moving (< 1.5 m/s), before its live
        departure there: it stays until then; reaching a timing point (its first stop, or the timetable has it stand
        there ≥ 30 s) before its departure: it waits there;
      - **by its times**: standing at a stop until its live departure; else on the piece to the next stop, the seconds
        left to its live arrival there × the timetable's speed of that piece (≥ 30 s a piece, 2–30 m/s), clamped to that
        piece;
      - **weights**: GPS 1 up to 20 s old, down to 0.15 at 120 s, 0.05 at 180 s; times 0.6 × (1, down to 0.5 for live
        times 4 min old) × (1 up to 2 min from your stop, down to 0.5 at 15 min); weighted mean;
      - **kept between** its fix and its times' place when its fix is behind; its fix more than 50 m further on than its
        times: its fresh (≤ 90 s) GPS (old: the mean, not behind its fix); GPS more than 1 km behind its times and fresh:
        its GPS; no GPS: its times; no live times: its GPS;
      - **not this journey's fix** (not used): before its trip starts (by its live departure at its first stop, a
        minute's slack), more than 150 m past its first stop; or more than max(1 km, 120 s × the timetable's speed there)
        further on than its live times have it;
      - not drawn before its trip starts when your stop is its first and no fix; not at your stop by moving it on (its
        fix more than 35 m short of your stop: at most 35 m short); not past your stop until 2 min after it left there;
      - **"Waiting · leaves 17:42"**: its own fix ≤ 90 s old within 35 m of your stop, leaving there (the card's time)
        more than 60 s from now: drawn at the stop with the label;
      - **drawn without jumps**: forward only, each step (1 s; the home map 2 s) closing 1 − e^(−dt/2) of the gap but at
        least the timetable's speed × dt, at most max(25 m/s, 1.5 × that speed) × dt (a step counts 5 s at most); back
        only when a new fix ≤ 60 s old puts it more than 150 m behind what's drawn: a straight glide there over 3 s; no
        step for 20 s: drawn where it is; on the map each step animates linearly over 1 s;
      - GPS and times more than 200 m apart: the road between them drawn faintly (wider, 25–30 % of the line's colour).
      The on-board matcher keeps the raw GPS. Vectors in `ios/Tests/BusFusionTests.swift` and `WaitMarkerTests.swift`. **Android 0.8.1:** `live/BusFusion.kt` (`BusFusionTest`, with the `WaitMarkerTests` vectors): only the ghost and Bus position: Estimated (as iOS 0.40.3).
## iOS 0.40.0

- [x] "From <stop>" in a trip's detail (`FromStop`, Fastest trip under the big card; folded away as "Buses from
      Bolkenplein ▾" in the home's next-trip card): the next departures from the stop you get on at (Transitous
      `/v6/stoptimes` for that stop, n 20, every 30 s while shown; a failed answer keeps the last list). Up to 6 of the
      lines that get you there (your trip's first line and the other ways' first lines from the same stop; your own
      ride always among them, tagged "Your trip"), then up to 3 other lines, smaller. Each: line pill, headsign, time,
      "in 4 min" under the hour, "+3" / "live" / "timetable" / "may not run", "Stand B" / "Platform 5". Greyed when you
      can't be at the stop for it (leaves more than 30 s before now + your walk). Tap one that gets you there: the trip
      switches to it (one of the ways already found, else the rest planned from that stop: the planner from the stop to
      the destination at its departure − 1 min, the itinerary whose first ride is that trip, with your walk to the stop
      put in front). It stays your pick like a ride chosen in Plan, but missing from later answers doesn't drop it, only
      leaving or being cancelled. Vectors in `ios/Tests/FromStopTests.swift`. **Android 0.8.0:** `travel/Departures.kt` (`FromStopTest` in `DeparturesTest`); folded on the home's next-trip card ("Buses from … ▾"); **0.8.1:** also under Fastest trip's big card (the first or chosen way).
- [x] Sticky upcoming trips (`StickyTrips`): a failed or empty answer keeps what's still to come (not left 60 s past its
      live departure, not cancelled); a partial answer adds to the list; a whole answer replaces it but keeps the trip
      you're heading for (the one shown first, by its first ride's trip id) until it has left, unless you're on it; a
      trip in both is the new answer's. The card holds that trip once its time to leave is within 5 min: while you can
      still reach its stop (straight-line metres × 1.3 at 1.7 m/s, before its departure + 30 s), or with no position
      known until 2 min past its time to leave (as before); else the first you can still leave for. Also across a
      planning-key change that only changes the start (walking away from home). Vectors in
      `ios/Tests/StickyTripsTests.swift`. **Android 0.8.0:** the home's next trips (`HomeModel.sticky`).
- [ ] (Replaced by 0.40.1's fused position: skip it.) The bus you wait for on the map agrees with its time (`WaitMarker`, Fastest trip's map and the live sheet): drawn
      within 150 m of your stop (or past it) while its time there is more than 2 min off doesn't add up. Then: its own GPS
      fix within 35 m of your stop and your stop is where its trip starts (or its times have it standing there): at the
      stop, labelled "Waiting · leaves 17:42"; else where its times put it when that's more than 150 m before your stop;
      its trip not started and nothing says where it is: not drawn (the stop's pin has the time); else 150 m short of
      the stop. Causes seen: a layover at the terminus that is your stop, GPS of the vehicle's previous journey, and a
      fix moved on too far at its pace. Vectors in `ios/Tests/WaitMarkerTests.swift`.
- [x] The walk at your own speed (`WalkPlan`): once 5 walks are learned (`Habits.walkSpeed`), your walk = the walk's
      metres (the map's walking route, else the planner's minutes × the speed it planned with) / your speed, rounded up,
      never more than the planner's. Shown "6 min walk · leave in 4 min (2 min spare)". The time to leave (and "Time to
      go") moves later by max(0, planner's walk − your walk − 2) minutes only; nothing learned: as before. School and
      planned-trip alarms unchanged. Vectors in `ios/Tests/WalkPlanTests.swift`. **Android 0.8.0:** the home's next-trip card ("Leave …" and the walk line). **Android 0.8.1:** "Time to go" (`TimeToGo`, new on Android): while the home or Fastest trip is open, a minute before you have to leave, once per ride, later by `WalkPlan` once 5 walks are learned (2 min spare).
- [x] Search on the home map: a bottom sheet over the same map (half height, the map still usable behind it, the same
      camera): your places, recent ones, stops found by name (also drawn as pins on the map; tap one), then the ways there
      in the sheet with Go and the route drawn on the map (the map moves only when the route isn't in view, and goes back
      when the search closes). "Another time or more options" opens the full Plan as before. **Android 0.8.1:** `ui/screens/HomeSearch.kt`: the search button on the map opens a half sheet (pull up for full): your places, recent ones (6, on the phone), places and stops found (the stops as pins on the same map; tap one), then the ways there with Go and the chosen one's route drawn on the map (its legs' shapes from the plan; walks dashed), moved only when it isn't in view, back when the search closes. "Another time or more options" opens Plan to that place.
- [x] Ghost departures (`GhostDepartures`, the home's departure cards, "From <stop>", the home's trips and Plan's
      options): the same journey from two sources once (same trip at the same stop, or same line + stop + timetable minute
      + headsign equal or one the start of the other; the live copy kept); cancelled ones hidden; for a line that has live
      data (live elsewhere in the list, or seen live today), one with no live data and no vehicle seen within 15 min of
      leaving is "No live info · may not run" and sorts as if 10 min later (trip options: after the others); past its
      time + 60 s with no sign of it: gone. Vectors in `ios/Tests/GhostDeparturesTests.swift`. **Android 0.8.0:** the home's departures and Plan's options ("may not run").

## iOS 0.39.1

From the field report of 25 November (the 154 to Schijndel taken for the 306 at 's-Hertogenbosch station). Log lines in
[logs-export.md](logs-export.md) › The wrong bus, a miss at the change, the bus at your stop (0.39.1).

- [x] A miss at the change (`MissRule` in `ChangeGuide.swift`): before you're there, as before (live arrival + the room
      the change needs > live departure). At the change: missed only once the next ride's live departure has gone by
      60 s with you not on it, and never while its own GPS (fix ≤ 180 s old) has it at or before the stop (≤ 40 m past
      it along its road). The next ride's time: its own trip answer of the last 3 min (asked every 2 min at the change
      too), else the change's list, else the saved copy, else the plan's. **Android 0.7.0:** `MissRule` and `ChangeGuide` ported and tested (`ride/ChangeGuide.kt`); shown with the change guide from 0.8.0.
- [x] Never start a leg by the planned one's timetable more than 2 min before its live departure, nor 20 min after it
      (`TimetableStart`); meanwhile keep looking for the one you're on. **Android 0.7.0.**
- [x] Choosing: the one shown failing by its own GPS 1000 m (a train 2500 m) or more from you (not off its path, not
      "not sure") while another one fitted by its own GPS this look or in the last 90 s: switch to that one at once
      (`farByGPS`, `gpsRescue`). What the "find another" look's GPS said goes into the choice that follows (a fit 10 s
      ago protects it from "the only one left"). **Android 0.7.0.**
- [x] Wrong bus (`WrongBus`): the ride the leg was planned with is remembered (a switch or replan the app made itself
      keeps it; a pick by hand: no alert). On another line, or the same line to another destination, that doesn't go
      to that leg's stop, and sure (the roads split, or its own GPS has fitted you for 75 s: fits at most 3 min apart,
      the newest at most 2 min old): once a trip a time-sensitive notification `wrongbus-<trip start>` (gone after
      20 min) and a ride-screen card "You’re on the 154 to Schijndel, not your 306" with the best way on from the
      planner: "Get off at Kloosterstraat — 306 back at 17:52" (its next stop) or "Stay on to Schijndel — 306 from
      there at 18:11"; buttons "Pick again" and "Got it". Vectors in `ios/Tests/WrongBusTests.swift`. **Android 0.7.0:** `ride/WrongBus.kt`, `WrongBusTest`; "Pick again" forgets the vehicle and looks again (Android has no "I'm actually on…" list).
- [x] Another line at your stop (`OtherAtStop`): waiting for a bus (before the first leg or at a change), within 150 m
      of the stop and yours leaving within 10 min: the stop's whole board (every line, asked once a minute from 5 min
      ago) and each one's own GPS; another line's bus within 80 m of you (fix ≤ 120 s), leaving within 5 min of now
      and not after yours (+1 min): a card "That’s the 154 to Schijndel — not yours" / "Your 306: 2 min" (closable) and
      once a bus a notification `otherbus-<trip id>` (gone after 10 min). Your own routes: every line of the list is
      yours. "This bus becomes the 306" is not shown: neither Transitous nor OVapi's positions give a reliable
      block/vehicle link to the next trip. **Android 0.7.0:** the planned bus only (Android has no own routes).
- [x] Usual line (`UsualLine.learnsFound`): a ride it found by itself teaches +1 only on the line the leg was planned
      with (nothing planned: any); another line only by your own pick. **Android 0.7.0.**
- [x] The moment you left (`DepartMatch`): "not then" by live times alone needs 180 s off (by its own GPS still 90 s, or
      45 s more than the one that left); two or more of them at the stop by their own GPS around the moment: no
      evidence (no pick, no bonus). **Android 0.7.0.**

## iOS 0.39.0

- [x] Change guidance (`ChangeGuide`): at a change (bus → train, train → train), on the ride screen, at the change and on
      the lock screen (Android: the ongoing trip notification): "Platform 5 → 7" (same platform "Same platform (5)", onto
      a bus "Platform 5 → bus 306", from a bus "To platform 7"), "3 min walk", "4 min to change" (from your live arrival;
      at the change from now). Missed when the room is under what the change needs: the planner's walk, or your own
      learned change time (`Habits.changeMinutes`, at most 2 min over the walk), never under 1 min. Then at once "You’ll
      miss the 08:12 — take the 08:27 from platform 4" (a bus: "… take bus 306 at 08:27"; none found: "You’ll likely miss
      the 08:12"): the first later ride of the next leg with that room for its own walk. One tap "Switch to the 08:27"
      on a planned trip: the rest planned again from the change (the planner from the change's stop to the trip's end,
      the itinerary whose first ride is that one, else one leaving within 60 s of it) and spliced after the current leg.
      Platforms from NS's live track, else Transitous `track`/`scheduledTrack`; the arrival platform from the ride's own
      trip answer at your stop. Vectors in `ios/Tests/ChangeGuideTests.swift`. **Android 0.8.0:** the ride screen's "Your change" card and the ongoing notification's second line with a Switch action; platforms from the planner and the stop's board (NS's live track not yet).
- [x] Adaptive wake-up (`AdaptiveWake`, Settings › Trips & alarm › "Learn when I get up", on by default, with a reset):
      per ring before the stop: seconds ring → Stop alarm (none: still ringing when you got within 450 m of the stop),
      seconds ring → at the stop; spare = lead − reaction. Valid: lead 30 s … 20 min, reaction ≤ lead + 5 min. Per mode
      the newest 10 kept; from 3 rides, the median spare of the newest 5: under 75 s → 1 min earlier, over 225 s → 1 min
      back; bounds 0…3 (train), 0…2 (bus), never later than the setting (it only adds minutes to the time rule; the
      distance rule unchanged). Shows "Learned: wakes you 1 min earlier" (or "… on trains", "Learning: 2 more rides",
      "Learned: as you set it"). Vectors in `ios/Tests/AdaptiveWakeTests.swift`. **Android 0.8.0:** `ride/AdaptiveWake.kt` (`AdaptiveWakeTest`), Settings › Trips & alarm › Learn when I get up.
- [x] Richer lock screen: the trip notification shows the next stop (not yours), the delay at your stop ("3 min
      late", "on time", "2 min early") and the platform you get in at ("Next: Vught · 3 min late · platform 5"), and the
      change line (the miss first). Plus a quiet "Get ready" (`GetReady`, id `ready-<trip start>-<leg>`, no sound, gone
      after 10 min) once the vehicle is at the stop before yours (30 s early counts), only before the alarm rang, when
      your stop is more than the wake minutes + 1 min away and within 15 min. Vectors in `ios/Tests/GetReadyTests.swift`,
      `ios/Tests/LockWordsTests.swift`, `ios/Tests/NoticeExpiryTests.swift`. **Android 0.8.0:** next stop and delay in the ongoing notification, the change line under it, `GetReady` (silent, `ready-…`); not yet the platform you get in at.
- [x] Without signal (`RideCache`): when a trip starts, each planned ride's trip answer (stops with times, scheduled
      times, platforms, the road shape, the line) saved on the phone; again when the vehicle is found and at most every
      2 min after; at most 4 rides, 120 stops and 400 road points each (thinned evenly, ends kept), 160 kB, for that trip
      only, cleared when it ends (and on app start). No answer: the ride's stops, your stop's time, the road for the
      wake time and dead reckoning come from the copy ("No network: going by the stops and times saved on your phone");
      the network back: ask again at once. Vectors in `ios/Tests/RideCacheTests.swift`. **Android 0.8.0:** `ride/RideCache.kt` (`RideCacheTest`), `no_backup/ridecache.json`.

## iOS 0.38.0

- [x] Departure-moment match (`DepartMatch` in `ios/App/PickRules.swift`): the moment you went from standing at a stop
      to moving (the latest run of fixes ≤ 60 m accuracy, all within 25 m or 1.5 × accuracy of its first for 15 s or
      more, then the newest fix 60 m (or 2 × its accuracy) away and at 4 m/s; kept 4 minutes), and per vehicle when it
      left that stop: by its own GPS (its newest or previous fix within 80 m of where you stood from 60 s before the
      moment to 60 s after it: left then, seconds off; its newest fix still there later: it stayed; 300 m away within
      30 s of the moment: elsewhere), else by its live times (a piece of its trip starting within 80 m, the departure
      nearest the moment; timetable-only times say nothing). Left then: ≤ 60 s off. Getting on, the one that alone left
      then gets 30 s off its cost; while choosing, the one that left then while every other one clearly didn't
      (elsewhere, ≥ 90 s off, or 45 s further off than it) settles the choice after 2 looks in a row that it passes,
      unless another one passed by its own GPS 30 s better while it didn't (after "roads parted" and the GPS run).
      Log: `depart · stood 40 s, left 07:42:25 · 305·7821 left then (live 5 s) · 306·7954 not then (gps elsewhere)`,
      `choose · … · left the stop with you`. **Android 0.7.0:** `match/PickRules.kt`, `PickRulesTest`.
- [x] Your usual line (`UsualLine`, stored in the habits book as `lines`, reset with Settings › Trips & alarm ›
      Learned from your rides): one entry per ride, line + bus/train + the planned departure's minute of the day +
      weekend or not, weight +1 for a ride it found by itself that you rode to the leg's end (2 minutes or more), +2 for
      the one you said you're on ("I'm actually on…", "I'm on this one" on the board or the list, the ask card), −1 for
      the one it had when you corrected it (another line); 150 kept. Usual: the line's entries within 20 minutes of now,
      same kind of day, add up to 3 or more and to 70 % of the positive totals of the lines in the running, and only
      one candidate has that line. A tie-breaker only: getting on, it wins when within 15 s of the best (the planned one
      still goes first); while choosing it gets 20 s off its cost while it holds (enters within 15 s of the best, lets go
      beyond 40 s: hysteresis); never when another one passed by its own GPS while it didn't. Settings row "Your usual
      lines": "305 at 07:41 on weekdays" (the two most ridden). **Android 0.7.0:** in `HabitBook.lines`, the Settings row with the others.
- [x] Stop pattern for buses (`BusStops`): while choosing between buses only, the candidates' stops within 300 m of your
      last 4 minutes of fixes; per stop who calls there (a stop within 60 m), who waits there by the timetable (45 s or
      more between arrival and departure), whose road passes within 40 m. What you did: stood (15 s within 25 m or 1.5 ×
      accuracy, within 40 m of it) or went through (from 120 m before to 120 m after, passing within 40 m, every step ≥
      4 m/s, fixes ≤ 15 s apart, accuracy ≤ 50 m). Against a candidate: you stood at a stop its road passes without it
      calling there; you went through a stop where it would wait. (Going through a stop it calls at counts for nothing:
      a bus passes a stop with nobody at it.) Beyond the fewest any candidate has, 2 or more: 20 s each on its cost, 60
      s at most. Log: `choose · bus stop pattern · 305·7821 +40 s (2 against it)`. **Android 0.7.0.**
- [x] Ask sooner (`AskSooner`): two still in the running a minute after you left the stop (the moment as the choice
      began, else choosing time + 20 s; 3 minutes while your usual line breaks the tie), of the same kind, differing in
      line or destination: the ask card at once, buses too: "305 or 306?" ("306 to Uden or 306 to Den Bosch?" for one
      line), buttons "Bus 305" / "Bus 306"; trains as 0.34 ("IC to Breda or IC to Eindhoven?"). The answer is a pick by
      hand, as before. Log: `ask · still tied 62 s after leaving · 305·7821 or 306·7954`. Vectors for all four in
      `ios/Tests/PickRulesTests.swift`. **Android 0.7.0:** the ride screen's card and a notification with two buttons.

## iOS 0.37.1

- [x] Notifications that work on a watch (`WristNotice`; iOS mirrors them to a paired Apple Watch while the phone is
      locked, Wear OS mirrors Android's the same way, so no watch app is needed): the trip alarm, the heads-up, arriving,
      the backup alarm and the school wake-up all high priority (iOS: time sensitive), short with the stop first ("Get
      off at Breda · 2 min", "Get off now at Breda", "You’re at Breda", "Get off at Breda soon"; stop names cut to 22
      characters with "…"), with a **Stop alarm** action that runs on the phone without opening the app (Android: a
      notification action to a BroadcastReceiver; Wear OS shows it) and goes the same way as the app's own stop. While
      the alarm still rings 30 s later, its notification once more ("Still ringing: …", once per ring; a new ring, stop
      or the leg ending cancels it; never for the heads-up). Grouped per trip (`trip-<trip start epoch>`; Android:
      `setGroup`) and the school ones per day; the ringing ones on top. Settings › Trips & alarm: "On an Apple Watch:
      the wake-up taps your wrist; tap Stop alarm there." (Android: "On a Wear OS watch: …"). Vectors in
      `ios/Tests/WristNoticeTests.swift`. **Android 0.7.0:** `ride/WristNotice.kt` (tests `WristNoticeTest`); Stop alarm is a broadcast to `StopReceiver`; groups `trip-<start>` / `wake-<day>`; the repeat `alarm-again` 30 s after it rang.

## Left after Android 0.6.0 (A6)

Android 0.6.0 (version code 7) ported iOS 0.32–0.37 (see [android/plan.md](android/plan.md) › As built A6): every pure
rule below with its tests, and most of it wired in. What's still open:

- [x] Trains on the same track in the ride: `TrainRules` is ported and tested, but Android's ride has A1's simpler
      matcher (no `choose` state machine, no candidates): the rivals look every 2 minutes, the roads-parted look at
      once, the stopping pattern while choosing, the one-time "IC to … or IC to …?" ask (ride screen and a notification
      with two buttons) and the trip following the through train (`stayOn`) need that first. **Done in Android 0.7.0** (`ride/RideChoice.kt`, `match/Choose.kt`: `VehicleMatch.choose` with the iOS `ChooseGPSTests`; the rivals look every 2 min, the stopping pattern, the ask, `stayOn`).
- [x] Dead reckoning by the vehicle's own fresh GPS (moved on at its pace): Android reckons at its pace only. **Done in Android 0.7.0** (its fix on the road, moved on at its speed, ≤ 2 min old).
- [ ] The home map's vehicles moved on at their seen pace (`Advance.place`): only the matcher uses it so far.
- [ ] Habits in the ranking: your change time as the least room in `Risk.miss` and the preferred-stop bonus in
      `Risk.score` (Android has no `Risk` ranking of options yet); the change odds' `missChance` likewise.
- [x] Check-out between train companies: Transitous's `agencyName` isn't parsed on Android, so two trains count as one. **Done in Android 0.7.0** (`Ride.agency`).
- [x] Works: the "Leave 10 min earlier" (a replan for that school day against the usual door-to-door) and the
      stations of planned trips (only the NS stations nearest Home and School are matched). **Android 0.7.0:** the replan and "Leave N min earlier" done; the stations of planned trips still the NS stations nearest Home and School.
- [x] OV-fiets on the ride screen's last train leg and in a station's sheet (shown on the trip's notes only). **Android 0.7.0:** on the ride screen (the trip's notes for what's left); not yet in a station's sheet.
- [x] Student OV and rain on the ride's Go card equivalent (shown on Fastest trip and the home's next-trip card). **Done in Android 0.7.0.**
- [ ] Motion: Android has no Play-Services-free Activity Recognition. The step detector gives "walking" only, so
      "automotive" (sooner looks, the far tier's earlier start) and "stationary" (rough GPS while waiting) stay out.
- [ ] Your year in travel shared as a picture (it's shared as text without places).
- [ ] Settings' search scrolling to the row on its page (it opens the page).
- [ ] The widget's lock-screen sizes (none on Android) and a Glance look.

## iOS 0.37 (done in Android 0.6.0 unless listed above)

- [x] OV-fiets at the station (`OVFiets`, Settings › Map & home, on by default): the relay's `/ns/ovfiets?station=BD`
      (NS Places API, slimmed to `{"station","locations":[{"name","code","bikes","lat","lon","open"}]}`), kept 5 min per
      station; "Breda · OV-fiets: 12 left" (warm at ≤ 5, "· closed now" when every staffed point says `open: "No"`) on
      the Go card for the station where the trip's last train gets in (when a bus or a walk of ≥ 5 min follows it), on
      the ride screen's last train leg and in a station's sheet. Vectors in `ios/Tests/OVFietsTests.swift`.
- [x] Rain advice for the walk (`RainAdvice`, Settings › Map & home, on by default): from 3 h before a trip until 5 min
      after it starts, Open-Meteo's hourly `precipitation` (the hour *before* its time) ≥ 0.5 mm during the walk to the
      first stop (from the trip's start, `walkBefore` min) or from the last one (last arrival → end) at the start or end
      point: "Rain at 08:00 — take bus 305 at 07:41 to the station instead of walking" when the first ride is a train
      with a walk of ≥ 6 min and a bus exists (another way starting with a bus, walk ≤ max(2, min(walk/2, walk − 4)),
      leaving after now + its walk, there by the trip's end + 10 min; else a Transitous bus-only plan to the station
      arriving by the train − 2 min), else "Rain at 08:00 — bring an umbrella"; on the home's next-trip card and the
      Go card. Vectors in `ios/Tests/RainAdviceTests.swift`.
- [x] Home-screen widget (Android: an app widget with its own stop setting, no shared storage needed): small / medium
      (+ lock-screen rectangular / inline on iOS) "next departures from a stop", Transitous `/v6/stoptimes` asked by the
      widget itself; entries just after each departure leaves, refresh every 12 min (sooner when the list runs short,
      at least 5 min apart; 30 min with nothing leaving); "07:41 (+2)", "07:41 cancelled"; tap opens the app on that
      stop (`haltewekker://stop?id=…&name=…&lat=…&lon=…&rail=1`); "Pick a stop" when none is set. Rules in
      `ios/Shared/StopBoardCore.swift`, vectors in `ios/Tests/StopBoardCoreTests.swift`.
- [x] Voice / shortcuts (Android: App Actions or shortcuts): "When's my bus?" (home stop within 600 m of home or with no
      fix, else the nearest stop; spoken "Bus 305 to Uden leaves Veghel at 07:41, 2 minutes late — in 6 minutes. Then
      the 306 at 07:52."), "Wake me at a stop" (opens Wake me at a stop with it, to confirm), "Plan to school / home"
      (Fastest trip), "Start my trip" (I'm on it when the planned ride leaves within 3 min or left in the last 15, else
      Fastest trip for it). Nothing over a running trip. Rules in `ios/App/IntentActions.swift`.

## iOS 0.36 (done in Android 0.6.0 unless listed above)

- [x] Check-out reminder (`CheckOut`, Settings › Trips & alarm, on by default): "Did you check out?" a minute after you
      get off at the end of a trip, off a bus, between bus and train, and between train companies (Transitous's
      `agencyName`); not between two NS trains. Taken back when the next leg finds the vehicle you got off, or (at the
      end) two fixes at ≥ 7 m/s in that minute. No NFC.
- [x] Student travel product (`StudentOV`, Settings › Trips & alarm: none / weekday free / weekend free): DUO's windows
      (days 04:00–04:00; week product free Mon 04:00 – Sat 04:00; weekend product free Fri 12:00 – Mon 04:00, Tue–Fri
      04:00–09:00 full fare; summer 16 Jul – 16 Aug discount for the week product; holidays), 40% off trains, 34% off
      buses; "Free with your student OV" / "Costs money now (weekday) — ~€3.60 with 40% off" on plan options and the Go
      card, the price from the relay's `/ns/price`. Windows in `ios/Tests/StudentOVTests.swift`.
- [x] Money back for a late train (`DelayClaim`, on by default): once per trip, after it, when its trains got you there
      ≥ 30 min late (the planned arrival counts once a train was ≥ 3 min late), with a tap to NS's claim page.
- [x] Works and disruptions on your routes (`RailWorks`, Settings › Notifications): the relay's
      `/ns/disruptions?stations=…` at most every 4 hours, matched to your usual train rides (home ⇄ school, planned
      trips; stations on the way by the straight line ± 2.5 km), today and the next 7 days; the home's card for today or
      tomorrow and a notification at 19:30 the evening before ("Thursday: no trains Tilburg–Breda (works). Leave 10 min
      earlier — buses replace trains"; the minutes from a replan for that school day against the usual door-to-door).
- [x] Last way home (`LastTrip`, Settings › Notifications): after 20:00 and > 3 km from Home, the latest way home (asked
      "arrive by" 04:00, 02:00, 01:00, midnight), refreshed at most hourly or after 1 km, on the home's card and a
      notification 30 min before it leaves.

## iOS 0.35 (done in Android 0.6.0 unless listed above)

- [x] The leaderboard's rule (`ScoreRules.board`): a planned trip between Home and School is scored on the corridor too
      (until iOS 0.34 only fixed routes were, so the board stopped getting trips); a stale start fix falls back to the
      first stop; going on with a trip ended by hand keeps its start; read the saved board entry by entry.
- [x] Today's best and worst trip (`DailyRank`): the `scores` box's optional `today` list, sent within 5 minutes of a new
      trip, and the words; on the Leaderboard and a small card on Friends. Rules and test vectors:
      [friends design › As built (0.35)](superpowers/specs/2026-11-18-friends-design.md).
- [x] Your year in travel (`TravelYear`, Settings › Advanced, and the home's card in December or in the two weeks after
      a year of rides, with ≥ 5 trips, put away per year): keep each ride on the phone (line, stops, km = straight line ×
      1.3 by bus, × 1.15 by train, delay, coach); the last 365 days ("Your travel so far" with less than a year of
      data); trips = kept trips + leaderboard trips from before the first kept ride; CO₂ saved = bus km × (0.19 − 0.05)
      + train km × (0.19 − 0.02) kg; favourite line / stop / coach (≥ 2), earliest start by time of day, longest delay,
      rides with friends; cards and share a card as a picture without stops. Numbers in `ios/Tests/TravelYearTests.swift`.

## iOS 0.34 (done in Android 0.6.0 unless listed above)

- [x] Trains on the same track: the rivals look on a confirmed train (NS positions, every 2 minutes), the roads-parted
      look at once, the stopping pattern while choosing, the one-time "IC to … or IC to …?" ask (ride screen and a
      notification with two buttons), and the trip following the through train (stay on to the last leg's end).
- [x] Old bus GPS moved on at its seen pace (up to 2 minutes), late as it is, with more room for an older fix.
- [x] Following in tunnels and dead zones (dead reckoning every 5 s after 15 s without a good fix; only the time rule
      rings on it).
- [x] Learned from your rides (walking speed to the planner as `pedestrianSpeed`, change time in the ranking, stops you
      prefer), with its settings row and reset.
- [x] How reliable a change is ("this change worked on 9 of 10 days"), on plan options and the Go card, and in the
      ranking.
