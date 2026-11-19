import XCTest

/// 0.28.1's shared ride logs: what a line may say once it leaves the phone, what goes in one upload, and when.
final class LogShareTests: XCTestCase {
    private let t0 = Fx.t0
    private let utc = TimeZone(identifier: "UTC")!

    private let known = LogScrubKnown(homes: ["Kerkstraat 12", "Veghel"], schools: ["BUas", "Academy campus"],
                                      places: ["Oma Riet", "Sportpark"], people: ["Sanne", "Max"],
                                      ids: ["0123456789abcdef0123456789abcdef"])

    private func scrub(_ s: String) -> String { LogScrub.line(s, known: known) }

    // MARK: lines as the app writes them stay as they are

    func test_realRideLinesKeepTheirMeaning() {
        let start = FieldFormat.rideStart(how: "Home on board, by itself", vehicle: "bus 305·7821", stopMetres: 16630, leg: 1, of: 3)
        XCTAssertEqual(start, "start · Home on board, by itself · bus 305·7821 · its stop 16630 m from you · leg 1/3")
        XCTAssertEqual(scrub(start), start)
        let lines = [
            "detect · n=9 · IC·a1b2 live 30 s | 306·c3d4 timetable off its path 180 m → keep IC·a1b2",
            "same bus · kept by GPS · 305·4779 · 120 m from you, 40 s old (drifting 8 m/s)",
            "board · fast lane · 305·4779 · GPS 120 m from you, 40 s old · 2 fixes, 9 s · you 24 m/s",
            "arrive · by GPS · 230 m (±15) · leg 12 s old · started 180 m",
            "ring · approach · 1600 m · leg 25 s old · started 1940 m",
            "real position · bus 305·4779 · GPS 12 s old · 80 m from its times (behind)",
            "cost · 07:33–08:10 · 37 min · 4% · GPS 36 min · 1.2 MB · 40 checks · 12 LA updates · CPU 0.4 s",
            "hand pick · bus 306·4942 (was 305·4779) · 120 m · gps",
        ]
        for l in lines { XCTAssertEqual(scrub(l), l, l) }
    }

    func test_publicStopNamesStay() {
        XCTAssertEqual(scrub("arrive · at Breda, Centraal Station · 230 m"), "arrive · at Breda, Centraal Station · 230 m")
        XCTAssertEqual(scrub("look · Eindhoven Centraal → Tilburg"), "look · Eindhoven Centraal → Tilburg")
    }

    // MARK: what's personal goes

    func test_yourPlacesBecomeHomeSchoolAndAPlace() {
        XCTAssertEqual(scrub("start · from Kerkstraat 12 to BUas · bus 321·1280"), "start · from Home to School · bus 321·1280")
        XCTAssertEqual(scrub("bus 305 to Veghel, Busstation"), "bus 305 to Home, Busstation")
        XCTAssertEqual(scrub("arrive · at buas · 40 m"), "arrive · at School · 40 m")                 // in any case
        XCTAssertEqual(scrub("ride to Oma Riet and Sportpark"), "ride to a place and a place")
        XCTAssertEqual(scrub("near the Academy campus gate"), "near the School gate")              // the longer name first
        XCTAssertEqual(scrub("BUasX stays"), "BUasX stays")                                         // only whole words
    }

    func test_peopleAndIdsGo() {
        XCTAssertEqual(scrub("shared with Sanne and Max"), "shared with a friend and a friend")
        XCTAssertEqual(scrub("max speed"), "max speed")                                             // a person's name as written
        XCTAssertEqual(scrub("account 0123456789ABCDEF0123456789ABCDEF"), "account [id]")
        XCTAssertEqual(scrub("device fedcba9876543210fedcba9876543210"), "device [id]")          // any long hex
        XCTAssertEqual(scrub("id 3F2504E0-4F89-11D3-9A0C-0305E82C3301"), "id [id]")
        XCTAssertEqual(scrub("token AbCdEfGhIjKlMnOpQrStUvWx12_-"), "token [id]")
        XCTAssertEqual(scrub("trip ·a1b2 · 305·7821"), "trip ·a1b2 · 305·7821")                  // the 4 characters stay
    }

