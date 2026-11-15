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

    /// Called when an add first takes the day's logged kcal to the limit: total, limit, the day. Once a day at most.
    /// The app posts the notice; there are no notifications in the tests.
    var limitReached: ((_ total: Double, _ limit: Double, _ day: DayKey) -> Void)?

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
        settleAnchor()
    }

    // MARK: - Reading

    var today: DayKey { RecompCalendar.day(for: now()) }

    /// Newest first.
    var todayEntries: [ProteinEntry] {
        entriesToday().sorted { $0.at > $1.at }
    }

    var todayTotal: Double { entriesToday().reduce(0) { $0 + $1.grams } }

    /// Only what's logged today: sources, scanned packs and other food.
    var todayKcal: Double { entriesToday().reduce(0) { $0 + $1.kcal } }

    /// The daily kcal limit now, moved with the week average when that's on.
    var kcalLimit: Double {
        let c = data.calories
        return KcalMath.limit(anchorLimit: c.anchorLimit, anchorWeight: c.anchorWeight, weekAverage: weekAverage,
                              follows: c.followsWeight)
    }

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
                                         amount: amount, gramsPerUnit: source.gramsPerUnit,
                                         kcalPerUnit: KcalMath.sane(source.kcalPerUnit) ?? 0))
        save()
        checkLimit()
    }

    func addProduct(barcode: String, fraction: Double) {
        guard fraction > 0, let p = data.products[barcode] else { return }
        data.entries.append(ProteinEntry(at: now(), name: p.name, unit: "pack", units: "packs",
                                         amount: fraction, gramsPerUnit: p.proteinPerPack,
                                         kcalPerUnit: p.packKcal ?? 0))
        save()
        checkLimit()
    }

    /// "Add kcal": food that isn't a source, 1…3000 kcal. No name: "Other food".
    func addOtherFood(name: String, kcal: Double) {
        guard kcal.isFinite, KcalMath.entryRange.contains(kcal) else { return }
        data.entries.append(ProteinEntry(at: now(), name: Self.foodName(name), unit: ProteinEntry.kcalUnit,
                                         units: ProteinEntry.kcalUnit, amount: kcal, gramsPerUnit: 0, kcalPerUnit: 1))
        save()
        checkLimit()
    }

    func updateOtherFood(_ entryID: UUID, name: String, kcal: Double) {
        guard kcal.isFinite, KcalMath.entryRange.contains(kcal),
              let i = data.entries.firstIndex(where: { $0.id == entryID }), data.entries[i].isOtherFood else { return }
        data.entries[i].name = Self.foodName(name)
        data.entries[i].amount = kcal
        save()
        checkLimit()
    }

    private static func foodName(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? ProteinEntry.otherFood : n
    }

    /// "2 slices": `count` portions of a product counted by portion. Nothing for a product without a portion.
    func addProductPortions(barcode: String, count: Double) {
        guard count > 0, count.isFinite, let p = data.products[barcode], let portion = p.portion else { return }
        data.entries.append(ProteinEntry(at: now(), name: p.name, unit: portion.name, units: portion.units,
                                         amount: count, gramsPerUnit: portion.protein, kcalPerUnit: p.portionKcal ?? 0))
        save()
        checkLimit()
    }

    /// The protein in a whole pack. The barcode's portion (with its kcal) stays as it was, unless `portion` brings a
    /// new one; so does its kcal per pack, unless a new one is given.
    func rememberProduct(barcode: String, name: String, proteinPerPack: Double, portion: Portion? = nil,
                         kcalPerPack: Double? = nil, kcalPerPortion: Double? = nil) {
        let old = data.products[barcode]
        var p = KnownProduct(name: name, proteinPerPack: proteinPerPack)
        if let portion {
            p.portionName = portion.name
            p.proteinPerPortion = portion.protein
            p.kcalPerPortion = KcalMath.sane(kcalPerPortion)
        } else if let keep = old?.portion {
            p.portionName = keep.name
            p.proteinPerPortion = keep.protein
            p.kcalPerPortion = old?.kcalPerPortion
        }
        p.kcalPerPack = KcalMath.sane(kcalPerPack) ?? old?.kcalPerPack
        data.products[barcode] = p
        save()
    }

    /// Count a remembered product by portion from now on. Not for an unknown barcode or a portion that can't be.
    /// Without `kcalPerPortion` a portion's kcal is its share of the pack's.
    func rememberPortion(barcode: String, name: String, proteinPerPortion: Double, kcalPerPortion: Double? = nil) {
        guard data.products[barcode] != nil, let portion = Portion(name: name, protein: proteinPerPortion) else { return }
        data.products[barcode]?.portionName = portion.name
        data.products[barcode]?.proteinPerPortion = portion.protein
        data.products[barcode]?.kcalPerPortion = KcalMath.sane(kcalPerPortion)
        save()
    }

    /// What Open Food Facts knows now, for a product remembered without it (before 0.17.1, say): its portion, if it
    /// has none and this one is a part of its pack, and its kcal per pack, if it has none. Nothing else changes.
    func fillIn(barcode: String, portion: Portion?, energy: Energy) {
        guard var p = data.products[barcode] else { return }
        let before = p
        if p.portion == nil, let portion, portion.isPart(of: p.proteinPerPack) {
            p.portionName = portion.name
            p.proteinPerPortion = portion.protein
            p.kcalPerPortion = KcalMath.sane(energy.perPortion)
        }
        if p.packKcal == nil, let k = KcalMath.sane(energy.perPack) { p.kcalPerPack = k }
        guard p != before else { return }
        data.products[barcode] = p
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
        checkLimit()
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
        settleAnchor()
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

    /// "Done, I've adjusted": the weeks before no longer count, and the kcal limit moves 200 down for "eat less",
    /// 200 up for "eat more" (whether or not it moves with the weight).
    func markAdjusted() {
        if let kind = data.check.pending?.kind {
            let step = kind == .eatLess ? -KcalMath.adjustStep : KcalMath.adjustStep
            data.calories.anchorLimit = KcalMath.clampLimit(data.calories.anchorLimit + step)
        }
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

    /// Set by hand: the limit is this from now, and moves from today's week average.
    func setKcalLimit(_ limit: Double) {
        data.calories.anchorLimit = KcalMath.clampLimit(limit)
        data.calories.anchorWeight = weekAverage
        save()
    }

    /// Switching it doesn't change the limit there is now; it only moves (or stops moving) from here.
    func setKcalFollowsWeight(_ on: Bool) {
        guard data.calories.followsWeight != on else { return }
        let current = kcalLimit
        data.calories.followsWeight = on
        data.calories.anchorLimit = current
        data.calories.anchorWeight = weekAverage
        save()
    }

    func setKcalNotify(_ on: Bool) {
        data.calories.notify = on
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

    /// A product counted by portion becomes a source in portions ("per slice", one at a time); any other in packs.
    @discardableResult
    func addToSources(barcode: String) -> Bool {
        guard data.sources.count < RecompData.maxSources, let p = data.products[barcode],
              !data.sources.contains(where: { $0.barcode == barcode }) else { return false }
        if let portion = p.portion {
            data.sources.append(ProteinSource(name: p.name, unit: portion.name, units: portion.units,
                                              gramsPerUnit: portion.protein, step: 1, barcode: barcode,
                                              kcalPerUnit: p.portionKcal ?? 0))
        } else {
            data.sources.append(ProteinSource(name: p.name, unit: "pack", units: "packs",
                                              gramsPerUnit: p.proteinPerPack, step: 0.25, barcode: barcode,
                                              kcalPerUnit: p.packKcal ?? 0))
        }
        save()
        return true
    }

    // MARK: - Calories

    /// The limit is set at the first week average there is.
    private func settleAnchor() {
        guard data.calories.anchorWeight == nil, let avg = weekAverage else { return }
        data.calories.anchorWeight = avg
        save()
    }

    /// After an add: the notice, once a day, when the day's logged kcal reaches the limit.
    private func checkLimit() {
        let t = today
        let total = todayKcal, limit = kcalLimit
        guard KcalMath.shouldNotify(total: total, limit: limit, lastNotified: data.calories.notifiedOn, today: t,
                                    enabled: data.calories.notify) else { return }
        data.calories.notifiedOn = t
        save()
        limitReached?(total, limit, t)
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
