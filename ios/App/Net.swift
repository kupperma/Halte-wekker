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
    static let urgent = Budget(idle: 6, total: 10, retries: 1, backoff: 0.3, fastFailure: 2, minLeft: 3)
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

    /// 0.20.7: each request that went out (not one that shared another's answer, not one turned away while cooling
    /// down), by its label, with the bytes of the body that came back: the battery log counts it.
    static var onRequest: (@Sendable (String, Int) -> Void)?
    /// 0.20.7: each request's real bytes, both ways (headers and the body as sent), and whether it went over a mobile
    /// network, from its metrics (`meter`): the battery log counts them.
    static var onMetrics: (@Sendable (URL?, Int, Bool) -> Void)?
    /// The delegate that reads a request's metrics: the app's own sessions have it, and a request elsewhere can take it
    /// (`data(for:delegate:)`).
    static let meter: URLSessionTaskDelegate? = {
        #if os(Linux)
        return nil
        #else
        return MetricsReader()
        #endif
    }()

    private static let urgentSession = URLSession(configuration: configuration(for: .urgent), delegate: meter, delegateQueue: nil)
    private static let backgroundSession = URLSession(configuration: configuration(for: .background), delegate: meter, delegateQueue: nil)
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
    /// a cancelled caller gets `CancellationError` at once. With a `label` (the path, no query), the call is written to
    /// `log` (the field log) once, whichever way it ends, with the tries it made and the bytes that came back.
    /// A server with a `Polite` (Transitous: see there, `polite` for tests) gets its requests a few at a time, a 429 is
    /// never tried again but pauses its background requests (those throw `coolingDown` at once meanwhile), and the
    /// same question asked again while it's on its way shares its answer.
    static func response(_ request: URLRequest, lane: Lane, budget: Budget? = nil,
                         gate: TimeInterval = gateWait, send: Send? = nil,
                         label: String? = nil, log: FieldLog? = nil, polite: Polite? = nil) async throws -> NetAnswer {
        let budget = budget ?? lane.budget
        let send: Send = send ?? { req in try await session(for: lane).data(for: req) }
        let polite = polite ?? Polite.of(request.url)
        var began = Date()
        func note(status: Int?, error: URLError.Code?, bytes: Int, attempts: Int, extra: String? = nil) {
            guard let label else { return }
            if attempts > 0, extra != "shared", extra != Polite.coolingNote { onRequest?(label, bytes) }
            (log ?? FieldLog.shared).add(.net, FieldFormat.net(label, lane: lane, status: status, error: error, bytes: bytes,
                                                               seconds: Date().timeIntervalSince(began), attempts: attempts,
                                                               note: extra))
        }
        // Asked to slow down: what can wait isn't sent at all.
        if lane == .background, let polite, polite.coolingLeft != nil {
            note(status: nil, error: nil, bytes: 0, attempts: 0, extra: Polite.coolingNote)
            throw coolingDown
        }
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
        began = Date()
        guard let polite else {
            let tries = Tries()
            do {
                let answer = try await limited(budget.total) { try await attempts(request, lane: lane, budget: budget, send: send, tries: tries) }
                note(status: answer.status, error: nil, bytes: answer.data.count, attempts: answer.attempts)
                return answer
            } catch {
                if Task.isCancelled {
                    note(status: nil, error: .cancelled, bytes: tries.bytes, attempts: max(1, tries.count))
                    throw CancellationError()
                }
                note(status: nil, error: (error as? URLError)?.code ?? .unknown, bytes: tries.bytes, attempts: max(1, tries.count))
                throw error
            }
        }
        // (the same address in the same lane: one request; anything but a GET never shares)
        let get = (request.httpMethod ?? "GET").uppercased() == "GET"
        let key = get ? "\(lane.rawValue) \(request.url?.absoluteString ?? "")" : UUID().uuidString
        let ticket = polite.join(key) { tries in
            // a place among the few on their way (waiting at most as long as the lane's total), then the whole budget
            try await polite.enter(lane, within: budget.total)
            defer { polite.exit(lane) }
            return try await limited(budget.total) {
                try await attempts(request, lane: lane, budget: budget, send: send, tries: tries, polite: polite)
            }
        }
        let shared = ticket.joined ? "shared" : nil
        do {
            let answer = try await polite.wait(ticket)
            note(status: answer.status, error: nil, bytes: answer.data.count, attempts: answer.attempts, extra: shared)
            return answer
        } catch {
            let tries = ticket.tries
            if Task.isCancelled {
                note(status: nil, error: .cancelled, bytes: tries.bytes, attempts: tries.count, extra: shared)
                throw CancellationError()
            }
            if error is Polite.Refused {
                note(status: nil, error: nil, bytes: 0, attempts: 0, extra: Polite.coolingNote)
                throw coolingDown
            }
            note(status: nil, error: (error as? URLError)?.code ?? .unknown, bytes: tries.bytes, attempts: tries.count, extra: shared)
            throw error
        }
    }

    /// What a background request to a server that asked to slow down throws instead of being sent: no answer this time.
    static var coolingDown: URLError { URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "Transitous asked to slow down"]) }

    /// `work`, or `.timedOut` after `total` seconds (and the work is cancelled).
    private static func limited(_ total: TimeInterval, _ work: @escaping @Sendable () async throws -> NetAnswer) async throws -> NetAnswer {
        try await withThrowingTaskGroup(of: NetAnswer.self) { g -> NetAnswer in
            g.addTask { try await work() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { g.cancelAll() }
            guard let first = try await g.next() else { throw URLError(.unknown) }
            return first
        }
    }

    /// The tries a request made so far, and the bytes that came back with them (for the field log, whichever way it ends).
    final class Tries: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0, received = 0
        func begin() { lock.lock(); n += 1; lock.unlock() }
        func got(_ bytes: Int) { lock.lock(); received += max(0, bytes); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        var bytes: Int { lock.lock(); defer { lock.unlock() }; return received }
    }

    /// The tries of one request. To a `polite` server: a 429 is the answer (no second try) and pauses the server, any
    /// other answer under 400 ends a run of pauses, and a background request isn't tried again during a pause.
    private static func attempts(_ request: URLRequest, lane: Lane, budget: Budget, send: Send, tries: Tries,
                                 polite: Polite? = nil) async throws -> NetAnswer {
        let start = Date()
        var attempt = 0
        var last: Result<NetAnswer, Error>?
        while true {
            try Task.checkCancellation()
            if let last, lane == .background, polite?.coolingLeft != nil { return try last.get() }
            var req = request
            req.timeoutInterval = budget.idle
            let began = Date()
            let delay: TimeInterval
            let sent = polite?.sending()
            tries.begin()
            do {
                let (data, resp) = try await send(req)
                tries.got(data.count)
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? 200
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After")
                let answer = NetAnswer(data: data, status: status, contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                                       attempts: attempt + 1, seconds: Date().timeIntervalSince(start))
                if let polite, let sent {
                    if status == 429 { polite.slowDown(retryAfter: retryAfter, sent: sent); return answer }
                    if status < 400 { polite.answered() }
                }
                if status == 429 || status >= 500,
                   let d = retryDelay(status: status, error: nil, retryAfter: retryAfter,
                                      took: Date().timeIntervalSince(began), elapsed: Date().timeIntervalSince(start),
                                      attempt: attempt, budget: budget) {
                    delay = d
                    last = .success(answer)
                } else {
                    return answer
                }
            } catch let e as URLError {
                if Task.isCancelled { throw CancellationError() }
                guard let d = retryDelay(status: nil, error: e.code, retryAfter: nil,
                                         took: Date().timeIntervalSince(began), elapsed: Date().timeIntervalSince(start),
                                         attempt: attempt, budget: budget) else { throw e }
                delay = d
                last = .failure(e)
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            attempt += 1
        }
    }

    /// How long Fastest trip waits after its `failures`-th empty look in a row: 4, 8, 16, then 30 seconds.
    static func nextBackoff(failures: Int) -> TimeInterval {
        let n = max(0, failures)
        return n >= 3 ? 30 : 4 * Double(1 << n)
    }

    private static let connection = Connection()
    final class Connection: @unchecked Sendable {
        private let lock = NSLock()
        private var up = true
        private var started = false
        private let queue = DispatchQueue(label: "haltewekker.connection")
        func set(_ v: Bool) { lock.lock(); up = v; lock.unlock() }
        /// Online unless the path says it can't connect at all.
        static func isOnline(_ status: NWPath.Status) -> Bool { status != .unsatisfied }
        var online: Bool { lock.lock(); defer { lock.unlock() }; return up }
        func start() {
            lock.lock()
            if started { lock.unlock(); return }
            started = true
            lock.unlock()
            let m = NWPathMonitor()
            // (`.requiresConnection`: it can connect when asked, as on a cellular link that's asleep, so it counts as online)
            m.pathUpdateHandler = { [weak self] path in self?.set(Connection.isOnline(path.status)) }
            m.start(queue: queue)
        }
    }
    /// True until the network monitor says there is no connection.
    static var online: Bool { connection.online }
    /// Start watching the connection (once, from the app's init).
    static func startWatchingConnection() { connection.start() }

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

extension Net {
    /// Kindness to a server that is free and run by volunteers (Transitous): only a few requests on their way at once,
    /// someone waiting on a screen first; an "HTTP 429, slow down" pauses everything that can wait; and the same
    /// question asked again while it's on its way goes out once.
    ///
    /// - At most `maxInFlight` requests at once, of which at most `maxBackground` background ones. A waiting urgent one
    ///   always goes before any waiting background one.
    /// - A 429 is never tried again. It starts a pause of its `Retry-After` seconds (kept within `shortest`…`longest`),
    ///   else `firstPause`. Each further one doubles it (`longest` at most): a 429 to a request sent during the pause, or
    ///   after it with no answer in between (one already on its way when the pause began only makes the pause last as
    ///   long as it asks). An answer (under 400) starts that over, and so does a pause that ended over `longest` ago. During a pause background requests aren't sent (they're turned away at once, the
    ///   ones waiting for a place too), and urgent ones go one at a time.
    /// - Identical requests (one key: the lane and the address) on their way at the same time share one request and
    ///   its answer. A caller that's cancelled stops waiting at once; the request stops when nobody waits for it.
    final class Polite: @unchecked Sendable {
        static let transitous = Polite(host: "api.transitous.org")
        /// The politeness a request's server gets, if any (Transitous; not the NS relay, nor the weather).
        static func of(_ url: URL?) -> Polite? { url?.host?.lowercased() == transitous.host ? transitous : nil }
        /// The field log's word for a request a pause turned away.
        static let coolingNote = "cooling down"

        /// Thrown by `enter` for a background request during a pause.
        struct Refused: Error {}

        let host: String
        let maxInFlight: Int
        let maxBackground: Int
        let firstPause: TimeInterval
        let shortest: TimeInterval
        let longest: TimeInterval
        private let clock: @Sendable () -> Date
        private let lock = NSLock()

        init(host: String, maxInFlight: Int = 4, maxBackground: Int = 2, firstPause: TimeInterval = 20,
             shortest: TimeInterval = 5, longest: TimeInterval = 120, clock: @escaping @Sendable () -> Date = { Date() }) {
            self.host = host
            self.maxInFlight = maxInFlight
            self.maxBackground = maxBackground
            self.firstPause = firstPause
            self.shortest = shortest
            self.longest = longest
            self.clock = clock
        }

        // MARK: the pause after a 429

        private var until: Date?                    // the pause lasts until then
        private var pause: TimeInterval = 0         // the last pause's length (0: an answer came since)
        private var pauses = 0                      // pauses begun (a request sent before the last one began has a lower number)

        private var cooling: Bool { until.map { clock() < $0 } ?? false }      // (under the lock)

        /// How much of the pause is left, if there is one.
        var coolingLeft: TimeInterval? {
            lock.lock(); defer { lock.unlock() }
            guard let until else { return nil }
            let left = until.timeIntervalSince(clock())
            return left > 0 ? left : nil
        }

        /// What a `Retry-After` asks for, in seconds (an HTTP date isn't read), kept within `shortest`…`longest`.
        func asked(_ retryAfter: String?) -> TimeInterval? {
            guard let s = retryAfter?.trimmingCharacters(in: .whitespaces), let v = Double(s), v.isFinite else { return nil }
            return min(longest, max(shortest, v))
        }

        /// What a request about to be sent remembers, for `slowDown`.
        struct Sent: Sendable { let pauses: Int; let cooling: Bool }
        func sending() -> Sent { lock.lock(); defer { lock.unlock() }; return Sent(pauses: pauses, cooling: cooling) }

        /// A 429 came back for a request that was sent with `sent`.
        func slowDown(retryAfter: String?, sent: Sent) {
            let want = asked(retryAfter)
            lock.lock()
            let now = clock()
            // (the last pause ended long ago: it has worn off, this one starts from the first pause again)
            if let u = until, now.timeIntervalSince(u) > longest { pause = 0 }
            if cooling, !(sent.cooling && sent.pauses == pauses) {
                // already on its way when this pause began: the same "slow down" again, it only makes sure the pause
                // lasts as long as this one asks
                if let want, let u = until { until = max(u, now.addingTimeInterval(want)) }
            } else {
                pause = pause > 0 ? min(longest, max(want ?? 0, pause * 2)) : (want ?? firstPause)
                pauses += 1
                until = max(until ?? now, now.addingTimeInterval(pause))
            }
            let ready = admit()
            lock.unlock()
            Self.resume(ready)
        }

        /// An answer came: the next 429 starts from the first pause again (a pause that's on goes on).
        func answered() { lock.lock(); pause = 0; lock.unlock() }

        // MARK: a few at a time

        private var urgentIn = 0, backgroundIn = 0
        private struct Waiter { let id: UInt64; let lane: Lane; let go: CheckedContinuation<Void, Error> }
        private var queue: [Waiter] = []
        private var ids: UInt64 = 0
        private func nextId() -> UInt64 { lock.lock(); defer { lock.unlock() }; ids += 1; return ids }

        /// Requests on their way now (for tests).
        var inFlight: (urgent: Int, background: Int) { lock.lock(); defer { lock.unlock() }; return (urgentIn, backgroundIn) }
        /// Requests waiting for a place now (for tests).
        var waiting: (urgent: Int, background: Int) {
            lock.lock(); defer { lock.unlock() }
            return (queue.filter { $0.lane == .urgent }.count, queue.filter { $0.lane == .background }.count)
        }

        private func fits(_ lane: Lane) -> Bool {
            guard urgentIn + backgroundIn < maxInFlight else { return false }
            return lane == .urgent ? (!cooling || urgentIn == 0) : (!cooling && backgroundIn < maxBackground)
        }
        private func take(_ lane: Lane) { if lane == .urgent { urgentIn += 1 } else { backgroundIn += 1 } }

        /// (Under the lock.) The waiting ones that may go now, urgent ones first, and the background ones a pause turns away.
        private func admit() -> [(CheckedContinuation<Void, Error>, Error?)] {
            var out: [(CheckedContinuation<Void, Error>, Error?)] = []
            if cooling {
                for w in queue where w.lane == .background { out.append((w.go, Refused())) }
                queue.removeAll { $0.lane == .background }
            }
            for lane in [Lane.urgent, .background] {
                while let i = queue.firstIndex(where: { $0.lane == lane }), fits(lane) {
                    take(lane)
                    out.append((queue.remove(at: i).go, nil))
                }
                if queue.contains(where: { $0.lane == .urgent }) { break }      // nothing goes before a waiting urgent one
            }
            return out
        }

        private static func resume(_ list: [(CheckedContinuation<Void, Error>, Error?)]) {
            for (c, e) in list { if let e { c.resume(throwing: e) } else { c.resume() } }
        }

        /// Waits for a place for a request in `lane`, `within` seconds at most (then `URLError(.timedOut)`). A background
        /// one during a pause throws `Refused`; a cancelled caller `CancellationError` at once. Each place taken is given
        /// back with `exit`.
        func enter(_ lane: Lane, within: TimeInterval) async throws {
            let id = nextId()
            let timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, within) * 1_000_000_000))
                if !Task.isCancelled { self?.drop(id, URLError(.timedOut)) }
            }
            defer { timer.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    var ready = admit()
                    let ahead = queue.contains { lane == .background || $0.lane == .urgent }
                    if Task.isCancelled {
                        ready.append((c, CancellationError()))
                    } else if lane == .background && cooling {
                        ready.append((c, Refused()))
                    } else if !ahead && fits(lane) {
                        take(lane)
                        ready.append((c, nil))
                    } else {
                        queue.append(Waiter(id: id, lane: lane, go: c))
                    }
                    lock.unlock()
                    Self.resume(ready)
                }
            } onCancel: {
                drop(id, CancellationError())
            }
        }

        /// A waiting one stops waiting (cancelled, or its time is up), if it's still waiting.
        private func drop(_ id: UInt64, _ error: Error) {
            lock.lock()
            let w = queue.firstIndex { $0.id == id }.map { queue.remove(at: $0) }
            lock.unlock()
            w?.go.resume(throwing: error)
        }

        /// A request is done: its place goes to the next one waiting.
        func exit(_ lane: Lane) {
            lock.lock()
            if lane == .urgent { urgentIn = max(0, urgentIn - 1) } else { backgroundIn = max(0, backgroundIn - 1) }
            let ready = admit()
            lock.unlock()
            Self.resume(ready)
        }

        // MARK: the same question once

        final class Flying: @unchecked Sendable {
            let tries = Tries()
            fileprivate var task: Task<Void, Never>?
            fileprivate var callers: Set<UInt64> = []
            fileprivate var waits: [UInt64: CheckedContinuation<NetAnswer, Error>] = [:]
            fileprivate var result: Result<NetAnswer, Error>?
        }
        /// One caller's place in a request on its way: `joined` when someone else's request was already on its way.
        struct Ticket: Sendable {
            let key: String
            let id: UInt64
            let flying: Flying
            let joined: Bool
            var tries: Tries { flying.tries }
        }
        private var flying: [String: Flying] = [:]

        /// Joins the request for `key` that's on its way, or starts it with `work`. Then `wait` for its answer.
        func join(_ key: String, work: @escaping @Sendable (Tries) async throws -> NetAnswer) -> Ticket {
            let id = nextId()
            lock.lock()
            defer { lock.unlock() }
            if let f = flying[key] {
                f.callers.insert(id)
                return Ticket(key: key, id: id, flying: f, joined: true)
            }
            let f = Flying()
            f.callers.insert(id)
            flying[key] = f
            f.task = Task { [weak self] in
                let r: Result<NetAnswer, Error>
                do { r = .success(try await work(f.tries)) } catch { r = .failure(error) }
                self?.finish(key, f, r)
            }
            return Ticket(key: key, id: id, flying: f, joined: false)
        }

        private func finish(_ key: String, _ f: Flying, _ r: Result<NetAnswer, Error>) {
            lock.lock()
            f.result = r
            if flying[key] === f { flying[key] = nil }
            let waiting = Array(f.waits.values)
            f.waits = [:]
            lock.unlock()
            for c in waiting { c.resume(with: r) }
        }

        /// The answer of the request `t` joined. A cancelled caller gets `CancellationError` at once.
        func wait(_ t: Ticket) async throws -> NetAnswer {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<NetAnswer, Error>) in
                    lock.lock()
                    if let r = t.flying.result {
                        lock.unlock()
                        c.resume(with: r)
                    } else if Task.isCancelled || !t.flying.callers.contains(t.id) {
                        lock.unlock()
                        c.resume(throwing: CancellationError())
                    } else {
                        t.flying.waits[t.id] = c
                        lock.unlock()
                    }
                }
            } onCancel: {
                leave(t)
            }
        }

        /// A caller stops waiting; once nobody waits for it, the request stops.
        private func leave(_ t: Ticket) {
            lock.lock()
            let c = t.flying.waits.removeValue(forKey: t.id)
            t.flying.callers.remove(t.id)
            var stop: Task<Void, Never>?
            if t.flying.callers.isEmpty, t.flying.result == nil {
                if flying[t.key] === t.flying { flying[t.key] = nil }
                stop = t.flying.task
            }
            lock.unlock()
            c?.resume(throwing: CancellationError())
            stop?.cancel()
        }
    }
}

