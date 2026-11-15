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

/// A bus or train: its pieces in departure order, and whether its times are live.
struct VehicleTrack: Equatable, Sendable {
    let tripId: String
    let line: String
    let isTrain: Bool
    let realTime: Bool
    let pieces: [TimedPiece]

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
    let drift: Double           // m/s, the change of the offset (between the same ends as `progress`)
    let yourSpeed: Double       // m/s along its path (`progress` over the time between those ends)
    let itsSpeed: Double        // m/s by its times
    let steady: Bool            // your speed in both halves within 30 % of each other, both at least 3 m/s
}

/// Why a vehicle isn't the one you're on.
enum Reject: Error, Equatable, Sendable {
    case tooFewFixes, offItsPath, wrongWay, implausibleSpeed, standing, drifting, tooFarFromTimes, noTimes
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
    static let driftShare = 0.25                // …or a quarter of your speed, when more
    static let standingMin = 40.0               // m you moved before "standing" is judged
    static let standingShare = 0.2              // it moved at least a fifth as far
    static let costSpeedMin = 5.0               // m/s: the least speed a cost is divided by
    static let oneFixTurn = 75.0                // degrees between your course and its path, with one fix
    static let slack: TimeInterval = 30         // s before its first piece and after its last it still counts as there
    static let passSlack = 20.0                 // m: where its path passes you twice, a pass this much (or the fix's
                                                //    accuracy) further than the nearest still counts
    static let jitter = 2.0                     // GPS jitter at a stop moves you up to twice the fixes' accuracy: only
                                                //    going back further is the wrong way, and only going further is
                                                //    moving (for "standing")

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
    /// and compared with where its times put it at that fix's own time. Nil when there is no evidence: no usable fix
    /// (`judgeAll` says `tooFewFixes`), no fix with a time position on it (`noTimes`), or fewer than 2 usable fixes
    /// (`tooFewFixes`).
    static func evidence(_ fixes: [Fix], _ v: VehicleTrack) -> Evidence? {
        try? gather(fixes, v).get()
    }

    /// The evidence, or why there is none: `noTimes` when none of the fixes has a time position on it, `tooFewFixes`
    /// when no fix is usable or fewer than 2 are.
    private static func gather(_ fixes: [Fix], _ v: VehicleTrack) -> Result<Evidence, Reject> {
        let good = fixes.filter {
            $0.accuracy.isFinite && $0.accuracy >= 0 && $0.accuracy <= maxAccuracy && $0.p.lat.isFinite && $0.p.lon.isFinite
        }
        guard let newest = good.map(\.t).max() else { return .failure(.tooFewFixes) }
        let j = Joined(v.pieces)
        var rows: [(t: Date, along: Double, cross: Double, at: Double, accuracy: Double, connector: Bool)] = []
        var timed = 0, previous: Double?
        for f in good.sorted(by: { $0.t < $1.t }) where newest.timeIntervalSince(f.t) <= window {
            let at = j.position(at: f.t)
            if at != nil { timed += 1 }
            // where its path passes you twice, the pass nearest its times (or, without, nearest your last fix)
            guard let p = j.pass(f.p, near: at ?? previous, within: max(passSlack, f.accuracy), previous: previous) else { continue }
            previous = p.projection.along
            guard let at else { continue }
            rows.append((f.t, p.projection.along, p.projection.crossTrack, at, f.accuracy, p.connector))
        }
        guard timed > 0 else { return .failure(.noTimes) }
        guard rows.count >= 2, let first = rows.first, let last = rows.last else { return .failure(.tooFewFixes) }
        let span = last.t.timeIntervalSince(first.t), offset = last.along - last.at
        // The ends you went from and to: the median of the first 3 and of the last 3 fixes (from their middle fixes'
        // times) once there are 6, else the first and the last fix.
        let ends = rows.count >= 6
            ? (from: Array(rows.prefix(3)), to: Array(rows.suffix(3)), time: rows[rows.count - 2].t.timeIntervalSince(rows[1].t))
            : (from: [first], to: [last], time: span)
        let progress = median(ends.to.map { $0.along }) - median(ends.from.map { $0.along })
        let drift = median(ends.to.map { $0.along - $0.at }) - median(ends.from.map { $0.along - $0.at })
        let per: (Double, TimeInterval) -> Double = { x, t in t > 0 ? x / t : 0 }
        let recent = rows.suffix(3)
        let e = Evidence(fixes: rows.count, span: span,
                         crossTrack: median(recent.map { $0.cross }), accuracy: median(rows.map { $0.accuracy }),
                         // a straight line it adds between pieces that don't meet has no road shape either
                         shaped: v.pieces.contains { $0.path.count > 2 } && !recent.contains { $0.connector },
                         progress: progress, offset: offset, drift: per(drift, ends.time),
                         yourSpeed: per(abs(progress), ends.time), itsSpeed: per(last.at - first.at, span),
                         steady: steady(rows.map { ($0.t, $0.along) }))
        let numbers = [e.span, e.crossTrack, e.accuracy, e.progress, e.offset, e.drift, e.yourSpeed, e.itsSpeed]
        return numbers.allSatisfy(\.isFinite) ? .success(e) : .failure(.noTimes)
    }

