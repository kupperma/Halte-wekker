import Foundation

/// 0.39: the change ahead, as the ride screen and the lock screen guide you through it: where you get in and where the
/// next one leaves ("Platform 5 → 7"), the walk, and the minutes you have ("4 min to change"). When your ride's live
/// times have you there too late for the planned one (less room than you need: the walk, or your own change time once
/// it's learned), it says so at once with the next one you do make: "You’ll miss the 08:12 — take the 08:27 from
/// platform 4", for one tap to switch the rest of the trip to it. Plain values, so it can be tested.
enum ChangeGuide {
    /// The least room a change has, in minutes, even across the platform.
    static let least = 1.0

    /// A ride you could change onto.
    struct Ride: Equatable, Sendable {
        var tripId: String
        var line: String            // "IC", "SPR", "306"
        var isTrain: Bool
        var departure: Date
        var platform: String? = nil
        var walk: Int = 0           // minutes the planner walks to it
        /// (0.42.3) Where it leaves from, when known: a ride instead must leave from the change (`MissCall.sane`).
        var from: GeoPoint? = nil
    }

    struct Guide: Equatable, Sendable {
        /// The one to take: the planned one, or the next you make when that's missed (`missed`).
        let target: Ride
        /// Minutes from arriving (at the change already: from now) to `target` leaving; negative: it has gone by then.
        let minutes: Int
        let platforms: String?      // "Platform 5 → 7"
        let walk: String?           // "3 min walk"
        let countdown: String       // "4 min to change"
        let tight: Bool             // under the room it needs (after a slow bus: more), or missed
        /// The planned one can't be made: less room than `need`.
        let missed: Bool
        /// The planned one, when missed (what `missText` names).
        let planned: Ride?
        let missText: String?       // "You’ll miss the 08:12 — take the 08:27 from platform 4"
        /// (0.42.3) What it says of the planned one (`MissCall`): fine, tight, look out for it, maybe, missed.
        var call: MissCall.Call = .fine
        /// (0.42.3) A quiet word under the countdown: "Look out for it", "Tight — run".
        var note: String? = nil

        /// What the lock screen shows under the ride: "Platform 5 → 7 · 3 min walk".
        var lockLine: String { [platforms, walk].compactMap { $0 }.joined(separator: " · ") }
    }

    /// Your own change time counts for this much more than the walk at most (as `HabitStore.changeNeed`: one number
    /// for every station).
    static let learnedExtraMax = 2.0

    /// The minutes a change onto a ride `walk` minutes away needs: the walk, or your own change time when it's learned
    /// and more (`Habits.changeMinutes`, at most `learnedExtraMax` over the walk), never under `least`.
    static func need(walk: Int, learned: Double?) -> Double {
        let w = Double(max(0, walk))
        let mine: Double = learned.flatMap { $0.isFinite ? min($0, w + learnedExtraMax) : nil } ?? w
        return max(least, max(w, mine))
    }

    /// "Platform 5 → 7"; across the same platform "Same platform (5)"; onto a bus "Platform 5 → bus 306"; from a bus
    /// "To platform 7"; only where you get in "Arrive at platform 5"; nothing known: nil.
    static func platforms(arrive a: String?, next: Ride) -> String? {
        let a = clean(a), d = clean(next.platform)
        switch (a, d) {
        case (let a?, let d?) where next.isTrain:
            return a == d ? "Same platform (\(a))" : "Platform \(a) → \(d)"
        case (let a?, _) where !next.isTrain:
            return "Platform \(a) → bus \(next.line)"
        case (nil, let d?) where next.isTrain:
            return "To platform \(d)"
        case (let a?, nil):
            return "Arrive at platform \(a)"
        default:
            return nil
        }
    }

