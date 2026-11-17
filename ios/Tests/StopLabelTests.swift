import XCTest

final class StopLabelTests: XCTestCase {
    func test_kind() {
        XCTAssertEqual(StopLabel.kind(isTrain: false, line: "305"), .bus)
        XCTAssertEqual(StopLabel.kind(isTrain: true, line: "IC"), .train)
        XCTAssertEqual(StopLabel.kind(isTrain: true, line: "SPR"), .train)
        XCTAssertEqual(StopLabel.kind(isTrain: true, line: "1"), .tram, "a tram's line is a number")
        XCTAssertEqual(StopLabel.kind(isTrain: true, line: ""), .train)
    }

    func test_trainPlatform() {
        let w = StopLabel.make(kind: .train, stop: "Eindhoven Centraal", track: "5", planned: "5")
        XCTAssertEqual(w.big, "Platform 5")
        XCTAssertEqual(w.under, "Eindhoven Centraal")
        XCTAssertEqual(w.chip, "Platform 5")
        XCTAssertFalse(w.changed)
        XCTAssertNil(w.changeNote)
        XCTAssertNil(w.unknownNote)
    }

    func test_trainPlatformChanged() {
        let w = StopLabel.make(kind: .train, stop: "Eindhoven Centraal", track: "5", planned: "4")
        XCTAssertTrue(w.changed)
        XCTAssertEqual(w.big, "Platform 5")
        XCTAssertEqual(w.changeNote, "Platform changed to 5 (was 4)")
        // only the planned one known: that one, not changed
        let p = StopLabel.make(kind: .train, stop: "Breda", track: nil, planned: "7")
        XCTAssertEqual(p.big, "Platform 7")
        XCTAssertFalse(p.changed)
        // the same, written otherwise
        XCTAssertFalse(StopLabel.make(kind: .train, stop: "Breda", track: "5a", planned: "5A").changed)
    }

    func test_trainPlatformUnknown() {
        let w = StopLabel.make(kind: .train, stop: "Breda", track: "", planned: nil)
        XCTAssertNil(w.code)
        XCTAssertEqual(w.big, "Breda")
        XCTAssertNil(w.under)
        XCTAssertNil(w.chip)
        XCTAssertEqual(w.unknownNote, "Platform not known yet")
    }

    func test_busStopLetterFromTrack() {
        let w = StopLabel.make(kind: .bus, stop: "Breda, Centraal Station", track: "U", planned: "U")
        XCTAssertEqual(w.big, "Stop U")
        XCTAssertEqual(w.under, "Breda, Centraal Station")
        XCTAssertEqual(w.chip, "Stop U")
        XCTAssertNil(w.unknownNote, "a bus stop without a letter is just its name")
        XCTAssertEqual(StopLabel.make(kind: .bus, stop: "Eindhoven, Station", track: "B1", planned: nil).big, "Stop B1")
        XCTAssertEqual(StopLabel.make(kind: .tram, stop: "Den Haag, Centraal", track: "Perron 2", planned: nil).big, "Stop 2")
    }

    func test_busStopChanged() {
        let w = StopLabel.make(kind: .bus, stop: "Breda, Centraal Station", track: "B", planned: "A")
        XCTAssertTrue(w.changed)
        XCTAssertEqual(w.changeNote, "Stop changed to B (was A)")
    }

    func test_busTrackTooLongFallsBackToName() {
        let w = StopLabel.make(kind: .bus, stop: "Breda, Nassausingel", track: "Busstation", planned: nil)
        XCTAssertNil(w.code)
        XCTAssertEqual(w.big, "Breda, Nassausingel")
        XCTAssertNil(w.under)
    }

