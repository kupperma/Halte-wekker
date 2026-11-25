import Foundation

/// One GPS fix. `speed` (m/s) and `course` (degrees) are negative when unknown, as in CoreLocation.
struct Fix: Equatable, Sendable {
    let t: Date
    let p: GeoPoint
    let accuracy: Double
    let speed: Double
    let course: Double
}

/// A vehicle's stop-to-stop piece: when it leaves, when it gets to the next stop, and its road between them.
struct TimedPiece: Equatable, Sendable {
    let departure: Date
    let arrival: Date
    let path: [GeoPoint]
}

/// A piece as the live map gives it: one trip on it.
struct MapPiece: Equatable, Sendable {
    let tripId: String
    let line: String
    let isTrain: Bool
    let realTime: Bool
    let piece: TimedPiece
}

/// A vehicle's own GPS (0.20.3): its newest fix in the open data, and the one before it (for its speed between them).
struct VehicleGPS: Equatable, Sendable {
    let fix: GPSFix
    var previous: GPSFix? = nil
}

/// A bus or train: its pieces in departure order, and whether its times are live. `gps`: its own fresh GPS fix, when
/// the open data has one: then the matcher judges it by where that puts it, not by its times.
struct VehicleTrack: Equatable, Sendable {
    let tripId: String
    let line: String
    let isTrain: Bool
    let realTime: Bool
    let pieces: [TimedPiece]
    var gps: VehicleGPS? = nil

    /// One track per trip, in the order the trips first come; a piece that comes twice counts once; live when any of
    /// its pieces is.
    static func group(_ pieces: [MapPiece]) -> [VehicleTrack] {
        var order: [String] = []
        var byTrip: [String: (first: MapPiece, live: Bool, pieces: [TimedPiece])] = [:]
        for m in pieces {
            if var g = byTrip[m.tripId] {
                if !g.pieces.contains(m.piece) { g.pieces.append(m.piece) }
                g.live = g.live || m.realTime
                byTrip[m.tripId] = g
            } else {
                order.append(m.tripId)
                byTrip[m.tripId] = (m, m.realTime, [m.piece])
            }
        }
        return order.compactMap { id in
            guard let g = byTrip[id] else { return nil }
            return VehicleTrack(tripId: id, line: g.first.line, isTrain: g.first.isTrain, realTime: g.live,
                                pieces: VehicleMatch.byDeparture(g.pieces))
        }
    }
}

/// What your fixes say about one vehicle. Metres along its joined path; + offset = you're ahead of its times.
struct Evidence: Equatable, Sendable {
    let fixes: Int
    let span: TimeInterval
    let crossTrack: Double      // m off its path: the median of the last 3 fixes
    let accuracy: Double        // m, the median of the fixes'
    let shaped: Bool            // its path has a road shape where your last fixes are: some piece has more than 2
                                // points, and none of the last 3 fixes is beside a straight connector between pieces
                                // that don't meet
    let progress: Double        // m you went along its path: from the first fixes to the last (the median of 3 at
                                // each end once there are 6, so a stop's GPS jitter doesn't read as going back)
    let offset: Double          // m, your along-position minus its timetable along-position at the last fix
    var drift: Double           // m/s, the change of the offset (between the same ends as `progress`)
    let yourSpeed: Double       // m/s along its path (`progress` over the time between those ends)
    var itsSpeed: Double        // m/s by its times
    let steady: Bool            // your speed in both halves within 30 % of each other, both at least 3 m/s
    // By its own GPS (0.20.3): `offset` and `drift` are from where its fix puts it (on its road, moved on at its
    // piece's speed for a minute at most), `itsSpeed` its speed between its last two fixes (else its piece's).
    var gps = false
    var gpsAge: TimeInterval? = nil     // s: your newest fix's time minus its fix's
    var gpsSpeed: Double? = nil         // m/s between its last two fixes (or the speed its fix gave), when known
    var speedKnown = true               // its speed says something about your fixes' time (false: a GPS speed from
                                        //    before them, or none): the speed tests skip it
    var headingOff: Double? = nil       // degrees between its heading and yours (by GPS only)
}

/// Why a vehicle isn't the one you're on.
enum Reject: Error, Equatable, Sendable {
    case tooFewFixes, offItsPath, wrongWay, implausibleSpeed, standing, drifting, tooFarFromTimes, noTimes

    /// Not a failure but "not sure yet": too few fixes to judge by, or no times for it now.
    var notSure: Bool { self == .tooFewFixes || self == .noTimes }
}

/// One vehicle, judged: the cost in seconds off its times, or why not.
struct Judgement: Equatable, Sendable {
    let id: String
    let line: String
    let isTrain: Bool
    let realTime: Bool
    let evidence: Evidence?
    let result: Result<Double, Reject>
}

struct Ranked: Equatable, Sendable {
    let id: String
    let cost: Double
}

/// Who has been beating the shown vehicle, in how many looks in a row, since when.
struct SwitchState: Equatable, Sendable {
    var leader: String? = nil
    var looks = 0
    var since: Date? = nil
}

enum Decision: Equatable, Sendable {
    case keep(String), switchTo(String), undecided([String]), none
}

/// A bus or train found by the road you're on: how late it is there by its own times (negative: early).
struct RoadHit: Equatable, Sendable {
    let tripId: String
    let line: String
    let isTrain: Bool
    let late: TimeInterval
}

extension VehicleMatch {
    /// Whether a walking plan from where you stand makes sense: not at train or bus speed (8 m/s or more), and not when
    /// the speed is unknown (negative) and you moved less than 30 s ago.
    static func planFromSpot(speed: Double, movedAgo: TimeInterval?) -> Bool {
        if speed >= 8 { return false }
        if speed < 0, let m = movedAgo, m < 30 { return false }
        return true
    }
}

/// Where a vehicle's own GPS puts it on its joined path: `along` at its fix's time `at`, moved on (or back) at its
/// piece's speed `speed` for `gpsAdvance` at most; `measured` its own speed, `heading` its own (or its road's there).
struct GPSAnchor: Equatable, Sendable {
    let along: Double
    let at: Date
    let speed: Double
    let measured: Double?
    let heading: Double?

    /// 0.34: at the speed it was seen going (`measured`, when sane: 0.5 m/s or more) for up to `gpsAdvanceSeen`.
    func position(at t: Date) -> Double {
        let dt = t.timeIntervalSince(at)
        if let m = measured, m.isFinite, m >= 0.5 {
            return along + m * min(VehicleMatch.gpsAdvanceSeen, max(-VehicleMatch.gpsAdvanceSeen, dt))
        }
        return along + speed * min(VehicleMatch.gpsAdvance, max(-VehicleMatch.gpsAdvance, dt))
    }
}

