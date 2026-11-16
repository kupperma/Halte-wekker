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

    func test_export() {
        let log = FieldLog(defaults: suite())
        // 07:12:03 UTC
        let day: Int = 1_800_000_000 - 1_800_000_000 % 86_400
        let at = Date(timeIntervalSince1970: TimeInterval(day + 25_923))      // 7 h 12 min 3 s
        log.add(.net, "x", at: at)
        XCTAssertEqual(log.export(timeZone: TimeZone(identifier: "Europe/Amsterdam")!), "08:12:03 net x")
    }
}
