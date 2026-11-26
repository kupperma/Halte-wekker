import MapKit
import SwiftUI

// The walk to a stop and "Where to?" for Fastest trip in the new look (0.21). The same as `WalkMapSheet` and
// `DestinationSheet` (the old look keeps those), in the phone's light or dark.

/// The way to a stop on foot: a map with you, the stop and the walking route, how far and how long, when to set off,
/// the turns, and Apple Maps for the whole walk with directions.
struct WalkMapSheetNew: View {
    let target: WalkTarget
    @Environment(\.dismiss) private var dismiss
    @State private var route: MKRoute?
    @State private var camera: MapCameraPosition = .automatic
    @State private var failed = false
    @State private var guiding = false                  // (0.41) walking with arrows

    private var kindColor: Color { target.rail ? DS.train : DS.bus }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $camera) {
                    UserAnnotation()
                    Marker(target.name, systemImage: target.rail ? "tram.fill" : "bus.fill", coordinate: target.coordinate)
                        .tint(kindColor)
                    if let route {
                        MapPolyline(route.polyline).stroke(DS.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .including([.publicTransport])))
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .frame(minHeight: 280)
                // (scrolls at large text, under the map)
                ScrollView { info }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 380)
                    .background(DS.surface)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Walk to the stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await findRoute() }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .fullScreenCover(isPresented: $guiding) {
            WalkGuideView(target: target) { there in
                guiding = false
                // there: back to the Go to card, which says you're here
                if there { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dismiss() } }
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            HStack(spacing: DS.s8) {
                Image(systemName: target.rail ? "tram.fill" : "bus.fill").font(.footnote.weight(.bold)).foregroundStyle(DS.onAccent)
                    .frame(width: 28, height: 28).background(kindColor, in: Circle())
                    .accessibilityHidden(true)
                Text(target.name).font(DS.headline).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let route {
                let mins = max(1, Int((route.expectedTravelTime / 60).rounded()))
                Text("\(mins) min walk · \(Fmt.distance(route.distance))").font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                if let c = target.catchText, let l = target.leaves {
                    let setOff = l.addingTimeInterval(-route.expectedTravelTime - 60)
                    let m = Int((setOff.timeIntervalSinceNow / 60).rounded())
                    DSNote(icon: m <= 0 ? "figure.walk.motion" : "clock",
                           tint: m <= 0 ? DS.warning : DS.accentText,
                           text: m <= 0 ? "Go now to catch \(c)." : "Leave by \(Fmt.hhmm(setOff)) (in \(m) min) to catch \(c).")
                }
                let steps = route.steps.filter { !$0.instructions.isEmpty }
                if !steps.isEmpty {
                    VStack(alignment: .leading, spacing: DS.s8) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                            HStack(alignment: .firstTextBaseline, spacing: DS.s8) {
                                Image(systemName: "arrow.turn.up.right").font(.caption.weight(.bold)).foregroundStyle(DS.secondary)
                                    .accessibilityHidden(true)
                                Text(s.instructions).font(DS.sub).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                if s.distance > 0 {
                                    Text(Fmt.distance(s.distance)).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(DS.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                }
            } else if failed {
                Text("Couldn’t work out the walk from here. Apple Maps can show you the way.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: DS.s8) {
                    ProgressView()
                    Text("Finding the way…").font(DS.sub).foregroundStyle(DS.secondary)
                }
            }
            // (0.41) turn by turn here, or Apple Maps
            DSPrimaryButton(title: "Walk with arrows", icon: "arrow.turn.up.right") { guiding = true }
                .accessibilityHint("Turn by turn on the map, as you walk")
            DSQuietButton(title: "Walk there with Apple Maps", icon: "map", full: true, action: openInMaps)
        }
        .padding(DS.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Fastest trip › Change: where to, by name, or one you went to before.
struct DestinationSheetNew: View {
    @EnvironmentObject var live: LiveStore
    @Environment(\.dismiss) private var dismiss
    let picked: (Destination) -> Void
    @State private var q = ""
    @State private var hits: [Transit.StopHit] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                if q.trimmingCharacters(in: .whitespaces).count >= 2 {
                    if !hits.isEmpty {
                        Section("Stops and stations") {
                            ForEach(hits) { h in
                                row(icon: "mappin.and.ellipse", title: h.name, sub: h.town.isEmpty ? nil : h.town) {
                                    pick(Destination(id: h.id, name: h.name, lat: h.lat, lon: h.lon))
                                }
                            }
                        }
                    } else if searching {
                        HStack(spacing: DS.s8) { ProgressView(); Text("Searching…").foregroundStyle(DS.secondary) }
                    } else {
                        Text("No stops or stations found for “\(q)”").foregroundStyle(DS.secondary)
                    }
                }
                if !live.recents.isEmpty {
                    Section("Recent") {
                        ForEach(live.recents) { d in
                            row(icon: "clock.arrow.circlepath", title: d.name, sub: nil) { pick(d) }
                        }
                    }
                }
            }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "A stop, station or town")
            .textInputAutocapitalization(.words).autocorrectionDisabled()
            .navigationTitle("Where to?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: q) {
                let t = q.trimmingCharacters(in: .whitespaces)
                guard t.count >= 2 else { hits = []; searching = false; return }
                searching = true
                try? await Task.sleep(nanoseconds: 350_000_000)             // wait until you stop typing
                guard !Task.isCancelled else { return }
                let r = await Transit.findStops(t)
                guard !Task.isCancelled else { return }
                hits = r; searching = false
            }
        }
        .tint(DS.accentText)
    }

    private func pick(_ d: Destination) { picked(d); dismiss() }

    private func row(icon: String, title: String, sub: String?, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: DS.s12) {
                Image(systemName: icon).foregroundStyle(DS.accentText).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.bodyStrong).foregroundStyle(DS.text)
                    if let sub { Text(sub).font(DS.footnote).foregroundStyle(DS.secondary) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: DS.hit).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
