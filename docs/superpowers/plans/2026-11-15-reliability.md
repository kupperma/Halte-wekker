# Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Haltewekker quick on a weak connection (request budgets, parallel and progressive loading, saved answers shown at once) and make it pick the bus or train that moves with you, with a "Classic vehicle matching" switch and a field log in Settings.

**Architecture:** The rules live in new Foundation-only files that the hostless `HaltewekkerTests` bundle compiles directly:
- `Net.swift`: lanes, budgets, retry, gate, `within`, `withPartials`, `Progressive`, backoff;
- `Memo.swift`, `Snapshots.swift`;
- `Geo.swift`, `VehicleMatch.swift`: evidence → hard tests → cost in seconds → decide with hysteresis;
- `FieldLog.swift`.

The existing stores (`Transit`, `LiveStore`, `TripManager`, `GoStore`, `Planner`, `NSStore`) keep thin calls. The app-only `MatchBridge.swift` converts CoreLocation and `LiveTrip` values. Every matching change is behind `MatchSettings.classic()`.

**Tech Stack:** Swift 5 language mode (Xcode 26), SwiftUI, iOS 17, URLSession, Network (`NWPathMonitor`), XCTest, XcodeGen, GitHub Actions (macos-15).

**Spec:** `docs/superpowers/specs/2026-11-15-reliability-design.md`. Read it first: it holds the thresholds, the decide rules and the exact copy. Background with file:line evidence: `.superpowers/reliability/analysis.md`.

## Global Constraints

- iOS 17.0, SwiftUI, `SWIFT_VERSION 5.0`. No third-party packages, no new entitlements, no new Info.plist keys.
- UI copy is English and exactly as in the spec's "Copy" section, with typographic apostrophes (’) as in the rest of the app.
- **Pure files**: `Net.swift`, `Memo.swift`, `Snapshots.swift`, `Geo.swift`, `VehicleMatch.swift` and `FieldLog.swift` import only `Foundation` (`Net.swift` also `Network`). They may not reference app types (`Ride`, `DoorTrip`, `Place`, `Transit`, `Fmt`, `LiveTrip`, `CLLocation`…).
- The task that creates a pure file appends it to `HaltewekkerTests` → `sources:` in `ios/project.yml`. Keep every existing entry: `Tests` and the `App/Recomp*.swift` and `App/OpenFoodFacts.swift` files.
- Do not touch `relay/` or `.github/`.
- Tests never use the network, the real clock or the real Caches folder. Inject `send` closures, clocks, `UserDefaults(suiteName:)` and temporary directories. Timing assertions allow at least twice the expected time (CI simulators are slow).
- Budgets, verbatim from the spec:
  - urgent: idle 4 s, total 8 s, 1 retry after 0.3 s;
  - background: idle 8 s, total 15 s, 1 retry after 1.0 s;
  - retry only after a failure that came back within 2 s, with ≥ 3 s left; never after a timeout;
  - 429: `Retry-After`, at most 10 s;
  - background waits at most 2 s behind urgent;
  - first content ≤ 300 ms from a saved answer;
  - ≤ 1 request in sequence before the first live content (2 for "what am I on").
- **The new matcher is the default.** `UserDefaults` key `"classicMatching"` = true runs today's code at every matching call site. Each such site reads `MatchSettings.classic()` and keeps today's body in the classic branch, unchanged.
- **Logs** hold paths, lanes, statuses, sizes, seconds, attempts, lines and the last 4 characters of trip ids. Never coordinates or query strings.
- **Saved answers** go to `Caches/answers/<key>.json`. They are never shown without "as of HH:mm", and departed items (more than 60 s ago) are dropped first.
- **No local Swift toolchain** (this container is Linux). Each task writes its tests and code together and verifies them with one push to `claude/cool-mendel-odsmk9`. Expected in the "Build iPhone app" run: `** TEST SUCCEEDED **` and `BUILD SUCCEEDED`, and no release (releases only come from `main`). Read the run with the GitHub MCP tools `actions_list` and `get_job_logs`.
- Line numbers below are at HEAD 13b6bc2 and move as earlier tasks land. Find each spot by the function named.
- Commit messages start with "Reliability: ".

## Review Focus

1. **Zero-length pieces.** Minute-rounded GTFS times give consecutive stops the same minute, so departure == arrival. Expect no NaN or division by zero: the vehicle sits at the piece's end, and its cost is finite. Test in Task 8 (`test_zeroDurationPiece`).
2. **Vehicle paths without a road shape.** Straight 2-point chords between stops are common for buses. You 150 m off the chord must not count as "off its path"; the same distance on a shaped path must. Test in Task 8 (`test_unshapedPathLenient`).
3. **Bad fixes in the window.** An indoor fix at 500 m accuracy, 2 km away, among good ones is ignored; the verdicts are identical without it. Test in Task 8 (`test_badFixesIgnored`).
4. **Leaving a screen mid-request** (the task is cancelled). It stops at once, never retries, and isn't reported as a timeout. Test in Task 1 (`test_cancelledNotRetried`).
5. **A corrupt or older-format saved answer.** It is ignored and deleted, without a crash; the screen behaves as if nothing was saved. Test in Task 6 (`test_corruptSnapshotIgnored`).

## Files

| File | Responsibility | Task |
|---|---|---|
| `ios/App/Net.swift` (new, pure) | lanes, budgets, sessions, retry rule, gate, `within`, `withPartials`, `Progressive`, backoff, connection monitor | 1, 3, 5, 9, 13 |
| `ios/App/Memo.swift` (new, pure) | remembered answers with expiry and shared fetches | 2 |
| `ios/App/Snapshots.swift` (new, pure) | saved answers on disk, "as of", key-change rule | 6 |
| `ios/App/Geo.swift` (new, pure) | flat-earth distance, bearing, projection on a path | 8 |
| `ios/App/VehicleMatch.swift` (new, pure) | tracks, evidence, hard tests, cost, rank, decide, rules, settings | 8–13 |
| `ios/App/FieldLog.swift` (new, pure) | the field log and its line formats | 9 |
| `ios/App/MatchBridge.swift` (new, app-only) | `CLLocation`/`VehicleSegment`/`LiveTrip` → pure types | 10 |
| `ios/Tests/*Tests.swift` (new) | one file per pure file, plus `MatchFixtures.swift` | each task |

---

### Task 1: Time limits per request, one quick retry, a short wait behind urgent ones (D1: N4, N6)

**Files:**
- Create: `ios/App/Net.swift`, `ios/Tests/NetTests.swift`
- Modify:
  - `ios/App/Transit.swift:156-244` (`within`, `urgent`, `Flight`, `urgentSession`, `get`)
  - `ios/App/NS.swift:87-94` (`fetch`) and its callers at `:110`, `:139`, `:158`
  - `ios/App/Go.swift:194, 208, 219, 458`
  - `ios/App/Live.swift:336`
  - `ios/App/TripManager.swift:698`
  - `ios/project.yml` (add `App/Net.swift`)

**Interfaces:**
- Produces:
  ```swift
  enum Lane: String, Sendable { case urgent, background; var budget: Budget { get } }
  struct Budget: Equatable, Sendable {
      let idle: TimeInterval; let total: TimeInterval; let retries: Int; let backoff: TimeInterval
      let fastFailure: TimeInterval   // only a failure that came back within this is retried
      let minLeft: TimeInterval       // …and only with this much of `total` left after the pause
      static let urgent = Budget(idle: 4, total: 8, retries: 1, backoff: 0.3, fastFailure: 2, minLeft: 3)
      static let background = Budget(idle: 8, total: 15, retries: 1, backoff: 1.0, fastFailure: 2, minLeft: 3)
  }
  struct NetAnswer: Sendable { let data: Data; let status: Int; let contentType: String?; let attempts: Int; let seconds: Double }
  enum Net {
      typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)
      static let gateWait: TimeInterval = 2
      static let flight: Flight                      // moved from Transit.swift:172-179, same API: begin(), end(), busy
      static func configuration(for lane: Lane) -> URLSessionConfiguration
      static func session(for lane: Lane) -> URLSession
      static func retryDelay(status: Int?, error: URLError.Code?, retryAfter: String?,
                             took: TimeInterval, elapsed: TimeInterval, attempt: Int, budget: Budget) -> TimeInterval?
      static func response(_ request: URLRequest, lane: Lane, budget: Budget? = nil,
                           gate: TimeInterval = gateWait, send: Send? = nil) async throws -> NetAnswer
      static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T?   // moved from Transit.swift:157
  }
  extension Transit { static func raw(_ path: String, _ items: [URLQueryItem]) async throws -> Data }   // `get` = raw + JSONSerialization
  ```

