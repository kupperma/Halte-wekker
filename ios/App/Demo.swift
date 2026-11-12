import MapKit
import SwiftUI

/// The demo: pretend buses for the Fastest trip screen, so you can try everything at home.
enum Demo {
    struct Bus {
        let line: String
        let stopName: String
        let stop: CLLocationCoordinate2D
        let departure: Date
        let planned: Date
    }
    /// The pretend buses, by trip id ("demo-306").
    static var buses: [String: Bus] = [:]
    private static var roads: [String: [CLLocationCoordinate2D]] = [:]

    static func isDemo(_ tripId: String) -> Bool { tripId.hasPrefix("demo-") }

    /// A pretend bus on real roads: it comes from about 1.4 km away to your stop, and on a bit past it.
    static func liveTrip(_ id: String) async -> LiveTrip? {
        guard let b = buses[id] else { return nil }
        let k = cos(b.stop.latitude * .pi / 180)
        let start = CLLocationCoordinate2D(latitude: b.stop.latitude - 900 / 110_540, longitude: b.stop.longitude - 1100 / (111_320 * k))
        let past = CLLocationCoordinate2D(latitude: b.stop.latitude + 500 / 110_540, longitude: b.stop.longitude + 700 / (111_320 * k))
        let key = "\(id)|\(b.stop.latitude),\(b.stop.longitude)"
        var path = roads[key] ?? []
        if path.isEmpty {
            let a = await road(start, b.stop), c = await road(b.stop, past)
            path = (a.isEmpty ? [start, b.stop] : a) + (c.isEmpty ? [past] : Array(c.dropFirst()))
            roads[key] = path
        }
        let stops = [
            LiveTrip.Stop(name: "Earlier stop", coordinate: start, arrival: b.departure.addingTimeInterval(-200), departure: b.departure.addingTimeInterval(-200), scheduled: nil),
            LiveTrip.Stop(name: b.stopName, coordinate: b.stop, arrival: b.departure.addingTimeInterval(-5), departure: b.departure, scheduled: b.planned),
            LiveTrip.Stop(name: "Next stop", coordinate: past, arrival: b.departure.addingTimeInterval(90), departure: b.departure.addingTimeInterval(90), scheduled: nil),
        ]
        return LiveTrip(line: b.line, headsign: "Den Bosch", live: true, stops: stops, path: path)
    }

    /// The road a car would take between two points (for the pretend bus).
    private static func road(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D] {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        req.transportType = .automobile
        guard let p = try? await MKDirections(request: req).calculate().routes.first?.polyline else { return [] }
        var cs = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: p.pointCount)
        p.getCoordinates(&cs, range: NSRange(location: 0, length: p.pointCount))
        return cs
    }
}

/// "Try it at home": what the demo shows, and the buttons to start it.
struct DemoSheet: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var near: NearMe
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("A pretend trip from the bus stop nearest to you. It takes about four minutes, and nothing real is watched. Allow notifications to see them too, and lock your phone now and then to see the lock screen.")
                        .font(BoardInk.sans(13, .regular)).foregroundStyle(Color.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 0) {
                        PlannerBar(title: "What you’ll see")
                        step(1, "map.fill", "Fastest trip, hands-free", "The big map that follows by itself: you, the dotted walk to your stop, and the bus coming to it.")
                        step(2, "bell.badge.fill", "It tells you", "Time to go, the bus running late, then something faster: it switches to that one by itself.")
                        step(3, "bus.fill", "It notices you’re on", "When the bus reaches your stop it sees you’re on board, and the trip starts by itself.")
                        step(4, "circle.dashed", "The ride", "The countdown ring with the bus riding round it, the stops, the speed, and the song you’re playing.")
                        step(5, "alarm.fill", "The alarm", "It rings 2 km before the stop and again at the stop. Hold to stop it.")
                        step(6, "checkmark.seal.fill", "You’re there", "And the end of the trip.")
                    }
                    .background(LinearGradient(colors: [BoardInk.blueTop, BoardInk.blueBottom], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button { go(full: true) } label: {
                        Label("Start the whole demo", systemImage: "play.fill").font(HWFont.display(15)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14).background(Color(hex: 0x2F9E5B), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    Button { go(full: false) } label: {
                        Label("Only the ride and the alarm", systemImage: "bus.fill").font(HWFont.display(15)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14).background(BoardInk.band, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    Text("Stop it any time with MAP at the top, or Hold to end trip. Skip the waiting on the Fastest trip screen with “I’m on it”.")
                        .font(BoardInk.sans(11, .regular)).foregroundStyle(Color.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .background(Color(hex: 0x0B1A44).ignoresSafeArea())
            .navigationTitle("Try it at home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { near.locate(force: true, ask: true) }
        }
        .preferredColorScheme(.dark)
    }

    private func step(_ n: Int, _ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(BoardInk.navy)
                .frame(width: 28, height: 28).background(BoardInk.yellow, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n). \(title)").font(BoardInk.sans(14)).foregroundStyle(.white)
                Text(text).font(BoardInk.sans(11.5, .regular)).foregroundStyle(Color.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1) }
    }

    private func go(full: Bool) {
        let here = near.position ?? trip.lastFix
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)        // the sheet closes first
            if full { withAnimation(.easeInOut(duration: 0.35)) { GoStore.shared.startDemo(near: here) } }
            else { trip.startDemo(from: here?.coordinate) }
        }
    }
}
