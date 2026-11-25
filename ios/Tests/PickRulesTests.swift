import XCTest

/// 0.38: picking the bus or train you're on faster: the moment you left the stop (`DepartMatch`), your usual line
/// (`UsualLine`), the bus stopping pattern (`BusStops`) and asking sooner (`AskSooner`), and how `VehicleMatch.choose`
/// takes them. In the matching tests' world (`Fx`): a straight road east, fixes every 2 s.
final class PickRulesTests: XCTestCase {
    private let t0 = Fx.t0      // a Friday, 08:00:00 UTC

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Standing 30 s at the stop (east 0), then off at 8 m/s for 20 s.
    private var leaving: [Fix] {
        Fx.fixes(from: 0, speed: 0, count: 16) + Fx.fixes(from: 16, speed: 8, count: 11, start: t0.addingTimeInterval(32))
    }

    private func bus(_ id: String, line: String, leaves: TimeInterval, live: Bool = true, gps: VehicleGPS? = nil) -> VehicleTrack {
        let piece = TimedPiece(departure: t0.addingTimeInterval(leaves), arrival: t0.addingTimeInterval(leaves + 240),
                               path: [Fx.east(0), Fx.east(1000), Fx.east(2000)])
        return VehicleTrack(tripId: id, line: line, isTrain: false, realTime: live, pieces: [piece], gps: gps)
    }

    private func fix(east m: Double, at s: TimeInterval) -> GPSFix {
        let p = Fx.east(m)
        return GPSFix(lat: p.lat, lon: p.lon, bearing: 90, at: t0.addingTimeInterval(s))
    }

    // MARK: the moment you left

