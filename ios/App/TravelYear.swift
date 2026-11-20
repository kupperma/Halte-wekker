import Foundation

// Your year in travel (0.35), Foundation only: the rides the phone kept (`RideRecord`, travel.json on this phone only,
// never sent) and the leaderboard's trips worked out into a few cards: hours on buses and trains, kilometres, trips,
// CO₂ saved against driving, your favourite line, stop and coach, your earliest start, the longest delay you sat
// through, and rides with friends. The screen is TravelYearViews.swift; the shared picture leaves out every place.

/// One ride (a leg on a bus or train), as the phone keeps it for Your year in travel.
struct RideRecord: Codable, Equatable, Identifiable {
    var id: String
    /// The trip it was part of (when its alarm started), so legs count as one trip.
    var trip: Date
    /// When it left (the planned departure once that had passed, else when the leg began) and when you got off.
    var dep: Date
    var arr: Date
    var train: Bool
    /// "Bus 305", "Intercity", "Sprinter".
    var label: String
    /// Where you got on and off (names only).
    var from: String
    var to: String
    /// Kilometres along the way (`TravelYear.km`).
    var km: Double
    /// Minutes late at your stop, once known.
    var late: Double? = nil
    /// The coach you marked on a train (0.26).
    var coach: Int? = nil

    var minutes: Double { max(0, arr.timeIntervalSince(dep) / 60) }
}

enum TravelLog {
    static let keepDays = 800
    static let maxKept = 6000

    /// The ride added (the newest last); past `keepDays` and `maxKept` the oldest go.
    static func add(_ list: [RideRecord], _ r: RideRecord, now: Date) -> [RideRecord] {
        var out: [RideRecord] = list.filter { $0.id != r.id }
        out.append(r)
        let oldest: Date = now.addingTimeInterval(-Double(keepDays) * 86400)
        out = out.filter { $0.dep >= oldest }.sorted { $0.dep < $1.dep }
        return Array(out.suffix(maxKept))
    }
}

struct TravelStats: Equatable {
    struct Fav: Equatable { var label: String; var n: Int }
    struct Delay: Equatable { var label: String; var mins: Double; var at: Date }

    /// The first ride or trip in the window.
    var since: Date?
    /// The phone has a year of it (else: "your travel so far").
    var fullYear = false
    var trips = 0
    var rides = 0
    var busMinutes = 0.0
    var trainMinutes = 0.0
    /// Trips from before the phone kept rides (0.35): their time door to door, from the leaderboard.
    var earlierMinutes = 0.0
    var busKm = 0.0
    var trainKm = 0.0
    var line: Fav?
    var stop: Fav?
    var coach: Fav?
    /// The earliest time of day you set off (its date).
    var earliest: Date?
    var delay: Delay?
    var friends = 0

    var hours: Double { (busMinutes + trainMinutes + earlierMinutes) / 60 }
    var km: Double { busKm + trainKm }
    var co2Saved: Double { TravelYear.co2Saved(busKm: busKm, trainKm: trainKm) }
    var empty: Bool { trips == 0 && rides == 0 }
}

/// A card of Your year in travel.
struct YearCard: Equatable, Identifiable {
    var id: String
    /// The small line on top ("Time on board").
    var title: String
    /// The big one ("38 h").
    var value: String
    var sub: String
    /// The line under it on the shared picture, when it's not `sub` (no places in it).
    var shareSub: String? = nil
    /// An SF Symbol.
    var symbol: String
}

enum TravelYear {
    // MARK: CO₂
    //
    // CO₂ saved = km by bus × (car − bus) + km by train × (car − train), in kg, with these factors (kg CO₂ per km),
    // rounded from the Dutch list of CO₂ emission factors (co2emissiefactoren.nl, kept by Milieu Centraal, Stimular and
    // SKAO; "personenauto" average, well-to-wheel) and the EEA's figures for passenger transport (EEA, "Transport and
    // environment report", CO₂ per passenger-km by mode):
    //   car   ≈ 0.19 per vehicle-km: an average car with you alone in it, the trip you'd otherwise have driven;
    //   bus   ≈ 0.05 per passenger-km: a regional bus at a usual occupancy;
    //   train ≈ 0.02 per passenger-km: Dutch electric trains (NS buys wind power; this leaves room for the grid and
    //           other operators).
    // These are approximations, and the screen says "about".
    static let carKgPerKm = 0.19
    static let busKgPerKm = 0.05
    static let trainKgPerKm = 0.02

