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
                        MapPolyline(route.polyline).stroke(BoardInk.blueTop, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
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
            .background(LinearGradient(colors: [BoardInk.blueTop, BoardInk.blueBottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .navigationTitle("Walk to the stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await findRoute() }
        }
        .preferredColorScheme(.dark)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: target.rail ? "tram.fill" : "bus.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(BoardInk.navy)
                    .frame(width: 22, height: 22).background(target.rail ? BoardInk.yellow : BoardInk.route, in: Circle())
                Text(target.name).font(BoardInk.sans(17)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.8)
            }
            if let route {
                let mins = max(1, Int((route.expectedTravelTime / 60).rounded()))
                Text("\(mins) min walk · \(Fmt.distance(route.distance))").font(BoardInk.sans(15)).foregroundStyle(.white)
                if let c = target.catchText, let l = target.leaves {
                    let setOff = l.addingTimeInterval(-route.expectedTravelTime - 60)
                    let m = Int((setOff.timeIntervalSinceNow / 60).rounded())
                    Text(m <= 0 ? "Go now to catch \(c)." : "Leave by \(Fmt.hhmm(setOff)) (in \(m) min) to catch \(c).")
                        .font(BoardInk.sans(13)).foregroundStyle(m <= 0 ? BoardInk.late : BoardInk.green)
                }
                let steps = route.steps.filter { !$0.instructions.isEmpty }
                if !steps.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "arrow.turn.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.white.opacity(0.7))
                                    Text(s.instructions).font(BoardInk.sans(12, .regular)).foregroundStyle(.white)
                                    Spacer(minLength: 4)
                                    if s.distance > 0 { Text(Fmt.distance(s.distance)).font(BoardInk.sans(11, .regular)).foregroundStyle(Color.white.opacity(0.7)) }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                }
            } else if failed {
                Text("Couldn’t work out the walk from here. Apple Maps can show you the way.").font(BoardInk.sans(12, .regular)).foregroundStyle(Color.white.opacity(0.85))
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Finding the way…").font(BoardInk.sans(12, .regular)).foregroundStyle(Color.white.opacity(0.85)) }
            }
            Button(action: openInMaps) {
                Label("Walk there with Apple Maps", systemImage: "figure.walk").font(BoardInk.sans(14)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 11).background(Color(hex: 0x2F9E5B), in: RoundedRectangle(cornerRadius: 6))
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
