import CryptoKit
import Foundation

// Live link payload v2 (relay 2026-11-27), Android's `LiveTripV2.kt`: the whole trip for the live page, from plain values
// so it's tested without the trip or the UI, byte for byte against docs/live-link-vectors.json (the same vector the page's
// own script and Android check). Inside the same lock as v1 (`LiveCrypto`); every v1 field is still there for a page
// before it. Also here: the messages a link's viewers send the sharer, the sharer's answers, whose name a link carries,
// and the app's own address for a link. Foundation and CryptoKit only.

/// One leg of the trip: a ride ("bus", "train", "tram", "metro", "ferry") or a walk ("walk", with `mins`).
struct LiveLeg: Codable, Equatable {
    var mode: String
    var line: String? = nil
    var num: String? = nil
    /// The line's colour, "RRGGBB" (none for a walk).
    var color: String? = nil
    var from: String
    var to: String
    var dep: Int? = nil
    var arr: Int? = nil
    var depPlatform: String? = nil
    var arrPlatform: String? = nil
    /// The coach and deck you shared for this train (only then).
    var coach: Int? = nil
    var deck: String? = nil
    var late: Int? = nil
    var mins: Int? = nil
}

/// A stop of the leg you're on (from where you got on to where you get off).
struct LiveStop: Codable, Equatable {
    var name: String
    var lat: Double
    var lon: Double
    var t: Int? = nil
}

/// "Listening now" (`MusicShare`): what you listen to, shown on the page while it’s under 10 minutes old.
struct LiveMusic: Codable, Equatable {
    var title: String
    var artist: String? = nil
    var app: String? = nil
    var url: String? = nil
    var coverUrl: String? = nil
    /// ISO 8601 ("2027-01-15T07:59:00Z").
    var at: String
}

enum LiveTripV2 {
    static let maxLegs = 12
    static let maxStops = 60
    static let maxShape = 200
    /// The whole state's JSON at most (bytes): over it the road goes, then the stops.
    static let budget = 12_000

    struct LegIn: Equatable {
        var mode: String
        var line: String? = nil
        var num: String? = nil
        var from: String
        var to: String
        var dep: Double? = nil
        var arr: Double? = nil
        var depPlatform: String? = nil
        var arrPlatform: String? = nil
        var coach: Int? = nil
        var deck: String? = nil
        var late: Int? = nil
        var mins: Int? = nil
    }

    struct StopIn: Equatable {
        var name: String
        var lat: Double
        var lon: Double
        var t: Double? = nil
    }

    struct Vehicle: Equatable {
        var lat: Double
        var lon: Double
        var at: Double
    }

    struct Trip: Equatable {
        var legs: [LegIn]
        var leg: Int
        /// The current leg's stops, where you got on to where you get off.
        var stops: [StopIn] = []
        /// The road its bus or train takes (all of it: cut here to your part).
        var shape: [GeoPoint] = []
        /// The vehicle's own GPS (the open feeds), when there's a fresh fix.
        var vehicle: Vehicle? = nil
        var face: String? = nil
        /// This app reads messages (the page shows its message box).
        var inbox: Bool = true
        var music: LiveMusic? = nil
    }