/// Which bus or train you're on: the one that moves with you (on its path, going its way, at a possible speed, keeping
/// pace with its own times), compared in seconds off its times. Every number here is a starting value, to be tuned from
/// the field log.
enum VehicleMatch {
    static let window: TimeInterval = 30        // the fixes looked at: the last 30 s
    static let minSpan: TimeInterval = 20       // enough evidence: fixes spanning 20 s…
    static let minFixes = 3                     // …and at least 3 of them
    static let maxAccuracy = 150.0              // m: worse fixes are left out
    static let offPath = 60.0                   // m off a path with a road shape
    static let offPathUnshaped = 250.0          // m off a path of straight lines between stops
    static let accuracyFactor = 1.5             // or this times the fixes' accuracy, when more
    static let backwards = 20.0                 // m it may see you go back along its path (or `jitter` × accuracy)
    static let busMax = 31.0                    // m/s: Dutch buses are limited to 100 km/h
    static let speedRatio = 3.0                 // your speed at least its speed ÷ 3
    static let steadyShare = 0.3                // steady: the two halves' speeds within 30 %
    static let driftMin = 3.0                   // m/s: moving with you…
    static let driftShare = 0.45                // …or 45 % of your speed, when more (a train or bus cruising faster
                                                //    than its piece's even speed, between speeding up and braking, is
                                                //    still the one)
    static let standingMin = 40.0               // m you moved before "standing" is judged
    static let standingShare = 0.2              // it moved at least a fifth as far
    static let costSpeedMin = 5.0               // m/s: the least speed a cost is divided by
    static let oneFixTurn = 75.0                // degrees between your course and its path, with one fix
    static let slack: TimeInterval = 30         // s before its first piece and after its last it still counts as there
    static let passSlack = 20.0                 // m: where its path passes you twice, a pass this much (or the fix's
                                                //    accuracy) further than the nearest still counts
    static let prefilterMargin = 300.0          // m around a path where a fix can still be on it (the path test allows
                                                //    250 m at most)
    static let jitter = 2.0                     // GPS jitter at a stop moves you up to twice the fixes' accuracy: only
                                                //    going back further is the wrong way, and only going further is
                                                //    moving (for "standing")
    // Its own GPS (0.20.3)
    static let gpsFresh: TimeInterval = 90      // a fix at most this much older than your newest one is judged by
    static let gpsAhead: TimeInterval = 60      // …and at most this much newer (a clock off)
    static let gpsAdvance: TimeInterval = 60    // moved on (or back) along its road at its piece's speed this long at most
    static let gpsAdvanceSeen: TimeInterval = RealPositions.maxAdvanceSeen     // …at the speed it was seen going (0.34)
    static let gpsOffRoute = 150.0              // m: a fix further from its road isn't used
    static let gpsSpeedOf: TimeInterval = 5     // its speed between two fixes says something about your fixes when the
                                                //    newer one is at most this long before your oldest one
    static let gpsKeep = 200.0                  // m: the ride's own one this close to you, moving with you, is kept

    /// How far a bus or train can be from where its times put it and still be the one you're on: further the faster
    /// you go (at 130 km/h, half a minute off its times is a kilometre).
    static func tolerance(isTrain: Bool, speed: Double) -> Double {
        let v = max(0, speed)
        return isTrain ? min(2500, max(600, v * 60)) : min(1000, max(400, v * 45))
    }

    /// Where its times put it at `t`: metres along its joined pieces. Nil when `t` is outside its pieces (and their slack).
    static func timePosition(_ v: VehicleTrack, at t: Date) -> Double? {
        Joined(v.pieces).position(at: t)
    }

    /// What the fixes of the last `window` seconds say about `v`, each put on the pass of its path nearest its times
    /// and compared with where its times put it at that fix's own time. Fixes before its path's start (further than
    /// `passSlack` or their accuracy) are left out: you're not on it yet. Nil when there is no evidence: no usable fix
    /// (`judgeAll` says `tooFewFixes`), no fix with a time position on it (`noTimes`), your newest fix beyond its path's
    /// end (`offItsPath`), or fewer than 2 fixes left (`tooFewFixes`).
    static func evidence(_ fixes: [Fix], _ v: VehicleTrack) -> Evidence? {
        try? gather(fixes, v).get()
    }

    /// The evidence, or why there is none: `noTimes` when none of the fixes has a time position on it, `offItsPath` when
    /// the newest is beyond its path's end, `tooFewFixes` when no fix is usable or fewer than 2 are left.
    private static func gather(_ fixes: [Fix], _ v: VehicleTrack) -> Result<Evidence, Reject> {
        let good = fixes.filter(usable)
        guard let newest = good.map(\.t).max() else { return .failure(.tooFewFixes) }
        let j = Joined(v.pieces)
        // its own GPS, when fresh and on its road: where it puts it replaces where its times put it
        let anchor = v.gps.flatMap { g in gpsFits(g, newest: newest) ? j.anchor(g, isTrain: v.isTrain) : nil }
        var rows: [(t: Date, along: Double, cross: Double, at: Double, accuracy: Double, connector: Bool)] = []
        var timed = 0, previous: Double?, newestBeyond = false
        let inWindow = good.sorted(by: { $0.t < $1.t }).filter { newest.timeIntervalSince($0.t) <= window }
        for f in inWindow {
            let at = anchor.map { $0.position(at: f.t) } ?? j.position(at: f.t)
            if at != nil { timed += 1 }
            newestBeyond = false
            // where its path passes you twice, the pass nearest its times (or, without, nearest your last fix)
            guard let p = j.pass(f.p, near: at ?? previous, within: max(passSlack, f.accuracy), previous: previous) else { continue }
            let away = beyondAnEnd(p.projection.crossTrack, f.accuracy)
            // before its path starts (a trip that starts at a stop you're coming to): not on its path yet, left out
            if p.beforeStart && away { continue }
            // beyond its end (a trip that ended at a stop you passed): counts against it, when it's your newest fix and
            // you're moving (standing past its stop, in a long stop whose next piece the map doesn't have yet, it's at
            // its end)
            newestBeyond = p.beyondEnd && away && f.speed.isFinite && f.speed >= 3
            previous = p.projection.along
            guard let at else { continue }
            rows.append((f.t, p.projection.along, p.projection.crossTrack, at, f.accuracy, p.connector))
        }
        guard timed > 0 else { return .failure(.noTimes) }
        if newestBeyond { return .failure(.offItsPath) }
        guard rows.count >= 2, let first = rows.first, let last = rows.last else { return .failure(.tooFewFixes) }
        let span = last.t.timeIntervalSince(first.t), offset = last.along - last.at
        // The ends you went from and to: the median of the first 3 and of the last 3 fixes (from their middle fixes'
        // times) once there are 6, else the first and the last fix.
        var ends: (from: [(t: Date, along: Double, cross: Double, at: Double, accuracy: Double, connector: Bool)],
                   to: [(t: Date, along: Double, cross: Double, at: Double, accuracy: Double, connector: Bool)],
                   time: TimeInterval) = ([first], [last], span)
        if rows.count >= 6 {
            let middle = rows[rows.count - 2].t.timeIntervalSince(rows[1].t)
            // fixes bunched in the middle of the window give a short time between the ends: then the end fixes and the
            // whole span are the better measure
            if middle > 0, middle >= span / 2 { ends = (Array(rows.prefix(3)), Array(rows.suffix(3)), middle) }
        }
        let progress = median(ends.to.map { $0.along }) - median(ends.from.map { $0.along })
        let drift = median(ends.to.map { $0.along - $0.at }) - median(ends.from.map { $0.along - $0.at })
        let per: (Double, TimeInterval) -> Double = { x, t in t > 0 ? x / t : 0 }
        let recent = rows.suffix(3)
        var e = Evidence(fixes: rows.count, span: span,
                         crossTrack: median(recent.map { $0.cross }), accuracy: median(rows.map { $0.accuracy }),
                         // a straight line it adds between pieces that don't meet has no road shape either
                         shaped: v.pieces.contains { $0.path.count > 2 } && !recent.contains { $0.connector },
                         progress: progress, offset: offset, drift: per(drift, ends.time),
                         yourSpeed: per(abs(progress), ends.time), itsSpeed: per(last.at - first.at, span),
                         steady: steady(rows.map { ($0.t, $0.along) }))
        if let a = anchor, let g = v.gps {
            // by its GPS: its speed is its own (between its last two fixes, else its piece's), and moving with you is
            // your speed along its road against that one
            e.gps = true
            e.gpsAge = newest.timeIntervalSince(g.fix.at)
            e.gpsSpeed = a.measured
            e.speedKnown = a.measured != nil && g.fix.at >= first.t.addingTimeInterval(-gpsSpeedOf)
            e.itsSpeed = a.measured ?? a.speed
            e.drift = per(progress, ends.time) - e.itsSpeed
            e.headingOff = Self.heading(inWindow).flatMap { yours in a.heading.map { angle(yours, $0) } }
        }
        let numbers = [e.span, e.crossTrack, e.accuracy, e.progress, e.offset, e.drift, e.yourSpeed, e.itsSpeed]
        return numbers.allSatisfy(\.isFinite) ? .success(e) : .failure(.noTimes)
    }