- [ ] **Step 1: Write `ios/Tests/NetTests.swift`.**
  - Setup: a scaled budget `let quick = Budget(idle: 0.4, total: 0.8, retries: 1, backoff: 0.05, fastFailure: 0.2, minLeft: 0.3)`, and an actor `Calls` that records each `send` time. Responses are `HTTPURLResponse(url:statusCode:httpVersion:headerFields:)`.
  - `test_configuration`:
    - urgent → `timeoutIntervalForRequest` 4, `timeoutIntervalForResource` 8, `waitsForConnectivity` false, `httpMaximumConnectionsPerHost` 6;
    - background → 8, 15, false.
  - `test_retryDelay` (urgent unless stated; `attempt: 0`, `took: 0.1`, `elapsed: 0.1` unless stated):

    | Input | Result |
    |---|---|
    | status 503 | 0.3 |
    | status 503, took 2.5 | nil |
    | `.networkConnectionLost` | 0.3 |
    | `.networkConnectionLost`, background | 1.0 |
    | `.networkConnectionLost`, elapsed 5.0 | nil |
    | `.timedOut` | nil |
    | `.notConnectedToInternet` | nil |
    | `.cancelled` | nil |
    | status 400 | nil |
    | status 429, `Retry-After` "3" | 3 |
    | status 429, "6" | nil |
    | status 429, "6", background | 6 |
    | status 429, "30", background | 10 |
    | status 429, nil, background | 1.0 |
    | status 429, "Wed, 21 Oct 2026 07:28:00 GMT", background | 1.0 |
    | status 503, `attempt: 1` | nil |
  - `test_fastFailureRetriedOnce`: the first send throws `URLError(.networkConnectionLost)` at once and the second returns 200 "ok" → data "ok", `attempts` 2, 2 sends, the second ≥ 0.05 s after the first.
  - `test_totalLimit`: send sleeps 5 s → throws `URLError` `.timedOut` within 1.6 s; 1 send.
  - `test_noRetryAfterTimeout`: send throws `.timedOut` after 0.25 s → throws `.timedOut`; 1 send.
  - `test_noRetryWhenTimeIsUp`: send throws `.networkConnectionLost` after 0.6 s → throws; 1 send.
  - `test_429RetryAfterZero`: 429 with `Retry-After: 0`, then 200 → status 200, `attempts` 2.
  - `test_400NotRetried`: 400 → `NetAnswer.status` 400, `attempts` 1.
  - `test_backgroundGate`: an urgent `response` whose send sleeps 1 s is in flight. A background `response` with `gate: 0.2` and an instant send finishes in < 0.6 s from its start.
  - `test_within`: `Net.within(0.1) { sleep 1 s; return 1 }` → nil in < 0.4 s; the work saw `Task.isCancelled` (set a flag after its `try? await Task.sleep`).
  - `test_cancelledNotRetried` (Review Focus 4): run `response` in a `Task` whose send sleeps 0.5 s; cancel after 0.1 s → it throws `CancellationError` or `URLError(.cancelled)` within 0.4 s; 1 send.

- [ ] **Step 2: Implement `Net.swift`** to these signatures.
  - `retryDelay` follows the spec's Budgets rules:
    - `attempt >= budget.retries` → nil;
    - 429 → `min(10, max(0, Double(retryAfter)))`, or `backoff` when that isn't a number; retry only if `total − elapsed − delay ≥ minLeft`;
    - 5xx, or `.networkConnectionLost`, `.cannotConnectToHost`, `.cannotFindHost`, `.dnsLookupFailed`, `.secureConnectionFailed` → `backoff`, only if `took ≤ fastFailure` and `total − elapsed − backoff ≥ minLeft`;
    - everything else → nil.
  - `response`:
    - a background call polls `flight.busy` every 250 ms for at most `gate` seconds; an urgent call wraps the work in `flight.begin()`/`end()`;
    - each attempt uses a copy of the request with `timeoutInterval = budget.idle`;
    - attempts and pauses race a `budget.total` timer in a throwing task group; when the timer wins it throws `URLError(.timedOut)` and cancels the attempt;
    - a cancellation is rethrown at once;
    - every HTTP status is returned (a non-HTTP response counts as 200). A transport failure that isn't retried throws its `URLError`.
  - `send` defaults to `session(for: lane).data(for:)`. The two sessions are built once from `configuration(for:)`.

- [ ] **Step 3: Route the callers through it.**
  - `Transit.swift`:
    - delete `within`, `Flight`, `flight` and `urgentSession` (156-199);
    - `raw` builds the URL and the User-Agent and calls `Net.response(req, lane: urgent ? .urgent : .background)`;
    - status 429 or ≥ 500 → throw `URLError(.badServerResponse)`;
    - keep today's `trouble.note` texts for urgent calls (230-238);
    - `get` parses `raw`'s data.
  - `NS.swift` `fetch(_ path: String)`: drop the `timeout` parameter (and `timeout: 15` at `:139`). Use `Net.response(…, lane: .background)` and keep `.reloadIgnoringLocalCacheData`. Return `(json, status)` as today; a thrown error → `(nil, -1)`.
  - `Transit.within` → `Net.within` at Go.swift 194, 208, 219, 458 and Live.swift 336.
  - `TripManager.matchVehicles` (698): wrap `Transit.vehicles` in `Transit.$urgent.withValue(going || isRiding)`, so the Fastest trip and ride looks aren't stuck behind background calls (N6).
  - `project.yml`: append `App/Net.swift`.

- [ ] **Step 4: Commit and push, then verify CI.**
  ```bash
  git add ios/App/Net.swift ios/Tests/NetTests.swift ios/App/Transit.swift ios/App/NS.swift ios/App/Go.swift ios/App/Live.swift ios/App/TripManager.swift ios/project.yml
  git commit -m "Reliability: time limits per request, one quick retry, a short wait behind urgent ones"
  git push origin claude/cool-mendel-odsmk9
  ```
  Expected: `** TEST SUCCEEDED **` and `BUILD SUCCEEDED`.

### Task 2: Remember only real answers, and ask for each trip once (D2: N8, N9)

**Files:**
- Create: `ios/App/Memo.swift`, `ios/Tests/MemoTests.swift`
- Modify:
  - `ios/App/Transit.swift:486-523` (`stationAt`, `nearStops`), `:635-677` (`tripStops`, `liveTrip`), `:735-750` (delete `StationMemo`)
  - `ios/App/LiveBus.swift:231-242` (`run`)
  - `ios/project.yml` (add `App/Memo.swift`)

**Interfaces:**
- Consumes: `Transit.raw` (Task 1).
- Produces:
  ```swift
  actor Memo<K: Hashable & Sendable, V: Sendable> {
      init(ttl: TimeInterval, limit: Int = 200, now: @escaping @Sendable () -> Date = { Date() })
      func get(_ key: K, fetch: @escaping @Sendable () async -> V?) async -> V?   // fresh value, else one shared fetch; nil is never stored
      func peek(_ key: K) -> V?                                                  // the stored value at any age
  }
  extension Transit {
      struct StationAnswer: Sendable { let stop: NearStop? }
      static let stations: Memo<String, StationAnswer>     // ttl 600
      static let tripAnswers: Memo<String, Data>           // ttl 20, raw /v5/trip answers
      static func nearStopsAnswer(_ c: CLLocationCoordinate2D) async -> [NearStop]?   // nil when the request failed
      static func cachedLiveTrip(_ tripId: String) async -> LiveTrip?               // from `tripAnswers.peek`, no request
  }
  ```

- [ ] **Step 1: Write `ios/Tests/MemoTests.swift`.** Use a movable test clock (`final class TestClock: @unchecked Sendable { var date: Date }`) and an actor counting fetches.
  - `test_failureNotRemembered`: `get("a")` with a fetch returning nil → nil. Then `get("a")` with a fetch returning 1 → 1. 2 fetches.
  - `test_sharedFetch`: 5 concurrent `get("a")` calls, the fetch sleeps 0.2 s and returns 7 → all five get 7; 1 fetch.
  - `test_expiry`: ttl 20. Stored at t0 (value 1). At t0+19 → 1 without fetching. At t0+21 → fetches again and returns 2.
  - `test_peekIgnoresAge`: stored at t0; at t0+100, `peek("a")` → 1; `peek("b")` → nil.
  - `test_limitDropsOldest`: limit 2, store a, b, c → `peek("a")` nil, `peek("c")` 3.

- [ ] **Step 2: Implement `Memo`.** Store `[K: (V, Date)]` plus in-flight `[K: Task<V?, Never>]`. Past `limit`, drop the oldest stored entry.

- [ ] **Step 3: Use it in `Transit`.**
  - `nearStopsAnswer`: today's `nearStops` body, returning nil when `get` throws or the JSON isn't a list. `nearStops` becomes `await nearStopsAnswer(c) ?? []`.
  - `stationAt`: same key. `await stations.get(key) { await nearStopsAnswer(c).map { StationAnswer(stop: $0.first { $0.rail && $0.meters < 350 }) } }?.stop`.
  - Delete `StationMemo`.
  - `tripStops` and `liveTrip` read `/v5/trip` through `tripAnswers.get(tripId) { try? await raw("/v5/trip", [.init(name: "tripId", value: tripId)]) }`, then parse as today. Move the `liveTrip` parsing into `private static func parseLiveTrip(_ json: [String: Any]) -> LiveTrip?`.
  - `cachedLiveTrip` = `peek` + `parseLiveTrip`. Demo trips keep `Demo.liveTrip`.
- [ ] **Step 4: `LiveBusSheet.run`.** Before the loop, show a cached copy: `if trip == nil, let t = await Transit.cachedLiveTrip(target.tripId) { trip = t; mine = findMine(t); fit(t, Date()) }`. The loop still fetches at once (`last` starts at `.distantPast`).
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: remember only real answers, and ask for each trip once". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 3: The home screen shows each list as soon as it's in (D3: N2, N3, N12, home)

**Files:**
- Create: `ios/Tests/ProgressiveTests.swift`
- Modify:
  - `ios/App/Net.swift` (add `Progressive`)
  - `ios/App/Live.swift:157-163` (`plans`), `:300-404` (`refresh`), `:407-424` (`boardGrades`)
  - `ios/App/Screens.swift:196-218` (the home loop) and `:224`

**Interfaces:**
- Produces:
  ```swift
  enum Progressive {
      /// Runs every job at once; after each one finishes, calls `publish` with everything so far (in finishing order); returns it all.
      static func gather<T: Sendable>(_ jobs: [@Sendable () async -> [T]], publish: @escaping @Sendable ([T]) async -> Void) async -> [T]
      /// Runs every job at once; results in the jobs' order.
      static func all<T: Sendable>(_ jobs: [@Sendable () async -> T]) async -> [T]
  }
  ```
  In `LiveStore`: `private struct PanelJob { let from: Place; let to: Place; let modes: String; let count: Int; let maxTransfers: Int }` and `private func loadPanelsIfDue(_ dir: Direction, key: String, force: Bool) async`.

