import Foundation

/// Ghost departures (0.40). In Schijndel one evening the boards were a mess: a bus showed coming in half an hour and
/// then simply never came. What the departure lists and the trip options do with a departure, before they show it:
/// - the same journey from two sources (two feeds, two ids for one stop) is shown once (the live one);
/// - a cancelled one isn't shown;
/// - for a line that normally has live data (seen live today, or live elsewhere in the same list), one with no live
///   data and no vehicle seen within `unsureWithin` of leaving is marked "no live info · may not run", and ranks
///   below the live ones;
/// - once it's past its time with no sign of it, it goes.
/// Plain values, so the rules are tested. Foundation only.
enum GhostDepartures {
    /// Within this of leaving, a line that normally has live data should have it.
    static let unsureWithin: TimeInterval = 15 * 60
    /// This long past its time with no sign of it (no live data, no vehicle), it's gone.
    static let goneAfter: TimeInterval = 60
    /// An unsure one sorts as if it left this much later (below the live ones around its time).
    static let unsurePenalty: TimeInterval = 10 * 60

    static let unsureText = "No live info · may not run"
    static let unsureShort = "may not run"

    struct Dep: Equatable, Sendable {
        var id: String              // the row's own id (unique in the list)
        var tripId: String
        var line: String
        var headsign: String
        var stop: String            // its stop: the name (or the id when it has none)
        var time: Date              // live, else the timetable's
        var scheduled: Date
        var live: Bool
        var cancelled: Bool
        var vehicle: Bool = false   // a vehicle was seen for it (its GPS)
    }

    enum Status: String, Equatable, Sendable {
        case live           // live data
        case timetable      // the timetable's, as usual for it (no live data expected yet, or this line never has it)
        case unsure         // a line that has live data, close to leaving, and none for this one: may not run
    }

    struct Row: Equatable, Sendable {
        let dep: Dep
        let status: Status
    }

    /// Lower case, letters and digits only ("'s-Hertogenbosch, Centraal" → "shertogenboschcentraal").
    static func normalized(_ s: String) -> String {
        var out = ""
        for u in s.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(u) { out.unicodeScalars.append(u) }
        return out
    }

