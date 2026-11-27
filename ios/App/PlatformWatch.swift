import Foundation

/// The trains of your trip, watched for a platform change or a cancellation (0.42.4). From the field report "The
/// platform changed but it didn't send a notification": only a first ride that was a train was ever watched (a trip is
/// bus 305, then the Intercity at Eindhoven: never), a watch started with no platform and the first NS answer filled it
/// in silently (a change before that answer was never told), and asleep on the bus the alert waited until you were
/// awake. Now every train of the trip is watched, from the plan's platform, and asleep it's a quiet notification at
/// once (the chime and the card when you're awake). Plain values, so the rules are tested. Foundation only.
enum PlatformWatch {
    /// s: trains leaving within this are watched…
    static let ahead: TimeInterval = 3 * 3600
    /// …and up to this long after their planned time (a late one is still to come).
    static let behind: TimeInterval = 10 * 60

    /// One ride of the trip.
    struct Leg: Equatable, Sendable {
        let train: Bool
        let num: String             // the train number ("3561"; empty: not known, matched by its time)
        let code: String?           // the NS station it leaves from (nil: not an NS station)
        let planned: Date           // its planned departure
    }

    /// The rides to watch: every train from an NS station, leaving within `ahead` (and not more than `behind` ago).
    static func toWatch(_ legs: [Leg], now: Date) -> [Int] {
        legs.indices.filter { k in
            let l: Leg = legs[k]
            guard l.train, let c = l.code, !c.isEmpty else { return false }
            let dt: TimeInterval = l.planned.timeIntervalSince(now)
            return dt <= ahead && dt >= -behind
        }
    }

    /// The platform a new watch starts from: the plan's (so a change against it is told, also one already made before
    /// NS's first answer), else NS's live one, else none (the first answer fills it in).
    static func seed(planned: String?, live: String?) -> String {
        if let p = planned, !norm(p).isEmpty { return p.trimmingCharacters(in: .whitespaces) }
        return (live ?? "").trimmingCharacters(in: .whitespaces)
    }

    enum Change: Equatable, Sendable {
        case none                       // nothing new
        case fill(String)               // the first platform it knows, nothing to tell
        case moved(was: String, now: String)
    }

    /// What NS's answer means for a watch at `track`: `live` its platform now, `nsPlanned` NS's own planned one. A watch
    /// with no platform yet takes NS's planned one as what it was (moved when the live one differs).
    static func change(track: String, live: String, nsPlanned: String) -> Change {
        let now: String = live.trimmingCharacters(in: .whitespaces)
        guard !norm(now).isEmpty else { return .none }
        var was: String = track.trimmingCharacters(in: .whitespaces)
        if norm(was).isEmpty {
            let p: String = nsPlanned.trimmingCharacters(in: .whitespaces)
            guard !norm(p).isEmpty, !same(p, now) else { return .fill(now) }
            was = p
        }
        return same(was, now) ? .none : .moved(was: was, now: now)
    }

    /// The same platform: equal, or the same number where one of them has no part letter ("5" and "5b": the plan
    /// often leaves the part out).
    static func same(_ a: String, _ b: String) -> Bool {
        let x: String = norm(a), y: String = norm(b)
        if x == y { return true }
        let dx: String = String(x.prefix { $0.isNumber }), dy: String = String(y.prefix { $0.isNumber })
        guard !dx.isEmpty, dx == dy else { return false }
        return x == dx || y == dy
    }

    static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }

    /// How it's told: at once with the chime and the card; asleep on a ride, at once as a quiet notification (seen on
    /// the lock screen and the watch), the chime and the card when you're awake.
    enum Delivery: Equatable, Sendable { case now, quietNowChimeLater }

    static func delivery(asleep: Bool) -> Delivery { asleep ? .quietNowChimeLater : .now }

    /// "platform · 08:02 Intercity to Breda at Eindhoven: 7 (was 5)", "platform · … at Eindhoven: cancelled".
    static func logLine(label: String, from: String, was: String, now: String, cancelled: Bool) -> String {
        if cancelled { return "platform · \(label) at \(from): cancelled" }
        return "platform · \(label) at \(from): \(now) (was \(was))"
    }
}