    /// Its GPS fix may be judged by at your newest fix's time: at most `gpsFresh` older, at most `gpsAhead` newer.
    static func gpsFits(_ g: VehicleGPS, newest: Date) -> Bool {
        let age = newest.timeIntervalSince(g.fix.at)
        return age.isFinite && age <= gpsFresh && age >= -gpsAhead
    }

    /// Your heading: your newest fix's GPS course while moving (3 m/s), else the way from your first to your newest
    /// fix when 20 m or more apart. Nil when neither.
    private static func heading(_ sorted: [Fix]) -> Double? {
        if let f = sorted.last, f.course.isFinite, f.course >= 0, f.course <= 360, f.speed.isFinite, f.speed >= 3 { return f.course }
        guard let a = sorted.first, let b = sorted.last, Geo.metres(a.p, b.p) >= 20 else { return nil }
        return Geo.bearing(a.p, b.p)
    }

    /// Degrees between two headings (0 to 180).
    static func angle(_ a: Double, _ b: Double) -> Double {
        var t = abs(a - b).truncatingRemainder(dividingBy: 360)
        if t > 180 { t = 360 - t }
        return t
    }

    /// The hard tests, in order: the first one failed is the reason. Passing costs the seconds you are off its times.
    /// `strictTimes: false` (choosing between candidates): a timetable-only vehicle skips the tests that use its times.
    /// By its own GPS (`e.gps`) "its times" are where its fix puts it, and it's judged so even while choosing; the speed
    /// tests (wrong speed, standing, drifting) only when its speed is known for your fixes' time (`speedKnown`).
    /// `minFixes`/`minSpan`: enough evidence (fewer for the fast lane, `MatchRules.fastLane`).
    static func judge(_ e: Evidence, isTrain: Bool, realTime: Bool, strictTimes: Bool = true,
                      minFixes: Int = VehicleMatch.minFixes, minSpan: TimeInterval = VehicleMatch.minSpan) -> Result<Double, Reject> {
        let byTimes = strictTimes || realTime || e.gps
        let bySpeed = byTimes && e.speedKnown
        // 1. enough evidence
        guard e.fixes >= minFixes, e.span >= minSpan else { return .failure(.tooFewFixes) }
        // 2. on its path
        let off = max(e.shaped ? offPath : offPathUnshaped, accuracyFactor * e.accuracy)
        guard e.crossTrack <= off else { return .failure(.offItsPath) }
        // 3. going its way (GPS jitter at a stop can look like going back by up to twice the fixes' accuracy)
        guard e.progress >= -max(backwards, jitter * e.accuracy) else { return .failure(.wrongWay) }
        // 4. a possible speed (its times only say something about its speed when it isn't crawling: the same 5 m/s floor
        //    as the cost)
        if !isTrain, !(e.yourSpeed <= busMax) { return .failure(.implausibleSpeed) }
        if bySpeed, e.steady, e.itsSpeed >= costSpeedMin, e.yourSpeed < e.itsSpeed / speedRatio { return .failure(.implausibleSpeed) }
        if byTimes {
            // 5. not standing while you go (once you moved further than GPS jitter can take you): by its times it went
            //    at least a fifth as far as you, in the same time
            if bySpeed, abs(e.progress) >= max(standingMin, jitter * e.accuracy), e.itsSpeed < standingShare * e.yourSpeed {
                return .failure(.standing)
            }
            // 6. moves with you
            if bySpeed, e.steady, abs(e.drift) > max(driftMin, driftShare * e.yourSpeed) { return .failure(.drifting) }
            // 7. near its times
            //    (by its own GPS, an older fix has more room: 0.34)
            let room = e.gps ? RealPositions.ageSlack(age: e.gpsAge ?? 0, speed: e.itsSpeed) : 0
            guard abs(e.offset) <= tolerance(isTrain: isTrain, speed: e.yourSpeed) + room else { return .failure(.tooFarFromTimes) }
        }
        return .success(cost(offset: e.offset, itsSpeed: e.itsSpeed))
    }

    /// Every vehicle judged on the same fixes; `noTimes` when no fix has a time position on it, `offItsPath` when your
    /// newest fix is beyond its path's end (while you move), `tooFewFixes` when fewer than 2 fixes are left.
    /// `prefilter`: a vehicle whose path's box, widened by `prefilterMargin`, has none of the fixes of the last `window`
    /// seconds is off its path at once, without projecting them (none could pass the path test); `false` projects
    /// every fix, for the tests that the outcome is the same.
    /// `minFixes`/`minSpan`: enough evidence (fewer for the fast lane).
    static func judgeAll(_ fixes: [Fix], _ vs: [VehicleTrack], strictTimes: Bool = true, prefilter: Bool = true,
                         minFixes: Int = VehicleMatch.minFixes, minSpan: TimeInterval = VehicleMatch.minSpan) -> [Judgement] {
        let recent = prefilter ? lastWindow(fixes) : []
        return vs.map { v -> Judgement in
            if !recent.isEmpty, !nearPath(recent, v) {
                return Judgement(id: v.tripId, line: v.line, isTrain: v.isTrain, realTime: v.realTime, evidence: nil, result: .failure(.offItsPath))
            }
            switch gather(fixes, v) {
            case .success(let e):
                let r = judge(e, isTrain: v.isTrain, realTime: v.realTime, strictTimes: strictTimes, minFixes: minFixes, minSpan: minSpan)
                return Judgement(id: v.tripId, line: v.line, isTrain: v.isTrain, realTime: v.realTime, evidence: e, result: r)
            case .failure(let why):
                return Judgement(id: v.tripId, line: v.line, isTrain: v.isTrain, realTime: v.realTime, evidence: nil, result: .failure(why))
            }
        }
    }

