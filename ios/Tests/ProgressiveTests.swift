import XCTest

private actor Publishes {
    private(set) var seen: [(items: [Int], at: Double)] = []
    func note(_ items: [Int], _ at: Double) { seen.append((items, at)) }
}

/// What a closure was handed, in order.
private actor Seen<T: Sendable> {
    private(set) var all: [T] = []
    func add(_ v: T) { all.append(v) }
}

/// How many requests have finished.
private actor Finished {
    private(set) var n = 0
    func one() { n += 1 }
}

/// A "request" that answers `[value]` after `seconds`, counted when it's done.
private func request(after seconds: Double, _ value: Int, _ finished: Finished) -> @Sendable () async -> [Int] {
    return {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await finished.one()
        return [value]
    }
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
        // the slow one first: one at a time, nothing would come in before 1 s
        let jobs: [@Sendable () async -> [Int]] = [job(after: 1.0, [3]), job(after: 0.05, [1]), job(after: 0.1, [2])]
        let all = await Progressive.gather(jobs) { soFar in
            await publishes.note(soFar, Date().timeIntervalSince(t0))
        }
        let took = Date().timeIntervalSince(t0)
        let seen = await publishes.seen
        XCTAssertEqual(seen.count, 3)
        guard seen.count == 3 else { return }
        // the quick ones as they came, long before the slow one (at least twice as early as its 1 s)
        XCTAssertEqual(seen[0].items, [1])
        XCTAssertLessThan(seen[0].at, 0.5)
        XCTAssertEqual(seen[1].items.count, 2)
        XCTAssertEqual(seen[1].items.sorted(), [1, 2])
        XCTAssertLessThan(seen[1].at, 0.5)
        XCTAssertLessThanOrEqual(seen[1].at, seen[2].at)
        XCTAssertEqual(seen[2].items.count, 3)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.sorted(), [1, 2, 3])
        XCTAssertGreaterThanOrEqual(took, 1.0)
    }

    func test_allKeepsOrderAndRunsAtOnce() async {
        let t0 = Date()
        // at once: 0.3 s; one at a time it would be 0.75 s
        let jobs: [@Sendable () async -> Int] = [job(after: 0.3, 0), job(after: 0.2, 1), job(after: 0.25, 2)]
        let all = await Progressive.all(jobs)
        XCTAssertEqual(all, [0, 1, 2])
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.6)
    }

    func test_withPartialsKeepsWhatArrived() async {
        let got = Seen<String>()
        let t0 = Date()
        let r: (value: String?, timedOut: Bool) = await Net.withPartials(0.2, { publish in
            try? await Task.sleep(nanoseconds: 50_000_000)
            await publish("a")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return "b"
        }, partial: { await got.add($0) })
        let took = Date().timeIntervalSince(t0)
        let seen = await got.all
        XCTAssertEqual(r.value, "a")
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(took, 0.45)
        XCTAssertEqual(seen, ["a"])
    }

    func test_withPartialsFinal() async {
        let got = Seen<String>()
        let r: (value: String?, timedOut: Bool) = await Net.withPartials(1, { publish in
            try? await Task.sleep(nanoseconds: 50_000_000)
            await publish("a")
            return "b"
        }, partial: { await got.add($0) })
        let seen = await got.all
        XCTAssertEqual(r.value, "b")
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(seen, ["a"])
    }

    func test_firstPartialAfterOneRequest() async {
        let finished = Finished()
        let doneAtPartial = Seen<Int>()
        // two requests at once: the first partial comes when the quick one is in, not after both
        let jobs = [request(after: 0.05, 1, finished), request(after: 0.3, 2, finished)]
        let r: (value: [Int]?, timedOut: Bool) = await Net.withPartials(2, { publish in
            await Progressive.gather(jobs, publish: publish)
        }, partial: { _ in
            let n = await finished.n
            await doneAtPartial.add(n)
        })
        let counts = await doneAtPartial.all
        XCTAssertEqual(counts.first, 1)
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(r.value?.sorted(), [1, 2])
        XCTAssertFalse(r.timedOut)
    }

    func test_withPartialsCallerLeavingStopsTheWork() async {
        let stopped = Seen<Bool>()
        let t0 = Date()
        let task = Task<(value: String?, timedOut: Bool), Never> {
            await Net.withPartials(5, { publish in
                await publish("a")
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { await stopped.add(true) }
                return "b"
            }, partial: { _ in })
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let r = await task.value
        let took = Date().timeIntervalSince(t0)
        let seen = await stopped.all
        XCTAssertEqual(seen, [true])
        XCTAssertFalse(r.timedOut)
        XCTAssertLessThan(took, 1.5)
    }
}
