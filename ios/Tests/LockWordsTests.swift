import XCTest

/// 0.39: the lock screen's next stop, delay and platform, and the change ahead; a state from before still decodes.
final class LockWordsTests: XCTestCase {
    func test_delayWords() {
        XCTAssertNil(LockWords.delay(nil))
        XCTAssertEqual(LockWords.delay(0), "on time")
        XCTAssertEqual(LockWords.delay(3), "3 min late")
        XCTAssertEqual(LockWords.delay(-2), "2 min early")
    }

    func test_rideLine() {
        XCTAssertEqual(LockWords.ride(nextStop: "Vught", delay: 3, platform: "5"), "Next: Vught · 3 min late · platform 5")
        XCTAssertEqual(LockWords.ride(nextStop: nil, delay: nil, platform: "5"), "platform 5")
        XCTAssertEqual(LockWords.ride(nextStop: " ", delay: 0, platform: ""), "on time")
        XCTAssertNil(LockWords.ride(nextStop: nil, delay: nil, platform: nil))
    }

    func test_aStateFromBeforeStillDecodes() throws {
        // as 0.38 wrote it: none of the 0.39 fields
        let json = """
        {"legTitle":"Intercity to Breda","isTrain":true,"distanceText":"12 km","finalName":"Breda","awake":false,"goingHome":false,
         "kicker":"NOW RIDING","stopName":"Breda","progress":0.4,"songPlaying":false,"stops":[0.5],"ringing":false,"vehicle":"ic","line":"IC"}
        """
        let s = try JSONDecoder().decode(TripAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(s.nextStop)
        XCTAssertNil(s.delay)
        XCTAssertNil(s.platform)
        XCTAssertNil(s.changeText)
        XCTAssertNil(s.changeLeaves)
        XCTAssertNil(s.changeMiss)
        XCTAssertNil(s.rideLine)
        XCTAssertNil(s.changeLine)
        XCTAssertEqual(s.line, "IC")
    }

    func test_newFieldsRoundTrip() throws {
        var s = try JSONDecoder().decode(TripAttributes.ContentState.self, from: Data("""
        {"legTitle":"x","isTrain":true,"distanceText":"","finalName":"","awake":false,"goingHome":false,"kicker":"NOW RIDING",
         "stopName":"","progress":0,"songPlaying":false}
        """.utf8))
        s.nextStop = "Vught"; s.delay = 2; s.platform = "5"
        s.changeText = "Platform 5 → 7 · 4 min to change"; s.changeLeaves = Date(timeIntervalSince1970: 1_800_000_000)
        let back = try JSONDecoder().decode(TripAttributes.ContentState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.rideLine, "Next: Vught · 2 min late · platform 5")
        XCTAssertEqual(back.changeLine, "Platform 5 → 7 · 4 min to change")
        s.changeMiss = "You’ll miss the 08:12 — take the 08:27 from platform 4"
        XCTAssertEqual(s.changeLine, s.changeMiss, "the miss comes first")
    }
}
