import Foundation

/// One stop of a trip as the live data gives it: when it gets there and when it leaves (live, else the timetable's),
/// and the timetable's own times. Plain values, so the rules can be tested without CoreLocation.
struct StopTimes: Equatable, Sendable {
    var arrival: Date?
    var departure: Date?
    var scheduledArrival: Date?
    var scheduledDeparture: Date?
    var at: Date? { arrival ?? departure }
    var leaves: Date? { departure ?? arrival }
    var scheduledAt: Date? { scheduledArrival ?? scheduledDeparture }
    var scheduledLeaves: Date? { scheduledDeparture ?? scheduledArrival }
}

extension StopTimes {
    /// A stop as a trip's live data has it: `scheduled` (either timetable time) stands in for the arrival when it has
    /// neither of the two.
    init(arrival: Date?, departure: Date?, scheduled: Date?, scheduledArrival: Date?, scheduledDeparture: Date?) {
        self.init(arrival: arrival, departure: departure,
                  scheduledArrival: scheduledArrival ?? (scheduledDeparture == nil ? scheduled : nil), scheduledDeparture: scheduledDeparture)
    }
}

/// A stop-to-stop piece's times (the live map's), with the timetable's.
struct PieceTimes: Equatable, Sendable {
    var departure: Date
    var arrival: Date
    var scheduledDeparture: Date?
    var scheduledArrival: Date?
}

/// One piece of a trip on the live map, as `LiveTimes.noCatchUp(trips:)` takes it.
struct TripPiece: Equatable, Sendable {
    var trip: String
    var carries: Bool               // a bus, coach or tram (`LiveTimes.carriesDelay`): trains stay as they are
    var live: Bool
    var times: PieceTimes
    var stops: String               // which stops it runs between: the same piece listed twice has the same
}

/// Where a bus is by its live times, without letting a late one run ahead of itself.
/// (Transitous has no bus GPS: a bus on the map is put where its stop times say. OpenOV's predictions let a late bus
/// make its delay up within a few stops, and MOTIS cuts every delay down to whole minutes, so a late bus is drawn
/// 50–90 s, half a kilometre to a kilometre, ahead of where it is.)
enum LiveTimes {
    static let lateFrom: TimeInterval = 60          // late: a minute or more behind its timetable
    static let horizon: TimeInterval = 15 * 60      // the delay is carried this far on (timetable time) [field]
    static let passGrace: TimeInterval = 120        // "passed your stop" only this long after it leaves there [field]

    /// Late buses, coaches and trams don't catch up (OpenOV's predictions); trains are left as they are. `mode` as the
    /// live data names it ("BUS", "TRAM", "REGIONAL_RAIL"); without one, by whether it's a train.
    static func carriesDelay(mode: String, isTrain: Bool) -> Bool {
        let m = mode.uppercased()
        guard !m.isEmpty else { return !isTrain }
        return m.contains("BUS") || m.contains("COACH") || m.contains("TRAM")
    }

    /// The last stop it has reached by the answer's own times at `asOf` (nil: not at its first stop yet).
    static func reached(_ s: [StopTimes], asOf: Date) -> Int? {
        s.indices.last { i in s[i].at.map { $0 <= asOf } ?? false }
    }

    /// No catching up. Each stop after the one it reached by `asOf` (before its first stop: its first stop) is no
    /// earlier than its timetable time plus the delay it left that stop with, less the waits the timetable has on the
    /// way (a late bus doesn't wait them out), up to `horizon` of timetable time on; the times stay in order. Only when
    /// that delay is at least `lateFrom`; only ever later; the stops it reached, and a trip without timetable times
    /// there, as given (a stop without timetable times is only kept in order).
    static func noCatchUp(_ s: [StopTimes], asOf: Date, horizon: TimeInterval = horizon) -> [StopTimes] {
        let r = reached(s, asOf: asOf) ?? 0
        guard r < s.count, let left = s[r].leaves, let planned = s[r].scheduledLeaves else { return s }
        var carry = left.timeIntervalSince(planned)
        guard carry >= lateFrom else { return s }
        var out = s
        var floor = left
        for k in (r + 1)..<max(r + 1, s.count) {
            var x = s[k]
            let sa = x.scheduledAt, sd = x.scheduledLeaves
            let within = sa.map { $0.timeIntervalSince(planned) <= horizon } ?? false
            if let a = x.arrival {
                var t = max(a, floor)
                if within, let sa { t = max(t, sa.addingTimeInterval(carry)) }
                x.arrival = t
            }
            // a wait in the timetable takes some of the delay up (it leaves as soon as it can)
            if let a = x.scheduledArrival, let d = x.scheduledDeparture { carry = max(0, carry - max(0, d.timeIntervalSince(a))) }
            if let d = x.departure {
                var t = max(d, x.arrival ?? floor, floor)
                if within, let sd { t = max(t, sd.addingTimeInterval(carry)) }
                x.departure = t
            }
            floor = x.leaves ?? floor
            out[k] = x
        }
        return out
    }

