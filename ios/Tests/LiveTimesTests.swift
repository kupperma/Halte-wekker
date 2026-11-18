import XCTest

final class LiveTimesTests: XCTestCase {
    private let t0 = Fx.t0

    /// `h:m` on the test day, as minutes after 10:00 from t0.
    private func at(_ minutes: Double) -> Date { t0 + minutes * 60 }

    /// A stop with one time (arrives and leaves at once), or two.
    private func stop(_ live: Double, _ sched: Double, leaves: Double? = nil, schedLeaves: Double? = nil) -> StopTimes {
        StopTimes(arrival: at(live), departure: at(leaves ?? live), scheduledArrival: at(sched), scheduledDeparture: at(schedLeaves ?? sched))
    }

    /// Line 74 towards Utrecht CS as measured: +4 at Kanaleneiland-Zuid, caught up to on time three stops on.
    func test_line74Utrecht() {
        // timetable K 10:28, E 10:31, L 10:32, T 10:34, CS 10:38/10:40, V 10:48; live K 10:32 … CS 10:38/10:40, V 10:48
        let s = [stop(32, 28), stop(34, 31), stop(34, 32), stop(35, 34), stop(38, 38, leaves: 40, schedLeaves: 40), stop(48, 48)]
        let out = LiveTimes.noCatchUp(s, asOf: at(32) + 39)
        XCTAssertEqual(out[0], s[0])
        XCTAssertEqual(out[1].arrival, at(35)); XCTAssertEqual(out[1].departure, at(35))
        XCTAssertEqual(out[2].arrival, at(36))
        XCTAssertEqual(out[3].arrival, at(38))
        XCTAssertEqual(out[4].arrival, at(42)); XCTAssertEqual(out[4].departure, at(42))      // 2 min waited out of the 4
        XCTAssertEqual(out[5].arrival, at(48))                                               // past the horizon, still in order
    }

    private func grid() -> [[StopTimes]] {
        var out: [[StopTimes]] = []
        for delay in [-3.0, 0, 0.5, 1, 2, 5, 9] {
            for decay in [0.0, 0.5, 1, 2] {
                for wait in [0.0, 1, 3] {
                    var s: [StopTimes] = []
                    var d = delay
                    for k in 0..<12 {
                        let sch = Double(k) * 3
                        let w = k == 5 ? wait : 0
                        s.append(StopTimes(arrival: at(sch + d), departure: at(sch + w + d), scheduledArrival: at(sch), scheduledDeparture: at(sch + w)))
                        d = max(0, d - decay)
                    }
                    out.append(s)
                }
            }
        }
        return out
    }

    func test_neverEarlier() {
        for s in grid() {
            for asOf in [at(-1), at(0.5), at(4), at(10)] {
                let out = LiveTimes.noCatchUp(s, asOf: asOf)
                for (a, b) in zip(s, out) {
                    if let x = a.arrival { XCTAssertGreaterThanOrEqual(b.arrival!, x) }
                    if let x = a.departure { XCTAssertGreaterThanOrEqual(b.departure!, x) }
                }
            }
        }
    }

    func test_inOrder() {
        for s in grid() {
            for asOf in [at(-1), at(0.5), at(4), at(10)] {
                let out = LiveTimes.noCatchUp(s, asOf: asOf, horizon: 10 * 60)
                let r = LiveTimes.reached(s, asOf: asOf) ?? 0
                var last = Date.distantPast
                for (k, x) in out.enumerated() where k >= r {
                    if let a = x.arrival { XCTAssertGreaterThanOrEqual(a, k == r ? .distantPast : last); last = max(last, a) }
                    if let d = x.departure { XCTAssertGreaterThanOrEqual(d, last); last = d }
                }
            }
        }
    }

