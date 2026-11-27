# Shared ride logs: reading what phones sent

Since 0.28.1 the app has **Settings › Help improve Haltewekker › Share ride logs** (off unless someone turns it on).
Phones that share send the matching and ride lines of their field log to the relay, scrubbed on the phone first:
no coordinates, no names of their places (Home and School become "Home" and "School"), no friends' names, no account
ids, no requests. Each phone's uploads are grouped by a random install id (not the Friends account). The relay keeps
them **60 days**, then deletes them. A phone can delete everything it sent at any time ("Delete what I sent").

Since 0.32 there is a second switch, **Share GPS points during rides** (also off unless turned on), and the first-run
setup asks both (step "Help improve Haltewekker", before Done); someone whose setup was done before gets a one-time card
on the home. The app says it's made by **Nana** and that what's shared goes to Nana (the name is one constant,
`Maker.name` in `ios/App/GPSShare.swift`). See [GPS points](#gps-points-032) and [Replay](#replay-the-matcher-on-real-rides).

The relay stores them already. To **read** them you need one secret, `LOGS_ADMIN_KEY`, that only you know. Until it
is set, the export answers `503 not configured`.

## 1. Add the secret once (Cloudflare dashboard)

1. Make a long random value, for example in Terminal on a Mac: `openssl rand -hex 32` (64 characters). Keep it in your
   password manager.
2. Go to <https://dash.cloudflare.com> and sign in.
3. **Workers & Pages** (left menu) › **haltewekker-relay**.
4. **Settings** › **Variables and Secrets** › **Add**.
5. Type: **Secret**. Variable name: `LOGS_ADMIN_KEY`. Value: the long random value from step 1.
6. **Deploy** (or **Save and deploy**).

`wrangler.jsonc` has `"keep_vars": true`, so the secret stays when the relay is deployed again from GitHub. Nothing
else needs setting up: the storage (a Durable Object called `Logs`) is declared in `wrangler.jsonc`.

To check it works (should give `401`, not `503`):

```sh
curl -s -o /dev/null -w "%{http_code}\n" https://haltewekker-relay.tsfaw1.workers.dev/logs/v1/export
```

## 2. Export

```sh
KEY='the value from step 1'
RELAY=https://haltewekker-relay.tsfaw1.workers.dev

# everything of the last 7 days, as JSON
curl -s -H "Authorization: Bearer $KEY" "$RELAY/logs/v1/export?since=$(( $(date +%s) - 7*86400 ))" > logs.json

# since a date, as plain text: one log line per line, "<received, UTC> <install id, 8> <app version> <line>"
curl -s -H "Authorization: Bearer $KEY" "$RELAY/logs/v1/export?since=2026-11-19&format=text" > logs.txt
```

`since` is unix seconds or an ISO date (`2026-11-19`, `2026-11-19T07:00:00Z`); it is the time the relay received an
upload. One answer holds up to 1000 uploads (`limit`, at most 5000) and about 4 MB. When there's more:

- JSON: the answer is `{"uploads":[{"id","install","app","at","lines":[…]}],"next":<id>,"more":true}`; ask again with
  `&after=<next>`.
- Text: the headers `X-Next` and `X-More` say the same (`curl -D -` shows them).

All of it, page by page, into one text file:

```sh
after=0; : > logs.txt
while :; do
  curl -s -D headers.txt -H "Authorization: Bearer $KEY" "$RELAY/logs/v1/export?since=0&format=text&after=$after" >> logs.txt
  after=$(grep -i '^x-next:' headers.txt | tr -d '\r' | awk '{print $2}')
  grep -qi '^x-more: true' headers.txt || break
done
```

A line looks like this (the sample the app shows):

```
2026-11-19T06:35:02Z 3f9a1c2e 0.28.1 (117) 2026-11-19 07:33:58 ride start · Home on board, by itself · bus 305·7821 · its stop 16630 m from you · leg 1/3
```

The second time is the phone's own clock (its time zone); `match` lines are the matcher's looks, `ride` lines what the
ride did (see `ios/App/FieldLog.swift` for every kind of line).

## Limits and answers

| Route | What | Answers |
| --- | --- | --- |
| `POST /logs/v1/put` | `{"install","secret","app","lines","fixes"?,"tz"?}`, may be gzipped; `lines` may be `[]` when `fixes` has points | 200 `{"ok","id","lines","fixes"}`, 400 bad shape, 403 another phone's id, 413 over 512 KB sent or 1 MB unzipped, 429 over 60 uploads, 3 MB of lines or 6 MB of points a day for one phone (or 120 an hour from one network), 507 storage full (800 MB in all) |
| `POST /logs/v1/delete` | `{"install","secret"}` | 200 `{"deleted":n}`, 403 wrong secret |
| `GET /logs/v1/export` | `?since=&after=&limit=&format=` | 200, 400 bad `since`, 401 wrong or missing key, 503 `not configured` (no `LOGS_ADMIN_KEY`) |

The relay never logs a line, an install id or a key. Everything older than 60 days goes by itself (checked daily).

To check the relay by hand: `node relay/test-logs.mjs` (local, no Cloudflare), or
`node relay/test-logs.mjs https://haltewekker-relay.tsfaw1.workers.dev` (puts and deletes one throwaway upload).

## GPS points (0.32)

**Settings › Help improve Haltewekker › Share GPS points during rides**, off unless turned on (in the setup's step,
the home's card or Settings). What the phone does:

- **Only while a trip runs** (sleeping, awake, alarm, at a change; not the pretend trip): from the trip's own location
  updates (it asks for no GPS of its own), at most **one point every 3 s**, accuracy 150 m or better, at most 6000 per
  trip. They're kept on the phone (`gpsshare.json` in Application Support) until the trip ends.
- **When the trip ends**: every point within the **first 500 m travelled or within 500 m (straight line) of where the
  trip started**, the same for the **last 500 m / where it ended**, and every point **within 500 m of Home, School or
  another saved place** is dropped (`GPSShareRules.trimmed`, `.outsideZones`). A trip under about 1 km sends nothing.
  What's left waits to go (at most 20 000 points; the oldest go first).
- **Upload**: with the ride-log uploads (after a trip, else at most hourly; never during a trip, not in Low Data Mode,
  not in Low Power Mode), gzipped, at most **600 KB of points per upload and 4 MB a day** (lines stay 200 KB / 2 MB).
  Points never go into the field log's text. Turning the switch off deletes the points not sent yet from the phone;
  "Delete what I sent" deletes the lines and the points on the relay.

One point as it's sent (rounded on the phone and again on the relay):

```json
{"t":1795070038.2,"lat":51.69012,"lon":5.29871,"acc":8,"spd":12.4,"crs":87,"leg":"1/3","veh":"bus 305·7821","ride":"3f9a1c2e"}
```

`t` unix seconds (0.1 s), `lat`/`lon` 5 decimals (about a metre), `acc` metres, `spd` m/s and `crs` degrees (`-1`: the
phone didn't know), `leg` and `veh` exactly as the ride lines write them (`leg 1/3`, `bus 305·7821`: the line and the
last 4 characters of the trip id; `veh` is the vehicle the ride had at that moment), `ride` a random id per trip. The
put also carries `tz`, the phone's offset from UTC in seconds: the lines' own clock is the phone's, so a line's UTC time
is its clock minus `tz`.

In the JSON export each upload has `"fixes":[…]` and `"tz"` when it brought points (`format=text` leaves them out).
An upload of points only has `"lines":[]`. The relay drops a point without a time or a place on earth (and a tag that
doesn't look like one) instead of refusing the whole upload.

## Replay the matcher on real rides

`tools/replay` is a small Swift package that compiles the app's own pure matcher files (`ios/App/Geo.swift`,
`VehicleMatch.swift`, `ChooseGPS.swift`, `OnBoardRules.swift`, `FieldLog.swift`, `RealPositions.swift`, linked from
`tools/replay/Sources/replay/App`) with a command-line tool. It reads an export and, per leg with GPS points:

- **truth**: the vehicle you were on: the one you picked by hand in that leg (`hand pick · bus 306·4942 (was …)`), else
  the one the app ended the leg on (the last points' `veh`);
- **app**: what the app showed (each point's `veh`), scored;
- **replay**: the points through the matcher as it is now, a look every 10 s: the points of the last two minutes
  judged against every vehicle around (`VehicleMatch.judgeAll`), ranked (`rank`, `top`) and chosen with the app's
  hysteresis (`decide`), scored the same way.

The score: **settle** (seconds from the leg's first point until it showed the right one and kept it to the end; `-`:
it didn't end on it), **flips** (changes from one vehicle to another), **on it** (share of the moments it showed the
right one). The summary counts the legs it settled on, the median time to settle and all flips.

The vehicles come from the input (the synthetic fixture has them), from `--tracks file.json`, or with `--fetch` from
Transitous's timetable for the ride's own time and place (`/v1/map/trips`, as the phone asked; past days are kept
there). `--save-tracks file.json` keeps what was fetched so the next run needs no network. A real ride replayed this way
is judged by the timetable (and by live times when Transitous still has them): the vehicles' own GPS of that moment and
the live times the phone saw then aren't in an export, so a replay is a comparison of matcher versions on the same
input, not a copy of what the phone saw. The first 500 m of a trip (often the boarding) are never in an export.

Install Swift once (Xcode on a Mac has it; on Linux the swift.org toolchain, e.g. 6.0). Then:

```sh
cd tools/replay
swift run -c release replay fixtures/synthetic.json          # the made-up fixture: proves it works
swift test                                                    # the replay's own tests, on that fixture

# real rides: export (as above), then replay with the vehicles from Transitous
KEY='…'; RELAY=https://haltewekker-relay.tsfaw1.workers.dev
curl -s -H "Authorization: Bearer $KEY" "$RELAY/logs/v1/export?since=$(( $(date +%s) - 7*86400 ))" > /tmp/rides.json
swift run -c release replay /tmp/rides.json --fetch --save-tracks /tmp/vehicles.json
swift run -c release replay /tmp/rides.json --tracks /tmp/vehicles.json --looks     # every look, again, offline
swift run -c release replay /tmp/rides.json --tracks /tmp/vehicles.json --json > /tmp/score.json
```

Several export pages can go in one file as a JSON array of answers. Keep real exports out of the repository (they are
people's rides): only `fixtures/synthetic.json` (made up by `make-fixture.mjs`) is committed. `--fetch` sends the box
and time around each ride to Transitous, as the phone did during the ride.

What it prints for the fixture:

```
install  ride      leg  min  truth (from)               | app: settle  flips  on it | replay: settle  flips  on it  ended on
00000000 5a5a5a5a  1/2    10  305·7821 (hand pick)       | app:   84 s      1    86% | replay:   30 s      0    97%  305·7821
         wake · bus: distance rule 2.8 min (1984 m) · time rule 1.9 min (1408 m) before the end · no ring in its log
00000000 5a5a5a5a  2/2     5  400·1111 (ended on)        | app:    0 s      0   100% | replay:   30 s      0    93%  400·1111
         wake · bus: distance rule 2.8 min (1980 m) · time rule 1.9 min (1404 m) before the end · no ring in its log

app (as logged): settled on the one you were on in 2 of 2 legs · median 42 s to settle · 1 flips · on it 93% of the time
replay (matcher now): settled on the one you were on in 2 of 2 legs · median 30 s to settle · 0 flips · on it 95% of the time
```

Read it as: the app showed bus 306 first and was put right by hand after 84 s; the matcher as it is now would have
shown 305 after 30 s (its first look with 20 s of points) and kept it. To try a change to the matcher, edit
`ios/App/VehicleMatch.swift` (or the other linked files), run the same command on the same export and vehicles file,
and compare the two summaries.

The `wake` line under each leg (0.33, `tools/replay/Sources/replay/Wake.swift`, with the app's own `WakeRule.swift`)
says when each wake rule would have rung, in minutes before the leg's last point (taken as its stop): the distance
rule (2 km a bus, 5 km a train) and the time rule alone (2 min a bus, 3 min a train, by your smoothed speed along the
track you went: an export has no live arrivals), and when the app's own `ring · …` line says it rang and by which
rule (`by distance`, `by time 3 min (live)`, `by time 2 min (speed)`). The app rings at whichever of the two comes
first.

0.34 adds two lines under each leg (`tools/replay/Sources/replay/Trains.swift`, with the app's own `TrainRules.swift`
and `DeadReckon.swift`): on a train leg, the stations you stood at and went through at speed and the trains the
stopping pattern rules out (`trains: stood at 2 stations, through 1 at speed · it rules out SPR·6628`; it says
`WRONG` if the one you were on is among them, which should never happen); on every leg, how dead reckoning would have
done over the gaps of more than 15 s in the GPS points (`reckon: 2 gaps over 15 s · the reckoned place off by 40 m
(median), 120 m at worst`), along the track you went. Old bus GPS moved on (0.34) needs the vehicles' own GPS of that
moment, which an export doesn't have.

## For Android (parity)

The same switches, words and rules, so the relay and the replay treat both alike:

- Setup step "Help improve Haltewekker" before the summary, both switches off; summary row "Ride logs" / "GPS points
  during rides" / both / "Nothing shared". Existing users: a one-time card ("Help improve Haltewekker?", "Not now",
  "Choose…"), shown once the setup is done, never during a test setup; answered or put away, it never comes back
  (`share.asked.v1`). Settings › Help improve Haltewekker has both switches and "Delete what I sent". The texts are
  `ShareAsk` in `ios/App/GPSShare.swift`; the maker's name, "Nana", one constant.
- Points: while a trip runs, from the trip's own location updates, one per 3 s at most, accuracy ≤ 150 m, ≤ 6000 per
  trip; rounded (t 0.1 s, lat/lon 5 decimals, acc 1 m, spd 0.1 m/s, crs 1°, unknown −1); tagged `leg` "i/n", `veh` as
  the ride lines ("bus 305·7821"; characters other than letters, digits, space and `·.+/_'()?-` become `-`, 40 at
  most), `ride` 8 random hex per trip. At the trip's end: drop points with less than 500 m travelled from the start or
  to the end, or within 500 m (straight line) of the first or the last point, or within 500 m of any saved place. Keep
  at most 20 000 waiting (drop the oldest).
- Upload with the log upload (same `install`/`secret`), `fixes` and `tz` only when there are points; at most 600 KB of
  points (their JSON) per upload and 4 MB a day, counted apart from the lines' 200 KB / 2 MB; the same moments and
  conditions as the lines (after a trip, else hourly; not during a trip, on a metered/Low Data network or in battery
  saver). Drop the sent points from the queue only after a 200; switching off clears the queue.

### Getting on wherever you get on (0.42.4)

What's new in 0.42.4 (`ios/App/WaitStart.swift`, tests `WaitStartTests`; wiring in `GoStore.checkBoarding` and
`TripManager.boardedHere`; Android parity in [android-todo.md](android-todo.md) › iOS 0.42.4). While Fastest trip
watches, one line per look in the match log (every look while you move or something moves with you; otherwise once a
minute while it says the same):

- `wait · moving 9 m/s 40 s · candidates bus 305·2718 gps 12 s fits, bus 306·1234 times elsewhere · start bus 305·2718`: seconds
  at bus speed (6 m/s) in the last 2 minutes and your speed now; up to 3 of the matcher's best, each by its own GPS
  (`gps 12 s`: its fix's age) or by its `times`, and `fits` (it takes you on), `elsewhere` (it doesn't) or `stops ?`
  (its stops couldn't be had); then the call.
- The holds: `held by standing`, `held by walking or cycling (motion)`, `held by not at bus speed for 30 s yet`,
  `held by no bus or train fits your gps`, `held by seen 1 of 2 looks`, `held by its stops not known yet`,
  `held by not your way` (`(told)` once the alert went).
- `wait · moving … · wrong bus bus 154·0855`, then `wait · wrong bus · on bus 154·0855 to Schijndel, planned 305 · Get off at the
  next stop, and plan again from there`: sure of one that doesn't take you on (its own GPS with you 75 s), told once.
- `wait · bus 305·2718 · got on at its stop 2 of 18, 1040 m from where the way had it`: the leg starts at the stop you got on
  at, not the planned one (or "On board" where it found you). During a ride (a vehicle found after "I'm on it"):
  `ride board · bus 305·2718 got on at its stop 2 of 18, 1040 m from where the leg was planned from`.
- `wait · bus 305·2718 · not started: no way on from it` (or `a long way round`, `its stop is where you are`): it would have
  started, but couldn't plan on from it.
- In the ride log: `ride wait · watching on · its look at what you get on runs (in front)` (`again`, `behind the
  screen`) and `ride wait · watching off · closed` (`you're there`, `the trip you waited for has gone`, `after 3 hours`):
  the look runs from one to the other whatever is on screen, and with the phone locked.
- `ride check-out reminder in 60 s …` no longer comes unless the check-out reminder is turned on again (Settings › Trips
  & alarm): 0.42.4 turns it off for everyone, once.

### False "You'll miss", short legs, the planned train at a change, OVapi keys (0.42.3)

What's new in 0.42.3 (`ios/App/MissCall.swift` with `ChangeGuide.swift`, `ios/App/ShortLeg.swift`,
`RideGuards.plannedNextAmong`, `RealPositions.noMatchReason`; tests `MissCallTests`, `ShortLegTests`; Android parity in
[android-todo.md](android-todo.md) › iOS 0.42.3). New lines in the ride log:

- `ride change · the 08:12 should be leaving now: look out for it (no live time, no gps of its own, you 40 m from its
  stop)` (or `its live time gone by, no gps of its own`): at a change, the next ride isn't called missed yet; the ride
  screen says "Should be leaving now · Look out for it" ("May have left" once a live time is over a minute gone).
- `ride change · maybe missing the 17:52: held a minute before it's told`: a miss is told (`ride change · You’ll miss …`)
  only once looks have said so for a minute; `ride change · the 17:52 not missed after all` when a later look takes a
  told miss back.
- `ride change · tight for the 17:52, not missed` (` (the ride you're on has no fresh data)`): on the way, a minute short
  or less, or the ride you're on has no GPS ≤ 90 s and no live times ≤ 2 min old.
- `ride change · no ride instead from the change: tight, run for the 17:52`: missed by the numbers, but nothing that
  leaves from the change (never the line you're on): "Tight — run" instead of "You'll miss … take …".
- `ride wake · short leg (480 m, wake 1000 m): no alarm, a quiet word before the stop, first fix 30 s in`: a leg whose
  ends are within the wake distance (or 800 m) doesn't ring; `ride get ready · short leg: get off at the next stop
  (260 m, leg 75 s old)` is its quiet notice (`ready-…`); `ride arrive · not yet: 380 m from the stop of a short leg`
  while it's under a minute old or further than half the way it started from (200–450 m).
- `ride ring · held: leg 30 s old, 480 m (nothing rings in a leg's first minute)`: a normal leg rings at the next fix
  after its first minute.
- `ride arrive · already on the next leg's train IC·3561 (on its road): this leg is done`, then `ride arrive · on the
  next leg's ride · …` and `ride start · next leg (its planned ride, on its road) · …` (or `found on board`): going away
  from this leg's stop on the ride the next leg was planned with starts that leg, instead of `ride start · wrong way`
  and a pick.
- `vehicle shown · … · no gps: no ovapi match for trip_id 400100123 (started 22:40) · by times`, or `…: not started yet,
  starts 23:05` (replaces `not in ovapi positions`); `no train number, not in ovapi (a trip of nl-…)`. The key is OVapi's
  own trip_id, the same one its feed carries; a bus whose journey has begun but sends no position simply isn't in it.

### Fastest trip, zoomed out (0.42.2)

What's new in 0.42.2 (`ios/App/NearbyRank.swift`, `ios/App/NearbyStore.swift`; tests `NearbySearchTests`; Android parity in
[android-todo.md](android-todo.md) › iOS 0.42.2): the stops around you are asked with one plan from where you are (a
second only when needed), and each search writes one `net` line, so a report like "No bus or train within 1.6 km" can be
read from the log:

- `nearby · r 1.6 km · stops 9 · plans 1 (+1 page) · ways 6 · 0 failed · 0.8 s · 320 KB`: the walk the last plan took
  (1.6 or 3.0 km), the stops drawn (the stops around and the ones the ways leave from), the plans sent (a later page
  counted apart), the stops with a way shown for the time to leave, how many plans got no answer (timed out, a 429,
  cancelled), the whole search's time and the plans' size. Then, when they apply: ` · cooling` (Transitous asked to slow
  down: no second plan), ` · no stops` (the stops around couldn't be had; the plan went anyway), ` · seed 3` (Fastest
  trip's own ways put in).
- The same line with ` · after the switch to in 20 min` when a switch of the time to leave asked for the next page.
- `nearby stop · plan · ways 3 · times 12 · 0.9 s · 150 KB`: a stop tapped: its own plan (` · plan failed` when it got no
  answer; no ` · plan` when the search had its ways already), the departures shown, the next departures of its lines
  (`/v6/stoptimes`), time and size.

### The vehicle you wait for or ride on the map (0.40.3)

What's new in 0.40.3 (`ios/App/RealFirst.swift`, tests `RealFirstTests`; Android parity in
[android-todo.md](android-todo.md) › iOS 0.40.3): the bus or train you wait for or ride is drawn at its own last GPS fix
(moved on 20 s at most while clearly moving), the estimate a faint ghost ahead of it. It replaces the `bus fused` line
below. Once a minute per trip while it's drawn (Fastest trip's map, the live sheet with your stop or while you ride it,
the home map's next-trip vehicle):

- `vehicle shown · 305·9449 · gps ovapi 48 s · real +20 m · ghost +510 m`: its fix's feed (`ovapi`, or `ns` for a train
  by its number) and age; where it's drawn and its ghost in metres along its road from the fix itself (rounded to 10,
  signed; `no ghost` when the estimate is within 150 m). ` · real at its fix, off its road` when drawn at the fix's own
  place. ` · arriving`, ` · waiting at your stop`, ` · at your stop` by a fix ≤ 90 s old within 80 m of your stop.
- `vehicle shown · 305·9449 · no gps: <why> · by times`, or `· not drawn` (no live position, e.g. `no fix, road before
  your stop not known`). `<why>`: `real positions off`, `low power mode`, `ovapi positions not in`, `not in ovapi
  positions`, `ns positions not in`, `train 3561 not in ns positions`, `no train number, not in ovapi`, `fix 240 s old`,
  `fix not this journey`, `fix off its road`, `no fix`.
- `vehicle shown · 305·9449 · on board: drawn where you are` while you ride it; ` · estimated` with Settings › Map › Bus
  position: Estimated (0.40.1's place).

### The bus you wait for on the map (0.40.1)

What's new in 0.40.1 (`ios/App/BusFusion.swift`, tests `BusFusionTests`, `WaitMarkerTests`; Android parity in
[android-todo.md](android-todo.md) › iOS 0.40.1): the bus you wait for is drawn where its GPS and its live times
together put it, without jumps. New line in the ride log, once a minute per trip while it's drawn (Fastest trip's map,
the live sheet with your stop, the home map's next-trip bus):

- `bus fused · 305·9449 · gps 48 s old +320 m · eta says +510 m · drawn +440 m`: metres along its road from its last
  fix itself (rounded to 10, signed): its GPS moved on to now, where its live times put it, and where it's drawn (the
  drawn place glides, so it can lag the others a little). ` · no live times` instead of `eta says` when it has only the
  timetable; ` · far apart: gps trusted` when its fresh fix (≤ 90 s) is more than 1 km behind its times, or further on
  than them; ` · waiting at your stop` while its fresh fix stands at your stop before it leaves ("Waiting · leaves
  17:42"). Without a usable fix: `bus fused · 305·9449 · no gps · drawn by its times`, or `· gps not this journey ·
  drawn by its times` (seen past its first stop before it starts, or a kilometre ahead of its times). `train fused · …`
  for a train.

### The wrong bus, a miss at the change, the bus at your stop (0.39.1)

What's new in 0.39.1 (`ios/App/WrongBus.swift`, `MissRule` in `ChangeGuide.swift`, `DepartMatch`/`UsualLine` in
`PickRules.swift`, `farByGPS`/`gpsRescue` in `ChooseGPS.swift`; tests `WrongBusTests`; Android parity in
[android-todo.md](android-todo.md) › iOS 0.39.1). New lines in the ride log:

- `ride change · the 17:21 is still at or before the stop by its own GPS: not missed`: at a change the next ride is
  missed only once its live departure has gone by a minute with you not on it, never while its own GPS has it at or
  before the stop.
- `ride wait · not by its timetable: bus 305·0551 leaves 17:35 (in 11 min) · finding the one you're on`: a leg isn't
  started by the planned one's timetable more than 2 minutes before its live departure.
- `match choose · … → switch to 154·0855 · its own GPS far from you, the other one's fits`: the one shown is 1 km (a
  train 2.5 km) from you by its own GPS while another one fitted by its own GPS this look or in the last 90 s.
- `ride wrong bus · on 154·0855 to Schijndel, planned 306 · Stay on to Schijndel — 306 from there at 18:11` (and
  ` · roads split`): once a trip, the notification `wrongbus-…` and the ride screen's card.
- `ride other at stop · 154·0855 to Schijndel by its own GPS 30 m from you · not yours · your 306 at 17:23`: the
  notification `otherbus-<trip>` and the card while you wait.
- `ride usual line · not learned: bus 154·0855 isn't the planned 306`: a ride it found by itself on another line than
  planned doesn't teach your usual line.
- `match depart · …`: by live times alone "not then" takes 180 s off (under that: `not sure (live 91 s)`); two at the
  stop by their own GPS: ` · 2 at the stop: says nothing`.

### Picking the one you're on (0.38)

What's new in 0.38: the app picks the bus or train you're on faster and more reliably (`ios/App/PickRules.swift`,
tests `PickRulesTests`; Android parity in [android-todo.md](android-todo.md) › iOS 0.38.0):

- **The moment you left** (`DepartMatch`): standing 15 s at a stop, then moving; the vehicle whose own GPS or live
  times have it leave that stop within a minute of you, while the others clearly didn't, settles a choice after two
  looks (`depart · …` and `choose · … · left the stop with you` lines). The replay prints it under each leg (`depart:
  stood 40 s, left 25 s into the leg · left then: 305·7821 · it picks 305·7821`, `WRONG` if not the one you were on).
- **Your usual line** (`UsualLine`): line, time of day and weekday or weekend of your rides and corrections; a
  tie-breaker with hysteresis, never against a vehicle's own GPS (`detect · usual line · …`, `choose · usual line · …`,
  `usual line · bus 305·7821 +1`).
- **Stop pattern for buses** (`BusStops`): a bus that drives past a stop where you stood still, or would have waited at
  one you went through, counts worse once that's happened twice (`choose · bus stop pattern · …`).
- **Ask sooner** (`AskSooner`): two still tied a minute after leaving: "305 or 306?" at once (`ask · still tied …`).

### Trains on the same track, old GPS, tunnels, habits, change reliability (0.34)

- **Trains on the same track** (`ios/App/TrainRules.swift`, tests `TrainRulesTests`):
  - a confirmed train kept by its times or road (not by its own NS position, `gpsKeeps`) has the other trains on your
    track looked at every 2 minutes ("rivals", each with its own NS position through the relay's `/ns/vehicles`); one
    that passes by its own GPS while the one shown doesn't (`rivals`, best 2) starts a choice between them, which the
    usual 0.26.1 rules settle (its GPS decides). Field log: `rivals · IC·1131 not with you by its own GPS · IC·3624 by
    theirs → choose`;
  - a confirmed train whose track went elsewhere (your fixes 300 m or twice their accuracy off it, `roadsParted`)
    looks for the one you're on at once (not after two misses); choosing switches at once (`split`);
  - the stopping pattern while choosing between trains: a station (any candidate's stop) you went through at speed
    (from 600 m before to 600 m after, every step 8 m/s or more, fixes no more than 20 s apart, accuracy ≤ 100 m)
    rules out the candidates that call there; one you stood at (20 s within 40 m, or 1.5 × accuracy, within 250 m of
    it) rules out those whose track runs through it (within 150 m) without calling. Never all of them. The one shown
    ruled out: the best other one that passes this look, at once (none passes: as before). `choose · stopping pattern
    · not SPR·6628`;
  - two trains still tied after 2 minutes whose headsigns differ: asked once, on the ride screen and as a notification
    (when the app isn't in front) with both as buttons: "IC to 's-Hertogenbosch or IC to Eindhoven Centraal?"; the
    answer is a pick by hand (the rest of the trip planned from it, not changed by itself for the rest of the leg);
  - the trip follows the train you're on (`stayOn`): it also goes to where a later leg ends, the last one included
    (arriving 2 minutes before the ride after it, when there is one): one leg to there, the changes in between gone
    ("Stay on to 's-Hertogenbosch · This Intercity goes all the way …").
- **Old bus GPS moved on** (`RealPositions.advance`/`observedSpeed`/`lateness`/`ageSlack`, tests `AdvanceTests`): at
  the speed it was seen going (the fix's own speed, else along its road between its last two fixes 5–180 s apart,
  0–46 m/s) for up to 120 s (else its timetable speed for 60 s, as before); at a stop on its way it stands 10 s at
  least and leaves no earlier than its departure plus how late it is. The matcher moves its GPS anchor at that speed
  too, and allows an older fix more room: a fifth of what it went after its first 30 s, 600 m at most.
- **Tunnels and dead zones** (`ios/App/DeadReckon.swift`, tests `DeadReckonTests`): on a ride with its vehicle known,
  a step every 5 s; once the newest good fix (≤ 100 m) is more than 15 s old (and less than 15 minutes), the place
  goes on along the vehicle's road from where you got on to your stop: by the vehicle's own fresh fix (moved on at its
  pace, 2 minutes at most), else at its pace (distance left over the time to its live or timetable arrival when that
  is 30 s or more away, else your last speed; never faster than 160/100 km/h), never back, never past your stop. The
  distance, ETA, ride screen ("No GPS here: following its route…") and lock screen follow it; **only the time rule may
  ring on it** (the distance rule never rings on a reckoned place alone). A good fix ends it. Log: `reckon · no good
  GPS for 16 s · on along its route`, `ring · reckoned (pace) · by time 3 min (live)`, `reckon · good GPS again`.
- **Learned from your rides** (`ios/App/Habits.swift`, `HabitStore.swift`, tests `HabitsTests`), on the phone only:
  walking speed (the median of your last walks once there are 5; a walk: 60 s or more at 0.6–2.6 m/s with fixes of
  25 m or better: across a change, and to the first stop), sent to the planner as `pedestrianSpeed` (m/s, one decimal)
  when 0.1 m/s or more off its 1.2; your change time (minutes from getting off to within 50 m of the next ride's stop,
  20 at most; the 80th percentile once there are 3) as the least room a change needs in `Risk.miss` (2 minutes more
  than the planner's walk at most); stops you get on at 3 times or more and more often than trips were planned from
  them: a plan from there 2 minutes better in `Risk.score`. Settings › Trips & alarm › "Learned from your rides": the
  three values and "Reset what it learned".
- **How reliable a change is** (`ios/App/ChangeOdds.swift`, tests `ChangeOddsTests`): per change (line A > line B @
  station, lower case) and time of week (`wd`/`we` and early < 7, am 7–9, day 9–16, pm 16–19, eve), one outcome per
  day (the day's last), 30 days and 200 changes kept: made it when you got on the planned one or one leaving within a
  minute of it, missed when a later one. "this change worked on 9 of 10 days" on the plan's options and the Go card
  once there are 3 days ("At Tilburg: …" on a trip with more than one change); in `Risk.miss` the chance leans on it by
  days / (days + 5) (a change with no time at all stays one).

### Wake by time and Motion & Fitness (0.33)

- Settings › Trips & alarm › "Wake me … before my stop": **By time** (default) or **By distance**; by time, minutes
  for trains (default 3) and buses (default 2), 1–10 (`wake.by` "time"/"distance", `wake.trainMin`, `wake.busMin`).
  The usual wake distance stays, as the safety net. Rules (`ios/App/WakeRule.swift`, tests in `WakeRuleTests`):
  - the distance rule first, as before (straight line from the newest good fix ≤ the wake distance) → `by distance`;
  - by time, only once you're 300 m or more from the leg's first stop, the distance left (along the vehicle's road
    from where you got on to your stop when known, never less than straight) within the minutes at top speed
    (160 km/h a train, 100 km/h a bus), and the estimate ≤ the minutes: the stop's **live** arrival from the vehicle's
    own trip answer while it is 150 s old or newer, in the future and not faster than top speed from here; else the
    distance left ÷ your **smoothed speed** (exponential, 30 s time constant; known after 20 s of readings, forgotten
    after 90 s without; the GPS's own speed, else between two fixes of ≤ 50 m, 2 s apart; > 100 m/s dropped), only at
    4 m/s or more (halted at a station before yours, or in a jam, it doesn't ring);
  - within 20 s of a leg's start either rule wakes it silently (as a leg that starts inside its wake distance);
  - the ring line says which fired: `ring · by time 3 min (live) · …`, `ring · by time 2 min (speed) · …`,
    `ring · by distance · …`; the notification "Wake up · <stop> in about 3 min." by time;
  - the far GPS tier and its backstop region keep clear of the time rule's reach (`WakeRule.gpsWakeMetres`).
- "Use motion to notice rides faster" (off by default; Settings › Trips & alarm, and the setup's Mornings step, which
  asks for the permission when it's turned on). Android: Activity Recognition (`ActivityRecognitionClient`,
  `ACTIVITY_RECOGNITION` permission at runtime, transitions API) with the same kinds; iOS: `CMMotionActivityManager`
  (`NSMotionUsageDescription`). Rules (`ios/App/MotionRules.swift`, tests in `MotionRulesTests`), each only next to
  the GPS, never instead of it; the alarm, the wake distance and the backup alarm never depend on it:
  - what it says now: the latest activity (automotive first when several), its run back over the same kind (a
    low-confidence other one in between doesn't break it); from a history answer (not live updates) at most 5 minutes
    old; "sure" is medium or high;
  - **automotive** (sure): moving like a bus or train at once (the home's on-board look runs now; Fastest trip's look
    counts it as moving); a trip waiting for the one you get on, at its first stop or a change, looks at once instead of after 7 s;
    leaving one of your stations, the first look after 12 s instead of 35);
  - **walking, running or cycling** (sure) under 12 m/s (43 km/h) isn't a vehicle, whatever the fixes say (faster:
    you're walking down a moving train);
  - **standing or walking about** (sure), the fixes not moving, waiting for the one you get on (a leg's first stop with
    nothing found yet, or at a change) and further from the stop it goes to than its wake distance (by time: the
    reach) + 2 km: the rough GPS (100 m, every 50 m) and looks every 15 s instead of 7; anything else, the best at once;
  - **automotive for 3 minutes** on a confirmed ride: the far tier from 6 minutes at full speed beyond the wake point
    instead of 8, without the extra kilometre to switch on;
  - live updates only while a trip runs or the home is in front with no trip; else one history question (the last
    15 minutes) on a wake-up (leaving one of your stations); no loop of its own. Ride log: `motion · automotive
    (high)`, `motion · automotive: looking for the one you're on now`, `gps · waiting, standing or walking about
    (motion): 100 m, every 50 m`.
