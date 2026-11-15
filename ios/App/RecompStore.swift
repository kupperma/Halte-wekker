import Foundation
import Combine

@MainActor
final class RecompStore: ObservableObject {
    static let shared = RecompStore()

    private static let key = "recomp.v1"

    @Published private(set) var data: RecompData
    @Published private(set) var verdict: Verdict = .notEnoughData

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        var loaded = RecompData()
        if let raw = defaults.data(forKey: RecompStore.key) {
            if let decoded = try? JSONDecoder().decode(RecompData.self, from: raw) {
                loaded = decoded
            } else {
                // Keep the unreadable bytes so nothing is lost for good.
                defaults.set(raw, forKey: RecompStore.key + ".corrupt")
            }
        }
        self.data = loaded
        prune()
        refreshCheck()
    }

    // MARK: - Reading

    var today: DayKey { RecompCalendar.day(for: now()) }

    /// Newest first.
    var todayEntries: [ProteinEntry] {
        entriesToday().sorted { $0.at > $1.at }
    }

    var todayTotal: Double { entriesToday().reduce(0) { $0 + $1.grams } }

    /// Today's 04:00–04:00 worked out once, then a plain comparison per entry.
    private func entriesToday() -> [ProteinEntry] {
        let b = RecompCalendar.bounds(of: today)
        return data.entries.filter { $0.at >= b.start && $0.at < b.end }
    }

    var todayWeight: Double? {
        let t = today
        return data.weights.last(where: { $0.day == t })?.value
    }

    var weekAverage: Double? { WeightMath.weekAverage(data.weights, endingOn: today) }
    var weekChange: Double? { WeightMath.weekChange(data.weights, on: today) }

    var waistDue: Bool {
        WeightMath.waistDue(data.waists, skippedOn: data.waistSkippedOn, today: today)
    }

    // MARK: - Protein

    func add(_ source: ProteinSource, amount: Double) {
        guard amount > 0 else { return }
        data.entries.append(ProteinEntry(at: now(), name: source.name, unit: source.unit, units: source.units,
                                         amount: amount, gramsPerUnit: source.gramsPerUnit))
        save()
    }

    func addProduct(barcode: String, fraction: Double) {
        guard fraction > 0, let p = data.products[barcode] else { return }
        data.entries.append(ProteinEntry(at: now(), name: p.name, unit: "pack", units: "packs",
                                         amount: fraction, gramsPerUnit: p.proteinPerPack))
        save()
    }

    func rememberProduct(barcode: String, name: String, proteinPerPack: Double) {
        data.products[barcode] = KnownProduct(name: name, proteinPerPack: proteinPerPack)
        save()
    }

    func setAmount(_ entryID: UUID, _ amount: Double) {
        guard let i = data.entries.firstIndex(where: { $0.id == entryID }) else { return }
        if amount <= 0 {
            data.entries.remove(at: i)
            save()
            return
        }
        data.entries[i].amount = amount
        save()
    }

    func remove(_ entryID: UUID) {
        data.entries.removeAll { $0.id == entryID }
        save()
    }

    // MARK: - Habits

    func isDone(_ habitID: UUID) -> Bool {
        data.habitsDone[today]?.contains(habitID) ?? false
    }

    func toggleHabit(_ habitID: UUID) {
        var ids = data.habitsDone[today] ?? []
        if let i = ids.firstIndex(of: habitID) {
            ids.remove(at: i)
        } else {
            ids.append(habitID)
        }
        data.habitsDone[today] = ids.isEmpty ? nil : ids
        save()
    }

    // MARK: - Body

    func logWeight(_ kg: Double) {
        let t = today
        data.weights.removeAll { $0.day == t }
        data.weights.append(Measure(day: t, value: kg))
        data.weights.sort { $0.day < $1.day }
        save()
        refreshCheck()
    }

    func logWaist(_ cm: Double) {
        let t = today
        data.waists.removeAll { $0.day == t }
        data.waists.append(Measure(day: t, value: cm))
        data.waists.sort { $0.day < $1.day }
        save()
        refreshCheck()
    }

    func skipWaist() {
        data.waistSkippedOn = today
        save()
    }

    // MARK: - Weekly check

    func markAdjusted() {
        data.check = WeeklyCheck.adjusted(data.check)
        save()
        refreshCheck()
    }

    func refreshCheck() {
        let (v, state) = WeeklyCheck.evaluate(weights: data.weights, waists: data.waists,
                                              state: data.check, today: today)
        if verdict != v { verdict = v }
        if state != data.check {
            data.check = state
            save()
        }
    }

    // MARK: - Settings

    func setGoal(_ g: Double) {
        data.goal = min(max(g, 100), 250)
        save()
    }

    func saveSources(_ s: [ProteinSource]) {
        data.sources = Array(s.prefix(RecompData.maxSources))
        save()
    }

    func saveHabits(_ h: [Habit]) {
        let kept = h.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        data.habits = Array(kept.prefix(RecompData.maxHabits))
        save()
    }

    @discardableResult
    func addToSources(barcode: String) -> Bool {
        guard data.sources.count < RecompData.maxSources, let p = data.products[barcode],
              !data.sources.contains(where: { $0.barcode == barcode }) else { return false }
        data.sources.append(ProteinSource(name: p.name, unit: "pack", units: "packs",
                                          gramsPerUnit: p.proteinPerPack, step: 0.25, barcode: barcode))
        save()
        return true
    }

    // MARK: - Persistence

    private func prune() {
        let cutoff = RecompCalendar.adding(-90, to: today)
        let cutoffStart = RecompCalendar.bounds(of: cutoff).start
        let before = data
        data.entries.removeAll { $0.at < cutoffStart }
        data.habitsDone = data.habitsDone.filter { $0.key >= cutoff }
        if data != before { save() }
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        defaults.set(raw, forKey: RecompStore.key)
    }
}
