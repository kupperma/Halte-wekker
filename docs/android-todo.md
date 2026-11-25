# Android: what iOS has that Android still needs

The rules and numbers for each are in [logs-export.md](logs-export.md) › For Android (parity), with the iOS files and
their tests.

## iOS 0.40.0

- [ ] "From <stop>" in a trip's detail (`FromStop`, Fastest trip under the big card; folded away as "Buses from
      Bolkenplein ▾" in the home's next-trip card): the next departures from the stop you get on at (Transitous
      `/v6/stoptimes` for that stop, n 20, every 30 s while shown; a failed answer keeps the last list). Up to 6 of the
      lines that get you there (your trip's first line and the other ways' first lines from the same stop; your own
      ride always among them, tagged "Your trip"), then up to 3 other lines, smaller. Each: line pill, headsign, time,
      "in 4 min" under the hour, "+3" / "live" / "timetable" / "may not run", "Stand B" / "Platform 5". Greyed when you
      can't be at the stop for it (leaves more than 30 s before now + your walk). Tap one that gets you there: the trip
      switches to it (one of the ways already found, else the rest planned from that stop: the planner from the stop to
      the destination at its departure − 1 min, the itinerary whose first ride is that trip, with your walk to the stop
      put in front). It stays your pick like a ride chosen in Plan, but missing from later answers doesn't drop it, only
      leaving or being cancelled. Vectors in `ios/Tests/FromStopTests.swift`.
- [ ] Sticky upcoming trips (`StickyTrips`): a failed or empty answer keeps what's still to come (not left 60 s past its
      live departure, not cancelled); a partial answer adds to the list; a whole answer replaces it but keeps the trip
      you're heading for (the one shown first, by its first ride's trip id) until it has left, unless you're on it; a
      trip in both is the new answer's. The card holds that trip once its time to leave is within 5 min: while you can
      still reach its stop (straight-line metres × 1.3 at 1.7 m/s, before its departure + 30 s), or with no position
      known until 2 min past its time to leave (as before); else the first you can still leave for. Also across a
      planning-key change that only changes the start (walking away from home). Vectors in
      `ios/Tests/StickyTripsTests.swift`.
- [ ] The bus you wait for on the map agrees with its time (`WaitMarker`, Fastest trip's map and the live sheet): drawn
      within 150 m of your stop (or past it) while its time there is more than 2 min off doesn't add up. Then: its own GPS
      fix within 35 m of your stop and your stop is where its trip starts (or its times have it standing there): at the
      stop, labelled "Waiting · leaves 17:42"; else where its times put it when that's more than 150 m before your stop;
      its trip not started and nothing says where it is: not drawn (the stop's pin has the time); else 150 m short of
      the stop. Causes seen: a layover at the terminus that is your stop, GPS of the vehicle's previous journey, and a
      fix moved on too far at its pace. Vectors in `ios/Tests/WaitMarkerTests.swift`.
- [ ] The walk at your own speed (`WalkPlan`): once 5 walks are learned (`Habits.walkSpeed`), your walk = the walk's
      metres (the map's walking route, else the planner's minutes × the speed it planned with) / your speed, rounded up,
      never more than the planner's. Shown "6 min walk · leave in 4 min (2 min spare)". The time to leave (and "Time to
      go") moves later by max(0, planner's walk − your walk − 2) minutes only; nothing learned: as before. School and
      planned-trip alarms unchanged. Vectors in `ios/Tests/WalkPlanTests.swift`.
- [ ] Search on the home map: a bottom sheet over the same map (half height, the map still usable behind it, the same
      camera): your places, recent ones, stops found by name (also drawn as pins on the map; tap one), then the ways there
      in the sheet with Go and the route drawn on the map (the map moves only when the route isn't in view, and goes back
      when the search closes). "Another time or more options" opens the full Plan as before.
- [ ] Ghost departures (`GhostDepartures`, the home's departure cards, "From <stop>", the home's trips and Plan's
      options): the same journey from two sources once (same trip at the same stop, or same line + stop + timetable minute
      + headsign equal or one the start of the other; the live copy kept); cancelled ones hidden; for a line that has live
      data (live elsewhere in the list, or seen live today), one with no live data and no vehicle seen within 15 min of
      leaving is "No live info · may not run" and sorts as if 10 min later (trip options: after the others); past its
      time + 60 s with no sign of it: gone. Vectors in `ios/Tests/GhostDeparturesTests.swift`.

## iOS 0.39.1

From the field report of 25 November (the 154 to Schijndel taken for the 306 at 's-Hertogenbosch station). Log lines in
[logs-export.md](logs-export.md) › The wrong bus, a miss at the change, the bus at your stop (0.39.1).

- [ ] A miss at the change (`MissRule` in `ChangeGuide.swift`): before you're there, as before (live arrival + the room
      the change needs > live departure). At the change: missed only once the next ride's live departure has gone by
      60 s with you not on it, and never while its own GPS (fix ≤ 180 s old) has it at or before the stop (≤ 40 m past
      it along its road). The next ride's time: its own trip answer of the last 3 min (asked every 2 min at the change
      too), else the change's list, else the saved copy, else the plan's.
- [ ] Never start a leg by the planned one's timetable more than 2 min before its live departure, nor 20 min after it
      (`TimetableStart`); meanwhile keep looking for the one you're on.
- [ ] Choosing: the one shown failing by its own GPS 1000 m (a train 2500 m) or more from you (not off its path, not
      "not sure") while another one fitted by its own GPS this look or in the last 90 s: switch to that one at once
      (`farByGPS`, `gpsRescue`). What the "find another" look's GPS said goes into the choice that follows (a fit 10 s
      ago protects it from "the only one left").