- [ ] **Step 1: Write `ios/Tests/ProgressiveTests.swift`.**
  - `test_gatherPublishesAsTheyCome`: jobs returning `[1]`, `[2]` and `[3]` after 0.05, 0.1 and 0.6 s:
    - the first publish comes before 0.25 s with `[1]`;
    - the second comes before 0.35 s with 2 items;
    - 3 publishes in all;
    - it returns 3 items after ≥ 0.6 s.
  - `test_allKeepsOrderAndRunsAtOnce`: jobs returning 0, 1 and 2 after 0.3, 0.1 and 0.2 s → `[0, 1, 2]` in < 0.55 s.
- [ ] **Step 2: Implement `Progressive`** with `withTaskGroup`. `all` collects `(index, value)` pairs and sorts by index.
- [ ] **Step 3: `LiveStore` loads the panels beside the trips, each list on arrival.**
  - In `refresh`, right after `busy = true; loadedFor = key; here = from` (327), start `async let panels: Void = loadPanelsIfDue(dir, key: key, force: force)`. It returns at once when `anywhere` (`here` is already set).
  - The trips flow (329-349) is unchanged, but nothing waits for the panels. Then `await boards`. If `anywhere`, set `panelsUpdated` (as at 352-356). Finally `await panels`.
  - `loadPanelsIfDue` takes today's code from 357 to 403. The 120 s gate, `lastPanels`, `keepBest`, the `emptyRetries` rule, the `NSStore.enrich` task after the trains and `panelsUpdated = Date()` at the end all stay. But each list now publishes as soon as its own answer is in, and only when `loadedFor == key`:
    - going to school: the board; `boardRides` (from `boardGrades`); `trains` (the Eindhoven and Den Bosch jobs through `Progressive.gather`, publishing `keepBest(partial)`); `buas`;
    - going home: `buas`; `trains` (gather); `toVeghel` (gather of the Den Bosch and Eindhoven jobs).
  - An empty answer keeps the last list (as today).
  - `boardGrades`: run the 4 plans (`veghel.ids` × [eindhoven, denBosch], in that order) through `Progressive.all`, then merge in that order, first one wins, as today.
  - `plans(from:…)` (161-163): the plans per destination id go through `Progressive.all`.
- [ ] **Step 4: Split the home loop** (`Screens.swift:196-218`) into four `.task(id: trip.direction)` loops. Each runs `while !Task.isCancelled { if scene == .active { … }; sleep 30 s }`, keeping its `Watchdog.shared.mark` labels:
  - (a) `near.locate(ask: true)`, then `live.refresh(trip.direction, at: near.position)`;
  - (b) `planner.refresh()`, then `autoGo()`;
  - (c) `SchoolAlarm.shared.refresh()`, then `watch.check()`;
  - (d) `updateOutfit()`, then `OutfitStore.shared.refresh()`.

  At `:224`, start the three refreshes as separate `Task`s.
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: the home screen shows each list as soon as it’s in". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 4: Planned trips, next departures and NS details load side by side (D3: N2, N3, the rest)

**Files:**
- Modify:
  - `ios/App/Planner.swift:200-237` (`refresh`), `:241-264` (`buses`)
  - `ios/App/TripManager.swift:1198-1227` (`loadUpcoming`)
  - `ios/App/NS.swift:224-252` (`enrich`)

**Interfaces:**
- Consumes: `Progressive.all` (Task 3). This task adds no logic of its own; its order-keeping and parallelism are pinned by `ProgressiveTests.test_allKeepsOrderAndRunsAtOnce`.

- [ ] **Step 1: `Planner.refresh`.**
  - The two train plans (one per station, in the order [eindhoven, denBosch]) run through `Progressive.all`.
  - `buses(for:)` for the picked trains runs through `Progressive.all`, so the options stay in the picked order.
  - Inside `buses`, `before` and `after` are two `async let`s.
  - Publish `options` (and `inexact`, `pick`, `error`, `updated`, `watchChosen()`) before NS. Then `Task { await NSStore.shared.enrich(…) }` instead of awaiting it at 230.
- [ ] **Step 2: `TripManager.loadUpcoming`.**
  - The plans per destination run through `Progressive.all` (order of `t.to`).
  - For buses, start the board request (1210) as an `async let` before the plans, so both go at once.
  - NS goes in `Task { await NSStore.shared.enrich(…) }`, so `upcomingBusy` clears at once.
- [ ] **Step 3: `NSStore.enrich`.**
  - Boards per station code, crowding per group and train sizes per ride each run through `Progressive.all`. Sizes return `(rideId, TrainSize?)`.
  - Then fill `info` in one pass with today's rules (240-250).
- [ ] **Step 4: Commit and push, then verify CI.** Commit message: "Reliability: planned trips, next departures and NS details load side by side". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 5: Fastest trip shows the first answer that's in and keeps what arrived (D4: N2, N5)

**Files:**
- Modify:
  - `ios/App/Net.swift` (add `withPartials`), `ios/Tests/ProgressiveTests.swift`
  - `ios/App/Transit.swift:329-367` (`tripsFrom`), `:446-473` (`fromNearest`)
  - `ios/App/Go.swift:185-202` (`refresh`), `:216-226` (`latestInTime`)

**Interfaces:**
- Consumes: `Progressive` (Task 3), `Net.within` (Task 1).
- Produces:
  ```swift
  extension Net {
      /// The final value when `work` finishes within `seconds`; else the last value it published (or nil), with timedOut true, and the work is cancelled.
      static func withPartials<T: Sendable>(_ seconds: Double,
          _ work: @escaping @Sendable (_ publish: @escaping @Sendable (T) async -> Void) async -> T,
          partial: @escaping @Sendable (T) async -> Void) async -> (value: T?, timedOut: Bool)
  }
  extension Transit {
      static func tripsFrom(_ c: CLLocationCoordinate2D, to: Place, count: Int = 5, keep: Int = 5,
                            publish: (@Sendable ([DoorTrip]) async -> Void)? = nil) async -> [DoorTrip]
  }
  ```

- [ ] **Step 1: Add the tests to `ProgressiveTests.swift`.**
  - `test_withPartialsKeepsWhatArrived`: the work publishes "a" at 0.05 s, then sleeps 1 s; limit 0.2 → `("a", true)` in < 0.45 s, and `partial` received `["a"]`.
  - `test_withPartialsFinal`: the work publishes "a" and returns "b" at 0.05 s; limit 1 → `("b", false)`.
  - `test_firstPartialAfterOneRequest`: the work is a `Progressive.gather` of two jobs, each counting a "request" (0.05 s and 0.3 s), that publishes. At the first `partial`, the counter of finished requests is 1.
- [ ] **Step 2: Implement `withPartials`.** Keep the last published value in a small actor, and race the work against a timer in a task group.
- [ ] **Step 3: `tripsFrom` hands over what it has.**
  - Move the filter at 352-366 into `private static func keepUseful(_ all: [DoorTrip], here: CLLocation, station: NearStop?, now: Date, keep: Int) -> [DoorTrip]`, unchanged.
  - Start `stationAt` and the from-your-spot plan together. The station plan starts as soon as the station is known.
  - After the spot plan arrives, `await publish?(keepUseful(…))`; when the station plan arrives, publish again; return the final `keepUseful`.
  - `fromNearest`: plan the two picks through `Progressive.all`.
- [ ] **Step 4: `GoStore.refresh` and `latestInTime`.**
  - Replace `Transit.within(25) { tripsFrom }` with `Net.withPartials(25, { publish in await Transit.tripsFrom(c, to: d, count: 6, keep: 8, publish: publish) }, partial: …)`, still inside `Transit.$urgent.withValue(true)`.
  - The partial handler (on the main actor) applies a partial only when `watching, dest == d, onBoard == nil, best == nil` and it isn't empty. It then sets `slow = false` and calls `apply`. So a partial only fills an empty screen and never sends "Faster:" or "Too late".
  - After it returns:
    - with `timedOut` and `best != nil`: keep the screen;
    - otherwise apply `value ?? []`;
    - the "No answer within 25 seconds: a slow connection." text only when timed out with nothing.
  - `latestInTime`: the plans per id run through `Progressive.all`.
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: Fastest trip shows the first answer that’s in and keeps what arrived". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 6: Saved answers on the home screen, shown at once (D10, part 1: N1)

**Files:**
- Create: `ios/App/Snapshots.swift`, `ios/Tests/SnapshotTests.swift`
- Modify:
  - `ios/App/Transit.swift:5, 47, 65, 83, 497`: add `Codable` to `Ride`, `DoorTrip`, `BoardDeparture`, `Heading`, `NearStop`
  - `ios/App/Model.swift:5-36`: `Place: Codable`. Use explicit `CodingKeys` key, name, short, ids, lat, lon, spoken, and put `init(from:)` in an extension so the memberwise init stays.
  - `ios/App/Live.swift`: `PanelTrip` and `BoardRide` get `Codable` (5, 13); `refresh` 312-349; `loadPanelsIfDue` (Task 3); `loadNear` 249-281
  - `ios/App/Screens.swift`: `boardFastestContent` 607-626, `nextPass` 1065-1074, `tripsFold` 1258
  - `ios/project.yml` (add `App/Snapshots.swift`)

