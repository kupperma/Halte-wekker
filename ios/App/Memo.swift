import Foundation

/// Remembers real answers for a while, and lets everyone asking for the same thing share one request.
/// A failed fetch (nil) is never remembered.
actor Memo<K: Hashable & Sendable, V: Sendable> {
    private let ttl: TimeInterval
    private let limit: Int
    private let now: @Sendable () -> Date
    private var items: [K: (value: V, at: Date)] = [:]
    private var flying: [K: Task<V?, Never>] = [:]

    init(ttl: TimeInterval, limit: Int = 200, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.limit = limit
        self.now = now
    }

    /// The fresh value, else one shared fetch.
    func get(_ key: K, fetch: @escaping @Sendable () async -> V?) async -> V? {
        if let hit = items[key], now().timeIntervalSince(hit.at) < ttl { return hit.value }
        if let task = flying[key] { return await task.value }
        let task = Task { await fetch() }
        flying[key] = task
        let value = await task.value
        flying[key] = nil
        if let value { store(key, value) }
        return value
    }

    /// The stored value at any age.
    func peek(_ key: K) -> V? { items[key]?.value }

    private func store(_ key: K, _ value: V) {
        items[key] = (value, now())
        while items.count > limit, let oldest = items.min(by: { $0.value.at < $1.value.at })?.key {
            items[oldest] = nil
        }
    }
}