- [ ] Wrong bus (`WrongBus`): the ride the leg was planned with is remembered (a switch or replan the app made itself
      keeps it; a pick by hand: no alert). On another line, or the same line to another destination, that doesn't go
      to that leg's stop, and sure (the roads split, or its own GPS has fitted you for 75 s: fits at most 3 min apart,
      the newest at most 2 min old): once a trip a time-sensitive notification `wrongbus-<trip start>` (gone after
      20 min) and a ride-screen card "You’re on the 154 to Schijndel, not your 306" with the best way on from the
      planner: "Get off at Kloosterstraat — 306 back at 17:52" (its next stop) or "Stay on to Schijndel — 306 from
      there at 18:11"; buttons "Pick again" and "Got it". Vectors in `ios/Tests/WrongBusTests.swift`.
- [ ] Another line at your stop (`OtherAtStop`): waiting for a bus (before the first leg or at a change), within 150 m
      of the stop and yours leaving within 10 min: the stop's whole board (every line, asked once a minute from 5 min
      ago) and each one's own GPS; another line's bus within 80 m of you (fix ≤ 120 s), leaving within 5 min of now
      and not after yours (+1 min): a card "That’s the 154 to Schijndel — not yours" / "Your 306: 2 min" (closable) and
      once a bus a notification `otherbus-<trip id>` (gone after 10 min). Your own routes: every line of the list is
      yours. "This bus becomes the 306" is not shown: neither Transitous nor OVapi's positions give a reliable
      block/vehicle link to the next trip.
- [ ] Usual line (`UsualLine.learnsFound`): a ride it found by itself teaches +1 only on the line the leg was planned
      with (nothing planned: any); another line only by your own pick.
- [ ] The moment you left (`DepartMatch`): "not then" by live times alone needs 180 s off (by its own GPS still 90 s, or
      45 s more than the one that left); two or more of them at the stop by their own GPS around the moment: no
      evidence (no pick, no bonus).

## iOS 0.39.0

- [ ] Change guidance (`ChangeGuide`): at a change (bus → train, train → train), on the ride screen, at the change and on
      the lock screen (Android: the ongoing trip notification): "Platform 5 → 7" (same platform "Same platform (5)", onto
      a bus "Platform 5 → bus 306", from a bus "To platform 7"), "3 min walk", "4 min to change" (from your live arrival;
      at the change from now). Missed when the room is under what the change needs: the planner's walk, or your own
      learned change time (`Habits.changeMinutes`, at most 2 min over the walk), never under 1 min. Then at once "You’ll
      miss the 08:12 — take the 08:27 from platform 4" (a bus: "… take bus 306 at 08:27"; none found: "You’ll likely miss
      the 08:12"): the first later ride of the next leg with that room for its own walk. One tap "Switch to the 08:27"
      on a planned trip: the rest planned again from the change (the planner from the change's stop to the trip's end,
      the itinerary whose first ride is that one, else one leaving within 60 s of it) and spliced after the current leg.
      Platforms from NS's live track, else Transitous `track`/`scheduledTrack`; the arrival platform from the ride's own
      trip answer at your stop. Vectors in `ios/Tests/ChangeGuideTests.swift`.
