import Foundation

/// What the app learns from your own rides and walks (0.34), on the phone only: how fast you walk (to stops, across a
/// change), how much time you need to change in practice, and stops you get on at more often than the planner has you
/// (Bolkenplein instead of the station). Planning uses it: your walking speed for the walks, your change time as the
/// least room a change has in its ranking (`Risk`), and a small bonus for a plan from a stop you prefer.
/// Settings › Trips & alarm › Learned from your rides shows it, with a reset.
struct HabitBook: Codable, Equatable, Sendable {
    var walks: [Double] = []                // m/s, one per walk, newest last
    var changes: [Double] = []              // minutes from getting off to being at the next ride's stop, newest last
    var boardedAt: [String: Int] = [:]      // stop (`Habits.key`) → rides you got on there
    var plannedAt: [String: Int] = [:]      // stop → trips you started whose first ride was planned from there
    var names: [String: String] = [:]       // stop key → its name as shown

    var isEmpty: Bool { walks.isEmpty && changes.isEmpty && boardedAt.isEmpty && plannedAt.isEmpty }

    mutating func addWalk(_ speed: Double) {
        guard speed.isFinite, speed >= Habits.walkMin, speed <= Habits.walkMax else { return }
        walks = Array((walks + [(speed * 100).rounded() / 100]).suffix(Habits.keep))
    }

    mutating func addChange(_ minutes: Double) {
        guard minutes.isFinite, minutes >= 0, minutes <= Habits.changeMax else { return }
        changes = Array((changes + [(minutes * 10).rounded() / 10]).suffix(Habits.keep))
    }

    mutating func boarded(at stop: String) {
        let k = Habits.key(stop)
        guard !k.isEmpty else { return }
        boardedAt[k, default: 0] += 1
        names[k] = stop.trimmingCharacters(in: .whitespaces)
        trim()
    }

    mutating func plannedFrom(_ stop: String) {
        let k = Habits.key(stop)
        guard !k.isEmpty else { return }
        plannedAt[k, default: 0] += 1
        if names[k] == nil { names[k] = stop.trimmingCharacters(in: .whitespaces) }
        trim()
    }

    /// At most `Habits.stops` stops each, the least used go first.
    private mutating func trim() {
        if boardedAt.count > Habits.stops {
            boardedAt = Dictionary(uniqueKeysWithValues: boardedAt.sorted { $0.value > $1.value }.prefix(Habits.stops).map { ($0.key, $0.value) })
        }
        if plannedAt.count > Habits.stops {
            plannedAt = Dictionary(uniqueKeysWithValues: plannedAt.sorted { $0.value > $1.value }.prefix(Habits.stops).map { ($0.key, $0.value) })
        }
        let used = Set(boardedAt.keys).union(plannedAt.keys)
        names = names.filter { used.contains($0.key) }
    }
}

enum Habits {
    static let plannerWalk = 1.2            // m/s: the planner's own walking speed (Transitous, about 4.3 km/h)
    static let walkMin = 0.6, walkMax = 2.6 // m/s: a walk (not standing, not a bike)
    static let walkFor: TimeInterval = 60   // s of walking in a walk at least
    static let walkAccuracy = 25.0          // m: rougher fixes say nothing about your speed
    static let walksNeeded = 5              // walks before it's your speed
    static let changesNeeded = 3            // changes before it's your change time
    static let changeMax = 20.0             // min: longer isn't a change across (a coffee, a wait)
    static let changeNear = 50.0            // m: at the next ride's stop
    static let preferredNeeded = 3          // rides got on at a stop before it may be one you prefer
    static let preferredBonus = 2.0         // min off a plan's score that starts at a stop you prefer
    static let keep = 40                    // walks and changes kept
    static let stops = 60                   // stops kept

    /// A stop as it's counted: its name, trimmed and in lower case.
    static func key(_ stop: String) -> String { stop.trimmingCharacters(in: .whitespaces).lowercased() }

