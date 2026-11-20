import Foundation

// 0.36: the student travel product (studentenreisproduct, "student OV") — when a ride is free, at a discount or full
// fare. Plain values, Foundation only, so every window is tested.
//
// The rules, as DUO and NS state them (checked 20 November 2026):
//   DUO, "Wanneer vrij reizen": https://duo.nl/particulier/ov-en-reizen/wanneer-reizen.jsp
//   NS, "Studenten OV":         https://www.ns.nl/producten/studenten/studenten-ov
// - The check-in time decides. Days run from 04:00 to 04:00.
// - Week product (weekabonnement): free Monday 04:00 – Saturday 04:00; a discount Saturday 04:00 – Monday 04:00.
//   Summer (16 July 04:00 – 16 August 04:00): a discount only. A public holiday (04:00 to 04:00 the next day): a
//   discount, except Good Friday: free.
// - Weekend product (weekendabonnement): free Friday 12:00 – Monday 04:00. Monday 04:00 – Tuesday 04:00 a discount;
//   Tuesday–Thursday 04:00–09:00 full fare, then a discount; Friday 04:00–09:00 full fare, 09:00–12:00 a discount, then
//   free. A public holiday: free (04:00 to 04:00); Good Friday and Ascension Day free from 12:00 the day before. The
//   summer is as the rest of the year.
// - The discount: 40% on trains; 34% on buses, trams, metros and the waterbus (regional buses included: the product
//   covers all public transport in the Netherlands, with the same week/weekend split).
// - DUO's holidays: New Year's Day, Good Friday, Easter Monday, King's Day, Liberation Day (5 May), Ascension Day,
//   Whit Monday, Christmas Day (and Boxing Day when it's a weekday).
// First class costs extra with either product; this is about 2nd class.

