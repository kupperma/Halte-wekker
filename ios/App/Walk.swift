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
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

/// The way to a stop on foot: a map with you, the stop and the walking route, how far and how long, when to set off,
/// the turns, and Apple Maps for the whole walk with directions.
struct WalkMapSheet: View {
    let target: WalkTarget
    @Environment(\.dismiss) private var dismiss
    @State private var route: MKRoute?
    @State private var camera: MapCameraPosition = .automatic
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $camera) {
                    UserAnnotation()
                    Marker(target.name, systemImage: target.rail ? "tram.fill" : "bus.fill", coordinate: target.coordinate)
                        .tint(target.rail ? BoardInk.yellow : BoardInk.route)
                    if let route {
                        MapPolyline(route.polyline).stroke(Paper.navy, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .including([.publicTransport])))
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .frame(minHeight: 280)
                info
            }
            .background(PaperFill().ignoresSafeArea())
            .navigationTitle("Walk to the stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await findRoute() }
        }
        .preferredColorScheme(.light)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: target.rail ? "tram.fill" : "bus.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(BoardInk.navy)
                    .frame(width: 22, height: 22).background(target.rail ? BoardInk.yellow : BoardInk.route, in: Circle())
                Text(target.name).font(BoardInk.sans(17)).foregroundStyle(Paper.ink).lineLimit(2).minimumScaleFactor(0.8)
            }
            if let route {
                let mins = max(1, Int((route.expectedTravelTime / 60).rounded()))
                Text("\(mins) min walk · \(Fmt.distance(route.distance))").font(BoardInk.sans(15)).foregroundStyle(Paper.ink)
                if let c = target.catchText, let l = target.leaves {
                    let setOff = l.addingTimeInterval(-route.expectedTravelTime - 60)
                    let m = Int((setOff.timeIntervalSinceNow / 60).rounded())
                    Text(m <= 0 ? "Go now to catch \(c)." : "Leave by \(Fmt.hhmm(setOff)) (in \(m) min) to catch \(c).")
                        .font(BoardInk.sans(13)).foregroundStyle(m <= 0 ? Paper.late : Paper.ok)
                }
                let steps = route.steps.filter { !$0.instructions.isEmpty }
                if !steps.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "arrow.turn.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Paper.ink.opacity(0.7))
                                    Text(s.instructions).font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink)
                                    Spacer(minLength: 4)
                                    if s.distance > 0 { Text(Fmt.distance(s.distance)).font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.7)) }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                }
            } else if failed {
                Text("Couldn’t work out the walk from here. Apple Maps can show you the way.").font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.85))
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Finding the way…").font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.85)) }
            }
            Button(action: openInMaps) {
                Label("Walk there with Apple Maps", systemImage: "figure.walk").font(BoardInk.sans(14)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 11).background(Paper.green, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    private var destination: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: target.coordinate))
        item.name = target.name
        return item
    }

    private func findRoute() async {
        let req = MKDirections.Request()
        req.source = MKMapItem.forCurrentLocation()
        req.destination = destination
        req.transportType = .walking
        do {
            let r = try await MKDirections(request: req).calculate()
            guard let first = r.routes.first else { failed = true; return }
            route = first
            // show the whole walk, with a little room round it
            let rect = first.polyline.boundingMapRect
            withAnimation { camera = .rect(rect.insetBy(dx: -max(rect.width * 0.25, 300), dy: -max(rect.height * 0.35, 400))) }
        } catch {
            failed = true
        }
    }

    private func openInMaps() {
        destination.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

/// "Show the way" next to a stop, on the boards.
struct WalkButton: View {
    var title = "Show the way"
    var icon = "figure.walk"
    let go: () -> Void
    var body: some View {
        Button(action: go) {
            Label(title, systemImage: icon).font(BoardInk.sans(11)).foregroundStyle(BoardInk.navy)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Color.white, in: Capsule())
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
