# Reliability: quick on a weak connection, and the right bus or train in a crowd

Design, 15 November 2026. iPhone app only (`ios/`). The relay (`relay/`) and CI (`.github/`) stay as they are.

Source: `.superpowers/reliability/analysis.md`, a root-cause analysis with file:line references (checked against HEAD 13b6bc2: they hold to within a line). N1–N13 (network causes), W1–W8 (matcher weaknesses), S1–S10 (matching scenarios) and D1–D12 (tasks) refer to it. **[field]** marks what code can't settle; the field log below is how we settle it.

## Why

The user rides Veghel ⇄ Breda by bus and train every day and asked to "rigorously test the trip planning app and improve it". Two problems come back often:

1. **Long loading on a bad connection.** Nothing is saved on disk, so every screen starts empty after launch, and a flip of the planning key (indoor GPS jumping around the 500 m BUas radius) empties lists that had data. Screens wait for their slowest request and many requests are chained (the planner makes 8 in a row). A request has no total time limit: a 9 s idle timeout plus a stacked retry is ≥ 16.6 s, and background requests wait up to 12 s behind urgent ones. Fastest trip throws away answers that already arrived when its 25 s limit fires. A failed station lookup is remembered as "no station" for 10 minutes.
2. **Confusion where many vehicles are around** (several buses, several trains, buses beside trains). The matcher compares one moment, in metres, with a timetable-derived position. That favours buses over trains (half a minute off at train speed is 900 m), never checks that you're on the vehicle's road or at a possible speed, ignores whether its times are live, compares old fixes with where vehicles are *now*, and once wrong it rarely recovers (a bus leg never considers a train).

He wants it "quick and snappy even on 2 bars of 5G", and fixed thoroughly. He isn't travelling tomorrow: quality beats speed.

## Goals

- **First useful content within 300 ms** on every screen that has had an answer before (a saved answer). Never a blank screen when an answer was ever seen.
- **No screen waits for its slowest request.** At most 1 request in sequence before the first live content (2 for "what am I on").
- Every request ends within its budget (below).
- The vehicle it picks **moves with you**: on its path, going its way, at a possible speed, keeping pace with its own times. Compared in **seconds off its times**, not metres.
- Once a vehicle is shown, it changes only when another is clearly better for a while.
- Every behaviour change is pinned by a unit test in `HaltewekkerTests`.
- What happens in the field is recorded on the phone, so the thresholds can be tuned.

## Non-goals

- Relay changes (D12) and what depends on them (N10, N11): streaming, smaller NS answers, Transitous via the relay with HTTP/3, pre-warming connections. Later.
- An offline timetable. The 300 ms content comes from saved answers only.
- New screens or redesigns: only small labels and one Settings section.
- The watched-train and watched-line checks (`Watch.swift`, `LineWatch.swift`) stay sequential: few requests, all background.

## Anti-goals: it must never

- Empty a list that had content because the planning key flipped.
- Show a saved answer without saying how old it is, or show a departure that has left.
- Plan a walk from the railway while you're on a moving train.
- Switch the vehicle shown on the strength of timetable-only times, or after one good look.
- Let a partial Fastest trip answer send a "Faster:" or "Too late" notification.
- Log a place, a coordinate or a query string.
- Retry after a timeout, or retry more than once.

## Rulings (binding)

- Scope: D1–D11. D12 (relay) is out of scope: the Worker deploys from GitHub and can't be verified here.
- D7/D8 (new vehicle matcher) are **on by default**. A Settings switch **"Classic vehicle matching"** (persisted in `UserDefaults`) restores today's behaviour. D9 decision logging is viewable in Settings next to the freeze log. D5 (pure code and tests) and D9 come before D7/D8 are wired.
- D10 (saved answers on disk): shown at once with an **"as of 08:12"** label, departed items filtered out, refreshed behind; **no wiping on planning-key change**.
- Budgets as below.
- Every behaviour change pinned by unit tests in the hostless XCTest target `HaltewekkerTests`. New pure files go into its `sources:` list in `ios/project.yml`; the Recomp entries stay.
- No local Swift toolchain: builds and tests run in CI on push to `claude/cool-mendel-odsmk9` ("Unit tests", then "Build (unsigned)"). Releases come only from `main`.
- English UI copy. No new entitlements. iOS 17. No third-party packages.
- Small tasks; the app builds and works after every one.
- Last task: `MARKETING_VERSION: "0.18.0"`, `CURRENT_PROJECT_VERSION: "83"` (Recomp is assumed to ship as 0.17.0 / 82).

