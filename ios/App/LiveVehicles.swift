import CoreLocation
import MapKit
import SwiftUI

/// The live buses and trains for the home map: asked for the visible box (`VehiclePick`'s gating: on screen, app
/// active, every 15 s at most, zoomed in, not in Low Power Mode, the setting on), drawn where their live times put them,
/// late ones without catching up (0.18.2), sliding along their road between answers; where their GPS says when the
/// open data has a fresh fix (0.20.2, `RealPositionsStore`).
@MainActor
final class LiveVehiclesModel: ObservableObject {
    @Published private(set) var segs: [VehicleSegment] = [] { didSet { gps.reset(segs) } }
    private let gps = GPSPlacer()               // real positions (0.20.2): where their GPS puts them
    private var lastAsk: Date?
    private var asking = false
    private let fuser = BusFuser()              // (0.40.3) the one you wait for, by its whole trip
    private var focusTrip: (id: String, trip: LiveTrip, at: Date)?

    /// (0.40.3) The trip you wait for, whole (its road before your stop too, which the map's pieces may not have): its
    /// live trip every 30 s while `tripId` is the one (nil: none). Run as a task while the map draws it.
    func follow(_ tripId: String?) async {
        guard let id = tripId else { focusTrip = nil; return }
        if focusTrip?.id != id { focusTrip = nil }
        while !Task.isCancelled {
            if let t = await Transit.liveTrip(id, maxAge: 25), !Task.isCancelled {
                let train: Bool = RealPositions.isRail(mode: t.mode)
                focusTrip = (id: id, trip: t.noCatchUp(asOf: Date(), isTrain: train), at: Date())
            }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    /// Your stop on the whole trip: the one nearest `stop` within 150 m (of several, the first still to come).
    private static func mine(_ t: LiveTrip, near stop: CLLocationCoordinate2D?, now: Date) -> Int? {
        guard let c = stop else { return nil }
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        let near: [Int] = t.stops.indices.filter { (i: Int) -> Bool in
            let p: CLLocationCoordinate2D = t.stops[i].coordinate
            return here.distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude)) < 150
        }
        let coming: Int? = near.first { (i: Int) -> Bool in (t.departure(i) ?? .distantFuture) > now.addingTimeInterval(-600) }
        return coming ?? near.first
    }

    /// The one you wait for drawn by its whole trip (`BusFuser`): nil when it isn't drawn (no live position).
    private func focusMoving(_ ft: (id: String, trip: LiveTrip, at: Date), stop: CLLocationCoordinate2D?, now: Date) -> Moving? {
        let t: LiveTrip = ft.trip
        let seg: VehicleSegment? = segs.first { $0.tripId == ft.id }
        let train: Bool = seg?.isTrain ?? RealPositions.isRail(mode: t.mode)
        let line: String = seg?.line ?? t.line
        let m: Int? = Self.mine(t, near: stop, now: now)
        let s: BusFuser.Shown = fuser.place(t, tripId: ft.id, line: line, isTrain: train, mine: m, mineLeaves: nil, timesAt: ft.at, now: now)
        guard s.drawn, let c = s.coordinate(on: t) else { return nil }
        var bearing: Double? = nil
        if let at = s.metres {
            let ahead: CLLocationCoordinate2D = t.coordinate(atMetres: at + 12)
            let p = CLLocation(latitude: c.latitude, longitude: c.longitude)
            if p.distance(from: CLLocation(latitude: ahead.latitude, longitude: ahead.longitude)) > 3 { bearing = Heading.bearing(c, ahead) }
        }
        let next: String = s.metres.map { t.stops[t.position(metres: $0).next].name } ?? (seg?.toName ?? "")
        var v = Moving(id: ft.id, line: line, isTrain: train, mode: seg?.mode ?? t.mode, coordinate: c, bearing: bearing, to: next,
                       gpsAt: s.source == .gps ? RealPositionsStore.shared.fix(for: ft.id, now: now)?.at : nil)
        v.tag = s.tag
        v.dim = s.dim
        v.ghost = s.ghost.map { t.coordinate(atMetres: $0) }
        return v
    }

    /// One bus or train on the map at a moment.
    struct Moving: Identifiable {
        let id: String
        let line: String
        let isTrain: Bool
        let mode: String
        let coordinate: CLLocationCoordinate2D
        let bearing: Double?
        let to: String
        var gpsAt: Date? = nil          // placed by its GPS fix of then (else by its times)
        var tag: String = ""            // (0.40.3) the one you wait for: "GPS 40 s", "by times"
        var dim: Bool = false           // …by its times only: fainter
        var ghost: CLLocationCoordinate2D? = nil    // …its estimate, faintly, when well ahead of it
    }

    static var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    static func gate(enabled: Bool, visible: Bool, active: Bool, region: MKCoordinateRegion?) -> VehiclePick.Gate {
        VehiclePick.Gate(enabled: enabled, visible: visible, active: active, lowPower: lowPower,
                         zoom: region.map { MapZoom.level(lonDelta: $0.span.longitudeDelta) } ?? 0)
    }

    /// Ask for what's running in the region, if the gating allows it now.
    func refresh(_ region: MKCoordinateRegion?, gate: VehiclePick.Gate) async {
        guard let r = region, !asking, VehiclePick.mayAsk(gate, last: lastAsk, now: Date()) else { return }
        asking = true
        defer { asking = false }
        lastAsk = Date()
        let b = VehiclePick.box(center: GeoPoint(lat: r.center.latitude, lon: r.center.longitude),
                                latDelta: r.span.latitudeDelta, lonDelta: r.span.longitudeDelta)
        let s = await Transit.liveVehicles(min: .init(latitude: b.minLat, longitude: b.minLon), max: .init(latitude: b.maxLat, longitude: b.maxLon))
        // (an empty answer, a bad moment on the connection, keeps what's drawn)
        if !s.isEmpty || segs.isEmpty { segs = Transit.noCatchUp(s, asOf: Date()) }
    }

