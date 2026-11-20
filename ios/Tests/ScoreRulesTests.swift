import XCTest

/// The leaderboard (0.35): which finished trips go on it, their score, and reading the saved board. The regression: on
/// the Veghel ⇄ BUas corridor, the new look's home starts every trip as a planned trip (a custom route), and until 0.34
/// only fixed routes were scored there, so no trip reached the board any more.
final class ScoreRulesTests: XCTestCase {
    // Veghel bus station and BUas (the corridor's Home and School), a stop near each, and Den Bosch
    let home = GeoPoint(lat: 51.6137, lon: 5.5474)
    let school = GeoPoint(lat: 51.5907, lon: 4.7932)
    let homeStop = GeoPoint(lat: 51.6150, lon: 5.5440)
    let breda = GeoPoint(lat: 51.5955, lon: 4.7801)                 // Breda station, ~1 km from BUas
    let denBosch = GeoPoint(lat: 51.6905, lon: 5.2934)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)              // Friday 15 January 2027, 09:00 in Amsterdam

    private func finished(_ kind: ScoreRules.Kind, home goingHome: Bool = false, starts: [GeoPoint]? = nil, end: GeoPoint? = nil,
                          leg: Int = 0, demo: Bool = false) -> ScoreRules.Finished {
        ScoreRules.Finished(kind: kind, demo: demo, startedAtLeg: leg, home: goingHome, starts: starts ?? [homeStop],
                            end: end ?? breda, homePlace: home, school: school)
    }

    // MARK: which trips go on the board

    /// The bug: a planned trip from Home to School on the corridor (Go's board, "I'm on it", the home map) is scored.
    func test_plannedTripOnTheCorridorIsScored() {
        let k = ScoreRules.board(finished(.custom))
        XCTAssertEqual(k?.route, DoorScore.toSchool)
        XCTAssertEqual(k?.home, false)
        let back = ScoreRules.board(finished(.custom, home: true, starts: [breda], end: homeStop))
        XCTAssertEqual(back?.route, DoorScore.toHome)
        XCTAssertEqual(back?.home, true)
    }

    /// The corridor's own routes keep their names (and their ideal), as since 0.9.
    func test_fixedRouteKeepsItsName() {
        let k = ScoreRules.board(finished(.fixed("Via Den Bosch"), home: true, starts: [], end: nil))
        XCTAssertEqual(k?.route, "Via Den Bosch")
        XCTAssertEqual(k?.home, true)
    }

    func test_notOnTheBoard() {
        XCTAssertNil(ScoreRules.board(finished(.custom, demo: true)), "the demo")
        XCTAssertNil(ScoreRules.board(finished(.custom, leg: 1)), "started at a change")
        XCTAssertNil(ScoreRules.board(finished(.fixed("Via Den Bosch"), leg: 1)), "auto-started at Den Bosch")
        XCTAssertNil(ScoreRules.board(finished(.single)), "a single stop")
        XCTAssertNil(ScoreRules.board(finished(.custom, end: denBosch)), "not to School")
        XCTAssertNil(ScoreRules.board(finished(.custom, starts: [])), "nowhere to start from")
    }

    /// A stale fix far away (where the phone last was) doesn't spoil it: the trip's first stop counts too.
    func test_startFallsBackToTheFirstStop() {
        XCTAssertEqual(ScoreRules.board(finished(.custom, starts: [denBosch, homeStop]))?.route, DoorScore.toSchool)
    }

    // MARK: the score

    func test_scoreAgainstYourFastest() {
        let first = ScoreRules.score(name: DoorScore.toSchool, ideal: nil, home: false, start: t0, end: t0.addingTimeInterval(50 * 60),
                                     trips: [], weekStart: t0.addingTimeInterval(-4 * 86400), plan: 46.04, lateLine: "305", late: 4.26)
        XCTAssertEqual(first?.entry.mins, 50)
        XCTAssertEqual(first?.entry.score, 500)
        XCTAssertEqual(first?.entry.est, true)
        XCTAssertEqual(first?.entry.plan, 46)
        XCTAssertEqual(first?.entry.late, 4.3)
        XCTAssertEqual(first?.entry.lateLine, "305")
        XCTAssertEqual(first?.firstWeek, true)
        let next = ScoreRules.score(name: DoorScore.toSchool, ideal: nil, home: false, start: t0.addingTimeInterval(86400),
                                    end: t0.addingTimeInterval(86400 + 62.5 * 60), trips: [first!.entry], weekStart: t0.addingTimeInterval(-4 * 86400))
        XCTAssertEqual(next?.entry.score, 400)                     // 500 × 50 / 62.5
        XCTAssertEqual(next?.entry.grade, "B")
        XCTAssertEqual(next?.fastestWeek, false)
        XCTAssertNil(ScoreRules.score(name: "x", ideal: nil, home: false, start: t0, end: t0.addingTimeInterval(240), trips: [], weekStart: t0))
    }

    // MARK: the saved board

    /// What 0.34 saved (no 0.35 fields) reads as it was: no trip is lost.
    func test_oldSaveReads() throws {
        let json = #"[{"id":"t1","at":800000000,"home":false,"route":"Via Den Bosch","mins":61.5,"score":460,"grade":"A","ref":57,"est":false}]"#
        let trips = ScoreRules.decode(Data(json.utf8))
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.route, "Via Den Bosch")
        XCTAssertNil(trips.first?.plan)
        // and a 0.35 one goes back and forth
        var t = trips[0]
        t.plan = 55; t.lateLine = "Intercity"; t.late = 6
        let again = ScoreRules.decode(try JSONEncoder().encode([t]))
        XCTAssertEqual(again, [t])
    }

    /// One entry that doesn't read is skipped, the others are kept (before, the whole board read as empty).
    func test_oneBadEntryKeepsTheRest() {
        let json = #"[{"id":"t1","at":800000000,"home":false,"route":"home→school","mins":48,"score":500,"grade":"S","ref":48,"est":true},{"id":"t2","home":true},{"id":"t3","at":800090000,"home":true,"route":"school→home","mins":52,"score":480,"grade":"S","ref":50,"est":true}]"#
        XCTAssertEqual(ScoreRules.decode(Data(json.utf8)).map(\.id), ["t1", "t3"])
        XCTAssertEqual(ScoreRules.decode(nil), [])
        XCTAssertEqual(ScoreRules.decode(Data("nonsense".utf8)), [])
    }

    func test_worseKeepsTheLatest() {
        XCTAssertEqual(ScoreRules.worse(nil, (line: "305", mins: 3)).line, "305")
        XCTAssertEqual(ScoreRules.worse((line: "305", mins: 3), (line: "Intercity", mins: 12)).line, "Intercity")
        XCTAssertEqual(ScoreRules.worse((line: "305", mins: 18), (line: "Intercity", mins: 12)).line, "305")
    }
}