    func test_coordinatesLinksAndAddressesGo() {
        XCTAssertEqual(scrub("fix 51.61612, 5.53125 · 12 m"), "fix [coord] · 12 m")
        XCTAssertEqual(scrub("at 51.6161 5.5312"), "at [coord]")
        XCTAssertEqual(scrub("lat 51.616123"), "lat [coord]")
        XCTAssertEqual(scrub("lon -0.12754"), "lon [coord]")
        XCTAssertEqual(scrub("near 51,61612"), "near [coord]")
        XCTAssertEqual(scrub("pair 51.62,5.53"), "pair [coord]")
        XCTAssertEqual(scrub("get https://example.org/plan?from=51.6&to=x done"), "get [link] done")
        XCTAssertEqual(scrub("mail someone@example.org"), "mail [email]")
        XCTAssertEqual(scrub("1.2 KB · 0.4 s · 16630 m"), "1.2 KB · 0.4 s · 16630 m")             // not coordinates
    }

    func test_oneLineStaysOneLineAndShort() {
        XCTAssertEqual(scrub("a\nb\tc\rd"), "a b c d")
        XCTAssertEqual(scrub(String(repeating: "x", count: 5000)).count, LogScrub.maxLine)
    }

    func test_namesLikeTheLogsOwnWordsAndShortOnesAreLeft() {
        let k = LogScrubKnown(homes: ["Home", "  "], schools: ["School", "AB"], places: ["Bus"], people: ["Ring"])
        XCTAssertTrue(LogScrub.names(k).isEmpty)
        let line = "ring · approach · bus 305·7821 · Home on board"
        XCTAssertEqual(LogScrub.line(line, known: k), line)
    }

    // MARK: one upload

    private func entry(_ s: TimeInterval, _ k: FieldEntry.Kind, _ t: String) -> FieldEntry { FieldEntry(at: t0 + s, kind: k, text: t) }

    func test_batchTakesNewMatchAndRideLinesOldestFirst() {
        let log = [                                                    // newest first, as the field log has them
            entry(40, .ride, "end · by hand"),
            entry(30, .net, "/ns/departures · 200 · 1.2 KB · 0.3 s · 1 try · background"),
            entry(20, .match, "detect · n=2 · 305·7821 live 20 s → choose 305·7821"),
            entry(10, .ride, "start · hand · bus 305·7821 · its stop 180 m from you · leg 1/1"),
            entry(0, .ride, "old · sent already"),
        ]
        let b = LogShareRules.batch(log, after: t0, budget: 10_000, known: known, timeZone: utc)
        XCTAssertEqual(b.lines.count, 3)
        XCTAssertTrue(b.lines[0].hasSuffix(" ride start · hand · bus 305·7821 · its stop 180 m from you · leg 1/1"))
        XCTAssertTrue(b.lines[1].contains(" match detect · "))
        XCTAssertTrue(b.lines[2].hasSuffix(" ride end · by hand"))
        XCTAssertFalse(b.lines.contains { $0.contains("/ns/") })                                   // never the requests
        XCTAssertEqual(b.through, t0 + 40)
        XCTAssertFalse(b.more)
        XCTAssertEqual(b.bytes, b.lines.joined(separator: "\n").utf8.count)
        XCTAssertEqual(LogShareRules.batch(log, after: t0 + 40, budget: 10_000, known: known).lines, [])
    }

