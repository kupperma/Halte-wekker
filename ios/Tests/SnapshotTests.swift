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
        lists.shown("trains", at: t0)
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

    /// Saved and kept lists are labelled, and saved, with the oldest time among the lists that show something; an
    /// empty answer keeps a list's rows and their time, so they're never re-dated.
    func test_oldestTimeAmongLists() {
        var lists = LiveLists<String>()
        let saved = t0.addingTimeInterval(-3600)
        lists.restored("trains", at: saved)
        lists.restored("buas", at: saved)
        XCTAssertEqual(lists.asOf(["trains", "buas"]), saved)
        lists.shown("trains", at: t0)                                  // trains came in; buas' answer was empty
        XCTAssertEqual(lists.oldest(["trains", "buas"]), saved)
        XCTAssertEqual(lists.asOf(["trains", "buas"]), saved)          // still a saved list: labelled as of the oldest
        lists.shown("buas", at: t0.addingTimeInterval(120))
        XCTAssertNil(lists.asOf(["trains", "buas"]))                   // all live: no label
        XCTAssertEqual(lists.oldest(["trains", "buas"]), t0)           // …and saved as of the oldest list, not of now
        lists.reset()                                                   // another key: kept, as of when they came in
        XCTAssertEqual(lists.asOf(["trains", "buas"]), t0)
        XCTAssertNil(lists.asOf([]))
        lists.restored("buas", at: nil)
        XCTAssertEqual(lists.oldest(["trains"]), t0)
    }

    func test_boardTimeKeepsTheOlderTimeWhileRowsAreKept() {
        let before = t0.addingTimeInterval(-600)
        XCTAssertEqual(Snapshots.boardTime(previous: before, now: t0, keptOld: false), t0)
        XCTAssertEqual(Snapshots.boardTime(previous: before, now: t0, keptOld: true), before)
        XCTAssertEqual(Snapshots.boardTime(previous: nil, now: t0, keptOld: true), t0)
    }

    /// Two keys can share a file name: the key saved inside decides, and another key's answer is deleted.
    func test_keyCheckedOnLoad() {
        XCTAssertEqual(SnapshotStore.fileName("next|a:b"), SnapshotStore.fileName("next|a_b"))
        store.save(deps([60]), key: "next|a:b", at: t0)
        XCTAssertEqual(store.load([Dep].self, key: "next|a:b", now: t0)?.key, "next|a:b")
        XCTAssertNil(store.load([Dep].self, key: "next|a_b", now: t0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(SnapshotStore.fileName("next|a_b")).path))
        XCTAssertNil(store.load([Dep].self, key: "next|a:b", now: t0))
    }

    func test_expiredDeletedOnLoad() {
        let key = "near"
        store.save(deps([60]), key: key, at: t0)
        XCTAssertNil(store.load([Dep].self, key: key, maxAge: 60, now: t0.addingTimeInterval(61)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(SnapshotStore.fileName(key)).path))
        store.save(deps([60]), key: key, at: t0.addingTimeInterval(120))          // a minute and more ahead of the clock
        XCTAssertNil(store.load([Dep].self, key: key, now: t0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(SnapshotStore.fileName(key)).path))
    }

    func test_pruneOldFiles() throws {
        store.save(deps([60]), key: "old", at: t0)
        store.save(deps([60]), key: "recent", at: t0)
        let other = dir.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: other)
        let fm = FileManager.default
        let week = 7 * 24 * 3600.0
        try fm.setAttributes([.modificationDate: t0.addingTimeInterval(-week - 3600)], ofItemAtPath: dir.appendingPathComponent(SnapshotStore.fileName("old")).path)
        try fm.setAttributes([.modificationDate: t0.addingTimeInterval(-24 * 3600)], ofItemAtPath: dir.appendingPathComponent(SnapshotStore.fileName("recent")).path)
        try fm.setAttributes([.modificationDate: t0.addingTimeInterval(-week - 3600)], ofItemAtPath: other.path)
        store.prune(olderThan: week, now: t0)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(SnapshotStore.fileName("old")).path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(SnapshotStore.fileName("recent")).path))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
        store.prune(olderThan: week, now: t0)                                   // nothing left to prune: no harm
        SnapshotStore(directory: dir.appendingPathComponent("missing")).prune(olderThan: week, now: t0)
    }
}
