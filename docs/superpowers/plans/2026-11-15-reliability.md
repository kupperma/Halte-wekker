# Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Haltewekker quick on a weak connection (request budgets, parallel and progressive loading, saved answers shown at once), and make it pick the bus or train that moves with you, with a "Classic vehicle matching" switch and a field log in Settings.

**Architecture:** The rules live in new Foundation-only files that the hostless `HaltewekkerTests` bundle compiles directly. They are `Net.swift`, `Memo.swift`, `Snapshots.swift`, `Geo.swift`, `VehicleMatch.swift` (evidence → hard tests → cost in seconds → decide with hysteresis) and `FieldLog.swift`. The existing stores (`Transit`, `LiveStore`, `TripManager`, `GoStore`, `Planner`, `NSStore`) keep thin calls, the app-only `MatchBridge.swift` converts CoreLocation and `LiveTrip` values, and every matching change sits behind `MatchSettings.classic()`.

**Tech Stack:** Swift 5 language mode (Xcode 26), SwiftUI, iOS 17, URLSession, Network (`NWPathMonitor`), XCTest, XcodeGen, GitHub Actions (macos-15).

**Spec:** `docs/superpowers/specs/2026-11-15-reliability-design.md`. Read it first: it holds the hard-test table, the decide rules and the exact copy. File:line evidence for every cause is in `.superpowers/reliability/analysis.md`.

## Global Constraints

- iOS 17.0, SwiftUI, `SWIFT_VERSION 5.0`. No third-party packages, no new entitlements, no new Info.plist keys.
- UI copy is English, exactly as in the spec's "Copy" section, with typographic apostrophes (’) as elsewhere in the app.
- `Net.swift`, `Memo.swift`, `Snapshots.swift`, `Geo.swift`, `VehicleMatch.swift` and `FieldLog.swift` import only `Foundation` (`Net.swift` also `Network`). They never reference app types (`Ride`, `DoorTrip`, `Place`, `Transit`, `Fmt`, `LiveTrip`, `CLLocation`…).
- The task that creates one of those files appends it to `HaltewekkerTests` → `sources:` in `ios/project.yml`. Keep `Tests`, `App/Recomp*.swift` and `App/OpenFoodFacts.swift` as they are.
- Don't touch `relay/` or `.github/`.
- Tests never use the network, the real clock or the real Caches folder. Inject `send` closures, clocks, `UserDefaults(suiteName: UUID().uuidString)` and temporary directories. Timing bounds allow at least twice the expected time.
- Budgets (verbatim from the spec):
  - urgent: idle 4 s, total 8 s; background: idle 8 s, total 15 s;
  - one retry, after 0.3 s (urgent) or 1.0 s (background), only after a failure that came back within 2 s and with ≥ 3 s left; never after a timeout;
  - 429 waits for `Retry-After`, at most 10 s;
  - background waits at most 2 s behind urgent;
  - first content ≤ 300 ms from a saved answer;
  - ≤ 1 request in sequence before the first live content (2 for "what am I on").
- The new matcher is the default. `UserDefaults` `"classicMatching"` = true runs today's choosing code at every matching call site: each site branches on `MatchSettings.classic()`, and the classic branch is today's code, unchanged.
- The field log holds paths, lanes, statuses, sizes, seconds, attempts, lines and the last 4 characters of trip ids. It never holds coordinates or query strings.
- Saved answers go to `Caches/answers/<key>.json`. They are never shown without "as of HH:mm", and items that departed more than 60 s ago are dropped first.
- There is no local Swift toolchain. Each task writes its tests and code together and verifies them with one push to `claude/cool-mendel-odsmk9`. In the "Build iPhone app" run, expect `** TEST SUCCEEDED **` and `BUILD SUCCEEDED`, and no release (releases come only from `main`). Read the run with the GitHub MCP tools `actions_list` and `get_job_logs`.
- Line numbers are at HEAD 13b6bc2 and move as earlier tasks land. Find the spot by the function named.
- Commit messages start with "Reliability: ".

## Review Focus

1. **Zero-length pieces.** With minute-rounded times, a piece can have departure == arrival. Expect no NaN and no division by zero: the vehicle sits at that piece's end, and the evidence stays finite. Test in Task 8 (`test_zeroDurationPiece`).
2. **Paths without a road shape.** Buses often have straight 2-point chords between stops. You 150 m off a chord must not count as off its path; the same distance from a shaped path must. Test in Task 8 (`test_unshapedPathLenient`).
3. **Bad fixes in the window.** A 500 m-accuracy fix 2 km away, among good ones, is ignored: the verdicts are identical without it. Test in Task 8 (`test_badFixesIgnored`).
4. **Leaving a screen mid-request.** When the task is cancelled, the request stops at once, isn't retried and isn't reported as a timeout. Test in Task 1 (`test_cancelledNotRetried`).
5. **A corrupt or older-format saved answer.** It is ignored and deleted, without a crash, as if nothing was saved. Test in Task 6 (`test_corruptSnapshotIgnored`).

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `ios/App/Net.swift` (new, pure) | lanes, budgets, sessions, retry rule, gate, `within`, `withPartials`, `Progressive`, backoff, connection monitor | 1, 3, 5, 9, 13 |
| `ios/App/Memo.swift` (new, pure) | remembered answers: expiry, shared fetches, failures never stored | 2 |
| `ios/App/Snapshots.swift` (new, pure) | saved answers on disk, "as of", what a planning-key change does | 6 |
| `ios/App/Geo.swift` (new, pure) | flat-earth distance, bearing, projection on a path | 8 |
| `ios/App/VehicleMatch.swift` (new, pure) | tracks, evidence, hard tests, cost, rank, decide, rules, settings | 8–13 |
| `ios/App/FieldLog.swift` (new, pure) | the field log and its line formats | 9 |
| `ios/App/MatchBridge.swift` (new, app-only) | `CLLocation` / `VehicleSegment` / `LiveTrip` → pure types | 10 |
| `ios/Tests/…Tests.swift` (new) | one test file per pure file, plus `MatchFixtures.swift` | each |

### Task 1: Time limits per request, one quick retry, a short wait behind urgent ones (D1: N4, N6)

**Files:**
- Create: `ios/App/Net.swift`, `ios/Tests/NetTests.swift`
- Modify:
  - `ios/App/Transit.swift:156-244`
  - `ios/App/NS.swift:87-94` (callers at `:110`, `:139`, `:158`)
  - `ios/App/Go.swift:194, 208, 219, 458`
  - `ios/App/Live.swift:336`
  - `ios/App/TripManager.swift:698`
  - `ios/project.yml`

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
      static let flight: Flight        // the Flight class moved from Transit.swift:172-179, same API (begin, end, busy)
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
  - Use a scaled budget `quick = Budget(idle: 0.4, total: 0.8, retries: 1, backoff: 0.05, fastFailure: 0.2, minLeft: 0.3)` and an actor that records each send time.
  - `test_configuration`: urgent → `timeoutIntervalForRequest` 4, `timeoutIntervalForResource` 8, `waitsForConnectivity` false, `httpMaximumConnectionsPerHost` 6. Background → 8, 15, false.
  - `test_retryDelay`. Each row is urgent with `attempt: 0, took: 0.1, elapsed: 0.1` unless it says otherwise.

    | Input | → |
    |---|---|
    | 503 | 0.3 |
    | 503, took 2.5 | nil |
    | `.networkConnectionLost` | 0.3 |
    | `.networkConnectionLost`, background | 1.0 |
    | `.networkConnectionLost`, elapsed 5.0 | nil |
    | `.timedOut`, `.notConnectedToInternet`, `.cancelled`, 400 | nil |
    | 429 with `Retry-After` "3" | 3 |
    | 429, "6" | nil |
    | 429, "6", background | 6 |
    | 429, "30", background | 10 |
    | 429, nil, background | 1.0 |
    | 429, "Wed, 21 Oct 2026 07:28:00 GMT", background | 1.0 |
    | 503, `attempt: 1` | nil |
  - `test_fastFailureRetriedOnce`: send 1 throws `URLError(.networkConnectionLost)` at once; send 2 returns 200 "ok" → data "ok", `attempts` 2, the second send ≥ 0.05 s after the first.
  - `test_totalLimit`: send sleeps 5 s → throws `.timedOut` within 1.6 s; 1 send.
  - `test_noRetryAfterTimeout`: send throws `.timedOut` after 0.25 s → rethrown; 1 send.
  - `test_noRetryWhenTimeIsUp`: send throws `.networkConnectionLost` after 0.6 s → rethrown; 1 send.
  - `test_429RetryAfterZero`: 429 with `Retry-After: 0`, then 200 → status 200, `attempts` 2.
  - `test_400NotRetried`: 400 → `status` 400, `attempts` 1.
  - `test_backgroundGate`: while an urgent `response` whose send sleeps 1 s is in flight, a background one with `gate: 0.2` and an instant send finishes in < 0.6 s.
  - `test_within`: `Net.within(0.1) { sleep 1 s; return 1 }` → nil in < 0.4 s, and the work sees `Task.isCancelled`.
  - `test_cancelledNotRetried` (Review Focus 4): `response` in a `Task` with a send that sleeps 0.5 s, cancelled after 0.1 s → throws `CancellationError` or `URLError(.cancelled)` within 0.4 s; 1 send.