    func test_lineFormat() {
        let e = FieldEntry(at: t0, kind: .ride, text: "start · Home on board, by itself · bus 305·7821 · its stop 16630 m from you · leg 1/3")
        // 1_800_000_000 is 2027-01-15 08:00:00 UTC
        XCTAssertEqual(LogShareRules.text(e, known: known, timeZone: utc),
                       "2027-01-15 08:00:00 ride start · Home on board, by itself · bus 305·7821 · its stop 16630 m from you · leg 1/3")
        XCTAssertEqual(LogShareRules.day(t0, timeZone: utc), "2027-01-15")
        XCTAssertEqual(LogShareRules.day(t0 + 16 * 3600, timeZone: utc), "2027-01-16")
    }

    func test_batchStopsAtTheBudgetAndGoesOnFromThere() {
        let log = (0..<10).reversed().map { entry(TimeInterval($0), .match, String(repeating: "m", count: 80)) }
        let one = LogShareRules.text(log.last!, known: known, timeZone: utc).utf8.count
        let b = LogShareRules.batch(log, after: nil, budget: one * 3 + 2, known: known, timeZone: utc)
        XCTAssertEqual(b.lines.count, 3)
        XCTAssertTrue(b.more)
        XCTAssertEqual(b.through, t0 + 2)
        let next = LogShareRules.batch(log, after: b.through, budget: 1_000_000, known: known, timeZone: utc)
        XCTAssertEqual(next.lines.count, 7)
        XCTAssertTrue(LogShareRules.batch(log, after: nil, budget: 0, known: known).lines.isEmpty)
    }

    func test_exampleIsYourNewestRideLineScrubbed() {
        let log = [entry(20, .match, "detect · near BUas"), entry(10, .ride, "start · from Kerkstraat 12 · bus 305·7821")]
        XCTAssertEqual(LogShareRules.example(log, known: known, timeZone: utc), "2027-01-15 08:00:10 ride start · from Home · bus 305·7821")
        XCTAssertNil(LogShareRules.example([entry(0, .net, "/x")], known: known))
        XCTAssertTrue(LogShareRules.sample.contains("ride start · Home on board, by itself · bus 305·7821"))
    }

    // MARK: when, and how much a day

    private func state(lastTry: Date? = nil, day: String = "2027-01-15", sent: Int = 0) -> LogShareState {
        var s = LogShareState.fresh(now: t0, random: { Array(repeating: 7, count: $0) })
        s.lastTry = lastTry; s.day = day; s.sentToday = sent
        return s
    }

    func test_dueAfterATripOrHourly() {
        let today = "2027-01-15"
        func due(_ s: LogShareState, _ trig: LogShareRules.Trigger, running: Bool = false, low: Bool = false, on: Bool = true,
                 at: TimeInterval) -> Bool {
            LogShareRules.due(s, enabled: on, trigger: trig, tripRunning: running, lowPower: low, now: t0 + at, today: today)
        }
        XCTAssertTrue(due(state(), .tick, at: 0))                                      // never tried
        XCTAssertFalse(due(state(), .tick, on: false, at: 0))                         // off: never
        XCTAssertFalse(due(state(), .tripEnded, running: true, at: 0))                // not during a trip
        XCTAssertFalse(due(state(), .tick, low: true, at: 0))                         // not in Low Power Mode
        let tried = state(lastTry: t0)
        XCTAssertFalse(due(tried, .tick, at: 3599))
        XCTAssertTrue(due(tried, .tick, at: 3600))
        XCTAssertFalse(due(tried, .tripEnded, at: 59))
        XCTAssertTrue(due(tried, .tripEnded, at: 60))                                 // a trip ended: soon
        XCTAssertTrue(due(tried, .tick, at: -10))                                     // the clock stepped back
        XCTAssertFalse(due(state(sent: LogShareRules.perDay), .tripEnded, at: 0))    // the day's 2 MB used up
        XCTAssertTrue(due(state(day: "2027-01-14", sent: LogShareRules.perDay), .tripEnded, at: 0))   // that was yesterday
    }