    static func co2Saved(busKm: Double, trainKm: Double) -> Double {
        max(0, busKm) * (carKgPerKm - busKgPerKm) + max(0, trainKm) * (carKgPerKm - trainKgPerKm)
    }

    // MARK: kilometres

    /// A ride's kilometres: the straight line between where you got on and off, times a detour factor (roads wind more
    /// than railways): 1.3 by bus, 1.15 by train.
    static func km(metres: Double, train: Bool) -> Double { max(0, metres) / 1000 * (train ? 1.15 : 1.3) }

    // MARK: the stats

    /// The window: the last 365 days up to `now`.
    static let windowDays = 365

    /// The stats of the last year: `rides` the phone kept, `trips` the leaderboard's (only those from before the first
    /// kept ride count, door to door, so nothing is counted twice), `together` the days of your rides with friends.
    static func stats(rides: [RideRecord], trips: [TripScore], together: [Date], now: Date, calendar: Calendar) -> TravelStats {
        let from: Date = now.addingTimeInterval(-Double(windowDays) * 86400)
        let mine: [RideRecord] = rides.filter { $0.dep >= from && $0.dep <= now }
        let firstRide: Date? = rides.map(\.dep).min()
        let earlier: [TripScore] = trips.filter { (t: TripScore) -> Bool in
            t.at >= from && t.at <= now && (firstRide.map { f in t.at < f } ?? true)
        }
        var s = TravelStats()
        let firstAny: Date? = [firstRide, trips.map { $0.at.addingTimeInterval(-$0.mins * 60) }.min()].compactMap { $0 }.min()
        s.fullYear = firstAny.map { $0 <= from } ?? false
        s.since = [mine.map(\.dep).min(), earlier.map { $0.at.addingTimeInterval(-$0.mins * 60) }.min()].compactMap { $0 }.min()
        s.rides = mine.count
        s.trips = Set(mine.map(\.trip)).count + earlier.count
        for r in mine {
            if r.train { s.trainMinutes += r.minutes; s.trainKm += r.km } else { s.busMinutes += r.minutes; s.busKm += r.km }
        }
        s.earlierMinutes = earlier.map(\.mins).reduce(0, +)
        s.line = favourite(mine.map(\.label))
        s.stop = favourite(mine.map(\.from))
        s.coach = favourite(mine.compactMap { r in r.train ? r.coach.map { "Coach \($0)" } : nil }, least: 2)
        // the earliest time of day you set off: a ride's departure, or an earlier trip's start
        let starts: [Date] = mine.map(\.dep) + earlier.map { $0.at.addingTimeInterval(-$0.mins * 60) }
        s.earliest = starts.min { secondOfDay($0, calendar) < secondOfDay($1, calendar) }
        if let d = mine.filter({ ($0.late ?? 0) >= 1 }).max(by: { a, b in (a.late ?? 0) != (b.late ?? 0) ? (a.late ?? 0) < (b.late ?? 0) : a.dep > b.dep }) {
            s.delay = TravelStats.Delay(label: d.label, mins: d.late ?? 0, at: d.dep)
        }
        s.friends = together.filter { $0 >= from && $0 <= now }.count
        return s
    }

    /// The most common one (at least `least` times); a tie goes to the one seen last.
    static func favourite(_ xs: [String], least: Int = 1) -> TravelStats.Fav? {
        var n: [String: Int] = [:], last: [String: Int] = [:]
        for (i, x) in xs.enumerated() where !x.isEmpty { n[x, default: 0] += 1; last[x] = i }
        guard let best = n.max(by: { a, b in a.value != b.value ? a.value < b.value : (last[a.key] ?? 0) < (last[b.key] ?? 0) }),
              best.value >= least else { return nil }
        return TravelStats.Fav(label: best.key, n: best.value)
    }

    static func secondOfDay(_ d: Date, _ c: Calendar) -> Int {
        let p = c.dateComponents([.hour, .minute, .second], from: d)
        return (p.hour ?? 0) * 3600 + (p.minute ?? 0) * 60 + (p.second ?? 0)
    }

    // MARK: words

