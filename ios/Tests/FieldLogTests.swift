import XCTest

final class FieldLogTests: XCTestCase {
    private func suite() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }
    private let t0 = Fx.t0

    func test_newestFirstAndLimit() {
        let log = FieldLog(defaults: suite(), limit: 3)
        for s in ["a", "b", "c", "d"] { log.add(.net, s) }
        XCTAssertEqual(log.entries.map(\.text), ["d", "c", "b"])
    }

    func test_persistsAfterFlush() {
        let d = suite()
        let log = FieldLog(defaults: d)
        log.add(.net, "one"); log.add(.match, "two")
        log.flush()
        XCTAssertEqual(FieldLog(defaults: d).entries.map(\.text), ["two", "one"])
        log.clear(); log.flush()
        XCTAssertTrue(FieldLog(defaults: d).entries.isEmpty)
    }

    /// The app's log lives in a file: an older log in the settings moves into it once (and goes from there), what was
    /// flushed comes back, and nothing is written before its time without a flush.
    func test_fileStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("fieldlog.json")
        let d = suite()
        let old = FieldLog(defaults: d)
        old.add(.ride, "old ride"); old.flush()
        let log = FieldLog(file: f, migrating: (defaults: d, key: "fieldLog.v1"))
        XCTAssertEqual(log.entries.map(\.text), ["old ride"])
        XCTAssertNil(d.data(forKey: "fieldLog.v1"))
        XCTAssertEqual(FieldLog(file: f).entries.map(\.text), ["old ride"])
        log.add(.net, "n1"); log.flush()
        XCTAssertEqual(FieldLog(file: f).entries.map(\.text), ["n1", "old ride"])
        let slow = FieldLog(file: f, every: 3600)
        slow.add(.match, "m1")
        XCTAssertEqual(FieldLog(file: f).entries.map(\.text), ["n1", "old ride"])
        slow.flush()
        XCTAssertEqual(FieldLog(file: f).entries.map(\.text), ["m1", "n1", "old ride"])
        // the same caps per kind as before
        let capped = FieldLog(file: dir.appendingPathComponent("capped.json"), caps: [.net: 2, .match: 2, .ride: 1])
        for i in 0..<4 { capped.add(.net, "n\(i)") }
        capped.add(.ride, "r0"); capped.add(.ride, "r1")
        XCTAssertEqual(capped.entries.map(\.text), ["r1", "n3", "n2"])
    }

    func test_netFormat() {
        XCTAssertEqual(FieldFormat.net("/v5/plan", lane: .urgent, status: 200, error: nil, bytes: 31_950, seconds: 2.43, attempts: 1),
                       "/v5/plan · 200 · 31.2 KB · 2.4 s · 1 try · urgent")
        XCTAssertEqual(FieldFormat.net("/v5/trip", lane: .background, status: nil, error: .timedOut, bytes: 0, seconds: 15.0, attempts: 1),
                       "/v5/trip · timed out · 0 B · 15.0 s · 1 try · background")
        XCTAssertEqual(FieldFormat.net("/ns/departures", lane: .background, status: 503, error: nil, bytes: 512, seconds: 0.4, attempts: 2),
                       "/ns/departures · 503 · 512 B · 0.4 s · 2 tries · background")
        // a request a pause turned away (never sent), and one that shared another's answer
        XCTAssertEqual(FieldFormat.net("/v6/stoptimes", lane: .background, status: nil, error: nil, bytes: 0, seconds: 0, attempts: 0, note: "cooling down"),
                       "/v6/stoptimes · cooling down · 0 B · 0.0 s · 0 tries · background")
        XCTAssertEqual(FieldFormat.net("/v6/stoptimes", lane: .background, status: 200, error: nil, bytes: 2048, seconds: 0.1, attempts: 1, note: "shared"),
                       "/v6/stoptimes · 200 · 2.0 KB · 0.1 s · 1 try · background · shared")
        func text(_ c: URLError.Code) -> String {
            FieldFormat.net("/x", lane: .urgent, status: nil, error: c, bytes: 0, seconds: 1, attempts: 1)
        }
        XCTAssertTrue(text(.notConnectedToInternet).contains("· offline ·"))
        XCTAssertTrue(text(.networkConnectionLost).contains("· connection lost ·"))
        XCTAssertTrue(text(.cancelled).contains("· cancelled ·"))
        XCTAssertTrue(text(.badURL).contains("· error \(URLError.Code.badURL.rawValue) ·"))
    }

    func test_netFormatHasNoQuery() {
        let s = FieldFormat.net("/v5/plan?fromPlace=51.5934,4.7791&toPlace=51.6,4.8", lane: .urgent, status: 200, error: nil,
                                bytes: 10, seconds: 1, attempts: 1)
        XCTAssertFalse(s.contains("?"))
        XCTAssertFalse(s.contains("51.59"))
        XCTAssertFalse(s.contains("4.77"))
        XCTAssertTrue(s.hasPrefix("/v5/plan · 200"))
    }

    private func evidence(crossTrack: Double = 0, offset: Double = 0, drift: Double = 0, you: Double = 0, it: Double = 0) -> Evidence {
        Evidence(fixes: 6, span: 30, crossTrack: crossTrack, accuracy: 20, shaped: true, progress: 0, offset: offset,
                 drift: drift, yourSpeed: you, itsSpeed: it, steady: true)
    }

    func test_rejectFormat() {
        XCTAssertEqual(FieldFormat.reject(.tooFewFixes, nil), "too few fixes")
        XCTAssertEqual(FieldFormat.reject(.offItsPath, evidence(crossTrack: 180.4)), "off its path 180 m")
        XCTAssertEqual(FieldFormat.reject(.wrongWay, nil), "going the other way")
        XCTAssertEqual(FieldFormat.reject(.implausibleSpeed, evidence(you: 30.2, it: 12)), "wrong speed (you 30 m/s, it 12)")
        XCTAssertEqual(FieldFormat.reject(.standing, nil), "standing by its times")
        XCTAssertEqual(FieldFormat.reject(.drifting, evidence(drift: -18.3)), "drifting 18 m/s")
        XCTAssertEqual(FieldFormat.reject(.tooFarFromTimes, evidence(offset: -2400)), "2400 m from its times")
        XCTAssertEqual(FieldFormat.reject(.noTimes, nil), "no times now")
    }

    func test_matchFormat() {
        let a = Judgement(id: "x-a1b2", line: "IC", isTrain: true, realTime: true, evidence: nil, result: .success(30.4))
        let b = Judgement(id: "y-c3d4", line: "306", isTrain: false, realTime: false,
                          evidence: evidence(crossTrack: 180), result: .failure(.offItsPath))
        XCTAssertEqual(FieldFormat.match("detect", [b, a], outcome: "keep IC·a1b2"),
                       "detect · IC·a1b2 live 30 s | 306·c3d4 timetable off its path 180 m → keep IC·a1b2")
        var many: [Judgement] = []
        for k in 0..<9 {
            let id: String = "id-" + String(1000 + k)
            many.append(Judgement(id: id, line: "1", isTrain: false, realTime: true, evidence: nil, result: .success(Double(k))))
        }
        XCTAssertEqual(FieldFormat.match("find", many, outcome: "none").components(separatedBy: " | ").count, 6)
    }

    func test_outcomeFormat() {
        let lines = ["x-a1b2": "IC", "y-c3d4": "306"]
        XCTAssertEqual(FieldFormat.outcome(.keep("x-a1b2"), lines: lines), "keep IC·a1b2")
        XCTAssertEqual(FieldFormat.outcome(.switchTo("x-a1b2"), lines: lines), "switch to IC·a1b2")
        XCTAssertEqual(FieldFormat.outcome(.undecided(["x-a1b2", "y-c3d4"]), lines: lines), "undecided: IC·a1b2, 306·c3d4")
        XCTAssertEqual(FieldFormat.outcome(.none, lines: lines), "none")
        // what `find` found is only chosen between
        XCTAssertEqual(FieldFormat.outcome(.switchTo("x-a1b2"), lines: lines, choosing: true), "choose IC·a1b2")
        XCTAssertEqual(FieldFormat.outcome(.undecided(["x-a1b2", "y-c3d4"]), lines: lines, choosing: true), "undecided: IC·a1b2, 306·c3d4")
    }

    /// A look while choosing: the 12-minute pick names the one it settles on, also when the decision says keep.
    func test_choiceOutcomeFormat() {
        let lines = ["x-a1b2": "IC", "y-c3d4": "306"]
        func look(_ d: Decision, settle: String?, why: ChoiceLook.Why?) -> ChoiceLook {
            ChoiceLook(decision: d, alive: ["x-a1b2", "y-c3d4"], settle: settle, why: why, shown: .fails, shownFailing: true)
        }
        XCTAssertEqual(FieldFormat.outcome(look(.keep("x-a1b2"), settle: "y-c3d4", why: .timedOut), shown: "x-a1b2", lines: lines),
                       "switch to 306·c3d4")
        XCTAssertEqual(FieldFormat.outcome(look(.keep("x-a1b2"), settle: "x-a1b2", why: .timedOut), shown: "x-a1b2", lines: lines),
                       "keep IC·a1b2")
        XCTAssertEqual(FieldFormat.outcome(look(.switchTo("y-c3d4"), settle: "y-c3d4", why: .decided), shown: "x-a1b2", lines: lines),
                       "switch to 306·c3d4")
        XCTAssertEqual(FieldFormat.outcome(look(.keep("x-a1b2"), settle: nil, why: nil), shown: "x-a1b2", lines: lines),
                       "keep IC·a1b2")
    }

    /// Adds and flushes from many threads at once: what's on disk at the end is the newest list, never an older copy.
    func test_flushNewestLast() {
        let d = suite()
        let log = FieldLog(defaults: d, limit: 1000)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            log.add(.net, "\(i)")
            log.flush()
        }
        log.flush()
        XCTAssertEqual(log.entries.count, 200)
        XCTAssertEqual(FieldLog(defaults: d, limit: 1000).entries.map(\.text), log.entries.map(\.text))
    }

    func test_classicFormat() {
        XCTAssertEqual(FieldFormat.classic("detect", [("306·a1b2", 120.4), ("305·c3d4", 310)]),
                       "detect (classic) · 306·a1b2 120 m | 305·c3d4 310 m")
    }

    func test_notSureFormat() {
        XCTAssertEqual(FieldFormat.notSure("detect", fixes: 4, span: 12.4), "detect · not sure (4 fixes, 12 s)")
        XCTAssertEqual(FieldFormat.notSure("board", fixes: 1, span: 0), "board · not sure (1 fix, 0 s)")
    }

    /// The newest of each kind up to its cap: a burst of requests doesn't push the ride out of the log.
    func test_perKindCaps() {
        let d = suite()
        let log = FieldLog(defaults: d, caps: [.net: 300, .match: 200, .ride: 100])
        log.add(.ride, "r0"); log.add(.match, "m0")
        for i in 0..<500 { log.add(.net, "n\(i)") }
        log.add(.match, "m1"); log.add(.match, "m2"); log.add(.ride, "r1")
        let e = log.entries
        XCTAssertEqual(e.filter { $0.kind == .net }.count, 300)
        XCTAssertEqual(e.filter { $0.kind == .match }.map(\.text), ["m2", "m1", "m0"])
        XCTAssertEqual(e.filter { $0.kind == .ride }.map(\.text), ["r1", "r0"])
        XCTAssertEqual(e.first?.text, "r1")
        XCTAssertEqual(e.filter { $0.kind == .net }.first?.text, "n499")
        XCTAssertEqual(e.filter { $0.kind == .net }.last?.text, "n200")
        for i in 0..<150 { log.add(.ride, "x\(i)") }
        XCTAssertEqual(log.entries.filter { $0.kind == .ride }.count, 100)
        XCTAssertEqual(log.entries.filter { $0.kind == .ride }.last?.text, "x50")
        // what was saved comes back with the same caps
        log.flush()
        XCTAssertEqual(FieldLog(defaults: d).entries, log.entries)
        // the old single limit still caps everything together
        let one = FieldLog(defaults: suite(), limit: 4)
        for i in 0..<3 { one.add(.net, "n\(i)") }
        one.add(.ride, "r"); one.add(.match, "m")
        XCTAssertEqual(one.entries.map(\.text), ["m", "r", "n2", "n1"])
        // a saved log over the caps comes back within them, the newest of each kind
        let d2 = suite()
        let big = FieldLog(defaults: d2, caps: [.net: 1000, .match: 1000, .ride: 1000])
        for i in 0..<5 { big.add(.net, "n\(i)") }
        big.add(.ride, "r0"); big.add(.ride, "r1")
        big.flush()
        XCTAssertEqual(FieldLog(defaults: d2, caps: [.net: 2, .match: 2, .ride: 1]).entries.map(\.text), ["r1", "n4", "n3"])
        // the app's caps
        XCTAssertEqual(FieldLog.caps, [.net: 300, .match: 200, .ride: 100])
    }

    /// Ride lines: no coordinates (no number with 3 or more decimals), only the last 4 characters of a trip id, metres
    /// rounded to 10.
    func test_rideLinePrivacy() {
        let v = FieldFormat.vehicle(line: "321", tripId: "20261116_NL:OVapi:12345:1280", isTrain: false)
        XCTAssertEqual(v, "bus 321·1280")
        let lines = [
            FieldFormat.rideStart(how: "replan at a change", vehicle: v, stopMetres: 183.4, leg: 1, of: 3),
            FieldFormat.rideStart(how: "hand", vehicle: nil, stopMetres: nil, leg: 1, of: 1),
            FieldFormat.rideRefused("replan onto", vehicle: v, stopMetres: 117, accuracy: 15.2),
            FieldFormat.rideWait(moved: 31.7, fromStop: 88.1),
            FieldFormat.rideWait(moved: nil, fromStop: nil),
            FieldFormat.rideWake(startedMetres: 1937.6, after: 42),
            FieldFormat.rideRing("approach", metres: 1604.9, legAge: 25.4, started: 1937.6),
            FieldFormat.rideArrive(why: "by GPS", metres: 226, accuracy: 15, legAge: 12.2, started: 183.4),
            FieldFormat.pickKept(FieldFormat.vehicle(line: "IC", tripId: "trip-abcdef", isTrain: true), metres: 38.6),
            FieldFormat.pickKept("train IC·cdef", metres: nil),
        ]
        let coordinate = try! NSRegularExpression(pattern: #"\d+\.\d{3,}"#)
        for l in lines {
            XCTAssertNil(coordinate.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), l)
            XCTAssertFalse(l.contains("OVapi") || l.contains("12345") || l.contains("trip-ab"), l)
        }
        XCTAssertEqual(lines[0], "start · replan at a change · bus 321·1280 · its stop 180 m from you · leg 1/3")
        XCTAssertEqual(lines[1], "start · hand · no vehicle yet · its stop ? m from you · leg 1/1")
        XCTAssertEqual(lines[2], "refused · replan onto bus 321·1280: its stop 120 m from you (±15)")
        XCTAssertEqual(lines[3], "wait · at a change: not going yet (30 m in 30 s, 90 m from the stop)")
        XCTAssertEqual(lines[4], "wait · at a change: not going yet (too few fixes, ? m from the stop)")
        XCTAssertEqual(lines[5], "wake · silently (started 1940 m from its stop, first fix 42 s in)")
        XCTAssertEqual(lines[6], "ring · approach · 1600 m · leg 25 s old · started 1940 m")
        XCTAssertEqual(lines[7], "arrive · by GPS · 230 m (±15) · leg 12 s old · started 180 m")
        XCTAssertEqual(lines[8], "pick kept · train IC·cdef: 40 m from its road")
        XCTAssertEqual(lines[9], "pick kept · train IC·cdef: its road not known")
        XCTAssertEqual(FieldFormat.metres(-3), "0 m")
        XCTAssertEqual(FieldFormat.metres(.nan), "? m")
        XCTAssertEqual(FieldFormat.metres(14), "10 m")
        XCTAssertEqual(FieldFormat.metres(15), "20 m")
        XCTAssertEqual(FieldFormat.metres(1e300), "10000000 m")              // (no overflow trap)
        XCTAssertEqual(FieldFormat.metres(.greatestFiniteMagnitude), "10000000 m")
    }

    /// A match line always shows the planned (or picked, or shown) one, and how many were judged; the rejected ones by how
    /// near their path is, so the bus you're on isn't hidden behind ICE and FlixBus segments.
    func test_matchShowsPlanned() {
        func far(_ id: String, _ line: String, _ m: Double) -> Judgement {
            Judgement(id: id, line: line, isTrain: true, realTime: true, evidence: evidence(crossTrack: m), result: .failure(.offItsPath))
        }
        var judged: [Judgement] = (0..<8).map { far("ice-\(1000 + $0)", "ICE", 14_000 + Double($0)) }
        // the planned one, 9th in the answer: too far from its times
        judged.append(Judgement(id: "ic-abcd", line: "IC", isTrain: true, realTime: true, evidence: evidence(crossTrack: 20, offset: 900),
                                result: .failure(.tooFarFromTimes)))
        let line = FieldFormat.match("detect", judged, outcome: "none", planned: "ic-abcd", count: judged.count)
        XCTAssertTrue(line.hasPrefix("detect · n=9 · IC·abcd (planned) live 900 m from its times | ICE·1000"), line)
        XCTAssertEqual(line.components(separatedBy: " | ").count, 6)
        // a passing one goes first; the planned one beyond the 6 still shows
        var many: [Judgement] = (0..<7).map { k in
            Judgement(id: "bus-\(2000 + k)", line: "1", isTrain: false, realTime: true, evidence: nil, result: .success(Double(k)))
        }
        many.append(judged[8])
        let l2 = FieldFormat.match("find", many, outcome: "none", planned: "ic-abcd", count: 8)
        XCTAssertEqual(l2.components(separatedBy: " | ").count, 7)
        XCTAssertTrue(l2.contains("| IC·abcd (planned) live 900 m from its times → none"), l2)
        // not in the answer
        let l3 = FieldFormat.match("detect", Array(judged.prefix(3)), outcome: "none", planned: "ic-abcd", count: 3)
        XCTAssertTrue(l3.hasPrefix("detect · n=3 · ICE·1000"), l3)
        XCTAssertTrue(l3.hasSuffix(" | planned ·abcd not in answer → none"), l3)
        let l3b = FieldFormat.match("detect", Array(judged.prefix(3)), outcome: "none", planned: "ic-abcd", count: 3, plannedExcluded: true)
        XCTAssertTrue(l3b.hasSuffix(" | planned ·abcd excluded → none"), l3b)
        // nothing planned: as before
        XCTAssertFalse(FieldFormat.match("detect", judged, outcome: "none").contains("planned"))
        // quick-box rejects (no evidence) after the measured ones, not-sure ones between
        let boxed = Judgement(id: "flix-0001", line: "FlixBus", isTrain: false, realTime: true, evidence: nil, result: .failure(.offItsPath))
        let unsure = Judgement(id: "bus-0002", line: "305", isTrain: false, realTime: true, evidence: nil, result: .failure(.noTimes))
        let l4 = FieldFormat.match("board", [boxed, unsure, far("ice-0003", "ICE", 14_600)], outcome: "none", count: 3)
        XCTAssertEqual(l4, "board · n=3 · ICE·0003 live off its path 14600 m | 305·0002 live no times now | FlixBus·0001 live off its path → none")
    }

    func test_export() {
        let log = FieldLog(defaults: suite())
        // 07:12:03 UTC
        let day: Int = 1_800_000_000 - 1_800_000_000 % 86_400
        let at = Date(timeIntervalSince1970: TimeInterval(day + 25_923))      // 7 h 12 min 3 s
        log.add(.net, "x", at: at)
        XCTAssertEqual(log.export(timeZone: TimeZone(identifier: "Europe/Amsterdam")!), "08:12:03 net x")
    }
}
