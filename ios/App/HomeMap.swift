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
    /// Only stations, stops and vehicles of our own: no shops or restaurants.
    var style: MapStyle {
        switch self {
        case .standard: return .standard(elevation: .flat, pointsOfInterest: .excludingAll)
        case .muted: return .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll)
        case .satellite: return .imagery(elevation: .flat)
        case .hybrid: return .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        }
    }
}

/// Settings keys of the new look.
enum NewLook {
    static let key = "ui.newLook"            // on by default (0.19)
    static let vehiclesKey = "map.liveVehicles"

    /// Settings › Reset everything: the new look's settings too (your places, the map, the switch, days turned off).
    @MainActor static func resetAll() {
        let d = UserDefaults.standard
        for k in [key, vehiclesKey, HomeMapStyle.key, PlanTripModel.recentsKey, PlacesLogic.storageKey] { d.removeObject(forKey: k) }
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

/// A station (a rounded square with a train) or a bus stop (a small dot), with its name when zoomed in.
struct MapStopMark: View {
    let stop: Transit.NearStop
    let names: Bool
    var body: some View {
        Group {
            if stop.rail {
                VStack(spacing: 4) {
                    Image(systemName: "tram.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.onAccent)
                        .frame(width: 34, height: 34)
                        .background(DS.train, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                    label(Fmt.place(stop.name), strong: true)
                }
            } else {
                HStack(spacing: 4) {
                    Circle().fill(DS.bus).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(DS.surface, lineWidth: 2))
                    if names { label(Fmt.stop(stop.name), strong: false) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stop.rail ? "Station \(Fmt.place(stop.name))" : "Bus stop \(Fmt.stop(stop.name))")
    }
    private func label(_ t: String, strong: Bool) -> some View {
        Text(t).font(strong ? DS.caption : .caption2.weight(.semibold)).foregroundStyle(DS.text).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(DS.surface.opacity(0.88), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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

    @State private var camera: MapCameraPosition
    @State private var region: MKCoordinateRegion?
    @State private var shown = false                       // on screen (not covered by Fastest trip or the ride)
    @State private var sheet: HomeSheet?
    @ObservedObject private var nearDeps = NearDeparturesModel.shared
    @ObservedObject private var school = SchoolAlarm.shared
    @EnvironmentObject var stopsStore: StopsStore
    @State private var focusedCard: String?
    @State private var tapped: DepartureTap?
    @State private var dayOpen = false
    @StateObject private var plan = PlanTripModel()
    @State private var planOpen = false
    @State private var planFromSearch = false
    @State private var warmedUp = false                    // the first seconds after appearing: no vehicles yet
    @State private var idsChangedAt = Date.distantPast     // when the cards last changed (not a swipe: the map stays)

    enum HomeSheet: String, Identifiable {
        case settings, weather, addPlace, demo
        var id: String { rawValue }
    }

    /// Where the map starts before your location is known: where the phone last was, or home.
    private static let startRegion = MKCoordinateRegion(center: CLLocationManager().location?.coordinate ?? Place.veghel.coordinate,
                                                        latitudinalMeters: 1400, longitudinalMeters: 1400)
    init() {
        _camera = State(initialValue: .userLocation(followsHeading: false, fallback: .region(Self.startRegion)))
    }

    /// The map is on screen: not under Your day, Fastest trip or the ride, and the app in front.
    private var visible: Bool {
        shown && !dayOpen && !planOpen && sheet == nil && tapped == nil && scene == .active && !goStore.isOpen
    }
    private var mapStyle: HomeMapStyle { HomeMapStyle(rawValue: styleRaw) ?? .standard }

    var body: some View {
        ZStack(alignment: .top) {
            map.ignoresSafeArea()
            if planOpen {
                PlanTripOverlay(model: plan, pickOnOpen: planFromSearch, close: closePlan)
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
        // the departures near you, when neither the live store nor your home board has them
        .task(id: ownDepartures && visible) {
            guard ownDepartures else { return }
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
        .onChange(of: goStore.isOpen) { _, open in if open { planOpen = false; dayOpen = false } }
        .sheet(item: $tapped) { DepartureDetailSheet(tap: $0).presentationDetents([.medium, .large]) }
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
                SettingsView(tryDemo: {
                    Task { @MainActor in try? await Task.sleep(nanoseconds: 500_000_000); sheet = .demo }
                }, newLook: true).presentationDetents([.large])
            case .demo: DemoSheet().presentationDetents([.large])
            case .weather: OutfitSheet().presentationDetents([.medium, .large])
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
                    Annotation(Fmt.place(s.name), coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon), anchor: s.rail ? .top : .leading) {
                        MapStopMark(stop: s, names: drawn.names)
                    }
                    .annotationTitles(.hidden)
                }
                if route.count > 1 {
                    MapPolyline(coordinates: route)
                        .stroke(DS.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                ForEach(moving) { v in
                    Annotation(v.line, coordinate: v.coordinate, anchor: .center) { VehiclePill(v: v) }
                        .annotationTitles(.hidden)
                }
            }
            .mapStyle(mapStyle.style)
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                region = ctx.region
                mapStops.cameraStopped(ctx.region, visible: visible)
                Task { await vehicles.refresh(ctx.region, gate: vehicleGate) }
            }
        }
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
        .padding(.horizontal, -2)
        .padding(.vertical, -6)
    }

    /// The travel time now, for the place you're going to (today's trips there; nothing is asked for the chips).
    private func chipMinutes(_ p: SavedPlace) -> Int? {
        guard live.nextAsOf == nil, !live.onTheMove, places.place(p).key == live.destination(trip.direction).key else { return nil }
        return PlacesLogic.minutesNow(arrival: live.next.first?.end, now: Date())
    }

    private var rightColumn: some View {
        VStack(alignment: .trailing, spacing: 8) {
            weatherChip
            followButton
        }
    }

    @ViewBuilder private var weatherChip: some View {
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
            .background(DS.surface.opacity(0.96), in: Capsule())
            .dsFloat()
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(outfit.plan?.start.map { "Weather: \(Int($0.w.temp.rounded())) degrees. What to wear" } ?? "Weather and what to wear")
    }

    private var followButton: some View {
        let on = camera.followsUserLocation && !trip.locationDenied
        return Button {
            withAnimation(DS.move) { camera = .userLocation(followsHeading: false, fallback: camera) }
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
        .accessibilityAddTraits(on ? .isSelected : [])
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
            let stops = live.nearStops.map { DepartureGroups.Stop(id: $0.id, name: $0.name, rail: $0.rail, metres: metres($0.lat, $0.lon, fallback: $0.meters), lat: $0.lat, lon: $0.lon) }
            let rail = Set(live.nearStops.filter(\.rail).map(\.id))
            let deps = live.nearBoard.map { departure($0, rail: rail.contains($0.stopId)) }
            return (DepartureGroups.cards(stops: stops, departures: deps, now: now), live.nearBoard.isEmpty && live.updated == nil, live.nearAsOf, nil)
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
        return DepartureCardsView(cards: data.cards, loading: data.loading, asOf: data.asOf, note: data.note, nudge: nudge,
                                  focused: $focusedCard, tap: { tapped = $0 }, openDay: { openDay() })
            .padding(.bottom, 8)
    }

    /// The cards' ids as they show (the nudge, the stops, or the empty card).
    private var cardIds: [String] {
        let c = cardData.cards.map(\.id)
        return (nudge == nil ? [] : ["nudge"]) + (c.isEmpty ? ["empty"] : c)
    }

    /// A swipe to a stop's card moves the map there.
    private func moveTo(card id: String?) {
        guard let id, let s = cardData.cards.first(where: { $0.id == id })?.stop, let la = s.lat, let lo = s.lon else { return }
        withAnimation(DS.move) {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: la, longitude: lo), latitudinalMeters: 900, longitudinalMeters: 900))
        }
    }

    /// When the school trip or a Be there by plan is due (the time `autoGo` opens Fastest trip by itself): one card
    /// with when to leave and Go, before the departures.
    private var nudge: AnyView? {
        guard trip.phase == .idle else { return nil }
        let now = Date()
        if let n = school.next, GoStore.schoolWindowOpen(n, now: now), let l = n.leave, let t = n.trip,
           DepartureGroups.leaveText(leave: l, now: now) != nil {
            return AnyView(NudgeCard(leave: l, ride: t.first, sub: "For your \(Fmt.hhmm(n.classStart)) class") {
                HomeActions.openPlanGo(school: true, trip: trip, planner: planner, goStore: goStore, near: near)
            })
        }
        if let a = planner.arrive, let t = planner.arriveChosen, GoStore.arriveWindowOpen(a, chosen: t, now: now),
           DepartureGroups.leaveText(leave: t.start, now: now) != nil {
            return AnyView(NudgeCard(leave: t.start, ride: t.first, sub: a.leaving ? "Your trip \(a.out ? "to school" : "home")" : "\(a.out ? "School" : "Home") by \(a.time)") {
                HomeActions.openPlanGo(school: false, trip: trip, planner: planner, goStore: goStore, near: near)
            })
        }
        return nil
    }

    // MARK: actions

    private func openDay() { withAnimation(DS.move) { dayOpen = true } }

    /// Search anywhere: Plan from your location, straight to picking where to.
    private func openSearch() {
        plan.from = .here; plan.to = nil; plan.when = .now; plan.clear()
        planFromSearch = true
        withAnimation(DS.quick) { planOpen = true }
    }

    /// A place's chip: Plan from your location to there, leaving now.
    private func openPlan(to p: SavedPlace) {
        plan.from = .here; plan.to = .place(places.place(p), name: p.name); plan.when = .now
        planFromSearch = false
        withAnimation(DS.quick) { planOpen = true }
    }

    private func closePlan() {
        withAnimation(DS.quick) { planOpen = false }
        plan.clear()
        withAnimation(DS.move) { camera = .userLocation(followsHeading: false, fallback: camera) }
    }

    /// The way you look at, on the map.
    private func fitRoute() {
        let c = plan.route(plan.focused)
        guard c.count > 1 else { return }
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
