# Android: what iOS has that Android still needs

The rules and numbers for each are in [logs-export.md](logs-export.md) › For Android (parity), with the iOS files and
their tests.

## iOS 0.42.2

From the field report at 23:10 in Veghel ("No bus or train from the stops within 1.6 km in this time" with buses every
half hour and the classic Fastest trip showing a way: "That's not possible") and the requests "Could you add how many
minutes are between my gaps" and "What's up with all the numbers". The field log showed why: 0.42.0 planned every stop
on its own, about 70 `/v5/plan` requests in 3 minutes (12 at once, again on every switch of the time to leave), most
of them timed out in the Transitous queue, two 429s, 150–210 KB each. Rules in `ios/App/NearbyRank.swift` (tests
`NearbyRankTests`, `NearbySearchTests`) and `ios/App/TripTimeline.swift` (tests `TripTimelineTests`); the iOS wiring in
`ios/App/NearbyStore.swift`, `NearbyViews.swift`, `NearbyDetail.swift`, `Transit.planPage`.

- [ ] **One plan per search, from where you are.** `/v5/plan` from your coordinate to the destination (its stop, or its
      spot when it has several), `numItineraries` 8, `maxItineraries` 12, `searchWindow` 3600, `maxTransfers` 3, `maxPreTransitTime` = the
      walk to 1.6 km (straight × 1.3 at 1.2 m/s, minutes up: 1740 s; at most 2700 s), `detailedTransfers=false`, your
      walking speed once learned. The planner walks to every stop around by itself. Each itinerary goes with the stop its
      first ride leaves from (`Nearby.groupIndex`: one of the stops around with its id, else a bus stop of its name
      within 300 m, else the nearest within 120 m, a station 400 m); a stop that's none of them is added with its own
      circle (`Nearby.newGroup`; a name already taken gets `@<id>`). Its walk is the planner's own walk from your spot.
- [ ] **A second plan only when needed** (`Nearby.nextPlan`, two per search at most): fewer than 3 stops have a way and
      there's a `nextPageCursor` (the next page, `maxPreTransitTime` for 3 km, so 2700 s), or the first got no answer
      (asked once more, the same wider walk, no cursor). Never while Transitous asks to slow down (after a 429).
- [ ] **The stops around** (`/v1/map/stops`, 1 km, kept 10 min) are only drawn (8 at most, as 0.42.0); the ones with no
      way from the plan are grey dots. **Tap one**: its own plan (from its first id, at when you can be there, 5
      itineraries; one stop at a time), and its next departures (`/v6/stoptimes`, 16, from when you can be there; kept a
      minute) of the same lines and headsigns as its ways, under "Also from here". A failed one: "Couldn’t check this stop
      just now (the planner is busy or didn’t answer)." with Try again.
- [ ] **At most 2 requests at once from this screen**; nothing re-fired or cancelled by the time switch.
- [ ] **Leave now / In 10 / In 20 filter what's in** (no new plan); one second after the last switch, the next page only
      when fewer than 3 stops have a ranked way for that time and the search has a plan left. Asked again after 5
      minutes on screen (what's shown stays), or when you moved 250 m or the destination changed.
- [ ] **The window** (`Nearby.shown`): a way counts when you leave your door at or after the time you set off (its
      departure less your walk, counted once; 30 s grace), with no upper bound: every way leaving your door within 35
      minutes, and at least the next 2 of a stop however late (tonight's last, or tomorrow's first). **Ranked** (tags,
      colours, the legend) only when it leaves your door within those 35 minutes, waits at most 90 minutes anywhere (before
      the first ride or at a change) and is there within 3 hours of setting off (`Nearby.ranked`); the others are drawn
      grey, tagged "later", with their day ("tomorrow", a weekday; nil today and the night after until 04:00).
- [ ] **Fastest trip's own ways are always in**, with their stop, in every window; nothing for that time: its stop is
      shown with its way from now ("Nothing found yet for that time: this is your trip’s way…").
- [ ] **What the screen says** (`Nearby.statusLine`): "No bus or train from the stops within 1.6 km in this time…" only
      when the planner answered and your trip has no way either; no answer: "Couldn’t check the stops around you just now
      (no answer in time / the planner is busy). Your trip has the fastest way."; some in: "Couldn’t check every stop
      just now (…): these are the ones in."; stops tapped that failed: "Couldn’t check N stops just now (…). Tap one to try
      again."
- [ ] **Surest only at 70 % on time or more** (`Nearby.surestAt`), on the list and in a stop's sheet; else no Surest.
- [ ] **Overnight ways apart.** In a stop's sheet the late ones (as above) get their own group, "Tomorrow morning" (there
      tomorrow before noon) or "Later · Sat", on their own time axis; never Fastest or Surest.
