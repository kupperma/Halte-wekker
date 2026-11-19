import Foundation

/// Friends (0.25): the relay's mailbox routes (relay/friends.js), each request signed with your account key. One
/// try per request (a signed request can't be sent twice: the relay refuses a nonce it has seen).
struct FriendRelay {
    static let base = NSStore.relay
    let me: FriendIdentity
    let device: String
    /// The field log's name for these calls ("friends/inbox"); nil: not written there at all (the test friend's own
    /// calls, 0.30.1, so they're never in a shared log).
    var label: String? = "friends"

    enum Failure: Error, Equatable {
        /// The account moved to another phone (restored there with the backup code).
        case signedOut
        /// The relay doesn't know this account (deleted, or never registered).
        case unknownAccount
        case slowDown
        case refused(Int, String)
        case offline
    }

    private static let budget = Budget(idle: 8, total: 15, retries: 0, backoff: 1, fastFailure: 2, minLeft: 3)

    private struct ErrorAnswer: Decodable { let error: String? }

    func call<T: Decodable>(_ path: String, _ body: [String: Any], lane: Lane = .background) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let url = URL(string: Self.base + path) else { throw Failure.offline }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let headers = try RelaySign.headers(me, device: device, path: path, body: data,
                                            time: Int(Date().timeIntervalSince1970), nonce: RelaySign.nonce())
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let answer: NetAnswer
        do {
            answer = try await Net.response(req, lane: lane, budget: Self.budget, label: label.map { $0 + String(path.dropFirst(5)) })
        } catch {
            throw Failure.offline
        }
        if answer.status == 200 {
            return try JSONDecoder().decode(T.self, from: answer.data)
        }
        let e = (try? JSONDecoder().decode(ErrorAnswer.self, from: answer.data))?.error ?? ""
        switch (answer.status, e) {
        case (409, _): throw Failure.signedOut
        case (404, "unknown_account"): throw Failure.unknownAccount
        case (429, _): throw Failure.slowDown
        default: throw Failure.refused(answer.status, e)
        }
    }

    func register() async throws -> RelayRegistered {
        try await call("/f/v1/register", ["signKey": B64URL.encode(me.card.signKey)], lane: .urgent)
    }

    func inbox(after: Int, lane: Lane = .background) async throws -> RelayInbox {
        try await call("/f/v1/inbox", ["after": after, "limit": 100], lane: lane)
    }

    private struct Deleted: Decodable { let deleted: Int }
    private struct OK: Decodable { let ok: Bool }

    func ack(_ ids: [Int]) async throws {
        guard !ids.isEmpty else { return }
        let _: Deleted = try await call("/f/v1/ack", ["ids": ids])
    }

    /// Sends up to 20 boxes; the relay answers for each.
    func send(_ boxes: [FriendPending]) async throws -> [RelaySendResult] {
        let list: [[String: Any]] = boxes.map { b in
            var d: [String: Any] = ["to": b.to, "data": b.data ?? ""]
            if let s = b.slot { d["slot"] = s }
            if let t = b.ttl { d["ttl"] = t }
            return d
        }
        let r: RelaySent = try await call("/f/v1/send", ["boxes": list])
        return r.results
    }

    func drop(_ peer: String) async throws { let _: OK = try await call("/f/v1/drop", ["peer": peer]) }
    func block(_ peer: String, on: Bool = true) async throws { let _: OK = try await call("/f/v1/block", ["peer": peer, "on": on]) }
    func vaultPut(_ data: Data) async throws { let _: OK = try await call("/f/v1/vault/put", ["data": B64URL.encode(data)]) }
    func vaultGet() async throws -> Data? {
        let v: RelayVault = try await call("/f/v1/vault/get", [:], lane: .urgent)
        return v.data.flatMap(B64URL.decode)
    }
    // MARK: latest states (0.26)

    /// Puts your state at up to 50 friends (each a box locked for them); the relay answers for each.
    func statePut(_ states: [(to: String, data: Data)], ttl: Int, lane: Lane = .background) async throws -> [RelaySendResult] {
        let list: [[String: Any]] = states.map { ["to": $0.to, "data": B64URL.encode($0.data), "ttl": ttl] }
        let r: RelaySent = try await call("/f/v1/state/put", ["states": list], lane: lane)
        return r.results
    }

    /// The states friends left for you.
    func stateGet(lane: Lane = .background) async throws -> [RelayState] {
        let r: RelayStates = try await call("/f/v1/state/get", [:], lane: lane)
        return r.states
    }

    /// Takes your state back: from these friends, or (nil) from everyone it went to.
    @discardableResult
    func stateClear(_ to: [String]? = nil) async throws -> Int {
        let body: [String: Any] = to.map { ["to": $0] } ?? [:]
        let r: RelayCleared = try await call("/f/v1/state/clear", body)
        return r.cleared
    }

    func leave() async throws { let _: OK = try await call("/f/v1/leave", [:], lane: .urgent) }
}