    /// The hard tests, in order: the first one failed is the reason. Passing costs the seconds you are off its times.
    /// `strictTimes: false` (choosing between candidates): a timetable-only vehicle skips the tests that use its times.
    static func judge(_ e: Evidence, isTrain: Bool, realTime: Bool, strictTimes: Bool = true) -> Result<Double, Reject> {
        let byTimes = strictTimes || realTime
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
        if byTimes, e.steady, e.itsSpeed >= costSpeedMin, e.yourSpeed < e.itsSpeed / speedRatio { return .failure(.implausibleSpeed) }
        if byTimes {
            // 5. not standing while you go (once you moved further than GPS jitter can take you): by its times it went
            //    at least a fifth as far as you, in the same time
            if abs(e.progress) >= max(standingMin, jitter * e.accuracy), e.itsSpeed < standingShare * e.yourSpeed {
                return .failure(.standing)
            }
            // 6. moves with you
            if e.steady, abs(e.drift) > max(driftMin, driftShare * e.yourSpeed) { return .failure(.drifting) }
            // 7. near its times
            guard abs(e.offset) <= tolerance(isTrain: isTrain, speed: e.yourSpeed) else { return .failure(.tooFarFromTimes) }
        }
        return .success(cost(offset: e.offset, itsSpeed: e.itsSpeed))
    }

    /// Every vehicle judged on the same fixes; `noTimes` when no fix has a time position on it, `tooFewFixes` when fewer
    /// than 2 usable fixes are left.
    static func judgeAll(_ fixes: [Fix], _ vs: [VehicleTrack], strictTimes: Bool = true) -> [Judgement] {
        vs.map { v -> Judgement in
            switch gather(fixes, v) {
            case .success(let e):
                let r = judge(e, isTrain: v.isTrain, realTime: v.realTime, strictTimes: strictTimes)
                return Judgement(id: v.tripId, line: v.line, isTrain: v.isTrain, realTime: v.realTime, evidence: e, result: r)
            case .failure(let why):
                return Judgement(id: v.tripId, line: v.line, isTrain: v.isTrain, realTime: v.realTime, evidence: nil, result: .failure(why))
            }
        }
    }

    /// With one fix only: on its path, going its way by the GPS course, a possible bus speed, and near its times, all at
    /// the fix's own time.
    static func judgeOne(_ f: Fix, _ v: VehicleTrack, tolerance: Double) -> Judgement {
        func verdict(_ e: Evidence?, _ r: Result<Double, Reject>) -> Judgement {
            Judgement(id: v.tripId, line: v.line, isTrain: v.isTrain, realTime: v.realTime, evidence: e, result: r)
        }
        guard f.accuracy.isFinite, f.accuracy >= 0, f.accuracy <= maxAccuracy else { return verdict(nil, .failure(.tooFewFixes)) }
        let j = Joined(v.pieces)
        guard let at = j.position(at: f.t) else { return verdict(nil, .failure(.noTimes)) }
        guard let pass = j.pass(f.p, near: at, within: max(passSlack, f.accuracy)) else { return verdict(nil, .failure(.tooFewFixes)) }
        let p = pass.projection, its = j.speed(at: f.t), speed = f.speed.isFinite ? f.speed : -1
        let e = Evidence(fixes: 1, span: 0, crossTrack: p.crossTrack, accuracy: f.accuracy,
                         shaped: v.pieces.contains { $0.path.count > 2 } && !pass.connector, progress: 0, offset: p.along - at,
                         drift: 0, yourSpeed: max(0, speed), itsSpeed: its, steady: false)
        guard [e.crossTrack, e.offset, e.itsSpeed].allSatisfy(\.isFinite) else { return verdict(nil, .failure(.noTimes)) }
        // on its path
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
    static func decide(shown: String?, ranked: [Ranked], liveIds: Set<String>, state: inout SwitchState, now: Date,
                       margin: Double = 60, looks: Int = 3, span: TimeInterval = 45) -> Decision {
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

        /// Where its path passes `p` (see `Geo.pass`), and whether that is on a connector.
        func pass(_ p: GeoPoint, near: Double?, within: Double, previous: Double? = nil) -> (projection: Geo.Projection, connector: Bool)? {
            guard let found = Geo.pass(p, on: path, near: near, within: within, previous: previous) else { return nil }
            return (found.projection, connectors.contains(found.segment))
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

        /// Its speed by its times around `t` (m/s over the half minute around it, or what of it it has times for).
        func speed(at t: Date) -> Double {
            let a = position(at: t.addingTimeInterval(-15)).map { ($0, -15.0) } ?? position(at: t).map { ($0, 0.0) }
            let b = position(at: t.addingTimeInterval(15)).map { ($0, 15.0) } ?? position(at: t).map { ($0, 0.0) }
            guard let a, let b, b.1 > a.1 else { return 0 }
            return (b.0 - a.0) / (b.1 - a.1)
        }
    }
}
