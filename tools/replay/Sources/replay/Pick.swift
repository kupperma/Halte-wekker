import Foundation

// 0.38: per leg, the moment you left the stop you got on at (`DepartMatch.moment`, with the app's own `PickRules.swift`)
// and which of the vehicles around then left that stop at that moment by their live times (`DepartMatch.clue`); the
// one it would pick (`DepartMatch.pick`) should be the one you were on. (An export has no vehicle GPS of that moment:
// by their times only, so only vehicles with live times in the vehicles file say anything.)

struct DepartLook: Codable, Equatable {
    var stood: Double               // s you stood
    var after: Double               // s into the leg you left
    var leftThen: [String]          // the ones that left that stop then (labels)
    var picked: String?             // the one it would pick
    var wrong: Bool                 // …and that's not the one you were on
}

enum DepartReplay {
    /// s of a leg looked at for getting on.
    static let boarding: TimeInterval = 300

    static func of(_ leg: ReplayLeg, tracks: [VehicleTrack]) -> DepartLook? {
        let fixes: [Fix] = leg.fixes.map(\.fix).sorted { $0.t < $1.t }.filter { $0.t <= leg.start.addingTimeInterval(boarding) }
        guard fixes.count >= 3 else { return nil }
        // the first moment it finds, as the fixes come in
        var found: Departure?
        for k in 3...fixes.count {
            if let d = DepartMatch.moment(Array(fixes.prefix(k))) { found = d; break }
        }
        guard let d = found else { return nil }
        let around: [VehicleTrack] = tracks.filter { v in
            v.pieces.contains { $0.arrival >= d.t.addingTimeInterval(-150) && $0.departure <= d.t.addingTimeInterval(150) }
        }
        let clues: [DepartClue] = around.map { DepartMatch.clue($0, at: d) }.filter { $0.offBy != nil || $0.elsewhere }
        let lines: [String: String] = Dictionary(around.map { ($0.tripId, $0.line) }, uniquingKeysWith: { a, _ in a })
        let left: [String] = clues.filter(DepartMatch.leftThen).map { FieldFormat.label($0.id, lines) }
        let pick: String? = DepartMatch.pick(clues, ids: clues.map(\.id)).map { FieldFormat.label($0, lines) }
        let wrong: Bool = pick != nil && leg.truth != nil && pick != leg.truth
        return DepartLook(stood: d.stood, after: d.t.timeIntervalSince(leg.start), leftThen: left, picked: pick, wrong: wrong)
    }

    static func words(_ l: DepartLook) -> String {
        var s = "depart: stood \(Int(l.stood.rounded())) s, left \(Int(l.after.rounded())) s into the leg"
        s += l.leftThen.isEmpty ? " · none left then by its times" : " · left then: \(l.leftThen.joined(separator: ", "))"
        if let p = l.picked { s += " · it picks \(p)" }
        if l.wrong { s += " (WRONG: not the one you were on)" }
        return s
    }
}
