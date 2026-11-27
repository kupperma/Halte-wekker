import XCTest

/// 0.42.12's battery and data rules (`RideSaver.swift`) against docs/battery-vectors.json (Android checks the same
/// vectors), and synthetic rides of the usual shapes (a 20 km bus, a 50 km train, a half-hour wait at a change):
/// the rough GPS covers most of the far part, and the best is always back before the wake point.
final class RideSaverTests: XCTestCase {
    private var v: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = Bundle(for: Self.self).url(forResource: "battery-vectors", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/battery-vectors.json")
        let d = try Data(contentsOf: url)
        v = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    private func num(_ x: Any?) -> Double? { (x as? NSNumber)?.doubleValue }
    private func flag(_ x: Any?) -> Bool? { (x as? NSNumber)?.boolValue }
    private func list(_ k: String) -> [[String: Any]] { (v[k] as? [[String: Any]]) ?? [] }

    // MARK: the vectors

    func test_accuracyVectors() {
        let cases = list("accuracy")
        XCTAssertGreaterThan(cases.count, 20)
        for c in cases {
            let i = c["input"] as? [String: Any] ?? [:]
            var input = RideAccuracy.Input(isTrain: flag(i["isTrain"]) ?? false, wakeMetres: num(i["wakeMetres"]) ?? 0, legAge: num(i["legAge"]) ?? 0)
            input.enabled = flag(i["enabled"]) ?? true
            input.asleep = flag(i["asleep"]) ?? true
            input.confirmed = flag(i["confirmed"]) ?? false
            input.confirmedAge = num(i["confirmedAge"])
            input.metresToStop = num(i["metresToStop"])
            input.accuracy = num(i["accuracy"])
            input.fixAge = num(i["fixAge"])
            input.speed = num(i["speed"])
            input.secondsToStop = num(i["secondsToStop"])
            input.backstop = flag(i["backstop"]) ?? false
            input.needBest = flag(i["needBest"]) ?? false
            input.wasReduced = flag(i["wasReduced"]) ?? false
            XCTAssertEqual(RideAccuracy.tier(input).rawValue, c["tier"] as? String, c["name"] as? String ?? "")
        }
    }

    func test_changeWaitVectors() {
        let cases = list("changeWait")
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let low = ChangeWait.low(standingFor: num(c["standingFor"]), nextIn: num(c["nextIn"]),
                                     moving: flag(c["moving"]) ?? false, inVehicle: flag(c["inVehicle"]) ?? false)
            XCTAssertEqual(low, flag(c["low"]), "\(c)")
        }
    }

    private func change(_ s: String?) -> ActivityCadence.Change {
        switch s {
        case "say": return .say
        case "meaningful": return .meaningful
        case "look": return .look
        default: return .none
        }
    }

    func test_cadenceVectors() {
        for c in list("cadence") {
            let ch = change(c["change"] as? String), near = flag(c["near"]) ?? false, since = num(c["sinceLast"]) ?? 0
            XCTAssertEqual(ActivityCadence.send(ch, near: near, sinceLast: since), flag(c["send"]), "\(c)")
            XCTAssertEqual(ActivityCadence.later(ch, near: near, sinceLast: since), num(c["later"]), "\(c)")
        }
        for c in list("cadenceNear") {
            XCTAssertEqual(ActivityCadence.near(secondsToStop: num(c["secondsToStop"]), awake: flag(c["awake"]) ?? false), flag(c["near"]), "\(c)")
        }
    }

    func test_rideNearVectors() {
        for c in list("rideNear") {
            let n = RideNet.near(secondsToStop: num(c["secondsToStop"]), metresToStop: num(c["metresToStop"]),
                                 wakeMetres: num(c["wakeMetres"]) ?? 0, awake: flag(c["awake"]) ?? false)
            XCTAssertEqual(n, flag(c["near"]), "\(c)")
        }
        XCTAssertEqual(RideNet.tripEvery(near: false), 120)
        XCTAssertEqual(RideNet.tripEvery(near: true), 45)
        XCTAssertEqual(RideNet.ways(10, inFront: false), 3)
        XCTAssertEqual(RideNet.ways(2, inFront: false), 2)
        XCTAssertEqual(RideNet.ways(10, inFront: true), 10)
        XCTAssertFalse(RideNet.homeLooks(riding: true))
        XCTAssertTrue(RideNet.homeLooks(riding: false))
    }