    /// With one fix only: on its path, going its way by the GPS course, a possible bus speed, and near its times, all at
    /// the fix's own time. A fix before its path's start is too little to tell (`tooFewFixes`); one beyond its end, while
    /// you're moving, is off its path.
    static func judgeOne(_ f: Fix, _ v: VehicleTrack, tolerance: Double) -> Judgement {
        func verdict(_ e: Evidence?, _ r: Result<Double, Reject>) -> Judgement {
            Judgement(id: v.tripId, line: v.line, isTrain: v.isTrain, realTime: v.realTime, evidence: e, result: r)
        }
        guard f.accuracy.isFinite, f.accuracy >= 0, f.accuracy <= maxAccuracy else { return verdict(nil, .failure(.tooFewFixes)) }
        let j = Joined(v.pieces)
        // its own GPS, when fresh and on its road, instead of its times
        let anchor = v.gps.flatMap { g in gpsFits(g, newest: f.t) ? j.anchor(g, isTrain: v.isTrain) : nil }
        guard let at = anchor.map({ $0.position(at: f.t) }) ?? j.position(at: f.t) else { return verdict(nil, .failure(.noTimes)) }
        guard let pass = j.pass(f.p, near: at, within: max(passSlack, f.accuracy)) else { return verdict(nil, .failure(.tooFewFixes)) }
        let away = beyondAnEnd(pass.projection.crossTrack, f.accuracy)
        // before its path starts (a trip that starts at a stop ahead of you): not on its path yet
        if pass.beforeStart && away { return verdict(nil, .failure(.tooFewFixes)) }
        let p = pass.projection, speed = f.speed.isFinite ? f.speed : -1
        let its = anchor.map { $0.measured ?? $0.speed } ?? j.speed(at: f.t)
        var e = Evidence(fixes: 1, span: 0, crossTrack: p.crossTrack, accuracy: f.accuracy,
                         shaped: v.pieces.contains { $0.path.count > 2 } && !pass.connector, progress: 0, offset: p.along - at,
                         drift: 0, yourSpeed: max(0, speed), itsSpeed: its, steady: false)
        if let a = anchor, let g = v.gps {
            e.gps = true; e.gpsAge = f.t.timeIntervalSince(g.fix.at); e.gpsSpeed = a.measured; e.speedKnown = false
            if f.course.isFinite, f.course >= 0, speed >= 3, let h = a.heading { e.headingOff = angle(f.course, h) }
        }
        guard [e.crossTrack, e.offset, e.itsSpeed].allSatisfy(\.isFinite) else { return verdict(nil, .failure(.noTimes)) }
        // beyond its end while you're moving (a trip that ended at a stop behind you), or off its path
        if pass.beyondEnd && away && speed >= 3 { return verdict(e, .failure(.offItsPath)) }
        guard e.crossTrack <= max(e.shaped ? offPath : offPathUnshaped, accuracyFactor * f.accuracy) else { return verdict(e, .failure(.offItsPath)) }
        // going its way, by the GPS's course while you're moving (a straight line it adds between pieces that don't
        // meet says nothing about which way its road runs)
        if !pass.connector, f.course.isFinite, f.course >= 0, speed >= 3 {
            var turn = abs(p.bearing - f.course).truncatingRemainder(dividingBy: 360)
            if turn > 180 { turn = 360 - turn }
            if turn > oneFixTurn { return verdict(e, .failure(.wrongWay)) }
        }
        // a possible bus speed
        if !v.isTrain, speed > busMax { return verdict(e, .failure(.implausibleSpeed)) }
        // near its times
        guard abs(e.offset) <= tolerance else { return verdict(e, .failure(.tooFarFromTimes)) }
        return verdict(e, .success(cost(offset: e.offset, itsSpeed: its)))
    }

    /// The ones that passed, best first: cost in seconds, the planned one `plannedBonus` seconds less; ties by id.
    static func rank(_ judged: [Judgement], planned: String?, plannedBonus: Double = 45) -> [Ranked] {
        judged.compactMap { j -> Ranked? in
            guard case .success(let c) = j.result else { return nil }
            return Ranked(id: j.id, cost: j.id == planned ? c - plannedBonus : c)
        }
        .sorted { $0.cost != $1.cost ? $0.cost < $1.cost : $0.id < $1.id }
    }

    /// Which one to show, with hysteresis.
    /// - Nothing shown yet: one candidate, or a best that beats the second by `margin` with both live, is shown; else up
    ///   to 3 stay in the running (those within `margin` of the best, or the best three when either of the best two is
    ///   timetable-only).
    /// - One shown: kept while it is the best, while it or the best is timetable-only and it still passes, or while the
    ///   best beats it by less than `margin`. It switches only after the same other one has been `margin` better (or the
    ///   shown one failed) in `looks` looks in a row spanning at least `span` seconds.
    /// - `unsure`: the ones it isn't sure about yet (too few fixes, no times now). A shown one among them hasn't failed:
    ///   it's kept, and the look breaks the run (it can't tell whether the other one is better).
    static func decide(shown: String?, ranked: [Ranked], liveIds: Set<String>, unsure: Set<String> = [], state: inout SwitchState,
                       now: Date, margin: Double = 60, looks: Int = 3, span: TimeInterval = 45) -> Decision {
        guard let best = ranked.first else {
            state = SwitchState()
            if let shown { return .keep(shown) }
            return Decision.none
        }
        guard let shown else {
            guard ranked.count > 1 else { state = SwitchState(); return .switchTo(best.id) }
            let second = ranked[1]
            let bothLive = liveIds.contains(best.id) && liveIds.contains(second.id)
            if bothLive, second.cost - best.cost >= margin { state = SwitchState(); return .switchTo(best.id) }
            let running = ranked.prefix(3).filter { !bothLive || $0.cost - best.cost < margin }
            return .undecided(running.map(\.id))
        }
        if best.id == shown { state = SwitchState(); return .keep(shown) }
        if let mine = ranked.first(where: { $0.id == shown }) {
            let bothLive = liveIds.contains(shown) && liveIds.contains(best.id)
            if !bothLive || mine.cost - best.cost < margin { state = SwitchState(); return .keep(shown) }
        } else if unsure.contains(shown) {
            state = SwitchState(); return .keep(shown)
        }
        // a look for `best`: the same one as last time carries the run on; any other starts it again
        if state.leader == best.id, state.since != nil {
            state.looks += 1
        } else {
            state = SwitchState(leader: best.id, looks: 1, since: now)
        }
        if state.looks >= looks, let since = state.since, now.timeIntervalSince(since) >= span {
            state = SwitchState()
            return .switchTo(best.id)
        }
        return .keep(shown)
    }

    // MARK: - Helpers

    /// A fix whose nearest spot on a path is one of its ends, this far from it, is beyond that end: further than
    /// `passSlack` or the fix's accuracy.
    private static func beyondAnEnd(_ crossTrack: Double, _ accuracy: Double) -> Bool {
        crossTrack > max(passSlack, accuracy)
    }

    /// The usable fixes of the last `window` seconds, counted back from the newest usable one.
    private static func lastWindow(_ fixes: [Fix]) -> [Fix] {
        let good = fixes.filter(usable)
        guard let newest = good.map(\.t).max() else { return [] }
        return good.filter { newest.timeIntervalSince($0.t) <= window }
    }

    /// Some of `fixes` lies in the box around `v`'s path points (its connectors run between them), widened by
    /// `prefilterMargin`. True for a path without a real point: then the full judgement decides.
    private static func nearPath(_ fixes: [Fix], _ v: VehicleTrack) -> Bool {
        var south = Double.infinity, north = -Double.infinity, west = Double.infinity, east = -Double.infinity
        for piece in v.pieces {
            for p in piece.path where p.lat.isFinite && p.lon.isFinite {
                south = min(south, p.lat); north = max(north, p.lat); west = min(west, p.lon); east = max(east, p.lon)
            }
        }
        guard south <= north, west <= east else { return true }
        // degrees for the margin: east-west at the box's latitude furthest from the equator (the widest in degrees)
        let dLat = prefilterMargin / 110_540
        let c = cos(max(abs(south), abs(north)) * .pi / 180)
        guard c > 0.01 else { return true }
        let dLon = prefilterMargin / (111_320 * c)
        return fixes.contains {
            $0.p.lat >= south - dLat && $0.p.lat <= north + dLat && $0.p.lon >= west - dLon && $0.p.lon <= east + dLon
        }
    }