    /// A name or place as sent: no control characters, single spaces, at most `max` characters.
    static func clean(_ s: String?, _ max: Int) -> String {
        guard let s else { return "" }
        let words: [Substring] = s.split(whereSeparator: { $0.isWhitespace })
        let kept: [String] = words.map { w in
            String(String.UnicodeScalarView(w.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        }
        let one: String = kept.filter { !$0.isEmpty }.joined(separator: " ")
        return String(one.prefix(max)).trimmingCharacters(in: .whitespaces)
    }

    /// In 1e-5 degrees, half away from zero (the same on every platform).
    static func q(_ x: Double) -> Int64 {
        let a: Double = (abs(x) * 1e5 + 0.5).rounded(.down)
        return Int64(x < 0 ? -a : a)
    }

    static func r5(_ x: Double) -> Double { Double(q(x)) / 1e5 }

    /// A line's colour by kind (the app's own: bus orange, intercity indigo, sprinter cyan, tram purple).
    static func color(_ mode: String, _ line: String?) -> String? {
        let l: String = (line ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        switch mode {
        case "walk": return nil
        case "train":
            let sprinter: Bool = l.hasPrefix("SPR") || l.hasPrefix("SNG") || l.range(of: "^S[0-9]", options: .regularExpression) != nil
            return sprinter ? "0A93B5" : "3B44B0"
        case "tram", "metro": return "7A55B0"
        case "ferry": return "2A7898"
        default: return "E0632E"
        }
    }

    // MARK: the road

    static func encode(_ pts: [(Int64, Int64)]) -> String {
        var out: String = ""
        var pa: Int64 = 0
        var po: Int64 = 0
        func e(_ v0: Int64) {
            var v: Int64 = v0 < 0 ? ~(v0 << 1) : v0 << 1
            while v >= 32 {
                out.unicodeScalars.append(Unicode.Scalar(UInt8((32 | (v & 31)) + 63)))
                v >>= 5
            }
            out.unicodeScalars.append(Unicode.Scalar(UInt8(v + 63)))
        }
        for p in pts {
            e(p.0 - pa)
            e(p.1 - po)
            pa = p.0
            po = p.1
        }
        return out
    }

    private static func nearest(_ pts: [(Int64, Int64)], _ p: (Int64, Int64), from: Int) -> Int {
        var best: Int = from
        var bd: Int64 = .max
        for i in from..<pts.count {
            let dy: Int64 = pts[i].0 - p.0
            let dx: Int64 = pts[i].1 - p.1
            let d: Int64 = dy * dy + dx * dx
            if d < bd { bd = d; best = i }
        }
        return best
    }

    /// Douglas–Peucker in 1e-5 degrees, `tol` of them.
    static func simplify(_ pts: [(Int64, Int64)], tol: Int64) -> [(Int64, Int64)] {
        guard pts.count >= 3 else { return pts }
        var keep: [Bool] = Array(repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        let t2: Double = Double(tol * tol)
        while let pair = stack.popLast() {
            let (a, b) = pair
            if b - a < 2 { continue }
            let ay: Int64 = pts[a].0
            let ax: Int64 = pts[a].1
            let dy: Int64 = pts[b].0 - ay
            let dx: Int64 = pts[b].1 - ax
            let len2: Int64 = dx * dx + dy * dy
            var mi: Int = -1
            var md: Double = -1
            for i in (a + 1)..<b {
                let py: Int64 = pts[i].0
                let px: Int64 = pts[i].1
                let d: Double
                if len2 == 0 {
                    d = Double((py - ay) * (py - ay) + (px - ax) * (px - ax))
                } else {
                    let c: Double = Double(dx * (py - ay) - dy * (px - ax))
                    d = c * c / Double(len2)
                }
                if d > md { md = d; mi = i }
            }
            if md > t2 {
                keep[mi] = true
                stack.append((a, mi))
                stack.append((mi, b))
            }
        }
        return pts.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    /// Your part of the road (nearest the first and the last stop), at most 200 points, encoded; nil: none.
    static func road(_ shape: [GeoPoint], _ stops: [StopIn]) -> String? {
        var pts: [(Int64, Int64)] = shape.map { (q($0.lat), q($0.lon)) }
        let qs: [(Int64, Int64)] = stops.map { (q($0.lat), q($0.lon)) }
        if pts.count < 2 || qs.count < 2 {
            pts = qs
        } else {
            let i0: Int = nearest(pts, qs[0], from: 0)
            let i1: Int = nearest(pts, qs[qs.count - 1], from: i0)
            pts = i1 > i0 ? Array(pts[i0...i1]) : qs
        }
        var d: [(Int64, Int64)] = []
        for p in pts where d.last.map({ $0.0 != p.0 || $0.1 != p.1 }) ?? true { d.append(p) }
        guard d.count >= 2 else { return nil }
        var tol: Int64 = 1
        var r: [(Int64, Int64)] = simplify(d, tol: tol)
        while r.count > maxShape {
            tol *= 2
            r = simplify(d, tol: tol)
        }
        return encode(r)
    }

    private static func https(_ u: String?) -> String? {
        guard let u, u.hasPrefix("https://"), u.count <= 500 else { return nil }
        return u
    }

    private static func whole(_ x: Double?) -> Int? { x.map { Int($0.rounded(.down)) } }

    // MARK: the state

    /// v1's state (`LiveRules.state`) with the whole trip added: v 2.
    static func build(_ base: LiveState, _ t: Trip, now: Date) -> LiveState {
        let legs: [LiveLeg] = t.legs.prefix(maxLegs).map { l in
            let m0: String = clean(l.mode, 12)
            let mode: String = m0.isEmpty ? "bus" : m0
            let line0: String = clean(l.line, 20)
            let line: String? = line0.isEmpty || mode == "walk" ? nil : line0
            let num0: String = clean(l.num, 12)
            var o = LiveLeg(mode: mode, line: line, num: num0.isEmpty || mode != "train" ? nil : num0, color: color(mode, line),
                            from: clean(l.from, 40), to: clean(l.to, 40), dep: whole(l.dep), arr: whole(l.arr))
            let dp: String = clean(l.depPlatform, 8)
            let ap: String = clean(l.arrPlatform, 8)
            o.depPlatform = dp.isEmpty ? nil : dp
            o.arrPlatform = ap.isEmpty ? nil : ap
            if let c = l.coach, (1...30).contains(c) { o.coach = c }
            if l.deck == "upper" || l.deck == "lower" { o.deck = l.deck }
            if mode != "walk", let late = l.late { o.late = max(0, min(600, late)) }
            if mode == "walk", let m = l.mins { o.mins = max(0, min(120, m)) }
            return o
        }
        let src: [StopIn] = t.stops.count > maxStops ? Array(t.stops.prefix(maxStops - 1)) + [t.stops[t.stops.count - 1]] : t.stops
        let stops: [LiveStop] = src.map { LiveStop(name: clean($0.name, 40), lat: r5($0.lat), lon: r5($0.lon), t: whole($0.t)) }
        let n: Double = now.timeIntervalSince1970
        var s: LiveState = base
        s.v = 2
        s.legs = legs
        s.leg = legs.isEmpty ? nil : max(0, min(legs.count - 1, t.leg))
        s.stops = stops.isEmpty ? nil : stops
        if stops.isEmpty {
            s.next = nil
        } else if base.state == "waiting" {
            s.next = 0
        } else {
            s.next = stops.firstIndex { x in x.t.map { Double($0) > n } ?? false } ?? (stops.count - 1)
        }
        s.shape = road(t.shape, src)
        if let v = t.vehicle {
            s.pos = LiveState.Position(lat: r5(v.lat), lon: r5(v.lon), at: Date(timeIntervalSince1970: v.at.rounded(.down)), src: "gps")
        } else if s.pos != nil {
            s.pos?.src = "phone"
        }
        if let f = t.face, f.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil { s.face = f.uppercased() }
        s.inbox = t.inbox ? true : nil
        if let m = t.music {
            let title: String = clean(m.title, 80)
            if !title.isEmpty {
                let ar: String = clean(m.artist, 60)
                let ap: String = clean(m.app, 20)
                s.music = LiveMusic(title: title, artist: ar.isEmpty ? nil : ar, app: ap.isEmpty ? nil : ap, url: https(m.url), coverUrl: https(m.coverUrl), at: m.at)
            }
        }
        if bytes(s) > budget { s.shape = nil }
        if bytes(s) > budget { s.stops = nil; s.next = nil }
        return s
    }

    static func bytes(_ s: LiveState) -> Int { (try? LiveCrypto.encoder.encode(s))?.count ?? 0 }

    /// A friends account's colour for its initial (the app's own six, picked by the account, as `FriendAvatar`).
    static func face(_ account: String?) -> String {
        let colours: [String] = ["0E7A55", "3B44B0", "0A93B5", "E0632E", "6B3FA0", "1C6E8C"]
        guard let account, !account.isEmpty else { return colours[0] }
        let n: Int = account.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return colours[n % colours.count]
    }
}

/// Whose name a live link carries: your Friends name, else the one you typed for live links; never anyone else's.
enum LiveNames {
    static func sender(friends: String?, typed: String?) -> String {
        let f: String = FriendNames.clean(friends ?? "")
        return f.isEmpty ? FriendNames.clean(typed ?? "") : f
    }
}

/// A message to the sharer from someone with the link: the page sends `fromKind` "web" with the name they typed (or
/// none), an app "app" with its own name and, with a friends account, its account (`friendId`) so the sharer's app shows
/// that friend. Locked with the link's key, AAD "hw-live-msg-v1\n" + token.
struct LiveMessage: Codable, Equatable {
    var from: String = ""
    var fromKind: String = "web"
    var friendId: String? = nil
    var text: String
    var at: Double
}

/// The sharer's answer, which every page of the link shows; AAD "hw-live-reply-v1\n" + token. `re`: the message it answers.
struct LiveReply: Codable, Equatable {
    var text: String
    var at: Double
    var re: Int? = nil
}

enum LiveMessages {
    static let msg = "hw-live-msg-v1"
    static let reply = "hw-live-reply-v1"
    static let maxText = 280
    static let chips: [String] = ["👋 On my way", "I’m at the station", "Running late", "Call me"]

    /// A message as read: text 1–280 characters (cleaned), a name ≤ 40, an account id of 32 hex characters or none.
    static func valid(_ m: LiveMessage) -> LiveMessage? {
        let text: String = LiveTripV2.clean(m.text, maxText)
        guard !text.isEmpty else { return nil }
        let kind: String = m.fromKind == "app" ? "app" : "web"
        var id: String? = nil
        if kind == "app", let f = m.friendId, f.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil { id = f }
        return LiveMessage(from: LiveTripV2.clean(m.from, 40), fromKind: kind, friendId: id, text: text, at: m.at.rounded(.down))
    }

    static func seal(_ m: LiveMessage, key: Data, token: String, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        try LiveCrypto.seal(try LiveCrypto.encoder.encode(m), key: key, token: token, kind: msg, nonce: nonce)
    }

    static func open(_ data: Data, key: Data, token: String) -> LiveMessage? {
        guard let p = try? LiveCrypto.open(data, key: key, token: token, kind: msg),
              let m = try? JSONDecoder().decode(LiveMessage.self, from: p) else { return nil }
        return valid(m)
    }

    static func sealReply(_ r: LiveReply, key: Data, token: String, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        try LiveCrypto.seal(try LiveCrypto.encoder.encode(r), key: key, token: token, kind: reply, nonce: nonce)
    }

    static func openReply(_ data: Data, key: Data, token: String) -> LiveReply? {
        guard let p = try? LiveCrypto.open(data, key: key, token: token, kind: reply),
              let r = try? JSONDecoder().decode(LiveReply.self, from: p) else { return nil }
        let t: String = LiveTripV2.clean(r.text, maxText)
        return t.isEmpty ? nil : LiveReply(text: t, at: r.at.rounded(.down), re: r.re)
    }

    /// Who it's from as the sharer's app shows it: the friend (by account), the name they gave, or "Someone with your link".
    static func sender(_ m: LiveMessage, friendName: (String) -> String?) -> String {
        if let id = m.friendId, let n = friendName(id) { return n }
        return m.from.isEmpty ? "Someone with your link" : m.from
    }

    /// "💬 Kim: On my way"
    static func notice(_ m: LiveMessage, friendName: (String) -> String?) -> String { "💬 " + sender(m, friendName: friendName) + ": " + m.text }

    /// The first live link (either form) in a shared or pasted text.
    static func find(_ text: String) -> String? {
        let p = "(https://haltewekker-relay\\.tsfaw1\\.workers\\.dev/live/|haltewekker://live/)[A-Za-z0-9_-]{22}/?#[^\\s]+"
        guard let r = text.range(of: p, options: .regularExpression) else { return nil }
        return String(text[r])
    }
}