- [ ] **Step 2: Implement `Net.swift`.**
  - `retryDelay`:
    - `attempt >= budget.retries` → nil.
    - 429 → `min(10, max(0, Double(retryAfter)))`, or `backoff` when it isn't a number. Retry only if `total − elapsed − delay ≥ minLeft`.
    - 5xx, or `.networkConnectionLost`, `.cannotConnectToHost`, `.cannotFindHost`, `.dnsLookupFailed`, `.secureConnectionFailed` → `backoff`. Retry only if `took ≤ fastFailure` and `total − elapsed − backoff ≥ minLeft`.
    - Anything else → nil.
  - `response`:
    - **Gate**: background polls `flight.busy` every 250 ms, for at most `gate` seconds. Urgent wraps its work in `flight.begin()`/`end()`.
    - **Attempts**: each one sends a copy of the request with `timeoutInterval = budget.idle`.
    - **Total limit**: the attempts and pauses race a `budget.total` timer in a throwing task group. When the timer wins, cancel the attempt and throw `URLError(.timedOut)`.
    - **Cancellation** is rethrown at once.
    - **Results**: every HTTP status is returned (a non-HTTP response counts as 200). A transport failure that isn't retried throws its `URLError`.
  - `send` defaults to `session(for: lane).data(for:)`, on two sessions built once from `configuration(for:)`.
- [ ] **Step 3: Route the callers through it.**
  - `Transit.swift`:
    - Delete `within` (156-165), `flight`/`Flight` (171-179) and `urgentSession` (194-199). Keep `urgent` and `trouble`.
    - `raw` builds the URL and User-Agent, then calls `Net.response(req, lane: urgent ? .urgent : .background)`. Status 429 or ≥ 500 → throw `URLError(.badServerResponse)`.
    - Keep today's `trouble.note` texts for urgent calls (230-238).
  - `NS.swift`: `fetch(_ path: String)` loses `timeout` (and `timeout: 15` at `:139`). It uses `Net.response(…, lane: .background)` and keeps `.reloadIgnoringLocalCacheData`. It returns `(json, status)` as today, and `(nil, -1)` when it throws.
  - `Transit.within` → `Net.within` in Go.swift (194, 208, 219, 458) and Live.swift (336).
  - `TripManager.matchVehicles` (698): wrap `Transit.vehicles` in `Transit.$urgent.withValue(going || isRiding)` (N6).
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
  - `ios/App/LiveBus.swift:231-242`
  - `ios/project.yml`

**Interfaces:**
- Consumes: `Transit.raw` (Task 1).
- Produces:
  ```swift
  actor Memo<K: Hashable & Sendable, V: Sendable> {
      init(ttl: TimeInterval, limit: Int = 200, now: @escaping @Sendable () -> Date = { Date() })
      func get(_ key: K, fetch: @escaping @Sendable () async -> V?) async -> V?   // fresh value, else one shared fetch; nil never stored
      func peek(_ key: K) -> V?                                                  // the stored value at any age
  }
  extension Transit {
      struct StationAnswer: Sendable { let stop: NearStop? }
      static let stations: Memo<String, StationAnswer>      // ttl 600
      static let tripAnswers: Memo<String, Data>            // ttl 20, raw /v5/trip answers
      static func nearStopsAnswer(_ c: CLLocationCoordinate2D) async -> [NearStop]?   // nil when the request failed
      static func cachedLiveTrip(_ tripId: String) async -> LiveTrip?               // from tripAnswers.peek, no request
  }
  ```

- [ ] **Step 1: Write `ios/Tests/MemoTests.swift`.** Use a movable clock (`final class TestClock: @unchecked Sendable { var date: Date }`) and an actor that counts fetches.
  - `test_failureNotRemembered`: a fetch returning nil → nil; then a fetch returning 1 → 1; 2 fetches.
  - `test_sharedFetch`: 5 concurrent `get("a")`, with a fetch that sleeps 0.2 s and returns 7 → five 7s, 1 fetch.
  - `test_expiry`: ttl 20, stored at t0. At t0+19 → 1, no fetch. At t0+21 → fetches, returns 2.
  - `test_peekIgnoresAge`: at t0+100 `peek("a")` → 1, and `peek("b")` → nil.
  - `test_limitDropsOldest`: limit 2; store a, b, c → `peek("a")` nil, `peek("c")` 3.
- [ ] **Step 2: Implement `Memo`.** It holds `[K: (V, Date)]` plus the in-flight fetches `[K: Task<V?, Never>]`. Over `limit`, it drops the oldest entry.
- [ ] **Step 3: Use it in `Transit`.**
  - `nearStopsAnswer` is today's `nearStops` body, returning nil when `get` throws or the answer isn't a list. `nearStops` becomes `?? []`.
  - `stationAt` keeps its key: `await stations.get(key) { await nearStopsAnswer(c).map { StationAnswer(stop: $0.first { $0.rail && $0.meters < 350 }) } }?.stop`. Delete `StationMemo`.
  - `tripStops` and `liveTrip` read `/v5/trip` through `tripAnswers.get(tripId) { try? await raw("/v5/trip", …) }`. Their parsing is unchanged; move `liveTrip`'s into `private static func parseLiveTrip(_ json: [String: Any]) -> LiveTrip?`.
  - `cachedLiveTrip` is `peek` + `parseLiveTrip`. Demo trips keep `Demo.liveTrip`.
- [ ] **Step 4: `LiveBusSheet.run`.** Before the loop:
  ```swift
  if trip == nil, let t = await Transit.cachedLiveTrip(target.tripId) {
      trip = t; mine = findMine(t); fit(t, Date())
  }
  ```
  The loop still fetches right away. Append `App/Memo.swift` to `project.yml`.
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: remember only real answers, and ask for each trip once". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 3: The home screen shows each list as soon as it's in (D3: N2, N3, N12)

**Files:**
- Create: `ios/Tests/ProgressiveTests.swift`
- Modify:
  - `ios/App/Net.swift`
  - `ios/App/Live.swift:157-163` (`plans`), `:300-404` (`refresh`), `:407-424` (`boardGrades`)
  - `ios/App/Screens.swift:196-218, 224`

**Interfaces:**
- Produces:
  ```swift
  enum Progressive {
      /// Runs every job at once; after each finishes, `publish` gets everything so far (in finishing order); returns it all.
      static func gather<T: Sendable>(_ jobs: [@Sendable () async -> [T]], publish: @escaping @Sendable ([T]) async -> Void) async -> [T]
      /// Runs every job at once; results in the jobs' order.
      static func all<T: Sendable>(_ jobs: [@Sendable () async -> T]) async -> [T]
  }
  // LiveStore: private struct PanelJob { let from: Place; let to: Place; let modes: String; let count: Int; let maxTransfers: Int }
  //            private func loadPanelsIfDue(_ dir: Direction, key: String, force: Bool) async
  ```

- [ ] **Step 1: Write `ios/Tests/ProgressiveTests.swift`.**
  - `test_gatherPublishesAsTheyCome`: jobs return `[1]`, `[2]` and `[3]` after 0.05, 0.1 and 0.6 s → the first publish (`[1]`) comes in < 0.25 s, the second (2 items) in < 0.35 s; 3 publishes; it returns 3 items after ≥ 0.6 s.
  - `test_allKeepsOrderAndRunsAtOnce`: jobs return 0, 1 and 2 after 0.3, 0.1 and 0.2 s → `[0, 1, 2]` in < 0.55 s.
- [ ] **Step 2: Implement `Progressive`** with `withTaskGroup`. `all` sorts the `(index, value)` pairs by index.
- [ ] **Step 3: `LiveStore`.**
  - In `refresh`, right after `busy = true; loadedFor = key; here = from` (327), start `async let panels: Void = loadPanelsIfDue(dir, key: key, force: force)`. It returns at once when `anywhere`.
  - The trips (329-349) no longer wait for the panels. At the end, `await boards`, set `panelsUpdated` when `anywhere` (352-356), then `await panels`.
  - `loadPanelsIfDue` holds 357-403 with its 120 s gate, `keepBest`, `emptyRetries`, NS task and final `panelsUpdated`. Each list now publishes as soon as its answer is in, if `loadedFor == key`, and an empty answer keeps the last list:
    - To school: the board; `boardRides`; `trains` (the two station jobs through `Progressive.gather`, publishing `keepBest(partial)`); `buas`.
    - Home: `buas`; `trains` (gather); `toVeghel` (gather).
  - `boardGrades`: the 4 plans (`veghel.ids` × [eindhoven, denBosch]) go through `Progressive.all`, then merge in that order, first wins.
  - `plans(from:…)` (161-163): the plans per destination id go through `Progressive.all`.