    /// A fix the evidence uses: a known accuracy of at most `maxAccuracy`, at a real place.
    private static func usable(_ f: Fix) -> Bool {
        f.accuracy.isFinite && f.accuracy >= 0 && f.accuracy <= maxAccuracy && f.p.lat.isFinite && f.p.lon.isFinite
    }

    /// Seconds off its times: metres ÷ its speed (at least `costSpeedMin`).
    private static func cost(offset: Double, itsSpeed: Double) -> Double {
        abs(offset) / max(costSpeedMin, itsSpeed)
    }

    /// The middle value (the mean of the middle two for an even count); 0 for none.
    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Your speed along its path in the first and the second half of the time, both at least `driftMin` and within
    /// `steadyShare` of the faster one.
    private static func steady(_ rows: [(t: Date, along: Double)]) -> Bool {
        guard let first = rows.first, let last = rows.last else { return false }
        let half = last.t.timeIntervalSince(first.t) / 2
        guard half > 0 else { return false }
        let mid = first.t.addingTimeInterval(half)
        var atMid = last.along
        for i in 1..<rows.count where rows[i].t >= mid {
            let a = rows[i - 1], b = rows[i], dt = b.t.timeIntervalSince(a.t)
            atMid = dt > 0 ? a.along + (b.along - a.along) * mid.timeIntervalSince(a.t) / dt : b.along
            break
        }
        let v1 = abs(atMid - first.along) / half, v2 = abs(last.along - atMid) / half
        guard v1.isFinite, v2.isFinite, v1 >= driftMin, v2 >= driftMin else { return false }
        return abs(v1 - v2) <= steadyShare * max(v1, v2)
    }

    /// Pieces by departure (then arrival, then as given).
    fileprivate static func byDeparture(_ pieces: [TimedPiece]) -> [TimedPiece] {
        pieces.enumerated().sorted { a, b in
            if a.element.departure != b.element.departure { return a.element.departure < b.element.departure }
            if a.element.arrival != b.element.arrival { return a.element.arrival < b.element.arrival }
            return a.offset < b.offset
        }
        .map { $0.element }
    }

    /// A vehicle's pieces joined into one path: each piece starts at the joined length before its first point.
    /// Pieces that don't meet are joined by a straight line (a connector), which has no road shape.
    private struct Joined {
        let pieces: [TimedPiece]
        let starts: [Double]
        let lengths: [Double]
        let path: [GeoPoint]
        let connectors: Set<Int>        // the segments (by their first point) that join pieces that don't meet

        init(_ given: [TimedPiece]) {
            let pieces = VehicleMatch.byDeparture(given)
            var path: [GeoPoint] = [], starts: [Double] = [], lengths: [Double] = [], total = 0.0
            var connectors = Set<Int>()
            for p in pieces {
                if let end = path.last, let begin = p.path.first {
                    total += Geo.metres(end, begin)
                    if end != begin { connectors.insert(path.count - 1) }
                }
                let l = Geo.length(p.path)
                starts.append(total); lengths.append(l)
                total += l
                path += p.path
            }
            self.pieces = pieces; self.starts = starts; self.lengths = lengths; self.path = path
            self.connectors = connectors
        }

        /// Where its path passes `p` (see `Geo.pass`), whether that is on a connector, and whether it lies before the
        /// joined path's start or beyond its end.
        func pass(_ p: GeoPoint, near: Double?, within: Double, previous: Double? = nil)
            -> (projection: Geo.Projection, connector: Bool, beforeStart: Bool, beyondEnd: Bool)? {
            guard let found = Geo.pass(p, on: path, near: near, within: within, previous: previous) else { return nil }
            return (found.projection, connectors.contains(found.segment), found.beforeStart, found.beyondEnd)
        }

        /// Metres along the joined path where its times put it at `t`.
        /// - Inside a piece, by time (a piece that takes no time: at its end).
        /// - Between pieces, by time along the connector from the earlier one's end (at its arrival) to the next one's
        ///   start (at its departure). Pieces that meet have a connector of 0 m: it waits at the stop.
        /// - Up to `slack` before the first or after the last: at that end. Otherwise nil.
        func position(at t: Date) -> Double? {
            guard !pieces.isEmpty else { return nil }
            if let k = pieces.lastIndex(where: { $0.departure <= t && t <= $0.arrival }) {
                let p = pieces[k], d = p.arrival.timeIntervalSince(p.departure)
                guard d > 0 else { return starts[k] + lengths[k] }
                return starts[k] + lengths[k] * min(1, max(0, t.timeIntervalSince(p.departure) / d))
            }
            if let k = pieces.firstIndex(where: { $0.departure > t }) {
                guard k > 0 else { return t >= pieces[0].departure.addingTimeInterval(-VehicleMatch.slack) ? starts[0] : nil }
                let from = starts[k - 1] + lengths[k - 1], to = starts[k]
                let a = pieces[k - 1].arrival, d = pieces[k].departure.timeIntervalSince(a)
                guard d > 0 else { return to }
                return from + (to - from) * min(1, max(0, t.timeIntervalSince(a) / d))
            }
            let k = pieces.count - 1
            return t <= pieces[k].arrival.addingTimeInterval(VehicleMatch.slack) ? starts[k] + lengths[k] : nil
        }

        /// Where its own GPS puts it on the joined path (0.20.3): its newest fix on the pass nearest where its times have
        /// it at the fix's time (of the passes within 30 m of the nearest), within `gpsOffRoute` of the path (beyond an
        /// end: within `passSlack`). Its speed to move on by: its piece's by its times (30 m/s at most for a bus, 45 for
        /// a train). Its own speed: the one its fix gives (a train's), else between its fix before and this one along
        /// the path, 5 s to 3 minutes apart (never less than 0). Nil when the fix isn't on its path.
        func anchor(_ g: VehicleGPS, isTrain: Bool) -> GPSAnchor? {
            let f = g.fix
            guard let p = pass(f.point, near: position(at: f.at), within: 30) else { return nil }
            let cross = p.projection.crossTrack
            guard cross.isFinite, cross <= VehicleMatch.gpsOffRoute,
                  !(p.beforeStart || p.beyondEnd) || cross <= VehicleMatch.passSlack else { return nil }
            let along = p.projection.along
            // the piece it's on (in a connector between two: the next one)
            let k = starts.indices.first { along <= starts[$0] + lengths[$0] } ?? (pieces.count - 1)
            let cap = isTrain ? 45.0 : RealPositions.maxSpeed
            let d = pieces[k].arrival.timeIntervalSince(pieces[k].departure)
            let pieceSpeed = lengths[k] > 0 ? min(cap, lengths[k] / max(1, d)) : 0
            var measured: Double?
            if let s = f.speed, s.isFinite, s >= 0 {
                measured = min(s, 60)
            } else if let q = g.previous {
                let dt = f.at.timeIntervalSince(q.at)
                if dt >= 5, dt <= 180,
                   let pq = pass(q.point, near: along - pieceSpeed * dt, within: 30), pq.projection.crossTrack <= VehicleMatch.gpsOffRoute {
                    let v = (along - pq.projection.along) / dt
                    if v.isFinite, v >= -3 { measured = min(60, max(0, v)) }
                }
            }
            return GPSAnchor(along: along, at: f.at, speed: pieceSpeed, measured: measured,
                             heading: f.bearing ?? p.projection.bearing)
        }

