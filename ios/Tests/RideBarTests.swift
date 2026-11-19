import XCTest

/// The ride made smaller (0.26.1): the bar's words.
final class RideBarTests: XCTestCase {
    func test_wake() {
        XCTAssertEqual(RideBar.wake(awake: true, waitingToBoard: true, vehicleKnown: true, byLocation: false, asked: true), .question)
        XCTAssertEqual(RideBar.wake(awake: false, waitingToBoard: true, vehicleKnown: false, byLocation: false, asked: false), .boarding)
        XCTAssertEqual(RideBar.wake(awake: false, waitingToBoard: false, vehicleKnown: false, byLocation: false, asked: false), .finding)
        XCTAssertEqual(RideBar.wake(awake: false, waitingToBoard: false, vehicleKnown: false, byLocation: true, asked: false), .sleeping)
        XCTAssertEqual(RideBar.wake(awake: false, waitingToBoard: false, vehicleKnown: true, byLocation: false, asked: false), .sleeping)
        XCTAssertEqual(RideBar.wake(awake: true, waitingToBoard: false, vehicleKnown: true, byLocation: false, asked: false), .awake)
        XCTAssertEqual(RideBar.wakeText(.sleeping, ringAtStop: true), "Wakes you before your stop")
        XCTAssertEqual(RideBar.wakeText(.awake, ringAtStop: false), "You’re awake")
    }

    func test_words() {
        XCTAssertEqual(RideBar.title(vehicle: "Bus 305", to: "Uden"), "Bus 305 to Uden")
        XCTAssertEqual(RideBar.title(vehicle: nil, to: "Uden"), "To Uden")
        XCTAssertEqual(RideBar.title(vehicle: nil, to: ""), "Your trip")
        let c = RideAhead.Countdown(value: "12", unit: "min", spoken: "12 minutes")
        XCTAssertEqual(RideBar.detail(next: "Veghel, Busstation", yours: false, countdown: c), "Next: Veghel, Busstation · 12 min")
        XCTAssertEqual(RideBar.detail(next: "Uden", yours: true, countdown: c), "12 min")
        XCTAssertEqual(RideBar.detail(next: nil, yours: false, countdown: nil), "")
        XCTAssertEqual(RideBar.spoken(title: "Bus 305 to Uden", next: "Zeeland", yours: false, countdown: c, wake: "Wakes you before your stop"),
                       "Bus 305 to Uden, 12 minutes to go, next stop Zeeland, Wakes you before your stop")
    }

    func test_smallForThisTripOnly() {
        XCTAssertTrue(RideBar.keepsSmall(true, rideOn: true, alarm: false))
        XCTAssertFalse(RideBar.keepsSmall(true, rideOn: true, alarm: true))      // the alarm takes the screen
        XCTAssertFalse(RideBar.keepsSmall(true, rideOn: false, alarm: false))    // the trip is over: the next one opens full
        XCTAssertFalse(RideBar.keepsSmall(false, rideOn: true, alarm: false))
    }
}
