import XCTest

/// 0.42.4: "The platform changed but it didn't send a notification" (`PlatformWatch`).
final class PlatformWatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 8_000_000)
    private func at(_ min: Double) -> Date { now.addingTimeInterval(min * 60) }

    func test_aTrainAsTheSecondRide_isWatched() {
        // bus 305 from Veghel, then the Intercity at Eindhoven
        let legs = [PlatformWatch.Leg(train: false, num: "", code: nil, planned: at(10)),
                    PlatformWatch.Leg(train: true, num: "3561", code: "EHV", planned: at(45))]
        XCTAssertEqual(PlatformWatch.toWatch(legs, now: now), [1])
    }

    func test_everyTrain_withinThreeHours_fromAnNSStation() {
        let legs = [PlatformWatch.Leg(train: true, num: "1", code: "EHV", planned: at(20)),
                    PlatformWatch.Leg(train: true, num: "2", code: "HT", planned: at(70)),
                    PlatformWatch.Leg(train: true, num: "3", code: nil, planned: at(90)),        // not an NS station
                    PlatformWatch.Leg(train: true, num: "4", code: "BD", planned: at(200)),      // over 3 hours
                    PlatformWatch.Leg(train: true, num: "5", code: "UT", planned: at(-15))]      // left 15 min ago
        XCTAssertEqual(PlatformWatch.toWatch(legs, now: now), [0, 1])
        XCTAssertEqual(PlatformWatch.toWatch([PlatformWatch.Leg(train: true, num: "6", code: "UT", planned: at(-5))], now: now), [0])
    }

    func test_thePlansPlatformSeedsTheWatch() {
        XCTAssertEqual(PlatformWatch.seed(planned: "5", live: "7"), "5")
        XCTAssertEqual(PlatformWatch.seed(planned: nil, live: "7"), "7")
        XCTAssertEqual(PlatformWatch.seed(planned: " ", live: nil), "")
    }

    func test_aChangeBeforeTheFirstNSAnswer_isTold() {
        // seeded from the plan: NS's first answer already says 7
        XCTAssertEqual(PlatformWatch.change(track: "5", live: "7", nsPlanned: "5"), .moved(was: "5", now: "7"))
        // nothing from the plan: NS's own planned platform is what it was
        XCTAssertEqual(PlatformWatch.change(track: "", live: "7", nsPlanned: "5"), .moved(was: "5", now: "7"))
        // nothing to compare with: filled in quietly
        XCTAssertEqual(PlatformWatch.change(track: "", live: "7", nsPlanned: ""), .fill("7"))
        XCTAssertEqual(PlatformWatch.change(track: "", live: "7", nsPlanned: "7"), .fill("7"))
    }

    func test_noChange_noAlert() {
        XCTAssertEqual(PlatformWatch.change(track: "5", live: "5", nsPlanned: "5"), .none)
        XCTAssertEqual(PlatformWatch.change(track: "5", live: "", nsPlanned: "5"), .none)
        // the plan often leaves the part letter out
        XCTAssertEqual(PlatformWatch.change(track: "5", live: "5b", nsPlanned: "5b"), .none)
        XCTAssertEqual(PlatformWatch.change(track: "5a", live: "5b", nsPlanned: "5a"), .moved(was: "5a", now: "5b"))
        XCTAssertEqual(PlatformWatch.change(track: "15", live: "5", nsPlanned: "15"), .moved(was: "15", now: "5"))
    }

    func test_asleep_quietNow_chimeLater() {
        XCTAssertEqual(PlatformWatch.delivery(asleep: true), .quietNowChimeLater)
        XCTAssertEqual(PlatformWatch.delivery(asleep: false), .now)
    }

    func test_logLine() {
        XCTAssertEqual(PlatformWatch.logLine(label: "08:02 Intercity to Breda", from: "Eindhoven", was: "5", now: "7", cancelled: false),
                       "platform · 08:02 Intercity to Breda at Eindhoven: 7 (was 5)")
        XCTAssertEqual(PlatformWatch.logLine(label: "08:02 Intercity to Breda", from: "Eindhoven", was: "", now: "", cancelled: true),
                       "platform · 08:02 Intercity to Breda at Eindhoven: cancelled")
    }
}
