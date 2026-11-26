import Foundation

/// 0.42.3: when the next ride of a change is called missed, and what is offered instead. From a field log of 27
/// November (the tests use synthetic data shaped like it):
/// - at a change onto a city bus with no live time and no GPS of its own, "You’ll miss the 08:12" came 78 s after its
///   timetable time and was taken back two minutes later; the bus came and was made;
/// - on the bus to the station (the first leg), "You’ll miss the 17:52" came while that bus's own data was stale and
///   the train was made;
/// - the one offered instead was a later bus of the line you were on, from where you got on, not from the change.
/// So: at the change, a ride without live time or GPS is "should be leaving now — look out for it" until its time and
/// 3 minutes have gone by and you're away from its stop; on the way, a miss needs fresh data of the ride you're on and
/// more than a minute short; a miss is only told once it held for a minute (`step`); and an alternative must leave from
/// the change (`sane`). Plain values, so it can be tested.
enum MissCall {
    /// min: on the way, short of the room you need by more than this before it's missed (less: tight).
    static let margin: Double = 1
    /// s: the ride you're on says when you're in, with its own GPS this new…
    static let gpsFresh: TimeInterval = 90
    /// s: …or its live times asked this recently.
    static let liveFresh: TimeInterval = 120
    /// s: a next ride with neither a live time nor GPS of its own isn't missed before its time and this much.
    static let unsure: TimeInterval = 180
    /// m: you this near its stop would see it come: a ride without live time or GPS isn't missed then.
    static let nearStop: Double = 150
    /// s: a miss is told only once it has held this long (a look later still says so).
    static let hold: TimeInterval = 60
    /// m: a ride instead leaves from this near the change (the next leg's stop, or where you get off).
    static let changeRadius: Double = 500
    /// m: its own fresh GPS this far past the stop has it gone.
    static let goneSlack: Double = 150

    /// What the change guide says of the planned next ride.
    enum Call: Equatable, Sendable {
        case fine
        /// Under the room you need, but not surely missed: "tight — run".
        case tight
        /// About its time, nothing live to go by: "should be leaving now — look out for it".
        case lookOut
        /// It may have gone (or the miss hasn't held for a minute yet): said quietly, not told.
        case maybe
        case missed
    }

    /// What the next ride's own GPS says.
    enum Seen: Equatable, Sendable {
        case none           // no fresh fix, or none that places it on its road
        case notLeft        // at your stop or still before it (`MissRule.notLeft`)
        case gone           // well past your stop
    }

    /// What is known of the next ride at the change.
    struct Next: Equatable, Sendable {
        /// Its departure is a live one (else the timetable's).
        var live: Bool
        var seen: Seen
        /// How far you are from its stop (nil: not known).
        var youMetres: Double?

        init(live: Bool = true, seen: Seen = .none, youMetres: Double? = nil) {
            self.live = live
            self.seen = seen
            self.youMetres = youMetres
        }
    }

    /// The ride you're on (on the way) or got off (at the change): never offered as the one instead.
    struct Feeding: Equatable, Sendable {
        var tripId: String?
        var line: String
        var isTrain: Bool

        init(tripId: String?, line: String, isTrain: Bool) {
            self.tripId = tripId
            self.line = line
            self.isTrain = isTrain
        }
    }

    /// The next ride's own GPS: `vehicleMetres` where its fix puts it along its road, `stopMetres` your stop along it,
    /// `fixAge` how old the fix is.
    static func seen(vehicleMetres: Double?, stopMetres: Double?, fixAge: TimeInterval?) -> Seen {
        if MissRule.notLeft(vehicleMetres: vehicleMetres, stopMetres: stopMetres, fixAge: fixAge) { return .notLeft }
        guard let v = vehicleMetres, let s = stopMetres, let a = fixAge, v.isFinite, s.isFinite, a.isFinite else { return .none }
        guard a >= -60, a <= gpsFresh else { return .none }
        return v > s + goneSlack ? .gone : .none
    }

