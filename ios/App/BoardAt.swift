import Foundation

/// Where to get on (0.25.1). Fastest trip's first bus is the planner's (or an earlier one onto the same connection,
/// `Transit.earlierWays`) at the stop that was asked about: in Veghel that put you on the 158 at the bus station, a
/// 9 minute walk back, while the same bus calls at Bolkenplein a minute later, round the corner from you. So: on the
/// same trip, from its first stop up to where you get off it, the stop you walk to least while you still make it
/// there (`margin` before it's due, by its live time when it has one). A stop only counts as better when it's clearly
/// closer than the one it had (`clearlyCloser`, straight line both): the planner's own walk there follows the
/// streets, and a near tie isn't worth another stop. Plain values (no stores, no network), so the rules are tested.
enum BoardAt {
    /// One stop of a trip, as the trip's own answer has it.
    struct Stop: Equatable, Sendable {
        let id: String
        let name: String
        let point: GeoPoint
        /// When it leaves there: the live time when there is one (nil: no time, it can't be the one).
        let departure: Date?
        var scheduledDeparture: Date? = nil
        var track: String? = nil
        var scheduledTrack: String? = nil
        /// You may get on there: not "drop off only", not cancelled.
        var boarding: Bool = true
    }

    /// Where to get on instead, and the walk there in minutes.
    struct Choice: Equatable {
        let index: Int
        let walk: Int
        var stop: Stop
    }

    /// Be there this long before it's due.
    static let margin: TimeInterval = 60
    /// Another stop only when it's at least this much closer (straight line) than the one it had.
    static let clearlyCloser = 80.0
    /// The boarding stop in the trip's list: its own id (or within this of where it is), the call closest to its time.
    static let sameStop = 80.0
    /// Where you get off: within this of the ride's end (or its name).
    static let alightWithin = 150.0

    /// The walk to a stop that far away (straight line): a third longer by the streets, at 1.2 m/s, whole minutes up;
    /// as `Transit.fromNearest` counts it.
    static func walkMinutes(metres m: Double) -> Int {
        max(1, Int((max(0, m) * 1.33 / 1.2 / 60).rounded(.up)))
    }

    /// Where in `stops` the ride gets on now: a call at its stop id (else within `sameStop` of where it's said to be),
    /// the one closest to its departure. Nil: not there.
    static func boardingIndex(_ stops: [Stop], fromId: String, from: GeoPoint?, departure: Date) -> Int? {
        var hits = stops.indices.filter { !fromId.isEmpty && stops[$0].id == fromId }
        if hits.isEmpty, let f = from {
            hits = stops.indices.filter { Geo.metres(f, stops[$0].point) <= sameStop }
        }
        func off(_ i: Int) -> Double {
            let t: Date = stops[i].departure ?? stops[i].scheduledDeparture ?? .distantPast
            return abs(t.timeIntervalSince(departure))
        }
        return hits.min { off($0) < off($1) }
    }

    /// Where the ride gets off: the first stop after `board` within `alightWithin` of its end (else by name). Nil: not
    /// found.
    static func alightingIndex(_ stops: [Stop], after board: Int, to: GeoPoint?, toName: String) -> Int? {
        guard board + 1 < stops.count else { return nil }
        let later = Array((board + 1)..<stops.count)
        if let t = to, let i = later.first(where: { Geo.metres(t, stops[$0].point) <= alightWithin }) { return i }
        guard !toName.isEmpty else { return nil }
        return later.first { stops[$0].name == toName }
    }

    /// Among the stops before `alight` (from the trip's first one), the one you'd walk to least from `you` that you
    /// still make: there `margin` before it leaves, at `walkMinutes`. Only one clearly closer than `board` (the stop it
    /// had); never one it has left, nor one you may not get on at. Nil: keep `board`.
    static func pick(_ stops: [Stop], board: Int, alight: Int, you: GeoPoint, now: Date) -> Choice? {
        guard stops.indices.contains(board), alight > board, alight <= stops.count else { return nil }
        let had = Geo.metres(you, stops[board].point)
        var best: (choice: Choice, metres: Double, departure: Date)?
        for i in 0..<alight where i != board {
            let s = stops[i]
            guard s.boarding, let dep = s.departure else { continue }
            let m = Geo.metres(you, s.point)
            guard m <= had - clearlyCloser else { continue }
            let walk = walkMinutes(metres: m)
            guard now.addingTimeInterval(Double(walk) * 60 + margin) <= dep else { continue }
            // the closest; on a tie, the later call (less waiting)
            if let b = best, m > b.metres || (m == b.metres && dep <= b.departure) { continue }
            best = (Choice(index: i, walk: walk, stop: s), m, dep)
        }
        return best?.choice
    }

    /// The whole question for one ride: where it gets on now (`fromId`, `from`, `departure`), where it gets off (`to`,
    /// `toName`), and where you'd better get on instead. Nil: where it gets on is best (or it can't tell).
    static func better(_ stops: [Stop], fromId: String, from: GeoPoint?, departure: Date, to: GeoPoint?, toName: String,
                       you: GeoPoint, now: Date) -> Choice? {
        guard let b = boardingIndex(stops, fromId: fromId, from: from, departure: departure),
              let e = alightingIndex(stops, after: b, to: to, toName: toName) else { return nil }
        return pick(stops, board: b, alight: e, you: you, now: now)
    }
}