- [ ] **Step 4: Split the home loop** (`Screens.swift:196-218`) into four `.task(id: trip.direction)` loops. Each runs `while !Task.isCancelled { if scene == .active { … }; sleep 30 s }` and keeps its `Watchdog` marks:
  - (a) `near.locate(ask: true)`, then `live.refresh(…)`;
  - (b) `planner.refresh()`, then `autoGo()`;
  - (c) `SchoolAlarm.shared.refresh()`, then `watch.check()`;
  - (d) `updateOutfit()`, then `OutfitStore.shared.refresh()`.

  At `:224`, start the three refreshes as separate `Task`s.
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: the home screen shows each list as soon as it’s in". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 4: Planned trips, next departures and NS details load side by side (D3, the rest)

**Files:**
- Modify:
  - `ios/App/Planner.swift:200-264` (`refresh`, `buses`)
  - `ios/App/TripManager.swift:1198-1227` (`loadUpcoming`)
  - `ios/App/NS.swift:224-252` (`enrich`)

**Interfaces:**
- Consumes: `Progressive.all` (Task 3). This task adds no logic of its own. Its order and parallelism are pinned by `test_allKeepsOrderAndRunsAtOnce` (Task 3).

- [ ] **Step 1: `Planner.refresh`.**
  - The two train plans ([eindhoven, denBosch]) and `buses(for:)` for the picked trains go through `Progressive.all`, so the options keep the picked order.
  - Inside `buses`, `before` and `after` are `async let`s.
  - Publish `options` (with `inexact`, `pick`, `error`, `updated`, `watchChosen()`) first, then `Task { await NSStore.shared.enrich(…) }` in place of the `await` at 230.
- [ ] **Step 2: `loadUpcoming`.**
  - The plans per destination go through `Progressive.all`.
  - For buses, the board request (1210) is an `async let` started before the plans.
  - NS runs in `Task { await NSStore.shared.enrich(…) }`, so `upcomingBusy` clears at once.
- [ ] **Step 3: `NSStore.enrich`.** The boards per station code, the crowding per group and the sizes per ride (returning `(rideId, TrainSize?)`) each go through `Progressive.all`. Then fill `info` in one pass, with today's rules (240-250).
- [ ] **Step 4: Commit and push, then verify CI.** Commit message: "Reliability: planned trips, next departures and NS details load side by side". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 5: Fastest trip shows the first answer that's in and keeps what arrived (D4: N2, N5)

**Files:**
- Modify:
  - `ios/App/Net.swift`, `ios/Tests/ProgressiveTests.swift`
  - `ios/App/Transit.swift:329-367` (`tripsFrom`), `:446-473` (`fromNearest`)
  - `ios/App/Go.swift:185-202` (`refresh`), `:216-226` (`latestInTime`)

**Interfaces:**
- Consumes: `Progressive` (Task 3).
- Produces:
  ```swift
  extension Net {
      /// The final value if `work` finishes within `seconds`; else the last value it published (or nil) with timedOut, and the work is cancelled.
      static func withPartials<T: Sendable>(_ seconds: Double,
          _ work: @escaping @Sendable (_ publish: @escaping @Sendable (T) async -> Void) async -> T,
          partial: @escaping @Sendable (T) async -> Void) async -> (value: T?, timedOut: Bool)
  }
  extension Transit {
      static func tripsFrom(_ c: CLLocationCoordinate2D, to: Place, count: Int = 5, keep: Int = 5,
                            publish: (@Sendable ([DoorTrip]) async -> Void)? = nil) async -> [DoorTrip]
  }
  ```

- [ ] **Step 1: Add to `ProgressiveTests.swift`.**
  - `test_withPartialsKeepsWhatArrived`: the work publishes "a" at 0.05 s, then sleeps 1 s; limit 0.2 → `("a", true)` in < 0.45 s, and `partial` got `["a"]`.
  - `test_withPartialsFinal`: the work publishes "a" and returns "b" at 0.05 s; limit 1 → `("b", false)`.
  - `test_firstPartialAfterOneRequest`: the work is a `gather` of two counted "requests" (0.05 s and 0.3 s) → at the first `partial`, 1 request has finished.
- [ ] **Step 2: Implement `withPartials`.** A small actor holds the last published value. Race the work against a timer in a task group.
- [ ] **Step 3: `tripsFrom`.**
  - Move the filter (352-366) unchanged into `private static func keepUseful(_ all: [DoorTrip], here: CLLocation, station: NearStop?, now: Date, keep: Int) -> [DoorTrip]`.
  - Start `stationAt` and the from-your-spot plan together. The station plan starts once the station is known.
  - Publish `keepUseful` after the spot plan, and again after the station plan. Return the final list.
  - `fromNearest`: plan its picks through `Progressive.all`.
- [ ] **Step 4: `GoStore.refresh`.**
  - Inside `Transit.$urgent.withValue(true)`, use `Net.withPartials(25, { publish in await Transit.tripsFrom(c, to: d, count: 6, keep: 8, publish: publish) }, partial: …)`.
  - The partial handler (main actor) calls `apply` only when `watching, dest == d, onBoard == nil, best == nil` and the list isn't empty, after setting `slow = false`. So a partial only fills an empty screen and never sends "Faster:" or "Too late".
  - Afterwards: timed out with `best != nil` → keep the screen; otherwise apply `value ?? []`. "No answer within 25 seconds: a slow connection." shows only when it timed out with nothing.
  - `latestInTime` plans per id through `Progressive.all`.
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: Fastest trip shows the first answer that’s in and keeps what arrived". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 6: The home screen shows its last answers at once (D10, part 1: N1)

**Files:**
- Create: `ios/App/Snapshots.swift`, `ios/Tests/SnapshotTests.swift`
- Modify:
  - `ios/App/Transit.swift:5, 47, 65, 83, 497`: add `Codable` to `Ride`, `DoorTrip`, `BoardDeparture`, `Heading`, `NearStop`.
  - `ios/App/Model.swift:5-36`: `Place: Codable`. `CodingKeys` key, name, short, ids, lat, lon, spoken; `init(from:)` goes in an extension so the memberwise init stays.
  - `ios/App/Live.swift`: `PanelTrip` and `BoardRide` get `Codable` (5, 13); `refresh` (312-349); `loadPanelsIfDue`; `loadNear` (249-281).
  - `ios/App/Screens.swift`: `boardFastestContent` (607-626), `nextPass` (1065-1074), `tripsFold` (1258).
  - `ios/project.yml`.

**Interfaces:**
- Produces:
  ```swift
  struct Snapshot<T: Codable>: Codable { let at: Date; let value: T }
  final class SnapshotStore: @unchecked Sendable {
      static let shared: SnapshotStore                                   // <Caches>/answers
      init(directory: URL)
      func save<T: Codable>(_ value: T, key: String, at: Date = Date())  // atomic; creates the folder
      func load<T: Codable>(_ type: T.Type, key: String, maxAge: TimeInterval = 12 * 3600, now: Date = Date()) -> Snapshot<T>?  // unreadable → deleted, nil
      static func fileName(_ key: String) -> String                      // outside [A-Za-z0-9._-] → "_", first 120 characters, + ".json"
  }
  struct PlanKey: Equatable, Sendable { let dir: String; let dest: String; let fromHere: Bool
      var text: String { get } }                                         // today's key at Live.swift:319: "\(dir)|\(dest)|here" or "…|usual"
  enum KeyChange: Equatable, Sendable { case showSaved, keep, clear }
  enum Snapshots {
      static func upcoming<E>(_ items: [E], now: Date, grace: TimeInterval = 60, time: (E) -> Date) -> [E]  // time(e) > now − grace
      static func asOf(_ at: Date, timeZone: TimeZone = .current) -> String                               // "as of 08:12"
      static func onKeyChange(from old: PlanKey?, to new: PlanKey, hasSaved: Bool) -> KeyChange
      static func closeEnough(saved: (lat: Double, lon: Double)?, here: (lat: Double, lon: Double)?, metres: Double) -> Bool
  }
  // LiveStore: @Published private(set) var nextAsOf: Date?, panelsAsOf: Date?, nearAsOf: Date?
  //   struct SavedTrips: Codable { let trips: [DoorTrip]; let lat: Double?; let lon: Double? }                  key "next|\(planKey.text)"
  //   struct SavedPanels: Codable { var board: [BoardDeparture]; var rides: [String: BoardRide]
  //                                 var trains: [PanelTrip]; var buas: [PanelTrip]; var toVeghel: [PanelTrip] }  key "panels|\(dir.rawValue)"
  //   struct SavedNear: Codable { let stops: [Transit.NearStop]; let board: [BoardDeparture]; let lat: Double; let lon: Double }   key "near"
  ```

