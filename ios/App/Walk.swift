import MapKit
import SwiftUI

/// A stop to walk to: where it is, and (if you're catching something there) when that leaves.
struct WalkTarget: Identifiable, Hashable {
    var id: String { "\(name)|\(lat),\(lon)" }
    let name: String
    let lat: Double
    let lon: Double
    var rail = false
    var catchText: String? = nil        // "the 380 at 14:22"
    var leaves: Date? = nil             // when that one leaves, to say when to set off
    var spot: String? = nil             // (0.41) where at the stop: "Platform 4", "Stop U"
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

/// "Show the way" next to a stop, on the boards.
struct WalkButton: View {
    var title = "Show the way"
    var icon = "figure.walk"
    let go: () -> Void
    var body: some View {
        Button(action: go) {
            Label(title, systemImage: icon).font(BoardInk.sans(11)).foregroundStyle(Paper.navy)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Paper.navy.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(Paper.navy.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The walk to a stop, small: you, the stop and the way there, with how long it takes. Tap it for the big map.
struct WalkPreview: View {
    let target: WalkTarget
    let open: () -> Void
    @State private var route: MKRoute?
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera, interactionModes: []) {
            UserAnnotation()
            Marker(target.name, systemImage: target.rail ? "tram.fill" : "bus.fill", coordinate: target.coordinate)
                .tint(target.rail ? BoardInk.yellow : BoardInk.route)
            if let route {
                MapPolyline(route.polyline).stroke(Paper.navy, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Paper.ink.opacity(0.2), lineWidth: 1))
        .overlay(alignment: .bottomLeading) {
            if let route {
                Label("\(max(1, Int((route.expectedTravelTime / 60).rounded()))) min · \(Fmt.distance(route.distance))", systemImage: "figure.walk")
                    .font(BoardInk.sans(11)).foregroundStyle(BoardInk.navy)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Color.white, in: Capsule()).padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .bold)).foregroundStyle(BoardInk.navy)
                .frame(width: 26, height: 26).background(Color.white, in: Circle()).padding(8)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of the walk to \(target.name)")
        .accessibilityAddTraits(.isButton)
        .task(id: target.id) {
            // again every minute, as you walk
            while !Task.isCancelled {
                await find()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func find() async {
        let req = MKDirections.Request()
        req.source = MKMapItem.forCurrentLocation()
        let item = MKMapItem(placemark: MKPlacemark(coordinate: target.coordinate))
        item.name = target.name
        req.destination = item
        req.transportType = .walking
        guard let r = try? await MKDirections(request: req).calculate().routes.first else { return }
        let first = route == nil
        route = r
        if first {
            let rect = r.polyline.boundingMapRect
            camera = .rect(rect.insetBy(dx: -max(rect.width * 0.3, 250), dy: -max(rect.height * 0.4, 300)))
        }
    }
}
