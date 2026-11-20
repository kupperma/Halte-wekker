import Foundation

/// What the app learns from your own rides and walks (0.34, `Habits`; 0.38 also your usual lines, `UsualLine`), and how
/// your changes went (`ChangeOdds`): kept on the phone only (UserDefaults), never sent anywhere. Settings › Trips &
/// alarm › Learned from your rides shows it and resets it.
@MainActor
final class HabitStore: ObservableObject {
    static let shared = HabitStore()

    @Published private(set) var book: HabitBook
    @Published private(set) var changes: ChangeBook

    private static let bookKey = "habits.book"
    private static let changesKey = "habits.changes"
    /// Your walking speed for the planner (m/s), read off the main thread by `Transit.plan` (nil: the planner's own).
    nonisolated static let speedKey = "habits.pedestrianSpeed"

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam") ?? .current
        return c
    }()

    private init() {
        let d = UserDefaults.standard
        book = d.data(forKey: Self.bookKey).flatMap { try? JSONDecoder().decode(HabitBook.self, from: $0) } ?? HabitBook()
        changes = d.data(forKey: Self.changesKey).flatMap { try? JSONDecoder().decode(ChangeBook.self, from: $0) } ?? ChangeBook()
    }

    /// The planner's walking speed: yours once learned (`Habits.pedestrianSpeed`), else nil.
    nonisolated static func pedestrianSpeed() -> Double? {
        let v = UserDefaults.standard.double(forKey: speedKey)
        return v > 0 ? v : nil
    }

    func addWalk(_ speed: Double) { book.addWalk(speed); save() }
    func addChange(_ minutes: Double) { book.addChange(minutes); save() }
    func boarded(at stop: String) { book.boarded(at: stop); save() }
    func plannedFrom(_ stop: String) { book.plannedFrom(stop); save() }

    /// 0.38: a ride on `line` whose planned departure is `at` (`UsualLine`: confirmed, said, or not this one).
    func rode(line: String, train: Bool, at: Date, weight: Int) {
        book.rode(line, train: train, minute: UsualLine.minute(at, calendar: calendar), weekend: UsualLine.weekend(at, calendar: calendar),
                  weight: weight)
        save()
    }

    /// 0.38: of `cands`, the one of your usual line at `at` (`UsualLine.usual`). Nil: none.
    func usual(_ cands: [(id: String, line: String, train: Bool)], at: Date) -> String? {
        UsualLine.usual(cands, minute: UsualLine.minute(at, calendar: calendar), weekend: UsualLine.weekend(at, calendar: calendar), book.lines)
    }

    /// How a change went today (one outcome a day per change and time of day).
    func recordChange(from a: String, to b: String, at station: String, time: Date, made: Bool) {
        let k = ChangeOdds.key(from: a, to: b, at: station, time: time, calendar: calendar)
        changes.record(k, day: ChangeOdds.day(Date(), calendar: calendar), made: made)
        save()
    }

    /// Your history of the change from `a` onto `b` at `station` around `time`: days made, of days.
    func tally(from a: String, to b: String, at station: String, time: Date) -> (made: Int, days: Int) {
        changes.tally(ChangeOdds.key(from: a, to: b, at: station, time: time, calendar: calendar))
    }

    /// "this change worked on 9 of 10 days" for the change between two rides (nil: fewer than 3 days).
    func words(after r: Ride, onto n: Ride) -> String? {
        let t = tally(from: r.line, to: n.line, at: n.fromStop, time: n.departure)
        return ChangeOdds.words(made: t.made, days: t.days)
    }

    /// The minutes a change needs at least, for you: the planner's walk, or your own change time when that's more (2
    /// minutes more at most: one number for every station, `Habits.changeMinutes`).
    func changeNeed(walk: Int) -> Double {
        let w = Double(max(0, walk))
        guard let mine = Habits.changeMinutes(book) else { return w }
        return max(w, min(mine, w + Self.changeExtraMax))
    }
    static let changeExtraMax = 2.0

    /// Minutes off the score of a plan from a stop you prefer (`Habits.bonus`).
    func bonus(_ t: DoorTrip) -> Double { Habits.bonus(firstStop: t.first.fromStop, book) }

    /// Settings › Learned from your rides › Reset.
    func reset() {
        book = HabitBook(); changes = ChangeBook()
        save()
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(book) { d.set(data, forKey: Self.bookKey) }
        if let data = try? JSONEncoder().encode(changes) { d.set(data, forKey: Self.changesKey) }
        if let v = Habits.pedestrianSpeed(book) { d.set(v, forKey: Self.speedKey) } else { d.removeObject(forKey: Self.speedKey) }
    }
}