        /// Its speed by its times around `t` (m/s over the half minute around it, or what of it it has times for).
        func speed(at t: Date) -> Double {
            let a = position(at: t.addingTimeInterval(-15)).map { ($0, -15.0) } ?? position(at: t).map { ($0, 0.0) }
            let b = position(at: t.addingTimeInterval(15)).map { ($0, 15.0) } ?? position(at: t).map { ($0, 0.0) }
            guard let a, let b, b.1 > a.1 else { return 0 }
            return (b.0 - a.0) / (b.1 - a.1)
        }
    }
}

extension VehicleMatch {
    /// The buses and trains whose road you're on and that go your way, found by the road, not by where their times put
    /// them: one running a few minutes late or early is kilometres from its timetable position, but it's on this road,
    /// going this way, about now. A piece counts where its road passes within `maxMetres` of you and runs within
    /// `maxTurn` degrees of your GPS course; `late` is the fix's own time minus when the piece's times have it at that
    /// spot, and only |late| < `maxLate` counts. Per trip the least late (of its pieces, and of the places a piece passes
    /// you); least late first, ties by id. Nothing without a GPS course.
    static func byRoad(_ f: Fix, _ pieces: [MapPiece], maxMetres: Double = 100, maxTurn: Double = 60,
                       maxLate: TimeInterval = 720) -> [RoadHit] {
        guard f.course.isFinite, f.course >= 0 else { return [] }
        var best: [String: RoadHit] = [:]
        for m in pieces {
            let span = m.piece.arrival.timeIntervalSince(m.piece.departure)
            for pass in Geo.passes(f.p, on: m.piece.path) where pass.projection.crossTrack <= maxMetres {
                let p = pass.projection
                var turn = abs(p.bearing - f.course).truncatingRemainder(dividingBy: 360)
                if turn > 180 { turn = 360 - turn }
                guard turn <= maxTurn else { continue }
                // when its times have it here, and how far off that is from the fix's own time
                let late = f.t.timeIntervalSince(m.piece.departure) - p.fraction * span
                guard late.isFinite, abs(late) < maxLate else { continue }
                if best[m.tripId].map({ abs(late) < abs($0.late) }) ?? true {
                    best[m.tripId] = RoadHit(tripId: m.tripId, line: m.line, isTrain: m.isTrain, late: late)
                }
            }
        }
        return best.values.sorted { a, b in
            abs(a.late) != abs(b.late) ? abs(a.late) < abs(b.late) : a.tripId < b.tripId
        }
    }

    /// The one it has fails in a way the other kind could explain (a train where it planned a bus): your speed doesn't fit
    /// it, or you don't move with it.
    static func otherKindPossible(_ r: Reject?) -> Bool {
        switch r {
        case .implausibleSpeed?, .drifting?: return true
        default: return false
        }
    }
}

extension VehicleMatch {
    /// The usable fixes of the last `window` seconds (counted back from the newest usable one): how many, and the
    /// time they span.
    static func spread(_ fixes: [Fix]) -> (fixes: Int, span: TimeInterval) {
        let recent = lastWindow(fixes)
        guard let newest = recent.map(\.t).max(), let oldest = recent.map(\.t).min() else { return (0, 0) }
        return (recent.count, newest.timeIntervalSince(oldest))
    }

    /// Enough fixes to judge by (the first hard test's own minimum): of the usable ones of the last `window` seconds, at
    /// least `minFixes`, spanning at least `minSpan`. Until then nothing passes `judgeAll`: not sure yet.
    static func enough(_ fixes: [Fix]) -> Bool {
        let s = spread(fixes)
        return s.fixes >= minFixes && s.span >= minSpan
    }

    /// The best `limit` of the ranked ones, always with `keep` (the planned or shown one) when it passed: then it takes
    /// the last place if it isn't in them already.
    static func top(_ ranked: [Ranked], keep: String?, limit: Int = 10) -> [Ranked] {
        guard limit > 0 else { return [] }
        var out = Array(ranked.prefix(limit))
        if let keep, !out.contains(where: { $0.id == keep }), let k = ranked.first(where: { $0.id == keep }) {
            if out.count >= limit { out.removeLast() }
            out.append(k)
        }
        return out
    }

    /// Looks in a row a candidate may fail the hard tests before it's out of the running.
    static let dropAfter = 2

    /// How long you may have clearly left on the planned one, with too few fixes to judge by, before it goes by the
    /// timetable anyway (sparse GPS, on a train, may never give enough).
    static let fallbackAfter: TimeInterval = 60

    /// The timetable fallback may go ahead: enough fixes to judge by, or you've clearly left (`leftSince`) for
    /// `after` (a minute) without them.
    static func fallbackSure(enough: Bool, leftSince: Date?, now: Date, after: TimeInterval = VehicleMatch.fallbackAfter) -> Bool {
        if enough { return true }
        guard let leftSince else { return false }
        return now.timeIntervalSince(leftSince) >= after
    }

    /// Since when something has held, look by look: from the first look it holds, kept while it holds, nil once it
    /// doesn't.
    static func heldSince(_ since: Date?, holds: Bool, now: Date) -> Date? {
        holds ? (since ?? now) : nil
    }

    /// A failure (other than tooFewFixes or noTimes) adds a miss; a success resets it. Returns those with < 2 misses, plus `keep` always.
    /// ("Not sure yet" neither adds nor resets: it's no look at all. `keep`, the one shown, is never dropped this way: the
    /// switching rule covers it.)
    static func prune(_ judged: [Judgement], misses: inout [String: Int], keep: String?) -> [Judgement] {
        prune(judged, misses: &misses, keeping: keep.map { Set([$0]) } ?? Set<String>())
    }

    /// `prune`, never dropping any of `keeping`.
    static func prune(_ judged: [Judgement], misses: inout [String: Int], keeping: Set<String>) -> [Judgement] {
        for j in judged {
            switch j.result {
            case .success: misses[j.id] = nil
            case .failure(let why): if !why.notSure { misses[j.id, default: 0] += 1 }
            }
        }
        return judged.filter { keeping.contains($0.id) || misses[$0.id, default: 0] < dropAfter }
    }

    /// Today's road check: your last fix this far from a bus's road (or `offRoadTrain` from a train's) is off it.
    static let offRoadBus = 300.0, offRoadTrain = 700.0

    /// Off its road by today's check: `metres` (your last fix from its road; nil: no road known) at least 300 m for a bus,
    /// 700 m for a train.
    static func offRoad(_ metres: Double?, isTrain: Bool) -> Bool {
        guard let metres else { return false }
        return metres >= (isTrain ? offRoadTrain : offRoadBus)
    }

    /// The one it shows, this look: it passes; it fails (a real hard-test failure, or, while it's not sure yet (too few
    /// fixes, no times now, or no track at all: `r` nil), you're off its road by today's check); or it's not sure yet.
    /// (A trip whose times have ended says nothing by its times: a late one you're on is still on its road, a wrong one
    /// that ended at a stop you passed isn't.)
    static func verdict(_ r: Result<Double, Reject>?, offRoad: Bool) -> ShownVerdict {
        switch r {
        case .success?: return .passes
        case .failure(let why)? where !why.notSure: return .fails
        default: return offRoad ? .fails : .notSure
        }
    }