    /// Turned off, or gone too far out: nothing drawn, and the next look asks again at once.
    func clear() { segs = []; lastAsk = nil }

    /// Where each one is at `t` (the piece of its route it's on, or the one it just finished), the nearest
    /// `VehiclePick.maxDrawn` to the middle of the region.
    /// `focus` (0.40.1): the one you wait for, and your stop: where its GPS and its live times together put it
    /// (`GPSPlacer.fused`), gliding there.
    func moving(at t: Date, in region: MKCoordinateRegion, focus: (tripId: String, stop: CLLocationCoordinate2D?)? = nil) -> [Moving] {
        var out: [String: Moving] = [:]
        for s in segs.sorted(by: { $0.departure < $1.departure }) {
            guard out[s.tripId] == nil || (s.departure <= t && t <= s.arrival), let p = s.position(at: t) else { continue }
            let ahead = s.position(at: t.addingTimeInterval(8))
            let bearing = ahead.flatMap { a -> Double? in
                let m = CLLocation(latitude: p.latitude, longitude: p.longitude).distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
                return m > 3 ? Heading.bearing(p, a) : nil
            }
            out[s.tripId] = Moving(id: s.tripId, line: s.line, isTrain: s.isTrain, mode: s.mode, coordinate: p, bearing: bearing, to: s.toName)
        }
        // where their GPS says, when there's a fresh fix on their road (0.20.2)
        for id in gps.trips where id != focus?.tripId {
            guard let g = gps.place(id, now: t) else { continue }
            let s = g.piece
            out[id] = Moving(id: id, line: s.line, isTrain: s.isTrain, mode: s.mode, coordinate: g.coordinate, bearing: g.bearing,
                             to: s.toName, gpsAt: g.fix.at)
        }
        if let f = focus {
            if let ft = focusTrip, ft.id == f.tripId {
                // (0.40.3) by its whole trip: where it really is, or not at all
                out[f.tripId] = focusMoving(ft, stop: f.stop, now: t)
            } else if let g = gps.fused(f.tripId, now: t, stop: f.stop) {
                let s: VehicleSegment = g.piece
                var v = Moving(id: f.tripId, line: s.line, isTrain: s.isTrain, mode: s.mode, coordinate: g.coordinate,
                               bearing: g.bearing, to: s.toName, gpsAt: g.fixAt)
                v.tag = g.tag
                v.dim = g.dim
                v.ghost = g.ghost
                out[f.tripId] = v
            }
        }
        let c = GeoPoint(lat: region.center.latitude, lon: region.center.longitude)
        let box = VehiclePick.Box(minLat: region.center.latitude - region.span.latitudeDelta * 0.6,
                                  minLon: region.center.longitude - region.span.longitudeDelta * 0.6,
                                  maxLat: region.center.latitude + region.span.latitudeDelta * 0.6,
                                  maxLon: region.center.longitude + region.span.longitudeDelta * 0.6)
        return VehiclePick.nearest(Array(out.values), point: { GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }, center: c, box: box)
    }
}

/// A moving bus or train: a pill with its line, and an arrow the way it's going.
struct VehiclePill: View {
    let v: LiveVehiclesModel.Moving
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: v.isTrain ? "tram.fill" : "bus.fill").font(.system(size: 10, weight: .bold))
            Text(v.line).font(.caption.weight(.bold)).monospacedDigit().lineLimit(1)
            if !v.tag.isEmpty {
                Text("· \(v.tag)").font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1)
            }
            if let b = v.bearing {
                Image(systemName: "location.north.fill").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(b))
            }
        }
        .foregroundStyle(DS.onAccent)
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 4)
        .background(DS.mode(train: v.isTrain, mode: v.mode, line: v.line), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1))      // (no shadow: up to 60 move every 2 s)
        .opacity(v.dim ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(v.isTrain ? "Train" : "Bus") \(v.line)\(v.to.isEmpty ? "" : ", next stop \(Fmt.place(v.to))")")
    }
}

/// A bus or train you tapped on the home map: its live sheet, and the trip of yours it starts when you could be on it.
struct VehicleTap: Identifiable {
    let target: LiveTrackTarget
    let trip: DoorTrip?
    /// Not the first ride of your trips, but it could be carrying you (0.26.2): "I'm on this one" plans from on board.
    var carrying = false
    var id: String { target.tripId }
}

/// A moving bus or train on the home map as a 44 pt button: tap for its live sheet. VoiceOver also offers "I'm on this
/// one" when it could be yours.
struct VehicleMark: View {
    let v: LiveVehiclesModel.Moving
    let tap: () -> Void
    var onIt: (() -> Void)? = nil
    var body: some View {
        Button(action: tap) {
            VehiclePill(v: v)
                .frame(minWidth: DS.hit, minHeight: DS.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(v.isTrain ? "Train" : "Bus") \(v.line)\(v.to.isEmpty ? "" : ", next stop \(Fmt.place(v.to))")")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows where it is and its next stops")
        .accessibilityActions {
            if let onIt { Button("I’m on this one", action: onIt) }
        }
    }
}

/// (0.40.3) Where the bus or train you wait for is expected (its GPS and its times together, `BusFusion`), when that's
/// well ahead of where it really is: a small hollow dot, faint, no label.
struct GhostDot: View {
    let color: Color
    var body: some View {
        Circle()
            .stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            .background(Circle().fill(color.opacity(0.15)))
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}
