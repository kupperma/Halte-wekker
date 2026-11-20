import Foundation

// Test friend (0.30.1): a bot that is a real second Friends account made on this phone, to try every Friends feature
// with before anyone you know has the app. Its account, its boxes and the relay are the real ones (see
// TestFriendBot.swift); this file is its brain: what it says back and the trips, waits and timetables it pretends,
// as plain values, tested without the relay or the UI. Foundation only.

enum TestFriendBrain {
    /// Its name everywhere (the request it sends, your list, the chat).
    static let name = "Test friend"
    /// Under its name in your requests.
    static let note = "A test friend made on your phone, to try Friends with. Remove it any time."

    /// Its first line once you're friends.
    static let hello = "Hi! I’m your test friend, a bot that lives on this phone. Write to me, send me a trip, add me to a group, or try the buttons under “Test friend controls” on my page."

    /// In a group it was added to (it only answers you there, never your other friends).
    static func groupHello(_ group: String) -> String {
        "Hi everyone! I’m the test friend. Thanks for adding me to “\(group)”. I answer here too."
    }

    /// Quick replies ("’" and "'" alike, any case).
    private static func plain(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "'", with: "’").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What it says back to a line of text (nil: nothing to say).
    static func reply(to text: String) -> String? {
        let t: String = ChatText.clean(text)
        guard !t.isEmpty else { return nil }
        let p: String = plain(t)
        if p.hasPrefix("on the "), t.count > 7 {
            let line: String = String(t.dropFirst(7))
            return "Nice, I’ll look out for you on the \(line)."
        }
        switch p {
        case "running 5 min late": return "No problem, I’ll wait. See you in a bit!"
        case "save me a seat": return "Saved you one by the window."
        case "wait for me": return "Sure, I’ll wait for you!"
        case "i’m at the stop": return "Great, I’m almost there!"
        case "hi", "hey", "hello", "hoi", "hallo": return "Hi! Test friend here. Your message came through, locked end to end."
        default: break
        }
        if p.hasSuffix("?") {
            return "Good question! I’m only a test friend, so I can’t really answer, but your message came through fine."
        }
        let shown: String = t.count > 80 ? String(t.prefix(80)) + "…" : t
        return "You said: “\(shown)”. Got it, locked end to end."
    }

    /// Its answer to a trip card: "I’m in" (as an answer), then a line about the ride.
    static func replies(toTrip c: TripCard, n: String) -> [ChatText] {
        var out: [ChatText] = [ChatText(text: TripAnswer.yes.text, re: n, answer: TripAnswer.yes.rawValue)]
        if let r = TripTake.shared(c) {
            out.append(ChatText(text: "See you on the \(r.label) at \(TripCardWords.hhmm(r.dep))!"))
        }
        return out
    }

    /// Its answer to your "Wait for me": "I’ll wait" (as an answer).
    static func reply(toWait id: String) -> ChatText {
        ChatText(text: WaitAnswer.wait.text, re: id, answer: WaitAnswer.wait.rawValue)
    }

    /// What it says when you answer something of its own (its wait, its card).
    static func reply(toAnswer answer: String) -> String? {
        switch answer {
        case WaitAnswer.wait.rawValue: return "Thanks for waiting! Nearly there."
        case WaitAnswer.next.rawValue: return "OK, let’s take the next one together."
        case TripAnswer.yes.rawValue: return "Great, see you there!"
        case TripAnswer.no.rawValue: return "Shame! Next time."
        default: return nil
        }
    }

    // MARK: its timetable (a plausible two weeks near yours)

    /// Two weeks of classes near yours: each weekday a first class when yours starts that day (or 08:45; Friday
    /// 10:30), the next after a 30-minute break and the last after an hour's (Wednesday afternoon free); no weekends.
    static func timetable(mine: TimetableShare?, now: Date) -> TimetableShare {
        let cal: Calendar = TimetableDays.calendar
        let window: (from: Date, to: Date) = TimetableDays.window(now: now)
        let firsts: [String: Date] = firstClasses(mine)
        var classes: [TimetableClass] = []
        for i in 0..<TimetableShare.days {
            guard let day = cal.date(byAdding: .day, value: i, to: window.from) else { continue }
            let weekday: Int = cal.component(.weekday, from: day)
            guard weekday != 1, weekday != 7 else { continue }
            let key: String = TimetableDays.key(day)
            var base: Int = weekday == 6 ? 10 * 60 + 30 : 8 * 60 + 45
            if let f = firsts[key] {
                let c: DateComponents = cal.dateComponents([.hour, .minute], from: f)
                base = (c.hour ?? 8) * 60 + (c.minute ?? 45)
            }
            base = max(7 * 60 + 30, min(13 * 60, base))
            var parts: [(Int, Int, String, String)] = [(0, 90, "Project work", "B1.12"), (120, 210, "Lecture", "Aula")]
            if weekday != 4 { parts.append((270, 390, "Workshop", "C0.08")) }
            for p in parts {
                guard let s = cal.date(byAdding: .minute, value: base + p.0, to: day),
                      let e = cal.date(byAdding: .minute, value: base + p.1, to: day) else { continue }
                classes.append(TimetableClass(start: s, end: e, title: p.2, room: p.3))
            }
        }
        return TimetableShare(from: window.from, to: window.to, classes: classes, src: "week")
    }