- [ ] **Circles that would overlap are one** (`Nearby.merge`): closer than 40 pt at the map's zoom, the earliest there
      is drawn (at its own place) with "+N"; grey dots under a circle are left out.
- [ ] **Whole trip rows** (`TripTimeline`): the time axis ticks every 10/15/30 min, 1/2/3/6 h, the smallest step with
      labels 56 pt apart, the start and end always, none closer (`tickStep`, `ticks(width:)`). Each row's leave and arrive
      times always, moved apart around the row's middle when the row is short (`ends`, 40 pt a time, 6 pt between). Every
      gap labelled with its minutes (`gapLabels`): the walk to the first stop "🚶 2" (with a wait: "🚶2 + 1 wait"), each
      change "6 min" or "🚶3 + 5 wait", the last walk "🚶 4"; centred on the gap when it fits (6 + 6.5 pt a character,
      14 the walker, 4 pt spare), else under the bar with a tick, in the first of two rows where it overlaps nothing (left
      out when neither has room). A change under 3 min red, under your learned change time yellow. Each ride's own
      minutes inside its bar ("41 min") when they fit (8 pt spare).
- [ ] **Field log** (`.net`): one line per search, see [logs-export.md](logs-export.md) › Fastest trip, zoomed out
      (0.42.2).

## iOS 0.42.1

From the request "Make it so you can stop the alarm without unlocking my phone". Rules in `ios/App/AlarmStop.swift`
(tests `AlarmStopTests`); the iOS wiring in `ios/App/AlarmResponder.swift`.

