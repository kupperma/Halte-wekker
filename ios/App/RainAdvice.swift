import Foundation

/// 0.37: rain on the walk of your next trip. Before a trip (from 3 hours before you leave), when Open-Meteo expects
/// 0.5 mm an hour or more while you walk to the first stop or from the last one, the home's next-trip card and the Go
/// card say so: "Rain at 08:00 — take bus 305 at 07:41 to the station instead of walking" when a bus there exists (a
/// walk of 6 min or more to a train), else "Rain at 08:00 — bring an umbrella". Plain values (Foundation only), tested.
enum RainAdvice {
    /// mm in an hour that counts as rain you'd rather not walk in.
    static let threshold = 0.5

    /// One hour of Open-Meteo's forecast: `mm` is the rain of the hour before `time` (its "preceding hour" sum).
    struct Hour: Equatable, Sendable {
        let time: Date
        let mm: Double
        var from: Date { time.addingTimeInterval(-3600) }
    }

    /// A part of the trip on foot, and where (at the start or the end).
    struct Stretch: Equatable, Sendable {
        let from: Date
        let to: Date
        let atStart: Bool
    }

    struct Hit: Equatable, Sendable {
        /// When the rain is there on the walk (its hour's start, or the walk's start when it's later).
        let at: Date
        let mm: Double
        let atStart: Bool
    }

    /// The walk before the first ride (from when you leave) and after the last one (to when you're there), when 2
    /// minutes or more.
    static func stretches(start: Date, walkBefore: Int, lastArrival: Date, end: Date) -> [Stretch] {
        var out: [Stretch] = []
        if walkBefore >= 2 { out.append(Stretch(from: start, to: start.addingTimeInterval(Double(walkBefore) * 60), atStart: true)) }
        if end.timeIntervalSince(lastArrival) >= 120 { out.append(Stretch(from: lastArrival, to: end, atStart: false)) }
        return out
    }

    /// The first time on a walk with rain at or over the threshold: the start's walk in `here`, the end's in `there`.
    static func hit(_ stretches: [Stretch], here: [Hour], there: [Hour], threshold: Double = threshold) -> Hit? {
        for s in stretches {
            let hours = (s.atStart ? here : there).sorted { $0.time < $1.time }
            for h in hours where h.mm >= threshold && h.from < s.to && h.time > s.from {
                return Hit(at: max(h.from, s.from), mm: h.mm, atStart: s.atStart)
            }
        }
        return nil
    }

    /// Only before a trip: from 3 hours before you leave until 5 minutes after.
    static func due(start: Date, now: Date) -> Bool {
        start.timeIntervalSince(now) <= 3 * 3600 && now.timeIntervalSince(start) <= 5 * 60
    }

    /// Another way that starts with a bus, as far as this needs: its line, when it leaves, the walk to it, when it gets
    /// you where it must (the station, or there), and by when that has to be.
    struct Bus: Equatable, Sendable {
        let line: String
        let departure: Date
        let walkBefore: Int
        let arrives: Date
        let deadline: Date
    }

    /// The bus to take instead of a walk of `walk` minutes: one you can still make, with at most half that walk (and at
    /// least 4 minutes less), there in time; the first to leave.
    static func bus(instead walk: Int, now: Date, from candidates: [Bus]) -> Bus? {
        let maxWalk = max(2, min(walk / 2, walk - 4))
        return candidates
            .filter { $0.walkBefore <= maxWalk && $0.departure.addingTimeInterval(-Double($0.walkBefore) * 60) >= now && $0.arrives <= $0.deadline }
            .min { $0.departure < $1.departure }
    }

    enum Advice: Equatable, Sendable {
        case bus(line: String, at: Date)
        case umbrella
    }

    /// The bus only for the walk to a train (6 minutes or more of it) with rain on that walk; else an umbrella.
    static func advice(_ hit: Hit, firstIsTrain: Bool, walkBefore: Int, bus: Bus?) -> Advice {
        if hit.atStart, firstIsTrain, walkBefore >= 6, let b = bus { return .bus(line: b.line, at: b.departure) }
        return .umbrella
    }

    /// "Rain at 08:00 — take bus 305 at 07:41 to the station instead of walking", "Rain at 08:00 — bring an umbrella".
    static func text(_ hit: Hit, _ advice: Advice, hhmm: (Date) -> String) -> String {
        switch advice {
        case .bus(let line, let at):
            let name = line.allSatisfy(\.isNumber) ? "bus \(line)" : "the \(line)"
            return "Rain at \(hhmm(hit.at)) — take \(name) at \(hhmm(at)) to the station instead of walking"
        case .umbrella:
            return "Rain at \(hhmm(hit.at)) — bring an umbrella"
        }
    }
}
