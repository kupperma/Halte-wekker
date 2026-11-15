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
        let memo = Memo<String, Int>(ttl: 20)
        let f = Fetches()
        let a = await memo.get("a") { await f.hit(); return nil }
        XCTAssertNil(a)
        let b = await memo.get("a") { await f.hit(); return 1 }
        XCTAssertEqual(b, 1)
        let n = await f.count
        XCTAssertEqual(n, 2)
    }

    func test_sharedFetch() async {
        let memo = Memo<String, Int>(ttl: 20)
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
}
