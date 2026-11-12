import MapKit
import SwiftUI

/// Every bus and train moving near you, live on a map, just to watch: each one with its line, sliding along its road
/// every second. Move the map and it fetches what's running there.
struct LiveAllSheet: View {
    let center: CLLocationCoordinate2D
    @Environment(\.dismiss) private var dismiss
    @State private var segs: [VehicleSegment] = []
    @State private var camera: MapCameraPosition
    @State private var region: MKCoordinateRegion
    @State private var picked: String?
    @State private var loading = true

    init(center: CLLocationCoordinate2D) {
        self.center = center
        let r = MKCoordinateRegion(center: center, latitudinalMeters: 6000, longitudinalMeters: 6000)
        _camera = State(initialValue: .region(r))
        _region = State(initialValue: r)
    }

    /// One bus or train on the map right now.
    private struct Moving: Identifiable {
        let id: String
        let line: String
        let isTrain: Bool
        let coordinate: CLLocationCoordinate2D
        let from: String
        let to: String
        let arrival: Date
    }

    /// Where each one is at `t`: the piece of its route it's on now (or, standing at a stop, the one it just finished).
    private func moving(_ t: Date) -> [Moving] {
        var out: [String: Moving] = [:]
        for s in segs.sorted(by: { $0.departure < $1.departure }) {
            guard out[s.tripId] == nil || (s.departure <= t && t <= s.arrival), let p = s.position(at: t) else { continue }
            out[s.tripId] = Moving(id: s.tripId, line: s.line, isTrain: s.isTrain, coordinate: p, from: s.fromName, to: s.toName, arrival: s.arrival)
        }
        return Array(out.values)
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let vs = moving(tl.date)
                ZStack(alignment: .bottom) {
                    Map(position: $camera) {
                        UserAnnotation()
                        ForEach(vs) { v in
                            Annotation("", coordinate: v.coordinate, anchor: .center) {
                                badge(v).onTapGesture { picked = v.id }
                            }
                        }
                    }
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .mapControls { MapUserLocationButton(); MapCompass() }
                    .onMapCameraChange(frequency: .onEnd) { ctx in region = ctx.region }
                    card(vs, tl.date)
                }
            }
            .navigationTitle("Everything moving near you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: regionKey) {
                // what's running where the map is, again every 30 seconds
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var regionKey: String {
        "\((region.center.latitude * 200).rounded())|\((region.center.longitude * 200).rounded())|\((region.span.latitudeDelta * 100).rounded())"
    }

    private func load() async {
        let c = region.center
        let la = min(max(region.span.latitudeDelta / 2, 0.01), 0.08), lo = min(max(region.span.longitudeDelta / 2, 0.015), 0.12)
        let s = await Transit.liveVehicles(min: .init(latitude: c.latitude - la, longitude: c.longitude - lo),
                                           max: .init(latitude: c.latitude + la, longitude: c.longitude + lo))
        if !s.isEmpty || segs.isEmpty { segs = s }
        loading = false
    }

    private func badge(_ v: Moving) -> some View {
        HStack(spacing: 3) {
            Image(systemName: v.isTrain ? "tram.fill" : "bus.fill").font(.system(size: 9, weight: .bold))
            Text(v.line).font(BoardInk.sans(11)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Paper.line(v.line, train: v.isTrain), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(picked == v.id ? Paper.ink : Color.white, lineWidth: picked == v.id ? 2.5 : 1.5))
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }

    private func card(_ vs: [Moving], _ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let p = picked, let v = vs.first(where: { $0.id == p }) {
                HStack(spacing: 8) {
                    LineBullet(line: v.line, train: v.isTrain, height: 24, minWidth: 38, font: 14)
                    Text(v.isTrain ? (v.line == "IC" ? "Intercity" : v.line == "SPR" ? "Sprinter" : "Train") : "Bus").font(BoardInk.sans(15)).foregroundStyle(Paper.ink)
                    Spacer()
                    Button { picked = nil } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Paper.ink) }.buttonStyle(.plain)
                }
                Text("\(Fmt.place(v.from)) → \(Fmt.place(v.to))").font(BoardInk.sans(13, .regular)).foregroundStyle(Paper.ink)
                Text("At \(Fmt.place(v.to)) \(Fmt.hhmm(v.arrival))").font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.8))
            } else {
                let buses = vs.filter { !$0.isTrain }.count, trains = vs.count - buses
                Text(loading ? "Finding everything that’s moving…" : "\(buses) bus\(buses == 1 ? "" : "es") and \(trains) train\(trains == 1 ? "" : "s") moving here")
                    .font(BoardInk.sans(14)).foregroundStyle(Paper.ink)
                Text("Live positions, worked out from their live times. Tap one to see where it’s going; move the map to look elsewhere.")
                    .font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperFill().opacity(0.97).clipShape(RoundedRectangle(cornerRadius: 10))).overlay(RoundedRectangle(cornerRadius: 10).stroke(Paper.edge, lineWidth: 1))
        .padding(10)
    }
}