- [ ] **Step 1: Write `ios/Tests/SnapshotTests.swift`.** Each test gets a fresh temporary directory and uses the test type `struct Dep: Codable, Equatable { let id: String; let time: Date }`.
  - `test_roundTripAndAge`: save 3 deps at t0. Load at t0+30 → `at` == t0, 3 items. With `maxAge: 60`, load at t0+61 → nil.
  - `test_firstPaintFiltersDeparted`: saved deps at t0−120, t0+60 and t0+300 → `load` then `upcoming(now: t0)` gives 2 items, keeps `at`, and takes < 100 ms.
  - `test_fileName`: `"next|toSchool||here"` → `"next_toSchool__here.json"`. A key of 300 × "x" → 125 characters.
  - `test_corruptSnapshotIgnored` (Review Focus 5): "not json" in the key's file → `load` returns nil, and the file is gone.
  - `test_asOf`: 2026-11-16 07:12 UTC in Europe/Amsterdam → `"as of 08:12"`.
  - `test_onKeyChange`, with `usual = PlanKey(dir: "toSchool", dest: "", fromHere: false)`:

    | old → new | saved | → |
    |---|---|---|
    | nil → usual | yes | `.showSaved` |
    | nil → usual | no | `.clear` |
    | usual → the same key with `fromHere: true` | no | `.keep` |
    | here → usual | yes | `.showSaved` |
    | toSchool → home | no | `.clear` |
    | dest "a" → dest "b" | no | `.clear` |
  - `test_closeEnough`:

    | saved | here | metres | → |
    |---|---|---|---|
    | nil | any | — | true |
    | 250 m apart | | 300 | true |
    | 450 m apart | | 400 | false |
    | present | nil | — | false |
- [ ] **Step 2: Implement `Snapshots.swift`.**
  - `asOf` uses `en_US_POSIX` `"HH:mm"` in `timeZone`.
  - `closeEnough` uses flat-earth distance (`kx = cos(lat) × 111 320`, `ky = 110 540`).
  - `onKeyChange`: saved → `.showSaved`; else the same dir and dest → `.keep`; else `.clear`.
- [ ] **Step 3: `LiveStore`.**
  - Build `PlanKey(dir: dir.rawValue, dest: custom?.id ?? "", fromHere: from != nil)`. Keep it in `loadedKey`, beside `loadedFor`.
  - **The key-change wipe at 321-324** becomes `onKeyChange` on the saved `next`. That answer is filtered by `first.departure` and used only when `closeEnough(…, metres: 300)` to `from`.
    - `.showSaved`: set `next`, `nextAsOf = at` and `pick = 0`.
    - `.keep`: the lists stay, and `nextAsOf = nextAsOf ?? updated`.
    - `.clear`: `next = []`, `nextAsOf = nil` and `pick = 0`.
    - Every case also sets `nextError = nil`, `updated = nil`, `panelsUpdated = nil` and `lastPanels = .distantPast`.
  - **Panels.** On a direction change, or the first load, show the new direction's saved panels: the board filtered by `cancelled ? scheduled : time`, the trips by `trip.first.departure`, and `panelsAsOf = at`. With nothing saved, clear them.
  - **Boards near you.** On entering "here", keep `nearBoard` only if `nearAt` is within 300 m of `from`. Otherwise use the saved `"near"` answer if it's close enough (`nearAsOf = at`), or else clear.
  - **Saving.** After a non-empty live `next`, set `nextAsOf = nil` and save `SavedTrips` (lat/lon of `from`; nil for the usual start). After a panels round that got any list, set `panelsAsOf = nil` and save `SavedPanels`. After a non-empty `loadNear` board, set `nearAsOf = nil` and save `SavedNear`.
- [ ] **Step 4: Labels (`Screens.swift`).**
  - In `boardFastestContent` under the time chips, and in `nextPass` under the boarding pass: when `live.nextAsOf` is set, show `Text(Snapshots.asOf(a))`. Use `BoardInk.sans(10, .regular)` at 0.6 ink opacity in `boardFastestContent`, and `HWFont.body(10)` muted in `nextPass`.
  - In `tripsFold` (1258): when `live.panelsAsOf` is set, show `"\(Snapshots.asOf(a))."` in place of "Updated at …".
  - `project.yml`: append `App/Snapshots.swift`.
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: the home screen shows its last answers at once, marked as of when". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 7: Next departures and Fastest trip start from their last answer (D10, part 2)

**Files:**
- Modify:
  - `ios/App/TripManager.swift:70-73, 338, 1193-1227`
  - `ios/App/Go.swift:19-35, 100-129, 201-213, 1088`
  - `ios/App/Features.swift:744-762`
  - `ios/App/Screens.swift:1521, 2006`

**Interfaces:**
- Consumes: `SnapshotStore`, `Snapshots.upcoming`, `asOf`, `closeEnough`, and the `Codable` types (Task 6).
- Produces:
  - `TripManager`: `@Published private(set) var upcomingAsOf: Date?`; `struct SavedUpcoming: Codable { let upcoming: [PanelTrip]; let board: [BoardDeparture] }` under key `"upcoming|\(upcomingKey)"`.
  - `GoStore`: `@Published private(set) var asOf: Date?`; `struct SavedGo: Codable { let trips: [DoorTrip]; let lat: Double; let lon: Double }` under key `"go|\(dest.key)"`.
  - `TransferList`: `var asOf: Date? = nil`.

- [ ] **Step 1: `loadUpcoming`.** On a key change (1194), show the new key's saved answer, filtered by departure, with `upcomingAsOf = at`; with nothing saved, clear as today. After a live answer with content, set `upcomingAsOf = nil` and save. `endTrip` resets `upcomingAsOf`.
- [ ] **Step 2: `GoStore`.**
  - In `begin`, when `seed` is empty, try `"go|\(d.key)"`: `maxAge: 1800`, `closeEnough(…, metres: 400)` to `fallback ?? trip?.lastFix`, filtered by `first.departure > now`. It goes through the seed path (115-119), with `asOf = at`.
  - `begin` resets `asOf` (103).
  - After each live `apply` in `refresh` that leaves a `best`, set `asOf = nil` and save `[best] + others` with the location.
- [ ] **Step 3: Labels.**
  - `TransferList`'s sub: `asOf.map { Snapshots.asOf($0) } ?? updated.map { "updated \(Fmt.hhmm($0))" }`. Pass `asOf: trip.upcomingAsOf` at `Screens.swift:2006`.
  - `Screens.swift:1521`: `"\(Snapshots.asOf(a))."` in place of "Updated at …".
  - `Go.swift:1088`: when `asOf` is set, `"\(Snapshots.asOf(a)) · checking again…"`.
- [ ] **Step 4: Commit and push, then verify CI.** Commit message: "Reliability: next departures and Fastest trip start from their last answer". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 8: The vehicle matcher as pure code, and the live flag from the map (D5)

**Files:**
- Create: `ios/App/Geo.swift`, `ios/App/VehicleMatch.swift`, `ios/Tests/MatchFixtures.swift`, `ios/Tests/GeoTests.swift`, `ios/Tests/VehicleMatchTests.swift`, `ios/Tests/DecideTests.swift`
- Modify: `ios/App/Transit.swift:108-117` (`VehicleSegment`), `:597-613` (`vehicles(near:)`); `ios/project.yml`