    private func point(_ x: Any?) -> GeoPoint? {
        guard let a = x as? [NSNumber], a.count == 2 else { return nil }
        return GeoPoint(lat: a[0].doubleValue, lon: a[1].doubleValue)
    }

    func test_prefilterVectors() throws {
        let p = try XCTUnwrap(v["prefilter"] as? [String: Any])
        let you = ((p["you"] as? [Any]) ?? []).compactMap(point)
        let planned = p["planned"] as? String
        let cands = (p["candidates"] as? [[String: Any]]) ?? []
        var built: [CandidatePrefilter.Candidate] = []
        for c in cands {
            let paths = ((c["paths"] as? [Any]) ?? []).map { (($0 as? [Any]) ?? []).compactMap(point) }
            let k = CandidatePrefilter.Candidate(tripId: c["tripId"] as? String ?? "", line: c["line"] as? String ?? "",
                                                 isTrain: flag(c["isTrain"]) ?? false, paths: paths,
                                                 gps: point(c["gps"]), gpsAge: num(c["gpsAge"]))
            built.append(k)
            XCTAssertEqual(CandidatePrefilter.drop(k, you: you, planned: planned)?.rawValue, c["drop"] as? String, k.tripId)
        }
        let r = CandidatePrefilter.filter(built, you: you, planned: planned) { $0 }
        let counts = try XCTUnwrap(p["counts"] as? [String: Any])
        XCTAssertEqual(r.dropped.coach, Int(num(counts["coach"]) ?? -1))
        XCTAssertEqual(r.dropped.route, Int(num(counts["route"]) ?? -1))
        XCTAssertEqual(r.dropped.far, Int(num(counts["far"]) ?? -1))
        XCTAssertEqual(r.kept.count + r.dropped.total, built.count)
        XCTAssertTrue(r.kept.contains { $0.tripId == planned })                       // the planned one, even a coach
        XCTAssertEqual(CandidatePrefilter.line(place: "board", dropped: r.dropped, of: built.count),
                       "prefilter · board · 6 of 12 left out (2 coaches, 2 off their route, 2 far by their GPS)")
    }

    // MARK: synthetic rides (made-up numbers of the usual shapes)

