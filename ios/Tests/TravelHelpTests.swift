import XCTest

final class TravelHelpTests: XCTestCase {
    private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }()
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private let hhmm: (Date) -> String = { d in
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "Europe/Amsterdam"); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    // MARK: check-out

    func test_checkOut_endAndChanges() {
        let bus = CheckOut.Ride(train: false), ns = CheckOut.Ride(train: true, company: "NS"), arriva = CheckOut.Ride(train: true, company: "Arriva")
        let train = CheckOut.Ride(train: true)
        XCTAssertTrue(CheckOut.due(after: 0, of: [bus]))                         // the end of the trip
        XCTAssertTrue(CheckOut.due(after: 0, of: [train, bus]))                  // train → bus
        XCTAssertTrue(CheckOut.due(after: 0, of: [bus, train]))                  // bus → train
        XCTAssertTrue(CheckOut.due(after: 0, of: [bus, bus]))                    // off every bus
        XCTAssertFalse(CheckOut.due(after: 0, of: [ns, ns]))                     // NS to NS: stay checked in
        XCTAssertFalse(CheckOut.due(after: 0, of: [train, train]))               // company unknown: as one
        XCTAssertTrue(CheckOut.due(after: 0, of: [ns, arriva]))                  // between companies
        XCTAssertTrue(CheckOut.due(after: 1, of: [ns, ns]))
        XCTAssertFalse(CheckOut.due(after: 2, of: [ns, ns]))
        XCTAssertFalse(CheckOut.due(after: -1, of: [ns]))
    }

    func test_checkOut_stillAboard() {
        XCTAssertTrue(CheckOut.stillAboard(speeds: [], sameVehicle: true))
        XCTAssertTrue(CheckOut.stillAboard(speeds: [12, 9.5], sameVehicle: false))
        XCTAssertFalse(CheckOut.stillAboard(speeds: [12, 1.2], sameVehicle: false))   // one fast fix isn't enough
        XCTAssertFalse(CheckOut.stillAboard(speeds: [1.4, 1.3, .nan], sameVehicle: false))
        XCTAssertEqual(CheckOut.after, 60)
    }

    func test_checkOut_words() {
        XCTAssertEqual(CheckOut.text(at: "Breda").title, "Did you check out?")
        XCTAssertTrue(CheckOut.text(at: "Breda").body.contains("You’re at Breda"))
        XCTAssertTrue(CheckOut.text(at: "Breda", change: (true, false)).body.contains("from train to bus"))
        XCTAssertTrue(CheckOut.text(at: "Tilburg", change: (true, true)).body.contains("train company"))
    }

    // MARK: delay compensation

    func test_claim_threshold() {
        XCTAssertFalse(DelayClaim.due(minutesLate: 29, told: false))
        XCTAssertTrue(DelayClaim.due(minutesLate: 30, told: false))
        XCTAssertTrue(DelayClaim.due(minutesLate: 29.6, told: false))           // shown as 30
        XCTAssertTrue(DelayClaim.due(minutesLate: 34, told: false))
        XCTAssertFalse(DelayClaim.due(minutesLate: 34, told: true))             // once per trip
        XCTAssertFalse(DelayClaim.due(minutesLate: nil, told: false))
        XCTAssertFalse(DelayClaim.due(minutesLate: .nan, told: false))
    }

    func test_claim_lateness() {
        let p = at(2026, 11, 20, 8, 30)
        // a missed change: each train on time by its own times, the journey 32 min late
        XCTAssertEqual(DelayClaim.minutesLate(plannedEnd: p, actualEnd: p.addingTimeInterval(32 * 60), trainDelays: [8, 0]), 32)
        // the train's own delay at your stop
        XCTAssertEqual(DelayClaim.minutesLate(plannedEnd: nil, actualEnd: nil, trainDelays: [12, 34]), 34)
        XCTAssertEqual(DelayClaim.minutesLate(plannedEnd: p, actualEnd: p.addingTimeInterval(-60), trainDelays: [3]), 3)
        XCTAssertNil(DelayClaim.minutesLate(plannedEnd: nil, actualEnd: nil, trainDelays: []))
    }

    func test_claim_words() {
        let t = DelayClaim.text(minutesLate: 34.2)
        XCTAssertEqual(t.title, "Your train was 34 min late — you can claim money back from NS")
        XCTAssertTrue(t.body.contains("half the fare"))
        XCTAssertTrue(DelayClaim.text(minutesLate: 61).body.contains("whole fare"))
        XCTAssertTrue(DelayClaim.claimURL.hasPrefix("https://www.ns.nl/"))
    }

    // MARK: last way home

    func test_lastTrip_whenWanted() {
        XCTAssertFalse(LastTrip.wanted(now: at(2026, 11, 20, 19, 59), metresFromHome: 10_000))
        XCTAssertTrue(LastTrip.wanted(now: at(2026, 11, 20, 20, 0), metresFromHome: 10_000))
        XCTAssertTrue(LastTrip.wanted(now: at(2026, 11, 21, 1, 0), metresFromHome: 10_000))
        XCTAssertFalse(LastTrip.wanted(now: at(2026, 11, 21, 4, 0), metresFromHome: 10_000))
        XCTAssertFalse(LastTrip.wanted(now: at(2026, 11, 20, 22, 0), metresFromHome: 2_900))   // near home
        XCTAssertFalse(LastTrip.wanted(now: at(2026, 11, 20, 22, 0), metresFromHome: nil))
    }

    func test_lastTrip_arriveByTimes() {
        let ev = LastTrip.arriveBy(now: at(2026, 11, 20, 21, 0))
        XCTAssertEqual(ev, [at(2026, 11, 21, 4), at(2026, 11, 21, 2), at(2026, 11, 21, 1), at(2026, 11, 21, 0)])
        let late = LastTrip.arriveBy(now: at(2026, 11, 21, 0, 50))
        XCTAssertEqual(late, [at(2026, 11, 21, 4), at(2026, 11, 21, 2)])              // (1:00 is too close)
    }

    func test_lastTrip_pick() {
        let now = at(2026, 11, 20, 22, 0)
        func o(_ lh: Int, _ lm: Int, arrive: Date, cancelled: Bool = false, dep: Date? = nil) -> LastTrip.Option {
            let l = lh < 12 ? at(2026, 11, 21, lh, lm) : at(2026, 11, 20, lh, lm)
            return LastTrip.Option(leave: l, firstDeparture: dep ?? l.addingTimeInterval(300), arrive: arrive, from: "Breda", cancelled: cancelled)
        }
        let list = [
            o(23, 10, arrive: at(2026, 11, 21, 0, 5)),
            o(0, 12, arrive: at(2026, 11, 21, 1, 5)),
            o(0, 12, arrive: at(2026, 11, 21, 0, 58)),                                 // the same leave, home sooner
            o(0, 40, arrive: at(2026, 11, 21, 1, 30), cancelled: true),
            o(1, 0, arrive: at(2026, 11, 21, 6, 30), dep: at(2026, 11, 21, 1, 5)),     // a night at a station
            o(21, 50, arrive: at(2026, 11, 20, 22, 40)),                               // gone
        ]
        XCTAssertEqual(LastTrip.pick(list, now: now), 2)
        XCTAssertNil(LastTrip.pick([], now: now))
        XCTAssertEqual(LastTrip.cardText(list[2], hhmm: hhmm), "Last way home leaves 00:12 from Breda")
        XCTAssertEqual(LastTrip.warnAt(list[2], now: now), at(2026, 11, 20, 23, 42))
        XCTAssertNil(LastTrip.warnAt(list[2], now: at(2026, 11, 20, 23, 50)))
        XCTAssertTrue(LastTrip.notice(list[2], hhmm: hhmm).body.contains("00:12"))
    }

    func test_lastTrip_refresh() {
        let now = at(2026, 11, 20, 22, 0), here = GeoPoint(lat: 51.59, lon: 4.78)
        XCTAssertTrue(LastTrip.refreshDue(lastAsked: nil, askedAt: nil, here: here, known: nil, now: now))
        XCTAssertFalse(LastTrip.refreshDue(lastAsked: now.addingTimeInterval(-1800), askedAt: here, here: here, known: nil, now: now))
        XCTAssertTrue(LastTrip.refreshDue(lastAsked: now.addingTimeInterval(-3600), askedAt: here, here: here, known: nil, now: now))
        XCTAssertTrue(LastTrip.refreshDue(lastAsked: now.addingTimeInterval(-600), askedAt: GeoPoint(lat: 51.60, lon: 4.78), here: here, known: nil, now: now))
        let gone = LastTrip.Option(leave: now.addingTimeInterval(-60), firstDeparture: now, arrive: now.addingTimeInterval(3600), from: "Breda")
        XCTAssertTrue(LastTrip.refreshDue(lastAsked: now.addingTimeInterval(-600), askedAt: here, here: here, known: gone, now: now))
    }
}