**Interfaces:**
- Produces:
  ```swift
  struct GeoPoint: Hashable, Codable, Sendable { var lat: Double; var lon: Double }
  enum Geo {
      static func metres(_ a: GeoPoint, _ b: GeoPoint) -> Double      // flat-earth as Live.swift:222 (kx from a's latitude)
      static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double     // 0..<360, as Transit.swift:96-99
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
      static func group(_ pieces: [MapPiece]) -> [VehicleTrack]       // per trip; identical pieces once; live if any piece is
  }
  struct Evidence: Equatable, Sendable { let fixes: Int; let span: TimeInterval; let crossTrack: Double; let accuracy: Double
      let shaped: Bool; let progress: Double; let offset: Double; let drift: Double; let yourSpeed: Double; let itsSpeed: Double; let steady: Bool }
  enum Reject: Error, Equatable, Sendable { case tooFewFixes, offItsPath, wrongWay, implausibleSpeed, standing, drifting, tooFarFromTimes, noTimes }
  struct Judgement: Equatable, Sendable { let id: String; let line: String; let isTrain: Bool; let realTime: Bool
                                          let evidence: Evidence?; let result: Result<Double, Reject> }
  struct Ranked: Equatable, Sendable { let id: String; let cost: Double }
  struct SwitchState: Equatable, Sendable { var leader: String? = nil; var looks = 0; var since: Date? = nil }
  enum Decision: Equatable, Sendable { case keep(String), switchTo(String), undecided([String]), none }
  enum VehicleMatch {
      static func tolerance(isTrain: Bool, speed: Double) -> Double     // moved from Live.swift:110-113, same values
      static func timePosition(_ v: VehicleTrack, at t: Date) -> Double?
      static func evidence(_ fixes: [Fix], _ v: VehicleTrack) -> Evidence?
      static func judge(_ e: Evidence, isTrain: Bool, realTime: Bool, strictTimes: Bool = true) -> Result<Double, Reject>
      static func judgeAll(_ fixes: [Fix], _ vs: [VehicleTrack], strictTimes: Bool = true) -> [Judgement]
      static func judgeOne(_ f: Fix, _ v: VehicleTrack, tolerance: Double) -> Judgement
      static func rank(_ judged: [Judgement], planned: String?, plannedBonus: Double = 45) -> [Ranked]
      static func decide(shown: String?, ranked: [Ranked], liveIds: Set<String>, state: inout SwitchState, now: Date,
                         margin: Double = 60, looks: Int = 3, span: TimeInterval = 45) -> Decision
  }
  // VehicleSegment gains `var realTime = false; var toLat: Double? = nil; var toLon: Double? = nil`.
  // Transit.vehicles(near:radiusDeg:back:ahead:allTrips: Bool = false).
  ```
  The spec's values are `static let` constants on `VehicleMatch`:

  | Constant | Value | Constant | Value | Constant | Value |
  |---|---|---|---|---|---|
  | `window` | 30 s | `minSpan` | 20 s | `minFixes` | 3 |
  | `maxAccuracy` | 150 | `offPath` | 60 | `offPathUnshaped` | 250 |
  | `accuracyFactor` | 1.5 | `backwards` | 20 | `busMax` | 31 |
  | `speedRatio` | 3 | `steadyShare` | 0.3 | `driftMin` | 3 |
  | `driftShare` | 0.25 | `standingMin` | 40 | `standingShare` | 0.2 |
  | `costSpeedMin` | 5 | `oneFixTurn` | 75 | `slack` | 30 s |

- [ ] **Step 1: Write `ios/Tests/MatchFixtures.swift`.** Put the helpers in `enum Fx`, so they can't collide with other tests:
  ```swift
  static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  static func east(_ m: Double, north: Double = 0) -> GeoPoint     // lat 51.59 + north/110 540, lon 4.70 + m/(111 320·cos 51.59°)
  static let railway = [east(0), east(3000), east(6900)]           // 3 points: shaped
  static func road(north: Double) -> [GeoPoint]                    // the railway shifted north
  static func fixes(from m0: Double, speed: Double, count: Int, every: Double = 2, north: Double = 0,
                    accuracy: Double = 20, course: Double = 90, start: Date = t0) -> [Fix]  // fix k: start + k·every, east(m0 + speed·k·every, north)
  static func track(_ id: String, line: String = "IC", train: Bool = true, live: Bool = true,
                    path: [GeoPoint], at m0: Double, speed: Double, start: Date = t0) -> VehicleTrack   // one piece; its times: m0 m along at `start`, `speed` m/s
  static func ok(_ j: [Judgement], _ id: String) -> Double?        // the cost, if it passed
  static func why(_ j: [Judgement], _ id: String) -> Reject?       // the reject, if it failed
  ```
- [ ] **Step 2: Write `ios/Tests/GeoTests.swift`.**
  - `test_metres`: east(0) → east(6900) is 6900 ± 10.
  - `test_projectMiddle`: `east(500, north: 50)` on [east(0), east(1000)] → crossTrack 50 ± 1, along 500 ± 2, fraction 0.5 ± 0.01, bearing 90 ± 0.5.
  - `test_projectBeyondEnd`: `east(1100)` → along 1000 ± 1, fraction 1, crossTrack 100 ± 1.
  - `test_degenerate`: a one-point path → nil; two identical points → nil.
  - `test_pointAtMetres`: 250 → `east(250)` (± 0.5 m); 5000 → the last point; −10 → the first; `[]` → nil.
  - `test_bearing`: north 0, east 90, south 180, west 270 (± 0.5).
- [ ] **Step 3: Write `ios/Tests/VehicleMatchTests.swift`.** "You" means `Fx.fixes(from: 2000, …)` unless stated otherwise.
  - `test_tolerancePinsToday`: (train, 30) 1800; (bus, 30) 1000; (train, 5) 600; (bus, 5) 400.
  - `test_timePosition`: two 1000 m pieces, running 0–60 s and 90–150 s → 500 at t0+30, 1000 at t0+75, 1500 at t0+120, 2000 at t0+170, nil at t0+200, nil at t0−40.
  - `test_zeroDurationPiece` (Review Focus 1): pieces along the railway: 0–60 s (0→1000 m), 60–60 s (1000→1500 m), 60–120 s (1500→2500 m).
    - At t0+60: finite and in 1000…1500. At t0+90: 2000 ± 1.
    - `evidence(Fx.fixes(from: 1000, speed: 25, count: 15, start: t0+40), track)` is non-nil, with every field finite.
  - `test_S1_busOnRoadBesideRailway`: you are 15 fixes on the railway at 30 m/s. Train "T": live, `at: 1100`, 30 m/s. Bus "B" (`train: false`) on `road(north: 200)`: `at: 2300`, 12 m/s → B `.offItsPath`; T costs 30 ± 1; `rank` ids `["T"]`.
  - `test_S1b_busOnCloseRoad`: as S1, with B on `road(north: 50)` → B `.drifting`.
  - `test_busTooFast`: you at 35 m/s on `road(north: 50)`; a bus there at 2000 m and 35 m/s → `.implausibleSpeed`.
  - `test_S2_trainPassingYourBus`: you are 15 fixes on `road(north: 50)` at 12 m/s. Bus "B" there: `at: 1900`, 12 m/s. Train "T" on the railway: `at: 1500`, 30 m/s → T `.drifting`; `rank` ids `["B"]`.
  - `test_S3_oppositeTrainsWithoutCourse`: you at 30 m/s, `course: -1` on every fix. "A" eastbound: `at: 1400`, 30 m/s. "B" on `railway.reversed()`: `at: length − 2200`, 30 m/s → B `.wrongWay`; A costs 20 ± 1.
  - `test_S4_leavingAStation`: you accelerate from east(2000): x(t) = 2000 + t²/6 up to t = 30, then 10 m/s, a fix every 2 s. The train is on the railway (`at: 2000`, 10 m/s). The bus's path leaves the railway at east(2050) heading 50° (40° left of the railway), with `at: 2000` and 10 m/s.
    - Fixes t0…t0+4 → both `.tooFewFixes`.
    - Fixes t0…t0+40 → bus `.offItsPath`; the train passes.
  - `test_S6_busStandingAtYourStop`: you leave `east(2000, north: 50)` at 8 m/s, a fix every 1.25 s, 17 fixes. Bus "S" on that road has a piece arriving at 2000 m at t0−5 and the next departing 2000 m at t0+20 → `.standing`.
  - `test_S7_oldFixUsesItsOwnTime`: one fix at t0−20 at east(2000), 30 m/s, course 90. Train `at: 2000`, 30 m/s, `start: t0−20` → `judgeOne(…, tolerance: 1800)` passes with cost < 1.
  - `test_timetableOnlyKeptAsCandidate`: you at 12 m/s on `road(north: 50)`. Bus "A" (`live: false`) there: `at: 5000`, 12 m/s → `.tooFarFromTimes` with `strictTimes: true`; it passes with `strictTimes: false`.
  - `test_unshapedPathLenient` (Review Focus 2): you at 12 m/s, `north: 150`. A bus at 2000 m and 12 m/s on [east(0), east(6900)] → not `.offItsPath`. The same bus on `railway` → `.offItsPath`.
  - `test_badFixesIgnored` (Review Focus 3): the S1 fixes plus one mid-window fix with accuracy 500 at `east(2400, north: 2000)` → `judgeAll` equals the result without it.
  - `test_S10_plannedBonus`: synthetic successes "p" 70 and "o" 40 with `planned: "p"` → `[Ranked(id: "p", cost: 25), Ranked(id: "o", cost: 40)]`.
  - `test_groupSharedPieces`: two identical `MapPiece`s of "x", a later "x" piece and a "y" piece → 2 tracks; "x" has 2 pieces, in departure order.
- [ ] **Step 4: Write `ios/Tests/DecideTests.swift`.** Looks come at t0, t0+24 and t0+48 unless a test says otherwise.
  - `test_S5_timetableOnlyKeepsShown`: shown "A" (not live); ranked [B 4, A 250]; `liveIds: ["B"]`; 10 looks 12 s apart → all `.keep("A")`.
  - `test_S5b_switchAfterThreeLooks`: both live, [B 10, A 100] → `.keep("A")`, `.keep("A")`, `.switchTo("B")`.
  - `test_S5c_runRestarts`: leads 90, 30, 90, and 90 at t0+72 → four `.keep("A")`.
  - `test_threeLooksTooQuick`: a lead of 90 at t0, t0+10 and t0+20 → three `.keep`; at t0+50 → `.switchTo("B")`.
  - `test_shownRejectedSwitches`: ranked [B 10] (A failed the tests), both live → keep, keep, `.switchTo("B")`.
  - `test_S8_sharedRoadUndecided`: shown nil, all live; b1 10, b2 12, b3 40, b4 80, b5 90 → `.undecided(["b1", "b2", "b3"])`.
  - `test_clearWinnerNoShown`:
    - [b1 10, b2 200], both live → `.switchTo("b1")`;
    - the same with b2 timetable-only → `.undecided(["b1", "b2"])`;
    - one candidate → `.switchTo`;
    - `[]` → `.none`.
