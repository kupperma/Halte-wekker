import Foundation

/// The NS station nearest a place, for "A train's time" (0.24): off the corridor, Plan by the time of a train between
/// the station nearest Home and the one nearest School.
enum NearestStation {
    /// A station further than this from Home or School isn't "yours": the option stays hidden.
    static let maxMetres = 5000.0

    /// The nearest station within `within` metres of a point, or nil.
    static func pick(_ p: GeoPoint, in stations: [NSStation], within: Double = maxMetres) -> NSStation? {
        var best: (NSStation, Double)?
        for s in stations {
            let d = Geo.metres(p, s.point)
            if d <= within, best.map({ d < $0.1 }) ?? true { best = (s, d) }
        }
        return best?.0
    }

    /// The two ends of "A train's time": the station nearest Home and the one nearest School. Nil (the option is hidden)
    /// when either has no station within 5 km, or both are the same station (no train between them).
    static func pair(home: GeoPoint, school: GeoPoint, in stations: [NSStation]) -> (home: NSStation, school: NSStation)? {
        guard let h = pick(home, in: stations), let s = pick(school, in: stations), h.code != s.code else { return nil }
        return (h, s)
    }
}

/// How Plan names the trip planned by a train's time and its pass. On the corridor these are the friend's train's
/// words to the letter ("Friend’s train", "arrive Breda", "the bus from Veghel"); off it, a train between the stations
/// nearest Home and School.
struct TrainTimeWords: Equatable, Sendable {
    /// The option's name: "Friend’s train", "A train’s time".
    var title: String
    /// The button that plans one: "Plan by your friend’s train".
    var planButton: String
    /// The tag on the train's row: "Friend’s", "Your train".
    var tag: String
    /// The station on the school's side: "Breda".
    var station: String
    /// The station on the home's side, when there is one (off the corridor).
    var homeStation: String?
    /// Home in the stops along the pass: "Veghel", "Home".
    var homeTown: String
    /// Your school: "BUas".
    var school: String

    static let legacy = TrainTimeWords(title: "Friend’s train", planButton: "Plan by your friend’s train", tag: "Friend’s",
                                       station: "Breda", homeStation: nil, homeTown: "Veghel", school: "BUas")

    /// The corridor's words (with its school's short name), or a train between two stations.
    static func make(corridor: Corridor?, school: String, homeStation: String?, schoolStation: String?) -> TrainTimeWords {
        if corridor != nil {
            var w = legacy
            w.school = school
            return w
        }
        return TrainTimeWords(title: "A train’s time", planButton: "Plan by a train’s time", tag: "Your train",
                              station: schoolStation ?? school, homeStation: homeStation, homeTown: "Home", school: school)
    }

    var onCorridor: Bool { homeStation == nil }

    /// "arrive Breda", "leave Breda" (lower case, after the day).
    func arriveLeave(out: Bool) -> String { out ? "arrive \(station)" : "leave \(station)" }
    /// The sheet's direction: "To Breda", "Home".
    var toStation: String { "To \(station)" }
    /// The sheet's time: "Arrive in Breda at", "Leave Breda at".
    func timeLabel(out: Bool) -> String { out ? "Arrive in \(station) at" : "Leave \(station) at" }
    /// The sheet's footer.
    func footer(out: Bool) -> String {
        if onCorridor {
            return "Use the time of your friend’s train. The app finds that train, \(out ? "the bus from \(homeTown) that gets you there in time and the bus to \(school) after it" : "the bus from \(school) to catch it and the bus to \(homeTown) after it")."
        }
        let h = homeStation ?? "your station"
        return "Use the time of a train between \(h) and \(station). The app finds that train, \(out ? "the bus or tram from home that gets you there in time and the one to \(school) after it" : "the bus or tram from \(school) to catch it and the one home after it")."
    }
    /// "No train arrives in Breda at exactly 08:21. This is the closest one."
    func inexact(out: Bool, time: String) -> String {
        "No train \(out ? "arrives in" : "leaves") \(station) at exactly \(time). This is the closest one."
    }
}
