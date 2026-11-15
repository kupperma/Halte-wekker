import XCTest

private struct Dep: Codable, Equatable {
    let id: String
    let time: Date
}

final class SnapshotTests: XCTestCase {
    private var dir: URL!
    private var store: SnapshotStore!
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("answers-\(UUID().uuidString)", isDirectory: true)
        store = SnapshotStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func deps(_ offsets: [TimeInterval]) -> [Dep] {
        offsets.enumerated().map { Dep(id: "d\($0.offset)", time: t0.addingTimeInterval($0.element)) }
    }

    func test_roundTripAndAge() {
        let saved = deps([60, 120, 180])
        store.save(saved, key: "next|toSchool||usual", at: t0)
        let s = store.load([Dep].self, key: "next|toSchool||usual", now: t0.addingTimeInterval(30))
        XCTAssertEqual(s?.at, t0)
        XCTAssertEqual(s?.value.count, 3)
        XCTAssertEqual(s?.value, saved)
        XCTAssertNil(store.load([Dep].self, key: "next|toSchool||usual", maxAge: 60, now: t0.addingTimeInterval(61)))
    }

    func test_firstPaintFiltersDeparted() {
        store.save(deps([-120, 60, 300]), key: "panels|toSchool", at: t0)
        let started = Date()
        let s = store.load([Dep].self, key: "panels|toSchool", now: t0)
        let shown = Snapshots.upcoming(s?.value ?? [], now: t0) { $0.time }
        let took = Date().timeIntervalSince(started)
        XCTAssertEqual(shown.map(\.id), ["d1", "d2"])
        XCTAssertEqual(s?.at, t0)
        XCTAssertLessThan(took, 0.1)
    }

    func test_fileName() {
        XCTAssertEqual(SnapshotStore.fileName("next|toSchool||here"), "next_toSchool__here.json")
        XCTAssertEqual(SnapshotStore.fileName(String(repeating: "x", count: 300)).count, 125)
    }

    func test_corruptSnapshotIgnored() throws {
        let key = "next|toSchool||usual"
        let url = dir.appendingPathComponent(SnapshotStore.fileName(key))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(store.load([Dep].self, key: key, now: t0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // an older format: good JSON, another shape
        try Data(#"{"at": 800000000, "value": {"trips": 3}}"#.utf8).write(to: url)
        XCTAssertNil(store.load([Dep].self, key: key, now: t0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // and then it's as if nothing was saved: a new answer saves and loads
        store.save(deps([60]), key: key, at: t0)
        XCTAssertEqual(store.load([Dep].self, key: key, now: t0)?.value.count, 1)
    }

    func test_asOf() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let at = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 7, minute: 12)))
        let amsterdam = try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam"))
        XCTAssertEqual(Snapshots.asOf(at, timeZone: amsterdam), "as of 08:12")
    }

    func test_onKeyChange() {
        let usual = PlanKey(dir: "toSchool", dest: "", fromHere: false)
        let here = PlanKey(dir: "toSchool", dest: "", fromHere: true)
        XCTAssertEqual(usual.text, "toSchool||usual")
        XCTAssertEqual(here.text, "toSchool||here")
        XCTAssertEqual(Snapshots.onKeyChange(from: nil, to: usual, hasSaved: true), .showSaved)
        XCTAssertEqual(Snapshots.onKeyChange(from: nil, to: usual, hasSaved: false), .clear)
        XCTAssertEqual(Snapshots.onKeyChange(from: usual, to: here, hasSaved: false), .keep)
        XCTAssertEqual(Snapshots.onKeyChange(from: here, to: usual, hasSaved: true), .showSaved)
        XCTAssertEqual(Snapshots.onKeyChange(from: usual, to: PlanKey(dir: "home", dest: "", fromHere: false), hasSaved: false), .clear)
        XCTAssertEqual(Snapshots.onKeyChange(from: PlanKey(dir: "toSchool", dest: "a", fromHere: true),
                                             to: PlanKey(dir: "toSchool", dest: "b", fromHere: true), hasSaved: false), .clear)
    }

    func test_closeEnough() {
        let a = (lat: 51.59, lon: 4.78)
        let north250 = (lat: a.lat + 250 / 110_540.0, lon: a.lon)
        let east450 = (lat: a.lat, lon: a.lon + 450 / (cos(a.lat * .pi / 180) * 111_320))
        XCTAssertTrue(Snapshots.closeEnough(saved: nil, here: a, metres: 300))
        XCTAssertTrue(Snapshots.closeEnough(saved: nil, here: nil, metres: 300))
        XCTAssertTrue(Snapshots.closeEnough(saved: a, here: north250, metres: 300))
        XCTAssertFalse(Snapshots.closeEnough(saved: a, here: east450, metres: 400))
        XCTAssertFalse(Snapshots.closeEnough(saved: a, here: nil, metres: 300))
    }

    /// A saved list, or one kept from another planning key, takes the first live rows; a live one waits for the whole answer.
    func test_partialFillsOnlyWhatIsNotLive() {
        var lists = LiveLists<String>()
        XCTAssertTrue(lists.takesPartial("trains", empty: false))
        XCTAssertTrue(lists.anyStale(["trains"]))
        lists.shown("trains")
        XCTAssertTrue(lists.isLive("trains"))
        XCTAssertFalse(lists.takesPartial("trains", empty: false))
        XCTAssertTrue(lists.takesPartial("trains", empty: true))
        XCTAssertTrue(lists.takesPartial("buas", empty: false))
        XCTAssertFalse(lists.anyStale(["trains"]))
        XCTAssertTrue(lists.anyStale(["trains", "buas"]))
        lists.reset()
        XCTAssertFalse(lists.isLive("trains"))
        XCTAssertTrue(lists.takesPartial("trains", empty: false))
    }
}