    /// 45 s late where it left, and catching up: under a minute, so as given (pins `lateFrom`).
    func test_lessThanAMinuteLateUnchanged() {
        XCTAssertEqual(LiveTimes.lateFrom, 60)
        let s = [StopTimes(arrival: t0 + 45, departure: t0 + 45, scheduledArrival: t0, scheduledDeparture: t0),
                 stop(2.5, 2), stop(4, 4), stop(6, 6)]
        XCTAssertEqual(LiveTimes.noCatchUp(s, asOf: t0 + 50), s)
        var on = s
        on[0].departure = t0 + 60; on[0].arrival = t0 + 60
        XCTAssertNotEqual(LiveTimes.noCatchUp(on, asOf: t0 + 65), on)          // a minute: carried
    }

    func test_onTimeAndEarlyUnchanged() {
        let delays: [Double] = [-2.0, 0, 0.5, 59.0 / 60]
        for delay in delays {
            var s: [StopTimes] = []
            for k in 0..<6 {
                let planned: Double = Double(k) * 2
                let live: Double = planned + delay
                s.append(StopTimes(arrival: at(live), departure: at(live), scheduledArrival: at(planned), scheduledDeparture: at(planned)))
            }
            XCTAssertEqual(LiveTimes.noCatchUp(s, asOf: at(0.5 + delay)), s)
        }
    }

    func test_reachedStopsUnchanged() {
        let s = [stop(5, 0), stop(8, 3), stop(10, 6), stop(10, 9), stop(12, 12), stop(15, 15)]
        let out = LiveTimes.noCatchUp(s, asOf: at(10) + 5)
        XCTAssertEqual(LiveTimes.reached(s, asOf: at(10) + 5), 3)
        XCTAssertEqual(Array(out[0...3]), Array(s[0...3]))
        XCTAssertEqual(out[4].arrival, at(13))           // left stop 3 one minute late: +1 carried
        XCTAssertEqual(out[5].arrival, at(16))
    }

    func test_timetableWaitAbsorbs() {
        // +3 at the first stop; a timetabled 2-minute wait at the third
        let s = [stop(3, 0), stop(5, 4), stop(9, 8, leaves: 10, schedLeaves: 10), stop(12, 13)]
        let out = LiveTimes.noCatchUp(s, asOf: at(3) + 10)
        XCTAssertEqual(out[1].arrival, at(7))
        XCTAssertEqual(out[2].arrival, at(11))
        XCTAssertEqual(out[2].departure, at(11))         // +1 after the wait
        XCTAssertEqual(out[3].arrival, at(14))
    }

    func test_horizon() {
        // left +4, then +1 by the data; timetable stops every 4 minutes up to 24 min on: 16 min on and later as given
        let s = (0..<7).map { k in stop(Double(k) * 4 + (k == 0 ? 4 : 1), Double(k) * 4) }
        let out = LiveTimes.noCatchUp(s, asOf: at(4) + 10)
        XCTAssertEqual(out[1].arrival, at(8))
        XCTAssertEqual(out[3].arrival, at(16))
        XCTAssertEqual(out[4].arrival, at(17))           // 16 min on: past 15, as given (and after the one before)
        XCTAssertEqual(out[5].arrival, at(21))
        XCTAssertEqual(out[6].arrival, at(25))
    }

    func test_predictedLaterWins() {
        let s = [stop(2, 0), stop(9, 3), stop(10, 6)]
        let out = LiveTimes.noCatchUp(s, asOf: at(2) + 1)
        XCTAssertEqual(out[1].arrival, at(9))
        XCTAssertEqual(out[2].arrival, at(10))
    }

    func test_notStartedCarriesFirstDeparture() {
        let s = [stop(5, 0), stop(5, 3), stop(6, 6)]
        let out = LiveTimes.noCatchUp(s, asOf: at(1))
        XCTAssertNil(LiveTimes.reached(s, asOf: at(1)))
        XCTAssertEqual(out[0], s[0])
        XCTAssertEqual(out[1].arrival, at(8))
        XCTAssertEqual(out[2].arrival, at(11))
    }