    func test_moment_standingThenMoving() {
        let d = DepartMatch.moment(leaving)
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.t, t0.addingTimeInterval(32))     // the last fix within 25 m of where you stood
        XCTAssertEqual(d?.stood ?? 0, 32, accuracy: 0.01)
        XCTAssertLessThan(Geo.metres(d?.p ?? Fx.east(999), Fx.east(0)), 1)
    }

    func test_moment_noneWhileStandingOrWithoutAStand() {
        XCTAssertNil(DepartMatch.moment(Fx.fixes(from: 0, speed: 0, count: 20)), "still standing")
        XCTAssertNil(DepartMatch.moment(Fx.fixes(from: 0, speed: 10, count: 20)), "never stood")
        XCTAssertNil(DepartMatch.moment(Fx.fixes(from: 0, speed: 0, count: 5) + Fx.fixes(from: 10, speed: 8, count: 10, start: t0.addingTimeInterval(10))),
                     "8 s standing is no stop")
        XCTAssertNil(DepartMatch.moment(Fx.fixes(from: 0, speed: 0, count: 16, accuracy: 120)), "rough fixes say nothing")
    }

    func test_moment_freshness() {
        let d = Departure(t: t0, p: Fx.east(0), stood: 30)
        XCTAssertNotNil(DepartMatch.usable(d, now: t0.addingTimeInterval(200)))
        XCTAssertNil(DepartMatch.usable(d, now: t0.addingTimeInterval(DepartMatch.fresh + 1)))
        XCTAssertNil(DepartMatch.usable(nil, now: t0))
    }

    // MARK: which one left then

    func test_clue_byLiveTimes() {
        let d = Departure(t: t0.addingTimeInterval(32), p: Fx.east(0), stood: 32)
        let a = DepartMatch.clue(bus("305-0001", line: "305", leaves: 40), at: d)
        // (0.39.1: by its live times alone "not then" takes 180 s off: this one leaves 218 s after you)
        let b = DepartMatch.clue(bus("306-0002", line: "306", leaves: 250), at: d)
        XCTAssertEqual(a.offBy ?? -1, 8, accuracy: 0.01)
        XCTAssertEqual(b.offBy ?? -1, 218, accuracy: 0.01)
        XCTAssertTrue(DepartMatch.leftThen(a))
        XCTAssertFalse(DepartMatch.leftThen(b))
        XCTAssertEqual(DepartMatch.pick([a, b], ids: ["306-0002", "305-0001"]), "305-0001")
        XCTAssertEqual(DepartMatch.bonuses([a, b], ids: ["305-0001", "306-0002"]), ["305-0001": -DepartMatch.bonus])
        XCTAssertEqual(DepartMatch.logLine(d, [a, b], lines: ["305-0001": "305", "306-0002": "306"], calendar: utc),
                       "depart · stood 32 s, left 08:00:32 · 305·0001 left then (live 8 s) · 306·0002 not then (live 218 s)")
    }

    func test_clue_timetableOnlySaysNothing() {
        let d = Departure(t: t0.addingTimeInterval(32), p: Fx.east(0), stood: 32)
        let a = DepartMatch.clue(bus("305-0001", line: "305", leaves: 40), at: d)
        let b = DepartMatch.clue(bus("306-0002", line: "306", leaves: 300, live: false), at: d)
        XCTAssertNil(b.offBy)
        XCTAssertNil(DepartMatch.pick([a, b], ids: ["305-0001", "306-0002"]), "the other one may still be it")
        XCTAssertEqual(DepartMatch.bonuses([a, b], ids: ["305-0001", "306-0002"]).count, 1)
    }

    func test_clue_bothLeftTogether() {
        // the 305 and the 306 side by side out of Veghel: both leave within the minute
        let d = Departure(t: t0.addingTimeInterval(32), p: Fx.east(0), stood: 32)
        let a = DepartMatch.clue(bus("305-0001", line: "305", leaves: 30), at: d)
        let b = DepartMatch.clue(bus("306-0002", line: "306", leaves: 60), at: d)
        XCTAssertNil(DepartMatch.pick([a, b], ids: ["305-0001", "306-0002"]))
        XCTAssertTrue(DepartMatch.bonuses([a, b], ids: ["305-0001", "306-0002"]).isEmpty)
    }

    func test_clue_byItsOwnGPS() {
        let d = Departure(t: t0.addingTimeInterval(32), p: Fx.east(0), stood: 32)
        // at the stop 12 s before you left, then on its way
        let with = bus("305-0001", line: "305", leaves: 400, live: false,
                       gps: VehicleGPS(fix: fix(east: 150, at: 50), previous: fix(east: 10, at: 20)))
        // still at the stop 68 s after you left (its newest fix)
        let stayed = bus("306-0002", line: "306", leaves: 40, gps: VehicleGPS(fix: fix(east: 10, at: 100)))
        // a kilometre away when you left
        let away = bus("306-0003", line: "306", leaves: 40, gps: VehicleGPS(fix: fix(east: 1200, at: 40)))
        let a = DepartMatch.clue(with, at: d), b = DepartMatch.clue(stayed, at: d), c = DepartMatch.clue(away, at: d)
        XCTAssertEqual(a.offBy ?? -1, 12, accuracy: 0.01)
        XCTAssertTrue(a.byGPS)
        XCTAssertTrue(b.elsewhere, "its GPS wins over its live times")
        XCTAssertTrue(c.elsewhere)
        XCTAssertEqual(DepartMatch.pick([a, b, c], ids: ["305-0001", "306-0002", "306-0003"]), "305-0001")
        // an older fix at the stop that late, followed by a newer one on its way: it says nothing of staying
        let went = bus("306-0004", line: "306", leaves: 400, live: false,
                       gps: VehicleGPS(fix: fix(east: 200, at: 120), previous: fix(east: 10, at: 100)))
        let w = DepartMatch.clue(went, at: d)
        XCTAssertFalse(w.elsewhere)
        XCTAssertNil(w.offBy)
    }

    // MARK: choosing with it

    private func j(_ id: String, _ r: Result<Double, Reject>, gps: Bool = false) -> Judgement {
        var e = Evidence(fixes: 15, span: 28, crossTrack: 8, accuracy: 15, shaped: true, progress: 300, offset: 0,
                         drift: 0, yourSpeed: 11, itsSpeed: 11, steady: true)
        e.gps = gps
        return Judgement(id: id, line: String(id.prefix(3)), isTrain: false, realTime: true, evidence: e, result: r)
    }

    private func look(_ ids: [String], _ judged: [Judgement], shown: String, at: TimeInterval, misses: inout [String: Int],
                      state: inout SwitchState, gps: inout GPSChoice, nudge: [String: Double] = [:], departed: String? = nil) -> ChoiceLook {
        VehicleMatch.choose(ids, judged: judged, shown: shown, shownOffRoad: false, choosingFor: at, misses: &misses, state: &state,
                            gps: &gps, now: t0.addingTimeInterval(at), nudge: nudge, departed: departed)
    }

    func test_choose_settlesOnTheOneThatLeftWithYou_inTwoLooks() {
        var misses: [String: Int] = [:], state = SwitchState(), gps = GPSChoice()
        let ids = ["306-0002", "305-0001"]
        let judged = [j("306-0002", .success(12)), j("305-0001", .success(20))]
        let first = look(ids, judged, shown: "306-0002", at: 0, misses: &misses, state: &state, gps: &gps, departed: "305-0001")
        XCTAssertNil(first.settle)
        let second = look(ids, judged, shown: "306-0002", at: 12, misses: &misses, state: &state, gps: &gps, departed: "305-0001")
        XCTAssertEqual(second.settle, "305-0001")
        XCTAssertEqual(second.why, .departed)
        XCTAssertEqual(second.decision, .switchTo("305-0001"))
    }

    func test_choose_departedShownIsSure() {
        var misses: [String: Int] = [:], state = SwitchState(), gps = GPSChoice()
        let ids = ["305-0001", "306-0002"]
        let judged = [j("306-0002", .success(12)), j("305-0001", .success(14))]
        _ = look(ids, judged, shown: "305-0001", at: 0, misses: &misses, state: &state, gps: &gps, departed: "305-0001")
        let c = look(ids, judged, shown: "305-0001", at: 12, misses: &misses, state: &state, gps: &gps, departed: "305-0001")
        XCTAssertEqual(c.settle, "305-0001")
        XCTAssertEqual(c.decision, .keep("305-0001"))
    }

    func test_choose_departedRunBreaksWhenItFails() {
        var run = GPSChoice()
        let ok = [j("305-0001", .success(10)), j("306-0002", .success(10))]
        let bad = [j("305-0001", .failure(.drifting)), j("306-0002", .success(10))]
        XCTAssertNil(VehicleMatch.departLook("305-0001", judged: ok, alive: ["305-0001", "306-0002"], run: &run))
        XCTAssertNil(VehicleMatch.departLook("305-0001", judged: bad, alive: ["305-0001", "306-0002"], run: &run))
        XCTAssertNil(VehicleMatch.departLook("305-0001", judged: ok, alive: ["305-0001", "306-0002"], run: &run), "the run started again")
        XCTAssertEqual(VehicleMatch.departLook("305-0001", judged: ok, alive: ["305-0001", "306-0002"], run: &run), "305-0001")
    }

    func test_choose_itsOwnGPSStaysTheClearerEvidence() {
        var run = GPSChoice()
        let judged = [j("306-0002", .success(5), gps: true), j("305-0001", .success(40))]
        for _ in 0..<3 {
            XCTAssertNil(VehicleMatch.departLook("305-0001", judged: judged, alive: ["306-0002", "305-0001"], run: &run))
        }
        var misses: [String: Int] = [:], state = SwitchState(), gps = GPSChoice()
        for k in 0..<4 {
            let c = look(["306-0002", "305-0001"], judged, shown: "306-0002", at: Double(k) * 12, misses: &misses, state: &state,
                         gps: &gps, departed: "305-0001")
            XCTAssertNotEqual(c.settle, "305-0001")
        }
    }

    func test_choose_nudgeMovesTheRanking() {
        let ranked = [Ranked(id: "a", cost: 10), Ranked(id: "b", cost: 20)]
        XCTAssertEqual(VehicleMatch.nudged(ranked, ["a": 15]).map(\.id), ["b", "a"])
        XCTAssertEqual(VehicleMatch.nudged(ranked, [:]), ranked)
        // the one shown 40 s worse by the stopping pattern: switched after 3 looks over 45 s, as any clear lead
        let ids = ["a-0001", "b-0002"]
        let judged = [j("a-0001", .success(20)), j("b-0002", .success(10))]
        var misses: [String: Int] = [:], state = SwitchState(), gps = GPSChoice()
        var out: [ChoiceLook] = []
        for k in 0..<4 {
            out.append(look(ids, judged, shown: "a-0001", at: Double(k) * 15, misses: &misses, state: &state, gps: &gps, nudge: ["a-0001": 40]))
        }
        XCTAssertEqual(out.last?.settle, "b-0002")
        XCTAssertTrue(out.dropLast().allSatisfy { $0.settle == nil })
        // without it: kept (10 s apart is a tie)
        misses = [:]; state = SwitchState(); gps = GPSChoice()
        for k in 0..<4 {
            let c = look(ids, judged, shown: "a-0001", at: Double(k) * 15, misses: &misses, state: &state, gps: &gps)
            XCTAssertNil(c.settle)
        }
    }

    // MARK: your usual line

    private func rides(_ line: String, _ n: Int, minute: Int = 7 * 60 + 40, weekend: Bool = false, weight: Int = 1) -> [LineRide] {
        (0..<n).map { _ in LineRide(line: line, train: false, minute: minute, weekend: weekend, weight: weight) }
    }

    func test_usual_learnedSlot() {
        let r = rides("305", 3)
        let cands: [(id: String, line: String, train: Bool)] = [(id: "a", line: "306", train: false), (id: "b", line: "305", train: false)]
        XCTAssertEqual(UsualLine.usual(cands, minute: 7 * 60 + 45, weekend: false, r), "b")
        XCTAssertNil(UsualLine.usual(cands, minute: 7 * 60 + 45, weekend: true, r), "another kind of day")
        XCTAssertNil(UsualLine.usual(cands, minute: 9 * 60, weekend: false, r), "another time of day")
        XCTAssertNil(UsualLine.usual(cands, minute: 7 * 60 + 45, weekend: false, rides("305", 2)), "not enough rides yet")
        let train: [(id: String, line: String, train: Bool)] = [(id: "a", line: "306", train: false), (id: "b", line: "305", train: true)]
        XCTAssertNil(UsualLine.usual(train, minute: 7 * 60 + 45, weekend: false, r), "a train 305 isn't the bus")
    }

    func test_usual_correctionsCount() {
        let cands: [(id: String, line: String, train: Bool)] = [(id: "a", line: "306", train: false), (id: "b", line: "305", train: false)]
        // 3 rides on the 305, then twice you said you're on the 306: no clear usual line any more
        XCTAssertNil(UsualLine.usual(cands, minute: 460, weekend: false, rides("305", 3) + rides("306", 2, weight: UsualLine.said)))
        // and twice more: the 306 it is
        let more = rides("305", 3) + rides("306", 4, weight: UsualLine.said) + rides("305", 2, weight: UsualLine.notThis)
        XCTAssertEqual(UsualLine.usual(cands, minute: 460, weekend: false, more), "a")
        // two of the usual line: it can't tell them apart
        let two: [(id: String, line: String, train: Bool)] = [(id: "a", line: "305", train: false), (id: "b", line: "305", train: false)]
        XCTAssertNil(UsualLine.usual(two, minute: 460, weekend: false, rides("305", 5)))
    }

    func test_usual_tieBreakWithHysteresis() {
        func c(_ u: Double, _ o: Double, gps: Bool = false) -> [UsualLine.Cand] {
            [UsualLine.Cand(id: "u", cost: u, byGPS: false), UsualLine.Cand(id: "o", cost: o, byGPS: gps)]
        }
        XCTAssertEqual(UsualLine.tieBreak(c(20, 10), usual: "u", held: nil), "u", "10 s apart: a tie")
        XCTAssertNil(UsualLine.tieBreak(c(35, 10), usual: "u", held: nil), "25 s apart: not a tie")
        XCTAssertEqual(UsualLine.tieBreak(c(35, 10), usual: "u", held: "u"), "u", "held: kept within 40 s")
        XCTAssertNil(UsualLine.tieBreak(c(55, 10), usual: "u", held: "u"), "45 s apart: it lets go")
        XCTAssertNil(UsualLine.tieBreak(c(10, 10, gps: true), usual: "u", held: "u"), "never over one by its own GPS")
        XCTAssertNil(UsualLine.tieBreak([UsualLine.Cand(id: "o", cost: 10, byGPS: false)], usual: "u", held: nil), "it didn't pass")
        XCTAssertNil(UsualLine.tieBreak(c(10, 20), usual: nil, held: nil))
    }

    func test_usual_wordsMinuteAndKeep() {
        XCTAssertEqual(UsualLine.words(rides("305", 4) + rides("306", 1)), ["305 at 07:40 on weekdays"])
        XCTAssertEqual(UsualLine.words([]), [])
        XCTAssertEqual(UsualLine.minute(t0.addingTimeInterval(41 * 60), calendar: utc), 8 * 60 + 41)
        XCTAssertFalse(UsualLine.weekend(t0, calendar: utc))
        XCTAssertTrue(UsualLine.weekend(t0.addingTimeInterval(86_400), calendar: utc))
        var kept: [LineRide] = []
        for _ in 0..<(UsualLine.keep + 10) { kept = UsualLine.add(LineRide(line: "305", train: false, minute: 460, weekend: false, weight: 1), to: kept) }
        XCTAssertEqual(kept.count, UsualLine.keep)
        XCTAssertEqual(UsualLine.add(LineRide(line: " ", train: false, minute: 460, weekend: false, weight: 1), to: []), [])
    }

    func test_usual_inTheHabitBook_andOldBooksStillRead() throws {
        var b = HabitBook()
        for _ in 0..<3 { b.rode("305", train: false, minute: 460, weekend: false, weight: UsualLine.confirmed) }
        XCTAssertFalse(b.isEmpty)
        XCTAssertEqual(Habits.rows(b).last, Habits.Row(label: "Your usual lines", value: "305 at 07:40 on weekdays"))
        let back = try JSONDecoder().decode(HabitBook.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
        // saved by 0.37: no `lines`
        let old = Data(#"{"walks":[1.4],"changes":[3],"boardedAt":{"x":1},"plannedAt":{},"names":{"x":"X"}}"#.utf8)
        let read = try JSONDecoder().decode(HabitBook.self, from: old)
        XCTAssertEqual(read.walks, [1.4])
        XCTAssertEqual(read.boardedAt, ["x": 1])
        XCTAssertTrue(read.lines.isEmpty)
    }

    // MARK: the bus stopping pattern

    func test_busStops_stoodAndThrough() {
        let stop = Fx.east(500)
        XCTAssertEqual(BusStops.seen(Fx.fixes(from: 490, speed: 0, count: 10), at: stop), .stood)
        XCTAssertNil(BusStops.seen(Fx.fixes(from: 490, speed: 0, count: 6), at: stop), "10 s isn't a halt")
        XCTAssertEqual(BusStops.seen(Fx.fixes(from: 200, speed: 10, count: 35), at: stop), .through)
        XCTAssertNil(BusStops.seen(Fx.fixes(from: 380, speed: 3, count: 80), at: stop), "crawling past: no telling")
        XCTAssertNil(BusStops.seen(Fx.fixes(from: 200, speed: 10, count: 20), at: stop), "not past it yet")
        XCTAssertNil(BusStops.seen(Fx.fixes(from: 200, speed: 10, count: 35, north: 200), at: stop), "not by it")
    }

    func test_busStops_againstAndPenalties() {
        // Kerk: the 306 calls there, the 305 drives past it; you stood there. Station: the 305 waits there by its
        // timetable; you went through. Markt: the 306 calls there, you went through (a bus passes a stop with nobody at it).
        let stops = [BusStops.Stop(key: "kerk", point: Fx.east(500), served: ["306"], waits: [], passing: ["305", "306"]),
                     BusStops.Stop(key: "station", point: Fx.east(900), served: ["305", "306"], waits: ["305"], passing: ["305", "306"]),
                     BusStops.Stop(key: "markt", point: Fx.east(1300), served: ["306"], waits: [], passing: ["305", "306"])]
        let ids = ["305", "306"]
        let one = BusStops.against(stops, seen: ["kerk": .stood], ids: ids)
        XCTAssertEqual(one, ["305": 1])
        XCTAssertTrue(BusStops.penalties(one, ids: ids).isEmpty, "once is no pattern")
        let two = BusStops.against(stops, seen: ["kerk": .stood, "station": .through, "markt": .through], ids: ids)
        XCTAssertEqual(two, ["305": 2])
        XCTAssertEqual(BusStops.penalties(two, ids: ids), ["305": 2 * BusStops.penalty])
        XCTAssertTrue(BusStops.penalties(["305": 2, "306": 2], ids: ids).isEmpty, "never all of them")
        XCTAssertEqual(BusStops.penalties(["305": 9], ids: ids), ["305": BusStops.maxPenalty])
        XCTAssertTrue(BusStops.penalties(["305": 3], ids: ["305"]).isEmpty)
    }

    // MARK: asking sooner

    func test_ask_dueAfterAMinute() {
        XCTAssertFalse(AskSooner.due(alive: ["a", "b"], movingFor: 59, asked: false, tieBroken: false))
        XCTAssertTrue(AskSooner.due(alive: ["a", "b"], movingFor: 61, asked: false, tieBroken: false))
        XCTAssertFalse(AskSooner.due(alive: ["a", "b"], movingFor: 61, asked: true, tieBroken: false), "once a choice")
        XCTAssertFalse(AskSooner.due(alive: ["a", "b", "c"], movingFor: 61, asked: false, tieBroken: false))
        XCTAssertFalse(AskSooner.due(alive: ["a"], movingFor: 61, asked: false, tieBroken: false))
        XCTAssertFalse(AskSooner.due(alive: ["a", "b"], movingFor: 120, asked: false, tieBroken: true), "your usual line breaks the tie")
        XCTAssertTrue(AskSooner.due(alive: ["a", "b"], movingFor: 181, asked: false, tieBroken: true))
    }

    func test_ask_words() {
        XCTAssertTrue(AskSooner.worthAsking(lines: ("305", "306"), destinations: ("", "")))
        XCTAssertFalse(AskSooner.worthAsking(lines: ("306", "306"), destinations: ("Den Bosch", "den bosch")))
        XCTAssertTrue(AskSooner.worthAsking(lines: ("306", "306"), destinations: ("Uden", "Den Bosch")))
        XCTAssertEqual(AskSooner.title(("305", "Eindhoven"), ("306", "Den Bosch"), train: false), "305 or 306?")
        XCTAssertEqual(AskSooner.title(("306", "Uden"), ("306", "Den Bosch"), train: false), "306 to Uden or 306 to Den Bosch?")
        XCTAssertEqual(AskSooner.title(("IC", "Breda"), ("IC", "Eindhoven"), train: true), "IC to Breda or IC to Eindhoven?")
        XCTAssertEqual(AskSooner.answer(line: "305", to: "Eindhoven", train: false, sameLine: false), "Bus 305")
        XCTAssertEqual(AskSooner.answer(line: "306", to: "Uden", train: false, sameLine: true), "Bus 306 to Uden")
        XCTAssertEqual(AskSooner.answer(line: "IC", to: "Breda", train: true, sameLine: true), "IC to Breda")
        XCTAssertTrue(AskSooner.body(train: false).hasPrefix("Two buses"))
        XCTAssertTrue(AskSooner.body(train: true).hasPrefix("Two trains"))
    }
}
