import CoreLocation
import Foundation

// The bus or train you wait for or ride, drawn where it really is (0.40.3, `RealFirst` has the rules; `BusFusion`'s
// estimate is only its ghost): Fastest trip's map, the live sheet, and (`GPSPlacer.fused`) the home map. The on-board
// matcher keeps its own raw GPS (`VehicleMatch`, `ChooseGPS`, `PickRules`, `WrongBus`): none of this reaches it.

extension LiveTrip {
    /// Its stops as `BusFusion` takes them: metres along its road, and their times.
    var fusionStops: [BusFusion.Stop] {
        stops.indices.map { (i: Int) -> BusFusion.Stop in BusFusion.Stop(metres: metres(ofStop: i), times: stops[i].times) }
    }

    /// Its GPS fix as `RealFirst` takes it: on its road (`RealPositions.snap`, with the speed it was seen going), else off
    /// it (metres straight to your stop `mine`).
    func realFix(_ f: GPSFix, previous: GPSFix?, mine: Int?, legs l: [RealPositions.Leg]) -> RealFirst.Fix {
        var toMine: Double? = nil
        if let k = mine, stops.indices.contains(k) {
            let c: CLLocationCoordinate2D = stops[k].coordinate
            let here = CLLocation(latitude: f.lat, longitude: f.lon)
            toMine = here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
        }
        let stopped: Bool = f.stopped ?? false
        guard let s = RealPositions.snap(f, on: l) else {
            return RealFirst.Fix(metres: nil, at: f.at, speed: f.speed, stopped: stopped, toMine: toMine)
        }
        let seen: Double? = RealPositions.observedSpeed(f, previous: previous, on: l)
        let m: Double = l[s.leg].start + s.along
        return RealFirst.Fix(metres: m, at: f.at, speed: seen, stopped: stopped, toMine: toMine, crossTrack: s.crossTrack)
    }
}

/// The glides and the old way's switch, for whichever map draws it. Not observed: read and written while drawing.
final class RealDraw {
    /// Settings › Map › Bus position: "real" (default) or "estimated" (0.40.1's, `RealFirst.estimated`).
    static let modeKey = "map.busPosition"
    static var estimated: Bool { UserDefaults.standard.string(forKey: modeKey) == "estimated" }

    /// Your phone's fix is good enough to say where the vehicle you're on is (`RealFirst.meFresh`, `meAccuracy`).
    static func usable(me: CLLocation, now: Date) -> Bool {
        let age: TimeInterval = now.timeIntervalSince(me.timestamp)
        let acc: Double = me.horizontalAccuracy
        return age >= -5 && age <= RealFirst.meFresh && acc >= 0 && acc <= RealFirst.meAccuracy
    }

    private var main: [String: RealFirst.Glide] = [:]
    private var ghosts: [String: RealFirst.Glide] = [:]
    private var old: [String: BusFusion.Glide] = [:]

    /// Where to draw it and its ghost now (metres along), gliding: nil where it isn't drawn on its road.
    func glide(_ id: String, _ s: RealFirst.Shown, stops: [BusFusion.Stop], fixAt: Date?, now: Date,
               estimated: Bool) -> (main: Double?, ghost: Double?) {
        var at: Double? = nil
        let onRoad: Bool = s.source == .gps || s.source == .byTimes
        if let m = s.metres, !s.atFix, onRoad {
            if estimated {
                var g: BusFusion.Glide = old[id] ?? BusFusion.Glide()
                let speed: Double = BusFusion.plannedSpeed(stops, at: m)
                at = g.step(to: m, now: now, speed: speed, fixAt: fixAt, fixAge: s.fixAge)
                old[id] = g
            } else {
                var g: RealFirst.Glide = main[id] ?? RealFirst.Glide()
                at = g.step(to: m, now: now)
                main[id] = g
            }
        } else {
            main[id] = nil
            old[id] = nil
        }
        var ghost: Double? = nil
        if let gm = s.ghost {
            var g: RealFirst.Glide = ghosts[id] ?? RealFirst.Glide()
            ghost = g.step(to: gm, now: now)
            ghosts[id] = g
        } else {
            ghosts[id] = nil
        }
        return (at, ghost)
    }
}

/// Where to draw the bus or train you wait for (`RealFirst.show`), gliding (`RealFirst.Glide`); a log line a minute.
/// Not observed: read and written while drawing (as `GPSHold`).
final class BusFuser {
    struct Shown {
        let real: RealFirst.Shown
        let metres: Double?                         // drawn here along its road (nil: at `point`, or not drawn)
        let point: CLLocationCoordinate2D?          // drawn at this place itself (its fix off its road; you, on board)
        let ghost: Double?                          // the estimate, faintly, along its road

        var waiting: Date? { real.waiting }
        var here: RealFirst.Here? { real.here }
        var source: RealFirst.Source { real.source }
        /// Drawn at all.
        var drawn: Bool { source != .none && (metres != nil || point != nil) }
        /// "GPS 40 s", "by times", "you’re on it".
        var tag: String { RealFirst.tag(real) }
        /// Drawn fainter: by its times only.
        var dim: Bool { source == .byTimes }

