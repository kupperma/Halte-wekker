import CoreLocation
import MapKit
import SwiftUI

// MARK: settings the map reads

/// Settings → Map → Style.
enum HomeMapStyle: String, CaseIterable, Identifiable {
    case standard, muted, satellite, hybrid
    static let key = "map.style"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Standard"
        case .muted: return "Muted"
        case .satellite: return "Satellite"
        case .hybrid: return "Hybrid"
        }
    }
    /// Only stations, stops and vehicles of our own: no shops or restaurants. Realistic elevation (0.20.1): zoomed out
    /// the map becomes the globe, as you'd expect from a maps app.
    var style: MapStyle {
        switch self {
        case .standard: return .standard(elevation: .realistic, pointsOfInterest: .excludingAll)
        case .muted: return .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll)
        case .satellite: return .imagery(elevation: .realistic)
        case .hybrid: return .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll)
        }
    }
}

/// Settings › Home style: the map with what leaves around you (concept C, the default), or your next trip first
/// (concept B, 0.19.1). Both are the same home over the same stores and refreshes; only the layout differs.
enum HomeStyle: String, CaseIterable, Identifiable {
    case live, nextTrip
    static let key = "ui.homeStyle"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "Live around you"
        case .nextTrip: return "Next trip first"
        }
    }
    static func of(_ raw: String) -> HomeStyle { HomeStyle(rawValue: raw) ?? .live }
}

/// Settings keys of the new look.
enum NewLook {
    static let key = "ui.newLook"            // on by default (0.19)
    static let vehiclesKey = "map.liveVehicles"

    /// Settings › Reset everything: the new look's settings too (your places, the map, the switch, days turned off).
    @MainActor static func resetAll() {
        let d = UserDefaults.standard
        for k in [key, vehiclesKey, HomeMapStyle.key, HomeStyle.key, PlanTripModel.recentsKey, PlacesLogic.storageKey] { d.removeObject(forKey: k) }
        PlacesStore.shared.reset()
        SchoolAlarm.shared.clearSkipped()
    }
}

// MARK: the stops on the map

/// The stations and stops for the part of the map you look at: `/v1/map/stops` per tile (`StopTiles`), on the
/// background lane, after the camera stops moving, at most every 20 s, and each tile kept for hours.
@MainActor
final class MapStopsModel: ObservableObject {
    /// One for the app: the tiles stay while Fastest trip or the ride has the screen.
    static let shared = MapStopsModel()
    @Published private(set) var stops: [String: Transit.NearStop] = [:]
    private var asked: [StopTile: Date] = [:]
    private var lastLook: Date?
    private var latest: MKCoordinateRegion?
    private var pending: Task<Void, Never>?
    private var running = false
    private var notBefore = Date.distantPast

    /// No look until then (the first seconds after the home appears belong to the live times).
    func hold(until t: Date) { notBefore = max(notBefore, t) }

    /// The camera stopped here: look now, or as soon as the 20 s are up (with wherever the camera is by then).
    func cameraStopped(_ r: MKCoordinateRegion, visible: Bool) {
        latest = r
        guard visible else { return }
        let now = Date()
        let zoom = MapZoom.level(lonDelta: r.span.longitudeDelta)
        guard zoom >= StopTiles.minZoom else { return }
        if now >= notBefore, StopTiles.mayLook(zoom: zoom, visible: visible, last: lastLook, now: now) {
            Task { await look() }
        } else if pending == nil {
            let interval = lastLook.map { StopTiles.minInterval - now.timeIntervalSince($0) } ?? 0
            let wait = max(1, interval, notBefore.timeIntervalSince(now))
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.pending = nil
                await self.look()
            }
        }
    }

    /// The screen went away: no look waits for it.
    func pause() { pending?.cancel(); pending = nil }

    private func look() async {
        guard !running, let r = latest, MapZoom.level(lonDelta: r.span.longitudeDelta) >= StopTiles.minZoom else { return }
        running = true
        defer { running = false }
        let first = lastLook == nil                     // (the first look of a launch: the two nearest tiles only)
        lastLook = Date()
        let c = r.center, la = r.span.latitudeDelta / 2, lo = r.span.longitudeDelta / 2
        let tiles = StopTiles.due(StopTiles.covering(minLat: c.latitude - la, minLon: c.longitude - lo, maxLat: c.latitude + la, maxLon: c.longitude + lo,
                                                     limit: first ? 2 : 6),
                                  asked: asked, now: Date())
        if stops.count > 4000 { stops = [:]; asked = [:] }      // (a long day of panning: start again)
        for t in tiles {
            if Task.isCancelled { return }
            let mid = StopTiles.center(t)
            // (the background lane: nobody waits for a stop's dot)
            guard let got = await Transit.nearStopsAnswer(CLLocationCoordinate2D(latitude: mid.lat, longitude: mid.lon)) else { continue }
            asked[t] = Date()
            for s in got where stops[s.id] == nil { stops[s.id] = s }
        }
    }

    /// The stops to draw in a region, and whether with their names.
    func drawn(in r: MKCoordinateRegion) -> (stops: [Transit.NearStop], names: Bool) {
        let c = r.center, la = r.span.latitudeDelta * 0.6, lo = r.span.longitudeDelta * 0.6
        let inView = stops.values.filter { abs($0.lat - c.latitude) <= la && abs($0.lon - c.longitude) <= lo }
        let pick = MapStopsDraw.pick(inView, id: \.id, point: { GeoPoint(lat: $0.lat, lon: $0.lon) }, rail: \.rail,
                                     center: GeoPoint(lat: c.latitude, lon: c.longitude), zoom: MapZoom.level(lonDelta: r.span.longitudeDelta))
        return (pick.ids.compactMap { stops[$0] }, pick.names)
    }
}

