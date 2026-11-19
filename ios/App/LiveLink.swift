import CryptoKit
import Foundation

// Live link (0.30): a web page with your trip's live times for someone without the app (a parent), as plain values,
// the lock and the rules, tested without the relay, the trip or the UI. Foundation and CryptoKit only.
//
//   link   = https://haltewekker-relay.tsfaw1.workers.dev/live/<token>#k=<key>   (0.30: #<key>; both read)
//   secret = 32 random bytes (stays on the phone: it lets the phone write)   key = 32 random bytes (AES-256-GCM)
//   token  = base64url(first 16 bytes of SHA-256("hw-live-token-v1" ‖ secret))
//   data   = 0x01 ‖ nonce (12) ‖ AES-256-GCM(key, AAD "hw-live-v1\n" + token)(the state's JSON) ‖ tag (16)
// The key is only in the link's fragment, which a browser never sends: the relay (relay/live.js) holds only locked
// bytes and forgets them when the link ends. The page decrypts in the browser with WebCrypto. Platform-neutral: see
// docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.30)".

/// What the page shows: a trip's state now (the 0.26 travel state, cut down), locked into each put.
struct LiveState: Codable, Equatable {
    struct Position: Codable, Equatable {
        var lat: Double
        var lon: Double
        var at: Date
    }

    enum Stage: String {
        case waiting, riding, change, arrived
    }

    var v: Int = 1
    /// Your name as the page says it ("Sam").
    var name: String
    /// "waiting" | "riding" | "change" | "arrived" (an unknown value reads as riding).
    var state: String
    /// "train" | "bus" (or "tram", "metro", "ferry").
    var mode: String
    /// As shown: "305", "IC".
    var line: String? = nil
    /// A train's number ("3512").
    var num: String? = nil
    /// Where this ride starts, and where it goes (names only).
    var from: String? = nil
    var to: String? = nil
    /// The trip's end, when it isn't `to`.
    var dest: String? = nil
    /// When it leaves `from` (waiting, or the next ride at a change).
    var dep: Date? = nil
    /// When it gets to `to` (arrived: when you got there).
    var eta: Date? = nil
    /// When it gets to the trip's end.
    var end: Date? = nil
    /// Minutes late (0: on time; absent: not known).
    var late: Int? = nil
    /// The phone's last fix (5 decimals).
    var pos: Position? = nil
    /// When this was written.
    var t: Date

    var stage: Stage { Stage(rawValue: state) ?? .riding }
}

/// A link's two secrets.
struct LiveKeys: Codable, Equatable {
    var secret: Data
    var key: Data

    static func make() -> LiveKeys { LiveKeys(secret: LiveCrypto.random(32), key: LiveCrypto.random(32)) }

    var token: String { LiveCrypto.token(secret) }
    var link: String { LiveCrypto.link(token: token, key: key) }
}

enum LiveCrypto {
    static let relay = "https://haltewekker-relay.tsfaw1.workers.dev"
    static let version: UInt8 = 1

    static func random(_ n: Int) -> Data {
        let k = SymmetricKey(size: SymmetricKeySize(bitCount: n * 8))
        return k.withUnsafeBytes { Data($0) }
    }

    /// The token for a secret: 22 characters.
    static func token(_ secret: Data) -> String {
        let h = SHA256.hash(data: Data("hw-live-token-v1".utf8) + secret)
        return B64URL.encode(Data(h).prefix(16))
    }

    /// (0.30.1) The key after `#k=` (0.30 put it bare after the `#`: the page and `parse` read both). Only ever in the
    /// fragment, which no browser sends: the relay never sees it.
    static func link(token: String, key: Data) -> String { "\(relay)/live/\(token)#k=\(B64URL.encode(key))" }