/// Independent requests at once, each answer used as soon as it's in: a screen never waits for its slowest list.
enum Progressive {
    /// Runs every job at once; after each finishes, `publish` gets everything so far (in finishing order); returns it all.
    static func gather<T: Sendable>(_ jobs: [@Sendable () async -> [T]], publish: @escaping @Sendable ([T]) async -> Void) async -> [T] {
        await withTaskGroup(of: [T].self) { g in
            for job in jobs { g.addTask { await job() } }
            var all: [T] = []
            for await part in g {
                all += part
                await publish(all)
            }
            return all
        }
    }

    /// Runs every job at once; results in the jobs' order.
    static func all<T: Sendable>(_ jobs: [@Sendable () async -> T]) async -> [T] {
        await withTaskGroup(of: (Int, T).self) { g in
            for (i, job) in jobs.enumerated() {
                g.addTask {
                    let value = await job()
                    return (i, value)
                }
            }
            var done: [(Int, T)] = []
            for await r in g { done.append(r) }
            return done.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
}

extension Net {
    /// The final value if `work` finishes within `seconds`; else the last value it published (or nil) with timedOut, and the work is cancelled.
    /// `partial` gets each value as it's published, while the work runs (nothing once it's stopped). When the caller is
    /// cancelled, the work stops too, and the answer isn't marked as timed out.
    static func withPartials<T: Sendable>(_ seconds: Double,
        _ work: @escaping @Sendable (_ publish: @escaping @Sendable (T) async -> Void) async -> T,
        partial: @escaping @Sendable (T) async -> Void) async -> (value: T?, timedOut: Bool) {
        let latest = Latest<T>()
        let publish: @Sendable (T) async -> Void = { value in
            guard !Task.isCancelled else { return }       // stopped: what it still sends may be cut short
            await latest.keep(value)
            await partial(value)
        }
        let done: T? = await withTaskGroup(of: T?.self) { g in
            g.addTask { await work(publish) }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        if let done { return (done, false) }
        return (await latest.value, !Task.isCancelled)
    }
}

/// The last value a piece of work published.
private actor Latest<T: Sendable> {
    private(set) var value: T?
    func keep(_ v: T) { value = v }
}

#if !os(Linux)
/// A request's real bytes from its metrics, handed to `Net.onMetrics` (0.20.7).
final class MetricsReader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let report = Net.onMetrics else { return }
        var bytes: Int64 = 0
        var mobile = false
        for t in metrics.transactionMetrics {
            bytes += t.countOfRequestHeaderBytesSent + t.countOfRequestBodyBytesSent
                + t.countOfResponseHeaderBytesReceived + t.countOfResponseBodyBytesReceived
            if t.isCellular { mobile = true }
        }
        report(task.originalRequest?.url ?? task.currentRequest?.url, Int(clamping: bytes), mobile)
    }
}
#endif
