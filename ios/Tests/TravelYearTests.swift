import XCTest

/// Your year in travel (0.35): the stats from the kept rides and the leaderboard, the CO₂ maths, the cards' words,
/// and when the home shows its card.
final class TravelYearTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)          // Friday 15 January 2027, 09:00 in Amsterdam
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }()
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let day: TimeInterval = 86400

    private func ride(_ id: String, trip: Date, dep: Date, mins: Double, train: Bool, label: String, from: String, km: Double,
                      late: Double? = nil, coach: Int? = nil) -> RideRecord {
        RideRecord(id: id, trip: trip, dep: dep, arr: dep.addingTimeInterval(mins * 60), train: train, label: label, from: from,
                   to: "x", km: km, late: late, coach: coach)
    }

    /// Two days of the corridor: bus 305 to Den Bosch, then the Intercity to Breda.
    private var rides: [RideRecord] {
        let d1 = t(-2 * day - 2 * 3600)                          // Wednesday 07:00
        let d2 = t(-day - 2 * 3600 - 19 * 60)                    // Thursday 06:41
        return [ride("a", trip: d1, dep: d1, mins: 30, train: false, label: "Bus 305", from: "Veghel, Busstation", km: 20),
                ride("b", trip: d1, dep: d1.addingTimeInterval(40 * 60), mins: 45, train: true, label: "Intercity", from: "'s-Hertogenbosch", km: 50, coach: 3),
                ride("c", trip: d2, dep: d2, mins: 30, train: false, label: "Bus 305", from: "Veghel, Busstation", km: 20, late: 4),
                ride("d", trip: d2, dep: d2.addingTimeInterval(45 * 60), mins: 50, train: true, label: "Intercity", from: "'s-Hertogenbosch", km: 50, late: 23, coach: 3)]
    }

    func test_co2() {
        // 40 km by bus and 100 by train: 40 × 0.14 + 100 × 0.17 = 22.6 kg
        XCTAssertEqual(TravelYear.co2Saved(busKm: 40, trainKm: 100), 22.6, accuracy: 0.0001)
        XCTAssertEqual(TravelYear.co2Saved(busKm: -5, trainKm: 0), 0)
        XCTAssertEqual(TravelYear.km(metres: 10_000, train: false), 13, accuracy: 0.0001)
        XCTAssertEqual(TravelYear.km(metres: 10_000, train: true), 11.5, accuracy: 0.0001)
    }

    func test_stats() {
        let old = TripScore(id: "o", at: t(-30 * day), home: false, route: "Via Den Bosch", mins: 60, score: 450, grade: "A", ref: 55, est: false)
        let s = TravelYear.stats(rides: rides, trips: [old], together: [t(-day), t(-400 * day)], now: t0, calendar: cal)
        XCTAssertEqual(s.rides, 4)
        XCTAssertEqual(s.trips, 3, "two kept trips and one from before the phone kept rides")
        XCTAssertEqual(s.busMinutes, 60)
        XCTAssertEqual(s.trainMinutes, 95)
        XCTAssertEqual(s.earlierMinutes, 60)
        XCTAssertEqual(s.km, 140)
        XCTAssertEqual(s.line, TravelStats.Fav(label: "Intercity", n: 2), "a tie: the one seen last")
        XCTAssertEqual(s.coach, TravelStats.Fav(label: "Coach 3", n: 2))
        XCTAssertEqual(s.delay, TravelStats.Delay(label: "Intercity", mins: 23, at: rides[3].dep))
        XCTAssertEqual(s.earliest, rides[2].dep)
        XCTAssertEqual(s.friends, 1)
        XCTAssertFalse(s.fullYear)
        XCTAssertEqual(s.since, t(-30 * day - 3600))
    }

    func test_cards() {
        let s = TravelYear.stats(rides: rides, trips: [], together: [t(-day)], now: t0, calendar: cal)
        let cards = TravelYear.cards(s, calendar: cal)
        XCTAssertEqual(cards.map(\.id), ["intro", "hours", "km", "co2", "favourite", "early", "delay", "friends"])
        XCTAssertEqual(cards[0].title, "Your travel so far")
        XCTAssertEqual(cards[0].value, "2 trips")
        XCTAssertEqual(cards[0].sub, "Since Wed 13 Jan, on buses and trains.")
        XCTAssertEqual(cards[1].value, "3 h")
        XCTAssertEqual(cards[1].sub, "2 h by train · 1 h by bus.")
        XCTAssertEqual(cards[2].value, "140 km")
        XCTAssertEqual(cards[3].value, "23 kg")                 // 40 km by bus × 0.14 + 100 by train × 0.17 = 22.6
        XCTAssertEqual(cards[4].value, "Intercity")
        XCTAssertEqual(cards[4].sub, "2 rides · most often from 's-Hertogenbosch · coach 3 on the train.")
        XCTAssertEqual(cards[4].shareSub, "2 rides · coach 3 on the train.", "no places in the shared picture")
        XCTAssertEqual(cards[5].value, "06:41")
        XCTAssertEqual(cards[6].sub, "The Intercity on Thu 14 Jan. You made it anyway.")
        XCTAssertEqual(cards[7].value, "1 ride")
        XCTAssertEqual(TravelYear.cards(TravelStats(), calendar: cal), [])
    }

    func test_fullYearAndWords() {
        let first = ride("z", trip: t(-370 * day), dep: t(-370 * day), mins: 20, train: false, label: "Bus 305", from: "A", km: 10)
        let s = TravelYear.stats(rides: [first] + rides, trips: [], together: [], now: t0, calendar: cal)
        XCTAssertTrue(s.fullYear)
        XCTAssertEqual(s.rides, 4, "a ride older than the year isn't counted")
        XCTAssertEqual(TravelYear.cards(s, calendar: cal).first?.title, "Your year in travel")
        XCTAssertEqual(TravelYear.grouped(1240), "1,240")
        XCTAssertEqual(TravelYear.grouped(999), "999")
        XCTAssertEqual(TravelYear.grouped(1_000_000), "1,000,000")
        XCTAssertEqual(TravelYear.hours(0.5), "30 min")
        XCTAssertEqual(TravelYear.hours(37.6), "38 h")
    }

    func test_seasonal() {
        let dec = Date(timeIntervalSince1970: 1_796_202_000)    // Wednesday 2 December 2026, 10:00
        XCTAssertEqual(TravelYear.seasonal(now: dec, firstData: dec.addingTimeInterval(-60 * day), trips: 5, dismissed: nil, calendar: cal), 2026)
        XCTAssertNil(TravelYear.seasonal(now: dec, firstData: nil, trips: 4, dismissed: nil, calendar: cal), "too few trips")
        XCTAssertNil(TravelYear.seasonal(now: dec, firstData: nil, trips: 9, dismissed: 2026, calendar: cal), "put away this year")
        // January: only in the two weeks after a year of rides
        XCTAssertNil(TravelYear.seasonal(now: t0, firstData: t(-100 * day), trips: 9, dismissed: nil, calendar: cal))
        XCTAssertEqual(TravelYear.seasonal(now: t0, firstData: t(-370 * day), trips: 9, dismissed: 2026, calendar: cal), 2027)
        XCTAssertNil(TravelYear.seasonal(now: t0, firstData: t(-380 * day), trips: 9, dismissed: nil, calendar: cal))
    }

    func test_logKeeps() {
        var list: [RideRecord] = []
        list = TravelLog.add(list, rides[1], now: t0)
        list = TravelLog.add(list, rides[0], now: t0)
        list = TravelLog.add(list, rides[0], now: t0)          // the same ride once
        XCTAssertEqual(list.map(\.id), ["a", "b"])
        let ancient = ride("old", trip: t(-900 * day), dep: t(-900 * day), mins: 10, train: false, label: "Bus 1", from: "A", km: 1)
        XCTAssertEqual(TravelLog.add(list, ancient, now: t0).map(\.id), ["a", "b"])
    }
}
