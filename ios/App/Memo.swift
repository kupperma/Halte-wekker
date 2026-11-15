import Foundation

/// Remembers real answers for a while, and lets everyone asking for the same thing share one request.
/// A failed fetch (nil) is never remembered. A waiter that is cancelled leaves at once with nil; when the last waiter
/// of a fetch has left, the fetch is cancelled too.
actor Memo<K: Hashable & Sendable, V: Sendable> {
    private struct FlightKey: Hashable { let key: K; let group: Int }
    private final class Flight: @unchecked Sendable {
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<V?, Never>] = [:]
    }

    private let ttl: TimeInterval
    private let limit: Int
    private let now: @Sendable () -> Date
    private var items: [K: (value: V, at: Date)] = [:]
    private var flights: [FlightKey: Flight] = [:]

    init(ttl: TimeInterval, limit: Int = 200, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.limit = limit
        self.now = now
    }

    /// The fresh value, else one shared fetch. Callers of different `group`s (urgent / background) never share a
    /// fetch, but they share the stored answer. A real answer that arrives after every waiter left is still stored.
    func get(_ key: K, group: Int = 0, fetch: @escaping @Sendable () async -> V?) async -> V? {
        if let hit = items[key], (0..<ttl).contains(now().timeIntervalSince(hit.at)) { return hit.value }
        let fk = FlightKey(key: key, group: group)
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<V?, Never>) in
                if Task.isCancelled { cont.resume(returning: nil); return }
                if let f = flights[fk] { f.waiters[id] = cont; return }
                let f = Flight()
                f.waiters[id] = cont
                flights[fk] = f
                f.task = Task { [self] in
                    let v = await fetch()
                    await finish(fk, f, v)
                }
            }
        } onCancel: {
            Task { await self.leave(fk, id) }
        }
    }

    /// The stored value at any age.
    func peek(_ key: K) -> V? { items[key]?.value }

    /// The stored value at any age, with when it was stored.
    func peekDated(_ key: K) -> (value: V, at: Date)? { items[key] }

    private func finish(_ fk: FlightKey, _ f: Flight, _ value: V?) {
        if flights[fk] === f { flights[fk] = nil }
        f.task = nil
        if let value { store(fk.key, value) }
        let waiting = f.waiters
        f.waiters = [:]
        for (_, c) in waiting { c.resume(returning: value) }
    }

    private func leave(_ fk: FlightKey, _ id: UUID) {
        guard let f = flights[fk], let c = f.waiters.removeValue(forKey: id) else { return }
        c.resume(returning: nil)
        if f.waiters.isEmpty {
            flights[fk] = nil
            f.task?.cancel()
        }
    }

    private func store(_ key: K, _ value: V) {
        items[key] = (value, now())
        while items.count > limit, let oldest = items.min(by: { $0.value.at < $1.value.at })?.key {
            items[oldest] = nil
        }
    }
}