    /// Your first class of each day (by day key).
    private static func firstClasses(_ mine: TimetableShare?) -> [String: Date] {
        var out: [String: Date] = [:]
        for c in mine?.classes ?? [] {
            let k: String = TimetableDays.key(c.start)
            if let had = out[k], had <= c.start { continue }
            out[k] = c.start
        }
        return out
    }

    // MARK: its scores (near yours)

    /// Its fastest trips on your routes (a little slower going, a little faster home), or two of its own when you
    /// have none yet; all from today, so they count for this month too.
    static func scores(mine: [ScoreTrip], rides: Int, now: Date) -> ScoresShare {
        let at: Date = now.addingTimeInterval(-3600)
        var trips: [ScoreTrip] = []
        for b in ScoresRules.bests(mine) {
            let factor: Double = b.home ? 0.96 : 1.05
            trips.append(ScoreTrip(route: b.route, home: b.home, mins: max(5, min(600, b.mins * factor)), at: at))
        }
        if trips.isEmpty {
            trips = [ScoreTrip(route: "home→school", home: false, mins: 46.5, at: at),
                     ScoreTrip(route: "school→home", home: true, mins: 51.2, at: at)]
        }
        // (0.35) and a trip to school an hour ago, for today's best and worst: 52.4 min, the 305 7 min late
        let today: [DayTrip] = [DayTrip(home: false, mins: 52.4, at: at, plan: 45, line: "305", late: 7)]
        return ScoresRules.build(trips: trips, rides: rides, now: now, today: today)
    }

    // MARK: the wake-up buddy

    /// "I haven't left": a plan for today that said leave 6 minutes ago, for a ride in 4 minutes.
    static func buddy(now: Date, ride: TripCard.Ride?) -> BuddyPlan {
        BuddyPlan(on: true, day: TimetableDays.key(now), leave: now.addingTimeInterval(-6 * 60), ride: ride, left: nil)
    }

    /// A ride for its pretend plans: from `from` to `to`, leaving in `inMinutes`.
    static func ride(from: TripCard.Spot, to: TripCard.Spot, train: Bool, now: Date, inMinutes: Double, id: String) -> TripCard.Ride {
        let dep: Date = now.addingTimeInterval(inMinutes * 60)
        return TripCard.Ride(mode: train ? "train" : "bus", line: train ? "SPR" : "300", name: train ? "Sprinter" : nil, num: nil,
                             trip: id, head: to.name, from: from, to: to, dep: dep, arr: dep.addingTimeInterval(12 * 60))
    }

    // MARK: your vault

    /// What the vault keeps, without the test friend: never in your backup (not in the list, a group's members, the
    /// timetable's "off" list or the buddy switch).
    static func scrub(_ c: FriendVaultContents, bot: String) -> FriendVaultContents {
        var v = c
        v.book.friends.removeAll { $0.id == bot }
        v.book.incoming.removeAll { $0.id == bot }
        v.book.outgoing.removeAll { $0.id == bot }
        if let gs = c.groups {
            v.groups = gs.map { (g: FriendGroup) -> FriendGroup in
                var x = g
                x.roster.members.removeAll { $0.id == bot }
                return x
            }
        }
        if var t = c.timetable, let off = t.off {
            let kept: [String] = off.filter { $0 != bot }
            t.off = kept.isEmpty ? nil : kept
            v.timetable = t
        }
        if var e = c.extras, let b = e.buddy {
            let kept: [String] = b.filter { $0 != bot }
            e.buddy = kept.isEmpty ? nil : kept
            v.extras = e
        }
        return v
    }
}

