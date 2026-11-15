import XCTest

private actor Publishes {
    private(set) var seen: [(items: [Int], at: Double)] = []
    func note(_ items: [Int], _ at: Double) { seen.append((items, at)) }
}

/// A job that answers `value` after `seconds`.
private func job<T: Sendable>(after seconds: Double, _ value: T) -> @Sendable () async -> T {
    return {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return value
    }
}

final class ProgressiveTests: XCTestCase {
    func test_gatherPublishesAsTheyCome() async {
        let publishes = Publishes()
        let t0 = Date()
        // the slow one first: one at a time, nothing would come in before 0.6 s
        let jobs: [@Sendable () async -> [Int]] = [job(after: 0.6, [3]), job(after: 0.05, [1]), job(after: 0.1, [2])]
        let all = await Progressive.gather(jobs) { soFar in
            await publishes.note(soFar, Date().timeIntervalSince(t0))
        }
        let took = Date().timeIntervalSince(t0)
        let seen = await publishes.seen
        XCTAssertEqual(seen.count, 3)
        guard seen.count == 3 else { return }
        XCTAssertEqual(seen[0].items, [1])
        XCTAssertLessThan(seen[0].at, 0.25)
        XCTAssertEqual(seen[1].items.count, 2)
        XCTAssertEqual(seen[1].items.sorted(), [1, 2])
        XCTAssertLessThan(seen[1].at, 0.35)
        XCTAssertEqual(seen[2].items.count, 3)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.sorted(), [1, 2, 3])
        XCTAssertGreaterThanOrEqual(took, 0.6)
    }

    func test_allKeepsOrderAndRunsAtOnce() async {
        let t0 = Date()
        // at once: 0.3 s; one at a time it would be 0.75 s
        let jobs: [@Sendable () async -> Int] = [job(after: 0.3, 0), job(after: 0.2, 1), job(after: 0.25, 2)]
        let all = await Progressive.all(jobs)
        XCTAssertEqual(all, [0, 1, 2])
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.6)
    }
}
