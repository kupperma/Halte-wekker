import Foundation

/// The ride you chose in Plan, which Fastest trip then keeps as your trip (it doesn't swap in the fastest), and the
/// place you searched, which the home then keeps as where you're going until your school schedule takes over again.
/// Plain values (no stores, no SwiftUI), so the rules are tested.
enum ChosenRide {
    /// The option to hand to Fastest trip as chosen: the one you moved to, not the one Plan put first by itself (that
    /// one is the fastest already, and then Fastest trip keeps picking the fastest as before). Nil: no choice made.
    static func pinned(focused: String?, suggested: String?) -> String? {
        guard let f = focused, f != suggested else { return nil }
        return f
    }

    /// Which of `list` (each a trip's ride trip ids, in order) is the ride you chose (`chosen`): the same rides, else
    /// one that starts with the same first ride and shares most of the rest with it (the first of those on a tie).
    /// Nil: it isn't there.
    static func match(_ chosen: [String], in list: [[String]]) -> Int? {
        guard let first = chosen.first else { return nil }
        if let i = list.firstIndex(of: chosen) { return i }
        let mine = Set(chosen)
        var best: (index: Int, shared: Int)?
        for (i, ids) in list.enumerated() where ids.first == first {
            let shared = Set(ids).intersection(mine).count
            if best == nil || shared > best!.shared { best = (i, shared) }
        }
        return best?.index
    }

    /// Looks in a row it may be missing from before it counts as gone (cancelled, or not run after all).
    static let maxMisses = 3

    /// Not in an answer: does that count against it? Only in a whole live answer that reaches past the time it leaves
    /// (so it should have been in it); an answer that stops before then, a first part or a saved one, doesn't count.
    static func countsAsMiss(departure: Date, answer: [Date], whole: Bool) -> Bool {
        whole && answer.contains { $0 >= departure }
    }

    /// Why the ride you chose went: Fastest trip then picks the fastest again, as without a choice.
    enum Gone: String, Equatable {
        case cancelled      // it, or a ride of it, is cancelled
        case left           // it left (without you), or you can't make it any more
        case missing        // no longer in the answers
    }

    /// The short note it leaves on the screen (no notification: the switch itself tells you, as before).
    static func goneNote(_ g: Gone) -> String {
        switch g {
        case .cancelled: return "The ride you chose is cancelled: back to the fastest way."
        case .left: return "The ride you chose has left: back to the fastest way."
        case .missing: return "The ride you chose isn’t in the live times any more: back to the fastest way."
        }
    }

    /// A way that beats the one you chose outright: it leaves no earlier (give or take a minute) and gets you there at
    /// least two minutes sooner. Only that is told, once, as a note; your choice stays. (An earlier one you passed over
    /// in Plan isn't news.)
    static func beats(start: Date, end: Date, chosenStart: Date, chosenEnd: Date) -> Bool {
        start >= chosenStart.addingTimeInterval(-60) && end <= chosenEnd.addingTimeInterval(-120)
    }

    /// The other ways against the one you chose: "your pick", "same time", "+6 min", "4 min sooner".
    static func against(chosenEnd: Date, _ end: Date, isChosen: Bool) -> String {
        if isChosen { return "your pick" }
        let m = Int((end.timeIntervalSince(chosenEnd) / 60).rounded())
        if m == 0 { return "same time" }
        return m > 0 ? "+\(m) min" : "\(-m) min sooner"
    }
}

/// The home's destination (0.20.2): by your schedule (school or home, by the direction), or a place you picked
/// (searched in Plan, a recent one, one of your places). A picked place stays, across launches, until you change it or
/// until the next school window opens (the one in which Fastest trip opens by itself for your class): then it's back
/// to your schedule. School alarms, the trip that opens by itself and planned trips never use the picked place.
enum HomeDest {
    /// When the school window opens: the alarm, or 45 minutes before you leave, whichever is first (the start of
    /// `GoStore.schoolWindowOpen`). Nil: the school alarm is off, or there's no time to leave yet.
    static func windowStart(on: Bool, leave: Date?, alarm: Date?) -> Date? {
        guard on, let l = leave else { return nil }
        return min(l.addingTimeInterval(-45 * 60), alarm ?? l)
    }

    /// Is the place picked at `chosenAt` over? It is once the first school window that opens after the pick has
    /// opened. `until`: that window's start as last seen (kept, so a window that came while the app was closed still
    /// ends it); `windowStart`: the next window as known now (it follows a schedule that moved). Gives the `until` to
    /// keep. No school window known: the place stays until you change it.
    static func resolve(chosenAt: Date, until: Date?, windowStart: Date?, now: Date) -> (over: Bool, until: Date?) {
        if let u = until, now >= u { return (true, u) }
        var u = until
        if let w = windowStart, w > chosenAt { u = w }
        return (u.map { now >= $0 } ?? false, u)
    }

    /// The last few places you searched, for the destination chip: newest first, once each, without the ones that are
    /// one of your places already (within 150 m), at most `max`. Gives their ids.
    static func recents(_ list: [(id: String, lat: Double, lon: Double)], saved: [(lat: Double, lon: Double)], max: Int = 3) -> [String] {
        var out: [String] = []
        for r in list where !out.contains(r.id) {
            guard !saved.contains(where: { metres(r.lat, r.lon, $0.lat, $0.lon) < 150 }) else { continue }
            out.append(r.id)
            if out.count >= max { break }
        }
        return out
    }

    /// Roughly how far apart two spots are, in metres (fine for "the same place").
    static func metres(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let dy = (la2 - la1) * 111_320
        let dx = (lo2 - lo1) * 111_320 * cos((la1 + la2) / 2 * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }
}