// MARK: a pretend trip

/// A trip the test friend pretends to be on: a real bus or train near your Home (its stops as the live data has them),
/// squeezed into `TestTripSim.rideFor` from now: a minute waiting at the first stop, then riding to the last.
struct TestTrip: Codable, Equatable {
    struct Stop: Codable, Equatable {
        var name: String
        var lat: Double
        var lon: Double
        /// Seconds after it starts riding.
        var at: TimeInterval
    }

    var mode: String
    var line: String
    var num: String?
    var trip: String
    var stops: [Stop]
    /// Where the bus or train goes in the end (its headsign), when it isn't the last stop here.
    var dest: String?
    /// When it started (waiting at the first stop).
    var start: Date

    var isTrain: Bool { mode == "train" }
}

enum TestTripSim {
    /// A minute at the stop first…
    static let waitFor: TimeInterval = 60
    /// …then this long on board.
    static let rideFor: TimeInterval = 10 * 60
    /// Stops taken after the first: until this far into the real trip, at most `maxStops` in all.
    static let realSpan: TimeInterval = 25 * 60
    static let maxStops = 8

    struct RealStop: Equatable {
        var name: String
        var lat: Double
        var lon: Double
        var time: Date?
    }

    /// The trip from `stops` (the real ones, from where it gets on): its stops' real times (or, without them, their
    /// distances) spread over `rideFor`. Nil: fewer than two stops.
    static func make(mode: String, line: String, num: String?, trip: String, stops: [RealStop], dest: String?, start: Date) -> TestTrip? {
        guard let first = stops.first else { return nil }
        var kept: [RealStop] = [first]
        for s in stops.dropFirst() {
            if kept.count >= maxStops { break }
            if kept.count >= 2, let t0 = first.time, let t = s.time, t.timeIntervalSince(t0) > realSpan { break }
            if Geo.metres(GeoPoint(lat: s.lat, lon: s.lon), GeoPoint(lat: kept[kept.count - 1].lat, lon: kept[kept.count - 1].lon)) < 30 { continue }
            kept.append(s)
        }
        guard kept.count >= 2 else { return nil }
        // the share of the way each stop is at: by its time when every time is known and they go up, else by distance
        var byTime: [TimeInterval] = []
        var timesOK = true
        for s in kept {
            guard let t = s.time, let t0 = first.time else { timesOK = false; break }
            let x: TimeInterval = t.timeIntervalSince(t0)
            if let last = byTime.last, x <= last { timesOK = false; break }
            byTime.append(x)
        }
        var share: [Double] = []
        if timesOK, let total = byTime.last, total > 0 {
            share = byTime.map { $0 / total }
        } else {
            var run: [Double] = [0]
            for i in 1..<kept.count {
                let a = GeoPoint(lat: kept[i - 1].lat, lon: kept[i - 1].lon), b = GeoPoint(lat: kept[i].lat, lon: kept[i].lon)
                run.append(run[i - 1] + max(1, Geo.metres(a, b)))
            }
            let total: Double = run[run.count - 1]
            share = run.map { $0 / total }
        }
        var out: [TestTrip.Stop] = []
        for (i, s) in kept.enumerated() {
            out.append(TestTrip.Stop(name: s.name, lat: s.lat, lon: s.lon, at: (share[i] * rideFor).rounded()))
        }
        let last: String = kept[kept.count - 1].name
        let d: String? = (dest?.isEmpty ?? true) || dest == last ? nil : dest
        return TestTrip(mode: mode, line: line, num: num, trip: trip, stops: out, dest: d, start: start)
    }

    /// When it's over (at the last stop).
    static func end(_ t: TestTrip) -> Date { t.start.addingTimeInterval(waitFor + rideFor) }

    static func over(_ t: TestTrip, now: Date) -> Bool { now >= end(t) }

    /// Where it is now, as a `travel` state (nil: over, or not begun). A train gets a coach (3 of 6, from the front).
    static func state(_ t: TestTrip, now: Date) -> TravelState? {
        guard t.stops.count >= 2, now >= t.start, !over(t, now: now) else { return nil }
        let first: TestTrip.Stop = t.stops[0], last: TestTrip.Stop = t.stops[t.stops.count - 1]
        let riding: Bool = now.timeIntervalSince(t.start) >= waitFor
        var s = TravelState(state: riding ? "riding" : "waiting", mode: t.mode,
                            from: TravelState.Spot(name: first.name, lat: first.lat, lon: first.lon),
                            to: TravelState.Spot(name: last.name, lat: last.lat, lon: last.lon))
        s.line = t.line
        s.num = t.num
        s.trip = t.trip
        if let d = t.dest { s.dest = TravelState.Spot(name: d) }
        s.eta = end(t)
        s.end = end(t)
        s.leg = 1
        s.legs = 1
        let p: GeoPoint = position(t, now: now)
        s.pos = TravelState.Position(lat: (p.lat * 100_000).rounded() / 100_000, lon: (p.lon * 100_000).rounded() / 100_000, acc: 12, at: now)
        if t.isTrain, riding { s.coach = coach(line: t.line) }
        return s
    }