- [ ] Adaptive wake-up (`AdaptiveWake`, Settings › Trips & alarm › "Learn when I get up", on by default, with a reset):
      per ring before the stop: seconds ring → Stop alarm (none: still ringing when you got within 450 m of the stop),
      seconds ring → at the stop; spare = lead − reaction. Valid: lead 30 s … 20 min, reaction ≤ lead + 5 min. Per mode
      the newest 10 kept; from 3 rides, the median spare of the newest 5: under 75 s → 1 min earlier, over 225 s → 1 min
      back; bounds 0…3 (train), 0…2 (bus), never later than the setting (it only adds minutes to the time rule; the
      distance rule unchanged). Shows "Learned: wakes you 1 min earlier" (or "… on trains", "Learning: 2 more rides",
      "Learned: as you set it"). Vectors in `ios/Tests/AdaptiveWakeTests.swift`.
- [ ] Richer lock screen: the trip notification shows the next stop (not yours), the delay at your stop ("3 min
      late", "on time", "2 min early") and the platform you get in at ("Next: Vught · 3 min late · platform 5"), and the
      change line (the miss first). Plus a quiet "Get ready" (`GetReady`, id `ready-<trip start>-<leg>`, no sound, gone
      after 10 min) once the vehicle is at the stop before yours (30 s early counts), only before the alarm rang, when
      your stop is more than the wake minutes + 1 min away and within 15 min. Vectors in `ios/Tests/GetReadyTests.swift`,
      `ios/Tests/LockWordsTests.swift`, `ios/Tests/NoticeExpiryTests.swift`.
- [ ] Without signal (`RideCache`): when a trip starts, each planned ride's trip answer (stops with times, scheduled
      times, platforms, the road shape, the line) saved on the phone; again when the vehicle is found and at most every
      2 min after; at most 4 rides, 120 stops and 400 road points each (thinned evenly, ends kept), 160 kB, for that trip
      only, cleared when it ends (and on app start). No answer: the ride's stops, your stop's time, the road for the
      wake time and dead reckoning come from the copy ("No network: going by the stops and times saved on your phone");
      the network back: ask again at once. Vectors in `ios/Tests/RideCacheTests.swift`.

## iOS 0.38.0

- [ ] Departure-moment match (`DepartMatch` in `ios/App/PickRules.swift`): the moment you went from standing at a stop
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
      `choose · … · left the stop with you`.
- [ ] Your usual line (`UsualLine`, stored in the habits book as `lines`, reset with Settings › Trips & alarm ›
      Learned from your rides): one entry per ride, line + bus/train + the planned departure's minute of the day +
      weekend or not, weight +1 for a ride it found by itself that you rode to the leg's end (2 minutes or more), +2 for
      the one you said you're on ("I'm actually on…", "I'm on this one" on the board or the list, the ask card), −1 for
      the one it had when you corrected it (another line); 150 kept. Usual: the line's entries within 20 minutes of now,
      same kind of day, add up to 3 or more and to 70 % of the positive totals of the lines in the running, and only
      one candidate has that line. A tie-breaker only: getting on, it wins when within 15 s of the best (the planned one
      still goes first); while choosing it gets 20 s off its cost while it holds (enters within 15 s of the best, lets go
      beyond 40 s: hysteresis); never when another one passed by its own GPS while it didn't. Settings row "Your usual
      lines": "305 at 07:41 on weekdays" (the two most ridden).
