import XCTest

/// 0.42.3: false "You’ll miss" calls at a change (`MissCall`, `ChangeGuide`). Synthetic data shaped like a field log:
/// (1a) at the change onto a city bus with no live time and no GPS of its own, "You’ll miss" 78 s after its time,
///      taken back two minutes later (the bus came);
/// (1b) still on the bus into the change, "You’ll miss the train" on stale data of that bus (the train was made);
/// (1c) the ride offered instead was the line you were on, from where you got on.
final class MissCallTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func hhmm(_ d: Date) -> String { "+\(Int((d.timeIntervalSince(t0) / 60).rounded(.down)))" }
    private func bus(_ id: String, _ line: String, _ s: TimeInterval, walk: Int = 1, from: GeoPoint? = nil) -> ChangeGuide.Ride {
        var r = ChangeGuide.Ride(tripId: id, line: line, isTrain: false, departure: at(s), platform: nil, walk: walk)
        r.from = from
        return r
    }
    private func train(_ id: String, _ s: TimeInterval, walk: Int = 2, from: GeoPoint? = nil) -> ChangeGuide.Ride {
        var r = ChangeGuide.Ride(tripId: id, line: "IC", isTrain: true, departure: at(s), platform: "3", walk: walk)
        r.from = from
        return r
    }
    // a made-up station and a stop 3 km off
    private let station = GeoPoint(lat: 51.5950, lon: 4.7800)
    private let away = GeoPoint(lat: 51.6200, lon: 4.7900)

    // MARK: (1a) at the change, nothing live

    func test_1a_noLiveNoGPS_isLookOutNotMissed_untilItsTimeAndThreeMinutes() {
        let blind = MissCall.Next(live: false, seen: .none, youMetres: 400)
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: blind, now: at(-120)), .fine, "before its time: the countdown")
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: blind, now: at(78)), .lookOut, "78 s after its time: look out for it")
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: blind, now: at(179)), .lookOut)
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: blind, now: at(181)), .missed, "3 min after, and you're away from its stop")
        let near = MissCall.Next(live: false, seen: .none, youMetres: 40)
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: near, now: at(600)), .lookOut, "at its stop you'd see it come: never missed")
        let unknownWhere = MissCall.Next(live: false, seen: .none, youMetres: nil)
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: unknownWhere, now: at(181)), .missed)
    }

    func test_1a_theGuideSaysLookOutQuietly() {
        let next = bus("city-1", "1", 0)
        let later = [bus("city-8", "8", 300)]
        let g = ChangeGuide.guide(arrive: at(-280), arrivePlatform: nil, fromTrain: true, grade: nil, next: next, later: later,
                                  learned: nil, now: at(78), hhmm: hhmm, atChange: true,
                                  seen: MissCall.Next(live: false, seen: .none, youMetres: 60))
        XCTAssertFalse(g.missed)
        XCTAssertNil(g.missText)
        XCTAssertEqual(g.call, .lookOut)
        XCTAssertEqual(g.countdown, "Should be leaving now")
        XCTAssertEqual(g.note, "Look out for it")
        XCTAssertEqual(g.target.tripId, "city-1")
    }

    func test_1a_noMissIsToldThatALaterLookTakesBack() {
        // looks every 30 s from its time on; at +184 s its own GPS turns up at the stop (it was late, and came)
        var hold = MissCall.Hold()
        var told: [TimeInterval] = []
        var t: TimeInterval = 18
        while t <= 240 {
            let seen: MissCall.Seen = t >= 184 ? .notLeft : .none
            let n = MissCall.Next(live: false, seen: seen, youMetres: 200)
            let first: MissCall.Call = MissCall.atChange(departure: at(0), next: n, now: at(t))
            let step = MissCall.step(hold, call: first, key: "1|city-1", now: at(t))
            hold = step.hold
            if step.call == .missed { told.append(t) }
            t += 30
        }
        XCTAssertEqual(told, [], "nothing told, so nothing taken back")
    }

    func test_1a_aLiveTimeWithoutGPS_mayHaveLeftForThreeMinutes() {
        let live = MissCall.Next(live: true, seen: .none, youMetres: 400)
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: live, now: at(50)), .fine, "within the minute's grace")
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: live, now: at(90)), .maybe)
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: MissCall.Next(live: true, seen: .none, youMetres: 30), now: at(90)), .lookOut)
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: live, now: at(200)), .missed)
        // its own GPS decides first
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: MissCall.Next(live: true, seen: .notLeft), now: at(400)), .fine)
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: MissCall.Next(live: false, seen: .gone), now: at(10)), .missed)
        XCTAssertEqual(MissCall.atChange(departure: at(0), next: MissCall.Next(live: true, seen: .gone), now: at(-300)), .fine,
                       "gone by GPS five minutes before its time says nothing")
    }

    func test_1a_seenByItsOwnGPS() {
        XCTAssertEqual(MissCall.seen(vehicleMetres: 1900, stopMetres: 2000, fixAge: 20), .notLeft)
        XCTAssertEqual(MissCall.seen(vehicleMetres: 2100, stopMetres: 2000, fixAge: 20), .none, "just past: not sure")
        XCTAssertEqual(MissCall.seen(vehicleMetres: 2400, stopMetres: 2000, fixAge: 20), .gone)
        XCTAssertEqual(MissCall.seen(vehicleMetres: 2400, stopMetres: 2000, fixAge: 150), .none, "too old to say it's gone")
        XCTAssertEqual(MissCall.seen(vehicleMetres: nil, stopMetres: 2000, fixAge: 20), .none)
    }

    func test_1a_theHoldTellsAMissOnlyOnceItHeldAMinute() {
        var h = MissCall.Hold()
        var s = MissCall.step(h, call: .missed, key: "k", now: at(0))
        XCTAssertEqual(s.call, .maybe)
        h = s.hold
        s = MissCall.step(h, call: .missed, key: "k", now: at(30))
        XCTAssertEqual(s.call, .maybe)
        h = s.hold
        s = MissCall.step(h, call: .missed, key: "k", now: at(61))
        XCTAssertEqual(s.call, .missed)
        h = s.hold
        s = MissCall.step(h, call: .fine, key: "k", now: at(90))
        XCTAssertEqual(s.call, .fine)
        XCTAssertTrue(s.retract, "told, then not: taken back")
        h = s.hold
        s = MissCall.step(h, call: .missed, key: "other", now: at(100))
        XCTAssertEqual(s.call, .maybe, "another ride starts its own hold")
        XCTAssertFalse(s.retract)
    }

    // MARK: (1b) on the way, on stale data

    func test_1b_onTheWay_missedOnlyMoreThanAMinuteShortWithFreshData() {
        // in at +0 by its live times, the train at +90 s, 3 min needed: 1.5 min short
        XCTAssertEqual(MissCall.onTheWay(arrive: at(0), departure: at(90), need: 3, now: at(-60), fresh: false), .tight,
                       "the bus's own data is stale: tight, not missed")
        XCTAssertEqual(MissCall.onTheWay(arrive: at(0), departure: at(90), need: 3, now: at(-60), fresh: true), .missed)
        XCTAssertEqual(MissCall.onTheWay(arrive: at(0), departure: at(130), need: 3, now: at(-60), fresh: true), .tight,
                       "under a minute short: tight")
        XCTAssertEqual(MissCall.onTheWay(arrive: at(0), departure: at(240), need: 3, now: at(-60), fresh: true), .fine)
    }

    func test_1b_freshness() {
        XCTAssertTrue(MissCall.fresh(gpsAge: 60, liveAge: nil))
        XCTAssertFalse(MissCall.fresh(gpsAge: 120, liveAge: nil), "gps over 90 s")
        XCTAssertTrue(MissCall.fresh(gpsAge: 300, liveAge: 100))
        XCTAssertFalse(MissCall.fresh(gpsAge: 300, liveAge: 200), "live times over 2 min")
        XCTAssertFalse(MissCall.fresh(gpsAge: nil, liveAge: nil))
    }

    func test_1b_onTheBus_staleData_saysTightNotMissed() {
        // on bus 4 into the station, the train at +60 s past its arrival; 4 min needed; the bus's data stale
        let next = train("ic-1940", 60, walk: 3, from: station)
        let later = [train("ic-2010", 30 * 60, walk: 3, from: station)]
        let feeding = MissCall.Feeding(tripId: "bus4-a", line: "4", isTrain: false)
        let g = ChangeGuide.guide(arrive: at(0), arrivePlatform: nil, fromTrain: false, grade: nil, next: next, later: later,
                                  learned: 4, now: at(-120), hhmm: hhmm, fresh: false, feeding: feeding, changeAt: [station])
        XCTAssertFalse(g.missed)
        XCTAssertNil(g.missText)
        XCTAssertEqual(g.call, .tight)
        XCTAssertEqual(g.note, "Tight — run")
        XCTAssertEqual(g.target.tripId, "ic-1940", "still the planned one")
    }

    // MARK: (1c) what instead

    func test_1c_theRideInsteadContinuesFromTheChange() {
        let planned = train("ic-1940", 0, from: station)
        let feeding = MissCall.Feeding(tripId: "bus4-a", line: "4", isTrain: false)
        let later: [ChangeGuide.Ride] = [
            bus("bus4-b", "4", 19 * 60),                    // the line you're on again
            bus("bus4-a", "4", 25 * 60),                    // the very ride you're on
            bus("bus7", "7", 10 * 60, from: away),          // from 3 km off
            train("ic-2010", 30 * 60, from: station),       // from the station: fine
            bus("bus9", "9", 12 * 60),                      // where it leaves from not known: kept
        ]
        let ok = MissCall.sane(later, planned: planned, feeding: feeding, changeAt: [station])
        XCTAssertEqual(ok.map(\.tripId), ["ic-2010", "bus9"])
        // the next leg on the same line as the one you're on: a later one of it may be offered
        let same = MissCall.sane([bus("bus4-b", "4", 19 * 60, from: station)], planned: bus("bus4-p", "4", 0), feeding: feeding,
                                 changeAt: [station])
        XCTAssertEqual(same.map(\.tripId), ["bus4-b"])
    }

    func test_1c_neverOffersTheLineYouAreOn_tightRunInstead() {
        // fresh data, well short: missed by the numbers, but the only one "instead" is bus 4 again
        let next = train("ic-1940", 60, walk: 3, from: station)
        let later = [bus("bus4-b", "4", 19 * 60)]
        let feeding = MissCall.Feeding(tripId: "bus4-a", line: "4", isTrain: false)
        let g = ChangeGuide.guide(arrive: at(0), arrivePlatform: nil, fromTrain: false, grade: nil, next: next, later: later,
                                  learned: 4, now: at(-120), hhmm: hhmm, fresh: true, call: .missed, feeding: feeding, changeAt: [station])
        XCTAssertFalse(g.missed)
        XCTAssertNil(g.missText, "never \"take bus 4\"")
        XCTAssertEqual(g.call, .tight)
        // with a sane one: said
        let ok = ChangeGuide.guide(arrive: at(0), arrivePlatform: nil, fromTrain: false, grade: nil, next: next,
                                   later: later + [train("ic-2010", 30 * 60, walk: 3, from: station)], learned: 4, now: at(-120),
                                   hhmm: hhmm, fresh: true, call: .missed, feeding: feeding, changeAt: [station])
        XCTAssertTrue(ok.missed)
        XCTAssertEqual(ok.missText, "You’ll miss the +1 — take the +30 from platform 3")
    }
}