**Interfaces:**
- Produces:
  ```swift
  struct Snapshot<T: Codable>: Codable { let at: Date; let value: T }
  final class SnapshotStore: @unchecked Sendable {
      static let shared: SnapshotStore                      // <Caches>/answers
      init(directory: URL)
      func save<T: Codable>(_ value: T, key: String, at: Date = Date())          // atomic write; creates the folder
      func load<T: Codable>(_ type: T.Type, key: String, maxAge: TimeInterval = 12 * 3600, now: Date = Date()) -> Snapshot<T>?   // unreadable → file deleted, nil
      static func fileName(_ key: String) -> String         // outside [A-Za-z0-9._-] → "_", first 120 characters, + ".json"
  }
  struct PlanKey: Equatable, Sendable { let dir: String; let dest: String; let fromHere: Bool
      var text: String { get } }                            // "\(dir)|\(dest)|here" or "…|usual": today's `key` at Live.swift:319
  enum KeyChange: Equatable, Sendable { case showSaved, keep, clear }
  enum Snapshots {
      static func upcoming<E>(_ items: [E], now: Date, grace: TimeInterval = 60, time: (E) -> Date) -> [E]   // time(e) > now − grace
      static func asOf(_ at: Date, timeZone: TimeZone = .current) -> String       // "as of 08:12"
      static func onKeyChange(from old: PlanKey?, to new: PlanKey, hasSaved: Bool) -> KeyChange
      static func closeEnough(saved: (lat: Double, lon: Double)?, here: (lat: Double, lon: Double)?, metres: Double) -> Bool
  }
  ```
  In `LiveStore`:
  - `@Published private(set) var nextAsOf: Date?`, `panelsAsOf: Date?`, `nearAsOf: Date?`
  - `struct SavedTrips: Codable { let trips: [DoorTrip]; let lat: Double?; let lon: Double? }`
  - `struct SavedPanels: Codable { var board: [BoardDeparture]; var rides: [String: BoardRide]; var trains: [PanelTrip]; var buas: [PanelTrip]; var toVeghel: [PanelTrip] }`
  - `struct SavedNear: Codable { let stops: [Transit.NearStop]; let board: [BoardDeparture]; let lat: Double; let lon: Double }`
  - keys `"next|\(key.text)"`, `"panels|\(dir.rawValue)"`, `"near"`

- [ ] **Step 1: Write `ios/Tests/SnapshotTests.swift`.** Each test uses a fresh temporary directory and a test type `struct Dep: Codable, Equatable { let id: String; let time: Date }`.
  - `test_roundTripAndAge`: save 3 deps at t0; load at t0+30 → `at` == t0, 3 items. With `maxAge: 60`, load at t0+61 → nil.
  - `test_firstPaintFiltersDeparted`: a saved board with deps at t0−120, t0+60 and t0+300; `load`, then `upcoming(now: t0)` → 2 items, `at` kept, all in < 100 ms.
  - `test_fileName`: `"next|toSchool||here"` → `"next_toSchool__here.json"`; a key of 300 "x" → 125 characters.
  - `test_corruptSnapshotIgnored` (Review Focus 5): write "not json" at the key's file → `load` nil, and the file is gone afterwards.
  - `test_asOf`: 2026-11-16 07:12 UTC in Europe/Amsterdam → `"as of 08:12"`.
  - `test_onKeyChange`, with `usual = PlanKey(dir: "toSchool", dest: "", fromHere: false)`:

    | old → new | saved | result |
    |---|---|---|
    | nil → usual | yes | `.showSaved` |
    | nil → usual | no | `.clear` |
    | usual → here (same dir and dest) | no | `.keep` |
    | here → usual | yes | `.showSaved` |
    | toSchool → home | no | `.clear` |
    | dest "a" → dest "b" | no | `.clear` |
  - `test_closeEnough`:

    | saved | here | metres | result |
    |---|---|---|---|
    | nil | anything | — | true |
    | 250 m apart | | 300 | true |
    | 450 m apart | | 400 | false |
    | present | nil | — | false |
- [ ] **Step 2: Implement `Snapshots.swift`.**
  - `asOf` uses a `DateFormatter` with `en_US_POSIX` and `"HH:mm"` in `timeZone`.
  - `closeEnough` uses a flat-earth distance (`kx = cos(lat) × 111 320`, `ky = 110 540`).
  - `onKeyChange` follows the table: saved → `.showSaved`; same dir and dest → `.keep`; else `.clear`.
- [ ] **Step 3: `LiveStore`.**
  - Build `PlanKey(dir: dir.rawValue, dest: custom?.id ?? "", fromHere: from != nil)` and keep the last one in `private var loadedKey: PlanKey?`.
  - Replace the wipe at 321-324 with the `onKeyChange` result for the saved `next` answer. That answer is filtered by `first.departure` and used only if `closeEnough(saved: lat/lon, here: from, metres: 300)`.
    - `.showSaved`: `next`, `nextAsOf = at`, `pick = 0`.
    - `.keep`: the lists stay; `nextAsOf = nextAsOf ?? updated`.
    - `.clear`: `next = []`, `nextAsOf = nil`, `pick = 0`.
    - In every case: `nextError = nil; updated = nil; panelsUpdated = nil; lastPanels = .distantPast`.
  - When the direction changed (or on the first load), show the saved panels for the new direction or clear them:
    - board filtered by `cancelled ? scheduled : time`;
    - trips by `trip.first.departure`;
    - `panelsAsOf = at`.
  - On entering "here" mode, keep `nearBoard` only if `nearAt` is within 300 m of `from`. Otherwise show the saved `"near"` answer if it's close enough (`nearAsOf = at`); else clear it.
  - Saving:
    - after a non-empty live `next`: `nextAsOf = nil` and save `SavedTrips` (lat/lon of `from`, nil for the usual start);
    - at the end of a panels round that got any list: `panelsAsOf = nil` and save `SavedPanels`;
    - after `loadNear` gets a non-empty board: `nearAsOf = nil` and save `SavedNear`.
- [ ] **Step 4: The labels in `Screens.swift`.**
  - `boardFastestContent`, under the time chips, and `nextPass`, under the boarding pass: when `live.nextAsOf != nil`, show `Text(Snapshots.asOf(a))` (`BoardInk.sans(10, .regular)`, ink at 0.6 / `HWFont.body(10)`, muted).
  - `tripsFold` (1258): `live.panelsAsOf` shows `"\(Snapshots.asOf(a))."` in place of "Updated at …".
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: the home screen shows its last answers at once, marked as of when". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 7: Saved answers for the next departures and Fastest trip (D10, part 2)

**Files:**
- Modify:
  - `ios/App/TripManager.swift:70-73` (properties), `:1193-1227` (`loadUpcoming`), `:338` (`endTrip` reset)
  - `ios/App/Go.swift:19-35` (properties), `:100-129` (`begin`), `:201-213` (`refresh`), `:1088` (label)
  - `ios/App/Features.swift:744-762` (`TransferList`)
  - `ios/App/Screens.swift:1521, 2006`

**Interfaces:**
- Consumes: `SnapshotStore`, `Snapshots.upcoming/asOf/closeEnough` (Task 6); `Codable` on `PanelTrip`, `DoorTrip` and `BoardDeparture` (Task 6).
- Produces:
  - `TripManager`: `@Published private(set) var upcomingAsOf: Date?`; `struct SavedUpcoming: Codable { let upcoming: [PanelTrip]; let board: [BoardDeparture] }`; key `"upcoming|\(upcomingKey)"`.
  - `GoStore`: `@Published private(set) var asOf: Date?`; `struct SavedGo: Codable { let trips: [DoorTrip]; let lat: Double; let lon: Double }`; key `"go|\(dest.key)"`.
  - `TransferList`: a new `var asOf: Date? = nil`.

- [ ] **Step 1: `loadUpcoming`.**
  - On a key change (1194), show the saved answer for the new key, filtered by departure (with `maxAge` 6 h): `upcomingAsOf = at`. With nothing saved, clear as today.
  - After a live answer with content: `upcomingAsOf = nil`, and save.
  - `endTrip` resets `upcomingAsOf`.
- [ ] **Step 2: `GoStore`.**
  - In `begin`, when `seed` is empty, the start list is `"go|\(d.key)"`: at most 30 min old (`maxAge: 1800`), `closeEnough(…, metres: 400)` to `fallback ?? trip?.lastFix`, and filtered by `first.departure > now`. It then goes through the seed path (115-119), with `asOf = at`.
  - `begin` resets `asOf = nil` (103).
  - After each live `apply` in `refresh` with a `best`: `asOf = nil`, and save `[best] + others` with the location.
- [ ] **Step 3: The labels.**
  - `TransferList` sub: `asOf.map { Snapshots.asOf($0) } ?? updated.map { "updated \(Fmt.hhmm($0))" }`; pass `asOf: trip.upcomingAsOf` at `Screens.swift:2006`.
  - `Screens.swift:1521`: `trip.upcomingAsOf` shows `"\(Snapshots.asOf(a))."` in place of "Updated at …".
  - `Go.swift:1088`: when `go.asOf` is set, `"\(Snapshots.asOf(a)) · checking again…"`; else today's "Checked at …".
- [ ] **Step 4: Commit and push, then verify CI.** Commit message: "Reliability: next departures and Fastest trip start from their last answer". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 8: The vehicle matcher as pure code, and the live flag from the map (D5)

**Files:**
- Create: `ios/App/Geo.swift`, `ios/App/VehicleMatch.swift`, `ios/Tests/MatchFixtures.swift`, `ios/Tests/GeoTests.swift`, `ios/Tests/VehicleMatchTests.swift`, `ios/Tests/DecideTests.swift`
- Modify:
  - `ios/App/Transit.swift:108-117` (`VehicleSegment` fields), `:597-613` (`vehicles(near:)`)
  - `ios/project.yml` (add `App/Geo.swift`, `App/VehicleMatch.swift`)

