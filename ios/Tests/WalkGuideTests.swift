import XCTest

/// 0.41: walking with arrows. The arrow from the route's shape, following the steps, off the route, there, the hurry
/// hint, and the words.
final class WalkGuideTests: XCTestCase {
    private typealias W = WalkGuide

    private func raw(_ text: String, _ path: [GeoPoint]) -> W.RawStep {
        W.RawStep(text: text, distance: Geo.length(path), path: path)
    }

    /// 100 m east along Kerkstraat, left onto Hoogstraat for 80 m north, there.
    private var lShape: W.Route {
        W.route([
            raw("", [Fx.east(0)]),
            raw("Head east on Kerkstraat", [Fx.east(0), Fx.east(100)]),
            raw("Turn left onto Hoogstraat", [Fx.east(100), Fx.east(100, north: 80)]),
            raw("The destination is on your left.", [Fx.east(100, north: 80)]),
        ])
    }

    // MARK: the arrow

    func test_changeWrapsRound() {
        XCTAssertEqual(W.change(from: 350, to: 10), 20, accuracy: 0.001)
        XCTAssertEqual(W.change(from: 10, to: 350), -20, accuracy: 0.001)
        XCTAssertEqual(W.change(from: 90, to: 0), -90, accuracy: 0.001)
        XCTAssertEqual(W.change(from: 0, to: 180), 180, accuracy: 0.001)
    }

    func test_turnFromChange() {
        XCTAssertEqual(W.turn(change: 5), .straight)
        XCTAssertEqual(W.turn(change: -15), .straight)
        XCTAssertEqual(W.turn(change: 30), .slightRight)
        XCTAssertEqual(W.turn(change: -30), .slightLeft)
        XCTAssertEqual(W.turn(change: 90), .right)
        XCTAssertEqual(W.turn(change: -95), .left)
        XCTAssertEqual(W.turn(change: 140), .sharpRight)
        XCTAssertEqual(W.turn(change: -150), .sharpLeft)
        XCTAssertEqual(W.turn(change: 178), .uTurn)
        XCTAssertEqual(W.turn(change: -170), .uTurn)
    }

    func test_routeFromSteps_startTurnThere() {
        let r = lShape
        XCTAssertEqual(r.steps.count, 3, "the step without words is joined to the next")
        XCTAssertEqual(r.length, 180, accuracy: 1)
        XCTAssertEqual(r.steps[0].turn, .depart)
        XCTAssertEqual(r.steps[0].start, 0)
        XCTAssertEqual(r.steps[0].end, 100, accuracy: 1)
        XCTAssertEqual(r.steps[1].turn, .left)
        XCTAssertEqual(r.steps[1].text, "Turn left onto Hoogstraat")
        XCTAssertEqual(r.steps[1].end, 180, accuracy: 1)
        XCTAssertEqual(r.steps[2].turn, .arrive)
        XCTAssertEqual(r.steps[2].text, "The destination is on your left")
    }

    func test_rightSlightAndWordsOnAStraightShape() {
        let right = W.route([raw("Head east", [Fx.east(0), Fx.east(100)]), raw("Turn right onto Markt", [Fx.east(100), Fx.east(100, north: -100)])])
        XCTAssertEqual(right.steps[1].turn, .right)
        XCTAssertEqual(right.steps.last?.turn, .arrive, "a last step that turns gets a stop after it")
        XCTAssertEqual(right.steps.count, 3)
        XCTAssertEqual(right.steps[2].start, 200, accuracy: 1)

        let slight = W.route([raw("Head east", [Fx.east(0), Fx.east(100)]),
                              raw("Keep left", [Fx.east(100), Fx.east(143.3, north: 25)]), raw("Arrive at the destination", [Fx.east(143.3, north: 25)])])
        XCTAssertEqual(slight.steps[1].turn, .slightLeft)

        // the shape goes straight on, the words say right: a slight right
        let words = W.route([raw("Head east", [Fx.east(0), Fx.east(100)]),
                             raw("Turn right onto Dorpsstraat", [Fx.east(100), Fx.east(200)]), raw("Arrive", [Fx.east(200)])])
        XCTAssertEqual(words.steps[1].turn, .slightRight)
    }

    func test_noWordsAtAll_justTheStop() {
        let r = W.route([raw("", [Fx.east(0), Fx.east(50)])])
        XCTAssertEqual(r.steps.map(\.turn), [.arrive])
        XCTAssertEqual(r.length, 50, accuracy: 1)
    }

    func test_sideFromWords() {
        XCTAssertEqual(W.side("Turn right onto Hoogstraat"), true)
        XCTAssertEqual(W.side("Sla linksaf naar Kerkstraat"), false)
        XCTAssertNil(W.side("Continue onto Markt"))
        XCTAssertTrue(W.saysArrive("The destination is on your right"))
        XCTAssertFalse(W.saysArrive("Turn left"))
    }

    // MARK: following it