final class RailWorksTests: XCTestCase {
    private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }()
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private let points: [String: GeoPoint] = [
        "TB": GeoPoint(lat: 51.56055, lon: 5.08361), "TBR": GeoPoint(lat: 51.57361, lon: 4.99444), "GZ": GeoPoint(lat: 51.58361, lon: 4.92611),
        "BD": GeoPoint(lat: 51.59555, lon: 4.78), "ETN": GeoPoint(lat: 51.575, lon: 4.63583), "RSD": GeoPoint(lat: 51.54028, lon: 4.45833),
        "HT": GeoPoint(lat: 51.69048, lon: 5.29362), "BTL": GeoPoint(lat: 51.58433, lon: 5.31912),
    ]
    private func point(_ c: String) -> GeoPoint? { points[c] }

    /// NS's answer as the relay slims it (shape from the live API, November 2026).
    private func sample(start: String = "2026-11-26T04:00:00+0100", end: String = "2026-11-27T02:00:00+0100",
                        stations: [String] = ["TB", "TBR", "GZ", "BD"], cons: [String]? = ["GZ", "BD"],
                        alt: String? = "er rijden stopbussen", type: String = "MAINTENANCE") -> Data {
        func sec(_ l: [String]) -> [String: Any] { ["stations": l.map { ["stationCode": $0, "name": ["TB": "Tilburg", "BD": "Breda", "GZ": "Gilze-Rijen", "TBR": "Tilburg Reeshof"][$0] ?? $0] }, "direction": "BOTH"] }
        var span: [String: Any] = ["start": start, "end": end, "situation": ["label": "Door werkzaamheden: tussen Gilze-Rijen en Breda rijden er bussen."]]
        if let alt { span["alternativeTransport"] = ["label": alt, "shortLabel": alt] }
        var ps: [String: Any] = ["section": sec(stations), "sectionType": "NL"]
        if let cons { ps["consequence"] = ["section": sec(cons), "description": "er rijden bussen", "level": "LESS_TRAINS"] }
        let list: [[String: Any]] = [
            ["id": "7001", "type": type, "title": "Tilburg - Breda.", "isActive": false, "start": start, "end": end, "timespans": [span], "publicationSections": [ps]],
            ["id": "c1", "type": "CALAMITY", "title": "Elsewhere"],
        ]
        return try! JSONSerialization.data(withJSONObject: list)
    }

    func test_parse() {
        let items = RailWorks.parse(sample())
        XCTAssertEqual(items.count, 1)                                   // (the calamity has no stretch)
        let i = items[0]
        XCTAssertEqual(i.id, "7001")
        XCTAssertTrue(i.works)
        XCTAssertEqual(i.stretches, [["GZ", "BD"]])                     // the consequence's part
        XCTAssertEqual(i.names["BD"], "Breda")
        XCTAssertEqual(i.spans.count, 1)
        XCTAssertTrue(i.spans[0].buses)
        XCTAssertTrue(i.spans[0].noTrains)
        XCTAssertEqual(i.spans[0].start, at(2026, 11, 26, 4))
        XCTAssertTrue(RailWorks.parse(Data("nope".utf8)).isEmpty)
        let wrapped = try! JSONSerialization.data(withJSONObject: ["payload": try! JSONSerialization.jsonObject(with: sample())])
        XCTAssertEqual(RailWorks.parse(wrapped).count, 1)
        // no consequence: the whole section
        XCTAssertEqual(RailWorks.parse(sample(cons: nil))[0].stretches, [["TB", "TBR", "GZ", "BD"]])
        XCTAssertFalse(RailWorks.parse(sample(type: "DISRUPTION"))[0].works)
    }

    func test_onYourRide() {
        let tbBd = RailWorks.Ride(from: "TB", to: "BD")
        // Tilburg → Breda passes Gilze-Rijen and Reeshof
        XCTAssertEqual(RailWorks.passed(tbBd, stretch: ["TB", "TBR", "GZ", "BD"], point: point), ["TB", "TBR", "GZ", "BD"])
        XCTAssertEqual(RailWorks.passed(tbBd, stretch: ["GZ", "BD"], point: point), ["GZ", "BD"])
        // Breda – Roosendaal is another line: only Breda is on the way
        XCTAssertEqual(RailWorks.passed(tbBd, stretch: ["BD", "ETN", "RSD"], point: point), ["BD"])
        let item = RailWorks.parse(sample())[0]
        XCTAssertEqual(RailWorks.hit(item, tbBd, point: point), ["GZ", "BD"])
        XCTAssertEqual(RailWorks.hit(item, RailWorks.Ride(from: "BD", to: "TB"), point: point), ["GZ", "BD"])
        XCTAssertNil(RailWorks.hit(item, RailWorks.Ride(from: "HT", to: "BTL"), point: point))
        XCTAssertNil(RailWorks.hit(item, RailWorks.Ride(from: "BD", to: "RSD"), point: point))
        // a station it can't place: only its own two ends count
        XCTAssertEqual(RailWorks.passed(RailWorks.Ride(from: "TB", to: "XX"), stretch: ["TB", "GZ"], point: point), ["TB"])
    }

    func test_impacts_daysAndWindows() {
        let items = RailWorks.parse(sample())
        let rides = [RailWorks.Ride(from: "TB", to: "BD"), RailWorks.Ride(from: "HT", to: "BTL")]
        let now = at(2026, 11, 23, 9)                                   // Monday; the works are Thursday
        let list = RailWorks.impacts(items, rides: rides, now: now, point: point)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].day, "2026-11-26")
        XCTAssertEqual(list[0].fromName, "Gilze-Rijen")
        XCTAssertEqual(list[0].toName, "Breda")
        XCTAssertTrue(list[0].buses && list[0].noTrains && list[0].works)
        // more than 7 days ahead: not yet
        XCTAssertTrue(RailWorks.impacts(items, rides: rides, now: at(2026, 11, 17, 9), point: point).isEmpty)
        // a window that day that misses it (night works, 00:30–06:00)
        let night = RailWorks.parse(sample(start: "2026-11-26T00:30:00+0100", end: "2026-11-26T06:00:00+0100"))
        let schoolOnly: (Date) -> (Date, Date)? = { d in (d.addingTimeInterval(7 * 3600), d.addingTimeInterval(9 * 3600)) }
        XCTAssertTrue(RailWorks.impacts(night, rides: rides, now: now, window: schoolOnly, point: point).isEmpty)
        XCTAssertEqual(RailWorks.impacts(night, rides: rides, now: now, point: point).count, 1)
        // no school that day: no window, nothing
        XCTAssertTrue(RailWorks.impacts(items, rides: rides, now: now, window: { _ in nil }, point: point).isEmpty)
        // today, once it's over: gone
        XCTAssertTrue(RailWorks.impacts(night, rides: rides, now: at(2026, 11, 26, 6), point: point).isEmpty)
    }

    func test_words() {
        let now = at(2026, 11, 23, 21)
        let i = RailWorks.impacts(RailWorks.parse(sample(cons: ["TB", "TBR", "GZ", "BD"])), rides: [RailWorks.Ride(from: "TB", to: "BD")], now: now, point: point)[0]
        XCTAssertEqual(RailWorks.headline(i, now: now, earlier: 10), "Thursday: no trains Tilburg–Breda (works). Leave 10 min earlier — buses replace trains")
        XCTAssertEqual(RailWorks.headline(i, now: now, earlier: nil), "Thursday: no trains Tilburg–Breda (works). Buses replace trains — allow extra time")
        XCTAssertEqual(RailWorks.dayWord(at(2026, 11, 23, 0), now: now), "Today")
        XCTAssertEqual(RailWorks.dayWord(at(2026, 11, 24, 0), now: now), "Tomorrow")
        let fewer = RailWorks.impacts(RailWorks.parse(sample(alt: nil, type: "DISRUPTION").replacingWords()), rides: [RailWorks.Ride(from: "TB", to: "BD")], now: now, point: point)[0]
        XCTAssertEqual(RailWorks.headline(fewer, now: now, earlier: nil), "Thursday: fewer trains Gilze-Rijen–Breda (disruption). Allow extra time")
    }

    func test_leaveEarlier() {
        let be = at(2026, 11, 26, 8, 45)
        XCTAssertEqual(RailWorks.leaveEarlier(usualMinutes: 40, newLeave: at(2026, 11, 26, 7, 55), beThere: be), 10)
        XCTAssertNil(RailWorks.leaveEarlier(usualMinutes: 40, newLeave: at(2026, 11, 26, 8, 4), beThere: be))   // 1 min: nothing
        XCTAssertNil(RailWorks.leaveEarlier(usualMinutes: nil, newLeave: at(2026, 11, 26, 7, 55), beThere: be))
    }

    func test_eveningBefore() {
        let day = at(2026, 11, 26, 0)
        XCTAssertEqual(RailWorks.eveningBefore(day), at(2026, 11, 25, 19, 30))
        let i = RailWorks.impacts(RailWorks.parse(sample()), rides: [RailWorks.Ride(from: "TB", to: "BD")], now: at(2026, 11, 25, 10), point: point)[0]
        XCTAssertFalse(RailWorks.tellNow(i, now: at(2026, 11, 25, 19, 0)))
        XCTAssertTrue(RailWorks.tellNow(i, now: at(2026, 11, 25, 19, 30)))
        XCTAssertTrue(RailWorks.tellNow(i, now: at(2026, 11, 25, 22, 59)))
        XCTAssertFalse(RailWorks.tellNow(i, now: at(2026, 11, 25, 23, 0)))
    }
}

private extension Data {
    /// The sample without "buses" in its words: a disruption with fewer trains.
    func replacingWords() -> Data {
        let s = String(decoding: self, as: UTF8.self)
            .replacingOccurrences(of: "rijden er bussen", with: "rijden minder treinen")
            .replacingOccurrences(of: "er rijden bussen", with: "minder treinen")
        return Data(s.utf8)
    }
}
