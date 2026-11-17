import XCTest

/// The battery and data log: cheap counters per day and per ride, the screen's lines, nothing about places.
final class BatteryLogTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }()
    private var tz: TimeZone { cal.timeZone }

    /// 2026-11-17 18:00 in Amsterdam.
    private var t0: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 18))! }

    private final class Box: @unchecked Sendable { var data: Data? }

    private func log(_ box: Box = Box()) -> BatteryLog {
        BatteryLog(load: { box.data }, store: { box.data = $0 }, every: .infinity, calendar: cal)
    }

    func test_gpsMinutesPerModeAndReason() {
        let l = log()
        l.gps("trip", mode: .best, reason: .fastest, at: t0)
        l.gps("trip", mode: .hundredMetres, reason: .fastest, at: t0 + 600)
        l.gps("trip", mode: .best, reason: .ride, at: t0 + 900)
        l.gps("trip", mode: nil, reason: nil, at: t0 + 2700)
        l.gps("home", mode: .tenMetres, reason: .home, at: t0 + 3000)
        let d = l.snapshot(at: t0 + 3060).days.last!
        XCTAssertEqual(d.day, "2026-11-17")
        XCTAssertEqual(d.gps["best|fastest"], 600)
        XCTAssertEqual(d.gps["hundredMetres|fastest"], 300)
        XCTAssertEqual(d.gps["best|ride"], 1800)
        XCTAssertEqual(d.gps["tenMetres|home"], 60)                      // still on: counted up to now
        XCTAssertEqual(d.gpsSeconds(.best), 2400)
        XCTAssertEqual(d.gpsSeconds(reason: .fastest), 900)
        XCTAssertEqual(d.gpsTotal, 2760)
    }

    func test_intervalSplitsAtMidnight() {
        let l = log()
        let late = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 23, minute: 50))!
        l.gps("trip", mode: .best, reason: .ride, at: late)
        l.scene(foreground: false, at: late)
        let s = l.snapshot(at: late + 1200)
        XCTAssertEqual(s.days.map(\.day), ["2026-11-17", "2026-11-18"])
        XCTAssertEqual(s.days[0].gps["best|ride"]!, 600, accuracy: 0.001)
        XCTAssertEqual(s.days[1].gps["best|ride"]!, 600, accuracy: 0.001)
        XCTAssertEqual(s.days[0].background, 600, accuracy: 0.001)
        XCTAssertEqual(s.days[1].background, 600, accuracy: 0.001)
    }

    func test_requestsBytesAndRadioWakes() {
        let l = log()
        l.request(.plan, body: 120_000, at: t0)
        l.request(.plan, body: 100_000, at: t0 + 2)         // the same wake
        l.request(.ovapi, body: 0, at: t0 + 11)             // still the same (within 12 s of the last)
        l.request(.trip, body: 11_000, at: t0 + 40)         // a new wake
        l.wire(.plan, bytes: 30_000, mobile: true, at: t0 + 1)
        l.wire(.ovapi, bytes: 190_000, mobile: false, at: t0 + 11)
        let d = l.snapshot(at: t0 + 60).days.last!
        XCTAssertEqual(d.net["plan"]?.requests, 2)
        XCTAssertEqual(d.net["plan"]?.body, 220_000)
        XCTAssertEqual(d.net["plan"]?.shown, 30_000)        // measured: the real bytes
        XCTAssertEqual(d.net["trip"]?.shown, 11_000)        // not measured: the body
        XCTAssertEqual(d.mobile, 30_000)
        XCTAssertEqual(d.bursts, 2)
        XCTAssertEqual(d.burstSeconds, 10 + 2 + 9 + 10, accuracy: 0.001)
        XCTAssertEqual(d.requests, 4)
        XCTAssertTrue(d.measured)
        XCTAssertEqual(BatteryReport.kinds(d).map(\.kind), [.ovapi, .plan, .trip])
    }

    func test_cpuBatteryAndCounters() {
        let l = log()
        l.cpu(total: 100, at: t0)                           // the first reading: from here on
        l.cpu(total: 112.5, at: t0 + 60)
        l.cpu(total: 3, at: t0 + 120)                       // a new process: starts over
        l.cpu(total: 5, at: t0 + 180)
        l.battery(level: 0.80, unplugged: true, at: t0)
        l.battery(level: 0.78, unplugged: true, at: t0 + 1800)
        l.battery(level: 0.78, unplugged: false, at: t0 + 2000)       // charging: not counted
        l.battery(level: 0.90, unplugged: false, at: t0 + 3000)
        l.battery(level: 0.89, unplugged: true, at: t0 + 3600)
        l.battery(level: 0.88, unplugged: true, at: t0 + 5400)
        l.battery(level: -1, unplugged: true, at: t0 + 5500)          // not known: ignored
        l.activityUpdate(at: t0); l.activityUpdate(at: t0 + 1)
        l.check(at: t0)
        let d = l.snapshot(at: t0 + 6000).days.last!
        XCTAssertEqual(d.cpu, 14.5, accuracy: 0.001)
        XCTAssertEqual(d.drop, 3, accuracy: 0.001)
        XCTAssertEqual(d.unplugged, 3600, accuracy: 0.001)
        XCTAssertEqual(BatteryReport.perHour(d), "3.0 %/h")
        XCTAssertEqual(d.activityUpdates, 2)
        XCTAssertEqual(d.checks, 1)
    }

    func test_rideCost() {
        let l = log()
        l.gps("trip", mode: .best, reason: .fastest, at: t0 - 600)              // before the ride: not the ride's
        l.request(.plan, body: 50_000, at: t0 - 300)
        l.rideStart(at: t0, battery: 0.70)
        l.gps("trip", mode: .best, reason: .ride, at: t0)
        l.gps("trip", mode: .tenMetres, reason: .ride, at: t0 + 360)
        l.request(.trip, body: 11_000, at: t0 + 400)
        l.wire(.trip, bytes: 4_000, mobile: true, at: t0 + 400)
        l.check(at: t0 + 401)
        l.activityUpdate(at: t0 + 402)
        l.gps("trip", mode: .best, reason: .ride, at: t0 + 1440)
        let r = l.rideEnd(at: t0 + 1440, battery: 0.66, legs: 2)!
        XCTAssertEqual(r.gps["best"]!, 360, accuracy: 0.001)
        XCTAssertEqual(r.gps["tenMetres"]!, 1080, accuracy: 0.001)
        XCTAssertEqual(r.body, 11_000)
        XCTAssertEqual(r.bytes, 4_000)
        XCTAssertEqual(r.mobile, 4_000)
        XCTAssertEqual(r.checks, 1)
        XCTAssertEqual(r.activityUpdates, 1)
        XCTAssertEqual(r.drop!, 4, accuracy: 0.001)
        XCTAssertEqual(r.legs, 2)
        XCTAssertEqual(BatteryReport.rideLine(r, timeZone: tz), "Ride 18:00–18:24 · 24 min (2 legs) · −4% · GPS best 6 min / 10 m 18 min · 0.0 MB")
        XCTAssertTrue(BatteryReport.fieldLine(r, timeZone: tz).hasPrefix("cost · 18:00–18:24 · 24 min (2 legs) · −4%"))
        XCTAssertTrue(BatteryReport.fieldLine(r, timeZone: tz).contains("1 checks · 1 LA updates"))
        XCTAssertNil(l.rideEnd(at: t0 + 2000))                                  // no ride on: nothing
        let s = l.snapshot(at: t0 + 2000)
        XCTAssertEqual(s.rides.count, 1)
        XCTAssertNil(s.ride)
    }

    func test_rideDropWords() {
        var r = RideCost(start: t0, batteryStart: 0.5)
        r.end = t0 + 600
        XCTAssertEqual(BatteryReport.drop(r), "battery ?")
        r.batteryEnd = 0.5
        XCTAssertEqual(BatteryReport.drop(r), "−<1%")
        r.batteryEnd = 0.44
        XCTAssertEqual(BatteryReport.drop(r), "−6%")
        r.unplugged = false
        XCTAssertEqual(BatteryReport.drop(r), "charging")
        XCTAssertEqual(BatteryReport.rideLine(r, timeZone: tz), "Ride 18:00–18:10 · 10 min · charging · GPS off · 0.0 MB (body size)")
    }

    func test_chargingDuringARide() {
        let l = log()
        l.rideStart(at: t0, battery: 0.5)
        l.battery(level: 0.55, unplugged: false, at: t0 + 300)
        let r = l.rideEnd(at: t0 + 600, battery: 0.6)!
        XCTAssertNil(r.drop)
        XCTAssertEqual(BatteryReport.drop(r), "charging")
    }

    func test_ridesAndDaysAreCapped() {
        let l = log()
        for i in 0..<40 {
            l.request(.plan, body: 1, at: t0 + Double(i) * 86_400 / 2)
            l.rideStart(at: t0 + Double(i) * 86_400 / 2)
            l.rideEnd(at: t0 + Double(i) * 86_400 / 2 + 60)
        }
        let s = l.snapshot(at: t0 + 30 * 86_400)
        XCTAssertEqual(s.rides.count, BatteryLog.keepRides)
        XCTAssertLessThanOrEqual(s.days.count, BatteryLog.keepDays)
        XCTAssertEqual(s.days.map(\.day), s.days.map(\.day).sorted())
    }

    func test_savedAndLoaded() {
        let box = Box()
        let a = log(box)
        a.request(.plan, body: 1000, at: t0)
        a.rideStart(at: t0)
        a.rideEnd(at: t0 + 60)
        a.rideStart(at: t0 + 100)                          // one on when the app goes: not kept as on
        a.flush()
        XCTAssertNotNil(box.data)
        let b = log(box)
        let s = b.snapshot(at: t0 + 200)
        XCTAssertEqual(s.days.first?.net["plan"]?.requests, 1)
        XCTAssertEqual(s.rides.count, 1)
        XCTAssertNil(s.ride)
        b.clear()
        XCTAssertTrue(b.snapshot(at: t0 + 300).rides.isEmpty)
    }

    func test_bars() {
        var d = BatteryDay(day: "2026-11-17")
        d.gps["best|ride"] = 60 * 60
        d.gps["hundredMetres|fastest"] = 20 * 60
        d.bursts = 100
        d.cpu = 6 * 60
        d.background = 120 * 60
        d.foreground = 47 * 60
        d.net["ovapi"] = NetCount(requests: 10, body: 2_000_000, wire: 1_900_000, mobile: 1_900_000, measured: 10)
        let bars = BatteryReport.bars(d)
        XCTAssertEqual(bars.map(\.title), ["GPS", "Network", "CPU", "Background"])
        XCTAssertEqual(bars[0].fraction, 1)                                   // 60 + 4 weighted minutes: the biggest
        XCTAssertEqual(bars[1].fraction, 15.0 / 64, accuracy: 0.001)
        XCTAssertEqual(bars[2].fraction, 6.0 / 64, accuracy: 0.001)
        XCTAssertEqual(bars[3].fraction, 6.0 / 64, accuracy: 0.001)
        XCTAssertEqual(bars[0].value, "1 h 20")
        XCTAssertTrue(bars[0].detail.contains("best 1 h 00 · 100 m 20 min"))
        XCTAssertTrue(bars[0].detail.contains("why: rides 1 h 00 · Fastest trip 20 min"))
        XCTAssertEqual(bars[1].value, "1.8 MB")
        XCTAssertEqual(bars[3].detail, "on screen 47 min")
        XCTAssertTrue(BatteryReport.bars(BatteryDay(day: "x")).allSatisfy { $0.fraction == 0 })
    }

    func test_mobileTodayAndWeek() {
        let l = log()
        let key = { (d: Date) in l.dayKey(d) }
        var days: [BatteryDay] = []
        for i in 0..<9 {
            var d = BatteryDay(day: key(t0 - Double(i) * 86_400))
            d.net["plan"] = NetCount(requests: 1, body: 0, wire: 1_000_000, mobile: 1_000_000, measured: 1)
            days.append(d)
        }
        let m = BatteryReport.mobile(days.reversed(), today: t0, calendar: cal, key: key)
        XCTAssertEqual(m.today, 1_000_000)
        XCTAssertEqual(m.week, 7_000_000)
        XCTAssertTrue(m.measured)
        XCTAssertFalse(BatteryReport.mobile([], today: t0, calendar: cal, key: key).measured)
    }

    func test_kindsByAddress() {
        XCTAssertEqual(CostKind.of(path: "/v5/plan"), .plan)
        XCTAssertEqual(CostKind.of(path: "/api/v5/plan"), .plan)
        XCTAssertEqual(CostKind.of(path: "/v5/trip"), .trip)
        XCTAssertEqual(CostKind.of(path: "/api/v5/trip"), .trip)
        XCTAssertEqual(CostKind.of(path: "/v1/map/trips"), .mapTrips)
        XCTAssertEqual(CostKind.of(path: "/v1/map/stops"), .mapStops)
        XCTAssertEqual(CostKind.of(path: "/v6/stoptimes"), .stoptimes)
        XCTAssertEqual(CostKind.of(path: "/v1/geocode"), .geocode)
        XCTAssertEqual(CostKind.of(path: "/nl/vehiclePositions.pb", host: "gtfs.ovapi.nl"), .ovapi)
        XCTAssertEqual(CostKind.of(path: "/ns/vehicles"), .nsVehicles)
        XCTAssertEqual(CostKind.of(path: "/ns/trips"), .relay)
        XCTAssertEqual(CostKind.of(path: "/v1/me/player/currently-playing", host: "api.spotify.com"), .spotify)
        XCTAssertEqual(CostKind.of(path: "/v1/forecast", host: "api.open-meteo.com"), .weather)
        XCTAssertEqual(CostKind.of(path: "/something"), .other)
    }

    func test_durationsAndSizes() {
        XCTAssertEqual(BatteryReport.duration(0), "0 min")
        XCTAssertEqual(BatteryReport.duration(40), "40 s")
        XCTAssertEqual(BatteryReport.duration(6 * 60), "6 min")
        XCTAssertEqual(BatteryReport.duration(126 * 60), "2 h 06")
        XCTAssertEqual(BatteryReport.mb(2_202_009), "2.1 MB")
        XCTAssertEqual(BatteryReport.mb(41 * 1_048_576), "41 MB")
    }

    /// The text holds kinds, counts, sizes and times: never a place.
    func test_textHasNoPlaces() {
        let l = log()
        l.request(.plan, body: 1000, at: t0)
        l.rideStart(at: t0, battery: 0.5)
        l.rideEnd(at: t0 + 600, battery: 0.49)
        let text = BatteryReport.text(l.snapshot(at: t0 + 700), today: t0, calendar: cal, key: { l.dayKey($0) }, timeZone: tz)
        XCTAssertTrue(text.contains("Ride 18:00–18:10 · 10 min · −1%"))
        for word in ["Veghel", "Breda", "lat", "lon", "51."] { XCTAssertFalse(text.contains(word)) }
    }
}