    /// The change ahead. `arrive`: when you're at the change (live); `arrivePlatform` where (nil: not known, a bus);
    /// `fromTrain`/`grade`: the ride you're on (a slow bus's change wants more room, `ChangeRoom.changeNote`); `next`:
    /// the planned next ride (at its live time); `later`: the next leg's other rides; `learned`: your own change time
    /// (nil: not learned yet).
    /// 0.39.1 (`MissRule`): `atChange`, you're at the change already: the planned one is missed only once its live
    /// departure has gone by with you not on it, and never while its own GPS has it at or before the stop (`notLeft`).
    /// 0.42.3 (`MissCall`): `seen` what is known of it at the change (a live time, its own GPS, how near you are; nil:
    /// a live time, and `notLeft`); `fresh` the ride you're on has fresh data (on the way); `call` the call as held
    /// (`MissCall.step`; nil: as this look has it); `feeding`/`changeAt` for the ride instead (`MissCall.sane`).
    static func guide(arrive: Date, arrivePlatform: String?, fromTrain: Bool, grade: String?, next: Ride, later: [Ride],
                      learned: Double?, now: Date, hhmm: (Date) -> String, atChange: Bool = false, notLeft: Bool = false,
                      seen: MissCall.Next? = nil, fresh: Bool = true, call: MissCall.Call? = nil,
                      feeding: MissCall.Feeding? = nil, changeAt: [GeoPoint] = []) -> Guide {
        let from: Date = max(arrive, now)
        var c: MissCall.Call = call ?? self.call(arrive: arrive, next: next, learned: learned, now: now, atChange: atChange,
                                                 notLeft: notLeft, seen: seen, fresh: fresh)
        var target = next
        var instead: Ride?
        if c == .missed {
            let ok: [Ride] = MissCall.sane(later, planned: next, feeding: feeding, changeAt: changeAt)
            instead = nextMade(after: next, later: ok, from: from, learned: learned)
            // (0.42.3) on the way with no sane one instead: tight, run (at the change it has gone: "likely missed")
            if let i = instead {
                target = i
            } else if !atChange {
                c = .tight
            }
        }
        let missed: Bool = c == .missed
        let m = Int((target.departure.timeIntervalSince(from) / 60).rounded(.down))
        let note = ChangeRoom.changeNote(minutes: m, walk: max(0, target.walk), isTrain: fromTrain, grade: grade)
        let words: (countdown: String, note: String?) = countdownWords(c, minutes: m)
        let walk: String? = target.walk > 0 ? "\(target.walk) min walk" : nil
        var text: String?
        if missed { text = missWords(planned: next, instead: instead, hhmm: hhmm) }
        let tight: Bool = missed || note.red || c == .tight || c == .maybe
        var g = Guide(target: target, minutes: m, platforms: platforms(arrive: arrivePlatform, next: target), walk: walk,
                      countdown: words.countdown, tight: tight, missed: missed, planned: missed ? next : nil, missText: text)
        g.call = c
        g.note = words.note
        return g
    }

    /// (0.42.3) This look's call on the planned next ride, before the hold (`MissCall.step`): at the change by
    /// `MissCall.atChange`, on the way by `MissCall.onTheWay`.
    static func call(arrive: Date, next: Ride, learned: Double?, now: Date, atChange: Bool, notLeft: Bool = false,
                     seen: MissCall.Next? = nil, fresh: Bool = true) -> MissCall.Call {
        if atChange {
            let n: MissCall.Next = seen ?? MissCall.Next(live: true, seen: notLeft ? .notLeft : .none)
            return MissCall.atChange(departure: next.departure, next: n, now: now)
        }
        let needed: Double = need(walk: next.walk, learned: learned)
        return MissCall.onTheWay(arrive: arrive, departure: next.departure, need: needed, now: now, fresh: fresh)
    }

