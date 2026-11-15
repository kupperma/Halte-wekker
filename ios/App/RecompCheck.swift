import Foundation

enum Verdict: Equatable {
    case notEnoughData
    case onTrack(kgPerWeek: Double)          // negative = losing
    case recompWorking(waistCm: Double)      // negative
    case eatLess, eatMore
    case waiting(adjustedOn: DayKey, nextCheck: DayKey)
}

enum WeightMath {
    /// Mean of the weigh-ins on days day−6...day; nil if there are none.
    static func weekAverage(_ w: [Measure], endingOn day: DayKey) -> Double? {
        let start = RecompCalendar.adding(-6, to: day)
        let inRange = w.filter { $0.day >= start && $0.day <= day }
        guard !inRange.isEmpty else { return nil }
        return inRange.reduce(0) { $0 + $1.value } / Double(inRange.count)
    }

    /// weekAverage(day) − weekAverage(day−7)
    static func weekChange(_ w: [Measure], on day: DayKey) -> Double? {
        guard let now = weekAverage(w, endingOn: day),
              let before = weekAverage(w, endingOn: RecompCalendar.adding(-7, to: day)) else { return nil }
        return now - before
    }

    /// True with no waist yet, or when the last one is 14 or more days old. False if skipped today.
    static func waistDue(_ waists: [Measure], skippedOn: DayKey?, today: DayKey) -> Bool {
        if let s = skippedOn, s == today { return false }
        guard let last = waists.map({ $0.day }).max() else { return true }
        return RecompCalendar.daysBetween(last, today) >= 14
    }

    static func waistSummary(_ waists: [Measure]) -> (latest: Double, sinceFirst: Double, firstDay: DayKey)? {
        let sorted = waists.sorted { $0.day < $1.day }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        return (last.value, last.value - first.value, first.day)
    }
}

enum WeeklyCheck {
    static func evaluate(weights: [Measure], waists: [Measure], state: CheckState, today: DayKey) -> (Verdict, CheckState) {
        var state = state
        let m = RecompCalendar.monday(of: today)
        let w0 = RecompCalendar.adding(-7, to: m)
        let w1 = RecompCalendar.adding(-14, to: m)
        let w2 = RecompCalendar.adding(-21, to: m)
        let w3 = RecompCalendar.adding(-28, to: m)

        // 1. Pending advice stays until adjusted, or until three weeks have passed.
        if let p = state.pending {
            if m >= RecompCalendar.adding(21, to: p.shownOn) {
                state.baseline = p.shownOn
                state.pending = nil
            } else {
                return (p.kind == .eatLess ? .eatLess : .eatMore, state)
            }
        }

        // 2. Waiting after an adjustment.
        if let b = state.baseline {
            let next = RecompCalendar.adding(28, to: b)
            if m < next { return (.waiting(adjustedOn: b, nextCheck: next), state) }
        }

        func avg(_ start: DayKey) -> Double? {
            if let b = state.baseline, start < b { return nil }
            let end = RecompCalendar.adding(6, to: start)
            let inRange = weights.filter { $0.day >= start && $0.day <= end }
            guard inRange.count >= 4 else { return nil }
            return inRange.reduce(0) { $0 + $1.value } / Double(inRange.count)
        }
        let a0 = avg(w0), a1 = avg(w1), a2 = avg(w2), a3 = avg(w3)

        // 3. Losing too fast, two weeks running.
        if let a0 = a0, let a1 = a1, let a2 = a2, a1 - a2 < -0.5, a0 - a1 < -0.5 {
            state.pending = PendingAdvice(kind: .eatMore, shownOn: m)
            return (.eatMore, state)
        }

        // 4. This week against three weeks ago.
        if let a0 = a0, let a3 = a3 {
            let drop = a0 - a3
            if drop > -0.25 {
                if let delta = waistChange(waists, from: RecompCalendar.adding(6, to: w3), to: RecompCalendar.adding(6, to: w0)),
                   delta <= -1.0 {
                    return (.recompWorking(waistCm: delta), state)
                }
                state.pending = PendingAdvice(kind: .eatLess, shownOn: m)
                return (.eatLess, state)
            }
            return (.onTrack(kgPerWeek: drop / 3), state)
        }

        // 5.
        return (.notEnoughData, state)
    }

    /// Start: last waist in [W3−14, W3+6] (`from` is W3+6).
    /// End: last waist on or before `to`. They must be two different entries.
    private static func waistChange(_ waists: [Measure], from: DayKey, to: DayKey) -> Double? {
        let sorted = waists.sorted { $0.day < $1.day }
        let windowStart = RecompCalendar.adding(-20, to: from)
        guard let early = sorted.last(where: { $0.day >= windowStart && $0.day <= from }),
              let late = sorted.last(where: { $0.day <= to }),
              early.day != late.day else { return nil }
        return late.value - early.value
    }

    /// The person tapped "adjusted": the weeks before this advice no longer count.
    static func adjusted(_ state: CheckState) -> CheckState {
        guard let p = state.pending else { return state }
        var s = state
        s.baseline = p.shownOn
        s.pending = nil
        return s
    }

    private static func oneDecimal(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.1f", v)
    }

    static func text(_ v: Verdict) -> (title: String, detail: String?) {
        let gb = Locale(identifier: "en_GB")
        switch v {
        case .eatLess:
            return ("Your weight hasn't moved in 3 weeks. Eat about 200 kcal less a day.",
                    "A smaller plate, measured oil, or no second helping.")
        case .eatMore:
            return ("You're losing faster than 0.5 kg a week. Eat a bit more so you keep your muscle.", nil)
        case .recompWorking(let cm):
            return ("Weight steady, waist down \(oneDecimal(abs(cm))) cm. That's a recomp working.", nil)
        case .onTrack(let kg):
            return ("On track: losing \(RecompFormat.kg(abs(kg), locale: gb)) a week.", nil)
        case .waiting(let on, let next):
            return ("Adjusted on \(RecompCalendar.shortText(on, locale: gb)). Next check on \(RecompCalendar.shortText(next, locale: gb)).", nil)
        case .notEnoughData:
            return ("Not enough weigh-ins yet.",
                    "Weigh in at least 4 mornings a week. The check compares this week with 3 weeks ago.")
        }
    }
}