- [ ] **Stop alarm works on the lock screen, never asks to unlock and never opens the app.** For the trip alarm, its
      repeat, the heads-up, arriving and the backup notification, and the school wake-up's notification fallback.
      Android: the ringing alarm as a full-screen-intent notification (`USE_FULL_SCREEN_INTENT`, `setFullScreenIntent`,
      `CATEGORY_ALARM`, shown over the lock screen with `setShowWhenLocked`/`setTurnScreenOn` on its activity) with a
      **Stop alarm** action whose `PendingIntent` goes to a `BroadcastReceiver` (not an activity, so the keyguard isn't
      asked for: no `requestDismissKeyguard`), and the same action on the ongoing ride notification while it rings
      (iOS: the Live Activity's big Stop alarm button; the Dynamic Island shows a bell while it rings).
- [ ] **A stop from the lock screen is the same as Stop in the app**: the sound, the buzz, the out-loud-after-60-s of
      "Sound only with headphones", the 30 s repeat; the ring counts as answered for the adaptive wake-up (when you
      stopped it); with "Ring at the stop" the leg goes to awake (and rings again at the stop), else the leg is done;
      the backup was already off since the ring. Still on? and the backup behave as after an in-app stop.
- [ ] **What each answer stops** (`AlarmStop.plan`): a school wake-up notification (`wake-<day>-<n>`) takes that day's
      three away (pending and shown) whatever you did with it; its Stop alarm also stops a real alarm still ringing.
      Stop alarm on any trip notification stops the trip alarm; tapping or swiping away the ringing alarm's own
      notification (or its repeat) does too. Anything else (Still on?, which train, a friend's message) goes to the trip
      engine as before.
- [ ] **Works when the app wasn't running**: the receiver must not need the trip engine. With no trip engine nothing
      rings (it plays the sound), so it only takes the alarm's notifications off the lock screen (`alarm`,
      `alarm-again`, `backup`, `heads-up-true/false` shown; the backup still to come stays) and makes the ride
      notification stop saying it rings; answers meant for the trip engine are kept and handed to it when it starts.
- [ ] The alarm and wake-up notifications show their title on the lock screen even with previews hidden
      (Android: `VISIBILITY_PUBLIC` for these, or a public version with the title).
- [ ] Not done on purpose: stopping with a volume or power button (iOS has no public way; on Android it's possible but
      keep it the same: Stop alarm only).

## iOS 0.42.0

From the field report ("At a friend's place going home to Centrum it showed one bus, unclear what other routes would come
out at about the same time"). Fastest trip, zoomed out (concept N5, with N4's whole-trip timelines). Rules in
`ios/App/NearbyRank.swift` (tests `NearbyRankTests`) and `ios/App/TripTimeline.swift` (tests `TripTimelineTests`).

- [ ] **Fastest trip opens on the stops around you.** Not on board, not a planned (Be there by / class) trip, not the demo:
      a map of every bus stop and train station you could walk to, each planned to the destination. Candidate stops from
      Transitous `/v1/map/stops` in a square of 1 km (then 1.6, 2.2, 3 km while fewer than 3 stops have a way); one entry
      per station (`parentId`); same-name stops within 300 m are one stop (both sides of the road, up to 2 ids); at most 8
      stops and 12 plans per step, 12 stops and 20 plans in all; the 2 nearest stations always among them. Each stop
      planned (`/v5/plan`, from its id, to the destination's stop, or its spot when it has several; 5 itineraries, at
      most 3 transfers) from when you can be there; drawn as each answer comes in; Fastest trip's own trips are put
      with their stops too. Every request through the normal Transitous limiter (a few at a time, pause on 429). The
      whole answer is kept 1 minute per place (~200 m), destination and leave time; asked again after 3 minutes on screen.
- [ ] **Walk**: straight line × 1.3 at 1.2 m/s, whole minutes up (`Nearby.plannedWalk`), shown at your learned speed
      with 2 min spare (`WalkPlan`, as 0.40). A departure counts when you make it setting off at the window start
      (30 s grace) and it leaves within 35 minutes after that (plus the walk).
- [ ] **Leave now / In 10 min / In 20 min** switch (the window's start), re-planned.
- [ ] **Circles**: colour by the stop's earliest arrival you make: green `#3DD598` → `#C9D45A` → `#E8A33D` → red `#E86F5A`,
      between the earliest and latest (at least 8 min apart), minutes inside; legend "arrive 18:44 … 18:58". **Ring** =
      how sure: solid at ≥ 85 % on time, dashed under, thin grey when it only goes by the time of day. Map framed on
      you and the stops with a way (×1.4, at least 600 m).
- [ ] **How sure** (`Nearby.sure`): on time = less than 3 min late at the destination. Your own rides on the trip's last
      line to its last stop (the app's delay book from your rides; ≥ 4 rides, the last 20): the share on time, "usually
      +N min" (median, when ≥ 1); else the model's chance (time of day, the line's live delays now and what was seen):
      "on time about NN% (by live times)" or "(by the time of day)"; either times the chance of making each change.
      Clamped to 1–99 %.
- [ ] **Tags**: Fastest = earliest arrival (tie: shorter walk, then later departure); Surest = highest on-time % (tie:
      earlier arrival), the fastest itself when it's as sure; Slower = 5 min or more after the fastest. List order:
      fastest, surest, then by arrival. Row: stop, walk, line chips, leaves, big arrival, on time NN%.
- [ ] **A stop tapped**: a half sheet (the map above still usable): walk, tag, "Arrive X: on time NN% of your last N
      rides · usually +1 min" (only what's backed; else "by live times"); Times (next 6 departures you make: line, time,
      live / +N / timetable / cancelled, arrive) or **Whole trip**: each departure as a timeline on one shared axis
      (start rounded down, end up to 5 min, at least 20 min; ticks every 10 / 15 / 30 min): walk (dotted), wait (thin),
      rides in their line colour (bright live, faint timetable), change stations under it (left out when closer than
      0.16 of the axis to the one before or to the trip's end times), leave and arrive times at its ends; gold border =
      fastest, green = surest; tap selects. **On the line now**: the next 3 vehicles of those departures with their own
      GPS age ("GPS 20 s"), "in 9 min · 4 stops" (stops to go by the fix on its road; dropped once past your stop),
      drawn on the map with the first one's road. **Go · leave in N min** makes it your trip (as From <stop>).
- [ ] "Your trip" (top right) or "Your trip and other times" shows Fastest trip's cards as before; "All stops around
      you" on them goes back.

## iOS 0.41.0

From the user ("When you're walking towards the station, like in Google Maps, have the arrow: turn right here, turn left
here … instead of just the text and the button to Google Maps (keep the button)"). Walking turn by turn to the stop or
platform. Rules in `ios/App/WalkGuide.swift` (tests `WalkGuideTests`); the map, GPS, buzzes and voice in
`ios/App/WalkGuideView.swift`.

- [ ] **Walk with arrows.** The walk sheet ("Walk there" on the Go to card, at a change, from the boards) has a "Walk with
      arrows" button above the Apple Maps one (which stays). It opens a full-screen map that follows you (heading up,
      or north up with a toggle), the route drawn with the walked part dimmed, and a big card on top: the arrow and
      "In 40 m · turn right onto Hoogstraat", the turn after it small. Below: "4 min · 320 m to go" and, with a ride to
      catch, "Your bus leaves in 6 min · you’ll make it" / "walk a bit faster" / "hurry, it’s tight" (your own walking
      speed once learned, else 1.2 m/s; fine with a minute spare, faster when 25 % quicker makes it).
- [ ] **The route and its arrows.** Apple's walking directions (MapKit `MKDirections`, free) give steps with words (in
      the phone's language), a length and a shape, but no turn type. The arrow comes from the shape: the direction over
      the 12 m into a step's start against the 12 m out of it: under 20° straight, under 45° slight, under 120° a turn,
      under 165° sharp, else a U-turn; a straight shape whose words say left or right is a slight turn that way. Steps
      without words join their neighbour; the first is the start, the last the stop (one is added when the last turns).
      **Android has no MapKit:** use OSM-based foot routing instead, to decide later: the public OSRM `foot` profile
      (its steps carry a maneuver type and modifier, so the arrow can come from those, the shape rule as a fallback;
      the public demo server is for light use only), Valhalla (pedestrian costing, e.g. a hosted instance), or the
      GraphHopper free tier (key needed, a daily quota). Google's Directions API is paid.
- [ ] **Following it.** GPS at best accuracy (3 m filter) only while the screen is in front; off in the background and
      when it closes. Each fix (accuracy 65 m or better) is placed on the route (the pass nearest to the last place, so
      a route that doubles back doesn't jump); the step moves on within 15 m of its turn or once past it, never back,
      and not while off the route. A buzz at 30 m before a turn (not on steps under 40 m), two strong ones at the turn.
      More than 40 m off for 10 s: a new route from where you are, at most every 20 s. Within 25 m of the stop: "You’re
      here · Platform 4", a success buzz, and after 2.5 s it closes back to the Go to card (which then says you're here).
- [ ] **Spoken turns** only with headphones in (the alarm's headphones rule), on its own audio session (never the trip's),
      not while the alarm rings, with a speaker toggle (remembered). "In 30 metres, turn right onto Hoogstraat".
- [ ] **Lock screen.** During a trip (walking at a change) the Live Activity's change line shows the next turn
      ("→ 40 m · Hoogstraat", the stop's platform for the last one) after a "you'll miss it" line; a new optional
      `walkTurn` in the state (an older state still decodes). Sent per turn (at the new step and at the 30 m buzz), not
      per metre. Android: the same line in the ongoing trip notification.
- [ ] The battery log has a new GPS reason "walking with arrows".

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

- [ ] **Real GPS first** for the bus or train you wait for (Fastest trip's map, the live sheet, the home map's next-trip
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
      - **on board**: the vehicle is drawn where your phone is (fix ≤ 30 s old, ±100 m), also in its live sheet.
- [ ] Fastest trip's stop pin is a stop, not a vehicle: a person-waiting icon, light pill with the line's colour as text
      and border ("IC · 19:38").
- [ ] Settings › Map › **Bus position**: Real GPS (default) / Estimated (0.40.1's fused place, no ghost).
      The on-board matcher keeps its raw GPS (unchanged). Vectors in `ios/Tests/RealFirstTests.swift`.

## iOS 0.40.2

From the field report ("The Friends tab pops up a new map, which is annoying, and you can't swipe to leave"; "It's hard
to get out of the calendar screen, you can't swipe"). UI only, no new rules.

- [ ] **Friends over the home map, not a second map.** iOS 0.31 opened Friends as a full-height sheet holding a map of its
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
      the predictive back gesture) closes it and steps back through its pages.
- [ ] **Your week is a sheet.** It was drawn over the map (both home styles) with only a small map button to leave. Now a
      full-height sheet with the grabber, swiped down or its × to close (like Your day). Android: Your week as a sheet or
      a screen that system back closes.
- [ ] **The one-time questions** ("Show friends your trips?", "Compare timetables with friends?") can be swiped away or
      left with "Not now" (top left) until answered; not answered stays off and is asked again the next time Friends
      opens (once per opening). Android: system back on them = "Not now".
- [ ] Android sweep: every screen that opens over another (Friends and its pages, Your week, Your day, the school
      calendar picker, Your week in Settings, Compare and a day of it, the consent screens) handles system back /
      predictive back and has a visible close or back control; only the first-run setup and the backup code just made
      hold back.

## iOS 0.40.1

From the field report of 26 November ("Where the bus was on the map wasn't matching the actual position until about the
end. It teleported when the time changed"): 0.40.0's `WaitMarker` moved a bus drawn within 150 m of your stop to where
its times put it while its time there was more than 2 min off, so it jumped with every new live time. Replaced by one
fused position (`ios/App/BusFusion.swift`, tests `BusFusionTests` and `WaitMarkerTests`). Log line in
[logs-export.md](logs-export.md) › The bus you wait for on the map (0.40.1).

- [ ] The bus you wait for (Fastest trip's map, the live sheet, the home map's next-trip bus): in metres along its road,
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
      The on-board matcher keeps the raw GPS. Vectors in `ios/Tests/BusFusionTests.swift` and `WaitMarkerTests.swift`.

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
- [ ] (Replaced by 0.40.1's fused position: skip it.) The bus you wait for on the map agrees with its time (`WaitMarker`, Fastest trip's map and the live sheet): drawn
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