/// A station (a rounded square with a train) or a bus stop (a small dot), with its name when zoomed in. A 44 pt button:
/// tap for its departures; VoiceOver also offers waking you there and planning to it.
struct MapStopMark: View {
    let stop: Transit.NearStop
    let names: Bool
    var tap: () -> Void = {}
    var wake: (() -> Void)? = nil
    var planTo: (() -> Void)? = nil
    var body: some View {
        Group {
            if stop.rail {
                Button(action: tap) {
                    VStack(spacing: -2) {
                        Image(systemName: "tram.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.onAccent)
                            .frame(width: 34, height: 34)
                            .background(DS.train, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                            .frame(width: DS.hit, height: DS.hit)
                        label(Fmt.place(stop.name), strong: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(DSPressStyle())
                .modifier(a11y)
            } else {
                // (the name's mirror on the left, hidden, so the dot is the middle: the mark is centred on the stop)
                HStack(spacing: -16) {
                    if names { label(Fmt.stop(stop.name), strong: false).hidden().accessibilityHidden(true) }
                    Button(action: tap) {
                        HStack(spacing: -16) {
                            Circle().fill(DS.bus).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(DS.surface, lineWidth: 2))
                                .frame(width: DS.hit, height: DS.hit)
                            if names { label(Fmt.stop(stop.name), strong: false) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DSPressStyle())
                    .modifier(a11y)
                }
            }
        }
    }
    private var a11y: StopMarkA11y {
        StopMarkA11y(label: stop.rail ? "Station \(Fmt.place(stop.name))" : "Bus stop \(Fmt.stop(stop.name))", wake: wake, planTo: planTo)
    }
    private func label(_ t: String, strong: Bool) -> some View {
        Text(t).font(strong ? DS.caption : .caption2.weight(.semibold)).foregroundStyle(DS.text).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(DS.surface.opacity(0.88), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A stop's mark for VoiceOver: its name, what a double-tap does, and the other actions.
private struct StopMarkA11y: ViewModifier {
    let label: String
    let wake: (() -> Void)?
    let planTo: (() -> Void)?
    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows its departures")
            .accessibilityActions {
                if let wake { Button("Wake me at this stop", action: wake) }
                if let planTo { Button("Plan a trip to here", action: planTo) }
            }
    }
}

// MARK: the new home

/// The new home (0.19, "New look"): the map with stations, stops and live vehicles; search and your places on top; the
/// weather and follow-me on the right; the departures around you at the bottom, pulled up into Your day.
struct NewHome: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var live: LiveStore
    @EnvironmentObject var planner: Planner
    @EnvironmentObject var near: NearMe
    @EnvironmentObject var goStore: GoStore
    @Environment(\.scenePhase) private var scene
    @ObservedObject private var places = PlacesStore.shared
    @ObservedObject private var outfit = OutfitStore.shared
    @ObservedObject private var mapStops = MapStopsModel.shared
    @StateObject private var vehicles = LiveVehiclesModel()
    @AppStorage(NewLook.vehiclesKey) private var showVehicles = true
    @AppStorage(HomeMapStyle.key) private var styleRaw = HomeMapStyle.standard.rawValue
    @AppStorage(HomeStyle.key) private var homeStyleRaw = HomeStyle.live.rawValue

    @State private var camera: MapCameraPosition
    @State private var region: MKCoordinateRegion?
    @State private var shown = false                       // on screen (not covered by Fastest trip or the ride)
    @State private var sheet: HomeSheet?
    @ObservedObject private var nearDeps = NearDeparturesModel.shared
    @ObservedObject private var school = SchoolAlarm.shared
    @ObservedObject private var friends = FriendStore.shared
    @EnvironmentObject var stopsStore: StopsStore
    @State private var focusedCard: String?
    @State private var tapped: DepartureTap?
    @State private var dayOpen = false
    @StateObject private var plan = PlanTripModel()
    @State private var planOpen = false
    @State private var planFromSearch = false
    @State private var warmedUp = false                    // the first seconds after appearing: no vehicles yet
    @State private var idsChangedAt = Date.distantPast     // when the cards last changed (not a swipe: the map stays)
    @State private var weekOpen = false                    // Next trip first: Your week over the map
    // follow me (0.20.1): our own state, not MapKit's; kept while the home is away (Fastest trip, the ride)
    @State private var following: Bool
    @State private var followSince = Date()
    @State private var followSpan: Double?                 // the zoom following settled at (a pinch changes it)
    @State private var followLocked = false                // the map has been on you since following began
    @State private var lastCamera: MapCamera?
    @State private var planReturn: PlanReturn?             // where the map was before Plan fitted a route
    // tapping the map (0.20.1)
    @State private var stopTap: Transit.NearStop?
    @State private var vehicleTap: VehicleTap?
    @State private var wakeAt: WakeTarget?
    @MainActor private static var keptFollowing = true
    @MainActor private static var keptCamera: MapCamera?
    /// The phone's newest fix (MapKit's own, while it follows you).
    @MainActor private static let locator = CLLocationManager()

    private struct PlanReturn { let following: Bool; let camera: MapCamera? }

    enum HomeSheet: String, Identifiable {
        case settings, weather, addPlace, demo
        var id: String { rawValue }
    }

    /// Where the map starts before your location is known: where the phone last was, or home.
    private static let startRegion = MKCoordinateRegion(center: CLLocationManager().location?.coordinate ?? Place.home.coordinate,
                                                        latitudinalMeters: 1400, longitudinalMeters: 1400)
    init() {
        // back from Fastest trip or the ride: the map as you left it (following you, or where you had moved it)
        if !Self.keptFollowing, let c = Self.keptCamera {
            _camera = State(initialValue: .camera(c))
            _following = State(initialValue: false)
        } else {
            _camera = State(initialValue: .userLocation(followsHeading: false, fallback: .region(Self.startRegion)))
            _following = State(initialValue: true)
        }
    }

    /// The map is on screen: not under Your day, Fastest trip or the ride, and the app in front.
    private var visible: Bool {
        shown && !dayOpen && !planOpen && !weekOpen && sheet == nil && tapped == nil && stopTap == nil && vehicleTap == nil && wakeAt == nil
            && scene == .active && !goStore.isOpen && !friends.showing
    }
    /// Settings › Home style: Next trip first (concept B) instead of Live around you (concept C).
    private var nextFirst: Bool { HomeStyle.of(homeStyleRaw) == .nextTrip }
    private var mapStyle: HomeMapStyle { HomeMapStyle(rawValue: styleRaw) ?? .standard }

    var body: some View {
        ZStack(alignment: .top) {
            map.ignoresSafeArea()
                .accessibilityHidden(weekOpen)
            if planOpen {
                PlanTripOverlay(model: plan, pickOnOpen: planFromSearch, legBars: nextFirst, close: closePlan)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .transition(.opacity)
            } else if nextFirst {
                // (capped where its big card and the bar still fit on the screen together)
                nextTripLayout
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .transition(.opacity)
            } else if weekOpen {
                // Live around you: the same Your week as Next trip first, over the map (0.20.1)
                DaySheet(close: { closeWeek() }, week: true)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        searchRow
                        chipsRow
                        HStack { Spacer(); rightColumn }
                    }
                    .padding(.horizontal, DS.edge)
                    .padding(.top, 6)
                    Spacer(minLength: 0)
                    bottomCards
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .transition(.opacity)
            }
            if let t = trip.toast { toast(t) }
        }
        .sheet(isPresented: $dayOpen) {
            DaySheet(close: { dayOpen = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .modifier(HomeLoops())
        // the lists per leg only while they're shown: here your home board under the map (0.20.7)
        .onAppear { live.panelsNeed = panelsShown }
        .onChange(of: panelsShown) { _, n in live.panelsNeed = n }
        // the departures near you, when neither the live store nor your home board has them
        // (Next trip first shows no departure cards: nothing is asked for them)
        .task(id: ownDepartures && visible && !nextFirst) {
            guard ownDepartures && !nextFirst else { return }
            while !Task.isCancelled && visible {
                await nearDeps.refresh(at: near.position)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .onChange(of: focusedCard) { old, new in
            // only a swipe moves the map: not the cards changing under your finger (new answers, the nudge coming)
            let ids = cardIds
            guard Date().timeIntervalSince(idsChangedAt) > 0.6, let new, let from = old ?? ids.first, from != new,
                  ids.contains(new), ids.contains(from) else { return }
            moveTo(card: new)
        }
        .onChange(of: cardIds) { _, _ in idsChangedAt = Date() }
        .onChange(of: live.updated) { _, u in if u != nil { warmedUp = true } }
        .onChange(of: plan.focused) { _, _ in if planOpen { fitRoute() } }
        .onChange(of: goStore.isOpen) { _, open in if open { planOpen = false; dayOpen = false; weekOpen = false } }
        // (0.27) "Take this trip" from a friend: Plan, filled in
        .onChange(of: friends.planRequest) { _, r in
            guard let r else { return }
            friends.planRequest = nil
            var when: PlanCompare.When = .now
            if let by = r.arriveBy, by > Date().addingTimeInterval(10 * 60) { when = .arrive(by) }
            openPlan(to: .place(r.to, name: r.name), when: when)
        }
        .onChange(of: homeStyleRaw) { _, _ in weekOpen = false; dayOpen = false }
        .sheet(item: $tapped) { DepartureDetailSheet(tap: $0).presentationDetents([.medium, .large]) }
        .sheet(item: $stopTap) { s in
            MapStopSheet(stop: s) { from in planFrom(stop: s, from: from) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $vehicleTap) { v in
            LiveBusSheet(target: v.target, newLook: true, onIt: onIt(v))
                .presentationDetents([.large])
        }
        .sheet(item: $wakeAt) { WakeAtStopNew(preset: $0) }
        .onChange(of: camera) { _, c in
            // MapKit says a hand moved it
            if following && c.positionedByUser { setFollowing(false) }
        }
        // the live vehicles: every 15 s while the home is on screen, the app in front and the setting on
        .task(id: showVehicles && visible && warmedUp) {
            guard showVehicles else { vehicles.clear(); return }
            while !Task.isCancelled && visible && warmedUp {
                await vehicles.refresh(region, gate: vehicleGate)
                try? await Task.sleep(nanoseconds: UInt64(VehiclePick.interval * 1_000_000_000))
            }
        }
        .onAppear {
            shown = true
            mapStops.hold(until: Date().addingTimeInterval(3))
            if live.updated != nil { warmedUp = true }
        }
        .task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            warmedUp = true
        }
        .onDisappear { shown = false; mapStops.pause() }
        .onChange(of: scene) { _, s in if s != .active { mapStops.pause() } else if let r = region { mapStops.cameraStopped(r, visible: visible) } }
        .sheet(item: $sheet) { s in
            switch s {
            case .settings:
                // (0.32.1: topics with a search; the old look keeps `SettingsView`)
                SettingsHub(tryDemo: {
                    Task { @MainActor in try? await Task.sleep(nanoseconds: 500_000_000); sheet = .demo }
                }).presentationDetents([.large])
            case .demo: DemoSheetNew().presentationDetents([.large])
            case .weather: OutfitSheetNew().presentationDetents([.medium, .large])
            case .addPlace: PlaceSearchSheet(title: "Add a place") { hit in places.add(name: Fmt.place(hit.name), lat: hit.lat, lon: hit.lon, stopIds: [hit.id]) }
            }
        }
        .animation(DS.quick, value: trip.toast)
    }

    // MARK: map

    private var map: some View {
        let drawn: (stops: [Transit.NearStop], names: Bool) = region.map { mapStops.drawn(in: $0) } ?? (stops: [], names: false)
        let showV = VehiclePick.shows(vehicleGate) && region != nil && !planOpen
        let route = planOpen ? plan.route(plan.focused) : []
        // (the vehicles slide along their road every 2 s while there are any; else the map is redrawn only when it changes)
        return TimelineView(.periodic(from: .now, by: showV && !vehicles.segs.isEmpty ? 2 : 3600)) { tl in
            let moving: [LiveVehiclesModel.Moving] = showV ? region.map { vehicles.moving(at: tl.date, in: $0) } ?? [] : []
            Map(position: $camera) {
                UserAnnotation()
                ForEach(drawn.stops) { s in
                    Annotation(Fmt.place(s.name), coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon), anchor: s.rail ? .top : .center) {
                        MapStopMark(stop: s, names: drawn.names, tap: { tapStop(s) },
                                    wake: trip.phase == .idle ? { tapStop(s, wake: true) } : nil,
                                    planTo: { planFrom(stop: s, from: false) })
                    }
                    .annotationTitles(.hidden)
                }
                if route.count > 1 {
                    MapPolyline(coordinates: route)
                        .stroke(DS.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                ForEach(moving) { v in
                    Annotation(v.line, coordinate: shownAt(v), anchor: .center) {
                        VehicleMark(v: v, tap: { tapVehicle(v) }, onIt: markOnIt(v))
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(mapStyle.style)
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .onEnd) { ctx in cameraEnded(ctx) }
        }
        // their GPS positions while they're drawn (0.20.2)
        .realPositions(showV)
    }

    /// May the live vehicles be asked for and drawn now (`VehiclePick`).
    private var vehicleGate: VehiclePick.Gate {
        LiveVehiclesModel.gate(enabled: showVehicles, visible: visible && warmedUp, active: scene == .active, region: region)
    }

    // MARK: top

    private var searchRow: some View {
        HStack(spacing: 0) {
            Button { openSearch() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.body.weight(.semibold)).foregroundStyle(DS.secondary)
                    Text("Search anywhere").font(DS.body).foregroundStyle(DS.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search anywhere")
            .accessibilityHint("Plan a trip")
            Button { sheet = .settings } label: {
                Image(systemName: "gearshape").font(.body.weight(.semibold)).foregroundStyle(DS.secondary)
                    .frame(width: 48, height: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
        .dsFloat()
    }

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // a place you picked that isn't one of yours (searched in Plan): first, as where you're going
                if let c = live.custom, !places.chips.contains(where: { isCustom($0) }) { pickedChip(c) }
                ForEach(places.chips) { p in
                    let mins = chipMinutes(p)
                    let lead = mins != nil
                    Button { openPlan(to: p) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: p.symbol).font(.subheadline.weight(.semibold))
                                .foregroundStyle(lead ? DS.onAccent : DS.accentText)
                            Text(PlacesLogic.chipLabel(p.name, minutes: mins)).font(DS.subStrong).monospacedDigit()
                                .foregroundStyle(lead ? DS.onAccent : DS.text).lineLimit(1)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 40)
                        .background(lead ? DS.accent : DS.surface, in: Capsule())
                        .dsFloat()
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DSPressStyle())
                    .accessibilityLabel(mins.map { "\(p.name), \($0) minutes from here" } ?? p.name)
                    .accessibilityHint("Plan a trip there")
                }
                Button { sheet = .addPlace } label: {
                    Image(systemName: "plus").font(.subheadline.weight(.bold)).foregroundStyle(DS.secondary)
                        .frame(width: 44, height: 44)
                        .background(DS.surface, in: Circle())
                        .dsFloat()
                }
                .buttonStyle(DSPressStyle())
                .accessibilityLabel("Add a place")
            }
            .padding(.vertical, 6).padding(.horizontal, 2)
        }
        // only as tall as the chips: a sideways ScrollView otherwise takes the free height and swallows map drags
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, -2)
        .padding(.vertical, -6)
    }

    /// The travel time now, for the place you're going to (today's trips there; nothing is asked for the chips).
    private func chipMinutes(_ p: SavedPlace) -> Int? {
        guard places.place(p).key == live.destination(trip.direction).key || isCustom(p) else { return nil }
        return destMinutes
    }
    private var destMinutes: Int? {
        guard live.nextAsOf == nil, !live.onTheMove else { return nil }
        return PlacesLogic.minutesNow(arrival: live.next.first?.end, now: Date())
    }
    /// One of your places is where you picked to go (`LiveStore.custom`).
    private func isCustom(_ p: SavedPlace) -> Bool {
        guard let c = live.custom else { return false }
        return abs(c.lat - p.lat) < 1e-6 && abs(c.lon - p.lon) < 1e-6
    }

    /// Where you picked to go (0.20.2: a place searched in Plan), as the lead chip with its travel time: tap for Plan.
    private func pickedChip(_ c: Destination) -> some View {
        let mins = destMinutes
        return Button { openPlan(to: .place(c.place), when: .now) } label: {
            HStack(spacing: 6) {
                Image(systemName: "mappin").font(.subheadline.weight(.semibold)).foregroundStyle(DS.onAccent)
                Text(PlacesLogic.chipLabel(c.short, minutes: mins)).font(DS.subStrong).monospacedDigit()
                    .foregroundStyle(DS.onAccent).lineLimit(1)
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(DS.accent, in: Capsule())
            .dsFloat()
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(mins.map { "Where you’re going: \(c.short), \($0) minutes from here" } ?? "Where you’re going: \(c.short)")
        .accessibilityHint("Plan a trip there")
    }

    private var rightColumn: some View {
        VStack(alignment: .trailing, spacing: 8) {
            weatherChip()
            followButton
            weekButton
            friendsButton
        }
    }

    /// Friends (0.25): the list, requests and adding someone; a badge with the requests waiting.
    private var friendsButton: some View {
        Button { friends.showing = true } label: {
            Image(systemName: friends.badge > 0 ? "person.2.fill" : "person.2")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(friends.badge > 0 ? DS.accentText : DS.secondary)
                .frame(width: DS.hit, height: DS.hit)
                .background(DS.surface, in: Circle())
                .overlay(alignment: .topTrailing) { if friends.badge > 0 { FriendsBadge(count: friends.badge).offset(x: 4, y: -4) } }
                .dsFloat()
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(friends.badge > 0 ? "Friends, \(friends.badge) new" : "Friends")
    }

    /// `inline`: inside the search field (Next trip first), without its own shadow.
    private func weatherChip(inline: Bool = false) -> some View {
        Button { sheet = .weather } label: {
            HStack(spacing: 4) {
                if let s = outfit.plan?.start {
                    Image(systemName: s.w.symbol).symbolRenderingMode(.multicolor).font(.subheadline)
                    Text("\(Int(s.w.temp.rounded()))°").font(DS.subStrong).monospacedDigit().foregroundStyle(DS.text)
                } else {
                    Image(systemName: "cloud.sun").font(.subheadline).foregroundStyle(DS.secondary)
                    if outfit.loading { ProgressView().controlSize(.mini) }
                }
            }
            .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 36)
            .background(inline ? DS.surface3 : DS.surface.opacity(0.96), in: Capsule())
            .shadow(color: .black.opacity(inline ? 0 : 0.14), radius: 8, y: 2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(outfit.plan?.start.map { "Weather: \(Int($0.w.temp.rounded())) degrees. What to wear" } ?? "Weather and what to wear")
    }

    /// Follow me: on, the map keeps you in the middle; tapped again (or the map moved by hand), it stays where it is.
    private var followButton: some View {
        let on = following && !trip.locationDenied
        return Button {
            if on {
                setFollowing(false)
                if let c = lastCamera { camera = .camera(c) }       // (stays where it is, no longer tracking you)
            } else {
                setFollowing(true)
                withAnimation(DS.move) { camera = .userLocation(followsHeading: false, fallback: camera) }
            }
        } label: {
            Image(systemName: on ? "location.fill" : "location")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(on ? DS.accentText : DS.secondary)
                .frame(width: 48, height: 48)
                .background(DS.surface, in: Circle())
                .dsFloat()
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(on ? "Following your location" : "Follow my location")
        .accessibilityHint(on ? "Tap to stop following, so you can move the map" : "Tap to keep the map on you")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Your week (the school calendar), as Next trip first's bar opens it.
    private var weekButton: some View {
        Button { withAnimation(DS.quick) { weekOpen = true } } label: {
            Image(systemName: "calendar")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.secondary)
                .frame(width: DS.hit, height: DS.hit)
                .background(DS.surface, in: Circle())
                .dsFloat()
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel("Your week")
        .accessibilityHint("Your classes, alarms and school dates for the next seven days")
    }

    // MARK: follow me, a free map, and taps

    private func setFollowing(_ on: Bool) {
        following = on
        Self.keptFollowing = on
        if on { followSince = Date(); followSpan = nil; followLocked = false }
    }

    /// The camera stopped: remember it; while following, a move by hand makes the map free (MapKit doesn't always say
    /// so through the camera); the stops and vehicles look at it if it's a usable box (their zoom gating does the rest).
    private func cameraEnded(_ ctx: MapCameraUpdateContext) {
        let r = ctx.region
        lastCamera = ctx.camera
        Self.keptCamera = ctx.camera
        if following {
            let settling = Date().timeIntervalSince(followSince) < MapFollow.settle
            let mid = CLLocation(latitude: r.center.latitude, longitude: r.center.longitude)
            // (your newest fix, fresh: less how far you could have gone since and its accuracy, so a fix a little behind
            // you on a bus never looks like a pan)
            let fixes = [near.position, trip.lastFix, Self.locator.location].compactMap { $0 }
            let you = fixes.max(by: { $0.timestamp < $1.timestamp }).flatMap { p -> Double? in
                let age = Date().timeIntervalSince(p.timestamp)
                guard age < 30, p.horizontalAccuracy >= 0, p.horizontalAccuracy < 150 else { return nil }
                return max(0, p.distance(from: mid) - max(0, p.speed) * max(0, age) - p.horizontalAccuracy)
            }
            let view = r.span.latitudeDelta * 111_000
            // (a zoom is judged only once the map has been on you: not MapKit's own first fly to where you are)
            if MapFollow.handMoved(following: true, settling: settling, centreToUser: you, viewMetres: view,
                                   span: r.span.latitudeDelta, baseline: followLocked ? followSpan : nil) {
                setFollowing(false)
                camera = .camera(ctx.camera)
            } else if let d = you, d <= max(80, view * 0.2) {
                followSpan = r.span.latitudeDelta
                if !settling { followLocked = true }
            }
        }
        guard MapTap.usable(centerLat: r.center.latitude, centerLon: r.center.longitude,
                            latDelta: r.span.latitudeDelta, lonDelta: r.span.longitudeDelta) else { region = nil; return }
        region = r
        mapStops.cameraStopped(r, visible: visible)
        Task { await vehicles.refresh(r, gate: vehicleGate) }
    }

    /// Centre the map on something you tapped (above the sheet that opens): following stops.
    private func centre(on c: CLLocationCoordinate2D) {
        setFollowing(false)
        let span = MapTap.span(current: region?.span.latitudeDelta)
        let ratio = region.map { min(3, max(0.3, $0.span.longitudeDelta / max(1e-9, $0.span.latitudeDelta))) } ?? 1
        let m = MapTap.centre(item: GeoPoint(lat: c.latitude, lon: c.longitude), latDelta: span)
        withAnimation(DS.move) {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: m.lat, longitude: m.lon),
                                                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span * ratio)))
        }
    }

    /// A stop or station tapped: its departures (or, from VoiceOver's action, Wake me there).
    private func tapStop(_ s: Transit.NearStop, wake: Bool = false) {
        centre(on: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon))
        if wake { wakeAt = WakeTarget(place: MapStopSheet.place(s), rail: s.rail) } else { stopTap = s }
    }

    /// A bus or train tapped: its live sheet, with "I'm on this one" when it could be yours.
    private func tapVehicle(_ v: LiveVehiclesModel.Moving) {
        centre(on: v.coordinate)
        let t = couldBeOn(v)
        vehicleTap = VehicleTap(target: LiveTrackTarget(tripId: v.id, line: v.line, headsign: "", stopName: "", time: Date(), rail: v.isTrain),
                                trip: t, carrying: t == nil && couldBeCarrying(v))
    }

    /// The trip of yours this bus or train starts, if you could be on it (`MapTap.couldBeOn`).
    /// The bus or train you're on is drawn where you are (0.20.5): your GPS, not where the open data or its times put
    /// it (those lag between stops). Only with a fresh fix, and not when they're kilometres apart.
    private func shownAt(_ v: LiveVehiclesModel.Moving) -> CLLocationCoordinate2D {
        let riding = trip.phase != .idle && trip.vehicle?.tripId == v.id
        guard riding || live.onBoard?.vehicle.tripId == v.id,
              let p = riding ? (trip.lastFix ?? near.position) : (near.position ?? trip.lastFix),
              Date().timeIntervalSince(p.timestamp) < 60, p.horizontalAccuracy >= 0, p.horizontalAccuracy <= 100,
              p.distance(from: CLLocation(latitude: v.coordinate.latitude, longitude: v.coordinate.longitude)) < 3000
        else { return v.coordinate }
        return p.coordinate
    }

    private func couldBeOn(_ v: LiveVehiclesModel.Moving) -> DoorTrip? {
        let m = near.position.map { $0.distance(from: CLLocation(latitude: v.coordinate.latitude, longitude: v.coordinate.longitude)) }
        let i = MapTap.couldBeOn(vehicleTrip: v.id, firstRides: live.next.map(\.first.tripId), fresh: live.nextAsOf == nil && !live.onTheMove,
                                 idle: trip.phase == .idle, metresFromYou: m)
        return i.flatMap { live.next[safe: $0] }
    }

    /// Not the first ride of your trips, but it could be carrying you (`MapTap.couldBeCarrying`, 0.26.2): "I'm on this
    /// one" starts the trip from on board.
    private func couldBeCarrying(_ v: LiveVehiclesModel.Moving) -> Bool {
        let p: CLLocation? = near.position ?? trip.lastFix
        let m: Double? = p.map { $0.distance(from: CLLocation(latitude: v.coordinate.latitude, longitude: v.coordinate.longitude)) }
        let moving: Bool = (live.vehicleMovedAgo ?? .infinity) < OnBoardRules.movedLately
        let age: TimeInterval? = p.map { Date().timeIntervalSince($0.timestamp) }
        return MapTap.couldBeCarrying(vehicleTrip: v.id, isTrain: v.isTrain, idle: trip.phase == .idle, onBoardTrip: live.onBoard?.vehicle.tripId,
                                      moving: moving, metresFromYou: m, fixAge: age)
    }

    /// VoiceOver's "I'm on this one" on a vehicle's mark, as its sheet's.
    private func markOnIt(_ v: LiveVehiclesModel.Moving) -> (() -> Void)? {
        let t = couldBeOn(v)
        return onIt(VehicleTap(target: LiveTrackTarget(tripId: v.id, line: v.line, headsign: "", stopName: "", time: Date(), rail: v.isTrain),
                               trip: t, carrying: t == nil && couldBeCarrying(v)))
    }

    /// "I'm on this one" in a tapped vehicle's sheet: one of your trips that starts with it, or (0.26.2) from on board.
    private func onIt(_ v: VehicleTap) -> (() -> Void)? {
        if let t = v.trip { return { HomeActions.startOnThisOne(t, live: live, trip: trip) } }
        guard v.carrying else { return nil }
        let target = v.target
        return { HomeActions.startOnBoardByHand(Vehicle(tripId: target.tripId, line: target.line, isTrain: target.rail),
                                                live: live, trip: trip, near: near) }
    }

    /// Plan from or to a stop you tapped (once its sheet has gone).
    private func planFrom(stop s: Transit.NearStop, from: Bool) {
        let wasOpen = stopTap != nil
        stopTap = nil
        let e = PlanTripModel.End.place(MapStopSheet.place(s), name: s.rail ? Fmt.place(s.name) : Fmt.stop(s.name))
        Task { @MainActor in
            if wasOpen { try? await Task.sleep(nanoseconds: 450_000_000) }
            weekOpen = false
            rememberForPlan()
            plan.when = .now; plan.clear()
            if from { plan.from = e; plan.to = nil; planFromSearch = true } else { plan.from = .here; plan.to = e; planFromSearch = false }
            withAnimation(DS.quick) { planOpen = true }
        }
    }

    /// Where the map was before Plan, to go back to after.
    private func rememberForPlan() {
        if !planOpen { planReturn = PlanReturn(following: following, camera: lastCamera) }
    }

    private func toast(_ t: String) -> some View {
        Text(t).font(DS.subStrong).foregroundStyle(DS.text).multilineTextAlignment(.leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
            .dsFloat()
            .padding(.horizontal, DS.edge).padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { withAnimation { trip.toast = nil } }
            .task(id: t) {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if trip.toast == t { withAnimation { trip.toast = nil } }
            }
            .zIndex(3)
    }

    // MARK: the departure cards

    /// Where the cards' departures come from: the live store's boards near you (away from your usual start), your home
    /// board (at home, going to school), or else asked for here.
    private enum CardSource { case near, homeBoard, own }
    private var cardSource: CardSource {
        if live.anywhere && !live.nearStops.isEmpty { return .near }
        if !live.anywhere && trip.direction == .toSchool && !stopsStore.boardStops.isEmpty { return .homeBoard }
        return .own
    }
    private var ownDepartures: Bool { cardSource == .own }
    /// The lists per leg this screen shows (0.20.7): your home board in the cards, else none of them.
    private var panelsShown: LiveStore.PanelNeed {
        cardSource == .homeBoard && !planOpen && !nextFirst && !weekOpen ? .board : .none
    }

    private func metres(_ lat: Double, _ lon: Double, fallback: Double?) -> Double? {
        guard let p = near.position else { return fallback }
        return p.distance(from: CLLocation(latitude: lat, longitude: lon))
    }

    private func departure(_ d: BoardDeparture, rail: Bool) -> DepartureGroups.Departure {
        let train = rail || d.train
        return DepartureGroups.Departure(tripId: d.tripId, stopId: d.stopId, line: train ? Transit.trainLabel(d.line) : d.line, headsign: d.headsign,
                                         time: d.time, scheduled: d.scheduled, live: d.live, cancelled: d.cancelled, platform: d.platform,
                                         train: train, stopName: d.stopName)
    }

    private var cardData: (cards: [DepartureGroups.Card], loading: Bool, asOf: Date?, note: String?) {
        let now = Date()
        switch cardSource {
        case .near:
            // (loading only until the boards near you have answered once for this question, even with nothing:
            // `panelsUpdated` is set when they're done, from anywhere)
            let stops = live.nearStops.map { DepartureGroups.Stop(id: $0.id, name: $0.name, rail: $0.rail, metres: metres($0.lat, $0.lon, fallback: $0.meters), lat: $0.lat, lon: $0.lon) }
            let rail = Set(live.nearStops.filter(\.rail).map(\.id))
            let deps = live.nearBoard.map { departure($0, rail: rail.contains($0.stopId)) }
            return (DepartureGroups.cards(stops: stops, departures: deps, now: now), live.nearBoard.isEmpty && live.panelsUpdated == nil, live.nearAsOf, nil)
        case .homeBoard:
            let stops = stopsStore.boardStops.map { DepartureGroups.Stop(id: $0.id, name: $0.name, rail: false, metres: nil) }
            let deps = live.board.map { departure($0, rail: false) }
            return (DepartureGroups.cards(stops: stops, departures: deps, now: now), live.panelsUpdated == nil, live.panelsAsOf, nil)
        case .own:
            let stops = nearDeps.stops.map { DepartureGroups.Stop(id: $0.id, name: $0.name, rail: $0.rail, metres: metres($0.lat, $0.lon, fallback: $0.meters), lat: $0.lat, lon: $0.lon) }
            let rail = Set(nearDeps.stops.filter(\.rail).map(\.id))
            let deps = nearDeps.board.map { departure($0, rail: rail.contains($0.stopId)) }
            var note: String?
            if near.position == nil {
                note = trip.locationDenied ? "Turn on location for Haltewekker to see what leaves around you." : "Finding where you are…"
            } else if nearDeps.loaded && stops.isEmpty {
                note = "No stops found around you."
            }
            return (DepartureGroups.cards(stops: stops, departures: deps, now: now), near.position != nil && !nearDeps.loaded, nil, note)
        }
    }

    private var bottomCards: some View {
        let data = cardData
        return DepartureCardsView(cards: data.cards, loading: data.loading, asOf: data.asOf, note: data.note, nudge: nudge, trips: tripsCard,
                                  focused: $focusedCard, tap: { tapped = $0 }, openDay: { openDay() })
            .padding(.bottom, 8)
    }

    /// The cards' ids as they show (the nudge, the stops, or the empty card, and off the corridor your next trips).
    private var cardIds: [String] {
        let c = cardData.cards.map(\.id)
        return (nudge == nil ? [] : ["nudge"]) + (c.isEmpty ? ["empty"] : c) + (tripsCard == nil ? [] : ["trips"])
    }

    /// Off the corridor (0.24): your next door-to-door trips between Home and School, as the last card, in place of the
    /// corridor's lists of trains and campus buses. Only from your usual start (at home, or at school going home).
    private var tripsCard: AnyView? {
        guard RoleSnapshot.corridor == nil, !live.anywhere, live.custom == nil, trip.phase == .idle else { return nil }
        let toSchool = trip.direction == .toSchool
        return AnyView(HomeTripsCard(trips: live.next, title: toSchool ? "Next to \(placeName(.school))" : "Next home",
                                     loading: live.updated == nil && live.nextError == nil, asOf: live.nextAsOf, note: live.nextError,
                                     open: { HomeActions.openGo(live: live, trip: trip, goStore: goStore, near: near) }))
    }

    /// A swipe to a stop's card moves the map there.
    private func moveTo(card id: String?) {
        guard let id, let s = cardData.cards.first(where: { $0.id == id })?.stop, let la = s.lat, let lo = s.lon else { return }
        setFollowing(false)
        withAnimation(DS.move) {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: la, longitude: lo), latitudinalMeters: 900, longitudinalMeters: 900))
        }
    }

    /// When the school trip or a Be there by plan is due (the time `autoGo` opens Fastest trip by itself): one card
    /// with when to leave and Go, before the departures.
    /// Else, going to a place you picked (0.20.2: searched in Plan): its next trip, as Next trip first's big card, with
    /// the chip to pick another place or go back to your schedule.
    private var nudge: AnyView? {
        // (0.26.2) on a bus or train, or with a trip you ended to go on with: that, not a time to leave from elsewhere
        if trip.phase == .idle, nudgeOwnCard(Date()) {
            return AnyView(TimelineView(.periodic(from: .now, by: 15)) { tl in
                NextTripCard(content: heroContent(now: tl.date), now: tl.date, chip: AnyView(destinationChip), start: startHero,
                             otherTimes: heroOtherTimes, plan: { openPlan(to: nil, when: .now) }, notNow: { trip.forgetResumable() })
            })
        }
        guard let d = HomeActions.due(trip: trip, planner: planner, now: Date()) else {
            guard live.custom != nil, trip.phase == .idle else { return nil }
            return AnyView(TimelineView(.periodic(from: .now, by: 15)) { tl in
                NextTripCard(content: heroContent(now: tl.date), now: tl.date, chip: AnyView(destinationChip), start: startHero,
                             otherTimes: heroOtherTimes, plan: { openPlan(to: nil, when: .now) }, notNow: { trip.forgetResumable() })
            })
        }
        return AnyView(NudgeCard(leave: d.leave, ride: d.trip.first, sub: d.sub) {
            HomeActions.openPlanGo(school: d.school, trip: trip, planner: planner, goStore: goStore, near: near)
        })
    }

    /// Live around you: the big card instead of the nudge while the home found you on board, a trip you ended is
    /// offered to go on with, or the due trip leaves from somewhere you aren't while you move like a bus or train.
    private func nudgeOwnCard(_ now: Date) -> Bool {
        if HomeActions.onBoardTrip(live: live) != nil || resumeOffer(now) != nil { return true }
        if let d = HomeActions.due(trip: trip, planner: planner, now: now) { return leaveHidden(d.trip) }
        return false
    }

    // MARK: Next trip first (concept B)

    /// The map on top with search and follow-me, the big card with your next trip, and the bar with Home, School,
    /// Plan and Your week (which then covers the map, the bar staying).
    private var nextTripLayout: some View {
        VStack(spacing: 0) {
            ZStack {
                if weekOpen {
                    DaySheet(close: { closeWeek() }, week: true)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 10) {
                        nextSearchRow
                        Spacer(minLength: 0)
                        HStack { Spacer(); followButton }
                        if trip.phase == .idle {
                            // the trip picked again with the countdown's clock, so a trip that has gone makes way
                            TimelineView(.periodic(from: .now, by: 15)) { tl in
                                NextTripCard(content: heroContent(now: tl.date), now: tl.date, chip: AnyView(destinationChip), start: startHero, otherTimes: heroOtherTimes,
                                             plan: { openPlan(to: nil, when: .now) }, notNow: { trip.forgetResumable() })
                            }
                        }
                    }
                    .padding(.horizontal, DS.edge).padding(.top, 6).padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // (not while a trip runs: at a change the bar to your trip takes its place)
            if trip.phase == .idle {
                NextTripBar(weekOpen: weekOpen, friendsWaiting: friends.badge, friends: { friends.showing = true },
                            week: { withAnimation(DS.quick) { weekOpen.toggle() } },
                            settings: { weekOpen = false; sheet = .settings })
            }
        }
    }

    private func closeWeek() { withAnimation(DS.quick) { weekOpen = false } }

    /// The search field, with the weather and Settings inside it.
    private var nextSearchRow: some View {
        HStack(spacing: 4) {
            Button { openSearch() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.body.weight(.semibold)).foregroundStyle(DS.secondary)
                    Text("Search a stop or place").font(DS.body).foregroundStyle(DS.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 18)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search a stop or place")
            .accessibilityHint("Plan a trip")
            weatherChip(inline: true)
        }
        .padding(.trailing, 6)
        .background(DS.surface, in: Capsule())
        .dsFloat()
    }

    /// What your places call a place (Home and School as you named them).
    private func placeName(_ p: Place) -> String {
        if p.key == Place.home.key { return places.home?.name ?? "Home" }
        if p.key == Place.school.key { return places.school?.name ?? p.short }
        return p.short
    }

    /// The card's trip: a due school or planned trip, else the first of your next trips toward where you're going,
    /// else nothing (`NextTrip.pick`).
    private func heroContent(now: Date) -> NextTripCard.Content {
        // on the bus or train already (0.20.5): when you're there, not a countdown to one you'd still have to catch
        if let ob = live.onBoard, let t = HomeActions.onBoardTrip(live: live) {
            return .onBoard(.init(vehicle: ob.vehicle, trip: t, destName: placeName(live.destination(trip.direction)),
                                  startsSoon: live.onBoardLooks == 1 && HomeActions.mayAutoStart(ob.vehicle)))
        }
        // a trip you ended by hand before its last leg, while you're still on the way (0.26.2): go on with it
        if let r = resumeOffer(now) {
            return .goOn(.init(destName: r.destName, next: r.next.title, from: r.from.short, train: r.next.mode == .train))
        }
        let due = HomeActions.due(trip: trip, planner: planner, now: now)
        let dest = live.destination(trip.direction).key
        let pick = NextTrip.pick(dest: dest, dueDest: due?.dest.key, schoolDue: due?.school == true, plannedDue: due.map { !$0.school } ?? false,
                                 liveDest: dest, liveLeaves: live.onTheMove ? [] : live.next.map(\.start), now: now)
        switch pick.source {
        case .school, .planned:
            guard let d = due else { return .empty(note: nil) }
            if leaveHidden(d.trip) { return .empty(note: Self.onTheMoveNote) }
            return .trip(.init(title: d.sub, leave: d.leave, trip: d.trip, destName: placeName(d.dest), asOf: nil))
        case .live:
            guard let i = pick.index, let t = live.next[safe: i] else { return .empty(note: nil) }
            if leaveHidden(t) { return .empty(note: Self.onTheMoveNote) }
            let dest = placeName(live.destination(trip.direction))
            return .trip(.init(title: "", leave: t.start, trip: t, destName: dest, asOf: live.nextAsOf, startTitle: "Start"))
        case .none:
            if live.onTheMove { return .empty(note: Self.onTheMoveNote) }
            if live.updated == nil && live.nextError == nil { return .loading }
            return .empty(note: live.nextError)
        }
    }

    static let onTheMoveNote = "You’re on the move: finding the bus or train you’re on."

    /// Moving like a bus or train and not at its first stop (0.26.2): no "time to leave" for this trip
    /// (`OnBoardRules.leaveCardHidden`).
    private func leaveHidden(_ t: DoorTrip) -> Bool {
        let f = t.first
        let at: CLLocation? = near.position ?? trip.lastFix
        let m: Double? = f.fromLat.flatMap { la in f.fromLon.flatMap { lo in at?.distance(from: CLLocation(latitude: la, longitude: lo)) } }
        return OnBoardRules.leaveCardHidden(onBoard: live.onBoard != nil, vehicleMovedAgo: live.vehicleMovedAgo, firstStopMetres: m)
    }

    /// The trip you ended by hand, while it's offered to go on with (`TripResume.offer`): moving like a bus or train, or
    /// near its next leg's stop, within half an hour.
    private func resumeOffer(_ now: Date) -> TripManager.Resumable? {
        guard let r = trip.resumable else { return nil }
        let moving: Bool = (live.vehicleMovedAgo ?? .infinity) < OnBoardRules.movedLately
        let at: CLLocation? = near.position ?? trip.lastFix
        let c = r.from.coordinate
        let m: Double? = at.map { $0.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) }
        return TripResume.offer(endedAt: r.endedAt, now: now, idle: trip.phase == .idle, moving: moving, metresToItsStop: m) ? r : nil
    }

    /// The due trip, when it goes where the card is going.
    private func dueHere(_ now: Date) -> DueTrip? {
        guard let d = HomeActions.due(trip: trip, planner: planner, now: now), d.dest.key == live.destination(trip.direction).key else { return nil }
        return d
    }

    /// The card's destination chip: where the live store's trips go; pick By your schedule (school or home, 0.20.2),
    /// Home, School or another of your places, or one of the last places you searched.
    private var destinationChip: some View {
        let dest = live.destination(trip.direction)
        let current = places.list.first(where: isCurrentDest)
        let scheduled: Place = trip.direction == .toSchool ? .school : .home
        let ids = HomeDest.recents(live.recents.map { (id: $0.id, lat: $0.lat, lon: $0.lon) }, saved: places.list.map { (lat: $0.lat, lon: $0.lon) })
        let recent = ids.compactMap { id in live.recents.first { $0.id == id } }
        return DestinationChip(title: NextTrip.destTitle(current?.name ?? placeName(dest)),
                               schedule: (name: placeName(scheduled), current: live.custom == nil),
                               places: places.list, recents: recent,
                               isCurrent: isCurrentDest, isCurrentRecent: { live.custom?.id == $0.id },
                               choose: chooseDest, chooseSchedule: chooseSchedule, chooseRecent: chooseRecent)
    }

    /// Back to your schedule: school or home, by the direction (as before you picked a place).
    private func chooseSchedule() {
        guard trip.phase == .idle, live.custom != nil else { return }
        live.go(to: nil)
        Task { await live.refresh(trip.direction, at: near.position, force: true) }
    }

    /// One of the last places you searched, as where the card goes.
    private func chooseRecent(_ d: Destination) {
        guard trip.phase == .idle, live.custom?.id != d.id else { return }
        live.go(to: d)
        Task { await live.refresh(trip.direction, at: near.position, force: true) }
    }

    private func isCurrentDest(_ p: SavedPlace) -> Bool {
        let key = places.place(p).key
        if key == Place.home.key || key == Place.school.key { return live.custom == nil && live.destination(trip.direction).key == key }
        guard let c = live.custom else { return false }
        return abs(c.lat - p.lat) < 1e-6 && abs(c.lon - p.lon) < 1e-6
    }

    /// Another destination for the card: the live store's own switch (your two trips' direction, or somewhere you
    /// picked, as the old home's destination list), then its trips there. Nothing else changes.
    private func chooseDest(_ p: SavedPlace) {
        guard trip.phase == .idle, !isCurrentDest(p) else { return }
        let key = places.place(p).key
        if key == Place.school.key {
            live.go(to: nil)
            if trip.direction != .toSchool { trip.pick(.toSchool) }
        } else if key == Place.home.key {
            live.go(to: nil)
            if trip.direction != .home { trip.pick(.home) }
        } else {
            live.go(to: Destination(id: p.stopIds.first ?? "\(p.lat),\(p.lon)", name: p.name, lat: p.lat, lon: p.lon))
        }
        Task { await live.refresh(trip.direction, at: near.position, force: true) }
    }

    /// Start: the hands-free Fastest trip, as Go (for the due trip with its plan; else to where you're going).
    private func startHero() {
        guard trip.phase == .idle else { return }
        if let t = HomeActions.onBoardTrip(live: live) {
            HomeActions.startOnThisOne(t, live: live, trip: trip)
        } else if resumeOffer(Date()) != nil {
            trip.resumeTrip()
        } else if let d = dueHere(Date()) {
            HomeActions.openPlanGo(school: d.school, trip: trip, planner: planner, goStore: goStore, near: near)
        } else {
            HomeActions.openGo(live: live, trip: trip, goStore: goStore, near: near)
        }
    }

    /// Other times: Plan to the card's place (to be there in time, for a due trip with a deadline).
    private func heroOtherTimes() {
        let now = Date()
        if let d = dueHere(now) {
            let when: PlanCompare.When = d.deadline.map { $0 > now ? .arrive($0) : .now } ?? .now
            openPlan(to: .place(d.dest, name: placeName(d.dest)), when: when)
        } else {
            let dest = live.destination(trip.direction)
            openPlan(to: .place(dest, name: placeName(dest)), when: .now)
        }
    }

    // MARK: actions

    private func openDay() { withAnimation(DS.move) { dayOpen = true } }

    /// Search anywhere: Plan from your location, straight to picking where to.
    private func openSearch() {
        weekOpen = false
        rememberForPlan()
        plan.from = .here; plan.to = nil; plan.when = .now; plan.clear()
        planFromSearch = true
        withAnimation(DS.quick) { planOpen = true }
    }

    /// A place's chip: Plan from your location to there, leaving now.
    private func openPlan(to p: SavedPlace) {
        openPlan(to: .place(places.place(p), name: p.name), when: .now)
    }

    /// Plan from your location to there (nil: empty, to pick where to), leaving now or to be there by a time.
    private func openPlan(to end: PlanTripModel.End?, when: PlanCompare.When) {
        weekOpen = false
        rememberForPlan()
        plan.from = .here; plan.to = end; plan.when = when
        if end == nil { plan.clear() }
        planFromSearch = false
        withAnimation(DS.quick) { planOpen = true }
    }

    private func closePlan() {
        withAnimation(DS.quick) { planOpen = false }
        plan.clear()
        // the map back as it was before Plan (following you only if it was)
        let back = planReturn
        planReturn = nil
        if back?.following ?? following {
            setFollowing(true)
            withAnimation(DS.move) { camera = .userLocation(followsHeading: false, fallback: camera) }
        } else if let c = back?.camera {
            withAnimation(DS.move) { camera = .camera(c) }
        }
    }

    /// The way you look at, on the map.
    private func fitRoute() {
        let c = plan.route(plan.focused)
        guard c.count > 1 else { return }
        setFollowing(false)
        let lats = c.map(\.latitude), lons = c.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, (lats.max()! - lats.min()!) * 2.2), longitudeDelta: max(0.01, (lons.max()! - lons.min()!) * 1.6))
        withAnimation(DS.move) { camera = .region(MKCoordinateRegion(center: center, span: span)) }
    }
}

/// Find a stop or station by name (Transitous's search), for a place or a trip's end.
struct PlaceSearchSheet: View {
    let title: String
    let pick: (Transit.StopHit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [Transit.StopHit] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                if searching && hits.isEmpty {
                    HStack { ProgressView(); Text("Searching…").foregroundStyle(DS.secondary) }
                } else if hits.isEmpty && query.count >= 2 {
                    Text("No stops found for “\(query)”").foregroundStyle(DS.secondary)
                }
                ForEach(hits) { h in
                    Button { pick(h); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.name).font(DS.bodyStrong).foregroundStyle(DS.text)
                            if !h.town.isEmpty { Text(h.town).font(DS.footnote).foregroundStyle(DS.secondary) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Stop or station")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { hits = []; return }
                try? await Task.sleep(nanoseconds: 350_000_000)        // (while you type: one search when you pause)
                guard !Task.isCancelled else { return }
                searching = true
                let found = await Transit.findStops(q)
                searching = false
                guard !Task.isCancelled else { return }
                hits = found
            }
        }
        .tint(DS.accentText)
    }
}

/// The next trip, due now: when to leave, the first ride, and Go (the hands-free screen; it also opens by itself).
struct NudgeCard: View {
    let leave: Date
    let ride: Ride
    let sub: String
    let go: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.everyMinute) { tl in
                HStack(spacing: 8) {
                    DSLinePill(line: ride.line, train: ride.isTrain)
                    Text("\(DepartureGroups.leaveText(leave: leave, now: tl.date) ?? "Leave now") · \(Fmt.hhmm(ride.departure))")
                        .font(DS.headline).monospacedDigit().foregroundStyle(DS.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            Text("\(sub) · from \(Fmt.place(ride.fromStop))").font(DS.sub).foregroundStyle(DS.secondary).lineLimit(2)
            Button(action: go) {
                Text("Go").font(DS.bodyStrong).foregroundStyle(DS.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(DS.accent, in: Capsule())
            }
            .buttonStyle(DSPressStyle())
            .accessibilityHint("Opens the hands-free trip")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .overlay(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous).stroke(DS.accent, lineWidth: 2))
    }
}
