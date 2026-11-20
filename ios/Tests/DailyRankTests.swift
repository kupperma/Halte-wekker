import XCTest

/// Today's best and worst trip (0.35): the rules and the words, as in docs/superpowers/specs/2026-11-18-friends-design.md,
/// "As built (0.35)" (the worked example there is `test_withFriends`).
final class DailyRankTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)          // Friday 15 January 2027, 09:00 in Amsterdam
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }()
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func score(_ mins: Double, home: Bool = false, at: Date, plan: Double? = nil, line: String? = nil, late: Double? = nil) -> TripScore {
        TripScore(id: "t\(Int(at.timeIntervalSince1970))", at: at, home: home, route: home ? "school→home" : "home→school", mins: mins,
                  score: 500, grade: "S", ref: Int(mins), est: true, plan: plan, lateLine: line, late: late)
    }

    func test_duration() {
        XCTAssertEqual(DailyRank.duration(41.2), "41 min")
        XCTAssertEqual(DailyRank.duration(60), "1 h")
        XCTAssertEqual(DailyRank.duration(65), "1 h 05")
        XCTAssertEqual(DailyRank.duration(72), "1 h 12")
        XCTAssertEqual(DailyRank.duration(59.6), "1 h")
    }

    /// The worked example: this morning to school, you 48.5 min, Sam 41, Tom 72 (the 305 18 min late).
    func test_withFriends() {
        let me = DailyRank.today([score(48.5, at: t(-1800))], now: t0, calendar: cal)
        let sam = [DayTrip(home: false, mins: 41, at: t(-2400), plan: 40)]
        let tom = [DayTrip(home: false, mins: 72, at: t(-600), plan: 52, line: "305", late: 18)]
        let rows = DailyRank.rows([(id: "me", trips: me), (id: "sam", trips: sam), (id: "tom", trips: tom)], mine: [], now: t0, calendar: cal)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].fastest.who, "sam")
        XCTAssertEqual(rows[0].slowest?.who, "tom")
        XCTAssertEqual(rows[0].count, 3)
        XCTAssertFalse(rows[0].mine)
        let names = ["sam": "Sam", "tom": "Tom"]
        XCTAssertEqual(DailyRank.lines(rows[0], name: { names[$0] ?? "?" }),
                       ["🏆 Fastest today: Sam, 41 min", "🐌 Slowest today: Tom, 1 h 12 — the 305 was 18 min late"])
    }

    func test_youAreFastest_andNoReason() {
        let rows = DailyRank.rows([(id: "me", trips: [DayTrip(home: true, mins: 39, at: t(-60))]),
                                   (id: "kim", trips: [DayTrip(home: true, mins: 47, at: t(-120), plan: 45)])], mine: [], now: t0, calendar: cal)
        XCTAssertEqual(DailyRank.lines(rows[0], name: { _ in "Kim" }), ["🏆 Fastest today: you, 39 min", "🐌 Slowest today: Kim, 47 min"])
        // over the plan by 5 or more says so (and a late ride under 3 minutes doesn't count)
        XCTAssertEqual(DailyRank.why(DayTrip(home: true, mins: 70, at: t0, plan: 50, line: "IC", late: 2)), " — 20 min more than planned")
        XCTAssertEqual(DailyRank.why(DayTrip(home: true, mins: 53, at: t0, plan: 50)), "")
    }

    /// On your own: against your usual (the median of the last 28 days, from 3 trips).
    func test_onYourOwn() {
        let past: [TripScore] = [score(50, at: t(-86400)), score(46, at: t(-2 * 86400)), score(52, at: t(-3 * 86400)),
                                 score(30, at: t(-40 * 86400)), score(60, home: true, at: t(-86400))]
        XCTAssertEqual(DailyRank.usual(past, home: false, now: t0, calendar: cal), 50)
        XCTAssertNil(DailyRank.usual(past, home: true, now: t0, calendar: cal))
        let todays = [score(41, at: t(-3600)), score(65, at: t(-1200), line: "Intercity", late: 9)]
        let all = todays + past
        let rows = DailyRank.rows([(id: "me", trips: DailyRank.today(all, now: t0, calendar: cal))], mine: all, now: t0, calendar: cal)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].mine)
        XCTAssertEqual(DailyRank.lines(rows[0], name: { $0 }),
                       ["🏆 Fastest today: 41 min · 9 min quicker than usual", "🐌 Slowest today: 1 h 05 — the Intercity was 9 min late"])
        let one = DailyRank.rows([(id: "me", trips: DailyRank.today([score(51, at: t(-60))] + past, now: t0, calendar: cal))],
                                 mine: past, now: t0, calendar: cal)
        XCTAssertEqual(DailyRank.lines(one[0], name: { $0 }), ["Today: 51 min · about your usual"])
        XCTAssertEqual(DailyRank.vsUsual(56, usual: 50), " · 6 min slower than usual")
        XCTAssertEqual(DailyRank.vsUsual(56, usual: nil), "")
    }

    /// Yesterday's trips are gone at local midnight (also a friend's, whatever their box still says).
    func test_resetsAtMidnight() {
        let lastNight = Date(timeIntervalSince1970: 1_799_967_600 - 60)      // Thursday 23:59
        let mine = [score(45, at: lastNight)]
        XCTAssertEqual(DailyRank.today(mine, now: t0, calendar: cal), [])
        XCTAssertEqual(DailyRank.today(mine, now: lastNight.addingTimeInterval(30), calendar: cal).count, 1)
        let rows = DailyRank.rows([(id: "sam", trips: [DayTrip(home: false, mins: 41, at: lastNight)])], mine: [], now: t0, calendar: cal)
        XCTAssertEqual(rows, [])
    }

    /// Both ways today: to school first.
    func test_bothWaysAndTies() {
        let rows = DailyRank.rows([(id: "me", trips: [DayTrip(home: true, mins: 50, at: t(-60)), DayTrip(home: false, mins: 44, at: t(-7200))]),
                                   (id: "ann", trips: [DayTrip(home: false, mins: 44, at: t(-7200))])], mine: [], now: t0, calendar: cal)
        XCTAssertEqual(rows.map(\.home), [false, true])
        XCTAssertEqual(rows[0].fastest.who, "me", "a tie: the same time, you first")
        XCTAssertEqual(rows[0].slowest?.who, "me")
        XCTAssertNil(rows[1].slowest)
    }

    func test_valid() {
        let list: [DayTrip] = [DayTrip(home: false, mins: 4, at: t0),
                               DayTrip(home: false, mins: 41, at: t0, plan: 700, line: " \u{7}305  ", late: 18),
                               DayTrip(home: true, mins: 50, at: t0, plan: 45, line: "IC", late: 0.5),
                               DayTrip(home: true, mins: 50, at: t0, plan: nil, line: "", late: 5)]
        XCTAssertEqual(DayTrip.valid(list), [DayTrip(home: false, mins: 41, at: t0, line: "305", late: 18),
                                             DayTrip(home: true, mins: 50, at: t0, plan: 45),
                                             DayTrip(home: true, mins: 50, at: t0)])
        XCTAssertNil(DayTrip.valid(nil))
        XCTAssertEqual(DayTrip.valid(Array(repeating: DayTrip(home: true, mins: 50, at: t0), count: 20))?.count, 12)
    }
}
