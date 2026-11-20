# Android: what iOS has that Android still needs

The rules and numbers for each are in [logs-export.md](logs-export.md) › For Android (parity), with the iOS files and
their tests.

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
