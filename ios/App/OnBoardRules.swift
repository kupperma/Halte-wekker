import Foundation

/// The home's "you're on bus …" look (0.26.1). On 2026-11-19, walking at a change in Den Bosch, it picked buses by
/// their timetable alone: "9·8406 timetable 6 s" over "305·7821 gps 14 s", then "15·9583 timetable 15 s". A
/// timetable-only fit says only that a bus's times pass near your track; at walking speed many do.
enum OnBoardRules {
    /// m/s: moving like a bus or train (as `VehicleMatch.planFromSpot`).
    static let vehicleSpeed = 8.0

    /// Timetable-only: no live times and not judged by its own GPS.
    static func timetableOnly(_ j: Judgement) -> Bool { !j.realTime && j.evidence?.gps != true }

    /// The one you're on, of those that passed (cheapest first, as `VehicleMatch.rank`), or nil:
    /// - when one passed by its own GPS, a timetable-only one never comes before it (they're left out);
    /// - a timetable-only best counts only while you move like a vehicle (`vehicleSpeed`): your speed along its path
    ///   (or, with one fix, `yourSpeed`, the GPS's own).
    static func best(_ judged: [Judgement], yourSpeed: Double) -> String? {
        let byId = Dictionary(judged.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ranked: [Ranked] = VehicleMatch.rank(judged, planned: nil)
        let anyGPS: Bool = judged.contains { VehicleMatch.passedByGPS($0) }
        if anyGPS { ranked = ranked.filter { r in byId[r.id].map { !timetableOnly($0) } ?? false } }
        guard let first = ranked.first, let j = byId[first.id] else { return nil }
        if timetableOnly(j) {
            let along: Double = j.evidence.map { $0.fixes > 1 ? $0.yourSpeed : max($0.yourSpeed, yourSpeed) } ?? yourSpeed
            guard along.isFinite, along >= vehicleSpeed else { return nil }
        }
        return first.id
    }

    /// The home may start a trip on the bus or train it found you on: no trip on (a running one is never restarted,
    /// least of all on the same one), and not one a trip already started on by itself or that you ended a ride on.
    static func mayAutoStart(_ tripId: String, idle: Bool, running: String?, blocked: Set<String>) -> Bool {
        idle && running != tripId && !blocked.contains(tripId)
    }
}
