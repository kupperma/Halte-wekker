import Foundation

/// "From <stop>" (0.40): the next departures from the stop you get on at, in a trip's detail. "It only clearly shows
/// the next bus, not the upcoming buses. When you click on a trip, show: this is the stop you're going to, these are
/// all the buses coming at this and this time." The lines that get you there first (up to `maxUseful`), then, smaller,
/// the other lines (up to `maxOther`); each with its time, how late or "live", its platform or stand; one you can't be
/// at the stop for any more greyed. Tap one of the lines that gets you there and the trip switches to it.
/// The ghost rules (`GhostDepartures`) go first: each journey once, no cancelled ones, "may not run" ranked lower.
/// Plain values, so the rules are tested. Foundation only.
enum FromStop {
    static let maxUseful = 6
    static let maxOther = 3
    /// s: one that leaves this little before you can be at the stop still counts as one you make (you hurry).
    static let slack: TimeInterval = 30

    struct Dep: Equatable, Sendable {
        var id: String
        var tripId: String
        var line: String
        var headsign: String
        var time: Date              // live, else the timetable's
        var scheduled: Date
        var live: Bool
        var cancelled: Bool
        var platform: String?
        var train: Bool
        var stop: String            // the stop's name
        var vehicle: Bool = false
    }

    struct Row: Equatable, Sendable, Identifiable {
        let dep: Dep
        let status: GhostDepartures.Status
        let useful: Bool            // one of the lines that gets you there
        let current: Bool           // the one your trip takes now
        let reachable: Bool         // you can be at the stop before it leaves
        var id: String { dep.id }
        /// Greyed: you can't be there for it, or (another line) it doesn't get you there.
        var dimmed: Bool { !reachable }
        /// May you switch the trip to it: a line that gets you there, you make it, and it isn't the one already.
        var switchable: Bool { useful && reachable && !current }
        /// "+3", "live", nil (timetable).
        var late: String? {
            guard dep.live else { return nil }
            let m = Int((dep.time.timeIntervalSince(dep.scheduled) / 60).rounded())
            if m >= 1 { return "+\(m)" }
            if m <= -1 { return "\(m)" }
            return "live"
        }
    }

    struct Board: Equatable, Sendable {
        let useful: [Row]
        let other: [Row]
        var isEmpty: Bool { useful.isEmpty && other.isEmpty }
    }

    /// The rows. `usefulLines`: the lines that get you there from here (your trip's and the other ways'); `current`: the
    /// trip id of the ride your trip takes now; `atStop`: when you can be at the stop (now when you're there);
    /// `alsoLive`: lines seen live today (for the ghost rule).
    static func board(_ deps: [Dep], usefulLines: Set<String>, current: String?, atStop: Date, now: Date,
                      alsoLive: Set<String> = []) -> Board {
        let ghost: [GhostDepartures.Dep] = deps.map { d in
            GhostDepartures.Dep(id: d.id, tripId: d.tripId, line: d.line, headsign: d.headsign, stop: d.stop, time: d.time,
                                scheduled: d.scheduled, live: d.live, cancelled: d.cancelled, vehicle: d.vehicle)
        }
        let byId: [String: Dep] = Dictionary(deps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted: Set<String> = Set(usefulLines.map(GhostDepartures.normalized))
        var useful: [Row] = [], other: [Row] = []
        for r in GhostDepartures.clean(ghost, now: now, alsoLive: alsoLive) {
            guard let d = byId[r.dep.id] else { continue }
            // (gone: it left a minute ago or more)
            guard d.time.timeIntervalSince(now) > -60 else { continue }
            let isCurrent: Bool = current.map { !$0.isEmpty && $0 == d.tripId } ?? false
            let isUseful: Bool = isCurrent || wanted.contains(GhostDepartures.normalized(d.line))
            let reach: Bool = d.time.addingTimeInterval(slack) >= atStop
            let row = Row(dep: d, status: r.status, useful: isUseful, current: isCurrent, reachable: reach)
            if isUseful { useful.append(row) } else { other.append(row) }
        }
        // the one your trip takes is always there, even past the first `maxUseful`
        var shown: [Row] = Array(useful.prefix(maxUseful))
        if let c = useful.first(where: \.current), !shown.contains(where: { $0.id == c.id }) {
            shown = Array(shown.prefix(maxUseful - 1)) + [c]
        }
        return Board(useful: shown, other: Array(other.prefix(maxOther)))
    }

    /// The departure's time as it's said: "17:42" (`clock`), "in 4 min" under the hour.
    static func countdown(_ d: Dep, now: Date) -> String? {
        let m = Int((d.time.timeIntervalSince(now) / 60).rounded(.down))
        if m < 1 { return "now" }
        return m < 60 ? "in \(m) min" : nil
    }

    /// "Stand B", "Platform 5", nil.
    static func place(_ d: Dep) -> String? {
        guard let p = d.platform?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        return d.train ? "Platform \(p)" : "Stand \(p)"
    }
}