    /// A link back into its token and key (nil: not a live link of this relay, or no key). The fragment may be the key
    /// itself or `k=<key>` among other fields.
    static func parse(_ s: String) -> (token: String, key: Data)? {
        let prefix = "\(relay)/live/"
        let t: String = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix(prefix) else { return nil }
        let rest: Substring = t.dropFirst(prefix.count)
        let parts: [Substring] = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let token: String = String(parts[0]).hasSuffix("/") ? String(parts[0].dropLast()) : String(parts[0])
        var keyText: String = String(parts[1])
        for field in parts[1].split(separator: "&") where field.hasPrefix("k=") { keyText = String(field.dropFirst(2)) }
        guard token.count == 22, let key = B64URL.decode(keyText), key.count == 32 else { return nil }
        return (token, key)
    }

    static func aad(_ token: String) -> Data { Data("hw-live-v1\n\(token)".utf8) }

    /// Locks a state's JSON for the page.
    static func seal(_ plain: Data, key: Data, token: String, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: nonce, authenticating: aad(token))
        guard let c = box.combined else { throw FriendBoxError.badFormat }
        return Data([version]) + c
    }

    static func open(_ data: Data, key: Data, token: String) throws -> Data {
        guard data.count >= 1 + 12 + 16, data.first == version else { throw FriendBoxError.badFormat }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst()))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad(token))
        } catch { throw FriendBoxError.cantOpen }
    }

    /// A state as it goes: its JSON (sorted keys), locked.
    static func lock(_ s: LiveState, keys: LiveKeys) throws -> Data {
        try seal(try FriendJSON.encoder.encode(s), key: keys.key, token: keys.token)
    }
}

/// When the phone posts, and how long the link lives.
enum LiveRules {
    /// A link lives at most this long after it was made (the relay holds to it too).
    static let maxAge: TimeInterval = 4 * 3600
    /// While the trip runs, each put keeps the link this much longer (so it ends by itself if the phone goes quiet).
    static let ahead: TimeInterval = 30 * 60
    /// After the last stop, "Arrived" stays this long.
    static let afterArrival: TimeInterval = 15 * 60
    /// A put at most this often on the ride's tick…
    static let every: TimeInterval = 55
    /// …and at once when the stage, the leg or the vehicle changes, but never within this of the last (the relay
    /// takes one every 5 s).
    static let minGap: TimeInterval = 6
    /// The page greys "Last update 07:41" after this.
    static let staleAfter: TimeInterval = 150

    /// The next put: something changed (and `minGap` went by), or `every` went by.
    static func due(lastSent: Date?, lastKey: String, key: String, now: Date) -> Bool {
        guard let lastSent else { return true }
        let gap: TimeInterval = now.timeIntervalSince(lastSent)
        if gap < 0 { return true }
        if gap < minGap { return false }
        return key != lastKey || gap >= every
    }

    /// The `until` a put asks for: `ahead` from now, never past the link's 4 hours; `arrived`: `afterArrival` from now.
    static func until(created: Date, now: Date, arrived: Bool = false) -> Date {
        let want: Date = now.addingTimeInterval(arrived ? afterArrival : ahead)
        return min(want, created.addingTimeInterval(maxAge))
    }

    /// The link has run its 4 hours.
    static func expired(created: Date, now: Date) -> Bool { now.timeIntervalSince(created) >= maxAge }

    /// The page's state from the trip's travel state (0.26's, as friends get it): names only, the position without its
    /// accuracy, how late when known, and when the next ride leaves while waiting or at a change.
    static func state(_ s: TravelState, name: String, dep: Date?, late: Int?, now: Date) -> LiveState {
        var v = LiveState(name: FriendNames.clean(name), state: s.state, mode: s.mode, t: now)
        v.line = s.line
        v.num = s.num
        v.from = s.from.name
        v.to = s.to.name
        if let d = s.dest, d.name != s.to.name { v.dest = d.name }
        v.eta = s.eta
        v.end = s.end
        if s.stage != .riding { v.dep = dep }
        if let late { v.late = max(0, min(600, late)) }
        if let p = s.pos { v.pos = LiveState.Position(lat: p.lat, lon: p.lon, at: p.at) }
        return v
    }

    /// The last state: arrived at `stop` at `at` (no position, no lateness).
    static func arrived(_ last: LiveState?, name: String, stop: String?, at: Date) -> LiveState {
        var v = LiveState(name: FriendNames.clean(name), state: LiveState.Stage.arrived.rawValue, mode: last?.mode ?? "bus", t: at)
        v.line = last?.line
        v.num = last?.num
        v.from = last?.from
        v.to = stop ?? last?.dest ?? last?.to
        v.eta = at
        return v
    }