- [ ] **Step 5: Implement `Geo.swift` and `VehicleMatch.swift`.**
  - **`timePosition`.** Join the pieces in departure order; each piece starts at the joined length before its first point.
    - Inside a piece, interpolate by time. A zero-length piece puts the vehicle at the piece's end.
    - Between pieces: the start of the next one.
    - Within `slack` before the first piece or after the last: that end.
    - Otherwise nil.
  - **`evidence`.** First drop fixes with accuracy > `maxAccuracy`. Then keep those within `window` of the newest remaining fix that have a time position; with fewer than 2, return nil. Then:
    - `crossTrack`: the median of the last 3 projections.
    - `progress`: along(last) − along(first). `offset`: at the last fix.
    - `drift`: (offset last − offset first) / span. `yourSpeed`: |progress| / span. `itsSpeed`: from the time positions at the first and last fix.
    - `steady`: split the span into halves by time; both speeds ≥ 3, and their difference ≤ `steadyShare` × the larger.
    - `shaped`: some piece has more than 2 points.
  - **`judge`.** The spec's hard-test table, tests 1–7 in order. When `strictTimes == false && !realTime`, skip the ratio part of test 4 and tests 5, 6 and 7. Success = |offset| / max(`costSpeedMin`, itsSpeed).
  - **`judgeAll`.** `.noTimes` when `evidence` is nil.
  - **`judgeOne`.** The spec's "One fix only".
  - **`rank`.** Successes only; subtract the bonus from `planned`'s cost; sort by cost, then id.
  - **`decide`.** The spec's "Decide, with hysteresis" rules. Reset the state on `.none`, on `.switchTo`, and on every `.keep` that isn't counting a look.
- [ ] **Step 6: Map parsing (`Transit.swift`). Behaviour stays the same by default.**
  - `vehicles(near:)` reads `s["realTime"]` and the `to` stop's `lat`/`lon`.
  - With `allTrips: true`, it makes one segment per entry of `trips` (S9). The default stays the first trip only.
  - `project.yml`: append `App/Geo.swift` and `App/VehicleMatch.swift`.
- [ ] **Step 7: Commit and push, then verify CI.** Commit message: "Reliability: a vehicle matcher that checks you move with it, as pure tested code". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 9: A connection and matching log in Settings, and the classic matching switch (D9)

**Files:**
- Create: `ios/App/FieldLog.swift`, `ios/Tests/FieldLogTests.swift`
- Modify:
  - `ios/App/Net.swift`, `ios/App/Transit.swift` (`raw`), `ios/App/NS.swift` (`fetch`)
  - `ios/App/VehicleMatch.swift`, `ios/Tests/VehicleMatchTests.swift`
  - `ios/App/Diagnostics.swift` (after `FreezeSection`)
  - `ios/App/Screens.swift:220-226, 2048`
  - `ios/project.yml`

**Interfaces:**
- Consumes: `Lane` (Task 1); `Judgement`, `Reject`, `Evidence` and `Decision` (Task 8).
- Produces:
  ```swift
  struct FieldEntry: Codable, Equatable, Sendable { enum Kind: String, Codable, Sendable { case net, match }
                                                    let at: Date; let kind: Kind; let text: String }
  final class FieldLog: @unchecked Sendable {
      static let shared: FieldLog                                          // UserDefaults.standard
      init(defaults: UserDefaults, key: String = "fieldLog.v1", limit: Int = 400)
      func add(_ kind: FieldEntry.Kind, _ text: String, at: Date = Date())   // newest first; written at most every 5 s
      func flush()
      var entries: [FieldEntry] { get }
      func clear()
      func export(timeZone: TimeZone = .current) -> String                 // a line per entry: "08:12:03 net <text>"
  }
  enum FieldFormat {
      static func net(_ path: String, lane: Lane, status: Int?, error: URLError.Code?, bytes: Int, seconds: Double, attempts: Int) -> String
      static func label(_ id: String, _ lines: [String: String]) -> String   // "306·a1b2": the line, "·", the last 4 of the trip id
      static func reject(_ r: Reject, _ e: Evidence?) -> String
      static func match(_ place: String, _ judged: [Judgement], outcome: String) -> String
      static func outcome(_ d: Decision, lines: [String: String]) -> String
      static func classic(_ place: String, _ found: [(label: String, metres: Double)]) -> String
  }
  enum MatchSettings { static let key = "classicMatching"; static func classic(_ d: UserDefaults = .standard) -> Bool }
  // Net.response(…, label: String? = nil): with a label, one .net entry per call
  struct FieldLogSection: View                                             // Diagnostics.swift
  ```

- [ ] **Step 1: Write `ios/Tests/FieldLogTests.swift`.**
  - `test_newestFirstAndLimit`: limit 3; add a, b, c, d → `["d", "c", "b"]`.
  - `test_persistsAfterFlush`: add 2, then `flush()`; a new `FieldLog` on that suite reads the same 2. After `clear()` and `flush()`, a new one is empty.
  - `test_netFormat`:

    | Input | → |
    |---|---|
    | ("/v5/plan", .urgent, 200, nil, 31_950, 2.43, 1) | `"/v5/plan · 200 · 31.2 KB · 2.4 s · 1 try · urgent"` |
    | ("/v5/trip", .background, nil, .timedOut, 0, 15.0, 1) | `"/v5/trip · timed out · 0 B · 15.0 s · 1 try · background"` |
    | ("/ns/departures", .background, 503, nil, 512, 0.4, 2) | `"/ns/departures · 503 · 512 B · 0.4 s · 2 tries · background"` |

    The other error texts are: `.notConnectedToInternet` "offline", `.networkConnectionLost` "connection lost", `.cancelled` "cancelled", and anything else "error <rawValue>".
  - `test_rejectFormat`:

    | Reject (evidence) | → |
    |---|---|
    | tooFewFixes | "too few fixes" |
    | offItsPath (crossTrack 180.4) | "off its path 180 m" |
    | wrongWay | "going the other way" |
    | implausibleSpeed (you 30.2, it 12) | "wrong speed (you 30 m/s, it 12)" |
    | standing | "standing by its times" |
    | drifting (−18.3) | "drifting 18 m/s" |
    | tooFarFromTimes (offset −2400) | "2400 m from its times" |
    | noTimes | "no times now" |
  - `test_matchFormat`: "detect"; "x-a1b2" IC live, cost 30.4; "y-c3d4" 306 timetable, offItsPath with crossTrack 180; outcome "keep IC·a1b2" → `"detect · IC·a1b2 live 30 s | 306·c3d4 timetable off its path 180 m → keep IC·a1b2"`. Passes come first, by cost, then rejects; at most 6.
  - `test_outcomeFormat`, with lines `["x-a1b2": "IC", "y-c3d4": "306"]`:

    | Decision | → |
    |---|---|
    | keep | "keep IC·a1b2" |
    | switchTo | "switch to IC·a1b2" |
    | undecided | "undecided: IC·a1b2, 306·c3d4" |
    | none | "none" |
  - `test_classicFormat`: ("detect", [("306·a1b2", 120.4), ("305·c3d4", 310)]) → `"detect (classic) · 306·a1b2 120 m | 305·c3d4 310 m"`.
  - `test_export`: an entry at 07:12:03 UTC, net, "x", in Europe/Amsterdam → `"08:12:03 net x"`.
  - In `VehicleMatchTests`, `test_newMatcherIsDefault`: a fresh suite → `classic(d)` false; after `d.set(true, forKey: MatchSettings.key)` → true.
- [ ] **Step 2: Implement `FieldLog.swift` and `MatchSettings`.** `FieldLog` keeps its entries behind an `NSLock` and stores them as JSON. `add` marks the log dirty and schedules a `flush` 5 s later, if none is pending.
- [ ] **Step 3: Log the requests.** `Net.response` gets a final `label: String? = nil`. With a label, it logs `FieldFormat.net(…)` once per call: on success, failure or timeout. `Transit.raw` passes `path`; `NSStore.fetch` passes the path up to the `?`.
- [ ] **Step 4: Settings.**
  - `FieldLogSection` is a `Section("Vehicle matching")` holding:
    - `Toggle("Classic vehicle matching", isOn: @AppStorage(MatchSettings.key))`, with the spec's footer;
    - `NavigationLink("Connection and matching log")`.
  - The log screen:
    - entries newest first: the time in `HWFont.body(12, bold: true)`, the text in `.system(size: 11, design: .monospaced)`;
    - "Nothing logged yet." when it's empty;
    - "Copy the log" (`UIPasteboard`; the button then reads "Copied: paste it in the chat") and "Clear";
    - the spec's footer.
  - Insert `FieldLogSection()` after `FreezeSection()` (`Screens.swift:2048`). In `.onChange(of: scene)` (220), call `FieldLog.shared.flush()` on `.background`.
  - `project.yml`: append `App/FieldLog.swift`.
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: a connection and matching log in Settings, and the classic matching switch". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 10: Road lookups at the fix's own time, and no first-come pick on a shared road (D6: S7, S8)