    func test_busLetterFromName() {
        let a = StopLabel.make(kind: .bus, stop: "Eindhoven, Station perron E2", track: nil, planned: nil)
        XCTAssertEqual(a.big, "Stop E2")
        XCTAssertEqual(a.under, "Eindhoven, Station")
        let b = StopLabel.make(kind: .bus, stop: "Tilburg, Centraal Station (perron D)", track: nil, planned: nil)
        XCTAssertEqual(b.big, "Stop D")
        XCTAssertEqual(b.under, "Tilburg, Centraal Station")
        let c = StopLabel.make(kind: .bus, stop: "Breda, Centraal Station (U)", track: nil, planned: nil)
        XCTAssertEqual(c.big, "Stop U")
        XCTAssertEqual(c.under, "Breda, Centraal Station")
        let d = StopLabel.make(kind: .bus, stop: "Den Bosch, Centraal Station, Perron A", track: nil, planned: nil)
        XCTAssertEqual(d.big, "Stop A")
        XCTAssertEqual(d.under, "Den Bosch, Centraal Station")
    }

    func test_nameBracketsThatAreNotALetter() {
        // a province or a town part in brackets is no stop letter
        XCTAssertNil(StopLabel.fromName("Oosterhout (NB), Arkendonk"))
        XCTAssertNil(StopLabel.fromName("Oosterhout (NB)"))
        XCTAssertNil(StopLabel.fromName("Doetinchem (Gld)"))
        XCTAssertNil(StopLabel.fromName("Veghel, Busstation"))
        XCTAssertNil(StopLabel.fromName("Perron 3"), "only a letter after the stop's name")
        XCTAssertEqual(StopLabel.make(kind: .bus, stop: "Oosterhout (NB)", track: nil, planned: nil).big, "Oosterhout (NB)")
    }

    func test_codes() {
        XCTAssertTrue(StopLabel.isCode("U", strict: false))
        XCTAssertTrue(StopLabel.isCode("B1", strict: false))
        XCTAssertTrue(StopLabel.isCode("12", strict: false))
        XCTAssertFalse(StopLabel.isCode("", strict: false))
        XCTAssertFalse(StopLabel.isCode("ABCD", strict: false))
        XCTAssertFalse(StopLabel.isCode("A 1", strict: false))
        XCTAssertTrue(StopLabel.isCode("E12", strict: true))
        XCTAssertFalse(StopLabel.isCode("NB", strict: true))
        XCTAssertEqual(StopLabel.clean(" Spoor 5 "), "5")
        XCTAssertNil(StopLabel.clean("  "))
        XCTAssertNil(StopLabel.clean(nil))
    }

    func test_vehicle() {
        XCTAssertEqual(StopLabel.vehicle(kind: .bus, line: "305", name: "305"), "Bus 305")
        XCTAssertEqual(StopLabel.vehicle(kind: .tram, line: "1", name: "1"), "Tram 1")
        XCTAssertEqual(StopLabel.vehicle(kind: .train, line: "IC", name: "Intercity"), "Intercity")
        XCTAssertEqual(StopLabel.vehicle(kind: .train, line: "IC", name: "IC"), "Intercity")
        XCTAssertEqual(StopLabel.vehicle(kind: .train, line: "ICD", name: "Intercity direct"), "Intercity direct")
        XCTAssertEqual(StopLabel.vehicle(kind: .train, line: "SPR", name: "SPR"), "Sprinter")
        XCTAssertEqual(StopLabel.vehicle(kind: .train, line: "ICE", name: "ICE International"), "ICE International")
        XCTAssertEqual(StopLabel.vehicle(kind: .train, line: "", name: ""), "Train")
        XCTAssertEqual(StopLabel.ride("Bus 305", toward: "Veghel"), "Bus 305 to Veghel")
        XCTAssertEqual(StopLabel.ride("Intercity", toward: "Den Haag Centraal"), "Intercity to Den Haag Centraal")
        XCTAssertEqual(StopLabel.ride("Bus 5", toward: " "), "Bus 5")
    }

    func test_delay() {
        XCTAssertEqual(StopLabel.delay(3, live: true, cancelled: false)?.text, "+3 min")
        XCTAssertEqual(StopLabel.delay(3, live: true, cancelled: false)?.spoken, "3 minutes late")
        XCTAssertEqual(StopLabel.delay(1, live: true, cancelled: false)?.spoken, "1 minute late")
        XCTAssertEqual(StopLabel.delay(-2, live: true, cancelled: false)?.text, "2 min early")
        XCTAssertEqual(StopLabel.delay(0, live: true, cancelled: false)?.text, "on time")
        XCTAssertEqual(StopLabel.delay(0, live: true, cancelled: false)?.warn, false)
        XCTAssertNil(StopLabel.delay(0, live: false, cancelled: false), "a timetable time: nothing said")
        XCTAssertEqual(StopLabel.delay(0, live: false, cancelled: true)?.text, "Cancelled")
    }

