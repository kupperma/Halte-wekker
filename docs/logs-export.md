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
