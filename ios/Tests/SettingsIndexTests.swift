import XCTest

final class SettingsIndexTests: XCTestCase {
    private func titles(_ q: String) -> [String] { SettingsIndex.search(q).map(\.title) }

    func test_alarmFindsEveryAlarm() {
        let t = titles("alarm")
        for want in ["Alarm sound", "Backup alarm", "School alarm", "Test the alarm"] {
            XCTAssertTrue(t.contains(want), "\(want) missing from \(t)")
        }
        XCTAssertEqual(t.first, "Alarm sound", "a title that starts with it comes first")
    }

    func test_topicNameAloneDoesNotMatch() {
        // "Station announcement" is on Trips & alarm, but has nothing to do with the word "alarm"
        XCTAssertFalse(titles("alarm").contains("Station announcement"))
    }

    func test_caseAccentsAndApostrophesDontMatter() {
        XCTAssertEqual(titles("WHATS SENT").first, "What’s sent")
        XCTAssertEqual(titles("what's sent").first, "What’s sent")
        XCTAssertTrue(titles("ALARM").contains("Backup alarm"))
        XCTAssertTrue(titles("im on my phone").contains("Just a notification when I’m on my phone"))
    }

    func test_everyWordMustMatch() {
        XCTAssertEqual(titles("backup alarm"), ["Backup alarm"])
        XCTAssertTrue(titles("alarm zebra").isEmpty)
    }

    func test_prefixOfAWord() {
        XCTAssertTrue(titles("headph").contains("Sound only with headphones"))
        XCTAssertTrue(titles("spot").contains("Connect Spotify"))
    }

    func test_keywordsFindIt() {
        XCTAssertTrue(titles("spotify").contains("Show music from"))
        XCTAssertTrue(titles("demo").contains("Try it at home: a pretend trip"))
        XCTAssertTrue(titles("credits").contains("About and open data"))
        XCTAssertTrue(titles("vibrate").contains("Sound only with headphones"))
    }

    func test_emptyQueryFindsNothing() {
        XCTAssertTrue(titles("").isEmpty)
        XCTAssertTrue(titles("   ").isEmpty)
        XCTAssertTrue(titles("?!").isEmpty)
    }

    func test_titleMatchesBeforeKeywordMatches() {
        let r = SettingsIndex.search("battery")
        XCTAssertEqual(Set(r.prefix(2).map(\.id)), ["battery.use", "battery.longRides"])
    }

    func test_resultsKnowTheirTopic() {
        XCTAssertEqual(SettingsIndex.search("backup alarm").first?.topic, .trips)
        XCTAssertEqual(SettingsIndex.search("school alarm").first?.topic, .school)
        XCTAssertEqual(SettingsIndex.search("reset").first?.topic, .advanced)
    }

    func test_idsAreUniqueAndEveryTopicHasSettings() {
        let ids = SettingsIndex.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for t in SettingsTopic.allCases {
            XCTAssertFalse(SettingsIndex.entries(in: t, corridor: false, testSetup: false).isEmpty, "\(t) has no settings")
        }
    }

    func test_corridorAndTestSetupOnlyRows() {
        let off = SettingsIndex.entries(corridor: false, testSetup: false).map(\.id)
        XCTAssertFalse(off.contains("map.newLook"))
        XCTAssertFalse(off.contains("adv.backToMine"))
        let on = SettingsIndex.entries(corridor: true, testSetup: true).map(\.id)
        XCTAssertTrue(on.contains("map.newLook"))
        XCTAssertTrue(on.contains("adv.backToMine"))
        XCTAssertTrue(SettingsIndex.search("new look", in: SettingsIndex.entries(corridor: false, testSetup: false)).isEmpty)
    }

    /// 0.33: waking by time, and Motion & Fitness, on Trips & alarm.
    func test_wakeByTimeAndMotionAreFound() {
        XCTAssertEqual(SettingsIndex.search("wake me").first?.id, "wake.by")
        XCTAssertTrue(titles("minutes before").contains("Wake me … before my stop"))
        XCTAssertTrue(titles("by time").contains("Wake me … before my stop"))
        XCTAssertEqual(SettingsIndex.search("motion").first?.id, "trips.motion")
        XCTAssertTrue(titles("cycling").contains("Use motion to notice rides faster"))
        XCTAssertEqual(SettingsIndex.search("motion").first?.topic, .trips)
    }

    func test_topicsInTwoGroups() {
        XCTAssertEqual(SettingsTopic.inGroup(1), [.trips, .places, .school, .friends, .map, .notifications])
        XCTAssertEqual(SettingsTopic.inGroup(2), [.battery, .share, .advanced])
    }

    func test_travelHelpRowsAreFound() {                                   // (0.36)
        XCTAssertEqual(SettingsIndex.search("student ov").first?.id, "trips.studentOV")
        XCTAssertEqual(SettingsIndex.search("check out").first?.id, "trips.checkOut")
        XCTAssertEqual(SettingsIndex.search("geld terug").first?.id, "trips.delayClaim")
        XCTAssertEqual(SettingsIndex.search("works").first?.id, "notices.works")
        XCTAssertEqual(SettingsIndex.search("last way home").first?.id, "notices.lastHome")
        XCTAssertEqual(SettingsIndex.search("last train").first?.topic, .notifications)
    }

    func test_rainOvfietsAndWidgetRowsAreFound() {                       // (0.37)
        XCTAssertEqual(SettingsIndex.search("umbrella").first?.id, "map.rainAdvice")
        XCTAssertEqual(SettingsIndex.search("rain").first?.id, "map.rainAdvice")
        XCTAssertEqual(SettingsIndex.search("ov-fiets").first?.id, "map.ovfiets")
        XCTAssertEqual(SettingsIndex.search("rental bike").first?.id, "map.ovfiets")
        XCTAssertEqual(SettingsIndex.search("siri").first?.id, "map.widget")
        XCTAssertEqual(SettingsIndex.search("widget").first?.topic, .map)
    }
}
