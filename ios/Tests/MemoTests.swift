import XCTest

private final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_000_000)
}

private actor Fetches {
    private(set) var count = 0
    func hit() { count += 1 }
}

final class MemoTests: XCTestCase {
    func test_failureNotRemembered() async {
        let clock = TestClock()
        let memo = Memo<String, Int>(ttl: 20, now: { clock.date })
        let f = Fetches()
        let a = await memo.get("a") { await f.hit(); return nil }
        XCTAssertNil(a)
        let b = await memo.get("a") { await f.hit(); return 1 }
        XCTAssertEqual(b, 1)
        let n = await f.count
        XCTAssertEqual(n, 2)
    }

    func test_sharedFetch() async {
        let clock = TestClock()
        let memo = Memo<String, Int>(ttl: 20, now: { clock.date })
        let f = Fetches()
        let results = await withTaskGroup(of: Int?.self) { g -> [Int?] in
            for _ in 0..<5 {
                g.addTask {
                    await memo.get("a") {
                        await f.hit()
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        return 7
                    }
                }
            }
            var out: [Int?] = []
            for await r in g { out.append(r) }
            return out
        }
        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0 == 7 })
        let n = await f.count
        XCTAssertEqual(n, 1)
    }

    func test_expiry() async {
        let clock = TestClock()
        let t0 = clock.date
        let memo = Memo<String, Int>(ttl: 20, now: { clock.date })
        let f = Fetches()
        _ = await memo.get("a") { await f.hit(); return 1 }
        clock.date = t0.addingTimeInterval(19)
        let fresh = await memo.get("a") { await f.hit(); return 2 }
        XCTAssertEqual(fresh, 1)
        var n = await f.count
        XCTAssertEqual(n, 1)
        clock.date = t0.addingTimeInterval(21)
        let stale = await memo.get("a") { await f.hit(); return 2 }
        XCTAssertEqual(stale, 2)
        n = await f.count
        XCTAssertEqual(n, 2)
    }

    func test_peekIgnoresAge() async {
        let clock = TestClock()
        let t0 = clock.date
        let memo = Memo<String, Int>(ttl: 20, now: { clock.date })
        _ = await memo.get("a") { 1 }
        clock.date = t0.addingTimeInterval(100)
        let a = await memo.peek("a")
        let b = await memo.peek("b")
        XCTAssertEqual(a, 1)
        XCTAssertNil(b)
    }

    func test_limitDropsOldest() async {
        let clock = TestClock()
        let memo = Memo<String, Int>(ttl: 20, limit: 2, now: { clock.date })
        _ = await memo.get("a") { 1 }
        clock.date = clock.date.addingTimeInterval(1)
        _ = await memo.get("b") { 2 }
        clock.date = clock.date.addingTimeInterval(1)
        _ = await memo.get("c") { 3 }
        let a = await memo.peek("a")
        let c = await memo.peek("c")
        XCTAssertNil(a)
        XCTAssertEqual(c, 3)
    }

    func test_cancelledWaiterLeavesAtOnce() async {
        let memo = Memo<String, Int>(ttl: 20)
        let slow: @Sendable () async -> Int? = {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return 7
        }
        let a = Task { await memo.get("a", fetch: slow) }
        let b = Task { () -> (Int?, TimeInterval) in
            let start = Date()
            let v = await memo.get("a", fetch: slow)
            return (v, Date().timeIntervalSince(start))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        b.cancel()
        let (vb, took) = await b.value
        XCTAssertNil(vb)
        XCTAssertLessThan(took, 0.25)   // well before the 0.3 s fetch ends (and 0.1 s after the cancel in practice)
        let va = await a.value
        XCTAssertEqual(va, 7)
    }

    func test_lastWaiterCancelStopsFetch() async {
        let memo = Memo<String, Int>(ttl: 20)
        let seen = Fetches()
        let t = Task {
            await memo.get("a") {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { await seen.hit(); return nil }
                return 7
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        t.cancel()
        let v = await t.value
        XCTAssertNil(v)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = await seen.count
        XCTAssertEqual(cancelled, 1)
        let stored = await memo.peek("a")
        XCTAssertNil(stored)
    }

    func test_groupsDoNotShareAFetch() async {
        let memo = Memo<String, Int>(ttl: 20)
        let f = Fetches()
        let slow: @Sendable () async -> Int? = {
            await f.hit()
            try? await Task.sleep(nanoseconds: 200_000_000)
            return 5
        }
        let bg = Task { await memo.get("a", group: 0, fetch: slow) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let urgent = await memo.get("a", group: 1, fetch: slow)
        XCTAssertEqual(urgent, 5)
        let b = await bg.value
        XCTAssertEqual(b, 5)
        let n = await f.count
        XCTAssertEqual(n, 2)
    }

    func test_peekDatedAndBackwardClock() async {
        let clock = TestClock()
        let t0 = clock.date
        let memo = Memo<String, Int>(ttl: 20, now: { clock.date })
        _ = await memo.get("a") { 1 }
        let d = await memo.peekDated("a")
        XCTAssertEqual(d?.value, 1)
        XCTAssertEqual(d?.at, t0)
        clock.date = t0.addingTimeInterval(-5)
        let again = await memo.get("a") { 2 }
        XCTAssertEqual(again, 2)
    }
}
