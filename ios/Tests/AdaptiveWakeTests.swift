import XCTest

/// 0.39: the adaptive wake-up: learned per mode from how soon you stop the alarm, only ever earlier, a minute at a time,
/// within bounds, outliers ignored.
final class AdaptiveWakeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func ride(_ train: Bool, react: Double?, lead: Double, _ k: Int = 0) -> WakeSample {
        WakeSample(train: train, react: react, lead: lead, at: t0.addingTimeInterval(Double(k) * 86_400))
    }

    func test_nothingMovesBeforeThreeRides() {
        var b = WakeBook()
        XCTAssertFalse(b.add(ride(true, react: 150, lead: 180)))
        XCTAssertFalse(b.add(ride(true, react: 150, lead: 180, 1)))
        XCTAssertEqual(b.trainExtra, 0)
        XCTAssertEqual(AdaptiveWake.summary(b, by: .time), "Learning: 1 more ride")
    }

    func test_shortOfTimeAgainMovesItAMinuteEarlier() {
        var b = WakeBook()
        // 30 s left after stopping it, three times: one minute earlier on trains, buses as they were
        for k in 0..<3 { b.add(ride(true, react: 150, lead: 180, k)) }
        XCTAssertEqual(b.trainExtra, 1)
        XCTAssertEqual(b.busExtra, 0)
        XCTAssertEqual(AdaptiveWake.summary(b, by: .time), "Learned: wakes you 1 min earlier on trains")
        // a step per ride, never past the bound
        for k in 3..<12 { b.add(ride(true, react: 170, lead: 180, k)) }
        XCTAssertEqual(b.trainExtra, AdaptiveWake.maxTrain)
    }

    func test_arrivingStillRingingCountsAsNoTime() {
        var b = WakeBook()
        for k in 0..<3 { b.add(ride(false, react: nil, lead: 120, k)) }
        XCTAssertEqual(b.busExtra, 1)
        for k in 3..<10 { b.add(ride(false, react: nil, lead: 120, k)) }
        XCTAssertEqual(b.busExtra, AdaptiveWake.maxBus, "2 at most on a bus")
    }

    func test_plentyOfRoomBringsItBackButNeverLaterThanYourSetting() {
        var b = WakeBook()
        for k in 0..<3 { b.add(ride(true, react: 150, lead: 180, k)) }
        XCTAssertEqual(b.trainExtra, 1)
        // up at once with 5 minutes to spare: back a minute at a time, to your setting and no further
        for k in 3..<15 { b.add(ride(true, react: 10, lead: 310, k)) }
        XCTAssertEqual(b.trainExtra, 0)
        var s = WakeSettings(); s.trainMinutes = 3; s.busMinutes = 2
        XCTAssertEqual(AdaptiveWake.effective(s, b).trainMinutes, 3)
    }

    func test_oneOddRideDoesNotMoveIt() {
        var b = WakeBook()
        for k in 0..<4 { b.add(ride(true, react: 20, lead: 180, k)) }     // 160 s spare: fine as it is
        XCTAssertFalse(b.add(ride(true, react: nil, lead: 180, 5)))       // once there still ringing
        XCTAssertEqual(b.trainExtra, 0)
    }

    func test_outliersAreIgnored() {
        XCTAssertFalse(AdaptiveWake.valid(ride(true, react: 5, lead: 10)), "rang 10 s before: GPS, not you")
        XCTAssertFalse(AdaptiveWake.valid(ride(true, react: 5, lead: 25 * 60)), "rang 25 min before: a train held up")
        XCTAssertFalse(AdaptiveWake.valid(ride(true, react: 900, lead: 200)), "stopped long after the stop")
        XCTAssertFalse(AdaptiveWake.valid(ride(true, react: -1, lead: 200)))
        XCTAssertTrue(AdaptiveWake.valid(ride(true, react: nil, lead: 200)))
        var b = WakeBook()
        for k in 0..<5 { b.add(ride(true, react: 5, lead: 10, k)) }
        XCTAssertTrue(b.samples.isEmpty)
        XCTAssertEqual(b.trainExtra, 0)
    }

    func test_effectiveOnlyEverAddsAndOffIsYourSetting() {
        var s = WakeSettings(); s.trainMinutes = 3; s.busMinutes = 2
        var b = WakeBook(); b.trainExtra = 2; b.busExtra = 9
        let e = AdaptiveWake.effective(s, b)
        XCTAssertEqual(e.trainMinutes, 5)
        XCTAssertEqual(e.busMinutes, 4, "bounded: 2 at most on a bus")
        b.trainExtra = -4
        XCTAssertEqual(AdaptiveWake.effective(s, b).trainMinutes, 3, "never later than your setting")
        b.on = false; b.trainExtra = 2
        XCTAssertEqual(AdaptiveWake.effective(s, b), s)
        XCTAssertEqual(AdaptiveWake.summary(b, by: .time), "Off")
    }

    func test_keepsTheNewestPerMode() {
        var b = WakeBook()
        for k in 0..<15 { b.add(ride(true, react: 20, lead: 180, k)) }
        for k in 0..<4 { b.add(ride(false, react: 20, lead: 180, k)) }
        XCTAssertEqual(b.samples.filter(\.train).count, AdaptiveWake.keep)
        XCTAssertEqual(b.samples.filter { !$0.train }.count, 4)
        XCTAssertEqual(b.samples.filter(\.train).first?.at, t0.addingTimeInterval(5 * 86_400))
    }

    func test_summaryWords() {
        var b = WakeBook()
        b.trainExtra = 1; b.busExtra = 1
        XCTAssertEqual(AdaptiveWake.summary(b, by: .time), "Learned: wakes you 1 min earlier")
        b.busExtra = 2
        XCTAssertEqual(AdaptiveWake.summary(b, by: .time), "Learned: wakes you 2 min earlier on buses, 1 on trains")
        b.trainExtra = 0
        XCTAssertEqual(AdaptiveWake.summary(b, by: .time), "Learned: wakes you 2 min earlier on buses")
        XCTAssertEqual(AdaptiveWake.summary(b, by: .distance), "Only when waking by time")
        var c = WakeBook()
        for k in 0..<3 { c.add(ride(true, react: 20, lead: 180, k)) }
        XCTAssertEqual(AdaptiveWake.summary(c, by: .time), "Learned: as you set it")
    }

    func test_codableRoundTrip() throws {
        var b = WakeBook()
        b.add(ride(true, react: nil, lead: 100))
        b.busExtra = 1
        let back = try JSONDecoder().decode(WakeBook.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
    }
}