    /// Its coach on a train: 3 of 6 from the front, and (0.31) a window: an Intercity's upper deck, the 8th window from
    /// the back; a Sprinter's 6th.
    static func coach(line: String) -> TravelState.Coach {
        let double: Bool = SeatMap.defaultDouble(line: line)
        let seat = TravelState.Seat(deck: double ? SeatMap.Deck.upper.rawValue : SeatMap.Deck.none.rawValue, w: double ? 8 : 6, of: SeatMap.windows)
        return TravelState.Coach(n: 3, of: 6, front: true, at: nil, seat: seat)
    }

    /// Between the two stops it's between now, by time (at the first stop while waiting, at the last when over).
    static func position(_ t: TestTrip, now: Date) -> GeoPoint {
        guard let first = t.stops.first, let last = t.stops.last else { return GeoPoint(lat: 0, lon: 0) }
        let r: TimeInterval = now.timeIntervalSince(t.start) - waitFor
        if r <= 0 { return GeoPoint(lat: first.lat, lon: first.lon) }
        for i in 1..<t.stops.count {
            let a: TestTrip.Stop = t.stops[i - 1], b: TestTrip.Stop = t.stops[i]
            guard r < b.at else { continue }
            let span: TimeInterval = max(1, b.at - a.at)
            let f: Double = max(0, min(1, (r - a.at) / span))
            return GeoPoint(lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f)
        }
        return GeoPoint(lat: last.lat, lon: last.lon)
    }

    /// Without the live data: a Sprinter between the NS station nearest home and the next one (at least 1.5 km on).
    static func fallback(home: GeoPoint, stations: [NSStation], start: Date) -> TestTrip? {
        guard let a = NearestStation.pick(home, in: stations, within: 30_000) else { return nil }
        var best: (NSStation, Double)?
        for s in stations where s.code != a.code {
            let d: Double = Geo.metres(a.point, s.point)
            if d >= 1500, d <= 40_000, best.map({ d < $0.1 }) ?? true { best = (s, d) }
        }
        guard let b = best?.0 else { return nil }
        let stops: [RealStop] = [RealStop(name: a.name, lat: a.lat, lon: a.lon, time: nil), RealStop(name: b.name, lat: b.lat, lon: b.lon, time: nil)]
        return make(mode: "train", line: "SPR", num: nil, trip: "test-friend-\(a.code)-\(b.code)", stops: stops, dest: nil, start: start)
    }
}

// MARK: a pretend "wait for me"

/// The test friend asks you to wait: coming from 650 m away, there after 5 minutes, over after 10.
struct TestWait: Codable, Equatable {
    var id: String
    var stop: TripCard.Spot
    var start: Date
}

enum TestWaitSim {
    static let comeFor: TimeInterval = 5 * 60
    static let overAfter: TimeInterval = 10 * 60
    static let startMetres = 650.0

    static func over(_ w: TestWait, now: Date) -> Bool { now.timeIntervalSince(w.start) >= overAfter }

    /// The `wait` body now.
    static func body(_ w: TestWait, now: Date) -> WaitFor {
        let e: TimeInterval = max(0, now.timeIntervalSince(w.start))
        if e >= overAfter { return WaitFor(id: w.id, state: WaitFor.Phase.off.rawValue, stop: w.stop, dist: 0, at: now) }
        if e >= comeFor { return WaitFor(id: w.id, state: WaitFor.Phase.there.rawValue, stop: w.stop, dist: 0, eta: now, at: now) }
        let left: Double = startMetres * (1 - e / comeFor)
        let dist: Int = Int((left / 10).rounded()) * 10
        return WaitFor(id: w.id, state: WaitFor.Phase.coming.rawValue, stop: w.stop, dist: dist,
                       eta: w.start.addingTimeInterval(comeFor), at: now)
    }
}