    /// One look while choosing between `ids` (in the order shown; the one shown among them), `judged` those it has a
    /// track for, `shownOffRoad` today's road check for the one shown, `choosingFor` the seconds since choosing began.
    /// - A candidate that fails `dropAfter` looks in a row is out (`prune`); the one shown never is, and counts as failed
    ///   while it's not sure yet but off its road (`verdict`). One it can't judge yet (no track) stays in the running.
    /// - `decide` with the seconds as they are (no planned bonus), the not-sure ones not failed.
    /// - Sure: the one `decide` switches to; the one shown when it's the only one left; after `timeout` (12 minutes) the
    ///   one shown, or, when it's failing (`dropAfter` misses in a row), the best that passed this look.
    /// - A live one shown that fails by its times alone (`timesOnly`, on its road by today's check) while the best is
    ///   timetable-only (judged without its times) is not sure for that look: no miss, the run starts again, and no
    ///   12-minute pick of that best. (Times say nothing about a timetable-only one; failing by them can't make it the
    ///   better one.) Off its path or going the other way still counts.
    static func choose(_ ids: [String], judged: [Judgement], shown: String?, shownOffRoad: Bool, choosingFor: TimeInterval,
                       misses: inout [String: Int], state: inout SwitchState, now: Date,
                       timeout: TimeInterval = 12 * 60) -> ChoiceLook {
        var gps = GPSChoice()
        return choose(ids, judged: judged, shown: shown, shownOffRoad: shownOffRoad, choosingFor: choosingFor,
                      misses: &misses, state: &state, gps: &gps, now: now, timeout: timeout)
    }

    /// `choose` with what the buses' own GPS said (0.26.1, `GPSChoice`): evidence decides, the one shown only wins a
    /// real tie.
    /// - A times-only failure soon after fitting by its own GPS is not sure (`soften`), and one that fitted by its GPS
    ///   in the last `gpsMemory` seconds isn't dropped ("the only one left" needs the other one out for real).
    /// - The roads parted (`roadsParted`): the one shown is far off its path (or off its road by today’s check while another
    ///   one fits by its GPS) and another one passes: that one, at once. Another one that far off is out at once.
    /// - One that fits by its own GPS while every other one fails (or fits `chooseMargin` worse), `gpsLooks` looks in a
    ///   row: that one.
    /// - Otherwise as before, with `chooseMargin` (30 s) as the margin between two that pass.
    /// 0.38: `nudge` moves each one's cost for the ranking (seconds; the usual line's tie-break, the bus stopping
    /// pattern; never what its own GPS says, `gpsBest`); `departed`, the one that left the stop with you
    /// (`DepartMatch.pick`), settles the choice once it passed `departLooks` looks in a row (`departLook`), after the
    /// roads parting and its own GPS.
    static func choose(_ ids: [String], judged given: [Judgement], shown: String?, shownOffRoad: Bool, choosingFor: TimeInterval,
                       misses: inout [String: Int], state: inout SwitchState, gps: inout GPSChoice, now: Date,
                       timeout: TimeInterval = 12 * 60, nudge: [String: Double] = [:], departed: String? = nil) -> ChoiceLook {
        noteGPSFits(given, into: &gps.fitAt, now: now)
        let judged: [Judgement] = soften(given, fits: gps.fitAt, now: now)
        let gpsPick: String? = gpsLook(ids, judged: judged, run: &gps, now: now)
        let splits: Set<String> = Set(judged.filter { roadsParted($0) }.map(\.id))
        let tracked: Set<String> = Set(judged.map(\.id))
        let mineJudged: Judgement? = judged.first { $0.id == shown }
        let mine: Result<Double, Reject>? = mineJudged?.result
        var shownVerdict: ShownVerdict? = shown.map { _ in verdict(mine, offRoad: shownOffRoad) }
        let before: Int? = shown.flatMap { misses[$0] }
        // kept whatever their misses: the one shown, and the ones that fitted by their own GPS a moment ago (not split)
        var protected: Set<String> = Set(gps.fitAt.keys).subtracting(splits)
        if let shown { protected.insert(shown) }
        var pruned: [Judgement] = prune(judged, misses: &misses, keeping: protected)
        // the roads parted: another one far off its path is out at once
        for id in splits where id != shown { misses[id] = max(misses[id, default: 0], dropAfter) }
        pruned = pruned.filter { $0.id == shown || !splits.contains($0.id) }
        let ranked: [Ranked] = nudged(rank(pruned, planned: nil), nudge)
        let live: Set<String> = liveIds(judged)
        // failing by its times only, against a timetable-only best: not sure, this look (its miss undone)
        let failsByTimes: Bool = mineJudged.map { timesOnly($0) } ?? false
        let bestTimetableOnly: Bool = ranked.first.map { !live.contains($0.id) } ?? false
        let byTimesOnly: Bool = !shownOffRoad && failsByTimes && bestTimetableOnly
        if let shown, byTimesOnly { misses[shown] = before; shownVerdict = .notSure }
        // not sure yet but off its road: a miss like any failure (a real failure `prune` counted already)
        if let shown, shownVerdict == .fails, verdict(mine, offRoad: false) != .fails { misses[shown, default: 0] += 1 }
        let kept: Set<String> = Set(pruned.map(\.id))
        let alive: [String] = ids.filter { kept.contains($0) || !tracked.contains($0) }
        let departPick: String? = departLook(departed, judged: judged, alive: alive, run: &gps)
        var unsure: Set<String> = Set(ids.filter { !tracked.contains($0) })
        for j in judged { if case .failure(let why) = j.result, why.notSure { unsure.insert(j.id) } }
        if let shown, shownVerdict == .fails { unsure.remove(shown) }
        if let shown, byTimesOnly { unsure.insert(shown) }
        var decision: Decision = decide(shown: shown, ranked: ranked, liveIds: live, unsure: unsure, state: &state, now: now,
                                        margin: chooseMargin)
        let failing: Bool = !byTimesOnly && (shown.map { misses[$0, default: 0] >= dropAfter } ?? false)
        let shownSplit: Bool = shown.map { s in
            splits.contains(s) || (shownOffRoad && judged.contains { $0.id != s && passedByGPS($0) })
        } ?? false
        var settle: String?, why: ChoiceLook.Why?
        // 0.39.1: the one shown far from you by its own GPS while another one fits by its GPS: that one, at once
        let rescue: String? = gpsRescue(shown: shown, judged: judged, alive: alive, fits: gps.fitAt, splits: splits)
        if shownSplit, let other = ranked.first(where: { $0.id != shown }) {
            decision = .switchTo(other.id); settle = other.id; why = .split
        } else if let r = rescue {
            decision = .switchTo(r); settle = r; why = .farByGPS
        } else if let pick = gpsPick, pick != shown, alive.contains(pick) {
            decision = .switchTo(pick); settle = pick; why = .byGPS
        } else if let pick = departPick {
            decision = pick == shown ? .keep(pick) : .switchTo(pick); settle = pick; why = .departed
        } else {
            switch decision {
            case .switchTo(let id): settle = id; why = .decided
            case .keep(let id) where alive == [id]: settle = id; why = .onlyOneLeft
            default: break
            }
        }
        if settle == nil, choosingFor > timeout {
            if failing, let best = ranked.first { settle = best.id }
            else if let shown, alive.contains(shown) { settle = shown }
            else { settle = ranked.first?.id }
            if settle != nil { why = .timedOut }
        }
        if settle != nil { gps.restart() }
        return ChoiceLook(decision: decision, alive: alive, settle: settle, why: why, shown: shownVerdict, shownFailing: failing)
    }

