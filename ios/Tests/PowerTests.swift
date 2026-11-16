import XCTest

final class PowerTests: XCTestCase {
    /// The speed on screen changes only when it's worth drawing again, not on every fix.
    func test_speedPublish() {
        XCTAssertFalse(SpeedPublish.worth(old: nil, new: nil))
        XCTAssertTrue(SpeedPublish.worth(old: nil, new: 0))
        XCTAssertTrue(SpeedPublish.worth(old: 3, new: nil))
        XCTAssertFalse(SpeedPublish.worth(old: 8.2, new: 8.5))
        XCTAssertTrue(SpeedPublish.worth(old: 8.2, new: 8.7))
        XCTAssertTrue(SpeedPublish.worth(old: 0.9, new: 1.1))            // "standing still" ⇄ a speed on the ride screen
        XCTAssertFalse(SpeedPublish.worth(old: 0.2, new: 0.6))
    }

    /// The regions iOS watches already are left alone when they're the ones wanted; any difference registers them again.
    func test_regionsSame() {
        let a = [RegionSpec(id: "school", lat: 51.59, lon: 4.78, radius: 400, entry: true, exit: false),
                 RegionSpec(id: "veghel", lat: 51.61, lon: 5.54, radius: 350, entry: false, exit: true)]
        XCTAssertTrue(RegionPlan.same(wanted: a, current: a.reversed()))
        XCTAssertTrue(RegionPlan.same(wanted: [], current: []))
        XCTAssertFalse(RegionPlan.same(wanted: a, current: [a[0]]))
        XCTAssertFalse(RegionPlan.same(wanted: [], current: [a[0]]))
        var moved = a; moved[1] = RegionSpec(id: "veghel", lat: 51.62, lon: 5.54, radius: 350, entry: false, exit: true)
        XCTAssertFalse(RegionPlan.same(wanted: a, current: moved))
        var wider = a; wider[1] = RegionSpec(id: "veghel", lat: 51.61, lon: 5.54, radius: 300, entry: false, exit: true)
        XCTAssertFalse(RegionPlan.same(wanted: a, current: wider))
        var told = a; told[0] = RegionSpec(id: "school", lat: 51.59, lon: 4.78, radius: 400, entry: true, exit: true)
        XCTAssertFalse(RegionPlan.same(wanted: a, current: told))
        let unknown = RegionSpec(id: "school", lat: .nan, lon: .nan, radius: -1, entry: true, exit: false)
        XCTAssertFalse(RegionPlan.same(wanted: [a[0]], current: [unknown]))
        XCTAssertFalse(RegionPlan.same(wanted: a, current: [a[0], a[0]]))         // the same id twice
    }
}
