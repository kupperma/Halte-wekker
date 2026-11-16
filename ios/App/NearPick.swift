import Foundation

/// Which stops near you get a board: the nearest stop of each of the two nearest bus-stop names, and the nearest
/// station. Transitous answers a stop's board with every stop of a similar name too (all its platforms, both sides of
/// the road), so one stop per name has all their departures; a bus station's 15 platforms asked one by one were the
/// same board 15 times over. Plain values, so it can be tested without CoreLocation.
enum NearPick {
    /// `stops` nearest first.
    static func onePerName<S>(_ stops: [S], name: (S) -> String, rail: (S) -> Bool, names: Int = 2) -> [S] {
        var picked: [String] = [], out: [S] = []
        for s in stops where !rail(s) && !picked.contains(name(s)) && picked.count < names {
            picked.append(name(s))
            out.append(s)
        }
        return out + (stops.first(where: rail).map { [$0] } ?? [])
    }

    /// A saved board that was asked of more stops than are kept now: the kept stop each saved stop's rows go with (the
    /// one of its name), so the rows still show under their name.
    static func keptStop(_ stops: [(id: String, name: String)], kept: [(id: String, name: String)]) -> [String: String] {
        var byName: [String: String] = [:]
        for k in kept where byName[k.name] == nil { byName[k.name] = k.id }
        var out: [String: String] = [:]
        for s in stops { if let k = byName[s.name] { out[s.id] = k } }
        return out
    }
}