**Interfaces:**
- Produces:
  ```swift
  struct GeoPoint: Hashable, Codable, Sendable { var lat: Double; var lon: Double }
  enum Geo {
      static func metres(_ a: GeoPoint, _ b: GeoPoint) -> Double        // flat-earth as Live.swift:222 (kx from a's latitude)
      static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double       // 0..<360, as Transit.swift:96-99
      static func length(_ path: [GeoPoint]) -> Double
      struct Projection: Equatable { let crossTrack: Double; let along: Double; let fraction: Double; let bearing: Double }
      static func project(_ p: GeoPoint, on path: [GeoPoint]) -> Projection?   // nil: < 2 points or length 0 (as Live.swift:220-241)
      static func point(atMetres m: Double, on path: [GeoPoint]) -> GeoPoint?   // clamped to the path; nil when empty
  }
  struct Fix: Equatable, Sendable { let t: Date; let p: GeoPoint; let accuracy: Double; let speed: Double; let course: Double }
  struct TimedPiece: Equatable, Sendable { let departure: Date; let arrival: Date; let path: [GeoPoint] }
  struct MapPiece: Equatable, Sendable { let tripId: String; let line: String; let isTrain: Bool; let realTime: Bool; let piece: TimedPiece }
  struct VehicleTrack: Equatable, Sendable {
      let tripId: String; let line: String; let isTrain: Bool; let realTime: Bool; let pieces: [TimedPiece]   // by departure
      static func group(_ pieces: [MapPiece]) -> [VehicleTrack]   // per trip; identical pieces once; realTime if any piece is
  }
  struct Evidence: Equatable, Sendable {
      let fixes: Int; let span: TimeInterval; let crossTrack: Double; let accuracy: Double; let shaped: Bool
      let progress: Double; let offset: Double; let drift: Double; let yourSpeed: Double; let itsSpeed: Double; let steady: Bool
  }
  enum Reject: Error, Equatable, Sendable { case tooFewFixes, offItsPath, wrongWay, implausibleSpeed, standing, drifting, tooFarFromTimes, noTimes }
  struct Judgement: Equatable, Sendable { let id: String; let line: String; let isTrain: Bool; let realTime: Bool
                                          let evidence: Evidence?; let result: Result<Double, Reject> }
  struct Ranked: Equatable, Sendable { let id: String; let cost: Double }
  struct SwitchState: Equatable, Sendable { var leader: String? = nil; var looks = 0; var since: Date? = nil }
  enum Decision: Equatable, Sendable { case keep(String), switchTo(String), undecided([String]), none }
  enum VehicleMatch {
      static func tolerance(isTrain: Bool, speed: Double) -> Double      // moved from Live.swift:110-113, same values
      static func timePosition(_ v: VehicleTrack, at t: Date) -> Double? // metres along its joined pieces
      static func evidence(_ fixes: [Fix], _ v: VehicleTrack) -> Evidence?
      static func judge(_ e: Evidence, isTrain: Bool, realTime: Bool, strictTimes: Bool = true) -> Result<Double, Reject>
      static func judgeAll(_ fixes: [Fix], _ vs: [VehicleTrack], strictTimes: Bool = true) -> [Judgement]
      static func judgeOne(_ f: Fix, _ v: VehicleTrack, tolerance: Double) -> Judgement
      static func rank(_ judged: [Judgement], planned: String?, plannedBonus: Double = 45) -> [Ranked]
      static func decide(shown: String?, ranked: [Ranked], liveIds: Set<String>, state: inout SwitchState, now: Date,
                         margin: Double = 60, looks: Int = 3, span: TimeInterval = 45) -> Decision
  }
  // VehicleSegment gains: var realTime = false; var toLat: Double? = nil; var toLon: Double? = nil
  // Transit.vehicles(near:radiusDeg:back:ahead:allTrips: Bool = false)
  ```
  The spec's constants are `static let`s on `VehicleMatch`:

  | Constant | Value |
  |---|---|
  | window | 30 s |
  | minSpan | 20 s |
  | minFixes | 3 |
  | maxAccuracy | 150 |
  | offPath | 60 |
  | offPathUnshaped | 250 |
  | accuracyFactor | 1.5 |
  | backwards | 20 |
  | busMax | 31 |
  | speedRatio | 3 |
  | steadyShare | 0.3 |
  | driftMin | 3 |
  | driftShare | 0.25 |
  | standingMin | 40 |
  | standingShare | 0.2 |
  | costSpeedMin | 5 |
  | oneFixTurn | 75 |
  | slack | 30 s |

- [ ] **Step 1: Write the fixtures, `ios/Tests/MatchFixtures.swift`.**
  ```swift
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  func east(_ m: Double, north: Double = 0) -> GeoPoint      // lat 51.59 + north/110_540, lon 4.70 + m/(111_320·cos 51.59°)
  let railway = [east(0), east(3000), east(6900)]            // 3 points: shaped
  func road(north: Double) -> [GeoPoint]                     // the railway shifted north
  func fixes(from m0: Double, speed: Double, count: Int, every: Double = 2, north: Double = 0,
             accuracy: Double = 20, course: Double = 90, start: Date = t0) -> [Fix]   // fix k at start+k·every, east(m0+speed·k·every, north)
  func track(_ id: String, line: String = "IC", train: Bool = true, live: Bool = true,
             path: [GeoPoint], at m0: Double, speed: Double, start: Date = t0) -> VehicleTrack
      // one piece over `path`; its times put it m0 m along at `start`, moving `speed` m/s
  func ok(_ j: [Judgement], _ id: String) -> Double?         // the cost, if it passed
  func why(_ j: [Judgement], _ id: String) -> Reject?        // the reject, if it failed
  ```
- [ ] **Step 2: Write `ios/Tests/GeoTests.swift`.**
  - `test_metres`: east(0) → east(6900) is 6900 ± 10.
  - `test_projectMiddle`: on the line east(0)–east(1000), the point `east(500, north: 50)` → crossTrack 50 ± 1, along 500 ± 2, fraction 0.5 ± 0.01, bearing 90 ± 0.5.
  - `test_projectBeyondEnd`: `east(1100)` → along 1000 ± 1, fraction 1, crossTrack 100 ± 1.
  - `test_degenerate`: a one-point path → nil; two identical points → nil.
  - `test_pointAtMetres`: 250 → `east(250)` (±0.5 m); 5000 → the last point; −10 → the first; `[]` → nil.
  - `test_bearing`: north 0, east 90, south 180, west 270 (± 0.5).
- [ ] **Step 3: Write `ios/Tests/VehicleMatchTests.swift`.** "you" is `fixes(from: 2000, …)` unless stated.
  - `test_tolerancePinsToday`: (train, 30) → 1800; (bus, 30) → 1000; (train, 5) → 600; (bus, 5) → 400.
  - `test_timePosition`: two 1000 m pieces, running 0–60 s and 90–150 s (standing 60–90 s) → 500 at t0+30, 1000 at t0+75, 1500 at t0+120, 2000 at t0+170, nil at t0+200, nil at t0−40.
  - `test_zeroDurationPiece` (Review Focus 1): pieces 0–60 s (0→1000 m), then 60–60 s (1000→1500 m), then 60–120 s (1500→2500 m):
    - at t0+60: finite and in 1000…1500;
    - at t0+90: 2000 ± 1;
    - `judgeAll` of 15 fixes at 25 m/s over that track gives a finite cost.
  - `test_S1_busOnRoadBesideRailway`: you are 15 fixes on the railway at 30 m/s. Train "T" on the railway, live, `at: 1100` at 30 m/s. Bus "B" (`train: false`) on `road(north: 200)` at 2300, 12 m/s → B `.offItsPath`; T passes with cost 30 ± 1; `rank` → `["T"]`.
  - `test_S1b_busOnCloseRoad`: the same with B on `road(north: 50)` → B `.drifting`.
  - `test_busTooFast`: you at 35 m/s on `road(north: 50)`; bus at 2000, 35 m/s on that road → `.implausibleSpeed`.
  - `test_S2_trainPassingYourBus`: you 15 fixes on `road(north: 50)` at 12 m/s. Your bus "B" there `at: 1900`, 12 m/s, live. Train "T" on the railway `at: 1500`, 30 m/s → T `.drifting`; `rank` → `["B"]`.
  - `test_S3_oppositeTrainsWithoutCourse`: you at 30 m/s with `course: -1` on every fix. A eastbound `at: 1400`, 30 m/s. B on `railway.reversed()` at `length − 2200`, 30 m/s → B `.wrongWay`; A passes with cost 20 ± 1.
  - `test_S4_leavingAStation`: you accelerate from `east(2000)`: x(t) = 2000 + t²/6 for t ≤ 30, then +10 m/s, a fix every 2 s. Train on the railway `at: 2000`, 10 m/s. Bus on a path that leaves the railway at `east(2050)` at 40° to the north-east, `at: 2000`, 10 m/s.
    - the fixes of t0…t0+4 → both `.tooFewFixes`;
    - the fixes of t0…t0+40 → bus `.offItsPath`, train passes.
  - `test_S6_busStandingAtYourStop`: you leave `east(2000, north: 50)` at 8 m/s, a fix every 1.25 s, 17 fixes. Bus "S" on `road(north: 50)`: one piece arriving at 2000 m at t0−5, the next departing 2000 m at t0+20 → `.standing`.
  - `test_S7_oldFixUsesItsOwnTime`: one fix at t0−20 at `east(2000)`, 30 m/s, course 90. Train `at: 2000`, 30 m/s, `start: t0−20` → `judgeOne(…, tolerance: 1800)` passes with cost < 1.
  - `test_timetableOnlyKeptAsCandidate`: you at 12 m/s on `road(north: 50)`. Bus "A" (`live: false`) on that road `at: 5000`, 12 m/s → `.tooFarFromTimes` with `strictTimes: true`; passes with `strictTimes: false`.
  - `test_unshapedPathLenient` (Review Focus 2): you at 12 m/s, `north: 150`. Bus at 2000, 12 m/s:
    - on the 2-point path `[east(0), east(6900)]` → not `.offItsPath`;
    - on `railway` (3 points) → `.offItsPath`.
  - `test_badFixesIgnored` (Review Focus 3): the S1 fixes, plus a fix in the middle with accuracy 500 at `east(2400, north: 2000)` → `judgeAll` results equal those without it.
  - `test_S10_plannedBonus`: synthetic successes "p" 70 and "o" 40, `planned: "p"` → `[Ranked(id: "p", cost: 25), Ranked(id: "o", cost: 40)]`.
  - `test_groupSharedPieces`: two identical `MapPiece`s of trip "x", a later piece of "x" and one piece of "y" → 2 tracks; "x" has 2 pieces in departure order.