    func test_noTimetableTimes() {
        let s = (0..<4).map { k in StopTimes(arrival: at(Double(k) * 3 + 4), departure: at(Double(k) * 3 + 4)) }
        XCTAssertEqual(LiveTimes.noCatchUp(s, asOf: at(4) + 5), s)
        // nil stays nil
        var t = [stop(4, 0), stop(5, 3), stop(6, 6)]
        t[1].departure = nil
        let out = LiveTimes.noCatchUp(t, asOf: at(4) + 5)
        XCTAssertNil(out[1].departure)
        XCTAssertEqual(out[1].arrival, at(7))
    }

    func test_piecesJoinAtStops() {
        func piece(_ d: Double, _ a: Double, _ sd: Double, _ sa: Double) -> PieceTimes {
            PieceTimes(departure: at(d), arrival: at(a), scheduledDeparture: at(sd), scheduledArrival: at(sa))
        }
        // +3, +2, +1, +0 at the stops: decaying
        let p = [piece(3, 5, 0, 3), piece(5, 7, 3, 6), piece(7, 9, 6, 9)]
        let out = LiveTimes.noCatchUp(pieces: p, asOf: at(3) + 20)
        XCTAssertEqual(out[0].departure, at(3))
        XCTAssertEqual(out[0].arrival, at(6))
        XCTAssertEqual(out[1].departure, at(6))
        XCTAssertEqual(out[1].arrival, at(9))
        XCTAssertEqual(out[2].departure, at(9))
        XCTAssertEqual(out[2].arrival, at(12))
        // a gap between pieces (a stretch left out): its timetable time takes delay up, it never adds any
        let gap = [piece(3, 5, 0, 2), piece(10, 12, 6, 8)]       // 4 min between the pieces by the timetable: the +3 is taken up
        let g = LiveTimes.noCatchUp(pieces: gap, asOf: at(3) + 20)
        XCTAssertEqual(g[0].arrival, at(5))
        XCTAssertEqual(g[1].departure, at(10))
        XCTAssertEqual(g[1].arrival, at(12))
        XCTAssertEqual(LiveTimes.noCatchUp(pieces: [], asOf: t0), [])
    }

    func test_hasLeftGrace() {
        let s = StopTimes(arrival: at(10), departure: at(10), scheduledArrival: nil, scheduledDeparture: nil)
        XCTAssertFalse(LiveTimes.hasLeft(s, now: at(10) + 119))
        XCTAssertTrue(LiveTimes.hasLeft(s, now: at(10) + 120))
        // no live time: by the timetable; no time at all: nothing to wait for (not pinned at your stop for ever)
        let planned = StopTimes(arrival: nil, departure: nil, scheduledArrival: at(9), scheduledDeparture: at(10))
        XCTAssertFalse(LiveTimes.hasLeft(planned, now: at(10) + 60))
        XCTAssertTrue(LiveTimes.hasLeft(planned, now: at(12)))
        XCTAssertTrue(LiveTimes.hasLeft(StopTimes(), now: at(10)))
    }

    func test_carriesDelay() {
        for m in ["BUS", "COACH", "TRAM", "tram", "TROLLEYBUS"] { XCTAssertTrue(LiveTimes.carriesDelay(mode: m, isTrain: true), m) }
        for m in ["RAIL", "REGIONAL_RAIL", "HIGHSPEED_RAIL", "SUBURBAN", "FERRY"] { XCTAssertFalse(LiveTimes.carriesDelay(mode: m, isTrain: false), m) }
        XCTAssertTrue(LiveTimes.carriesDelay(mode: "", isTrain: false))
        XCTAssertFalse(LiveTimes.carriesDelay(mode: "", isTrain: true))
    }

