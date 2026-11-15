import XCTest

private final class Clock {
    var date: Date
    init(_ d: Date) { date = d }
}

@MainActor
final class RecompStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var clock: Clock!

    /// A Monday, 12:00 in the device time zone.
    private let startDay = "2026-11-16"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: UUID().uuidString)!
        clock = Clock(RecompCalendar.date(of: startDay))
    }

    private func makeStore() -> RecompStore {
        let c = clock!
        return RecompStore(defaults: defaults, now: { c.date })
    }

    private func source(_ store: RecompStore, _ name: String) -> ProteinSource {
        store.data.sources.first { $0.name == name }!
    }

    func test_defaults() {
        let s = makeStore()
        let got = s.data.sources.map { "\($0.name)|\($0.unit)|\($0.units)|\($0.gramsPerUnit)|\($0.step)" }
        XCTAssertEqual(got, [
            "Kwark|tub|tubs|42.0|0.25",
            "Eggs|egg|eggs|6.5|1.0",
            "Milk|glass|glasses|8.0|1.0",
            "Tuna|can|cans|25.0|1.0",
            "Chicken|portion|portions|27.0|1.0",
            "Beans & lentils|can|cans|18.0|0.5",
            "Whey|scoop|scoops|22.0|1.0",
        ])
        XCTAssertEqual(s.data.habits.map { $0.title }, [
            "Only zero drinks", "Half the plate veg", "Oil and sauce measured",
            "Nothing straight from the bag", "One planned treat",
        ])
        XCTAssertEqual(s.data.goal, 160)
    }

    func test_addAndTotal() {
        let s = makeStore()
        s.add(source(s, "Eggs"), amount: 3)
        s.add(source(s, "Kwark"), amount: 0.75)
        XCTAssertEqual(s.todayTotal, 51.0, accuracy: 0.001)
        let cal = RecompCalendar.calendar
        let tomorrow = RecompCalendar.date(of: RecompCalendar.adding(1, to: startDay))
        clock.date = cal.date(bySettingHour: 4, minute: 0, second: 0, of: tomorrow)!
        XCTAssertEqual(s.todayTotal, 0, accuracy: 0.001)
    }

    /// The day runs 04:00 to 04:00: 03:59 the next calendar day is still today, 04:00 is not.
    func test_todayIncludes0359NextDay() {
        let s = makeStore()
        let cal = RecompCalendar.calendar
        let noon = clock.date
        let nextDay = RecompCalendar.date(of: RecompCalendar.adding(1, to: startDay))
        let late = cal.date(bySettingHour: 3, minute: 59, second: 0, of: nextDay)!
        let four = cal.date(bySettingHour: 4, minute: 0, second: 0, of: nextDay)!
        clock.date = late
        s.add(source(s, "Eggs"), amount: 1)         // 6.5 g
        clock.date = four
        s.add(source(s, "Milk"), amount: 1)         // 8 g
        clock.date = noon
        XCTAssertEqual(s.todayEntries.map { $0.name }, ["Eggs"])
        XCTAssertEqual(s.todayTotal, 6.5, accuracy: 0.001)
        clock.date = late
        XCTAssertEqual(s.todayEntries.map { $0.name }, ["Eggs"])
        clock.date = four
        XCTAssertEqual(s.todayEntries.map { $0.name }, ["Milk"])
        XCTAssertEqual(s.todayTotal, 8, accuracy: 0.001)
    }

    func test_entryKeepsItsGrams() {
        let s = makeStore()
        var eggs = source(s, "Eggs")
        s.add(eggs, amount: 3)
        eggs.gramsPerUnit = 10
        s.saveSources(s.data.sources.map { $0.name == "Eggs" ? eggs : $0 })
        XCTAssertEqual(s.todayTotal, 19.5, accuracy: 0.001)
        s.saveSources(s.data.sources.filter { $0.name != "Eggs" })
        XCTAssertEqual(s.todayTotal, 19.5, accuracy: 0.001)
    }

    func test_setAmountAndRemove() {
        let s = makeStore()
        clock.date = clock.date.addingTimeInterval(-60)
        s.add(source(s, "Eggs"), amount: 3)
        clock.date = clock.date.addingTimeInterval(60)
        s.add(source(s, "Milk"), amount: 2)
        let eggs = s.todayEntries.first { $0.name == "Eggs" }!
        let milk = s.todayEntries.first { $0.name == "Milk" }!
        XCTAssertEqual(s.todayEntries.first?.name, "Milk")
        s.setAmount(eggs.id, 4)
        XCTAssertEqual(s.todayTotal, 26 + 16, accuracy: 0.001)
        s.remove(eggs.id)
        XCTAssertEqual(s.todayEntries.map { $0.id }, [milk.id])
        XCTAssertEqual(s.todayTotal, 16, accuracy: 0.001)
    }

    func test_weightReplacesSameDay() {
        let s = makeStore()
        s.logWeight(88.6)
        s.logWeight(88.4)
        XCTAssertEqual(s.data.weights.count, 1)
        XCTAssertEqual(s.data.weights.first?.value, 88.4)
        XCTAssertEqual(s.todayWeight, 88.4)
    }

    func test_persistence() {
        let s = makeStore()
        s.add(source(s, "Eggs"), amount: 2)
        s.logWeight(90)
        s.logWaist(95)
        s.setGoal(170)
        s.toggleHabit(s.data.habits[0].id)
        let again = makeStore()
        XCTAssertEqual(again.data, s.data)
        XCTAssertEqual(again.data.goal, 170)
        XCTAssertTrue(again.isDone(again.data.habits[0].id))
    }

    func test_pruneOldEntries() {
        var d = RecompData()
        let old = RecompCalendar.adding(-100, to: startDay)
        let recent = RecompCalendar.adding(-80, to: startDay)
        let habit = d.habits[0].id
        d.entries = [
            ProteinEntry(at: RecompCalendar.date(of: old), name: "Eggs", unit: "egg", units: "eggs", amount: 1, gramsPerUnit: 6.5),
            ProteinEntry(at: RecompCalendar.date(of: recent), name: "Eggs", unit: "egg", units: "eggs", amount: 2, gramsPerUnit: 6.5),
        ]
        d.habitsDone = [old: [habit], recent: [habit]]
        d.weights = [Measure(day: old, value: 90)]
        d.waists = [Measure(day: old, value: 100)]
        defaults.set(try! JSONEncoder().encode(d), forKey: "recomp.v1")
        let s = makeStore()
        XCTAssertEqual(s.data.entries.count, 1)
        XCTAssertEqual(s.data.entries.first?.amount, 2)
        XCTAssertEqual(Array(s.data.habitsDone.keys), [recent])
        XCTAssertEqual(s.data.weights.count, 1)
        XCTAssertEqual(s.data.waists.count, 1)
    }

    func test_limits() {
        let s = makeStore()
        let nine = (0..<9).map { ProteinSource(name: "S\($0)", unit: "u", units: "us", gramsPerUnit: 1, step: 1) }
        s.saveSources(nine)
        XCTAssertEqual(s.data.sources.count, 7)
        s.rememberProduct(barcode: "1", name: "X", proteinPerPack: 10)
        XCTAssertFalse(s.addToSources(barcode: "1"))
        s.saveSources(Array(nine.prefix(3)))
        XCTAssertFalse(s.addToSources(barcode: "unknown"))
        XCTAssertTrue(s.addToSources(barcode: "1"))
        XCTAssertEqual(s.data.sources.count, 4)
        XCTAssertEqual(s.data.sources.last?.name, "X")
        s.saveHabits([Habit(title: ""), Habit(title: "A")])
        XCTAssertEqual(s.data.habits.map { $0.title }, ["A"])
        s.setGoal(10)
        XCTAssertEqual(s.data.goal, 100)
        s.setGoal(999)
        XCTAssertEqual(s.data.goal, 250)
    }

    func test_product() {
        let s = makeStore()
        s.rememberProduct(barcode: "4012345678901", name: "AH Kwark", proteinPerPack: 41)
        s.addProduct(barcode: "4012345678901", fraction: 0.5)
        let e = s.todayEntries[0]
        XCTAssertEqual(e.grams, 20.5, accuracy: 0.001)
        XCTAssertEqual(ProteinMath.amountLabel(e.amount, unit: e.unit, units: e.units), "½ pack")
    }

    func test_missingKeysUseDefaults() {
        let json = #"{"goal":150,"weights":[{"day":"2026-11-16","value":88.4}]}"#
        defaults.set(Data(json.utf8), forKey: "recomp.v1")
        let s = makeStore()
        XCTAssertEqual(s.data.goal, 150)
        XCTAssertEqual(s.data.weights, [Measure(day: "2026-11-16", value: 88.4)])
        XCTAssertEqual(s.data.sources.map { $0.name }, RecompDefaults.sources.map { $0.name })
        XCTAssertEqual(s.data.habits.map { $0.title }, RecompDefaults.habits.map { $0.title })
        XCTAssertNil(defaults.data(forKey: "recomp.v1.corrupt"))
    }

    func test_corruptKeepsBackup() {
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: "recomp.v1")
        let s = makeStore()
        XCTAssertEqual(s.data, RecompData())
        XCTAssertEqual(defaults.data(forKey: "recomp.v1.corrupt"), garbage)
    }

    func test_nonPositiveAmounts() {
        let s = makeStore()
        s.add(source(s, "Eggs"), amount: 0)
        s.add(source(s, "Eggs"), amount: -2)
        XCTAssertTrue(s.todayEntries.isEmpty)
        s.rememberProduct(barcode: "1", name: "X", proteinPerPack: 10)
        s.addProduct(barcode: "1", fraction: 0)
        s.addProduct(barcode: "1", fraction: -1)
        XCTAssertTrue(s.todayEntries.isEmpty)
        s.add(source(s, "Eggs"), amount: 3)
        let id = s.todayEntries[0].id
        s.setAmount(id, 0)
        XCTAssertTrue(s.todayEntries.isEmpty)
    }

    func test_addToSourcesNoDuplicate() {
        let s = makeStore()
        s.saveSources(Array(s.data.sources.prefix(3)))
        s.rememberProduct(barcode: "1", name: "X", proteinPerPack: 10)
        XCTAssertTrue(s.addToSources(barcode: "1"))
        XCTAssertFalse(s.addToSources(barcode: "1"))
        XCTAssertEqual(s.data.sources.count, 4)
    }

    // MARK: - Portions

    private let bread = "8712345678906"

    /// A product saved by 0.17.0 has no portion fields: it still loads, counted by the pack.
    func test_oldProductDecodes() throws {
        let json = #"{"goal":160,"products":{"8712345678906":{"name":"Brood","proteinPerPack":68}}}"#
        defaults.set(Data(json.utf8), forKey: "recomp.v1")
        let s = makeStore()
        let p = try XCTUnwrap(s.data.products[bread])
        XCTAssertEqual(p.name, "Brood")
        XCTAssertEqual(p.proteinPerPack, 68)
        XCTAssertNil(p.portionName)
        XCTAssertNil(p.proteinPerPortion)
        XCTAssertNil(p.portion)
        XCTAssertNil(defaults.data(forKey: "recomp.v1.corrupt"))
    }

    /// A portion field of the wrong type is dropped; the rest of the data still loads.
    func test_badPortionFieldsDecode() throws {
        let json = #"{"goal":150,"products":{"8712345678906":{"name":"Brood","proteinPerPack":68,"portionName":7,"proteinPerPortion":"x"}}}"#
        defaults.set(Data(json.utf8), forKey: "recomp.v1")
        let s = makeStore()
        XCTAssertEqual(s.data.goal, 150)
        let p = try XCTUnwrap(s.data.products[bread])
        XCTAssertEqual(p.proteinPerPack, 68)
        XCTAssertNil(p.portion)
        XCTAssertNil(defaults.data(forKey: "recomp.v1.corrupt"))
    }

    func test_addPortions() throws {
        let s = makeStore()
        s.rememberProduct(barcode: bread, name: "Grafschafter Sandwich", proteinPerPack: 67.5,
                          portion: Portion(name: "slice", protein: 3.6))
        s.addProductPortions(barcode: bread, count: 2)
        let e = try XCTUnwrap(s.todayEntries.first)
        XCTAssertEqual(e.name, "Grafschafter Sandwich")
        XCTAssertEqual(e.grams, 7.2, accuracy: 0.001)
        XCTAssertEqual(ProteinMath.amountLabel(e.amount, unit: e.unit, units: e.units), "2 slices")
        XCTAssertEqual(ProteinMath.amountLabel(1, unit: e.unit, units: e.units), "1 slice")
        // the pack still works too
        s.addProductPortions(barcode: bread, count: 0)
        s.addProductPortions(barcode: bread, count: -1)
        s.addProduct(barcode: bread, fraction: 0.25)
        XCTAssertEqual(s.todayEntries.count, 2)
        XCTAssertEqual(s.todayTotal, 7.2 + 16.875, accuracy: 0.001)
    }

    func test_portionsNeedAPortion() {
        let s = makeStore()
        s.rememberProduct(barcode: bread, name: "Brood", proteinPerPack: 68)
        s.addProductPortions(barcode: bread, count: 2)
        s.addProductPortions(barcode: "unknown", count: 2)
        XCTAssertTrue(s.todayEntries.isEmpty)
    }

    /// Counted by hand: 17 slices share the pack's 68 g. Remembered for the barcode, also after a restart.
    func test_rememberPortion() throws {
        let s = makeStore()
        s.rememberProduct(barcode: bread, name: "Brood", proteinPerPack: 68)
        let one = try XCTUnwrap(Portion.split(pack: 68, into: 17, name: "slice"))
        s.rememberPortion(barcode: bread, name: one.name, proteinPerPortion: one.protein)
        XCTAssertEqual(s.data.products[bread]?.portion, Portion(name: "slice", protein: 4))
        // can't be: ignored
        s.rememberPortion(barcode: bread, name: "slice", proteinPerPortion: 1000)
        s.rememberPortion(barcode: bread, name: "slice", proteinPerPortion: .infinity)
        s.rememberPortion(barcode: bread, name: "", proteinPerPortion: 4)
        s.rememberPortion(barcode: "unknown", name: "slice", proteinPerPortion: 4)
        XCTAssertEqual(s.data.products[bread]?.portion, Portion(name: "slice", protein: 4))
        XCTAssertNil(s.data.products["unknown"])
        XCTAssertEqual(makeStore().data.products[bread]?.portion, Portion(name: "slice", protein: 4))
    }

    /// Typing the pack's protein again keeps how it's counted.
    func test_correctingKeepsPortion() {
        let s = makeStore()
        s.rememberProduct(barcode: bread, name: "Brood", proteinPerPack: 68, portion: Portion(name: "slice", protein: 4))
        s.rememberProduct(barcode: bread, name: "Brood", proteinPerPack: 60)
        XCTAssertEqual(s.data.products[bread]?.proteinPerPack, 60)
        XCTAssertEqual(s.data.products[bread]?.portion, Portion(name: "slice", protein: 4))
    }

    func test_addToSourcesInPortions() throws {
        let s = makeStore()
        s.saveSources(Array(s.data.sources.prefix(3)))
        s.rememberProduct(barcode: bread, name: "Grafschafter Sandwich", proteinPerPack: 67.5,
                          portion: Portion(name: "slice", protein: 3.6))
        XCTAssertTrue(s.addToSources(barcode: bread))
        let src = try XCTUnwrap(s.data.sources.last)
        XCTAssertEqual(src.name, "Grafschafter Sandwich")
        XCTAssertEqual(src.unit, "slice")
        XCTAssertEqual(src.units, "slices")
        XCTAssertEqual(src.gramsPerUnit, 3.6, accuracy: 0.001)
        XCTAssertEqual(src.step, 1)
        XCTAssertEqual(src.barcode, bread)
        s.add(src, amount: 3)
        XCTAssertEqual(s.todayTotal, 10.8, accuracy: 0.001)
        // without a portion it's still packs
        s.rememberProduct(barcode: "1", name: "Kwark", proteinPerPack: 41)
        XCTAssertTrue(s.addToSources(barcode: "1"))
        XCTAssertEqual(s.data.sources.last?.unit, "pack")
        XCTAssertEqual(s.data.sources.last?.step, 0.25)
    }

    // MARK: - Calories

    func test_defaultKcal() {
        let s = makeStore()
        XCTAssertEqual(s.data.sources.map { $0.kcalPerUnit }, [280, 72, 115, 130, 250, 250, 120])
        XCTAssertEqual(s.kcalLimit, 2450)
        XCTAssertTrue(s.data.calories.followsWeight)
        XCTAssertTrue(s.data.calories.notify)
    }

    func test_kcalTotals() {
        let s = makeStore()
        s.add(source(s, "Eggs"), amount: 3)                 // 216
        s.add(source(s, "Kwark"), amount: 0.5)              // 140
        s.addOtherFood(name: "  ", kcal: 650)
        XCTAssertEqual(s.todayKcal, 1006, accuracy: 0.001)
        XCTAssertEqual(s.todayTotal, 19.5 + 21, accuracy: 0.001)     // other food has no protein
        let food = s.todayEntries.first { $0.isOtherFood }!
        XCTAssertEqual(food.name, "Other food")
        XCTAssertEqual(food.grams, 0)
        s.updateOtherFood(food.id, name: "Pizza", kcal: 800)
        XCTAssertEqual(s.todayKcal, 1156, accuracy: 0.001)
        XCTAssertEqual(s.todayEntries.first { $0.isOtherFood }?.name, "Pizza")
        // out of range: nothing
        s.addOtherFood(name: "x", kcal: 0)
        s.addOtherFood(name: "x", kcal: 3001)
        s.updateOtherFood(food.id, name: "x", kcal: 5000)
        XCTAssertEqual(s.todayKcal, 1156, accuracy: 0.001)
        // a changed amount changes its kcal
        let eggs = s.todayEntries.first { $0.name == "Eggs" }!
        s.setAmount(eggs.id, 2)
        XCTAssertEqual(s.todayKcal, 1156 - 72, accuracy: 0.001)
        // tomorrow starts at 0
        let tomorrow = RecompCalendar.date(of: RecompCalendar.adding(1, to: startDay))
        clock.date = RecompCalendar.calendar.date(bySettingHour: 4, minute: 0, second: 0, of: tomorrow)!
        XCTAssertEqual(s.todayKcal, 0)
    }

    /// An entry keeps the kcal it was logged with, like its grams.
    func test_entryKeepsItsKcal() {
        let s = makeStore()
        var eggs = source(s, "Eggs")
        s.add(eggs, amount: 2)
        eggs.kcalPerUnit = 90
        s.saveSources(s.data.sources.map { $0.name == "Eggs" ? eggs : $0 })
        XCTAssertEqual(s.todayKcal, 144, accuracy: 0.001)
        s.add(eggs, amount: 1)
        XCTAssertEqual(s.todayKcal, 234, accuracy: 0.001)
    }

    func test_productKcal() {
        let s = makeStore()
        // a pack of 1875 kcal; a slice of 100 kcal from Open Food Facts
        s.rememberProduct(barcode: bread, name: "Brood", proteinPerPack: 67.5, portion: Portion(name: "slice", protein: 3.6),
                          kcalPerPack: 1875, kcalPerPortion: 100)
        s.addProductPortions(barcode: bread, count: 2)
        s.addProduct(barcode: bread, fraction: 0.25)
        XCTAssertEqual(s.todayKcal, 200 + 468.75, accuracy: 0.001)
        // a slice counted by hand: its share of the pack
        s.rememberPortion(barcode: bread, name: "slice", proteinPerPortion: 67.5 / 15)
        XCTAssertEqual(try XCTUnwrap(s.data.products[bread]?.portionKcal), 125, accuracy: 0.001)
        // no kcal known: 0, and it still logs the protein
        s.rememberProduct(barcode: "1", name: "Kwark", proteinPerPack: 41)
        s.addProduct(barcode: "1", fraction: 1)
        XCTAssertEqual(s.todayKcal, 668.75, accuracy: 0.001)
        // typing the protein again without kcal keeps the kcal; a new kcal replaces it; 5001 is no kcal
        s.rememberProduct(barcode: bread, name: "Brood", proteinPerPack: 60)
        XCTAssertEqual(s.data.products[bread]?.kcalPerPack, 1875)
        s.rememberProduct(barcode: bread, name: "Brood", proteinPerPack: 60, kcalPerPack: 1500)
        XCTAssertEqual(s.data.products[bread]?.kcalPerPack, 1500)
        s.rememberProduct(barcode: "2", name: "X", proteinPerPack: 10, kcalPerPack: 5001)
        XCTAssertNil(s.data.products["2"]?.kcalPerPack)
    }

    func test_addToSourcesKeepsKcal() {
        let s = makeStore()
        s.saveSources(Array(s.data.sources.prefix(3)))
        s.rememberProduct(barcode: bread, name: "Brood", proteinPerPack: 67.5, portion: Portion(name: "slice", protein: 3.6),
                          kcalPerPack: 1875, kcalPerPortion: 100)
        s.rememberProduct(barcode: "1", name: "Kwark", proteinPerPack: 41, kcalPerPack: 300)
        XCTAssertTrue(s.addToSources(barcode: bread))
        XCTAssertEqual(s.data.sources.last?.kcalPerUnit, 100)
        XCTAssertTrue(s.addToSources(barcode: "1"))
        XCTAssertEqual(s.data.sources.last?.kcalPerUnit, 300)
    }

    /// For a product remembered before: only what's missing is filled in.
    func test_fillIn() {
        let s = makeStore()
        s.rememberProduct(barcode: bread, name: "Brood", proteinPerPack: 67.5)
        s.fillIn(barcode: bread, portion: Portion(name: "slice", protein: 3.6), energy: Energy(perPack: 1875, perPortion: 100))
        XCTAssertEqual(s.data.products[bread]?.portion, Portion(name: "slice", protein: 3.6))
        XCTAssertEqual(s.data.products[bread]?.kcalPerPack, 1875)
        XCTAssertEqual(s.data.products[bread]?.kcalPerPortion, 100)
        // counted already: kept
        s.fillIn(barcode: bread, portion: Portion(name: "piece", protein: 5), energy: Energy(perPack: 1000, perPortion: 1))
        XCTAssertEqual(s.data.products[bread]?.portion, Portion(name: "slice", protein: 3.6))
        XCTAssertEqual(s.data.products[bread]?.kcalPerPack, 1875)
        // not a part of the pack as remembered: no portion
        s.rememberProduct(barcode: "1", name: "Yoghurt", proteinPerPack: 5)
        s.fillIn(barcode: "1", portion: Portion(name: "portion", protein: 5), energy: Energy())
        XCTAssertNil(s.data.products["1"]?.portion)
        s.fillIn(barcode: "unknown", portion: Portion(name: "slice", protein: 1), energy: Energy(perPack: 10))
        XCTAssertNil(s.data.products["unknown"])
    }

    /// The limit notice: once, on the add that reaches the limit; again the next day; never when it's off.
    func test_limitNoticeOncePerDay() {
        let s = makeStore()
        var notices: [String] = []
        s.limitReached = { total, limit, day in notices.append("\(Int(total))/\(Int(limit)) \(day)") }
        s.addOtherFood(name: "", kcal: 2000)
        XCTAssertTrue(notices.isEmpty)
        s.addOtherFood(name: "", kcal: 480)
        XCTAssertEqual(notices, ["2480/2450 \(startDay)"])
        s.addOtherFood(name: "", kcal: 300)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(s.data.calories.notifiedOn, startDay)
        // after a restart, still once
        let again = makeStore()
        again.limitReached = { _, _, _ in notices.append("again") }
        again.addOtherFood(name: "", kcal: 100)
        XCTAssertEqual(notices.count, 1)
        // the next day
        clock.date = clock.date.addingTimeInterval(24 * 3600)
        again.addOtherFood(name: "", kcal: 2500)
        XCTAssertEqual(notices.last, "again")
        // switched off
        clock.date = clock.date.addingTimeInterval(24 * 3600)
        again.setKcalNotify(false)
        again.addOtherFood(name: "", kcal: 2500)
        XCTAssertEqual(notices.count, 2)
    }

    private func weighIn(_ store: RecompStore, _ kg: Double, daysAgo: Int) {
        let keep = clock.date
        clock.date = keep.addingTimeInterval(Double(-daysAgo) * 24 * 3600)
        store.logWeight(kg)
        clock.date = keep
    }

    /// The anchor is the first week average there is; set by hand it starts again from today's.
    func test_limitAnchors() {
        let s = makeStore()
        XCTAssertNil(s.data.calories.anchorWeight)
        XCTAssertEqual(s.kcalLimit, 2450)
        s.logWeight(88)
        XCTAssertEqual(s.data.calories.anchorWeight, 88)
        XCTAssertEqual(s.kcalLimit, 2450)
        // a week later at 85: 2400
        clock.date = clock.date.addingTimeInterval(7 * 24 * 3600)
        s.logWeight(85)
        XCTAssertEqual(s.kcalLimit, 2400)
        // set by hand: 2600 now, moving from 85
        s.setKcalLimit(2600)
        XCTAssertEqual(s.data.calories.anchorLimit, 2600)
        XCTAssertEqual(s.data.calories.anchorWeight, 85)
        XCTAssertEqual(s.kcalLimit, 2600)
        clock.date = clock.date.addingTimeInterval(7 * 24 * 3600)
        s.logWeight(91)                                   // +6 kg: +90
        XCTAssertEqual(s.kcalLimit, 2700)
        // switched off: it stays where it is
        s.setKcalFollowsWeight(false)
        XCTAssertEqual(s.kcalLimit, 2700)
        clock.date = clock.date.addingTimeInterval(7 * 24 * 3600)
        s.logWeight(80)
        XCTAssertEqual(s.kcalLimit, 2700)
        // by hand, rounded to 50 and kept inside 1200…5000
        s.setKcalLimit(2437)
        XCTAssertEqual(s.kcalLimit, 2450)
        s.setKcalLimit(9000)
        XCTAssertEqual(s.kcalLimit, 5000)
    }

    /// No weigh-ins: the limit is the anchor, and setting it by hand leaves no anchor weight.
    func test_limitWithoutWeekAverage() {
        let s = makeStore()
        s.setKcalLimit(2200)
        XCTAssertNil(s.data.calories.anchorWeight)
        XCTAssertEqual(s.kcalLimit, 2200)
        s.logWeight(90)
        XCTAssertEqual(s.data.calories.anchorWeight, 90)
        XCTAssertEqual(s.kcalLimit, 2200)
    }

    /// "Done, I've adjusted" moves the anchor 200 down for "eat less" and 200 up for "eat more", toggle or not.
    func test_adjustedMovesLimit() {
        for (kind, want) in [(AdviceKind.eatLess, 2250.0), (.eatMore, 2650.0)] {
            defaults = UserDefaults(suiteName: UUID().uuidString)!
            var d = RecompData()
            d.check.pending = PendingAdvice(kind: kind, shownOn: startDay)
            d.calories.followsWeight = kind == .eatMore
            defaults.set(try! JSONEncoder().encode(d), forKey: "recomp.v1")
            let s = makeStore()
            s.markAdjusted()
            XCTAssertEqual(s.data.calories.anchorLimit, want)
            XCTAssertEqual(s.kcalLimit, want)
            XCTAssertNil(s.data.check.pending)
            s.markAdjusted()                                // nothing pending any more: no second move
            XCTAssertEqual(s.data.calories.anchorLimit, want)
        }
    }

    /// Data from 0.17.0: no calories anywhere. Default sources get their kcal, others 0; the limit is the default.
    func test_oldDataWithoutCalories() throws {
        let json = #"""
        {"goal":160,
         "sources":[{"name":"Eggs","unit":"egg","units":"eggs","gramsPerUnit":6.5,"step":1},
                    {"name":"Skyr","unit":"cup","units":"cups","gramsPerUnit":15,"step":1}],
         "entries":[{"at":0,"name":"Eggs","unit":"egg","units":"eggs","amount":2,"gramsPerUnit":6.5},
                    {"at":0,"name":"AH Kwark","unit":"pack","units":"packs","amount":1,"gramsPerUnit":41}],
         "products":{"8712345678906":{"name":"Brood","proteinPerPack":68}}}
        """#
        defaults.set(Data(json.utf8), forKey: "recomp.v1")
        let s = makeStore()
        XCTAssertNil(defaults.data(forKey: "recomp.v1.corrupt"))
        XCTAssertEqual(s.data.sources.map { $0.kcalPerUnit }, [72, 0])
        XCTAssertEqual(s.data.calories, CalorieSettings())
        XCTAssertEqual(s.kcalLimit, 2450)
        XCTAssertNil(s.data.products[bread]?.kcalPerPack)
        XCTAssertNil(s.data.products[bread]?.portionKcal)
        // decoded straight, so the 90-day pruning doesn't drop the old entries
        let d = try JSONDecoder().decode(RecompData.self, from: Data(json.utf8))
        XCTAssertEqual(d.entries.map { $0.kcalPerUnit }, [72, 0])
    }

    /// A calories value of the wrong type is the defaults; the rest still loads.
    func test_badCaloriesDecode() {
        let json = #"{"goal":150,"calories":{"anchorLimit":"x","followsWeight":"yes","notify":false}}"#
        defaults.set(Data(json.utf8), forKey: "recomp.v1")
        let s = makeStore()
        XCTAssertEqual(s.data.goal, 150)
        XCTAssertEqual(s.data.calories.anchorLimit, 2450)
        XCTAssertTrue(s.data.calories.followsWeight)
        XCTAssertFalse(s.data.calories.notify)
        let broken = #"{"goal":150,"calories":7}"#
        defaults.set(Data(broken.utf8), forKey: "recomp.v1")
        XCTAssertEqual(makeStore().data.calories, CalorieSettings())
        XCTAssertNil(defaults.data(forKey: "recomp.v1.corrupt"))
    }

    func test_caloriesPersist() {
        let s = makeStore()
        s.setKcalLimit(2300)
        s.setKcalNotify(false)
        s.addOtherFood(name: "Soup", kcal: 250)
        let again = makeStore()
        XCTAssertEqual(again.data.calories, s.data.calories)
        XCTAssertEqual(again.todayKcal, 250, accuracy: 0.001)
        XCTAssertEqual(again.kcalLimit, 2300)
    }
}
