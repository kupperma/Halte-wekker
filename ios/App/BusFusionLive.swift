import CoreLocation
import Foundation

// The bus you wait for, by its GPS and its live times together (0.40.1, `BusFusion` has the rules): Fastest trip's map,
// the live sheet, and (`GPSPlacer.fused`) the home map. The on-board matcher keeps its own raw GPS (`VehicleMatch`,
// `ChooseGPS`, `PickRules`, `WrongBus`): none of this reaches it.

extension LiveTrip {
    /// Its stops as `BusFusion` takes them: metres along its road, and their times.
    var fusionStops: [BusFusion.Stop] {
        stops.indices.map { (i: Int) -> BusFusion.Stop in BusFusion.Stop(metres: metres(ofStop: i), times: stops[i].times) }
    }

    /// Its GPS fix on its road for `BusFusion` (not moved on), with the speed it was seen going; nil off its road.
    func fusionFix(_ f: GPSFix, previous: GPSFix?) -> BusFusion.Fix? {
        let l: [RealPositions.Leg] = legs
        guard let s = RealPositions.snap(f, on: l) else { return nil }
        let seen: Double? = RealPositions.observedSpeed(f, previous: previous, on: l)
        return BusFusion.Fix(metres: l[s.leg].start + s.along, at: f.at, speed: seen)
    }
}

/// Where to draw the bus you wait for: `BusFusion.fuse`, not past your stop before it has left there, gliding there
/// (`BusFusion.Glide`); a log line a minute. Not observed: read and written while drawing (as `GPSHold`).
final class BusFuser {
    struct Shown {
        let metres: Double?                         // where to draw it (nil: not at all)
        let waiting: Date?                          // standing at your stop: "Waiting · leaves 17:42"
        let hint: (from: Double, to: Double)?       // its GPS and its times far apart: the stretch between
        let estimate: BusFusion.Estimate
    }

    private var glides: [String: BusFusion.Glide] = [:]

    /// `mine`: your stop on its trip; `mineLeaves`: when it leaves there as the card says it; `timesAt`: when its live
    /// times were fetched.
    @MainActor
    func place(_ t: LiveTrip, tripId: String, line: String, isTrain: Bool, mine: Int?, mineLeaves: Date?, timesAt: Date?,
               now: Date) -> Shown {
        let stops: [BusFusion.Stop] = t.fusionStops
        let store: RealPositionsStore = RealPositionsStore.shared
        let gf: GPSFix? = store.fix(for: tripId, now: now)
        var fix: BusFusion.Fix? = nil
        if let gf { fix = t.fusionFix(gf, previous: store.previousFix(for: tripId)) }
        let m: Int? = mine.flatMap { stops.indices.contains($0) ? $0 : nil }
        let input = BusFusion.Input(stops: stops, fix: fix, live: t.live, timesAt: timesAt, mine: m, mineLeaves: mineLeaves, now: now)
        let e: BusFusion.Estimate = BusFusion.fuse(input)
        guard var target: Double = e.metres else {
            glides[tripId] = nil
            return Shown(metres: nil, waiting: nil, hint: nil, estimate: e)
        }
        if let m {
            let left: Bool = LiveTimes.hasLeft(t.stops[m].times, now: now)
            target = LiveTimes.shown(target, mine: stops[m].metres, left: left)
        }
        var g: BusFusion.Glide = glides[tripId] ?? BusFusion.Glide()
        let usedAt: Date? = fix == nil ? nil : gf?.at
        let age: TimeInterval? = gf.map { now.timeIntervalSince($0.at) }
        let speed: Double = BusFusion.plannedSpeed(stops, at: target)
        let drawn: Double = g.step(to: target, now: now, speed: speed, fixAt: usedAt, fixAge: age)
        glides[tripId] = g
        if m != nil { FusionLog.note(tripId: tripId, line: line, isTrain: isTrain, e, drawn: drawn, now: now) }
        return Shown(metres: drawn, waiting: e.waiting, hint: e.hint, estimate: e)
    }
}

/// "bus fused · 305·9449 · gps 48 s old +320 m · eta says +510 m · drawn +440 m": once a minute per trip while you wait,
/// whichever map draws it.
@MainActor
enum FusionLog {
    static let every: TimeInterval = 60
    private static var last: [String: Date] = [:]

    static func note(tripId: String, line: String, isTrain: Bool, _ e: BusFusion.Estimate, drawn: Double, now: Date) {
        if let l = last[tripId], now >= l, now.timeIntervalSince(l) < every { return }
        if last.count > 50 { last = [:] }
        last[tripId] = now
        let vehicle: String = "\(line)·\(tripId.suffix(4))"
        FieldLog.shared.add(.match, BusFusion.logLine(kind: isTrain ? "train" : "bus", vehicle: vehicle, e, drawn: drawn))
    }
}