    /// One walk's speed from its fixes: of the good ones (`walkAccuracy`), those at a walking pace (the GPS's own speed,
    /// else the step from the fix before), when there are `walkFor` seconds of them: their median. Nil: not a walk.
    static func walkSpeed(of fixes: [Fix]) -> Double? {
        let f = fixes.filter { $0.accuracy.isFinite && $0.accuracy >= 0 && $0.accuracy <= walkAccuracy }.sorted { $0.t < $1.t }
        guard f.count >= 3 else { return nil }
        var speeds: [Double] = [], time: TimeInterval = 0
        for i in 1..<f.count {
            let dt = f[i].t.timeIntervalSince(f[i - 1].t)
            guard dt > 0, dt <= 20 else { continue }
            let v = f[i].speed.isFinite && f[i].speed >= 0 ? f[i].speed : Geo.metres(f[i - 1].p, f[i].p) / dt
            guard v >= walkMin, v <= walkMax else { continue }
            speeds.append(v); time += dt
        }
        guard time >= walkFor else { return nil }
        return median(speeds)
    }

    /// Your walking speed: the median of your walks once there are `walksNeeded`.
    static func walkSpeed(_ b: HabitBook) -> Double? {
        guard b.walks.count >= walksNeeded else { return nil }
        return median(b.walks)
    }

    /// The planner's walk of `minutes` at your speed (rounded up; the planner's when nothing's learned).
    static func walkMinutes(_ minutes: Int, _ b: HabitBook) -> Int {
        guard minutes > 0, let v = walkSpeed(b), v > 0 else { return minutes }
        return Int((Double(minutes) * plannerWalk / v).rounded(.up))
    }

    /// Your speed for the planner (m/s, to a tenth), when it's clearly not its own (0.1 m/s or more off).
    static func pedestrianSpeed(_ b: HabitBook) -> Double? {
        guard let v = walkSpeed(b), abs(v - plannerWalk) >= 0.1 else { return nil }
        return (min(walkMax, max(walkMin, v)) * 10).rounded() / 10
    }

    /// Minutes from getting off (`arrived`) to being at the next ride's stop: the first fix within `changeNear` of it.
    static func changeMinutes(arrived: Date, fixes: [Fix], stop: GeoPoint) -> Double? {
        let f = fixes.filter { $0.t >= arrived && $0.accuracy.isFinite && $0.accuracy >= 0 && $0.accuracy <= 50 }.sorted { $0.t < $1.t }
        guard let at = f.first(where: { Geo.metres($0.p, stop) <= max(changeNear, $0.accuracy) }) else { return nil }
        let m = at.t.timeIntervalSince(arrived) / 60
        return m <= changeMax ? m : nil
    }

    /// The time you need to change: what was enough on 8 of 10 days (the 80th percentile, nearest rank), once there
    /// are `changesNeeded`; whole minutes, up.
    static func changeMinutes(_ b: HabitBook) -> Double? {
        guard b.changes.count >= changesNeeded else { return nil }
        let s = b.changes.sorted()
        let rank = Int((0.8 * Double(s.count)).rounded(.up))
        return s[max(0, min(s.count - 1, rank - 1))].rounded(.up)
    }

    /// A stop you get on at more often than the planner had you: `preferredNeeded` rides or more, and more than the trips
    /// planned from there.
    static func preferred(_ stop: String, _ b: HabitBook) -> Bool {
        let k = key(stop)
        let n = b.boardedAt[k] ?? 0
        return n >= preferredNeeded && n > (b.plannedAt[k] ?? 0)
    }

    /// Minutes off the score of a plan whose first ride is from `firstStop`.
    static func bonus(firstStop: String, _ b: HabitBook) -> Double { preferred(firstStop, b) ? preferredBonus : 0 }

    /// The stops you prefer, most used first, by their names.
    static func preferredStops(_ b: HabitBook) -> [String] {
        b.boardedAt.filter { preferred($0.key, b) }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { b.names[$0.key] ?? $0.key }
    }

    struct Row: Equatable, Sendable { let label: String; let value: String }

    /// Settings › Learned from your rides.
    static func rows(_ b: HabitBook) -> [Row] {
        let walk = walkSpeed(b).map { String(format: "%.1f km/h", $0 * 3.6) } ?? "not yet"
        let change = changeMinutes(b).map { "\(Int($0)) min" } ?? "not yet"
        let stops = preferredStops(b)
        return [Row(label: "Walking speed", value: walk),
                Row(label: "Time you need to change", value: change),
                Row(label: "Stops you prefer", value: stops.isEmpty ? "none yet" : stops.prefix(3).joined(separator: ", "))]
    }

    private static func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