- [ ] Stop pattern for buses (`BusStops`): while choosing between buses only, the candidates' stops within 300 m of your
      last 4 minutes of fixes; per stop who calls there (a stop within 60 m), who waits there by the timetable (45 s or
      more between arrival and departure), whose road passes within 40 m. What you did: stood (15 s within 25 m or 1.5 ×
      accuracy, within 40 m of it) or went through (from 120 m before to 120 m after, passing within 40 m, every step ≥
      4 m/s, fixes ≤ 15 s apart, accuracy ≤ 50 m). Against a candidate: you stood at a stop its road passes without it
      calling there; you went through a stop where it would wait. (Going through a stop it calls at counts for nothing:
      a bus passes a stop with nobody at it.) Beyond the fewest any candidate has, 2 or more: 20 s each on its cost, 60
      s at most. Log: `choose · bus stop pattern · 305·7821 +40 s (2 against it)`.
- [ ] Ask sooner (`AskSooner`): two still in the running a minute after you left the stop (the moment as the choice
      began, else choosing time + 20 s; 3 minutes while your usual line breaks the tie), of the same kind, differing in
      line or destination: the ask card at once, buses too: "305 or 306?" ("306 to Uden or 306 to Den Bosch?" for one
      line), buttons "Bus 305" / "Bus 306"; trains as 0.34 ("IC to Breda or IC to Eindhoven?"). The answer is a pick by
      hand, as before. Log: `ask · still tied 62 s after leaving · 305·7821 or 306·7954`. Vectors for all four in
      `ios/Tests/PickRulesTests.swift`.

## iOS 0.37.1

- [ ] Notifications that work on a watch (`WristNotice`; iOS mirrors them to a paired Apple Watch while the phone is
      locked, Wear OS mirrors Android's the same way, so no watch app is needed): the trip alarm, the heads-up, arriving,
      the backup alarm and the school wake-up all high priority (iOS: time sensitive), short with the stop first ("Get
      off at Breda · 2 min", "Get off now at Breda", "You’re at Breda", "Get off at Breda soon"; stop names cut to 22
      characters with "…"), with a **Stop alarm** action that runs on the phone without opening the app (Android: a
      notification action to a BroadcastReceiver; Wear OS shows it) and goes the same way as the app's own stop. While
      the alarm still rings 30 s later, its notification once more ("Still ringing: …", once per ring; a new ring, stop
      or the leg ending cancels it; never for the heads-up). Grouped per trip (`trip-<trip start epoch>`; Android:
      `setGroup`) and the school ones per day; the ringing ones on top. Settings › Trips & alarm: "On an Apple Watch:
      the wake-up taps your wrist; tap Stop alarm there." (Android: "On a Wear OS watch: …"). Vectors in
      `ios/Tests/WristNoticeTests.swift`.

## Left after Android 0.6.0 (A6)

Android 0.6.0 (version code 7) ported iOS 0.32–0.37 (see [android/plan.md](android/plan.md) › As built A6): every pure
rule below with its tests, and most of it wired in. What's still open:

- [ ] Trains on the same track in the ride: `TrainRules` is ported and tested, but Android's ride has A1's simpler
      matcher (no `choose` state machine, no candidates): the rivals look every 2 minutes, the roads-parted look at
      once, the stopping pattern while choosing, the one-time "IC to … or IC to …?" ask (ride screen and a notification
      with two buttons) and the trip following the through train (`stayOn`) need that first.
- [ ] Dead reckoning by the vehicle's own fresh GPS (moved on at its pace): Android reckons at its pace only.
- [ ] The home map's vehicles moved on at their seen pace (`Advance.place`): only the matcher uses it so far.
- [ ] Habits in the ranking: your change time as the least room in `Risk.miss` and the preferred-stop bonus in
      `Risk.score` (Android has no `Risk` ranking of options yet); the change odds' `missChance` likewise.
- [ ] Check-out between train companies: Transitous's `agencyName` isn't parsed on Android, so two trains count as one.
- [ ] Works: the "Leave 10 min earlier" (a replan for that school day against the usual door-to-door) and the
      stations of planned trips (only the NS stations nearest Home and School are matched).
- [ ] OV-fiets on the ride screen's last train leg and in a station's sheet (shown on the trip's notes only).
- [ ] Student OV and rain on the ride's Go card equivalent (shown on Fastest trip and the home's next-trip card).
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