**Files:**
- Create: `ios/App/MatchBridge.swift`
- Modify:
  - `ios/App/VehicleMatch.swift`, `ios/Tests/VehicleMatchTests.swift`
  - `ios/App/Live.swift:198-217` (`vehiclesByRoad`)
  - `ios/App/TripManager.swift:145` (add `recentFixes`), `:886-887`, `:968-989` (`findBusYoureOn`)

**Interfaces:**
- Consumes: Task 8; `FieldLog`, `FieldFormat` and `MatchSettings` (Task 9); `Progressive.all` (Task 3); the trip memo (Task 2).
- Produces:
  ```swift
  struct RoadHit: Equatable, Sendable { let tripId: String; let line: String; let isTrain: Bool; let late: TimeInterval }
  extension VehicleMatch {
      /// Pieces whose road you're on (≤ maxMetres) going your way (course within maxTurn of the road's bearing); late = f.t − when its times
      /// have it at your spot; |late| < maxLate; per trip the least late; least late first.
      static func byRoad(_ f: Fix, _ pieces: [MapPiece], maxMetres: Double = 100, maxTurn: Double = 60, maxLate: TimeInterval = 720) -> [RoadHit]
      static func otherKindPossible(_ r: Reject?) -> Bool          // implausibleSpeed or drifting
  }
  // MatchBridge.swift (app-only, imports CoreLocation):
  extension GeoPoint { init(_ c: CLLocationCoordinate2D) }
  extension Fix { init(_ l: CLLocation) }                          // timestamp, coordinate, horizontalAccuracy, speed, course
  extension MapPiece { init(_ s: VehicleSegment) }                 // trains: Transit.trainLabel(line)
  extension VehicleTrack { init?(tripId: String, line: String, isTrain: Bool, trip: LiveTrip) }
      // a piece per stop pair: departure(i), arrival(i+1), trip.road(from: metres(ofStop: i), to: metres(ofStop: i+1)); realTime = trip.live; nil without a piece
  // TripManager:
  var recentFixes: [Fix] { get }                                   // samples of the last 120 s with 0 ≤ accuracy < 150
  private func findBusYoureOn(not v: Vehicle, at here: CLLocation, limit: Double) async -> (vehicle: Vehicle, stops: [TripStop], others: [Vehicle])?
  ```

- [ ] **Step 1: Add to `VehicleMatchTests.swift`.**
  - `test_byRoadUsesFixTime`: a fix at t0−20 at east(2000), course 90. A railway piece whose times have it at 2000 m at t0−20 → one hit with `late` 0 ± 2.
  - `test_byRoadSkipsOtherWay`: the same piece on `railway.reversed()` → `[]`.
  - `test_byRoadLeastLateFirst`: two trips, 120 s and −30 s late → [−30, 120].
  - `test_otherKindPossible`: `.implausibleSpeed` and `.drifting` → true; `.offItsPath` and nil → false.
- [ ] **Step 2: Implement `byRoad`, `otherKindPossible` and `MatchBridge.swift`.**
- [ ] **Step 3: `vehiclesByRoad`.** The classic branch is today's body. The new branch fetches with `allTrips: true` and returns `VehicleMatch.byRoad(Fix(f), segs.map(MapPiece.init))` as today's tuples. Keep the guard at 199.
- [ ] **Step 4: `findBusYoureOn`.** The classic branch is today's body with `others: []`. The new branch:
  - `anyKind`: `route?.isFixed == false && otherKindPossible(…)` of the current vehicle, judged by `judgeAll(recentFixes, [VehicleTrack(…, trip: roadOf.trip)], strictTimes: false)` when `roadOf?.tripId == v.tripId`.
  - Candidate ids as today: planned, then `boardAlternatives`, then `matchVehicles(mode: anyKind ? nil : leg?.mode, excluding: [v.tripId])`. Deduplicate, keep at most 8, and skip the other kind unless `anyKind`.
  - Fetch their `liveTrip`s through `Progressive.all` and make tracks.
  - Then `judgeAll(recentFixes, tracks, strictTimes: false)`, `rank(…, planned: route?.planned?[safe: index]?.tripId)` and `decide(shown: nil, …)`:
    - `.switchTo(x)` → `(x, its stops, [])`;
    - `.undecided(xs)` → `(xs[0], its stops, the rest)`;
    - `.none` → nil.
  - Log `FieldFormat.match("find", …, outcome: FieldFormat.outcome(d, lines:))`.
- [ ] **Step 5: `checkSameBus` (886-887).** After `switchVehicle(…, to: found.vehicle, …)`, if `found.others` isn't empty, call `beginChoosing([found.vehicle] + found.others)`.
- [ ] **Step 6: Commit and push, then verify CI.** Commit message: "Reliability: road lookups at the fix’s own time, and no first-come pick on a shared road". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 11: Pick the bus or train that moves with you (D7)

**Files:**
- Modify:
  - `ios/App/VehicleMatch.swift`, `ios/Tests/VehicleMatchTests.swift`
  - `ios/App/TripManager.swift`: `:8-14` (add `Match`), `:418-425`, `:605-673`, `:686-731`, `:878`, `:1041`
  - `ios/App/Live.swift:119-193` (`onBoardTrips`, `plans`)
  - `ios/App/Go.swift:458, 464-481, 491-525`

**Interfaces:**
- Consumes: Tasks 8–10.
- Produces:
  ```swift
  struct MatchRules: Equatable, Sendable {
      let oneLook: Double; let oneLookWatched: Double; let expected: Double; let plannedEdge: Double; let close: Double; let sameLineNear: Double
      static let classic = MatchRules(oneLook: 150, oneLookWatched: 250, expected: 350, plannedEdge: 200, close: 300, sameLineNear: 400)  // metres: today
      static let seconds = MatchRules(oneLook: 15, oneLookWatched: 20, expected: 30, plannedEdge: 0, close: 60, sameLineNear: 40)       // seconds off its times
      static func current(_ d: UserDefaults = .standard) -> MatchRules
  }
  struct Match: Equatable { let vehicle: Vehicle; let meters: Double; let score: Double }   // TripManager.swift; score: metres (classic) or seconds
  func matchVehicle(mode: Mode?, excluding: Set<String> = []) async -> Match?
  func matchVehicles(mode: Mode?, excluding: Set<String> = [], planned: String? = nil, place: String = "match") async -> [Match]
  static func onBoardTrips(_ f: CLLocation, to dest: Place, tripId: String? = nil, wasMoving: Bool = false,
                           late: TimeInterval? = nil, line: String? = nil, isTrain: Bool? = nil, history: [Fix] = []) async -> (OnBoard, [DoorTrip])?
  ```

- [ ] **Step 1: Add to `VehicleMatchTests.swift`.**
  - `test_rulesPinToday`: `MatchRules.classic` has exactly the values above.
  - `test_rulesFollowTheSwitch`: a fresh suite → `.seconds`; with classic on → `.classic`.
- [ ] **Step 2: `matchVehicles`.**
  - The classic branch is today's body (`allTrips: false`, score = metres), plus a `FieldFormat.classic(place, …)` log entry.
  - The new branch:
    - keep the speed gate (693-696), and fetch urgent as in Task 1, with `allTrips: true`;
    - `VehicleTrack.group(segs.map(MapPiece.init))`, filtered by `mode` and `excluding`;
    - `judgeAll(recentFixes, tracks)`, then `rank(…, planned:)`;
    - return a `Match` per ranked track, with `meters = |evidence.offset|` and `score = cost`;
    - log `FieldFormat.match(place, judged, outcome:)`. The outcome is `"best " + FieldFormat.label(first id, lines)`, or "none".
  - `matchVehicle` returns `.first`.
- [ ] **Step 3: Use `R = MatchRules.current()` in place of the metre literals.**
  - `startDetecting` calls `matchVehicles(mode: nil, excluding: rejected, planned: planned?.tripId, place: "detect")`. Then:
    - 638: `pm.score < m.score + R.plannedEdge`;
    - 642: `m.score < R.expected`;
    - 644: `m.score < R.oneLook`;
    - 661: `$0.score < m.score + R.close`.
  - The idle line watch (423): `m.score < R.oneLookWatched`.
  - `checkSameBus` (878): `$0.score < R.sameLineNear`, with place "same bus".
  - `Go.firstLook` confirms with `matchVehicles(mode: nil, planned: v.tripId, place: "confirm")`; 470: `R.close`.
  - `Go.checkBoarding` uses `matchVehicles(mode: nil, planned: best?.first.tripId, place: "board")`. Then:
    - 502: `bm.score < m.score + R.plannedEdge`;
    - 505: `R.close`;
    - 509: `m.score < R.oneLookWatched`.
  - `matchMeters = Int(m.meters)` stays.