    /// A small fixed random sequence, so every run is the same.
    private struct Noise {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53)
        }
    }

    private struct Leg {
        var metres: Double          // where you started, from the stop
        var speed: Double           // m/s, steady
        var isTrain: Bool
        var wake: Double
        var stops: [Double] = []    // metres from the stop where it stands 60 s
    }

    private struct Outcome {
        var reducedSeconds = 0.0
        var totalSeconds = 0.0
        var bestAgainAt: Double?    // true metres from the stop when the best came back (the last time)
        var nearestWhileReduced = Double.infinity
    }

    /// Runs one leg second by second: a fix every 25 m (best) or 300 m (rough, with an error up to its accuracy and a
    /// time lag), the decision on each fix and every 30 s; the vehicle confirmed from 90 s on (a look passed every 30 s,
    /// as the same-bus look does while the best is on; while rough it holds); arrival known by time.
    private func ride(_ leg: Leg, seed: UInt64, roughAccuracy: Double = 400) -> Outcome {
        var n = Noise(s: seed)
        var out = Outcome()
        var d = leg.metres, t = 0.0
        var tier = RideAccuracy.Tier.best
        var lastFixAt = 0.0, lastFixD = d, lastFixAcc = 10.0, lastFixPos = d
        var lastPass: Double?
        var lastEval = 0.0
        var standing = 0.0
        var stops = leg.stops
        while d > 0 {
            // move (or stand at a stop)
            if standing > 0 { standing -= 1 } else {
                d = max(0, d - leg.speed)
                if let s = stops.first, d <= s { stops.removeFirst(); standing = 60 }
            }
            t += 1
            let filter = tier == .reduced ? RideAccuracy.reducedFilter : 25
            var evaluate = t - lastEval >= RideAccuracy.lookEvery
            if abs(lastFixPos - d) >= filter {
                let acc = tier == .reduced ? 30 + n.next() * roughAccuracy : 5 + n.next() * 10
                let err = (n.next() * 2 - 1) * acc
                lastFixAt = t; lastFixPos = d; lastFixD = max(0, d + err); lastFixAcc = acc
                evaluate = true
            }
            if tier == .best, t >= 90, Int(t) % 30 == 0 { lastPass = t }
            if evaluate {
                lastEval = t
                var i = RideAccuracy.Input(isTrain: leg.isTrain, wakeMetres: leg.wake, legAge: t)
                i.confirmed = lastPass != nil
                i.confirmedAge = lastPass.map { t - $0 }
                i.metresToStop = lastFixD
                i.accuracy = lastFixAcc
                i.fixAge = t - lastFixAt
                i.speed = tier == .best ? leg.speed : nil
                let left = stops.count * 60 + Int(standing)
                i.secondsToStop = d / leg.speed + Double(left)
                i.wasReduced = tier == .reduced
                // once it rings the leg is no longer asleep: that's at the wake distance
                i.asleep = d > leg.wake
                let next = RideAccuracy.tier(i)
                if tier == .reduced, next == .best { out.bestAgainAt = d }
                tier = next
            }
            if tier == .reduced {
                out.reducedSeconds += 1
                out.nearestWhileReduced = min(out.nearestWhileReduced, d)
            }
            out.totalSeconds += 1
        }
        return out
    }

    /// A train leg (about 50 km at up to 160 km/h, a few stations): rough for most of the leg, the best again
    /// well before the wake point, whatever the fixes' error.
    func test_trainLegReplay() {
        for (k, speed) in [30.0, 39.0, 45.0].enumerated() {
            for seed in 1...20 {
                let leg = Leg(metres: 51_000, speed: speed, isTrain: true, wake: 5000, stops: [38_000, 24_000, 12_000])
                let o = ride(leg, seed: UInt64(seed * 31 + k), roughAccuracy: 900)
                XCTAssertGreaterThan(o.reducedSeconds / o.totalSeconds, 0.55, "speed \(speed) seed \(seed)")
                XCTAssertGreaterThanOrEqual(o.nearestWhileReduced, leg.wake + RideAccuracy.exitMargin, "speed \(speed) seed \(seed)")
                if let at = o.bestAgainAt { XCTAssertGreaterThanOrEqual(at, leg.wake + RideAccuracy.exitMargin) }
            }
        }
    }

    /// A bus leg (about 20 km): rough between the first 2 minutes and the last few km.
    func test_busLegReplay() {
        for seed in 1...20 {
            let leg = Leg(metres: 19_500, speed: 13, isTrain: false, wake: 2000, stops: [16_000, 12_000, 8000, 5000])
            let o = ride(leg, seed: UInt64(seed))
            XCTAssertGreaterThan(o.reducedSeconds / o.totalSeconds, 0.4, "seed \(seed)")
            XCTAssertGreaterThanOrEqual(o.nearestWhileReduced, max(RideAccuracy.busBest, leg.wake + RideAccuracy.exitMargin), "seed \(seed)")
        }
    }

    /// Faster than its top speed for the rough tier (a train at 300 km/h): its arrival time brings the best back.
    func test_fastTrainByTime() {
        let leg = Leg(metres: 60_000, speed: 83, isTrain: true, wake: 5000)
        let o = ride(leg, seed: 7, roughAccuracy: 300)
        XCTAssertGreaterThanOrEqual(o.nearestWhileReduced, leg.wake)
        if let at = o.bestAgainAt { XCTAssertGreaterThan(at / leg.speed, RideAccuracy.exitSeconds - RideAccuracy.lookEvery) }
    }

    /// The GPS plan: the rough tiers, and the order they go in.
    func test_gpsPlan() {
        let ride = GPSPolicy.plan(phase: .riding, demo: false, going: false, lineWatch: false, regionLook: false, rideFar: true, rideReduced: true)
        XCTAssertEqual(ride, .coarse(300))
        XCTAssertEqual(GPSPolicy.plan(phase: .riding, demo: false, going: false, lineWatch: false, regionLook: false, rideFar: true), .ten(75))
        XCTAssertEqual(GPSPolicy.plan(phase: .transfer, demo: false, going: false, lineWatch: false, regionLook: false, changeLow: true), .coarse(100))
        XCTAssertEqual(GPSPolicy.plan(phase: .transfer, demo: false, going: false, lineWatch: false, regionLook: false), .best(25))
        XCTAssertEqual(GPSPolicy.plan(phase: .riding, demo: true, going: false, lineWatch: false, regionLook: false, rideReduced: true), .off)
    }

    /// The Battery & data screen's line per ride: the best against the rough tiers.
    func test_gpsSplit() {
        var r = RideCost(start: Date(timeIntervalSince1970: 0))
        XCTAssertNil(BatteryReport.gpsSplit(r))
        XCTAssertEqual(BatteryReport.reducedShare(r), "")
        r.gps = ["best": 25 * 60, "hundredMetres": 60 * 60, "tenMetres": 15 * 60]
        XCTAssertEqual(BatteryReport.gpsSplit(r), "GPS best 25 min · reduced 1 h 15 (75%)")
        XCTAssertEqual(BatteryReport.reducedShare(r), " · GPS reduced 75%")
        XCTAssertTrue(BatteryReport.fieldLine(r, timeZone: TimeZone(identifier: "UTC")!).hasSuffix(" · GPS reduced 75%"))
    }

    /// The list at a change behind the screen: 5 ways from just before you got there, or 10 minutes back on a long wait.
    func test_changeList() {
        let now = Date(timeIntervalSince1970: 100_000)
        let front = RideNet.changeList(inFront: true, arrived: now.addingTimeInterval(-60), now: now)
        XCTAssertEqual(front.from, now.addingTimeInterval(-1800)); XCTAssertEqual(front.count, 10)
        let justIn = RideNet.changeList(inFront: false, arrived: now.addingTimeInterval(-120), now: now)
        XCTAssertEqual(justIn.from, now.addingTimeInterval(-420)); XCTAssertEqual(justIn.count, 5)
        let long = RideNet.changeList(inFront: false, arrived: now.addingTimeInterval(-1800), now: now)
        XCTAssertEqual(long.from, now.addingTimeInterval(-600))
        XCTAssertEqual(RideNet.changeList(inFront: false, arrived: nil, now: now).from, now.addingTimeInterval(-600))
    }

    /// The vehicle in doubt (a look fails): the best at once, wherever it is.
    func test_doubtBringsTheBest() {
        var i = RideAccuracy.Input(isTrain: true, wakeMetres: 5000, legAge: 900)
        i.confirmed = true; i.confirmedAge = 30; i.metresToStop = 40_000; i.accuracy = 300; i.fixAge = 5; i.secondsToStop = 1500
        i.wasReduced = true
        XCTAssertEqual(RideAccuracy.tier(i), .reduced)
        i.confirmed = false
        XCTAssertEqual(RideAccuracy.tier(i), .best)
        i.confirmed = true; i.needBest = true
        XCTAssertEqual(RideAccuracy.tier(i), .best)
    }

    /// A long wait at a change (a bus in, a train out 33 minutes later): rough from 3 minutes in until 3 minutes
    /// before it leaves.
    func test_changeWaitReplay() {
        let wait = 33 * 60.0
        var low = 0.0
        for t in stride(from: 0.0, to: wait, by: 1) {
            if ChangeWait.low(standingFor: t, nextIn: wait - t, moving: false, inVehicle: false) { low += 1 }
        }
        XCTAssertEqual(low, wait - ChangeWait.standFor - ChangeWait.lead - 1, accuracy: 1)
        XCTAssertGreaterThan(low / wait, 0.8)
        // walking over to the platform: the best
        XCTAssertFalse(ChangeWait.low(standingFor: 600, nextIn: 900, moving: true, inVehicle: false))
    }

    /// A 100-minute trip's lock screen (stops every 2.5 minutes, the arrival minute moving every 4, the distance on every
    /// fix): far fewer updates than one every 30 s that changed, and every one of the last 5 minutes within 20 s.
    func test_cadenceReplay() {
        var sent = 0, old = 0
        var last = -1000.0, lastOld = -1000.0
        var shownStop = 0, shownMinute = 0, shownStep = 0
        var nearGapMax = 0.0
        let legEnd = 100 * 60.0
        for s in stride(from: 0.0, to: legEnd, by: 5) {
            let stop = Int(s / 150), minute = Int(s / 240), step = ActivityCadence.distanceStep(40_000 * (1 - s / legEnd))
            let meaningful = stop != shownStop || minute != shownMinute
            let look = step != shownStep
            let near = ActivityCadence.near(secondsToStop: legEnd - s, awake: false)
            let c = ActivityCadence.change(say: false, meaningful: meaningful, look: look)
            if ActivityCadence.send(c, near: near, sinceLast: s - last) {
                if near, last > legEnd - 300 { nearGapMax = max(nearGapMax, s - last) }
                sent += 1; last = s; shownStop = stop; shownMinute = minute; shownStep = step
            }
            // 0.20.7's rule: anything changed (the distance always does), at most every 30 s
            if ActivityThrottle.send(changed: true, phaseChanged: false, sinceLast: s - lastOld) { old += 1; lastOld = s }
        }
        XCTAssertLessThan(sent, old / 2)
        XCTAssertLessThanOrEqual(sent, 80)
        XCTAssertLessThanOrEqual(nearGapMax, 25)
        XCTAssertEqual(ActivityCadence.minute(Date(timeIntervalSince1970: 119)), 1)
        XCTAssertEqual(ActivityCadence.minute(nil), 0)
        XCTAssertEqual(ActivityCadence.distanceStep(1950), 19)
        XCTAssertEqual(ActivityCadence.distanceStep(2400), 24)
        XCTAssertEqual(ActivityCadence.distanceStep(nil), -1)
    }

    /// A board look: the planned bus and another of its line near you, long-distance coaches far "off their path" or on
    /// your road, a bus whose route is far away. Only the ones that can be yours are judged.
    func test_prefilterBoardLook() {
        let you = [GeoPoint(lat: 50.0000, lon: 6.0000), GeoPoint(lat: 50.0005, lon: 6.0010)]
        let road = [GeoPoint(lat: 49.99, lon: 5.99), GeoPoint(lat: 50.01, lon: 6.01)]
        let far = [GeoPoint(lat: 50.20, lon: 5.70), GeoPoint(lat: 50.25, lon: 5.60)]
        let list = [
            CandidatePrefilter.Candidate(tripId: "10a", line: "10", isTrain: false, paths: [road]),
            CandidatePrefilter.Candidate(tripId: "10b", line: "10", isTrain: false, paths: [road]),
            CandidatePrefilter.Candidate(tripId: "fb1", line: "FlixBus N100", isTrain: false, paths: [far]),
            CandidatePrefilter.Candidate(tripId: "fb2", line: "FlixBus N300", isTrain: false, paths: [road]),
            CandidatePrefilter.Candidate(tripId: "20", line: "20", isTrain: false, paths: [far]),
        ]
        let r = CandidatePrefilter.filter(list, you: you, planned: "10a") { $0 }
        XCTAssertEqual(r.kept.map(\.tripId), ["10a", "10b"])
        XCTAssertEqual(r.dropped, CandidatePrefilter.Counts(coach: 2, route: 1, far: 0))
        // no fixes: nothing left out but the coaches
        XCTAssertEqual(CandidatePrefilter.filter(list, you: [], planned: nil) { $0 }.dropped.total, 2)
    }
}
