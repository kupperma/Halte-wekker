import XCTest

final class PlanChoiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 4_000_000)
    private func at(_ min: Double) -> Date { now.addingTimeInterval(min * 60) }

    // MARK: the ride you chose

    func test_pinned_onlyWhenYouMovedAwayFromPlansOwnPick() {
        XCTAssertNil(ChosenRide.pinned(focused: "a", suggested: "a"), "Plan's own first pick: Fastest trip picks as before")
        XCTAssertEqual(ChosenRide.pinned(focused: "b", suggested: "a"), "b")
        XCTAssertEqual(ChosenRide.pinned(focused: "b", suggested: nil), "b")
        XCTAssertNil(ChosenRide.pinned(focused: nil, suggested: "a"))
    }

    func test_match_sameRidesFirst() {
        let list = [["306", "IC1"], ["306", "IC2"], ["305", "IC2"]]
        XCTAssertEqual(ChosenRide.match(["306", "IC2"], in: list), 1)
        XCTAssertEqual(ChosenRide.match(["305", "IC2"], in: list), 2)
    }

    func test_match_sameFirstRideSharingMost() {
        // the onward train changed (or there's one more change): still the bus you chose
        let list = [["305", "IC9"], ["306", "SPR1", "IC2"], ["306", "SPR4"]]
        XCTAssertEqual(ChosenRide.match(["306", "IC2"], in: list), 1)
        XCTAssertEqual(ChosenRide.match(["306", "IC7"], in: list), 1, "a tie: the first of them")
        XCTAssertEqual(ChosenRide.match(["306"], in: [["306", "IC2"]]), 0)
    }

    func test_match_noneWithoutItsFirstRide() {
        XCTAssertNil(ChosenRide.match(["306", "IC2"], in: [["305", "IC2"], ["IC2"]]), "another bus onto the same train isn't your choice")
        XCTAssertNil(ChosenRide.match(["306"], in: []))
        XCTAssertNil(ChosenRide.match([], in: [["306"]]))
    }

    func test_countsAsMiss_onlyAWholeAnswerReachingPastIt() {
        XCTAssertTrue(ChosenRide.countsAsMiss(departure: at(20), answer: [at(5), at(25)], whole: true))
        XCTAssertTrue(ChosenRide.countsAsMiss(departure: at(20), answer: [at(20)], whole: true))
        XCTAssertFalse(ChosenRide.countsAsMiss(departure: at(40), answer: [at(5), at(25)], whole: true), "the answer stops before it: too short")
        XCTAssertFalse(ChosenRide.countsAsMiss(departure: at(20), answer: [at(5), at(25)], whole: false), "a first part, or a saved answer")
        XCTAssertFalse(ChosenRide.countsAsMiss(departure: at(20), answer: [], whole: true))
        XCTAssertGreaterThanOrEqual(ChosenRide.maxMisses, 2, "one odd answer never drops your choice")
    }

    func test_beats_onlyOutright() {
        // leaves later and is there sooner
        XCTAssertTrue(ChosenRide.beats(start: at(12), end: at(50), chosenStart: at(10), chosenEnd: at(55)))
        // the same time to leave (a minute either way), two minutes sooner
        XCTAssertTrue(ChosenRide.beats(start: at(9), end: at(53), chosenStart: at(10), chosenEnd: at(55)))
        // earlier to leave: one you passed over, not news
        XCTAssertFalse(ChosenRide.beats(start: at(2), end: at(40), chosenStart: at(10), chosenEnd: at(55)))
        // a minute sooner isn't worth a note
        XCTAssertFalse(ChosenRide.beats(start: at(12), end: at(54), chosenStart: at(10), chosenEnd: at(55)))
    }

    func test_against() {
        XCTAssertEqual(ChosenRide.against(chosenEnd: at(50), at(50), isChosen: true), "your pick")
        XCTAssertEqual(ChosenRide.against(chosenEnd: at(50), at(50.2), isChosen: false), "same time")
        XCTAssertEqual(ChosenRide.against(chosenEnd: at(50), at(56), isChosen: false), "+6 min")
        XCTAssertEqual(ChosenRide.against(chosenEnd: at(50), at(46), isChosen: false), "4 min sooner")
    }

    func test_goneNotes() {
        for g in [ChosenRide.Gone.cancelled, .left, .missing] {
            XCTAssertTrue(ChosenRide.goneNote(g).hasSuffix("back to the fastest way."))
        }
    }

    // MARK: the home's destination

    func test_windowStart_alarmOrThreeQuartersBeforeLeaving() {
        XCTAssertEqual(HomeDest.windowStart(on: true, leave: at(100), alarm: at(40)), at(40))
        XCTAssertEqual(HomeDest.windowStart(on: true, leave: at(100), alarm: at(80)), at(55))
        XCTAssertEqual(HomeDest.windowStart(on: true, leave: at(100), alarm: nil), at(55))
        XCTAssertNil(HomeDest.windowStart(on: false, leave: at(100), alarm: at(40)), "no school alarm: no window")
        XCTAssertNil(HomeDest.windowStart(on: true, leave: nil, alarm: at(40)))
    }

    func test_resolve_staysUntilTheNextWindowOpens() {
        // picked the evening before; tomorrow's window at +600
        var r = HomeDest.resolve(chosenAt: now, until: nil, windowStart: at(600), now: at(1))
        XCTAssertFalse(r.over)
        XCTAssertEqual(r.until, at(600))
        r = HomeDest.resolve(chosenAt: now, until: r.until, windowStart: at(600), now: at(599))
        XCTAssertFalse(r.over)
        r = HomeDest.resolve(chosenAt: now, until: r.until, windowStart: at(600), now: at(600))
        XCTAssertTrue(r.over, "the window opened: back to your schedule")
    }

    func test_resolve_windowPassedWhileClosed() {
        // the app was closed through the window: the next one known now is the day after, but the kept one ended it
        let r = HomeDest.resolve(chosenAt: now, until: at(600), windowStart: at(2040), now: at(900))
        XCTAssertTrue(r.over)
    }

    func test_resolve_pickedDuringAWindow_holdsUntilTheNextOne() {
        // picked at +10 while today's window (opened at 0) is open: today's doesn't count
        var r = HomeDest.resolve(chosenAt: at(10), until: nil, windowStart: now, now: at(11))
        XCTAssertFalse(r.over)
        XCTAssertNil(r.until)
        // after class the next one is tomorrow's
        r = HomeDest.resolve(chosenAt: at(10), until: r.until, windowStart: at(1440), now: at(200))
        XCTAssertFalse(r.over)
        XCTAssertEqual(r.until, at(1440))
    }

    func test_resolve_followsAMovedWindow_andKeepsWithoutOne() {
        // the class moved later: the window follows it
        var r = HomeDest.resolve(chosenAt: now, until: at(600), windowStart: at(660), now: at(100))
        XCTAssertEqual(r.until, at(660))
        XCTAssertFalse(HomeDest.resolve(chosenAt: now, until: r.until, windowStart: at(660), now: at(630)).over)
        // the school alarm turned off: no window known, the one seen stays
        r = HomeDest.resolve(chosenAt: now, until: at(660), windowStart: nil, now: at(100))
        XCTAssertEqual(r.until, at(660))
        // never a window: it stays until you change it
        r = HomeDest.resolve(chosenAt: now, until: nil, windowStart: nil, now: at(100_000))
        XCTAssertFalse(r.over)
        XCTAssertNil(r.until)
    }

    func test_recents_newestFirstWithoutYourPlaces() {
        let list: [(id: String, lat: Double, lon: Double)] = [
            (id: "ehv", lat: 51.4432, lon: 5.4812),
            (id: "bd", lat: 51.5955, lon: 4.7797),
            (id: "ehv", lat: 51.4432, lon: 5.4812),
            (id: "ut", lat: 52.0894, lon: 5.1100),
            (id: "tb", lat: 51.5606, lon: 5.0836),
        ]
        // Breda station saved as one of your places (60 m off)
        let saved: [(lat: Double, lon: Double)] = [(lat: 51.5960, lon: 4.7800)]
        XCTAssertEqual(HomeDest.recents(list, saved: saved), ["ehv", "ut", "tb"])
        XCTAssertEqual(HomeDest.recents(list, saved: saved, max: 1), ["ehv"])
        XCTAssertEqual(HomeDest.recents([], saved: saved), [])
    }

    func test_metres() {
        XCTAssertEqual(HomeDest.metres(51.0, 5.0, 51.0, 5.0), 0, accuracy: 0.001)
        XCTAssertEqual(HomeDest.metres(51.0, 5.0, 51.001, 5.0), 111.3, accuracy: 0.5)
    }
}