    func test_locate_thenAdvanceNearTheTurn() throws {
        let r = lShape
        let a = try XCTUnwrap(W.locate(Fx.east(50), on: r, step: 0, lastAlong: nil))
        XCTAssertEqual(a.step, 0)
        XCTAssertFalse(a.advanced)
        XCTAssertEqual(a.toTurn, 50, accuracy: 1)
        XCTAssertEqual(a.left, 130, accuracy: 1)
        XCTAssertEqual(W.next(r, step: a.step)?.turn, .left)
        XCTAssertEqual(W.then(r, step: a.step)?.turn, .arrive)

        let b = try XCTUnwrap(W.locate(Fx.east(88), on: r, step: 0, lastAlong: 50))
        XCTAssertEqual(b.step, 1, "within 15 m of the turn: the next step")
        XCTAssertTrue(b.advanced)
        XCTAssertEqual(b.toTurn, 92, accuracy: 1)
        XCTAssertEqual(W.next(r, step: b.step)?.turn, .arrive)
        XCTAssertNil(W.then(r, step: b.step))

        // past the turn along the route: moved on as well
        let c = try XCTUnwrap(W.locate(Fx.east(100, north: 20), on: r, step: 0, lastAlong: 88))
        XCTAssertEqual(c.step, 1)
    }

    func test_locate_neverBack_andNotWhenOffTheRoute() throws {
        let r = lShape
        let back = try XCTUnwrap(W.locate(Fx.east(30), on: r, step: 1, lastAlong: 100))
        XCTAssertEqual(back.step, 1)
        XCTAssertFalse(back.advanced)

        let off = try XCTUnwrap(W.locate(Fx.east(95, north: -60), on: r, step: 0, lastAlong: 80))
        XCTAssertEqual(off.off, 60, accuracy: 1)
        XCTAssertEqual(off.step, 0, "off the route: it doesn't move on")
    }

    func test_warnAt30m_onceAndNotOnShortSteps() throws {
        let r = lShape
        let p = try XCTUnwrap(W.locate(Fx.east(75), on: r, step: 0, lastAlong: 60))
        XCTAssertTrue(W.warn(p, on: r, warned: false))
        XCTAssertFalse(W.warn(p, on: r, warned: true))
        let early = try XCTUnwrap(W.locate(Fx.east(50), on: r, step: 0, lastAlong: 40))
        XCTAssertFalse(W.warn(early, on: r, warned: false))

        let short = W.route([raw("Head east", [Fx.east(0), Fx.east(30)]), raw("Turn left", [Fx.east(30), Fx.east(30, north: 100)]), raw("Arrive", [Fx.east(30, north: 100)])])
        let s = try XCTUnwrap(W.locate(Fx.east(10), on: short, step: 0, lastAlong: nil))
        XCTAssertFalse(W.warn(s, on: short, warned: false), "a 30 m step has no warning of its own")
    }

    func test_offRoute_10sThenReroute_atMostEvery20s() {
        let t0 = Fx.t0
        var s = W.OffRoute()
        var o = W.offRoute(s, off: 50, accuracy: 10, now: t0)
        XCTAssertFalse(o.reroute); s = o.state
        XCTAssertEqual(s.since, t0)
        o = W.offRoute(s, off: 55, accuracy: 10, now: t0.addingTimeInterval(5))
        XCTAssertFalse(o.reroute); s = o.state
        o = W.offRoute(s, off: 55, accuracy: 10, now: t0.addingTimeInterval(10))
        XCTAssertTrue(o.reroute); s = o.state
        XCTAssertNil(s.since)

        // still off: 10 s more, but the last new route was only 15 s ago
        o = W.offRoute(s, off: 60, accuracy: 10, now: t0.addingTimeInterval(15)); s = o.state
        o = W.offRoute(s, off: 60, accuracy: 10, now: t0.addingTimeInterval(25))
        XCTAssertFalse(o.reroute); s = o.state
        o = W.offRoute(s, off: 60, accuracy: 10, now: t0.addingTimeInterval(30))
        XCTAssertTrue(o.reroute); s = o.state

        // back on it: forgotten; an unsure fix changes nothing
        o = W.offRoute(s, off: 60, accuracy: 10, now: t0.addingTimeInterval(40)); s = o.state
        XCTAssertNotNil(s.since)
        o = W.offRoute(s, off: 10, accuracy: 10, now: t0.addingTimeInterval(41)); s = o.state
        XCTAssertNil(s.since)
        o = W.offRoute(s, off: 200, accuracy: 150, now: t0.addingTimeInterval(42))
        XCTAssertEqual(o.state, s)
        XCTAssertFalse(o.reroute)
    }

    func test_arrivedWithin25m() {
        XCTAssertTrue(W.arrived(metres: 20, accuracy: 10))
        XCTAssertFalse(W.arrived(metres: 30, accuracy: 10))
        XCTAssertFalse(W.arrived(metres: 10, accuracy: 120), "not on an unsure fix")
        XCTAssertFalse(W.arrived(metres: 10, accuracy: -1))
    }