- [ ] **Step 4: `onBoardTrips`.**
  - **Choosing.** The classic branch, and every call with a `tripId`, choose as today. The new branch, for `tripId == nil`:
    - tracks from `vehicles(near:…, allTrips: true)`;
    - when `history` spans ≥ 20 s, `judgeAll(history, tracks)`;
    - otherwise `judgeOne(Fix(f), track, tolerance: still ? 250 : VehicleMatch.tolerance(isTrain:, speed: speedNow))` for each track;
    - then `rank(…, planned: nil)`. The best's newest segment gives the line, kind and `toName`. Log with place "on board".
  - **Two requests instead of three** (in the shared tail, after the choice, for both branches):
    - Split `plans` into `planOn(next: TripStop, at: Date, to: Place) async -> [DoorTrip]` (the planner calls) and `assemble(…, stops:, its:)` (164-192).
    - When the chosen segment's `to` stop has `toLat`/`toLon` and arrives after now + 20 s, use it as `next`, and run `async let stops = Transit.tripStops(seg.tripId)` beside `async let its = planOn(…)`.
    - Otherwise, as today: stops, then plans.
  - **History.** `Go.firstLook` (458) and `Go.checkBoarding` (516) pass `trip.recentFixes`. `TripManager.wrongWay` (1041) passes `recentFixes`.
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: pick the bus or train that moves with you". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 12: Switch to another bus only when it's clearly the one, for a while (D8: S3, S5)

**Files:**
- Modify:
  - `ios/App/VehicleMatch.swift`, `ios/Tests/DecideTests.swift`
  - `ios/App/TripManager.swift`:
    - state: `:111-129`;
    - resets: `:276, 340, 901, 957`;
    - `checkSameBus`: `:849-891`;
    - `resolveCandidates`: `:909-953`.

**Interfaces:**
- Consumes: `judgeAll`, `rank`, `decide` and `SwitchState` (Task 8); `VehicleTrack(…, trip:)`, `recentFixes` and `findBusYoureOn` (Task 10); `FieldFormat` (Task 9).
- Produces:
  ```swift
  extension VehicleMatch {
      /// A failure (other than tooFewFixes or noTimes) adds a miss; a success resets it. Returns those with < 2 misses, plus `keep` always.
      static func prune(_ judged: [Judgement], misses: inout [String: Int], keep: String?) -> [Judgement]
  }
  // TripManager: private var candSwitch = SwitchState(); private var candMisses: [String: Int] = [:]
  ```

- [ ] **Step 1: Add to `DecideTests.swift`.**
  - `test_pruneDropsAfterTwoMisses`: "b" fails twice (`.offItsPath`) while "a" passes → only "a" is left after the second call.
  - `test_pruneNeverDropsShown`: "a" fails 3 times with `keep: "a"` → still returned.
  - `test_pruneResetsOnSuccess`: "b" fails, passes, then fails → still returned.
  - `test_pruneIgnoresTooFewFixes`: `.tooFewFixes` 3 times → still returned.
- [ ] **Step 2: Implement `prune`.**
- [ ] **Step 3: `resolveCandidates`.** The classic branch is today's body. The new branch, after the trips are fetched (916-919):
  - Make tracks for the candidates with a trip, then `judgeAll(recentFixes, tracks, strictTimes: false)`, then `prune(…, misses: &candMisses, keep: vehicle?.tripId)`.
  - Alive = the pruned ids, plus the candidates with no trip yet.
  - Then `rank(pruned, planned: nil)` and `decide(shown: vehicle?.tripId, …, liveIds: live track ids, state: &candSwitch, now:)`.
  - `cands` and `choosing` = the alive ones.
  - `.switchTo(x)` → `settle(x)`; `.keep` with only the shown one left → `settle(shown)`. The 12-minute rule (947-948) stays.
  - Log with place "choose".
  - Reset `candSwitch` and `candMisses` wherever `candLead` is reset.
- [ ] **Step 4: `checkSameBus`.** The classic branch is today's body. In the new branch, the road check (862-863) becomes `judgeAll(recentFixes, [VehicleTrack(…, trip: t)], strictTimes: false).first`.
  - A failure other than `.tooFewFixes` or `.noTimes` → `offRoad += 1`; at 2, `findBusYoureOn` as today.
  - Otherwise → `offRoad = 0`, and the line rename (865-870) and the far looks (873-880) run as today.
  - Log with place "same bus".
- [ ] **Step 5: Commit and push, then verify CI.** Commit message: "Reliability: switch to another bus only when it’s clearly the one, for a while". Expected: `** TEST SUCCEEDED **`, `BUILD SUCCEEDED`.

### Task 13: No walking plan on a moving train, a calm retry without a connection, and 0.18.0 (D11: N7, N13)

**Files:**
- Modify:
  - `ios/App/VehicleMatch.swift`, `ios/App/Net.swift`
  - `ios/Tests/VehicleMatchTests.swift`, `ios/Tests/NetTests.swift`
  - `ios/App/Live.swift:24-41, 332-343`
  - `ios/App/Screens.swift:608, 808, 1072`, and the as-of lines from Task 6
  - `ios/App/Go.swift:113-129`
  - `ios/App/HaltewekkerApp.swift:10-15`
  - `ios/project.yml`

**Interfaces:**
- Consumes: `Net.within` (Task 1), `Snapshots.asOf` (Task 6).
- Produces:
  ```swift
  extension VehicleMatch { static func planFromSpot(speed: Double, movedAgo: TimeInterval?) -> Bool }  // false at ≥ 8 m/s, or speed < 0 and moved < 30 s ago
  extension Net {
      static func nextBackoff(failures: Int) -> TimeInterval     // 4, 8, 16, then 30
      static var online: Bool { get }                            // true until NWPathMonitor says otherwise
      static func startWatchingConnection()                      // once, from HaltewekkerApp.init
  }
  // LiveStore: @Published private(set) var onTheMove = false
  ```

- [ ] **Step 1: Write the tests.**
  - `test_planFromSpot`:

    | (speed, movedAgo) | → |
    |---|---|
    | (12, 5) | false |
    | (8, 1) | false |
    | (7.9, 1) | true |
    | (2, 60) | true |
    | (−1, 10) | false |
    | (−1, 120) | true |
    | (−1, nil) | true |
  - `test_backoff`: failures 0, 1, 2, 3, 9 and −1 → 4, 8, 16, 30, 30 and 4.
- [ ] **Step 2: Implement them.** `online` sits behind an `NSLock` and is set by an `NWPathMonitor` (`path.status == .satisfied`) on its own queue. Call `startWatchingConnection()` in `HaltewekkerApp.init`.
- [ ] **Step 3: `LiveStore.refresh` (336-340).**
  - When the 7 s on-board look finds nothing and `!planFromSpot(speed: f.speed, movedAgo: now − lastMoving)`: set `onBoard = nil; onTheMove = true; trips = []`. The keep-what-you-had line (346) then keeps `next`. Keep `nextError = nil` while `onTheMove`.
  - Every other branch sets `onTheMove = false`.
  - `Screens.swift`: the three "Finding your next connection(s)…" texts (608, 808, 1072), and the as-of lines from Task 6, show "On the move: finding what you’re on…" while `live.onTheMove`.
- [ ] **Step 4: Fastest trip's loop (Go.swift:120-128).**
  - `emptyLooks` goes up after a refresh with `best == nil` and back to 0 with a `best`.
  - With nothing on screen, the wait is `here == nil ? 1.5 : Net.nextBackoff(failures: emptyLooks - 1)`.
  - While `!Net.online`: skip `refresh()` and wait 4 s. With `best == nil`, set `error` to "No internet connection right now. It looks again as soon as you’re back online.".
  - `begin` resets `emptyLooks`.
- [ ] **Step 5: Bump the version** in `ios/project.yml`: `MARKETING_VERSION: "0.18.0"`, `CURRENT_PROJECT_VERSION: "83"`.
- [ ] **Step 6: Commit and push, then verify CI.** Commit message: "Reliability 0.18.0: no walking plan on a moving train, and a calm retry without a connection". Expected: `** TEST SUCCEEDED **` and `BUILD SUCCEEDED`. No release yet: that comes when the branch is merged into `main`.
- [ ] **Step 7: The user checks it on the phone after merging.**
  - The app opens to its last answers, marked "as of".
  - Fastest trip on a weak connection shows a trip within a few seconds.
  - On the train out of Breda past the buses, it picks the train.
  - "Connection and matching log" shows requests and choices, and "Copy the log" works.