    func test_budgetAndCounting() {
        let today = "2027-01-15"
        XCTAssertEqual(LogShareRules.budget(state(), today: today), 200 * 1024)
        XCTAssertEqual(LogShareRules.budget(state(sent: LogShareRules.perDay - 1000), today: today), 1000)
        XCTAssertEqual(LogShareRules.budget(state(day: "2027-01-14", sent: LogShareRules.perDay), today: today), 200 * 1024)
        let b = LogShareBatch(lines: ["a"], bytes: 500, through: t0 + 9)
        var s = LogShareRules.sent(state(sent: 100), b, now: t0 + 10, today: today)
        XCTAssertEqual(s.sentToday, 600)
        XCTAssertEqual(s.through, t0 + 9)
        XCTAssertTrue(s.sentEver)
        s = LogShareRules.sent(s, b, now: t0 + 90_000, today: "2027-01-16")
        XCTAssertEqual(s.sentToday, 500)                                               // a new day starts at 0
        XCTAssertEqual(s.day, "2027-01-16")
        XCTAssertEqual(LogShareRules.tried(s, now: t0 + 5).lastTry, t0 + 5)
    }

    // MARK: the install id

    func test_installIdAndSecret() {
        let s = LogShareState.fresh(now: t0)
        XCTAssertEqual(s.install.count, 32)
        XCTAssertEqual(s.secret.count, 64)
        XCTAssertEqual(s.through, t0)                                                 // only lines from now on
        XCTAssertNotEqual(s.install, LogShareState.fresh(now: t0).install)
        let fixed = LogShareState.fresh(now: t0, random: { Array(repeating: 0xab, count: $0) })
        XCTAssertEqual(fixed.install, String(repeating: "ab", count: 16))
        var sent = fixed; sent.sentEver = true; sent.through = t0 + 99
        let r = sent.rotated()
        XCTAssertNotEqual(r.install, sent.install)
        XCTAssertNotEqual(r.secret, sent.secret)
        XCTAssertFalse(r.sentEver)
        XCTAssertEqual(r.through, t0 + 99)                                            // what went isn't sent again
        let data = try? JSONEncoder().encode(r)
        XCTAssertEqual(LogShareState.decode(data), r)
        var odd = r; odd.install = "not hex"
        XCTAssertNil(LogShareState.decode(try? JSONEncoder().encode(odd)))
        XCTAssertNil(LogShareState.decode(Data("{}".utf8)))
        XCTAssertNil(LogShareState.decode(nil))
    }

    func test_putCarriesOnlyItsFourFields() throws {
        let put = LogSharePut(install: String(repeating: "a", count: 32), secret: String(repeating: "b", count: 64),
                              app: "0.28.1 (117)", lines: ["2027-01-15 08:00:00 ride end · by hand"])
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(put)) as? [String: Any]
        XCTAssertEqual(Set(obj?.keys.map { $0 } ?? []), ["install", "secret", "app", "lines"])
        let del = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LogShareDelete(install: put.install, secret: put.secret))) as? [String: Any]
        XCTAssertEqual(Set(del?.keys.map { $0 } ?? []), ["install", "secret"])
    }

    // MARK: gzip

    func test_crc32() {
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(Gzip.crc32(Data()), 0)
    }

    func test_gzipWrapsRawDeflate() throws {
        let text = Data((0..<200).map { "2027-01-15 08:00:\($0 % 60) ride start · bus 305·7821" }.joined(separator: "\n").utf8)
        let z = try XCTUnwrap(Gzip.compress(text))
        XCTAssertEqual(Array(z.prefix(4)), [0x1F, 0x8B, 0x08, 0x00])
        XCTAssertLessThan(z.count, text.count)
        let body = z.subdata(in: 10..<(z.count - 8))
        let back = try (body as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(back, text)
        let tail = Array(z.suffix(8))
        XCTAssertEqual(le32(tail, 0), Gzip.crc32(text))
        XCTAssertEqual(Int(le32(tail, 4)), text.count)
    }

    private func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(b[i + k]) << UInt32(8 * k) }
        return v
    }
}