    func test_splitWalkedAndAhead() {
        let path = [Fx.east(0), Fx.east(100), Fx.east(200)]
        let s = W.split(path, at: 150)
        XCTAssertEqual(s.walked.count, 3)
        XCTAssertEqual(Geo.length(s.walked), 150, accuracy: 1)
        XCTAssertEqual(s.ahead.count, 2)
        XCTAssertEqual(Geo.length(s.ahead), 50, accuracy: 1)
        let start = W.split(path, at: 0)
        XCTAssertTrue(start.walked.isEmpty)
        XCTAssertEqual(start.ahead, path)
    }

    // MARK: will you make it

    func test_hurryHint() {
        let now = Fx.t0
        let fine = W.hurry(left: 600, speed: nil, leaves: now.addingTimeInterval(720), now: now, what: "your bus")
        XCTAssertEqual(fine.walkMinutes, 9)
        XCTAssertEqual(fine.pace, .fine)
        XCTAssertEqual(fine.text, "Your bus leaves in 12 min · you’ll make it")

        let faster = W.hurry(left: 600, speed: nil, leaves: now.addingTimeInterval(530), now: now, what: "your train")
        XCTAssertEqual(faster.pace, .faster)
        XCTAssertEqual(faster.text, "Your train leaves in 8 min · walk a bit faster")

        let tight = W.hurry(left: 600, speed: nil, leaves: now.addingTimeInterval(300), now: now, what: "your bus")
        XCTAssertEqual(tight.pace, .hurry)

        let gone = W.hurry(left: 600, speed: nil, leaves: now.addingTimeInterval(10), now: now, what: "your bus")
        XCTAssertEqual(gone.pace, .gone)
        XCTAssertEqual(gone.text, "Your bus leaves now")

        let mine = W.hurry(left: 600, speed: 1.5, leaves: nil, now: now, what: "your bus")
        XCTAssertEqual(mine.walkMinutes, 7, "your own speed")
        XCTAssertNil(mine.text)
        XCTAssertNil(mine.pace)
        XCTAssertEqual(W.hurry(left: 600, speed: 9, leaves: nil, now: now, what: "x").walkMinutes, 9, "a silly speed: the planner's")
        XCTAssertEqual(W.left(metres: 320, minutes: 4), "4 min · 320 m to go")
    }

    // MARK: the words

    func test_words() {
        XCTAssertEqual(W.short("  Turn right onto   Hoogstraat. "), "Turn right onto Hoogstraat")
        XCTAssertEqual(W.lowerFirst("Turn right onto Hoogstraat"), "turn right onto Hoogstraat")
        XCTAssertEqual(W.lowerFirst("NS station is ahead"), "NS station is ahead")
        XCTAssertEqual(W.metres(3), "5 m")
        XCTAssertEqual(W.metres(42), "40 m")
        XCTAssertEqual(W.metres(437), "440 m")
        XCTAssertEqual(W.metres(1234), "1.2 km")
        let step = W.Step(text: "Turn right onto Hoogstraat", turn: .right, start: 0, end: 10)
        XCTAssertEqual(W.phrase(metres: 41, step: step), "In 40 m · turn right onto Hoogstraat")
        XCTAssertEqual(W.spoken(metres: 41, step: step), "In 40 metres, turn right onto Hoogstraat")
        XCTAssertEqual(W.lockLine(metres: 41, step: step, stop: "Platform 4"), "→ 40 m · Hoogstraat")
        let there = W.Step(text: "The destination is on your right", turn: .arrive, start: 10, end: 10)
        XCTAssertEqual(W.lockLine(metres: 20, step: there, stop: "Platform 4"), "◉ 20 m · Platform 4")
        let bare = W.Step(text: "", turn: .left, start: 0, end: 10)
        XCTAssertEqual(W.phrase(metres: 60, step: bare), "In 60 m · turn left")
        XCTAssertEqual(W.street("Turn right onto Hoogstraat"), "Hoogstraat")
        XCTAssertEqual(W.street("Sla rechtsaf naar de Kerkstraat"), "Kerkstraat")
        XCTAssertNil(W.street("Turn right"))
        for t in W.Turn.allCases { XCTAssertFalse(t.symbol.isEmpty); XCTAssertFalse(t.glyph.isEmpty) }
    }

    // MARK: the lock screen

    func test_lockScreenWalkTurn_optional_andAfterAMiss() throws {
        let json = """
        {"legTitle":"Change at Breda","isTrain":true,"distanceText":"–","finalName":"Breda","awake":false,"goingHome":false,
         "kicker":"CHANGE HERE","stopName":"Breda","progress":1,"songPlaying":false,"changeText":"Platform 5 → 7"}
        """
        var s = try JSONDecoder().decode(TripAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(s.walkTurn, "a state from before 0.41 still decodes")
        XCTAssertEqual(s.changeLine, "Platform 5 → 7")
        s.walkTurn = "→ 40 m · Hoogstraat"
        let back = try JSONDecoder().decode(TripAttributes.ContentState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.walkTurn, "→ 40 m · Hoogstraat")
        XCTAssertEqual(back.changeLine, "→ 40 m · Hoogstraat", "walking: the next turn")
        s.changeMiss = "You’ll miss the 08:12"
        XCTAssertEqual(s.changeLine, "You’ll miss the 08:12", "a miss still comes first")
    }
}