    /// The countdown and the quiet word under it for a call.
    static func countdownWords(_ c: MissCall.Call, minutes m: Int) -> (countdown: String, note: String?) {
        switch c {
        case .lookOut:
            return ("Should be leaving now", "Look out for it")
        case .maybe:
            return ("May have left", "Look out for it")
        case .tight:
            return m <= 0 ? ("Tight — run", nil) : ("\(m) min to change", "Tight — run")
        case .fine, .missed:
            return (m < 0 ? "It leaves before you’re there" : "\(m) min to change", nil)
        }
    }

    /// The first of `later` after `planned` that you make from `from`: room for its own walk (or your change time).
    static func nextMade(after planned: Ride, later: [Ride], from: Date, learned: Double?) -> Ride? {
        let options: [Ride] = later.filter { $0.tripId != planned.tripId && $0.departure > planned.departure }
            .sorted { $0.departure < $1.departure }
        return options.first { r in r.departure.timeIntervalSince(from) / 60 >= need(walk: r.walk, learned: learned) }
    }

    /// "You’ll miss the 08:12 — take the 08:27 from platform 4"; a bus "… — take bus 306 at 08:27"; none found yet:
    /// "You’ll likely miss the 08:12".
    static func missWords(planned: Ride, instead: Ride?, hhmm: (Date) -> String) -> String {
        guard let i = instead else { return "You’ll likely miss the \(hhmm(planned.departure))" }
        let head = "You’ll miss the \(hhmm(planned.departure)) — "
        if !i.isTrain { return head + "take bus \(i.line) at \(hhmm(i.departure))" }
        let p: String = clean(i.platform).map { " from platform \($0)" } ?? ""
        return head + "take the \(hhmm(i.departure))\(p)"
    }

    /// Switch the trip onto `instead`: the rest planned again from the change, the plan whose first ride is that one
    /// (else the first that leaves with it, within a minute). Nil: no plan has it.
    static func pickPlan(_ firstRides: [(tripId: String, departure: Date)], instead: Ride) -> Int? {
        if let k = firstRides.firstIndex(where: { $0.tripId == instead.tripId }) { return k }
        return firstRides.firstIndex { abs($0.departure.timeIntervalSince(instead.departure)) <= 60 }
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }
}

/// 0.39.1: when the next ride of a change is missed. The field report of 25 November: "You’ll miss the 08:14", "… the
/// 16:39", "… the 17:21" while you stood at the change and the one you wanted was late and still coming (made it twice;
/// the third time the board said "in 2 min"). Its live departure decides, and its own GPS: a bus or train still at the
/// stop, or before it, hasn't left.
enum MissRule {
    /// s past its live departure before it has gone without you (a live time is a forecast; a bus pulls out late).
    static let grace: TimeInterval = 60
    /// m: its own GPS this far past your stop along its road still counts as at it.
    static let atStopSlack = 40.0
    /// s: an older fix of its own says nothing about now.
    static let fixFresh: TimeInterval = 180

    /// Its own GPS has it at your stop or still before it: `vehicleMetres` where its fix puts it along its road,
    /// `stopMetres` where your stop is along that road, `fixAge` how old the fix is. False when any is unknown.
    static func notLeft(vehicleMetres: Double?, stopMetres: Double?, fixAge: TimeInterval?) -> Bool {
        guard let v = vehicleMetres, let s = stopMetres, let a = fixAge, v.isFinite, s.isFinite, a.isFinite else { return false }
        guard a >= -60, a <= fixFresh else { return false }
        return v <= s + atStopSlack
    }

    /// Missed. Still on the way there: your live arrival plus the room you `need` (minutes) is after its live
    /// departure. At the change (`atChange`): only once its live departure has gone by `grace` with you not on it, and
    /// never while its own GPS has it at or before the stop (`notLeft`).
    static func missed(arrive: Date, departure: Date, need: Double, now: Date, atChange: Bool, notLeft: Bool) -> Bool {
        if atChange {
            if notLeft { return false }
            return now.timeIntervalSince(departure) > grace
        }
        let from: Date = max(arrive, now)
        let room: Double = departure.timeIntervalSince(from) / 60
        return room < need
    }
}
