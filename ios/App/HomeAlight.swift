import Foundation

// 0.42.10: from a ride screen at 16:01 ("Leg 2 of 2 · Bus 306 to Veghel · 2 min to Veghel · there at 16:03 · Stops
// ahead: Veghel your stop"): "It says I should just get off at Veghel and not at which stop; and the stop I'm actually
// getting off at is at 16:07". The stop is named in full, and on the way to Home you get off at your own home stop
// (from the setup) when the bus or train calls there, not the planner's first stop in town. Plain rules (Foundation
// only), tested in `HomeAlightTests`; Android has the same (`data/HomeAlight.kt`, `HomeAlightTest`).
enum HomeAlight {
    /// One call of the ride's trip.
    struct Call: Equatable {
        var id: String
        var name: String
        var point: GeoPoint
        var arrival: Date?
    }

    /// One of your own stops (the setup's home stops): by id, or within 60 m of where it is.
    struct Own: Equatable {
        var id: String
        var point: GeoPoint?
    }

    static let sameStop: Double = 60
    static let streets: Double = 1.3

    /// The stop's full name ("Veghel, Busstation", not "Veghel").
    static func fullName(_ n: String) -> String { n.trimmingCharacters(in: .whitespaces) }

    /// Minutes to walk from a stop to the place, at `speed` (whole minutes up, at least one).
    static func walkMinutes(_ a: GeoPoint, _ b: GeoPoint, speed: Double) -> Int {
        let m: Double = Geo.metres(a, b) * streets
        return max(1, Int((m / max(0.3, speed) / 60).rounded(.up)))
    }

    static func isOwn(_ c: Call, _ own: [Own]) -> Bool {
        own.contains { o in
            if !o.id.isEmpty && o.id == c.id { return true }
            guard let p = o.point else { return false }
            return Geo.metres(p, c.point) <= sameStop
        }
    }

    /// Where to get off instead of the planner's `plannerTo`: of the calls after you got on (`from`), your own stops
    /// with a time, the one with the shortest walk to the place (the earlier on a tie). Nil: none of them is called at,
    /// or the planner's stop is that one already.
    static func pick(calls: [Call], from: Int, plannerTo: Int, own: [Own], place: GeoPoint, speed: Double) -> Int? {
        guard !own.isEmpty, from >= 0, from < calls.count else { return nil }
        var best: (i: Int, walk: Int)? = nil
        for i in (from + 1)..<max(from + 1, calls.count) {
            let c = calls[i]
            guard c.arrival != nil, isOwn(c, own) else { continue }
            let w = walkMinutes(c.point, place, speed: speed)
            if best == nil || w < best!.walk { best = (i, w) }
        }
        guard let b = best, b.i != plannerTo else { return nil }
        if plannerTo >= 0, plannerTo < calls.count, isOwn(calls[plannerTo], own),
           walkMinutes(calls[plannerTo].point, place, speed: speed) <= b.walk { return nil }
        return b.i
    }

    /// The call a ride's stop is: by id, else the one nearest to its spot (within 150 m), after `after`.
    static func index(of id: String, point: GeoPoint?, in calls: [Call], after: Int = -1) -> Int? {
        let range = calls.indices.filter { $0 > after }
        if !id.isEmpty, let i = range.first(where: { calls[$0].id == id }) { return i }
        guard let p = point else { return nil }
        let near = range.min { Geo.metres(calls[$0].point, p) < Geo.metres(calls[$1].point, p) }
        return near.flatMap { Geo.metres(calls[$0].point, p) <= 150 ? $0 : nil }
    }
}
