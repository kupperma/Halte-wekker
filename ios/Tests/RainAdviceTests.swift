import XCTest

/// 0.37: rain on the walk of the next trip — which walk, which hour (Open-Meteo's value is the hour before its time),
/// the bus instead, and the words.
final class RainAdviceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_799_996_400)     // on the hour (499 999 × 3600)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }
    private func hhmm(_ d: Date) -> String { "+\(Int(d.timeIntervalSince(t0) / 60))" }
    private func hours(_ mm: [Double]) -> [RainAdvice.Hour] {
        mm.enumerated().map { RainAdvice.Hour(time: at(Double($0.offset + 1) * 60), mm: $0.element) }   // hour i: [i h, i+1 h]
    }

    func test_stretches() {
        let s = RainAdvice.stretches(start: at(10), walkBefore: 8, lastArrival: at(60), end: at(70))
        XCTAssertEqual(s, [.init(from: at(10), to: at(18), atStart: true), .init(from: at(60), to: at(70), atStart: false)])
        XCTAssertTrue(RainAdvice.stretches(start: at(10), walkBefore: 1, lastArrival: at(60), end: at(61)).isEmpty, "no walk to speak of")
    }

    func test_rainOnTheWalkThere() {
        let s = RainAdvice.stretches(start: at(40), walkBefore: 10, lastArrival: at(100), end: at(105))
        // dry first hour, 0.8 mm the second (from +60): the walk +40…+50 is dry
        XCTAssertNil(RainAdvice.hit(s, here: hours([0.1, 0.8]), there: hours([0, 0])))
        // 0.6 mm in the first hour (0…60): rain at the walk's start
        let h = RainAdvice.hit(s, here: hours([0.6, 0]), there: hours([0, 0]))
        XCTAssertEqual(h, .init(at: at(40), mm: 0.6, atStart: true))
    }

    func test_rainOnTheWalkFromTheLastStop() {
        let s = RainAdvice.stretches(start: at(40), walkBefore: 10, lastArrival: at(55), end: at(70))
        // there: rain from +60 (the second hour)
        let h = RainAdvice.hit(s, here: hours([0, 0]), there: hours([0, 2.0]))
        XCTAssertEqual(h, .init(at: at(60), mm: 2.0, atStart: false))
    }

    func test_thresholdIsHalfAMillimetre() {
        let s = RainAdvice.stretches(start: at(10), walkBefore: 10, lastArrival: at(30), end: at(30))
        XCTAssertNil(RainAdvice.hit(s, here: hours([0.49]), there: []))
        XCTAssertNotNil(RainAdvice.hit(s, here: hours([0.5]), there: []))
    }

    func test_onlyBeforeATrip() {
        XCTAssertTrue(RainAdvice.due(start: at(170), now: at(0)))
        XCTAssertFalse(RainAdvice.due(start: at(190), now: at(0)), "more than 3 hours ahead")
        XCTAssertTrue(RainAdvice.due(start: at(0), now: at(4)))
        XCTAssertFalse(RainAdvice.due(start: at(0), now: at(6)), "you've left")
    }

    func test_busInstead() {
        let ok = RainAdvice.Bus(line: "305", departure: at(20), walkBefore: 2, arrives: at(35), deadline: at(38))
        let late = RainAdvice.Bus(line: "306", departure: at(25), walkBefore: 2, arrives: at(40), deadline: at(38))
        let far = RainAdvice.Bus(line: "158", departure: at(15), walkBefore: 7, arrives: at(30), deadline: at(38))
        let gone = RainAdvice.Bus(line: "90", departure: at(11), walkBefore: 2, arrives: at(30), deadline: at(38))
        XCTAssertEqual(RainAdvice.bus(instead: 12, now: at(10), from: [late, far, gone, ok]), ok)
        XCTAssertNil(RainAdvice.bus(instead: 12, now: at(10), from: [late, far, gone]))
        // a 6-minute walk: at most 2 minutes to the bus
        XCTAssertEqual(RainAdvice.bus(instead: 6, now: at(10), from: [ok]), ok)
        XCTAssertNil(RainAdvice.bus(instead: 6, now: at(10), from: [.init(line: "1", departure: at(20), walkBefore: 3, arrives: at(30), deadline: at(38))]))
    }

    func test_adviceAndWords() {
        let start = RainAdvice.Hit(at: at(60), mm: 1, atStart: true)
        let end = RainAdvice.Hit(at: at(60), mm: 1, atStart: false)
        let b = RainAdvice.Bus(line: "305", departure: at(41), walkBefore: 2, arrives: at(55), deadline: at(58))
        XCTAssertEqual(RainAdvice.advice(start, firstIsTrain: true, walkBefore: 12, bus: b), .bus(line: "305", at: at(41)))
        XCTAssertEqual(RainAdvice.advice(start, firstIsTrain: false, walkBefore: 12, bus: b), .umbrella, "the walk is to a bus already")
        XCTAssertEqual(RainAdvice.advice(start, firstIsTrain: true, walkBefore: 4, bus: b), .umbrella, "a short walk")
        XCTAssertEqual(RainAdvice.advice(end, firstIsTrain: true, walkBefore: 12, bus: b), .umbrella, "rain on the way from the last stop")
        XCTAssertEqual(RainAdvice.advice(start, firstIsTrain: true, walkBefore: 12, bus: nil), .umbrella)
        XCTAssertEqual(RainAdvice.text(start, .bus(line: "305", at: at(41)), hhmm: hhmm),
                       "Rain at +60 — take bus 305 at +41 to the station instead of walking")
        XCTAssertEqual(RainAdvice.text(start, .bus(line: "N1", at: at(41)), hhmm: hhmm),
                       "Rain at +60 — take the N1 at +41 to the station instead of walking")
        XCTAssertEqual(RainAdvice.text(end, .umbrella, hhmm: hhmm), "Rain at +60 — bring an umbrella")
    }
}
