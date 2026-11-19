import Foundation

/// Tapping the home map (0.20.1): a stop or a station opens its departures, a bus or train its live sheet; and the map
/// that pans and zooms freely, out to the whole globe. Plain values, so they're tested.
enum MapTap {
    // MARK: the camera after a tap

    /// The span (degrees of latitude) to show a tapped thing at: the zoom you were at, but not further out than a town
    /// or further in than a few streets, so it is clearly there.
    static let minSpan = 0.004
    static let maxSpan = 0.03
    static func span(current: Double?) -> Double {
        guard let c = current, c.isFinite, c > 0 else { return 0.012 }
        return min(maxSpan, max(minSpan, c))
    }

    /// The camera's middle so the tapped thing sits in the upper part of the map, above the sheet that opens over the
    /// lower half: the middle moved south by `above` of the span.
    static func centre(item: GeoPoint, latDelta: Double, above: Double = 0.22) -> GeoPoint {
        GeoPoint(lat: max(-85, min(85, item.lat - latDelta * above)), lon: item.lon)
    }

    // MARK: a free map

    /// A camera region the stops and vehicles may look at: finite, a real span, on the earth. (Zoomed out to the globe
    /// the region can come back odd; then nothing is asked for: their own zoom gating does the rest.)
    static func usable(centerLat: Double, centerLon: Double, latDelta: Double, lonDelta: Double) -> Bool {
        guard centerLat.isFinite, centerLon.isFinite, latDelta.isFinite, lonDelta.isFinite else { return false }
        guard latDelta > 0, lonDelta > 0, latDelta <= 180, lonDelta <= 360 else { return false }
        return abs(centerLat) <= 90 && abs(centerLon) <= 540
    }

    // MARK: the stop's sheet

    /// The ids a board can be asked for: real stop ids, not a "lat,lon" (a saved stop without one), each once.
    static func boardIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            let t = id.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !isCoordinate(t) else { return false }
            return seen.insert(t).inserted
        }
    }

    static func isCoordinate(_ s: String) -> Bool {
        let p = s.split(separator: ",", omittingEmptySubsequences: false)
        return p.count == 2 && p.allSatisfy { Double($0.trimmingCharacters(in: .whitespaces)) != nil }
    }

    /// "350 m away · 4 min walk", "2.4 km away" (nil: where you are isn't known).
    static func awayText(metres: Double?) -> String? {
        guard let m = metres, m.isFinite, m >= 0 else { return nil }
        let d: String
        if m < 1000 { d = "\(max(0, Int((m / 10).rounded()) * 10)) m" }
        else if m < 100_000 { d = String(format: "%.1f km", m / 1000) }
        else { d = "\(Int((m / 1000).rounded())) km" }
        if m <= 1500, let w = DepartureGroups.walkText(metres: m) { return "\(d) away · \(w)" }
        return "\(d) away"
    }

    // MARK: the vehicle's sheet

    /// The trip of yours this bus or train is the first ride of, if you could be on it: only with no trip running and
    /// your next trips worked out from where you are now (not a saved answer). The index into those trips.
    /// And only a bus or train near you (`metresFromYou`, within `nearYou`): you can't be on one across town.
    static let nearYou = 1500.0
    static func couldBeOn(vehicleTrip: String, firstRides: [String], fresh: Bool, idle: Bool, metresFromYou: Double?) -> Int? {
        guard idle, fresh, !vehicleTrip.isEmpty, let m = metresFromYou, m.isFinite, m <= nearYou else { return nil }
        return firstRides.firstIndex(of: vehicleTrip)
    }

    /// m (0.26.2): a bus this near your fresh fix while you move like one could be carrying you (a train: its marker
    /// lags more, at its speed).
    static let carryingBus = 300.0
    static let carryingTrain = 600.0
    static let freshFix: TimeInterval = 60

    /// "I'm on this one" for a bus or train that isn't the first ride of any of your next trips (0.26.2): on 2026-11-19
    /// on an Intercity, the home's trips were planned from the spot (an SPR from Eindhoven), so the Intercity at your
    /// own position offered nothing. With no trip running: the one the home found you on (`onBoardTrip`); or, while
    /// you move like a bus or train (`moving`), one within `carryingBus`/`carryingTrain` of your fix of the last minute.
    /// The trip then starts from on board, planned on from it.
    static func couldBeCarrying(vehicleTrip: String, isTrain: Bool, idle: Bool, onBoardTrip: String?, moving: Bool,
                                metresFromYou: Double?, fixAge: TimeInterval?) -> Bool {
        guard idle, !vehicleTrip.isEmpty else { return false }
        if onBoardTrip == vehicleTrip { return true }
        guard moving, let a = fixAge, a >= 0, a <= freshFix, let m = metresFromYou, m.isFinite, m >= 0 else { return false }
        return m <= (isTrain ? carryingTrain : carryingBus)
    }

    /// The stops still to come to list under its next one: after `next`, at most `limit` (none once it's done).
    static func ahead(next: Int, count: Int, done: Bool, limit: Int = 4) -> Range<Int> {
        guard !done, count > 0, next >= 0, next + 1 < count else { return 0..<0 }
        return (next + 1)..<min(count, next + 1 + limit)
    }

    /// "+3 min", "2 min early", "on time" for a stop's printed time against its timetable (nil: no timetable time).
    static func delayText(at: Date?, scheduled: Date?) -> String? {
        guard let a = at, let s = scheduled else { return nil }
        let m = Int((a.timeIntervalSince(s) / 60).rounded())
        if m >= 1 { return "+\(m) min" }
        if m <= -1 { return "\(-m) min early" }
        return "on time"
    }

    // MARK: wake me at a stop

    /// The wake distance one step on (`by` ±0.5 km), within today's bounds: 0.5 km to 10 (a bus) or 15 (a train).
    static func wakeKm(_ km: Double, by: Double, bus: Bool) -> Double {
        let hi = bus ? 10.0 : 15.0
        let v = ((km + by) * 2).rounded() / 2
        return min(hi, max(0.5, v))
    }
}

/// Follow me on the home map (0.20.1): the button toggles between following you and a free map; any pan or zoom by hand
/// makes it free; nothing else turns following back on. MapKit doesn't always report a hand move through the camera
/// binding, so the camera's own end-of-move is checked too.
enum MapFollow {
    /// After the follow button, the camera flies to you: its moves in this time are its own, not a hand.
    static let settle: TimeInterval = 1.5

    /// Did a hand move the map while it was following you? `centreToUser`: how far the map's middle ended from you
    /// (nil: where you are isn't known freshly); `viewMetres`: the height of what the map shows; `span` and
    /// `baseline`: its latitude span now and when following settled (nil: not yet).
    static func handMoved(following: Bool, settling: Bool, centreToUser: Double?, viewMetres: Double, span: Double, baseline: Double?) -> Bool {
        guard following, !settling else { return false }
        if let d = centreToUser, d.isFinite, d > max(80, viewMetres * 0.2) { return true }        // panned away
        if let b = baseline, b > 0, span.isFinite, span > 0, abs(span / b - 1) > 0.2 { return true }  // zoomed
        return false
    }

    /// A map that keeps something in view by itself (Fastest trip's): a camera move ending more than `fitSettle` after
    /// its last fit is a hand's. (Before the first fit, the map's own first look: not a hand.)
    static let fitSettle: TimeInterval = 1.8
    static func handMovedSinceFit(lastFit: Date?, now: Date) -> Bool {
        guard let f = lastFit else { return false }
        return now.timeIntervalSince(f) > fitSettle
    }
}