## Budgets

| Lane | Used for | Idle (no byte for) | Total (retry included) | Retries | Pause before the retry |
|---|---|---|---|---|---|
| urgent | someone waits: Fastest trip, "what am I on", matching during a ride or Fastest trip | 4 s | 8 s | 1 | 0.3 s |
| background | boards, home panels, planner, next departures, NS, school alarm | 8 s | 15 s | 1 | 1.0 s |

- Retry only after a failure that came back **within 2 s** (connection lost, can't connect, host not found, DNS, TLS, HTTP 5xx), and only with **≥ 3 s of the total left** after the pause. Never after a timeout, "offline", a cancellation or a 4xx.
- HTTP 429: wait `Retry-After` seconds (at most 10; missing or not a number: the lane's pause), only with ≥ 3 s left after it.
- A background request waits **at most 2 s** while an urgent one is in flight (was 12 s).
- First content ≤ 300 ms from a saved answer. ≤ 1 request in sequence before the first live content; 2 for "what am I on".

## How requests go out

- **Net** (new): two `URLSession`s, urgent and background, with the idle and total timeouts and `waitsForConnectivity = false`. `Transit.get` and `NSStore.fetch` go through `Net.response`. It enforces the total itself (a timer races the attempts, because a session's resource timeout is per attempt), applies the retry rule and the 2 s gate, and returns status and data, so callers keep judging HTTP codes as today.
- **Remembered answers** (`Memo`): a station lookup is remembered 10 minutes only when it was answered; a failure is never remembered (N8). `/v5/trip` is remembered 20 s and simultaneous asks share one request (N9): at most one `/v5/trip` per trip per 20 s. The live bus map shows the last known copy of the trip at once, then asks again.
- **Each list as it arrives** (`Progressive`): independent requests run at once and each list shows when its own answer is in. This covers the home panels; the board's ride times (4 plans in parallel, no longer holding back the board); the planner (2 levels, each in parallel, shown before NS details); the next departures on a ride (plans and board together, NS after); NS details (boards, crowding and sizes in parallel); and the home screen's 30 s loop, split into one loop per refresher.
- **Fastest trip**: the plan from your spot shows as soon as it's in, and the station plan follows. At the 25 s limit it keeps what arrived. A partial answer only fills an empty screen. Nearest-stop plans and Be-there-by plans run in parallel.
- **"What am I on"** plans from the next stop the live map already gives while it fetches the vehicle's stops: 2 requests in sequence instead of 3.
- **Fastest trip with nothing on screen** backs off 4, 8, 16, 30 s (back to 4 after an answer), and doesn't ask at all while iOS says there's no connection (N13).

## Saved answers (D10)

- **What**: next trips (per planning key); the Veghel board, its ride times and the three panels (per direction); the boards near you (with their stops and where they were asked); the next departures before boarding and at a change (per leg key); Fastest trip's last answer (per destination).
- **Where**: one JSON file per key in `Caches/answers/`, written after each live answer that has content. An unreadable file is deleted and ignored.
- **Shown at once**, before any request, minus what has left (more than a minute ago), with **"as of 08:12"** where the list says when it was updated. The live answer replaces it. An empty live answer keeps what's shown (as today).
- Trips "from here" and boards near you are used only within 300 m of where they were asked. Fastest trip's are used within 400 m and 30 minutes. Everything else is used for up to 12 h; departed items drop out anyway.
- **On a planning-key change** the new key's saved answer is shown if there is one. Otherwise, when only the start changed (usual ⇄ here, same direction and destination), the lists stay, marked "as of". Only a different direction or destination with nothing saved shows "Loading…", because the old lists answer another question. The panels depend only on the direction, so they stay when the direction stays.

## Matching model

**Inputs.** Your fixes: the last 120 s, accuracy ≤ 150 m. Vehicle tracks: per trip, its stop-to-stop pieces with departure, arrival, path and live flag. They come from the live map (`/v1/map/trips`, now also reading `realTime`, the `to` stop and every trip of a shared piece, S9), or from a trip's own stops and road (`/v5/trip`).

**1. Evidence**, per vehicle. Use the fixes of the last 30 s. Project each fix on the vehicle's path and compare it with where the vehicle's times put it **at that fix's own time** (S7, W8). This gives:
- cross-track: the median of the last 3 fixes;
- your progress along its path;
- offset: your along-position minus its timetable along-position at the last fix;
- drift: the change of the offset per second;
- your speed and its timetable speed;
- **steady**: your speed in the first and second half of the window are within 30 % of each other, both ≥ 3 m/s.

**2. Hard tests**, in this order. The first failure is the reason.

| # | Test | Reject | Rule |
|---|---|---|---|
| 1 | enough evidence | tooFewFixes | ≥ 3 fixes spanning ≥ 20 s (W5, S6) |
| 2 | on its path | offItsPath | cross-track ≤ max(60 m, 1.5 × median accuracy). A path without shape (every piece only 2 points): ≤ max(250 m, 1.5 × accuracy) |
| 3 | going its way | wrongWay | progress ≥ −20 m. No GPS course needed (S3) |
| 4 | a possible speed | implausibleSpeed | bus: your speed ≤ 31 m/s (Dutch buses are limited to 100 km/h). When steady and its speed is ≥ 5 m/s: your speed ≥ its speed ÷ 3 |
| 5 | not standing while you go | standing | when you moved ≥ 40 m, it moved ≥ a fifth as far by its times (S6) |
| 6 | moves with you | drifting | when steady: \|drift\| ≤ max(3 m/s, ¼ of your speed) (S1, S2) |
| 7 | near its times | tooFarFromTimes | \|offset\| ≤ today's allowed distance: train speed × 60 clamped to 600–2500 m, bus speed × 45 clamped to 400–1000 m |

- With no time position at any fix the reject is **noTimes**.
- Tests 4 (the ratio part), 5, 6 and 7 use the timetable. For a **timetable-only vehicle that is already a candidate** (choosing between candidates, the still-the-same-bus check, looking for the real one), they are skipped: its times say little (S5).
- The drift and ratio tests run only when you're **steady**. Timetable positions move at an even speed, so they never match a vehicle that is speeding up or slowing down at a stop (S4).

**3. Cost**: seconds off its times = |offset| ÷ max(5 m/s, its speed). The planned or watched vehicle gets 45 s off (S10).

**4. Decide, with hysteresis** (S5, S8).
- **Nothing shown yet** (finding the real one):
  - one candidate → that one;
  - the best is ≥ 60 s better than the second and both are live → the best;
  - otherwise undecided: up to 3 stay in the running (those within 60 s of the best; the best three if either of the best two is timetable-only).
- **One shown**: keep it while
  - it is the best; or
  - it or the best is timetable-only and it still passes the hard tests; or
  - the best beats it by less than 60 s.
- **Switching**: only after the same other vehicle has been ≥ 60 s better (or the shown one failed the hard tests) in **3 looks in a row spanning ≥ 45 s**. Any break restarts the count.
- **Dropping**: a candidate failing the hard tests in 2 looks in a row is dropped. The shown one is never dropped this way; the switching rule covers it.
- **After 12 minutes of choosing**, it keeps the one shown (as today).

**5. One fix only** (the home screen has no fix history). The same path test, a direction test by GPS course (75°, as today), the bus speed limit and the times test, all at the fix's own time. Cost as above.

**Where it's used**

| Place | Today | New |
|---|---|---|
| `matchVehicles` (ride detection, Fastest trip boarding, idle line watch) | mean metres of the last 4 fixes vs timetable positions | evidence + hard tests + seconds, planned bonus |
| `onBoardTrips` (home, Fastest trip's first look) | one fix vs the position *now* | with ≥ 20 s of fixes: evidence; else the one-fix judge at the fix's time |
| `vehiclesByRoad` (going the wrong way) | lateness vs now | lateness vs the fix's time |
| `findBusYoureOn` | first passing vehicle in list order, planned kind only | all judged; the best only if clearly best, else they stay candidates; the other kind too when the current one moves at the wrong speed (Fastest-trip trips only) |
| `resolveCandidates` | metres off times; one road limit for all | hard tests per candidate + decide |
| `checkSameBus` | within 300 m (bus) / 700 m (train) of any part of its route | hard tests on its own path and times |
| one-look thresholds | 150 / 250 / 350 / 200 / 300 / 400 m | 15 / 20 / 30 / 0 / 60 / 40 s |

Every number here is a starting value, to be tuned from the field log **[field]**.

## Classic vehicle matching

Settings → "Vehicle matching" → **"Classic vehicle matching"**. It is off by default (`UserDefaults` key `classicMatching`). When on, every call site in the table above runs today's code, and the live map reads only the first trip of a piece. Network and saved-answer changes don't depend on it. The field log keeps logging either way: in metres for classic, in seconds for the new matcher.

## Field log (D9)

- **Every request**: path (no query), lane, status or error, bytes, seconds, attempts.
- **Every matching look**: where (detect, board, confirm, on board, find, choose, same bus), each vehicle (line·last 4 of the trip id, live or timetable, cost or reason), and the outcome.
- The last 400 entries, newest first, in `UserDefaults`. Written at most every 5 s, and when the app goes to the background.
- Settings, right after "When the app froze": the switch, a link to the log, "Copy the log" and "Clear".
- On the phone only. No coordinates.

## On a moving train (N7)

At home, it may not tell within 7 s which vehicle you're on. If you're then going ≥ 8 m/s (or the speed is unknown and you moved in the last 30 s), it doesn't plan a walk from where you are. It keeps the trips it had and says **"On the move: finding what you’re on…"**.

## Copy (exact)

- "as of 08:12" (24-hour clock)
- Fastest trip, while showing a saved answer: "as of 08:12 · checking again…"
- "On the move: finding what you’re on…"
- Fastest trip without a connection: "No internet connection right now. It looks again as soon as you’re back online."
- Settings section "Vehicle matching":
  - toggle "Classic vehicle matching", with the footer "Picks buses and trains the way the app did before version 0.18. Turn it on only if the new way keeps choosing the wrong one, and send the log.";
  - link "Connection and matching log";
  - on the log screen: "Nothing logged yet.", "Copy the log" (then "Copied: paste it in the chat"), "Clear", and the footer "The last 400 requests and vehicle choices, kept on this phone only. No places or coordinates."

## Testing

- The rules live in pure files compiled straight into the hostless `HaltewekkerTests`: `Net.swift` (Foundation and Network), `Memo.swift`, `Snapshots.swift`, `Geo.swift`, `VehicleMatch.swift`, `FieldLog.swift`. App files keep thin calls. Conversions from CoreLocation and `LiveTrip` live in the app-only `MatchBridge.swift`.
- Network behaviour is tested with an injected `send` closure and scaled-down budgets: no network, no `URLProtocol`.
- Matching is tested on a straight railway at latitude 51.59 (longitude 4.70–4.80, about 6.9 km), with roads 50 m and 200 m north, and fixes every 2 s at 20 m accuracy. The tests cover S1–S8 and S10 from the analysis, plus the plan's Review Focus cases.
- Who waits for whom is pinned through `Progressive`. Real speed on 2 bars is **[field]**: the log measures it.

## Later

- D12, the relay: streaming answers, NS answers cut to the fields used, Transitous through the relay with HTTP/3 and a direct fallback, connections pre-warmed when the app opens (N11). Also smaller answers: fewer departures, next stops only where needed, a lower live-map zoom (N10).
- **[field]**, from the log:
  - real sizes and times per endpoint;
  - the share of timetable-only vehicles around Breda;
  - GPS accuracy and course in trains;
  - how far apart parallel road and rail shapes are, and how often shapes are missing;
  - how people read "as of";
  - every threshold above.
- The watched-train and watched-line checks in parallel.
