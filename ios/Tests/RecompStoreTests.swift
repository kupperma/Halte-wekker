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
}