- [ ] **Step 4: Write `ios/Tests/DecideTests.swift`.** Looks are at t0, t0+24 and t0+48 unless stated.
  - `test_S5_timetableOnlyKeepsShown`: shown "A" (not in `liveIds`), ranked `[B 4, A 250]`, `liveIds ["B"]` → 10 looks 12 s apart, all `.keep("A")`.
  - `test_S5b_switchAfterThreeLooks`: both live, ranked `[B 10, A 100]` → `.keep("A")`, `.keep("A")`, `.switchTo("B")`.
  - `test_S5c_runRestarts`: leads 90, 30, 90, then 90 at t0+72 → four `.keep("A")`.
  - `test_threeLooksTooQuick`: lead 90 at t0, t0+10, t0+20 → `.keep` ×3; at t0+50 → `.switchTo("B")`.
  - `test_shownRejectedSwitches`: ranked `[B 10]` (A failed), both live → keep, keep, `.switchTo("B")`.
  - `test_S8_sharedRoadUndecided`: shown nil, all live, costs b1 10, b2 12, b3 40, b4 80, b5 90 → `.undecided(["b1", "b2", "b3"])`.
  - `test_clearWinnerNoShown`:
    - `[b1 10, b2 200]`, both live → `.switchTo("b1")`;
    - with b2 timetable-only → `.undecided(["b1", "b2"])`;
    - a single candidate → `.switchTo`;
    - `[]` → `.none`.