    func test_walk() {
        XCTAssertEqual(StopLabel.walk(minutes: 9, metres: 712, leaveBy: "15:37"), "9 min walk · 700 m · leave by 15:37")
        XCTAssertEqual(StopLabel.walk(minutes: 2, metres: nil, leaveBy: nil), "2 min walk")
        XCTAssertEqual(StopLabel.walk(minutes: 14, metres: 1180, leaveBy: nil), "14 min walk · 1.2 km")
        XCTAssertEqual(StopLabel.walk(minutes: 25, metres: 2000, leaveBy: nil), "25 min walk · 2 km")
        XCTAssertEqual(StopLabel.walk(minutes: 0, metres: 20, leaveBy: "15:37"), "50 m · leave by 15:37")
        XCTAssertNil(StopLabel.walk(minutes: 0, metres: nil, leaveBy: "15:37"))
        XCTAssertEqual(StopLabel.walkSpoken(minutes: 9, leaveBy: "15:37"), "9 minute walk, leave by 15:37")
        XCTAssertNil(StopLabel.walkSpoken(minutes: 0, leaveBy: "15:37"))
    }

    func test_here() {
        XCTAssertTrue(StopLabel.isHere(metres: 40, walkMinutes: 3))
        XCTAssertTrue(StopLabel.isHere(metres: 60, walkMinutes: 3))
        XCTAssertFalse(StopLabel.isHere(metres: 80, walkMinutes: 3))
        XCTAssertTrue(StopLabel.isHere(metres: 100, walkMinutes: 0), "no walk planned: a little further still counts")
        XCTAssertFalse(StopLabel.isHere(metres: 150, walkMinutes: 0))
        XCTAssertFalse(StopLabel.isHere(metres: nil, walkMinutes: 0), "where you are isn't known")
        XCTAssertFalse(StopLabel.isHere(metres: .nan, walkMinutes: 0))
        XCTAssertEqual(StopLabel.waiting("Bus 305", minutes: 4), "Waiting for Bus 305 · in 4 min")
        XCTAssertEqual(StopLabel.waiting("Bus 305", minutes: 0), "Waiting for Bus 305 · due now")
        XCTAssertEqual(StopLabel.waiting("Bus 305", minutes: -3), "Waiting for Bus 305 · left 3 min ago")
    }

    func test_spoken() {
        let w = StopLabel.make(kind: .train, stop: "Eindhoven Centraal", track: "5", planned: "5")
        let s = StopLabel.spoken(w, here: false, ride: "Intercity to Den Haag Centraal", time: "15:46",
                                 delay: StopLabel.delay(3, live: true, cancelled: false)?.spoken,
                                 walk: StopLabel.walkSpoken(minutes: 9, leaveBy: "15:37"))
        XCTAssertEqual(s, "Go to Platform 5, Eindhoven Centraal, Intercity to Den Haag Centraal at 15:46, 3 minutes late, 9 minute walk, leave by 15:37")
        let b = StopLabel.make(kind: .bus, stop: "Breda, Centraal Station", track: "U", planned: nil)
        XCTAssertEqual(StopLabel.spoken(b, here: true, ride: "Bus 5 to BUas", time: "16:27", delay: nil, walk: "2 minute walk"),
                       "You’re here, Stop U, Breda, Centraal Station, Bus 5 to BUas at 16:27, waiting for it")
        let c = StopLabel.make(kind: .train, stop: "Breda", track: "8", planned: "7")
        XCTAssertEqual(StopLabel.spoken(c, here: false, ride: "Sprinter to Roosendaal", time: "16:02", delay: "on time", walk: nil),
                       "Go to Platform 8, Breda, Platform changed to 8 (was 7), Sprinter to Roosendaal at 16:02, on time")
    }
}