enum StudentOV {
    /// Settings › Trips & alarm › Student travel product.
    enum Product: String, CaseIterable, Codable, Sendable, Identifiable {
        case none, week, weekend
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "None"
            case .week: return "Weekday free (weekend discount)"
            case .weekend: return "Weekend free (weekday discount)"
            }
        }
    }

    enum Fare: Equatable, Sendable {
        case free
        case discount(percent: Int)
        case full
    }

    /// Why it's not free now, for the line on the card.
    enum Why: String, Equatable, Sendable {
        case weekday, weekend, summer, holiday
        case morning                                    // the weekend product's weekday mornings before 09:00: full fare
    }

    struct Answer: Equatable, Sendable {
        let fare: Fare
        let why: Why
    }

    static let trainDiscount = 40
    static let busDiscount = 34

    static let zone = TimeZone(identifier: "Europe/Amsterdam")!
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c
    }

    // MARK: holidays

    /// Easter Sunday (the Gregorian computus, "Anonymous Gregorian algorithm").
    static func easter(_ year: Int) -> DateComponents {
        let a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31, day = (h + l - 7 * m + 114) % 31 + 1
        return DateComponents(year: year, month: month, day: day)
    }

    enum Holiday: String, Equatable, Sendable { case newYear, goodFriday, easterMonday, kingsDay, liberation, ascension, whitMonday, christmas, boxingDay }

    /// The holiday on this calendar day (year, month, day), if it's one of DUO's.
    static func holiday(year: Int, month: Int, day: Int) -> Holiday? {
        let cal = calendar
        if month == 1 && day == 1 { return .newYear }
        if month == 12 && day == 25 { return .christmas }
        if month == 12 && day == 26 { return .boxingDay }
        if month == 5 && day == 5 { return .liberation }
        // King's Day: 27 April, or the 26th when the 27th is a Sunday
        if month == 4, day == 26 || day == 27 {
            let d27 = cal.date(from: DateComponents(year: year, month: 4, day: 27, hour: 12))!
            let sunday = cal.component(.weekday, from: d27) == 1
            if (day == 27 && !sunday) || (day == 26 && sunday) { return .kingsDay }
        }
        guard let e = cal.date(from: { var x = easter(year); x.hour = 12; return x }()),
              let here = cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return nil }
        let offset = cal.dateComponents([.day], from: e, to: here).day ?? 0
        switch offset {
        case -2: return .goodFriday
        case 1: return .easterMonday
        case 39: return .ascension
        case 50: return .whitMonday
        default: return nil
        }
    }

    // MARK: the windows

    /// The travel day a moment belongs to (days run 04:00–04:00): its year, month, day, weekday (1 Sunday … 7 Saturday),
    /// and the minutes since that day's 04:00.
    struct TravelDay: Equatable {
        let year: Int, month: Int, day: Int, weekday: Int
        let minutes: Int
    }

    static func travelDay(_ at: Date) -> TravelDay {
        let cal = calendar
        let shifted = at.addingTimeInterval(-4 * 3600)
        let c = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: shifted)
        return TravelDay(year: c.year!, month: c.month!, day: c.day!, weekday: c.weekday!, minutes: c.hour! * 60 + c.minute!)
    }

    /// 16 July 04:00 – 16 August 04:00.
    static func summer(_ d: TravelDay) -> Bool {
        (d.month == 7 && d.day >= 16) || (d.month == 8 && d.day < 16)
    }

    /// The fare for a ride you check in on at `at`. Nil without a product.
    static func fare(_ product: Product, at: Date, train: Bool) -> Answer? {
        let pct = train ? trainDiscount : busDiscount
        let d = travelDay(at)
        let hol = holiday(year: d.year, month: d.month, day: d.day)
        switch product {
        case .none:
            return nil
        case .week:
            if summer(d) { return Answer(fare: .discount(percent: pct), why: .summer) }
            if let h = hol {
                if h == .goodFriday { return Answer(fare: .free, why: .holiday) }
                if (2...6).contains(d.weekday) { return Answer(fare: .discount(percent: pct), why: .holiday) }
            }
            if (2...6).contains(d.weekday) { return Answer(fare: .free, why: .weekday) }
            return Answer(fare: .discount(percent: pct), why: .weekend)
        case .weekend:
            if hol != nil { return Answer(fare: .free, why: .holiday) }
            // Good Friday and Ascension Day: free from 12:00 the day before
            let cal = calendar
            if d.minutes >= 8 * 60, let today = cal.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12)),
               let next = cal.date(byAdding: .day, value: 1, to: today) {
                let n = cal.dateComponents([.year, .month, .day], from: next)
                if let h = holiday(year: n.year!, month: n.month!, day: n.day!), h == .goodFriday || h == .ascension {
                    return Answer(fare: .free, why: .holiday)
                }
            }
            switch d.weekday {
            case 7, 1: return Answer(fare: .free, why: .weekend)                 // Saturday, Sunday
            case 2: return Answer(fare: .discount(percent: pct), why: .weekday)  // Monday from 04:00
            case 6:                                                              // Friday
                if d.minutes >= 8 * 60 { return Answer(fare: .free, why: .weekend) }          // from 12:00
                if d.minutes >= 5 * 60 { return Answer(fare: .discount(percent: pct), why: .weekday) }  // 09:00–12:00
                return Answer(fare: .full, why: .morning)
            default:                                                             // Tuesday–Thursday
                return d.minutes >= 5 * 60 ? Answer(fare: .discount(percent: pct), why: .weekday) : Answer(fare: .full, why: .morning)
            }
        }
    }

    // MARK: the words

    /// "€3.60"
    static func euros(_ cents: Int) -> String {
        String(format: "€%d.%02d", cents / 100, cents % 100)
    }

    /// What you'd pay: the full fare less the discount, rounded to the cent (nil: free, or no price known).
    static func pay(_ a: Answer, fullCents: Int?) -> Int? {
        guard let c = fullCents, c > 0 else { return nil }
        switch a.fare {
        case .free: return nil
        case .full: return c
        case .discount(let p): return Int((Double(c) * Double(100 - p) / 100).rounded())
        }
    }

    /// "Free with your student OV", "Costs money now (weekend) — ~€3.60", "Costs money now (weekday morning) — full
    /// fare" (no price known). Nil without a product.
    static func line(_ product: Product, at: Date, train: Bool, fullCents: Int?) -> String? {
        guard let a = fare(product, at: at, train: train) else { return nil }
        if a.fare == .free { return "Free with your student OV" }
        let why = a.why == .morning ? "weekday morning" : a.why.rawValue
        let head = "Costs money now (\(why))"
        if let p = pay(a, fullCents: fullCents) {
            if case .discount(let pct) = a.fare { return "\(head) — ~\(euros(p)) with \(pct)% off" }
            return "\(head) — ~\(euros(p))"
        }
        if case .discount(let pct) = a.fare { return "\(head) — \(pct)% off" }
        return "\(head) — full fare"
    }

    /// A trip of several rides: the first one that isn't free decides (each is checked in on at its own departure);
    /// all free: free. `rides`: (train, departure); `fullCents`: the trains' price, for a train that isn't free.
    static func tripLine(_ product: Product, rides: [(train: Bool, at: Date)], fullCents: Int?) -> String? {
        guard product != .none, !rides.isEmpty else { return nil }
        for r in rides {
            guard let a = fare(product, at: r.at, train: r.train) else { return nil }
            if a.fare != .free { return line(product, at: r.at, train: r.train, fullCents: r.train ? fullCents : nil) }
        }
        return "Free with your student OV"
    }

    /// The price NS gives for a journey, from the relay's `/ns/price` (NS's own price answer, or the fares on its first
    /// trip): the 2nd-class single fare without discount, in cents. Reads any shape that has fare objects in it.
    static func fullFareCents(_ json: Any?) -> Int? {
        var found: [(cents: Int, cls: String, disc: String)] = []
        func walk(_ x: Any?) {
            if let d = x as? [String: Any] {
                let cents: Int? = (d["priceInCents"] as? NSNumber)?.intValue ?? (d["totalPriceInCents"] as? NSNumber)?.intValue
                if let c = cents, c > 0 {
                    let cls = ((d["travelClass"] as? String) ?? (d["classType"] as? String) ?? "").uppercased()
                    let disc = ((d["discountType"] as? String) ?? "").uppercased()
                    found.append((c, cls, disc))
                }
                for v in d.values { walk(v) }
            } else if let a = x as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(json)
        func second(_ s: String) -> Bool { s.isEmpty || s.contains("SECOND") || s == "2" }
        func noDiscount(_ s: String) -> Bool { s.isEmpty || s.contains("NO_DISCOUNT") || s == "NONE" }
        if let f = found.first(where: { second($0.cls) && noDiscount($0.disc) && !$0.cls.isEmpty }) { return f.cents }
        if let f = found.first(where: { second($0.cls) && noDiscount($0.disc) }) { return f.cents }
        return nil
    }
}
