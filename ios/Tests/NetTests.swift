import XCTest

private actor Sends {
    private(set) var times: [Date] = []
    func note() { times.append(Date()) }
    var count: Int { times.count }
}

private func http(_ status: Int, _ body: String = "", headers: [String: String] = [:]) -> (Data, URLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://example.test/x")!, statusCode: status, httpVersion: nil, headerFields: headers)!)
}

final class NetTests: XCTestCase {
    private let quick = Budget(idle: 0.4, total: 0.8, retries: 1, backoff: 0.05, fastFailure: 0.2, minLeft: 0.3)
    private let req = URLRequest(url: URL(string: "https://example.test/x")!)

    func test_configuration() {
        let u = Net.configuration(for: .urgent)
        XCTAssertEqual(u.timeoutIntervalForRequest, 4)
        XCTAssertEqual(u.timeoutIntervalForResource, 8)
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
        XCTAssertNil(d(error: .networkConnectionLost, elapsed: 5.0))
        XCTAssertNil(d(error: .timedOut))
        XCTAssertNil(d(error: .notConnectedToInternet))
        XCTAssertNil(d(error: .cancelled))
        XCTAssertNil(d(status: 400))
        XCTAssertEqual(d(status: 429, after: "3"), 3)
        XCTAssertNil(d(status: 429, after: "6"))
        XCTAssertEqual(d(status: 429, after: "6", .background), 6)
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
            _ = try await Net.response(req, lane: .urgent, budget: quick) { _ in
                await sends.note()
                try await Task.sleep(nanoseconds: 600_000_000)
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

    func test_backoff() {
        XCTAssertEqual([0, 1, 2, 3, 9, -1].map { Net.nextBackoff(failures: $0) }, [4, 8, 16, 30, 30, 4])
    }
}