    /// The ride you're on has fresh data on when you're in: its own GPS at most `gpsFresh` old, or its live times
    /// asked at most `liveFresh` ago (nil: none).
    static func fresh(gpsAge: TimeInterval?, liveAge: TimeInterval?) -> Bool {
        if let g = gpsAge, g.isFinite, g >= -60, g <= gpsFresh { return true }
        if let l = liveAge, l.isFinite, l >= -60, l <= liveFresh { return true }
        return false
    }

    /// On the way (still on the ride into the change): your arrival (live or by GPS) plus the room you `need`
    /// (minutes) against its live departure. Short by more than `margin` with fresh data: missed; short otherwise:
    /// tight.
    static func onTheWay(arrive: Date, departure: Date, need: Double, now: Date, fresh: Bool) -> Call {
        let from: Date = max(arrive, now)
        let room: Double = departure.timeIntervalSince(from) / 60
        let short: Double = need - room
        if short <= 0 { return .fine }
        if short > margin && fresh { return .missed }
        return .tight
    }

    /// At the change: its own GPS first (at or before the stop: coming; well past it within a minute of its time or
    /// later: gone). Without GPS and without a live time: "look out for it" from its time until 3 minutes after, and
    /// as long as you're near its stop; missed only after that. With a live time: a minute's grace, then "maybe" for
    /// up to 3 minutes ("look out for it" near its stop), then missed.
    static func atChange(departure: Date, next: Next, now: Date) -> Call {
        let past: TimeInterval = now.timeIntervalSince(departure)
        switch next.seen {
        case .notLeft:
            return .fine
        case .gone:
            if past > -MissRule.grace { return .missed }
        case .none:
            break
        }
        let near: Bool = (next.youMetres ?? .infinity) <= nearStop
        if !next.live {
            if past < 0 { return .fine }
            if past <= unsure || near { return .lookOut }
            return .missed
        }
        if past <= MissRule.grace { return .fine }
        if past <= unsure { return near ? .lookOut : .maybe }
        return .missed
    }

    /// What a miss has held so far, for one change's planned ride (`key`).
    struct Hold: Equatable, Sendable {
        var key: String?
        var since: Date?
        var told: Bool

        init(key: String? = nil, since: Date? = nil, told: Bool = false) {
            self.key = key
            self.since = since
            self.told = told
        }
    }

    /// One look's call through the hold: a miss is told (`missed`) only once looks have said so for `hold` seconds
    /// (meanwhile `maybe`); once told it stays until a look says otherwise (`retract`: a miss told is taken back).
    static func step(_ h: Hold, call: Call, key: String, now: Date) -> (hold: Hold, call: Call, retract: Bool) {
        var n: Hold = h.key == key ? h : Hold(key: key)
        guard call == .missed else {
            let retract: Bool = n.told
            n.since = nil
            n.told = false
            return (n, call, retract)
        }
        let since: Date = n.since ?? now
        n.since = since
        if n.told || now.timeIntervalSince(since) >= hold {
            n.told = true
            return (n, .missed, false)
        }
        return (n, .maybe, false)
    }

    /// The rides that may be offered instead: not the ride you're on or got off (`feeding`, by trip, and by its line
    /// unless the next leg is on that line too), and, where it's known where they leave from, from the change
    /// (`changeAt`: within `changeRadius` of one of its points).
    static func sane(_ later: [ChangeGuide.Ride], planned: ChangeGuide.Ride, feeding: Feeding?, changeAt: [GeoPoint]) -> [ChangeGuide.Ride] {
        later.filter { r in
            if let f = feeding {
                if let id = f.tripId, !id.isEmpty, r.tripId == id { return false }
                let sameAsFeeding: Bool = r.line == f.line && r.isTrain == f.isTrain
                let plannedSame: Bool = planned.line == f.line && planned.isTrain == f.isTrain
                if sameAsFeeding && !plannedSame { return false }
            }
            if let p = r.from, !changeAt.isEmpty {
                let near: Bool = changeAt.contains { Geo.metres($0, p) <= changeRadius }
                if !near { return false }
            }
            return true
        }
    }
}
