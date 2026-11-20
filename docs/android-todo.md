# Android: what iOS has that Android still needs

The rules and numbers for each are in [logs-export.md](logs-export.md) › For Android (parity), with the iOS files and
their tests.

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

## iOS 0.37

- [ ] OV-fiets at the station (`OVFiets`, Settings › Map & home, on by default): the relay's `/ns/ovfiets?station=BD`
      (NS Places API, slimmed to `{"station","locations":[{"name","code","bikes","lat","lon","open"}]}`), kept 5 min per
      station; "Breda · OV-fiets: 12 left" (warm at ≤ 5, "· closed now" when every staffed point says `open: "No"`) on
      the Go card for the station where the trip's last train gets in (when a bus or a walk of ≥ 5 min follows it), on
      the ride screen's last train leg and in a station's sheet. Vectors in `ios/Tests/OVFietsTests.swift`.
- [ ] Rain advice for the walk (`RainAdvice`, Settings › Map & home, on by default): from 3 h before a trip until 5 min
      after it starts, Open-Meteo's hourly `precipitation` (the hour *before* its time) ≥ 0.5 mm during the walk to the
      first stop (from the trip's start, `walkBefore` min) or from the last one (last arrival → end) at the start or end
      point: "Rain at 08:00 — take bus 305 at 07:41 to the station instead of walking" when the first ride is a train
      with a walk of ≥ 6 min and a bus exists (another way starting with a bus, walk ≤ max(2, min(walk/2, walk − 4)),
      leaving after now + its walk, there by the trip's end + 10 min; else a Transitous bus-only plan to the station
      arriving by the train − 2 min), else "Rain at 08:00 — bring an umbrella"; on the home's next-trip card and the
      Go card. Vectors in `ios/Tests/RainAdviceTests.swift`.
- [ ] Home-screen widget (Android: an app widget with its own stop setting, no shared storage needed): small / medium
      (+ lock-screen rectangular / inline on iOS) "next departures from a stop", Transitous `/v6/stoptimes` asked by the
      widget itself; entries just after each departure leaves, refresh every 12 min (sooner when the list runs short,
      at least 5 min apart; 30 min with nothing leaving); "07:41 (+2)", "07:41 cancelled"; tap opens the app on that
      stop (`haltewekker://stop?id=…&name=…&lat=…&lon=…&rail=1`); "Pick a stop" when none is set. Rules in
      `ios/Shared/StopBoardCore.swift`, vectors in `ios/Tests/StopBoardCoreTests.swift`.
- [ ] Voice / shortcuts (Android: App Actions or shortcuts): "When's my bus?" (home stop within 600 m of home or with no
      fix, else the nearest stop; spoken "Bus 305 to Uden leaves Veghel at 07:41, 2 minutes late — in 6 minutes. Then
      the 306 at 07:52."), "Wake me at a stop" (opens Wake me at a stop with it, to confirm), "Plan to school / home"
      (Fastest trip), "Start my trip" (I'm on it when the planned ride leaves within 3 min or left in the last 15, else
      Fastest trip for it). Nothing over a running trip. Rules in `ios/App/IntentActions.swift`.

## iOS 0.36

- [ ] Check-out reminder (`CheckOut`, Settings › Trips & alarm, on by default): "Did you check out?" a minute after you
      get off at the end of a trip, off a bus, between bus and train, and between train companies (Transitous's
      `agencyName`); not between two NS trains. Taken back when the next leg finds the vehicle you got off, or (at the
      end) two fixes at ≥ 7 m/s in that minute. No NFC.
- [ ] Student travel product (`StudentOV`, Settings › Trips & alarm: none / weekday free / weekend free): DUO's windows
      (days 04:00–04:00; week product free Mon 04:00 – Sat 04:00; weekend product free Fri 12:00 – Mon 04:00, Tue–Fri
      04:00–09:00 full fare; summer 16 Jul – 16 Aug discount for the week product; holidays), 40% off trains, 34% off
      buses; "Free with your student OV" / "Costs money now (weekday) — ~€3.60 with 40% off" on plan options and the Go
      card, the price from the relay's `/ns/price`. Windows in `ios/Tests/StudentOVTests.swift`.
- [ ] Money back for a late train (`DelayClaim`, on by default): once per trip, after it, when its trains got you there
      ≥ 30 min late (the planned arrival counts once a train was ≥ 3 min late), with a tap to NS's claim page.
- [ ] Works and disruptions on your routes (`RailWorks`, Settings › Notifications): the relay's
      `/ns/disruptions?stations=…` at most every 4 hours, matched to your usual train rides (home ⇄ school, planned
      trips; stations on the way by the straight line ± 2.5 km), today and the next 7 days; the home's card for today or
      tomorrow and a notification at 19:30 the evening before ("Thursday: no trains Tilburg–Breda (works). Leave 10 min
      earlier — buses replace trains"; the minutes from a replan for that school day against the usual door-to-door).
- [ ] Last way home (`LastTrip`, Settings › Notifications): after 20:00 and > 3 km from Home, the latest way home (asked
      "arrive by" 04:00, 02:00, 01:00, midnight), refreshed at most hourly or after 1 km, on the home's card and a
      notification 30 min before it leaves.

## iOS 0.35

- [ ] The leaderboard's rule (`ScoreRules.board`): a planned trip between Home and School is scored on the corridor too
      (until iOS 0.34 only fixed routes were, so the board stopped getting trips); a stale start fix falls back to the
      first stop; going on with a trip ended by hand keeps its start; read the saved board entry by entry.
- [ ] Today's best and worst trip (`DailyRank`): the `scores` box's optional `today` list, sent within 5 minutes of a new
      trip, and the words; on the Leaderboard and a small card on Friends. Rules and test vectors:
      [friends design › As built (0.35)](superpowers/specs/2026-11-18-friends-design.md).
- [ ] Your year in travel (`TravelYear`, Settings › Advanced, and the home's card in December or in the two weeks after
      a year of rides, with ≥ 5 trips, put away per year): keep each ride on the phone (line, stops, km = straight line ×
      1.3 by bus, × 1.15 by train, delay, coach); the last 365 days ("Your travel so far" with less than a year of
      data); trips = kept trips + leaderboard trips from before the first kept ride; CO₂ saved = bus km × (0.19 − 0.05)
      + train km × (0.19 − 0.02) kg; favourite line / stop / coach (≥ 2), earliest start by time of day, longest delay,
      rides with friends; cards and share a card as a picture without stops. Numbers in `ios/Tests/TravelYearTests.swift`.

## iOS 0.34

- [ ] Trains on the same track: the rivals look on a confirmed train (NS positions, every 2 minutes), the roads-parted
      look at once, the stopping pattern while choosing, the one-time "IC to … or IC to …?" ask (ride screen and a
      notification with two buttons), and the trip following the through train (stay on to the last leg's end).
- [ ] Old bus GPS moved on at its seen pace (up to 2 minutes), late as it is, with more room for an older fix.
- [ ] Following in tunnels and dead zones (dead reckoning every 5 s after 15 s without a good fix; only the time rule
      rings on it).
- [ ] Learned from your rides (walking speed to the planner as `pedestrianSpeed`, change time in the ranking, stops you
      prefer), with its settings row and reset.
- [ ] How reliable a change is ("this change worked on 9 of 10 days"), on plan options and the Go card, and in the
      ranking.