    /// "1,240".
    static func grouped(_ n: Int) -> String {
        let s = String(abs(n))
        var out = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    /// "38 h", "45 min" (under an hour).
    static func hours(_ h: Double) -> String { h < 1 ? "\(Int((h * 60).rounded())) min" : "\(grouped(Int(h.rounded()))) h" }

    static func day(_ d: Date, _ c: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.calendar = c
        f.timeZone = c.timeZone
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }

    static func hhmm(_ d: Date, _ c: Calendar) -> String {
        let p = c.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", p.hour ?? 0, p.minute ?? 0)
    }

    /// The cards, in order; one without anything to say is left out.
    static func cards(_ s: TravelStats, calendar c: Calendar) -> [YearCard] {
        guard !s.empty else { return [] }
        var out: [YearCard] = []
        let sinceWords: String = s.since.map { "Since \(day($0, c))" } ?? "So far"
        out.append(YearCard(id: "intro", title: s.fullYear ? "Your year in travel" : "Your travel so far",
                            value: s.trips == 1 ? "1 trip" : "\(grouped(s.trips)) trips",
                            sub: s.fullYear ? "The last 12 months on buses and trains." : "\(sinceWords), on buses and trains.",
                            symbol: "sparkles"))
        if s.hours > 0 {
            var parts: [String] = []
            if s.trainMinutes > 0 { parts.append("\(hours(s.trainMinutes / 60)) by train") }
            if s.busMinutes > 0 { parts.append("\(hours(s.busMinutes / 60)) by bus") }
            if s.earlierMinutes > 0 { parts.append("\(hours(s.earlierMinutes / 60)) on earlier trips, door to door") }
            out.append(YearCard(id: "hours", title: "Time on board", value: hours(s.hours), sub: parts.joined(separator: " · ") + ".", symbol: "clock"))
        }
        if s.km >= 1 {
            let earth = 40_075.0
            let k = Int(s.km.rounded())
            let around: String = s.km >= earth ? String(format: "%.1f× around the world", s.km / earth)
                : "\(max(1, Int((s.km / earth * 100).rounded())))% of the way around the world"
            out.append(YearCard(id: "km", title: "Distance", value: "\(grouped(k)) km", sub: "About \(around).", symbol: "point.topleft.down.to.point.bottomright.curvepath"))
            let kg = Int(s.co2Saved.rounded())
            if kg >= 1 {
                out.append(YearCard(id: "co2", title: "CO₂ saved", value: "\(grouped(kg)) kg",
                                    sub: "About that much less than driving those \(grouped(k)) km alone in a car (car 0.19 kg/km, bus 0.05, train 0.02).",
                                    symbol: "leaf"))
            }
        }
        if let l = s.line {
            var bits: [String] = [l.n == 1 ? "1 ride" : "\(grouped(l.n)) rides"]
            var share: [String] = bits
            if let st = s.stop { bits.append("most often from \(st.label)") }
            if let co = s.coach { bits.append("\(co.label.lowercased()) on the train"); share.append("\(co.label.lowercased()) on the train") }
            out.append(YearCard(id: "favourite", title: "Your favourite", value: l.label, sub: bits.joined(separator: " · ") + ".",
                                shareSub: share.joined(separator: " · ") + ".", symbol: "heart"))
        }
        if let e = s.earliest {
            out.append(YearCard(id: "early", title: "Earliest start", value: hhmm(e, c), sub: "\(day(e, c)). The early bird gets the seat.", symbol: "sunrise"))
        }
        if let d = s.delay {
            let m = Int(d.mins.rounded())
            out.append(YearCard(id: "delay", title: "Longest delay survived", value: "\(m) min",
                                sub: "The \(d.label) on \(day(d.at, c)). You made it anyway.", symbol: "tortoise"))
        }
        if s.friends > 0 {
            out.append(YearCard(id: "friends", title: "With friends", value: s.friends == 1 ? "1 ride" : "\(grouped(s.friends)) rides",
                                sub: "On the same bus or train as a friend.", symbol: "person.2"))
        }
        return out
    }

    // MARK: the home's card

    /// The year the home's card is for now, or nil: in December, or in the two weeks after a year of rides, with at
    /// least 5 trips, and not put away for that year.
    static func seasonal(now: Date, firstData: Date?, trips: Int, dismissed: Int?, calendar c: Calendar) -> Int? {
        guard trips >= 5 else { return nil }
        let year: Int = c.component(.year, from: now)
        guard dismissed != year else { return nil }
        if c.component(.month, from: now) == 12 { return year }
        if let f = firstData {
            let a = f.addingTimeInterval(Double(windowDays) * 86400)
            if now >= a && now < a.addingTimeInterval(14 * 86400) { return year }
        }
        return nil
    }
}