    /// A stop as /v5/trip gives it: `scheduled` stands in for the arrival only when it has neither timetable time.
    func test_stopTimesFromTrip() {
        let a = StopTimes(arrival: at(5), departure: at(6), scheduled: at(1), scheduledArrival: nil, scheduledDeparture: nil)
        XCTAssertEqual(a.scheduledArrival, at(1)); XCTAssertNil(a.scheduledDeparture)
        let b = StopTimes(arrival: at(5), departure: at(6), scheduled: at(1), scheduledArrival: nil, scheduledDeparture: at(2))
        XCTAssertNil(b.scheduledArrival); XCTAssertEqual(b.scheduledDeparture, at(2))
        let c = StopTimes(arrival: at(5), departure: at(6), scheduled: at(1), scheduledArrival: at(3), scheduledDeparture: at(4))
        XCTAssertEqual(c.scheduledArrival, at(3)); XCTAssertEqual(c.scheduledDeparture, at(4))
    }

    /// The live map's pieces of several trips at once: each late bus by itself, in the order given; a piece listed
    /// twice counted once (both copies corrected alike); trains, timetable-only trips and pieces without timetable
    /// times as they are.
    func test_tripsGroupedAndOnce() {
        func p(_ trip: String, _ k: Int, dep: Double, arr: Double, carries: Bool = true, live: Bool = true, sched: Bool = true) -> TripPiece {
            TripPiece(trip: trip, carries: carries, live: live,
                      times: PieceTimes(departure: at(dep), arrival: at(arr), scheduledDeparture: sched ? at(Double(k) * 2) : nil,
                                        scheduledArrival: sched ? at(Double(k + 1) * 2) : nil),
                      stops: "\(trip)\(k)>\(k + 1)")
        }
        // bus A: left +3, data +2 then +1; given out of order and its second piece twice
        let given = [p("A", 1, dep: 4, arr: 5), p("T", 0, dep: 3, arr: 4, carries: false), p("A", 0, dep: 3, arr: 4),
                     p("A", 1, dep: 4, arr: 5), p("O", 0, dep: 3, arr: 4, live: false), p("N", 0, dep: 3, arr: 4, sched: false)]
        let out = LiveTimes.noCatchUp(trips: given, asOf: at(3) + 10)
        XCTAssertEqual(out.count, given.count)
        XCTAssertEqual(out[2].arrival, at(5)); XCTAssertEqual(out[2].departure, at(3))
        XCTAssertEqual(out[0].departure, at(5)); XCTAssertEqual(out[0].arrival, at(7))
        XCTAssertEqual(out[3], out[0])
        XCTAssertEqual(out[1], given[1].times)
        XCTAssertEqual(out[4], given[4].times)
        XCTAssertEqual(out[5], given[5].times)
        XCTAssertEqual(LiveTimes.noCatchUp(trips: [], asOf: t0), [])
    }

    func test_shownStaysAtYourStop() {
        XCTAssertEqual(LiveTimes.shown(820, mine: 800, left: false), 800)
        XCTAssertEqual(LiveTimes.shown(820, mine: 800, left: true), 820)
        XCTAssertEqual(LiveTimes.shown(500, mine: 800, left: false), 500)
    }

    /// The bias measured across the country (late buses, MOTIS's times): a stop 0–2 min ahead is predicted ~1 min early.
    /// With the delay carried, a typical case of it lands within ±20 s of the truth.
    func test_noCatchUpBias() {
        // the bus left stop 0 three minutes late; the data has it +2 at the next stop and +1 at the one after (caught
        // up), the truth is +3 at both (the minute truncation and OpenOV's catch-up)
        let s = [stop(3, 0), stop(5, 3), stop(7, 6)]
        let truth = [at(6), at(9)]
        let out = LiveTimes.noCatchUp(s, asOf: at(3) + 10)
        XCTAssertEqual(truth[0].timeIntervalSince(s[1].arrival!), 60)                        // as given: a minute early
        XCTAssertEqual(truth[1].timeIntervalSince(s[2].arrival!), 120)
        XCTAssertEqual(abs(truth[0].timeIntervalSince(out[1].arrival!)), 0, accuracy: 20)
        XCTAssertEqual(abs(truth[1].timeIntervalSince(out[2].arrival!)), 0, accuracy: 20)
    }
}