    /// A failure by its times alone, with its road and your way along it fitting: drifting from its times, standing by
    /// them, too far from them, or a speed its times don't fit (not a bus faster than a bus can go).
    /// (Not one judged by its own GPS: where its fix puts it is no timetable.)
    static func timesOnly(_ j: Judgement) -> Bool {
        guard case .failure(let why) = j.result, j.evidence?.gps != true else { return false }
        switch why {
        case .drifting, .standing, .tooFarFromTimes: return true
        case .implausibleSpeed: return j.isTrain || (j.evidence.map { $0.yourSpeed <= busMax } ?? false)
        default: return false
        }
    }

    /// The ones whose times are live, or that were judged by their own GPS: `decide` tells those apart by their cost.
    static func liveIds(_ judged: [Judgement]) -> Set<String> {
        Set(judged.filter { $0.realTime || $0.evidence?.gps == true }.map(\.id))
    }

    /// "Same bus?" (0.20.3): the ride's own one is kept by its GPS: judged by its fix, that puts it within `gpsKeep`
    /// (200 m) of you along its road, you on its path (as the path test has it), going its way at 3 m/s or more, a
    /// possible bus speed, and moving with you: when its speed is known for your fixes' time, not drifting from you;
    /// else, with a speed from before them, it was moving (3 m/s) then. Nothing else (an arrival, a change, the guards)
    /// is decided by it.
    static func gpsKeeps(_ e: Evidence?, isTrain: Bool) -> Bool {
        guard let e, e.gps, e.fixes >= 2, abs(e.offset) <= gpsKeep else { return false }
        guard e.crossTrack <= max(e.shaped ? offPath : offPathUnshaped, accuracyFactor * e.accuracy) else { return false }
        guard e.progress > 0, e.yourSpeed >= driftMin else { return false }
        if !isTrain, !(e.yourSpeed <= busMax) { return false }
        if e.speedKnown { return abs(e.drift) <= max(driftMin, driftShare * e.yourSpeed) }
        if let v = e.gpsSpeed { return v >= driftMin }
        return true
    }

    /// The fast lane's view of each judged one (`MatchRules.fastLane`): judged by its own GPS or not, how far from you
    /// along its road (nil: no evidence), its heading against yours, whether it passed, and whether it could still be
    /// the one (passed, or failed by its times or speed alone: not off its path, not the other way).
    static func lane(_ judged: [Judgement]) -> [MatchRules.LaneCandidate] {
        judged.map { j in
            let passed: Bool
            var plausible = false
            switch j.result {
            case .success: passed = true; plausible = true
            case .failure(let why):
                passed = false
                switch why {
                case .drifting, .standing, .tooFarFromTimes: plausible = true
                case .implausibleSpeed: plausible = j.isTrain || (j.evidence.map { $0.yourSpeed <= busMax } ?? false)
                default: plausible = false
                }
            }
            return MatchRules.LaneCandidate(id: j.id, gps: j.evidence?.gps == true, metres: j.evidence.map { abs($0.offset) },
                                            headingOff: j.evidence?.headingOff, passed: passed, plausible: plausible && j.evidence != nil)
        }
    }

    /// Choosing again between the same ones as a choice that ran out of time less than `within` (10 minutes) ago: no use,
    /// their times can't tell them apart.
    static func sameChoice(_ ids: [String], as last: TimedOut?, now: Date, within: TimeInterval = 600) -> Bool {
        guard let last else { return false }
        return Set(ids) == last.ids && now.timeIntervalSince(last.at) < within
    }
}

/// The one shown, this look: passes, fails, or not sure yet.
enum ShownVerdict: Equatable, Sendable { case passes, notSure, fails }

/// One look while choosing (see `VehicleMatch.choose`).
struct ChoiceLook: Equatable, Sendable {
    enum Why: Equatable, Sendable { case decided, onlyOneLeft, timedOut, byGPS, split, departed, farByGPS }
    let decision: Decision
    let alive: [String]             // still in the running, in the order given
    let settle: String?             // sure now: the one to show (nil: still choosing)
    let why: Why?
    let shown: ShownVerdict?        // the one shown, this look
    let shownFailing: Bool          // the one shown failed `dropAfter` looks in a row
}

/// A choice that ran out of time (12 minutes) without being sure: between which ones, and when.
struct TimedOut: Equatable, Sendable {
    let ids: Set<String>
    let at: Date
}

/// The one-look thresholds where the app picks the bus or train you're on. Classic matching compares metres from where
/// a vehicle's times put it (today's numbers); the matcher compares seconds off its times.
struct MatchRules: Equatable, Sendable {
    let oneLook: Double             // one look is enough for one of the line it planned, this close
    let oneLookWatched: Double      // …for the line you watch, or the one on the Fastest trip screen
    let expected: Double            // …for one it expects (one it listed or planned)
    let plannedEdge: Double         // the planned one wins when it is at most this much worse than the best
    let close: Double               // others at most this much worse than the pick stay in the running
    let sameLineNear: Double        // still the same bus?: another of its line this close is looked at too
    static let classic = MatchRules(oneLook: 150, oneLookWatched: 250, expected: 350, plannedEdge: 200, close: 300, sameLineNear: 400)  // metres: today
    static let seconds = MatchRules(oneLook: 15, oneLookWatched: 20, expected: 30, plannedEdge: 0, close: 60, sameLineNear: 40)       // seconds off its times

    /// Metres while "Classic vehicle matching" is on, else seconds.
    static func current(_ d: UserDefaults = .standard) -> MatchRules {
        MatchSettings.classic(d) ? .classic : .seconds
    }

    // MARK: the fast lane (0.20.3)

    static let fastFixes = 2                        // enough evidence in the fast lane: 2 fixes…
    static let fastSpan: TimeInterval = 8           // …spanning 8 s (instead of 3 and 20 s)
    static let fastNear = 150.0                     // m: one judged by its own GPS this close to you…
    static let fastTurn = 45.0                      // …heading your way (degrees)…
    static let fastSpeed = 11.0                     // …while you go faster than this (m/s, 40 km/h)…
    static let fastRivals = 400.0                   // …and no other one that could be it this close (m)

    /// One judged one as the fast lane sees it (`VehicleMatch.lane`).
    struct LaneCandidate: Equatable, Sendable {
        let id: String
        let gps: Bool               // judged by its own GPS
        let metres: Double?         // from you along its road (by its GPS, or its times); nil: no evidence
        let headingOff: Double?     // degrees between its heading and yours (GPS only)
        let passed: Bool            // passed the hard tests (with the fast lane's few fixes)
        let plausible: Bool         // could still be the one you're on
    }

    /// Boarding with few fixes: the one to take after `fastSpan` and `fastFixes`, when all of these hold, else nil (the
    /// usual 20 s and 3 fixes):
    /// - exactly one of them is judged by a fresh GPS fix within `fastNear` (150 m) of you, and it passed;
    /// - it heads your way (`fastTurn`, 45°; a heading not known isn't);
    /// - you go faster than `fastSpeed` (11 m/s);
    /// - no other one (by GPS or by its times) that could be it is within `fastRivals` (400 m) of you.
    static func fastLane(_ cands: [LaneCandidate], yourSpeed: Double, fixes: Int, span: TimeInterval) -> String? {
        guard fixes >= fastFixes, span >= fastSpan, yourSpeed.isFinite, yourSpeed > fastSpeed else { return nil }
        let near = cands.filter { c in c.gps && (c.metres.map { $0 <= fastNear } ?? false) }
        guard near.count == 1, let one = near.first, one.passed,
              let turn = one.headingOff, turn.isFinite, turn <= fastTurn else { return nil }
        let rival = cands.contains { c in
            c.id != one.id && c.plausible && (c.metres.map { $0 <= fastRivals } ?? false)
        }
        return rival ? nil : one.id
    }
}
