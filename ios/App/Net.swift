import Foundation
import Network

/// Who is waiting for an answer: `urgent` is someone looking at a screen for it, `background` is everything else.
enum Lane: String, Sendable {
    case urgent, background
    var budget: Budget { self == .urgent ? .urgent : .background }
}

/// How long a request may take, and when it may be tried once more.
struct Budget: Equatable, Sendable {
    let idle: TimeInterval          // no byte for this long: timed out
    let total: TimeInterval         // everything (the retry included) ends within this
    let retries: Int
    let backoff: TimeInterval
    let fastFailure: TimeInterval   // only a failure that came back within this is retried
    let minLeft: TimeInterval       // …and only with this much of `total` left after the pause
    static let urgent = Budget(idle: 4, total: 8, retries: 1, backoff: 0.3, fastFailure: 2, minLeft: 3)
    static let background = Budget(idle: 8, total: 15, retries: 1, backoff: 1.0, fastFailure: 2, minLeft: 3)
}

struct NetAnswer: Sendable {
    let data: Data
    let status: Int
    let contentType: String?
    let attempts: Int
    let seconds: Double
}

enum Net {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The longest a background request waits behind an urgent one.
    static let gateWait: TimeInterval = 2

    /// How many urgent requests are on their way.
    static let flight = Flight()
    final class Flight: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func begin() { lock.lock(); n += 1; lock.unlock() }
        func end() { lock.lock(); n = max(0, n - 1); lock.unlock() }
        var busy: Bool { lock.lock(); defer { lock.unlock() }; return n > 0 }
    }

    static func configuration(for lane: Lane) -> URLSessionConfiguration {
        let b = lane.budget
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = b.idle
        c.timeoutIntervalForResource = b.total
        c.waitsForConnectivity = false
        if lane == .urgent { c.httpMaximumConnectionsPerHost = 6 }
        return c
    }

    private static let urgentSession = URLSession(configuration: configuration(for: .urgent))
    private static let backgroundSession = URLSession(configuration: configuration(for: .background))
    static func session(for lane: Lane) -> URLSession { lane == .urgent ? urgentSession : backgroundSession }

    private static let retryable: Set<URLError.Code> = [.networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                                                        .dnsLookupFailed, .secureConnectionFailed]

    /// How long to pause before the one more try, or nil for no retry.
    static func retryDelay(status: Int?, error: URLError.Code?, retryAfter: String?,
                           took: TimeInterval, elapsed: TimeInterval, attempt: Int, budget: Budget) -> TimeInterval? {
        guard attempt < budget.retries else { return nil }
        if status == 429 {
            var delay = budget.backoff
            if let s = retryAfter?.trimmingCharacters(in: .whitespaces), let v = Double(s), v.isFinite {
                delay = min(10, max(0, v))
            }
            return budget.total - elapsed - delay >= budget.minLeft ? delay : nil
        }
        let failed = (status.map { $0 >= 500 } ?? false) || (error.map { retryable.contains($0) } ?? false)
        guard failed, took <= budget.fastFailure else { return nil }
        return budget.total - elapsed - budget.backoff >= budget.minLeft ? budget.backoff : nil
    }

    /// One request within its lane's budget. Every HTTP status comes back as an answer (a non-HTTP response counts as
    /// 200); a transport failure that isn't retried throws its `URLError`; the total running out throws `.timedOut`;
    /// a cancelled caller gets `CancellationError` at once.
    static func response(_ request: URLRequest, lane: Lane, budget: Budget? = nil,
                         gate: TimeInterval = gateWait, send: Send? = nil) async throws -> NetAnswer {
        let budget = budget ?? lane.budget
        let send: Send = send ?? { req in try await session(for: lane).data(for: req) }
        if lane == .urgent {
            flight.begin()
        } else {
            var waited = 0.0
            while flight.busy && waited < gate {
                let step = min(0.25, gate - waited)
                try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                waited += step
            }
        }
        defer { if lane == .urgent { flight.end() } }
        do {
            return try await withThrowingTaskGroup(of: NetAnswer.self) { g -> NetAnswer in
                g.addTask { try await attempts(request, budget: budget, send: send) }
                g.addTask {
                    try await Task.sleep(nanoseconds: UInt64(budget.total * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                defer { g.cancelAll() }
                guard let first = try await g.next() else { throw URLError(.unknown) }
                return first
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func attempts(_ request: URLRequest, budget: Budget, send: Send) async throws -> NetAnswer {
        let start = Date()
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var req = request
            req.timeoutInterval = budget.idle
            let began = Date()
            let delay: TimeInterval
            do {
                let (data, resp) = try await send(req)
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? 200
                if status == 429 || status >= 500,
                   let d = retryDelay(status: status, error: nil, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                                      took: Date().timeIntervalSince(began), elapsed: Date().timeIntervalSince(start),
                                      attempt: attempt, budget: budget) {
                    delay = d
                } else {
                    return NetAnswer(data: data, status: status, contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                                     attempts: attempt + 1, seconds: Date().timeIntervalSince(start))
                }
            } catch let e as URLError {
                if Task.isCancelled { throw CancellationError() }
                guard let d = retryDelay(status: nil, error: e.code, retryAfter: nil,
                                         took: Date().timeIntervalSince(began), elapsed: Date().timeIntervalSince(start),
                                         attempt: attempt, budget: budget) else { throw e }
                delay = d
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            attempt += 1
        }
    }

    /// Whatever `work` gives within `seconds`, or nil (and it's stopped): so a slow answer never holds a screen.
    static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { g in
            g.addTask { await work() }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }
}
