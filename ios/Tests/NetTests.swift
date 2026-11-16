import XCTest
import Network

private actor Sends {
    private(set) var times: [Date] = []
    func note() { times.append(Date()) }
    var count: Int { times.count }
}

private func http(_ status: Int, _ body: String = "", headers: [String: String] = [:]) -> (Data, URLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://example.test/x")!, statusCode: status, httpVersion: nil, headerFields: headers)!)
}

/// The most requests on their way at once, per lane and in all (counted inside `send`).
private actor Gauge {
    private var now: [Lane: Int] = [:]
    private(set) var most: [Lane: Int] = [:]
    private(set) var mostAll = 0
    func enter(_ l: Lane) {
        now[l, default: 0] += 1
        most[l] = max(most[l] ?? 0, now[l] ?? 0)
        mostAll = max(mostAll, now.values.reduce(0, +))
    }
    func exit(_ l: Lane) { now[l, default: 0] -= 1 }
}

private actor Order {
    private(set) var list: [String] = []
    func add(_ s: String) { list.append(s) }
}

/// Opens once; everyone waiting goes on.
private actor Flag {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// A clock that only moves when told (the pauses after a 429 last seconds to minutes).
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

/// A Transitous-like request (the tests hand `Net.response` their own `Polite`, never the app's).
private func tr(_ q: String) -> URLRequest { URLRequest(url: URL(string: "https://api.transitous.org/api/v5/plan?q=\(q)")!) }

final class NetTests: XCTestCase {
    private let quick = Budget(idle: 0.4, total: 0.8, retries: 1, backoff: 0.05, fastFailure: 0.2, minLeft: 0.3)
    private let req = URLRequest(url: URL(string: "https://example.test/x")!)

    func test_configuration() {
        // R-rel-27: urgent idle 6 s, total 10 s
        let u = Net.configuration(for: .urgent)
        XCTAssertEqual(u.timeoutIntervalForRequest, 6)
        XCTAssertEqual(u.timeoutIntervalForResource, 10)
        XCTAssertFalse(u.waitsForConnectivity)
        XCTAssertEqual(u.httpMaximumConnectionsPerHost, 6)
        let b = Net.configuration(for: .background)
        XCTAssertEqual(b.timeoutIntervalForRequest, 8)
        XCTAssertEqual(b.timeoutIntervalForResource, 15)
        XCTAssertFalse(b.waitsForConnectivity)
    }

    func test_retryDelay() {
        func d(status: Int? = nil, error: URLError.Code? = nil, after: String? = nil, took: Double = 0.1, elapsed: Double = 0.1,
               attempt: Int = 0, _ budget: Budget = .urgent) -> TimeInterval? {
            Net.retryDelay(status: status, error: error, retryAfter: after, took: took, elapsed: elapsed, attempt: attempt, budget: budget)
        }
        XCTAssertEqual(d(status: 503), 0.3)
        XCTAssertNil(d(status: 503, took: 2.5))
        XCTAssertEqual(d(error: .networkConnectionLost), 0.3)
        XCTAssertEqual(d(error: .networkConnectionLost, .background), 1.0)
        XCTAssertEqual(d(error: .networkConnectionLost, elapsed: 6.5), 0.3)       // 3.2 s left after the pause
        XCTAssertNil(d(error: .networkConnectionLost, elapsed: 7.0))              // 2.7 s: too little
        XCTAssertNil(d(error: .timedOut))
        XCTAssertNil(d(error: .notConnectedToInternet))
        XCTAssertNil(d(error: .cancelled))
        XCTAssertNil(d(status: 400))
        XCTAssertEqual(d(status: 429, after: "3"), 3)
        XCTAssertEqual(d(status: 429, after: "6"), 6)
        XCTAssertNil(d(status: 429, after: "8"))
        XCTAssertEqual(d(status: 429, after: "8", .background), 8)
        XCTAssertEqual(d(status: 429, after: "30", .background), 10)
        XCTAssertEqual(d(status: 429, after: nil, .background), 1.0)
        XCTAssertEqual(d(status: 429, after: "Wed, 21 Oct 2026 07:28:00 GMT", .background), 1.0)
        XCTAssertNil(d(status: 503, attempt: 1))
    }

    func test_fastFailureRetriedOnce() async throws {
        let sends = Sends()
        let a = try await Net.response(req, lane: .urgent, budget: quick) { _ in
            await sends.note()
            if await sends.count == 1 { throw URLError(.networkConnectionLost) }
            return http(200, "ok")
        }
        XCTAssertEqual(String(data: a.data, encoding: .utf8), "ok")
        XCTAssertEqual(a.attempts, 2)
        let t = await sends.times
        XCTAssertEqual(t.count, 2)
        XCTAssertGreaterThanOrEqual(t[1].timeIntervalSince(t[0]), 0.05)
    }

    func test_totalLimit() async {
        let sends = Sends()
        let t0 = Date()
        do {
            _ = try await Net.response(req, lane: .urgent, budget: quick) { _ in
                await sends.note()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return http(200)
            }
            XCTFail("should time out")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .timedOut)
        } catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.6)
        let n = await sends.count
        XCTAssertEqual(n, 1)
    }

    func test_noRetryAfterTimeout() async {
        let sends = Sends()
        do {
            _ = try await Net.response(req, lane: .urgent, budget: quick) { _ in
                await sends.note()
                try await Task.sleep(nanoseconds: 250_000_000)
                throw URLError(.timedOut)
            }
            XCTFail("should throw")
        } catch let e as URLError { XCTAssertEqual(e.code, .timedOut) } catch { XCTFail("\(error)") }
        let n = await sends.count
        XCTAssertEqual(n, 1)
    }

    func test_noRetryWhenTimeIsUp() async {
        let sends = Sends()
        do {
            // (0.3 s: well within the 0.8 s total, and still slower than a fast failure)
            _ = try await Net.response(req, lane: .urgent, budget: quick) { _ in
                await sends.note()
                try await Task.sleep(nanoseconds: 300_000_000)
                throw URLError(.networkConnectionLost)
            }
            XCTFail("should throw")
        } catch let e as URLError { XCTAssertEqual(e.code, .networkConnectionLost) } catch { XCTFail("\(error)") }
        let n = await sends.count
        XCTAssertEqual(n, 1)
    }

    func test_429RetryAfterZero() async throws {
        let sends = Sends()
        let a = try await Net.response(req, lane: .urgent, budget: quick) { _ in
            await sends.note()
            if await sends.count == 1 { return http(429, headers: ["Retry-After": "0"]) }
            return http(200, "ok")
        }
        XCTAssertEqual(a.status, 200)
        XCTAssertEqual(a.attempts, 2)
    }

    func test_400NotRetried() async throws {
        let sends = Sends()
        let a = try await Net.response(req, lane: .urgent, budget: quick) { _ in
            await sends.note()
            return http(400, "no")
        }
        XCTAssertEqual(a.status, 400)
        XCTAssertEqual(a.attempts, 1)
        let n = await sends.count
        XCTAssertEqual(n, 1)
    }

    func test_backgroundGate() async throws {
        let q = quick
        let r = req
        let urgent = Task {
            try await Net.response(r, lane: .urgent, budget: q) { _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return http(200)
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let t0 = Date()
        let a = try await Net.response(req, lane: .background, budget: quick, gate: 0.2) { _ in http(200, "bg") }
        XCTAssertEqual(a.status, 200)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.6)
        _ = try? await urgent.value
    }

    func test_within() async {
        let seen = Sends()
        let t0 = Date()
        let r: Int? = await Net.within(0.1) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { await seen.note() }
            return 1
        }
        XCTAssertNil(r)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.4)
        let n = await seen.count
        XCTAssertEqual(n, 1)
    }

    func test_cancelledNotRetried() async {
        let sends = Sends()
        let q = quick, r = req
        let t0 = Date()
        let task = Task {
            try await Net.response(r, lane: .urgent, budget: q) { _ in
                await sends.note()
                try await Task.sleep(nanoseconds: 500_000_000)
                return http(200)
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("should be cancelled")
        } catch is CancellationError {
        } catch let e as URLError {
            XCTAssertEqual(e.code, .cancelled)
        } catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.4)
        let n = await sends.count
        XCTAssertEqual(n, 1)
    }

    /// A failed request is logged with the tries it really made and the bytes that came back (a 503's body, then a lost
    /// connection: 2 tries, 4 B); one that ran out of time with its one try.
    func test_failureLogsTriesAndBytes() async {
        let log = FieldLog(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sends = Sends()
        do {
            _ = try await Net.response(req, lane: .urgent, budget: quick, send: { _ in
                await sends.note()
                if await sends.count == 1 { return http(503, "busy") }
                throw URLError(.networkConnectionLost)
            }, label: "/x", log: log)
            XCTFail("should throw")
        } catch let e as URLError { XCTAssertEqual(e.code, .networkConnectionLost) } catch { XCTFail("\(error)") }
        let text = log.entries.first?.text ?? ""
        XCTAssertTrue(text.hasPrefix("/x · connection lost · 4 B · "), text)
        XCTAssertTrue(text.contains(" · 2 tries · urgent"), text)
        XCTAssertEqual(log.entries.count, 1)

        let slow = FieldLog(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        _ = try? await Net.response(req, lane: .urgent, budget: quick, send: { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return http(200)
        }, label: "/y", log: slow)
        let late = slow.entries.first?.text ?? ""
        XCTAssertTrue(late.hasPrefix("/y · timed out · 0 B · "), late)
        XCTAssertTrue(late.contains(" · 1 try · urgent"), late)
    }

    /// Only a path that can't connect at all is offline: one that connects when asked (`.requiresConnection`) isn't.
    func test_onlineUnlessUnsatisfied() {
        XCTAssertTrue(Net.Connection.isOnline(.satisfied))
        XCTAssertTrue(Net.Connection.isOnline(.requiresConnection))
        XCTAssertFalse(Net.Connection.isOnline(.unsatisfied))
    }

    func test_backoff() {
        XCTAssertEqual([0, 1, 2, 3, 9, -1].map { Net.nextBackoff(failures: $0) }, [4, 8, 16, 30, 30, 4])
    }

    // MARK: kindness to Transitous

    private let roomy = Budget(idle: 1, total: 2, retries: 1, backoff: 0.05, fastFailure: 0.2, minLeft: 0.3)

    /// Only Transitous gets it: not the NS relay, nor any other server.
    func test_politeOnlyForTransitous() {
        XCTAssertTrue(Net.Polite.of(URL(string: "https://api.transitous.org/api/v5/plan?fromPlace=x")) === Net.Polite.transitous)
        XCTAssertNil(Net.Polite.of(URL(string: "https://haltewekker-relay.tsfaw1.workers.dev/ns/trips?x=1")))
        XCTAssertNil(Net.Polite.of(URL(string: "https://example.test/x")))
        XCTAssertNil(Net.Polite.of(nil))
        let t = Net.Polite.transitous
        XCTAssertEqual([t.maxInFlight, t.maxBackground], [4, 2])
        XCTAssertEqual([t.firstPause, t.shortest, t.longest], [20, 5, 120])
    }

    /// A 429 is the answer, never tried again (either lane), and pauses the server: background requests aren't sent
    /// (they throw at once, and say so in the field log), urgent ones still are; after the pause background goes again.
    func test_429PausesWithoutRetry() async throws {
        let clock = FakeClock()
        let p = Net.Polite(host: "api.transitous.org", clock: { clock.now })
        let log = FieldLog(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sends = Sends()
        let a = try await Net.response(tr("a"), lane: .background, budget: quick, gate: 0, send: { _ in
            await sends.note()
            return http(429, "slow down")
        }, label: "/v5/plan", log: log, polite: p)
        XCTAssertEqual(a.status, 429)
        XCTAssertEqual(a.attempts, 1)
        var n = await sends.count
        XCTAssertEqual(n, 1)
        XCTAssertEqual(p.coolingLeft ?? -1, 20, accuracy: 0.001)
        XCTAssertTrue(log.entries.first?.text.hasPrefix("/v5/plan · 429 · 9 B · ") ?? false)

        let t0 = Date()
        do {
            _ = try await Net.response(tr("b"), lane: .background, budget: quick, gate: 0.5, send: { _ in
                await sends.note()
                return http(200)
            }, label: "/v6/stoptimes", log: log, polite: p)
            XCTFail("should be turned away")
        } catch let e as URLError { XCTAssertEqual(e.code, .cannotConnectToHost) } catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.25)
        n = await sends.count
        XCTAssertEqual(n, 1)
        XCTAssertEqual(log.entries.first?.text, "/v6/stoptimes · cooling down · 0 B · 0.0 s · 0 tries · background")

        let u = try await Net.response(tr("u"), lane: .urgent, budget: quick, send: { _ in
            await sends.note()
            return http(200, "ok")
        }, polite: p)
        XCTAssertEqual(u.status, 200)
        n = await sends.count
        XCTAssertEqual(n, 2)
        XCTAssertEqual(p.coolingLeft ?? -1, 20, accuracy: 0.001)       // (an answer doesn't end the pause)

        clock.advance(20.5)
        XCTAssertNil(p.coolingLeft)
        let b = try await Net.response(tr("c"), lane: .background, budget: quick, gate: 0, send: { _ in
            await sends.note()
            return http(200)
        }, polite: p)
        XCTAssertEqual(b.status, 200)
        n = await sends.count
        XCTAssertEqual(n, 3)

        // urgent: not tried again either, even when Retry-After says 0 (another server's is: test_429RetryAfterZero)
        let q = Net.Polite(host: "api.transitous.org", clock: { clock.now })
        let s2 = Sends()
        let v = try await Net.response(tr("v"), lane: .urgent, budget: quick, send: { _ in
            await s2.note()
            return http(429, headers: ["Retry-After": "0"])
        }, polite: q)
        XCTAssertEqual(v.status, 429)
        XCTAssertEqual(v.attempts, 1)
        let m = await s2.count
        XCTAssertEqual(m, 1)
        XCTAssertEqual(q.coolingLeft ?? -1, 5, accuracy: 0.001)
    }

    /// During a pause urgent requests go one at a time.
    func test_pauseUrgentOneAtATime() async throws {
        let clock = FakeClock()
        let p = Net.Polite(host: "api.transitous.org", clock: { clock.now })
        _ = try await Net.response(tr("x"), lane: .background, budget: quick, gate: 0, send: { _ in http(429) }, polite: p)
        XCTAssertNotNil(p.coolingLeft)
        let g = Gauge()
        let budget = roomy
        let tasks = (1...3).map { i in
            Task {
                try await Net.response(tr("u\(i)"), lane: .urgent, budget: budget, send: { _ in
                    await g.enter(.urgent)
                    try await Task.sleep(nanoseconds: 150_000_000)
                    await g.exit(.urgent)
                    return http(200)
                }, polite: p)
            }
        }
        for t in tasks { let a = try await t.value; XCTAssertEqual(a.status, 200) }
        let most = await g.mostAll
        XCTAssertEqual(most, 1)
    }

    /// A background request waiting for a place when a pause begins is turned away without being sent; a 429 to a
    /// request that was already on its way when the pause began doesn't make it longer.
    func test_pauseTurnsAwayWaitingBackground() async throws {
        let clock = FakeClock()
        let p = Net.Polite(host: "api.transitous.org", clock: { clock.now })
        let sends = Sends()
        let budget = roomy
        let busy = (0..<2).map { i in
            Task {
                try await Net.response(tr("b\(i)"), lane: .background, budget: budget, gate: 0, send: { _ in
                    await sends.note()
                    try await Task.sleep(nanoseconds: 250_000_000)
                    return http(429)
                }, polite: p)
            }
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(p.inFlight.background, 2)
        let third = Task {
            try await Net.response(tr("b2"), lane: .background, budget: budget, gate: 0, send: { _ in
                await sends.note()
                return http(200)
            }, polite: p)
        }
        do {
            _ = try await third.value
            XCTFail("should be turned away")
        } catch let e as URLError { XCTAssertEqual(e.code, .cannotConnectToHost) } catch { XCTFail("\(error)") }
        for t in busy { let a = try await t.value; XCTAssertEqual(a.status, 429) }
        let n = await sends.count
        XCTAssertEqual(n, 2)
        XCTAssertEqual(p.coolingLeft ?? -1, 20, accuracy: 0.001)
    }

    /// Retry-After (in seconds) is honoured, kept within 5…120 s; without one (or an HTTP date) the pause is 20 s.
    func test_retryAfterClamped() async throws {
        let p = Net.Polite(host: "api.transitous.org")
        XCTAssertEqual(p.asked("3"), 5)
        XCTAssertEqual(p.asked("45"), 45)
        XCTAssertEqual(p.asked(" 300 "), 120)
        XCTAssertNil(p.asked("Wed, 21 Oct 2026 07:28:00 GMT"))
        XCTAssertNil(p.asked("soon"))
        XCTAssertNil(p.asked(nil))
        for (header, want) in [("3", 5.0), ("45", 45), ("300", 120), ("Wed, 21 Oct 2026 07:28:00 GMT", 20), ("", 20)] {
            let clock = FakeClock()
            let q = Net.Polite(host: "api.transitous.org", clock: { clock.now })
            let h = header.isEmpty ? [:] : ["Retry-After": header]
            _ = try await Net.response(tr("r"), lane: .background, budget: quick, gate: 0, send: { _ in http(429, headers: h) }, polite: q)
            XCTAssertEqual(q.coolingLeft ?? -1, want, accuracy: 0.001, header)
        }
    }

    /// A 429 to a request sent during a pause doubles it (120 s at most), and so does one after a pause with no answer
    /// since; an answer starts it over (but doesn't end the pause that's on).
    func test_pauseDoublesAndResets() async throws {
        func ask(_ p: Net.Polite, _ lane: Lane, _ status: Int) async throws {
            let a = try await Net.response(tr(UUID().uuidString), lane: lane, budget: quick, gate: 0, send: { _ in http(status) }, polite: p)
            XCTAssertEqual(a.attempts, 1)
        }
        func left(_ p: Net.Polite) -> Double { p.coolingLeft ?? -1 }
        let clock = FakeClock()
        let p = Net.Polite(host: "api.transitous.org", clock: { clock.now })
        try await ask(p, .background, 429)
        XCTAssertEqual(left(p), 20, accuracy: 0.001)
        clock.advance(1)
        try await ask(p, .urgent, 429)
        XCTAssertEqual(left(p), 40, accuracy: 0.001)
        try await ask(p, .urgent, 429)
        XCTAssertEqual(left(p), 80, accuracy: 0.001)
        try await ask(p, .urgent, 429)
        XCTAssertEqual(left(p), 120, accuracy: 0.001)
        try await ask(p, .urgent, 429)
        XCTAssertEqual(left(p), 120, accuracy: 0.001)

        // after a pause, with no answer since: twice as long again
        let c2 = FakeClock()
        let q = Net.Polite(host: "api.transitous.org", clock: { c2.now })
        try await ask(q, .background, 429)
        c2.advance(21)
        XCTAssertNil(q.coolingLeft)
        try await ask(q, .background, 429)
        XCTAssertEqual(left(q), 40, accuracy: 0.001)

        // an answer starts it over: the pause that's on goes on, the next one is 20 s
        try await ask(q, .urgent, 200)
        XCTAssertEqual(left(q), 40, accuracy: 0.001)
        c2.advance(41)
        try await ask(q, .background, 200)
        try await ask(q, .background, 429)
        XCTAssertEqual(left(q), 20, accuracy: 0.001)
    }

    /// A 429 to a request that was already on its way when the pause began doesn't double it: it only makes it last as
    /// long as its Retry-After asks (never shorter), and the next 429 during the pause doubles the first pause.
    func test_pauseExtendedByOneSentBefore() async throws {
        let clock = FakeClock()
        let p = Net.Polite(host: "api.transitous.org", clock: { clock.now })
        let budget = roomy
        func held(_ q: String, _ lane: Lane, after s: Double, _ retryAfter: String?) -> Task<NetAnswer, Error> {
            Task {
                try await Net.response(tr(q), lane: lane, budget: budget, gate: 0, send: { _ in
                    try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                    return http(429, headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
                }, polite: p)
            }
        }
        // three on their way at once: the 429s come back after 0.1, 0.3 and 0.5 s
        let a = held("a", .background, after: 0.1, nil)
        let b = held("b", .background, after: 0.3, "60")
        let c = held("c", .urgent, after: 0.5, "10")
        _ = try await a.value
        XCTAssertEqual(p.coolingLeft ?? -1, 20, accuracy: 0.001)
        _ = try await b.value
        XCTAssertEqual(p.coolingLeft ?? -1, 60, accuracy: 0.001)       // as long as it asks
        _ = try await c.value
        XCTAssertEqual(p.coolingLeft ?? -1, 60, accuracy: 0.001)       // never shorter
        // sent during the pause: twice the first pause (40 s), which the 60 s left already covers
        let d = try await Net.response(tr("d"), lane: .urgent, budget: quick, send: { _ in http(429) }, polite: p)
        XCTAssertEqual(d.attempts, 1)
        XCTAssertEqual(p.coolingLeft ?? -1, 60, accuracy: 0.001)
        clock.advance(61)
        _ = try await Net.response(tr("e"), lane: .background, budget: quick, gate: 0, send: { _ in http(429) }, polite: p)
        XCTAssertEqual(p.coolingLeft ?? -1, 80, accuracy: 0.001)       // (no answer since: 40 doubled)
    }

    /// The doubling wears off: a 429 more than 120 s after the last pause ended starts from 20 s again.
    func test_pauseDoublingWearsOff() async throws {
        func ask(_ p: Net.Polite) async throws {
            _ = try await Net.response(tr(UUID().uuidString), lane: .background, budget: quick, gate: 0, send: { _ in http(429) }, polite: p)
        }
        let clock = FakeClock()
        let p = Net.Polite(host: "api.transitous.org", clock: { clock.now })
        try await ask(p)
        clock.advance(21)
        try await ask(p)
        XCTAssertEqual(p.coolingLeft ?? -1, 40, accuracy: 0.001)       // soon after: doubled
        clock.advance(40 + 100)
        try await ask(p)
        XCTAssertEqual(p.coolingLeft ?? -1, 80, accuracy: 0.001)       // 100 s after it ended: still doubled
        clock.advance(80 + 121)
        try await ask(p)
        XCTAssertEqual(p.coolingLeft ?? -1, 20, accuracy: 0.001)       // over 120 s after: from the start
        clock.advance(3 * 3600)
        try await ask(p)
        XCTAssertEqual(p.coolingLeft ?? -1, 20, accuracy: 0.001)       // hours later: 20 s, not 120
    }

    /// At most 4 requests on their way at once, of which at most 2 background ones.
    func test_placesCapped() async throws {
        let p = Net.Polite(host: "api.transitous.org")
        let g = Gauge()
        let budget = roomy
        let sends = Sends()
        func hold(_ lane: Lane, _ i: Int) -> Task<NetAnswer, Error> {
            Task {
                try await Net.response(tr("\(lane.rawValue)\(i)"), lane: lane, budget: budget, gate: 0, send: { _ in
                    await sends.note()
                    await g.enter(lane)
                    try await Task.sleep(nanoseconds: 200_000_000)
                    await g.exit(lane)
                    return http(200)
                }, polite: p)
            }
        }
        let tasks = (0..<5).map { hold(.background, $0) } + (0..<5).map { hold(.urgent, $0) }
        for t in tasks { let a = try await t.value; XCTAssertEqual(a.status, 200) }
        let most = await g.mostAll, most_ = await g.most, n = await sends.count
        XCTAssertEqual(most, 4)
        XCTAssertEqual(most_[.background], 2)
        XCTAssertEqual(n, 10)
        XCTAssertEqual(p.inFlight.urgent + p.inFlight.background, 0)
    }

    /// A waiting urgent request goes before a background one that has waited longer.
    func test_urgentGoesFirst() async throws {
        // Deterministic: every step waits for the state it needs (CI's simulator can be slow to start tasks).
        let p = Net.Polite(host: "api.transitous.org")
        let order = Order()
        let budget = Budget(idle: 10, total: 20, retries: 1, backoff: 0.05, fastFailure: 0.2, minLeft: 0.3)
        let first = Flag(), rest = Flag()
        // four urgent ones take every place; the first is done once `first` opens, the others once `rest` opens
        let holders = (0..<4).map { i in
            Task {
                try await Net.response(tr("h\(i)"), lane: .urgent, budget: budget, send: { _ in
                    await (i == 0 ? first : rest).wait()
                    return http(200)
                }, polite: p)
            }
        }
        try await until { p.inFlight == (urgent: 4, background: 0) }
        let bg = Task {
            try await Net.response(tr("bg"), lane: .background, budget: budget, gate: 0, send: { _ in
                await order.add("background")
                return http(200)
            }, polite: p)
        }
        try await until { p.waiting.background == 1 }
        let urgent = Task {
            try await Net.response(tr("u"), lane: .urgent, budget: budget, send: { _ in
                await order.add("urgent")
                return http(200)
            }, polite: p)
        }
        try await until { p.waiting.urgent == 1 }
        // one place comes free: the urgent one, though it came later, goes first
        await first.open()
        _ = try await urgent.value
        var seen = await order.list
        XCTAssertEqual(seen.first, "urgent")          // (the background one may already have gone in the place it left)
        _ = try await bg.value
        seen = await order.list
        XCTAssertEqual(seen, ["urgent", "background"])
        await rest.open()
        for h in holders { _ = try await h.value }
    }

    /// Polls `cond` every 10 ms for at most `seconds` (then fails the test).
    private func until(_ seconds: Double = 10, _ cond: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !(await cond()) {
            if Date() > end { XCTFail("timed out waiting", file: file, line: line); throw CancellationError() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Waiting for a place: a cancelled caller stops at once and its request is never sent.
    func test_cancelledWhileWaiting() async throws {
        let p = Net.Polite(host: "api.transitous.org", maxInFlight: 1)
        let budget = roomy
        let holder = Task {
            try await Net.response(tr("h"), lane: .urgent, budget: budget, send: { _ in
                try await Task.sleep(nanoseconds: 600_000_000)
                return http(200)
            }, polite: p)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let sends = Sends()
        let waiting = Task {
            try await Net.response(tr("w"), lane: .urgent, budget: budget, send: { _ in
                await sends.note()
                return http(200)
            }, polite: p)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let t0 = Date()
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("should be cancelled")
        } catch is CancellationError {
        } catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.2)
        _ = try await holder.value
        let n = await sends.count
        XCTAssertEqual(n, 0)
    }

    /// The same request asked again while it's on its way shares its answer (one request); lanes never share, and once
    /// it's in, the next one asks again.
    func test_identicalRequestsShared() async throws {
        let p = Net.Polite(host: "api.transitous.org")
        let log = FieldLog(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sends = Sends()
        let r = URLRequest(url: URL(string: "https://api.transitous.org/api/v6/stoptimes?stopId=a&n=20")!)
        let send: Net.Send = { _ in
            await sends.note()
            try await Task.sleep(nanoseconds: 200_000_000)
            return http(200, "board")
        }
        let q = quick
        let tasks = (0..<3).map { _ in
            Task { try await Net.response(r, lane: .background, budget: q, gate: 0, send: send, label: "/v6/stoptimes", log: log, polite: p) }
        }
        for t in tasks { let a = try await t.value; XCTAssertEqual(String(data: a.data, encoding: .utf8), "board") }
        var n = await sends.count
        XCTAssertEqual(n, 1)
        let lines = log.entries.map(\.text)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.filter { $0.hasSuffix(" · 1 try · background · shared") }.count, 2, "\(lines)")
        XCTAssertEqual(lines.filter { $0.hasSuffix(" · 1 try · background") }.count, 1, "\(lines)")

        let both = [Lane.urgent, .background].map { lane in
            Task { try await Net.response(r, lane: lane, budget: q, gate: 0, send: send, polite: p) }
        }
        for t in both { _ = try await t.value }
        n = await sends.count
        XCTAssertEqual(n, 3)

        _ = try await Net.response(r, lane: .background, budget: quick, gate: 0, send: send, polite: p)
        n = await sends.count
        XCTAssertEqual(n, 4)
    }

    /// A shared request goes on for the others when one caller is cancelled, and stops when nobody waits for it.
    func test_sharedRequestAndCancelling() async throws {
        let p = Net.Polite(host: "api.transitous.org")
        let sends = Sends()
        let q = roomy
        let r = tr("same")
        let send: Net.Send = { _ in
            await sends.note()
            try await Task.sleep(nanoseconds: 500_000_000)
            return http(200, "x")
        }
        let first = Task { try await Net.response(r, lane: .background, budget: q, gate: 0, send: send, polite: p) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = Task { try await Net.response(r, lane: .background, budget: q, gate: 0, send: send, polite: p) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let t0 = Date()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("should be cancelled")
        } catch is CancellationError {
        } catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.2)
        let a = try await second.value
        XCTAssertEqual(String(data: a.data, encoding: .utf8), "x")
        var n = await sends.count
        XCTAssertEqual(n, 1)

        // nobody waits any more: the request stops, and gives its place back
        let stopped = Sends()
        let only = Task {
            try await Net.response(tr("alone"), lane: .background, budget: q, gate: 0, send: { _ in
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { await stopped.note(); throw error }
                return http(200)
            }, polite: p)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        only.cancel()
        _ = try? await only.value
        try await Task.sleep(nanoseconds: 150_000_000)
        n = await stopped.count
        XCTAssertEqual(n, 1)
        XCTAssertEqual(p.inFlight.urgent + p.inFlight.background, 0)
    }

    /// Other servers (the NS relay, the weather) are untouched: all at once, a 429 tried again, no pause, no sharing.
    func test_otherServersUnaffected() async throws {
        let g = Gauge()
        let q = quick
        let tasks = (0..<6).map { i in
            Task {
                try await Net.response(URLRequest(url: URL(string: "https://example.test/x?\(i)")!), lane: .background, budget: q, gate: 0, send: { _ in
                    await g.enter(.background)
                    try await Task.sleep(nanoseconds: 200_000_000)
                    await g.exit(.background)
                    return http(200)
                })
            }
        }
        for t in tasks { _ = try await t.value }
        let most = await g.mostAll
        XCTAssertEqual(most, 6)

        let sends = Sends()
        let a = try await Net.response(req, lane: .background, budget: quick, gate: 0) { _ in
            await sends.note()
            if await sends.count == 1 { return http(429, headers: ["Retry-After": "0"]) }
            return http(200)
        }
        XCTAssertEqual(a.status, 200)
        XCTAssertEqual(a.attempts, 2)
        let b = try await Net.response(req, lane: .background, budget: quick, gate: 0) { _ in http(200, "still") }
        XCTAssertEqual(String(data: b.data, encoding: .utf8), "still")

        let same = Sends()
        let r = req
        let two = (0..<2).map { _ in
            Task {
                try await Net.response(r, lane: .background, budget: q, gate: 0) { _ in
                    await same.note()
                    try await Task.sleep(nanoseconds: 150_000_000)
                    return http(200)
                }
            }
        }
        for t in two { _ = try await t.value }
        let n = await same.count
        XCTAssertEqual(n, 2)
        XCTAssertNil(Net.Polite.transitous.coolingLeft)
    }
}