        /// Where on the map.
        func coordinate(on t: LiveTrip) -> CLLocationCoordinate2D? {
            if let p = point { return p }
            guard let m = metres else { return nil }
            return t.coordinate(atMetres: m)
        }
    }

    private let draw = RealDraw()
    private var fixes: [String: (at: Date, stamp: Int, fix: RealFirst.Fix)] = [:]

    /// `mine`: your stop on its trip; `mineLeaves`: when it leaves there as the card says it; `timesAt`: when its live
    /// times were fetched; `me`: your phone's fix while you ride it (drawn there).
    @MainActor
    func place(_ t: LiveTrip, tripId: String, line: String, isTrain: Bool, mine: Int?, mineLeaves: Date?, timesAt: Date?,
               now: Date, me: CLLocation? = nil) -> Shown {
        let store: RealPositionsStore = RealPositionsStore.shared
        store.learn(tripId, trip: t)                                // (a train: its number, for NS's position)
        let m: Int? = mine.flatMap { t.stops.indices.contains($0) ? $0 : nil }
        let stops: [BusFusion.Stop] = t.fusionStops
        let gf: GPSFix? = store.fix(for: tripId, now: now)
        var fix: RealFirst.Fix? = nil
        if let gf { fix = realFix(t, tripId: tripId, gf, mine: m) }
        let train: Bool = isTrain || RealPositions.isRail(mode: t.mode)
        var input = RealFirst.Input(stops: stops, fix: fix, live: t.live, timesAt: timesAt, mine: m, mineLeaves: mineLeaves,
                                    now: now, fromStart: true, isTrain: train)
        var point: CLLocationCoordinate2D? = nil
        if let p = me, RealDraw.usable(me: p, now: now) {
            let g = GPSFix(lat: p.coordinate.latitude, lon: p.coordinate.longitude, bearing: nil, at: p.timestamp)
            var on: RealFirst.Fix = t.realFix(g, previous: nil, mine: m, legs: t.legs)
            on.speed = p.speed >= 0 ? p.speed : nil
            input.onBoard = on
            point = p.coordinate
        }
        let estimated: Bool = RealDraw.estimated && input.onBoard == nil
        let s: RealFirst.Shown = estimated ? RealFirst.estimated(input) : RealFirst.show(input)
        if s.source != .onBoard { point = nil }
        if s.atFix, s.source == .gps, let gf { point = CLLocationCoordinate2D(latitude: gf.lat, longitude: gf.lon) }
        let d: (main: Double?, ghost: Double?) = draw.glide(tripId, s, stops: stops, fixAt: gf?.at, now: now, estimated: estimated)
        if m != nil || me != nil {
            FusionLog.note(tripId: tripId, line: line, feed: store.feed(for: tripId), s, estimated: estimated, now: now)
        }
        var metres: Double? = nil
        if s.source != .none { metres = point == nil ? d.main : s.metres }
        return Shown(real: s, metres: metres, point: point, ghost: d.ghost)
    }

    /// Its fix as `RealFirst` takes it, put on its road once per fix (and again for a new answer).
    @MainActor
    private func realFix(_ t: LiveTrip, tripId: String, _ gf: GPSFix, mine: Int?) -> RealFirst.Fix {
        let first: Double = t.departure(0)?.timeIntervalSince1970 ?? 0
        let stamp: Int = t.stops.count &* 31 &+ t.path.count &+ Int(first) &+ (mine ?? -1) &* 7
        if let c = fixes[tripId], c.at == gf.at, c.stamp == stamp { return c.fix }
        let prev: GPSFix? = RealPositionsStore.shared.previousFix(for: tripId)
        let f: RealFirst.Fix = t.realFix(gf, previous: prev, mine: mine, legs: t.legs)
        if fixes.count > 20 { fixes = [:] }
        fixes[tripId] = (gf.at, stamp, f)
        return f
    }
}

/// "vehicle shown · 305·9449 · gps ovapi 48 s · real +320 m · ghost +510 m": once a minute per trip while you wait for
/// it or ride it, whichever map draws it.
@MainActor
enum FusionLog {
    static let every: TimeInterval = 60
    private static var last: [String: Date] = [:]

    static func note(tripId: String, line: String, feed: String, _ s: RealFirst.Shown, estimated: Bool, now: Date) {
        if let l = last[tripId], now >= l, now.timeIntervalSince(l) < every { return }
        if last.count > 50 { last = [:] }
        last[tripId] = now
        let vehicle: String = "\(line)·\(tripId.suffix(4))"
        var shown: RealFirst.Shown = s
        if s.source == .byTimes || s.source == .none, let why = RealPositionsStore.shared.noGPSReason(for: tripId) {
            shown.why = why
        }
        FieldLog.shared.add(.match, RealFirst.logLine(vehicle: vehicle, feed: feed, shown, estimated: estimated))
    }
}
