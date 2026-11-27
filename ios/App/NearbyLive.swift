import Foundation

// 0.42.7: the stops around you by live times. From the field report "The new screen doesn't account for delayed time":
// at 14:37 the classic Fastest trip said "Bus 5 to Centraal Station 14:41 +3 min", the stop's sheet "5 14:38 live"
// (its plan answer was a few minutes old, and its fresher board left out the departures it had). Plain rules, tested in
// `NearbyLiveTests`; Android has the same (`travel/NearbyLive.kt`, `NearbyLiveTest`).

/// A way's legs freshened by newer live times of the same trips (by trip id: the stop's board, Fastest trip's own
/// ways), and how a time is shown ("14:41 +3", the planned one struck through).
enum NearbyLive {
    /// One leg's times: live when `live`, the timetable's beside them.
    struct Leg: Equatable {
        var tripId: String
        var departure: Date
        var scheduledDeparture: Date
        var arrival: Date
        var scheduledArrival: Date
        var live: Bool
        var toStop: String = ""
    }

    /// A trip's live times as a newer answer has them: how late it leaves (and arrives at `toStop`), and when that was
    /// known. A delay applies to the leg's own timetable times, so it fits at another stop of the same trip too.
    struct Update: Equatable {
        var tripId: String
        var departureDelay: TimeInterval
        var arrivalDelay: TimeInterval? = nil
        var toStop: String? = nil
        var live: Bool
        var asOf: Date
    }

    /// The update for a leg of a newer answer (Fastest trip's): its delays, live or not.
    static func update(_ l: Leg, asOf: Date) -> Update {
        Update(tripId: l.tripId, departureDelay: l.departure.timeIntervalSince(l.scheduledDeparture),
               arrivalDelay: l.arrival.timeIntervalSince(l.scheduledArrival), toStop: l.toStop, live: l.live, asOf: asOf)
    }

    /// The update a stop's board gives (`/v6/stoptimes`): the departure there.
    static func update(board tripId: String, time: Date, scheduled: Date, live: Bool, asOf: Date) -> Update {
        Update(tripId: tripId, departureDelay: time.timeIntervalSince(scheduled), live: live, asOf: asOf)
    }

    /// The newest update per trip (only live ones: a timetable answer never overrides live times).
    static func merge(_ a: [String: Update], _ more: [Update]) -> [String: Update] {
        var out = a
        for u in more where u.live {
            if let old = out[u.tripId], old.asOf >= u.asOf { continue }
            out[u.tripId] = u
        }
        return out
    }

    /// A leg with a newer update (`answered`: when the leg's own answer came; only a later update counts). The
    /// departure is its timetable time plus the update's delay; the arrival the same at the update's stop, else moved
    /// as much as the departure moved (never before it). The same update twice changes nothing more.
    static func apply(_ l: Leg, _ u: Update?, answered: Date?) -> Leg {
        guard let u, u.live, u.tripId == l.tripId else { return l }
        if let a = answered, u.asOf <= a { return l }
        var out = l
        out.departure = l.scheduledDeparture.addingTimeInterval(u.departureDelay)
        let ownDep: TimeInterval = l.departure.timeIntervalSince(l.scheduledDeparture)
        let ownArr: TimeInterval = l.arrival.timeIntervalSince(l.scheduledArrival)
        var arr: TimeInterval = ownArr + (u.departureDelay - ownDep)
        if let d = u.arrivalDelay, let s = u.toStop, !s.isEmpty, s == l.toStop { arr = d }
        let arrival: Date = l.scheduledArrival.addingTimeInterval(arr)
        out.arrival = max(arrival, out.departure)
        out.live = true
        return out
    }

    /// A whole way: its legs freshened, the time you leave your door and get there moved with its first and last leg.
    static func trip(start: Date, end: Date, legs: [Leg], updates: [String: Update], answered: Date?) -> (start: Date, end: Date, legs: [Leg]) {
        guard let first = legs.first, let last = legs.last else { return (start, end, legs) }
        let fresh: [Leg] = legs.map { apply($0, updates[$0.tripId], answered: answered) }
        let s: Date = start.addingTimeInterval(fresh[0].departure.timeIntervalSince(first.departure))
        let e: Date = end.addingTimeInterval(fresh[fresh.count - 1].arrival.timeIntervalSince(last.arrival))
        return (s, e, fresh)
    }

    /// How a departure is shown: its live time, the timetable's beside it (struck through) when they differ by a
    /// minute or more, and the word: "+3", "-1", "live" (on time by live times), "timetable", "cancelled".
    struct Shown: Equatable {
        let time: Date
        let planned: Date?
        let word: String
        let late: Bool
    }

    static func shown(departure: Date, scheduled: Date, live: Bool, cancelled: Bool) -> Shown {
        if cancelled { return Shown(time: scheduled, planned: nil, word: "cancelled", late: true) }
        if !live { return Shown(time: scheduled, planned: nil, word: "timetable", late: false) }
        let d: Int = Int((departure.timeIntervalSince(scheduled) / 60).rounded())
        if d == 0 { return Shown(time: departure, planned: nil, word: "live", late: false) }
        return Shown(time: departure, planned: scheduled, word: d > 0 ? "+\(d)" : "\(d)", late: true)
    }

    /// The one there first by live arrival (the same arrival: the fewer changes, then the one that leaves later).
    static func fastest(arrivals: [Date], changes: [Int], departures: [Date]) -> Int? {
        guard !arrivals.isEmpty, arrivals.count == changes.count, changes.count == departures.count else { return nil }
        return arrivals.indices.min { a, b in
            if arrivals[a] != arrivals[b] { return arrivals[a] < arrivals[b] }
            if changes[a] != changes[b] { return changes[a] < changes[b] }
            return departures[a] > departures[b]
        }
    }
}
