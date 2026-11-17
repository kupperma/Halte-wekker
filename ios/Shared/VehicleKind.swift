import Foundation

/// The kind of vehicle the Live Activity draws on its track and shows as a glyph: a bus, an intercity, a sprinter, a
/// tram, a metro, or a train it can't tell more about. Its raw value is what `TripAttributes.ContentState.vehicle` holds.
enum VehicleKind: String, CaseIterable {
    case bus, ic, sprinter, tram, metro, train

    /// The kind from a leg's mode, as the live data or the planner names it ("BUS", "RAIL", "TRAM", "SUBWAY"…; "" not
    /// known), and its line ("IC", "SPR", "Intercity", "306"…). With neither saying more: a train or a bus by `isTrain`.
    static func of(mode: String, line: String, isTrain: Bool) -> VehicleKind {
        let m = mode.uppercased()
        if m.contains("TRAM") { return .tram }
        if m.contains("SUBWAY") || m.contains("METRO") { return .metro }
        if m.contains("BUS") || m.contains("COACH") { return .bus }
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let k = railKind(l) { return k }
        if m.contains("HIGHSPEED") || m.contains("LONG_DISTANCE") { return .ic }
        if m.isEmpty, !isTrain { return .bus }
        return .train
    }

    /// An intercity or a sprinter, by the line's name; nil when the name doesn't say.
    private static func railKind(_ l: String) -> VehicleKind? {
        guard !l.isEmpty else { return nil }
        let words = l.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let first = words.first ?? l
        // sprinters and stopping trains
        if first == "SPR" || l.contains("SPRINTER") || l.hasPrefix("STOP") || first == "ST" { return .sprinter }
        // intercity and the long-distance trains like it
        if ["IC", "ICE", "ICD", "ICNG", "ICM", "ICR", "EC", "ECE", "EN", "EST", "NJ", "TGV", "THA", "RJ", "RJX"].contains(first) { return .ic }
        if first.hasPrefix("IC") && first.count <= 4 && !first.contains(where: \.isNumber) { return .ic }
        if l.contains("INTERCITY") || l.contains("EURO") || l.contains("NIGHTJET") || l.contains("THALYS") { return .ic }
        return nil
    }

    /// The value stored in the state back to a kind; "" or unknown (a state from before 0.20.4): a train or a bus.
    static func stored(_ raw: String, isTrain: Bool) -> VehicleKind {
        VehicleKind(rawValue: raw) ?? (isTrain ? .train : .bus)
    }

    var isRail: Bool { self != .bus }

    /// Its short name, for a pill with no line ("IC", "SPR"…).
    var short: String {
        switch self {
        case .bus: return "Bus"
        case .ic: return "IC"
        case .sprinter: return "SPR"
        case .tram: return "Tram"
        case .metro: return "Metro"
        case .train: return "Train"
        }
    }

    /// What its pill says: a bus's, tram's or metro's line when it's short ("5", "306"); an intercity's own code
    /// ("IC", "ICE", "ICD"); "SPR" for a sprinter; else the kind's short name.
    static func pillText(line: String, kind: VehicleKind) -> String {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .sprinter: return "SPR"
        case .ic:
            let u = l.uppercased()
            return !u.isEmpty && u.count <= 4 && u.allSatisfy(\.isLetter) && !u.hasPrefix("EURO") ? u : "IC"
        case .train: return !l.isEmpty && l.count <= 4 ? l.uppercased() : kind.short
        case .bus, .tram, .metro: return !l.isEmpty && l.count <= 4 ? l : kind.short
        }
    }
}