- [ ] **Step 5: Implement `Geo.swift` and `VehicleMatch.swift`.**
  - `timePosition`:
    - pieces in departure order, joined into one path; each piece starts at the joined length before its first point;
    - inside a piece → interpolate by time (a zero-length piece puts it at the piece's end);
    - between pieces → the start of the next one;
    - within `slack` before the first or after the last → that end;
    - else nil.
  - `evidence`:
    - keep fixes with accuracy ≤ `maxAccuracy` within `window` of the newest one, and with a time position; nil when fewer than 2 remain;
    - `crossTrack` is the median of the last 3 projections;
    - `progress` = along(last) − along(first); `offset` at the last fix;
    - `drift` = (offset last − offset first) / span; `yourSpeed` = |progress| / span; `itsSpeed` from the time positions at the first and last fix;
    - `steady`: halves by time, both speeds ≥ 3, and their difference ≤ `steadyShare` × the larger;
    - `shaped`: some piece has more than 2 points.
  - `judge`: the spec's test table, in order 1–7. With `strictTimes == false && !realTime`, skip the ratio part of 4, and 5, 6 and 7. Success = |offset| / max(`costSpeedMin`, itsSpeed).
  - `judgeAll` maps tracks to judgements (`.noTimes` when `evidence` is nil). `judgeOne` follows the spec's "one fix only". `rank` keeps successes, subtracts the bonus for `planned`, and sorts by cost, then id.
  - `decide` follows the spec's "Decide, with hysteresis" rules exactly. Reset the state whenever it returns `.keep` for a reason other than counting a look.
- [ ] **Step 6: Parse the map better** (`Transit.swift`; no behaviour change yet).
  - Add `realTime` and the `to` stop's `lat`/`lon` to `VehicleSegment`.
  - `vehicles(near:)` reads `s["realTime"]` and `s["to"]["lat"/"lon"]`. With `allTrips: true` it makes one segment per entry of `trips` (S9); the default is false, the first only, as today.
  - `project.yml`: append `App/Geo.swift`, `App/VehicleMatch.swift`.
- [ ] **Step 7: Commit and push, then verify CI.** Commit message: "Reliability: a vehicle matcher that checks you move with it, as pure tested code". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 9: Field log, and the classic-matching switch in Settings (D9)

**Files:**
- Create: `ios/App/FieldLog.swift`, `ios/Tests/FieldLogTests.swift`
- Modify:
  - `ios/App/Net.swift` (`response` gets `label`)
  - `ios/App/Transit.swift` (`raw` passes its path), `ios/App/NS.swift` (`fetch` passes the path before `?`)
  - `ios/App/VehicleMatch.swift` (add `MatchSettings`), `ios/Tests/VehicleMatchTests.swift`
  - `ios/App/Diagnostics.swift` (after `FreezeSection`)
  - `ios/App/Screens.swift:2048` (Settings) and `:220-226` (flush on background)
  - `ios/project.yml` (add `App/FieldLog.swift`)

**Interfaces:**
- Consumes: `Lane` (Task 1); `Judgement`, `Reject`, `Evidence`, `Decision` (Task 8).
- Produces:
  ```swift
  struct FieldEntry: Codable, Equatable, Sendable { enum Kind: String, Codable, Sendable { case net, match }
                                                    let at: Date; let kind: Kind; let text: String }
  final class FieldLog: @unchecked Sendable {
      static let shared: FieldLog                                   // UserDefaults.standard
      init(defaults: UserDefaults, key: String = "fieldLog.v1", limit: Int = 400)
      func add(_ kind: FieldEntry.Kind, _ text: String, at: Date = Date())   // newest first; written at most every 5 s
      func flush()
      var entries: [FieldEntry] { get }
      func clear()
      func export(timeZone: TimeZone = .current) -> String         // one line per entry: "08:12:03 net <text>"
  }
  enum FieldFormat {
      static func net(_ path: String, lane: Lane, status: Int?, error: URLError.Code?, bytes: Int, seconds: Double, attempts: Int) -> String
      static func label(_ id: String, _ lines: [String: String]) -> String     // "306·a1b2": the line, "·", the last 4 of the trip id
      static func reject(_ r: Reject, _ e: Evidence?) -> String
      static func match(_ place: String, _ judged: [Judgement], outcome: String) -> String
      static func outcome(_ d: Decision, lines: [String: String]) -> String
      static func classic(_ place: String, _ found: [(label: String, metres: Double)]) -> String
  }
  enum MatchSettings { static let key = "classicMatching"; static func classic(_ d: UserDefaults = .standard) -> Bool }
  // Net.response(_:lane:budget:gate:send:label: String? = nil): with a label, one .net entry per call
  struct FieldLogSection: View          // in Diagnostics.swift
  ```

- [ ] **Step 1: Write `ios/Tests/FieldLogTests.swift`.**
  - `test_newestFirstAndLimit`: limit 3; add a, b, c, d → `["d", "c", "b"]`.
  - `test_persistsAfterFlush`: add 2, `flush()`, a new `FieldLog` on the same suite → the same 2. `clear()` + `flush()` → a new one is empty.
  - `test_netFormat`:

    | Input | Line |
    |---|---|
    | ("/v5/plan", .urgent, 200, nil, 31_950, 2.43, 1) | `"/v5/plan · 200 · 31.2 KB · 2.4 s · 1 try · urgent"` |
    | ("/v5/trip", .background, nil, .timedOut, 0, 15.0, 1) | `"/v5/trip · timed out · 0 B · 15.0 s · 1 try · background"` |
    | ("/ns/departures", .background, 503, nil, 512, 0.4, 2) | `"/ns/departures · 503 · 512 B · 0.4 s · 2 tries · background"` |

    Other errors read: `.notConnectedToInternet` "offline", `.networkConnectionLost` "connection lost", `.cancelled` "cancelled", anything else "error <rawValue>".
  - `test_rejectFormat`:

    | Reject (evidence) | Text |
    |---|---|
    | tooFewFixes | "too few fixes" |
    | offItsPath (crossTrack 180.4) | "off its path 180 m" |
    | wrongWay | "going the other way" |
    | implausibleSpeed (you 30.2, it 12) | "wrong speed (you 30 m/s, it 12)" |
    | standing | "standing by its times" |
    | drifting (−18.3) | "drifting 18 m/s" |
    | tooFarFromTimes (offset −2400) | "2400 m from its times" |
    | noTimes | "no times now" |
  - `test_matchFormat`: place "detect"; judged: "x-a1b2" IC live, cost 30.4; "y-c3d4" 306 timetable, offItsPath, crossTrack 180; outcome "keep IC·a1b2" → `"detect · IC·a1b2 live 30 s | 306·c3d4 timetable off its path 180 m → keep IC·a1b2"`. Successes come first by cost, then rejects, at most 6.
  - `test_outcomeFormat`, with lines `["x-a1b2": "IC", "y-c3d4": "306"]`:

    | Decision | Text |
    |---|---|
    | keep | "keep IC·a1b2" |
    | switchTo | "switch to IC·a1b2" |
    | undecided | "undecided: IC·a1b2, 306·c3d4" |
    | none | "none" |
  - `test_classicFormat`: ("detect", [("306·a1b2", 120.4), ("305·c3d4", 310)]) → `"detect (classic) · 306·a1b2 120 m | 305·c3d4 310 m"`.
  - `test_export`: an entry at 07:12:03 UTC, net "x", in Europe/Amsterdam → `"08:12:03 net x"`.
  - In `VehicleMatchTests`, `test_newMatcherIsDefault`: a fresh suite → `MatchSettings.classic(d)` false; after `d.set(true, forKey: MatchSettings.key)` → true.
- [ ] **Step 2: Implement `FieldLog.swift` and `MatchSettings`.** Guard the entries with an `NSLock`. `add` marks the log dirty and schedules a `flush` 5 s later if none is pending. Store the entries as JSON.
- [ ] **Step 3: Log the requests.**
  - `Net.response` gets a final `label: String? = nil`. When it's set, log `FieldFormat.net(…)` once per call, on success, failure or timeout.
  - `Transit.raw` passes `path`. `NSStore.fetch` passes the path before `?`.
- [ ] **Step 4: Settings.**
  - `FieldLogSection` in `Diagnostics.swift`: `Section("Vehicle matching")` holding:
    - a `Toggle("Classic vehicle matching", isOn: @AppStorage(MatchSettings.key))`, with the spec's footer;
    - a `NavigationLink("Connection and matching log")` to a list of the entries: newest first, time in `HWFont.body(12, bold: true)`, text in `.system(size: 11, design: .monospaced)`, "Nothing logged yet." when empty;
    - on the log screen, "Copy the log" (`UIPasteboard`, the label becomes "Copied: paste it in the chat") and "Clear", with the spec's footer.
  - Insert `FieldLogSection()` right after `FreezeSection()` (`Screens.swift:2048`).
  - In `.onChange(of: scene)` (220), call `FieldLog.shared.flush()` when it becomes `.background`.
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: a connection and matching log in Settings, and the classic matching switch". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 10: Road lookups at the fix's own time, and the best of several on a shared road (D6: S7, S8)

**Files:**
- Create: `ios/App/MatchBridge.swift`
- Modify:
  - `ios/App/VehicleMatch.swift` (add `RoadHit`, `byRoad`, `otherKindPossible`), `ios/Tests/VehicleMatchTests.swift`
  - `ios/App/Live.swift:198-217` (`vehiclesByRoad`)
  - `ios/App/TripManager.swift:145` (add `recentFixes`), `:886-887` (`checkSameBus`), `:968-989` (`findBusYoureOn`)

**Interfaces:**
- Consumes: Task 8 (all), `FieldLog`, `FieldFormat`, `MatchSettings` (Task 9), `Progressive.all` (Task 3), `Transit.liveTrip` through the memo (Task 2).
- Produces:
  ```swift
  struct RoadHit: Equatable, Sendable { let tripId: String; let line: String; let isTrain: Bool; let late: TimeInterval }
  extension VehicleMatch {
      /// The pieces whose road you're on (≤ maxMetres) going your way (course within maxTurn); late = f.t − when its times have it at your spot; |late| < maxLate; per trip the least late; least late first.
      static func byRoad(_ f: Fix, _ pieces: [MapPiece], maxMetres: Double = 100, maxTurn: Double = 60, maxLate: TimeInterval = 720) -> [RoadHit]
      static func otherKindPossible(_ r: Reject?) -> Bool     // implausibleSpeed or drifting
  }
  // MatchBridge.swift (app-only, imports CoreLocation):
  extension GeoPoint { init(_ c: CLLocationCoordinate2D) }
  extension Fix { init(_ l: CLLocation) }                     // timestamp, coordinate, horizontalAccuracy, speed, course
  extension MapPiece { init(_ s: VehicleSegment) }            // trains get Transit.trainLabel(line)
  extension VehicleTrack { init?(tripId: String, line: String, isTrain: Bool, trip: LiveTrip) }
      // a piece per stop pair with departure(i), arrival(i+1) and trip.road(from: metres(ofStop: i), to: metres(ofStop: i+1)); realTime = trip.live; nil without a piece
  // TripManager:
  var recentFixes: [Fix] { get }     // samples of the last 120 s with 0 ≤ accuracy < 150
  private func findBusYoureOn(not v: Vehicle, at here: CLLocation, limit: Double) async -> (vehicle: Vehicle, stops: [TripStop], others: [Vehicle])?
  ```

- [ ] **Step 1: Add to `VehicleMatchTests.swift`.**
  - `test_byRoadUsesFixTime`: a fix at t0−20 at `east(2000)`, course 90. A piece over the railway whose times have it at 2000 m at t0−20 → one hit with `late` 0 ± 2. (Comparing with "now", t0, would have given 20.)
  - `test_byRoadSkipsOtherWay`: the same piece over `railway.reversed()` → `[]`.
  - `test_byRoadLeastLateFirst`: two trips late 120 s and −30 s → order [−30, 120].
  - `test_otherKindPossible`: `.implausibleSpeed` true; `.drifting` true; `.offItsPath` false; nil false.
- [ ] **Step 2: Implement `byRoad`, `otherKindPossible` and `MatchBridge.swift`.**
- [ ] **Step 3: `vehiclesByRoad`.** The classic branch is today's body. The new branch is `VehicleMatch.byRoad(Fix(f), segs.map(MapPiece.init))`, mapped to today's tuple type. Keep the `course`/`speed` guard at 199.
- [ ] **Step 4: `findBusYoureOn`.** The classic branch is today's body, with `others: []`. The new branch:
  - `anyKind = route?.isFixed == false && otherKindPossible(…)` of the current vehicle: `judgeAll(recentFixes, [VehicleTrack(…, trip: roadOf.trip)], strictTimes: false)`, when `roadOf?.tripId == v.tripId`.
  - Candidate ids as today: planned, then `boardAlternatives`, then `matchVehicles(mode: anyKind ? nil : leg?.mode, excluding: [v.tripId])`. Deduplicated, at most 8. Skip the other kind unless `anyKind`.
  - Fetch their `liveTrip`s through `Progressive.all` and make tracks.
  - `judgeAll(recentFixes, tracks, strictTimes: false)`, then `rank(…, planned: route?.planned?[safe: index]?.tripId)`, then `decide(shown: nil, …, liveIds: live track ids)`:
    - `.switchTo(x)` → `(x, stops of x, [])`;
    - `.undecided(xs)` → `(xs[0], stops, xs.dropFirst())`;
    - `.none` → nil.
  - Log `FieldFormat.match("find", …, outcome: FieldFormat.outcome(d, lines:))`.
- [ ] **Step 5: `checkSameBus` (886-887).** After `switchVehicle(from: v, to: found.vehicle, …)`, call `beginChoosing([found.vehicle] + found.others)` when `others` isn't empty.
- [ ] **Step 6: Commit and push, then verify CI.** Commit message: "Reliability: road lookups at the fix’s own time, and no first-come pick on a shared road". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 11: Pick the bus or train that moves with you (D7)

**Files:**
- Modify:
  - `ios/App/VehicleMatch.swift` (add `MatchRules`), `ios/Tests/VehicleMatchTests.swift`
  - `ios/App/TripManager.swift`:
    - `:8-14` (add `Match`)
    - `:418-425` (idle line watch)
    - `:605-673` (`startDetecting`)
    - `:686-731` (`matchVehicle`, `matchVehicles`)
    - `:878` (`checkSameBus`, far looks)
    - `:1041` (`wrongWay`)
  - `ios/App/Live.swift:119-193` (`onBoardTrips`, `plans`)
  - `ios/App/Go.swift:458, 464-481` (`firstLook`), `:491-525` (`checkBoarding`)

**Interfaces:**
- Consumes: Tasks 8–10 (`judgeAll`, `judgeOne`, `rank`, `tolerance`, `VehicleTrack.group`, `MapPiece.init`, `Fix.init`, `recentFixes`, `FieldFormat`, `MatchSettings`).
- Produces:
  ```swift
  struct MatchRules: Equatable, Sendable {
      let oneLook: Double; let oneLookWatched: Double; let expected: Double; let plannedEdge: Double; let close: Double; let sameLineNear: Double
      static let classic = MatchRules(oneLook: 150, oneLookWatched: 250, expected: 350, plannedEdge: 200, close: 300, sameLineNear: 400)  // metres: today
      static let seconds = MatchRules(oneLook: 15, oneLookWatched: 20, expected: 30, plannedEdge: 0, close: 60, sameLineNear: 40)       // seconds off its times
      static func current(_ d: UserDefaults = .standard) -> MatchRules
  }
  struct Match: Equatable { let vehicle: Vehicle; let meters: Double; let score: Double }   // TripManager.swift; score: metres (classic) or cost in seconds
  func matchVehicle(mode: Mode?, excluding: Set<String> = []) async -> Match?
  func matchVehicles(mode: Mode?, excluding: Set<String> = [], planned: String? = nil, place: String = "match") async -> [Match]
  static func onBoardTrips(_ f: CLLocation, to dest: Place, tripId: String? = nil, wasMoving: Bool = false,
                           late: TimeInterval? = nil, line: String? = nil, isTrain: Bool? = nil, history: [Fix] = []) async -> (OnBoard, [DoorTrip])?
  ```

- [ ] **Step 1: Add to `VehicleMatchTests.swift`.**
  - `test_rulesPinToday`: `MatchRules.classic` has exactly the values above.
  - `test_rulesFollowTheSwitch`: a fresh suite → `.seconds`; with classic on → `.classic`.
- [ ] **Step 2: Implement `MatchRules`.**
- [ ] **Step 3: `matchVehicles`.**
  - The classic branch is today's body (`allTrips: false`, score = metres), plus a `FieldFormat.classic(place, …)` entry.
  - The new branch:
    - keeps the speed gate at 693-696;
    - fetches the vehicles with `allTrips: true`, urgent as in Task 1;
    - makes tracks with `VehicleTrack.group(segs.map(MapPiece.init))`, filtered by `mode` and `excluding`;
    - calls `judgeAll(recentFixes, tracks)`, then `rank(…, planned:)`;
    - returns a `Match` per ranked track, with `meters = |evidence.offset|` and `score = cost`;
    - logs `FieldFormat.match(place, judged, outcome: ranked.first.map { "best " + FieldFormat.label($0.id, lines) } ?? "none")`.
  - `matchVehicle` returns `.first`.
- [ ] **Step 4: Use `MatchRules.current()` (`R`) at the call sites, replacing the metre literals.**
  - `startDetecting`:
    - calls `matchVehicles(mode: nil, excluding: rejected, planned: planned?.tripId, place: "detect")`;
    - 638 `pm.score < m.score + R.plannedEdge`; 642 `m.score < R.expected`; 644 `m.score < R.oneLook`; 661 `$0.score < m.score + R.close`.
  - The idle line watch: 423 `m.score < R.oneLookWatched`.
  - `checkSameBus` 878: `$0.score < R.sameLineNear`, with `place: "same bus"`.
  - `Go.firstLook` confirmation: `matchVehicles(mode: nil, planned: v.tripId, place: "confirm")`; 470 `$0.score < me.score + R.close`.
  - `Go.checkBoarding`: `matchVehicles(mode: nil, planned: best?.first.tripId, place: "board")`; 502 `bm.score < m.score + R.plannedEdge`; 505 `R.close`; 509 `m.score < R.oneLookWatched`.
  - `matchMeters = Int(m.meters)` stays.
- [ ] **Step 5: `onBoardTrips` with history.**
  - The classic branch (and every `tripId != nil` call) is today's code.
  - The new branch, for `tripId == nil`:
    - tracks from `vehicles(near:…, allTrips: true)`;
    - `history` spanning ≥ 20 s → `judgeAll(history, tracks)`; else `judgeOne(Fix(f), track, tolerance: still ? 250 : tolerance(isTrain:, speed: speedNow))` per track;
    - `rank(…, planned: nil)`; the best's newest segment gives the line, kind and `toName`;
    - log with place `"on board"`.
  - **Two requests in sequence instead of three** (both branches):
    - when the chosen segment's `to` stop has `toLat`/`toLon` and an arrival later than now + 20 s, it is `next`;
    - split `plans` into `planOn(next:at:to:) async -> [DoorTrip]` (the planner calls) and `assemble(…, stops:, its:)` (today's lines 164-192);
    - run `async let stops = Transit.tripStops(seg.tripId)` beside `async let its = planOn(…)`;
    - otherwise, as today: stops first, then plans.
  - Callers pass history: `Go.firstLook` (458) and `Go.checkBoarding` (516) pass `trip.recentFixes`; `TripManager.wrongWay` (1041) passes `recentFixes`. `LiveStore.refresh` passes none.
- [ ] **Step 6: Commit and push, then verify CI.** Commit message: "Reliability: pick the bus or train that moves with you". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 12: Switch to another bus only when it's clearly the one, for a while (D8: S3, S5)

**Files:**
- Modify:
  - `ios/App/VehicleMatch.swift` (add `prune`), `ios/Tests/DecideTests.swift`
  - `ios/App/TripManager.swift`:
    - `:111-129` (state)
    - the resets at `:276, :340, :901, :957`
    - `:849-891` (`checkSameBus`)
    - `:909-953` (`resolveCandidates`)

**Interfaces:**
- Consumes: `judgeAll`, `rank`, `decide`, `SwitchState` (Task 8); `VehicleTrack(…, trip:)`, `recentFixes` (Task 10); `findBusYoureOn` (Task 10); `FieldFormat` (Task 9).
- Produces:
  ```swift
  extension VehicleMatch {
      /// A judgement failing (not tooFewFixes or noTimes) adds one miss and a success resets it; returns those with fewer than 2 misses, plus `keep` always.
      static func prune(_ judged: [Judgement], misses: inout [String: Int], keep: String?) -> [Judgement]
  }
  // TripManager: private var candSwitch = SwitchState(); private var candMisses: [String: Int] = [:]
  ```

- [ ] **Step 1: Add to `DecideTests.swift`.**
  - `test_pruneDropsAfterTwoMisses`: "b" fails twice (`.offItsPath`), "a" passes → after the second call only "a" is left.
  - `test_pruneNeverDropsShown`: "a" fails 3 times with `keep: "a"` → still returned.
  - `test_pruneResetsOnSuccess`: "b" fails, passes, fails → still returned.
  - `test_pruneIgnoresTooFewFixes`: `.tooFewFixes` 3 times → still returned.
- [ ] **Step 2: Implement `prune`.**
- [ ] **Step 3: `resolveCandidates`.** The classic branch is today's body. The new branch, after the trips are fetched (916-919):
  - tracks = candidates with a trip → `VehicleTrack(…, trip:)`;
  - `judgeAll(recentFixes, tracks, strictTimes: false)` → `prune(…, misses: &candMisses, keep: vehicle?.tripId)`;
  - the alive set = pruned ids plus the candidates with no trip yet;
  - `rank(pruned, planned: nil)`;
  - `decide(shown: vehicle?.tripId, …, liveIds: live track ids, state: &candSwitch, now:)`;
  - `cands` and `choosing` = the alive ones;
  - `.switchTo(x)` → `settle(x)`. `.keep` with only the shown one left → `settle(shown)`. The 12-minute rule (947-948) stays;
  - log with place `"choose"`.
  - Reset `candSwitch` and `candMisses` wherever `candLead` is reset.
- [ ] **Step 4: `checkSameBus`.** The classic branch is today's body. In the new branch, the on-its-road check (862-863) becomes: `judgeAll(recentFixes, [VehicleTrack(…, trip: t)], strictTimes: false).first`.
  - It counts as off the vehicle only when the result is a failure other than `.tooFewFixes` or `.noTimes`. Then `offRoad += 1`; at 2, `findBusYoureOn` as today.
  - Otherwise `offRoad = 0`, and the line rename (865-870) and the far looks (873-880) run as today.
  - Log with place `"same bus"`.
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: switch to another bus only when it’s clearly the one, for a while". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 13: No walking plan on a moving train, a back-off when there's no connection, and 0.18.0 (D11: N7, N13)

**Files:**
- Modify:
  - `ios/App/VehicleMatch.swift` (add `planFromSpot`), `ios/App/Net.swift` (add `nextBackoff`, `online`, `startWatchingConnection`)
  - `ios/Tests/VehicleMatchTests.swift`, `ios/Tests/NetTests.swift`
  - `ios/App/Live.swift:24-41` (add `onTheMove`), `:332-343` (`refresh`)
  - `ios/App/Screens.swift:608, 808, 1072`, and the as-of lines from Task 6
  - `ios/App/Go.swift:113-129` (the loop)
  - `ios/App/HaltewekkerApp.swift:10-15`
  - `ios/project.yml`

**Interfaces:**
- Consumes: `Net.within` (Task 1), `Snapshots.asOf` (Task 6).
- Produces:
  ```swift
  extension VehicleMatch { static func planFromSpot(speed: Double, movedAgo: TimeInterval?) -> Bool }   // false at ≥ 8 m/s, or speed unknown (< 0) and moved < 30 s ago
  extension Net {
      static func nextBackoff(failures: Int) -> TimeInterval   // 4, 8, 16, then 30
      static var online: Bool { get }                          // true until NWPathMonitor says otherwise
      static func startWatchingConnection()                    // once, at app start
  }
  // LiveStore: @Published private(set) var onTheMove = false
  ```

- [ ] **Step 1: Write the tests.**
  - `test_planFromSpot` (`VehicleMatchTests`):

    | (speed, movedAgo) | result |
    |---|---|
    | (12, 5) | false |
    | (8, 1) | false |
    | (7.9, 1) | true |
    | (2, 60) | true |
    | (−1, 10) | false |
    | (−1, 120) | true |
    | (−1, nil) | true |
  - `test_backoff` (`NetTests`): failures 0, 1, 2, 3, 9 and −1 → 4, 8, 16, 30, 30 and 4.
- [ ] **Step 2: Implement them.** `online` is guarded by an `NSLock` and set from an `NWPathMonitor` (`path.status == .satisfied`) on its own queue. Call `startWatchingConnection()` in `HaltewekkerApp.init`.
- [ ] **Step 3: `LiveStore.refresh` (336-340).** When the on-board look within 7 s finds nothing and `!planFromSpot(speed: f.speed, movedAgo: now − lastMoving)`:
  - `onBoard = nil; onTheMove = true; trips = []`. The existing "one empty answer keeps what you had" at 346 then keeps `next`; set `nextError = nil` while `onTheMove`.
  - Every other branch sets `onTheMove = false`.
  - In `Screens.swift`, the three "Finding your next connection(s)…" texts (608, 808, 1072) show "On the move: finding what you’re on…" while `live.onTheMove`. The as-of lines from Task 6 show it in place of "as of …".
- [ ] **Step 4: Fastest trip's loop (Go.swift:120-128).**
  - Count `emptyLooks`: + 1 after a refresh with `best == nil`, reset to 0 when `best != nil`.
  - The wait with nothing on screen becomes `here == nil ? 1.5 : Net.nextBackoff(failures: emptyLooks - 1)`.
  - While `!Net.online`, skip `refresh()`, wait 4 s, and with `best == nil` set `error` to "No internet connection right now. It looks again as soon as you’re back online.".
  - `begin` resets `emptyLooks`.
- [ ] **Step 5: Bump the version** in `ios/project.yml`: `MARKETING_VERSION: "0.18.0"`, `CURRENT_PROJECT_VERSION: "83"`.
- [ ] **Step 6: Commit and push, then verify CI.** Commit message: "Reliability 0.18.0: no walking plan on a moving train, and a calm retry without a connection". Expected: `** TEST SUCCEEDED **` and `BUILD SUCCEEDED`. There is no release yet: that comes when the branch is merged into `main`.
- [ ] **Step 7: The user checks it on the phone after merging.**
  - The app opens to the last answers, marked "as of".
  - Fastest trip on a weak connection shows a trip within a few seconds.
  - On the train out of Breda past the 305/306 buses, it picks the train.
  - Settings → "Connection and matching log" shows requests and choices, and "Copy the log" works.
