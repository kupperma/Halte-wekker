import CoreLocation
import MapKit
import SwiftUI

/// The live buses and trains for the home map: asked for the visible box (`VehiclePick`'s gating: on screen, app
/// active, every 15 s at most, zoomed in, not in Low Power Mode, the setting on), drawn where their live times put them,
/// late ones without catching up (0.18.2), sliding along their road between answers.
@MainActor
final class LiveVehiclesModel: ObservableObject {
    @Published private(set) var segs: [VehicleSegment] = []
    private var lastAsk: Date?
    private var asking = false

    /// One bus or train on the map at a moment.
    struct Moving: Identifiable {
        let id: String
        let line: String
        let isTrain: Bool
        let mode: String
        let coordinate: CLLocationCoordinate2D
        let bearing: Double?
        let to: String
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
    func moving(at t: Date, in region: MKCoordinateRegion) -> [Moving] {
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
            if let b = v.bearing {
                Image(systemName: "location.north.fill").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(b))
            }
        }
        .foregroundStyle(DS.onAccent)
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 4)
        .background(DS.mode(train: v.isTrain, mode: v.mode), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1))      // (no shadow: up to 60 move every 2 s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(v.isTrain ? "Train" : "Bus") \(v.line)\(v.to.isEmpty ? "" : ", next stop \(Fmt.place(v.to))")")
    }
}