    /// Minutes late at your stop: the live arrival against the scheduled one (nil when either isn't known).
    static func late(live: Date?, scheduled: Date?) -> Int? {
        guard let live, let scheduled else { return nil }
        return max(0, Int((live.timeIntervalSince(scheduled) / 60).rounded()))
    }

    /// A fingerprint of what changes the page at once: the stage, the vehicle, the leg's ends.
    static func key(_ s: LiveState) -> String {
        "\(s.state)|\(s.mode)|\(s.line ?? "")|\(s.num ?? "")|\(s.from ?? "")|\(s.to ?? "")"
    }
}

/// The page's words, the same in the app (what they see) and on the page (relay/live.js does the same).
enum LiveWords {
    /// "bus 305", "the IC 3512", "the IC", "the train", "the bus", "tram 1".
    static func vehicle(_ s: LiveState) -> String {
        let line: String = (s.line ?? "").trimmingCharacters(in: .whitespaces)
        let num: String = (s.num ?? "").trimmingCharacters(in: .whitespaces)
        let mode: String = s.mode.isEmpty ? "bus" : s.mode
        if mode == "train" { return line.isEmpty ? "the train" : "the " + (num.isEmpty ? line : "\(line) \(num)") }
        return line.isEmpty ? "the \(mode)" : "\(mode) \(line)"
    }

    private static func late(_ s: LiveState) -> String {
        guard let l = s.late else { return "" }
        return l >= 1 ? " · \(l) min late" : " · on time"
    }

    /// "Sam is on bus 305 to Den Bosch · arrives 07:51 · 3 min late", "Sam is waiting for the IC 3512 to Breda at
    /// Eindhoven Centraal · leaves 07:41", "Sam is changing at Eindhoven Centraal · then the IC 3512 to Breda at 08:03",
    /// "Sam has arrived at Den Bosch · 07:52".
    static func headline(_ s: LiveState, zone: TimeZone = TimetableDays.zone) -> String {
        let n0: String = s.name.trimmingCharacters(in: .whitespaces)
        let n: String = n0.isEmpty ? "Your friend" : n0
        let v: String = vehicle(s)
        let to: String = s.to.map { " to \($0)" } ?? ""
        let clock: (Date) -> String = { TravelWords.clock($0, zone: zone) }
        switch s.stage {
        case .arrived:
            let place: String = s.to.map { " at \($0)" } ?? ""
            let when: String = s.eta.map { " · " + clock($0) } ?? ""
            return n + " has arrived" + place + when
        case .waiting:
            let at: String = s.from.map { " at \($0)" } ?? ""
            let dep: String = s.dep.map { " · leaves " + clock($0) } ?? ""
            return n + " is waiting for " + v + to + at + dep + late(s)
        case .change:
            let at: String = s.from.map { " at \($0)" } ?? ""
            guard s.line != nil else { return n + " is changing" + at }
            let dep: String = s.dep.map { " at " + clock($0) } ?? ""
            return n + " is changing" + at + " · then " + v + to + dep
        case .riding:
            let eta: String = s.eta.map { " · arrives " + clock($0) } ?? ""
            return n + " is on " + v + to + eta + late(s)
        }
    }

    /// "Then on to Breda · there around 08:45" (nil: arrived, or `to` is the trip's end).
    static func detail(_ s: LiveState, zone: TimeZone = TimetableDays.zone) -> String? {
        guard s.stage != .arrived, let d = s.dest, d != s.to else { return nil }
        let there: String = s.end.map { " · there around " + TravelWords.clock($0, zone: zone) } ?? ""
        return "Then on to \(d)" + there
    }

    /// (0.30.1) What "Send the link" hands the share sheet: plain text, the whole link on a line of its own. Text is kept
    /// as it is; a link handed over as a link can be turned into a preview that opens without its # part (its key).
    static func shareText(_ link: String) -> String { "Follow my trip live:\n\(link)" }
}