    /// Two headsigns for the same journey: equal, one empty, or one the start of the other ("Veghel" and "Veghel
    /// Busstation").
    static func sameHeadsign(_ a: String, _ b: String) -> Bool {
        let x = normalized(a), y = normalized(b)
        if x.isEmpty || y.isEmpty || x == y { return true }
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// The same journey twice: the same trip at the same stop, or the same line from the same stop at the same
    /// timetable minute toward the same place.
    static func same(_ a: Dep, _ b: Dep) -> Bool {
        let stopA = normalized(a.stop), stopB = normalized(b.stop)
        guard stopA == stopB else { return false }
        if !a.tripId.isEmpty && a.tripId == b.tripId { return true }
        guard normalized(a.line) == normalized(b.line) else { return false }
        let minuteA = Int((a.scheduled.timeIntervalSince1970 / 60).rounded(.down))
        let minuteB = Int((b.scheduled.timeIntervalSince1970 / 60).rounded(.down))
        guard minuteA == minuteB else { return false }
        return sameHeadsign(a.headsign, b.headsign)
    }

    /// Which of two copies to keep: the live one, then the one with a vehicle, then the one not cancelled.
    static func better(_ a: Dep, than b: Dep) -> Bool {
        if a.live != b.live { return a.live }
        if a.vehicle != b.vehicle { return a.vehicle }
        if a.cancelled != b.cancelled { return !a.cancelled }
        return false
    }

    /// Each journey once, where its first copy was in the list (the better copy kept).
    static func dedupe(_ deps: [Dep]) -> [Dep] {
        var out: [Dep] = []
        for d in deps {
            if let i = out.firstIndex(where: { same($0, d) }) {
                // (a copy says it's cancelled while the other runs live: the live one wins)
                if better(d, than: out[i]) { out[i] = d }
            } else {
                out.append(d)
            }
        }
        return out
    }

    /// The lines with live data in the list (normalized).
    static func liveLines(_ deps: [Dep]) -> Set<String> {
        Set(deps.filter { $0.live && !$0.cancelled }.map { normalized($0.line) })
    }

    /// How sure it is that it runs. `normallyLive`: its line normally has live data.
    static func status(live: Bool, vehicle: Bool, leaves: Date, normallyLive: Bool, now: Date) -> Status {
        if live || vehicle { return live ? .live : .timetable }
        guard normallyLive else { return .timetable }
        return leaves.timeIntervalSince(now) <= unsureWithin ? .unsure : .timetable
    }

    /// Past its time with no sign of it (no live data, no vehicle) on a line that normally has live data: gone.
    static func gone(live: Bool, vehicle: Bool, scheduled: Date, time: Date, normallyLive: Bool, now: Date) -> Bool {
        guard !live, !vehicle, normallyLive else { return false }
        return now.timeIntervalSince(max(scheduled, time)) > goneAfter
    }

    /// The time it sorts by: an unsure one `unsurePenalty` later.
    static func rankTime(_ r: Row) -> Date {
        r.status == .unsure ? r.dep.time.addingTimeInterval(unsurePenalty) : r.dep.time
    }

    /// The list as it's shown: each journey once, no cancelled ones, none gone without a sign, each with its status,
    /// by `rankTime` (ties in the order given). `alsoLive`: lines known to have live data today (seen live elsewhere).
    static func clean(_ deps: [Dep], now: Date, alsoLive: Set<String> = []) -> [Row] {
        let lines: Set<String> = liveLines(deps).union(alsoLive.map(normalized))
        let unique: [Dep] = dedupe(deps).filter { !$0.cancelled }
        var rows: [(offset: Int, row: Row)] = []
        for (k, d) in unique.enumerated() {
            let usual: Bool = lines.contains(normalized(d.line))
            if gone(live: d.live, vehicle: d.vehicle, scheduled: d.scheduled, time: d.time, normallyLive: usual, now: now) { continue }
            let s: Status = status(live: d.live, vehicle: d.vehicle, leaves: d.time, normallyLive: usual, now: now)
            rows.append((offset: k, row: Row(dep: d, status: s)))
        }
        rows.sort { a, b in
            let x: Date = rankTime(a.row), y: Date = rankTime(b.row)
            return x != y ? x < y : a.offset < b.offset
        }
        return rows.map { $0.row }
    }

    // MARK: trip options

    /// A trip option by its first ride, as `order` takes it.
    struct Option: Equatable, Sendable {
        var id: String
        var line: String
        var departs: Date
        var scheduled: Date
        var live: Bool
        var cancelled: Bool
        var vehicle: Bool = false
    }

    /// The options' statuses, by id (`status`; a cancelled first ride is left to the trip lists, which already say so).
    static func statuses(_ options: [Option], now: Date, alsoLive: Set<String> = []) -> [String: Status] {
        let lines: Set<String> = Set(options.filter { $0.live && !$0.cancelled }.map { normalized($0.line) }).union(alsoLive.map(normalized))
        var out: [String: Status] = [:]
        for o in options {
            out[o.id] = status(live: o.live, vehicle: o.vehicle, leaves: o.departs, normallyLive: lines.contains(normalized(o.line)), now: now)
        }
        return out
    }

    /// The options in their order, the unsure ones after the others (each group in the order given), unless only
    /// unsure ones are left (then as given). Gone ones (past their time without a sign) are dropped.
    static func order(_ options: [Option], now: Date, alsoLive: Set<String> = []) -> [String] {
        let lines: Set<String> = Set(options.filter { $0.live && !$0.cancelled }.map { normalized($0.line) }).union(alsoLive.map(normalized))
        let kept: [Option] = options.filter { o in
            !gone(live: o.live, vehicle: o.vehicle, scheduled: o.scheduled, time: o.departs, normallyLive: lines.contains(normalized(o.line)), now: now)
        }
        let st: [String: Status] = statuses(kept, now: now, alsoLive: alsoLive)
        let sure: [Option] = kept.filter { st[$0.id] != .unsure }
        let unsure: [Option] = kept.filter { st[$0.id] == .unsure }
        return (sure + unsure).map(\.id)
    }
}