    /// The same for a trip's pieces (in departure order): a piece's end and the next one's start count as one stop, so
    /// a gap between two pieces (a stretch the live map left out) only takes delay up, it never adds any.
    static func noCatchUp(pieces: [PieceTimes], asOf: Date, horizon: TimeInterval = horizon) -> [PieceTimes] {
        guard !pieces.isEmpty else { return pieces }
        var stops: [StopTimes] = [StopTimes(arrival: nil, departure: pieces[0].departure,
                                            scheduledArrival: nil, scheduledDeparture: pieces[0].scheduledDeparture)]
        for k in pieces.indices {
            let next = k + 1 < pieces.count ? pieces[k + 1] : nil
            stops.append(StopTimes(arrival: pieces[k].arrival, departure: next?.departure,
                                   scheduledArrival: pieces[k].scheduledArrival, scheduledDeparture: next?.scheduledDeparture))
        }
        let fixed = noCatchUp(stops, asOf: asOf, horizon: horizon)
        return pieces.indices.map { k in
            var p = pieces[k]
            p.departure = fixed[k].departure ?? p.departure
            p.arrival = fixed[k + 1].arrival ?? p.arrival
            return p
        }
    }

    /// Every trip's pieces without catching up (`noCatchUp(pieces:)`), in the order given: grouped by trip, in
    /// departure order, a piece listed twice counted once; a trip that isn't carried (`carries`), has no live piece,
    /// or has a piece without timetable times, as it is.
    static func noCatchUp(trips given: [TripPiece], asOf: Date, horizon: TimeInterval = horizon) -> [PieceTimes] {
        var out = given.map(\.times)
        let byTrip = Dictionary(grouping: given.indices.filter { given[$0].carries }, by: { given[$0].trip })
        for (_, idx) in byTrip {
            guard idx.contains(where: { given[$0].live }),
                  idx.allSatisfy({ given[$0].times.scheduledDeparture != nil && given[$0].times.scheduledArrival != nil }) else { continue }
            var pieces: [PieceTimes] = [], slot: [Int: Int] = [:], seen: [String: Int] = [:]
            let order = idx.sorted { a, b in
                given[a].times.departure != given[b].times.departure ? given[a].times.departure < given[b].times.departure : a < b
            }
            for i in order {
                let t = given[i].times
                let key = "\(t.departure.timeIntervalSince1970)|\(t.arrival.timeIntervalSince1970)|\(given[i].stops)"
                if let k = seen[key] { slot[i] = k; continue }
                seen[key] = pieces.count; slot[i] = pieces.count
                pieces.append(t)
            }
            let fixed = noCatchUp(pieces: pieces, asOf: asOf, horizon: horizon)
            for (i, k) in slot { out[i] = fixed[k] }
        }
        return out
    }

    /// It has left your stop: it left there (by its times, else by the timetable) `grace` ago or more. Until then it's
    /// due, not gone. A stop without any time: nothing to wait for (left).
    static func hasLeft(_ stop: StopTimes, now: Date, grace: TimeInterval = passGrace) -> Bool {
        guard let l = stop.leaves ?? stop.scheduledLeaves else { return true }
        return now.timeIntervalSince(l) >= grace
    }

    /// Where to draw it while you wait at your stop (`mine` metres along): by its times, but not past your stop
    /// before it has left.
    static func shown(_ metres: Double, mine: Double, left: Bool) -> Double { left ? metres : min(metres, mine) }
}
