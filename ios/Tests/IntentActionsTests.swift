import XCTest

/// 0.37: Siri, Shortcuts and the widget's tap — what each asks of the app, and that nothing gets past a running trip.
final class IntentActionsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    func test_widgetLinkOpensTheStop() throws {
        let s = StopBoardCore.Stop(id: "nl_1", name: "Veghel, Busstation", lat: 51.6, lon: 5.5)
        let url = try XCTUnwrap(StopBoardCore.link(s))
        guard case .showStop(let back)? = IntentActions.action(url) else { return XCTFail("not the stop") }
        XCTAssertEqual(back.id, "nl_1")
        XCTAssertNil(IntentActions.action(URL(string: "haltewekker://friend?v=1&k=x")!), "a friend link is the friends' own")
        XCTAssertNil(IntentActions.action(URL(string: "haltewekker://spotify?code=1")!))
    }

    func test_nothingStartsOverARunningTrip() {
        let s = StopBoardCore.Stop(id: "x", name: "X", lat: 1, lon: 1)
        XCTAssertEqual(IntentActions.outcome(.showStop(s), idle: false), .go, "looking at a stop is fine")
        for a in [IntentActions.Action.wake(s), .fastest(toSchool: true), .startTrip] {
            XCTAssertEqual(IntentActions.outcome(a, idle: true), .go)
            guard case .refuse = IntentActions.outcome(a, idle: false) else { return XCTFail("\(a) went past a running trip") }
        }
    }

    func test_startMyTrip() {
        XCTAssertEqual(IntentActions.start(idle: false, departure: at(1), now: t0), .alreadyRunning)
        XCTAssertEqual(IntentActions.start(idle: true, departure: nil, now: t0), .openFastest)
        XCTAssertEqual(IntentActions.start(idle: true, departure: at(3), now: t0), .startNow, "at the stop")
        XCTAssertEqual(IntentActions.start(idle: true, departure: at(-10), now: t0), .startNow, "on it")
        XCTAssertEqual(IntentActions.start(idle: true, departure: at(4), now: t0), .openPlanned, "still to leave for: it watches")
        XCTAssertEqual(IntentActions.start(idle: true, departure: at(-16), now: t0), .openFastest, "long gone")
        XCTAssertNil(IntentActions.startText(.startNow))
        XCTAssertNotNil(IntentActions.startText(.openPlanned))
    }

    func test_whichStopForWhensMyBus() {
        XCTAssertEqual(IntentActions.busFrom(metresFromHome: 200, haveHomeStop: true), .home)
        XCTAssertEqual(IntentActions.busFrom(metresFromHome: nil, haveHomeStop: true), .home, "no fix: the home stop")
        XCTAssertEqual(IntentActions.busFrom(metresFromHome: 2_000, haveHomeStop: true), .nearest)
        XCTAssertEqual(IntentActions.busFrom(metresFromHome: 100, haveHomeStop: false), .nearest)
    }
}
