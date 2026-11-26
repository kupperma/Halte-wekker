import MapKit
import SwiftUI

// Friends (0.31, "Map first"): friends' faces where they are, ringed in their vehicle's colour, their routes drawn.
// (0.40.2) Drawn on the home map, with Friends a sheet over it (as search); `FriendsLiveMap` is left only for the small
// trip map on a friend's page when Friends was opened away from the home map (Settings). The framing is worked out in
// MapFrame.swift (tested).

// MARK: the routes

/// The road each friend's bus or train takes, once per vehicle (its live trip's shape), for the map.
@MainActor
final class FriendRoutes: ObservableObject {
    static let shared = FriendRoutes()
    @Published private(set) var paths: [String: [GeoPoint]] = [:]
    private var asked: Set<String> = []

    private init() {}

    /// Fetches the shapes not asked for yet (a trip id the live data doesn't know just stays without one).
    func load(_ tripIds: [String]) async {
        for id in tripIds where !id.isEmpty && !asked.contains(id) {
            asked.insert(id)
            if asked.count > 200 { asked = [id] }
            guard let t = await Transit.liveTrip(id, maxAge: 600) else { continue }
            paths[id] = t.path.map { GeoPoint(lat: $0.latitude, lon: $0.longitude) }
        }
    }

    /// The bit a friend rides (a straight line through where they are without a shape).
    func route(_ s: TravelState) -> [GeoPoint] {
        MapFrame.route(s, path: s.trip.flatMap { paths[$0] } ?? [])
    }
}

// MARK: the map

/// A face on the map: a travelling friend (ringed in their vehicle's colour) or one on campus (the accent).
struct FriendMapPin: Identifiable, Equatable {
    let id: String
    let name: String
    let point: GeoPoint
    let ring: Color
    let label: String
    let stale: Bool
    let route: [GeoPoint]
}

/// Where a friend got on ("from") or gets off ("to").
struct MapStop: Identifiable, Equatable {
    let id: String
    let name: String
    let point: GeoPoint
}

/// Friends' faces and routes on a full map, framed (`MapFrame.fit`) so they sit in the part the sheet leaves free.
struct FriendsLiveMap: View {
    let pins: [FriendMapPin]
    /// What to frame (the pins, and for one friend where they got on and get off).
    let frame: [GeoPoint]
    /// Where one friend got on and gets off (their page).
    var stops: [MapStop] = []
    /// The share of the map's height the sheet covers at the bottom.
    var cover: CGFloat = 0
    var tap: ((String) -> Void)? = nil
    @State private var camera: MapCameraPosition = .automatic

    private var key: String {
        let f: String = frame.map { String(format: "%.4f,%.4f", $0.lat, $0.lon) }.joined(separator: ";")
        return f + "|\(Int(cover * 100))"
    }

    var body: some View {
        GeometryReader { g in
            map
                .onAppear { reframe(g.size) }
                .onChange(of: key) { _, _ in reframe(g.size) }
                .onChange(of: g.size) { _, s in reframe(s) }
        }
    }

    private var map: some View {
        Map(position: $camera) {
            ForEach(pins) { p in
                if p.route.count >= 2 {
                    MapPolyline(coordinates: p.route.map(Self.coord)).stroke(p.ring.opacity(p.stale ? 0.5 : 0.9), lineWidth: 5)
                }
            }
            ForEach(stops) { s in
                Marker(s.name, systemImage: s.id == "to" ? "flag.fill" : "circle.fill", coordinate: Self.coord(s.point))
                    .tint(s.id == "to" ? DS.accent : DS.legQuiet)
            }
            ForEach(pins) { p in
                Annotation(p.name, coordinate: Self.coord(p.point), anchor: .center) { face(p) }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pins.isEmpty ? "Map" : "Map of friends")
    }

    static func coord(_ p: GeoPoint) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon) }

    /// (0.31's fix) Always a region worked out from the points, never MapKit's `.automatic` (which frames only once).
    private func reframe(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let aspect: Double = Double(size.height / size.width)
        var pts: [GeoPoint] = frame
        if pts.isEmpty {
            // nobody on the map: around your Home and School
            pts = [Place.home.point, Place.school.point].filter(MapFrame.valid)
        }
        guard let r = MapFrame.fit(pts, aspect: aspect, cover: Double(cover)) else { return }
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: r.lat, longitude: r.lon),
                                        span: MKCoordinateSpan(latitudeDelta: r.latDelta, longitudeDelta: r.lonDelta))
        withAnimation(DS.quick) { camera = .region(region) }
    }

    @ViewBuilder private func face(_ p: FriendMapPin) -> some View {
        if let tap {
            FriendFace(pin: p, tap: { tap(p.id) })
        } else {
            FriendFace(pin: p, tap: nil)
        }
    }
}

/// A friend's face on a map (the home map while Friends is open, or a friend's small trip map): ringed in their
/// vehicle's colour, faded when their update is old; a button when it can be tapped.
struct FriendFace: View {
    let pin: FriendMapPin
    let tap: (() -> Void)?
    @ObservedObject private var store = FriendStore.shared

    var body: some View {
        if let tap {
            Button(action: tap) { picture }
                .buttonStyle(DSPressStyle())
                .accessibilityLabel(pin.label)
                .accessibilityHint("Shows \(pin.name)’s page")
        } else {
            picture
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(pin.label)
        }
    }

    private var picture: some View {
        FriendAvatar(name: pin.name, id: pin.id, picture: store.pictures[pin.id], size: 42)
            .padding(3)
            .background(Circle().fill(DS.surface))
            .overlay(Circle().stroke(pin.ring, lineWidth: 3))
            .opacity(pin.stale ? 0.6 : 1)
            .dsFloat()
    }
}

// MARK: friends on the home map (0.40.2)

/// (0.40.2) Friends is a sheet over the home map, as search is (0.40): no second map of its own. The sheet says which
/// friend's page is open (their trip framed on the home map); the home map says which face was tapped (the sheet opens
/// their page).
@MainActor
final class FriendsOnMap: ObservableObject {
    static let shared = FriendsOnMap()
    /// The friend whose page is open in the Friends sheet.
    @Published var focus: String?
    /// A face tapped on the home map, for the sheet to open.
    @Published var tapped: String?

    private init() {}

    /// What the home map draws for Friends: every travelling friend (and friends on campus), or with a friend's page
    /// open and them travelling, just them with where they got on and get off.
    struct Layer {
        var pins: [FriendMapPin] = []
        var stops: [MapStop] = []
        /// What the map frames.
        var frame: [GeoPoint] = []

        /// Changes when what is framed changes (a face moving a little doesn't move the map).
        var key: String {
            let pts: [String] = frame.map { String(format: "%.3f,%.3f", $0.lat, $0.lon) }
            return pts.joined(separator: ";")
        }
    }

    func layer(now: Date = Date()) -> Layer {
        if let id = focus, let one = Self.one(id, now: now) { return one }
        return Self.all(now: now)
    }

    /// One friend's trip: their face, their route, where they got on and get off.
    private static func one(_ id: String, now: Date) -> Layer? {
        let store = FriendStore.shared
        guard let f = store.book?.friend(id), let t = store.travel[id], TravelAge.freshness(t, now: now) != .gone else { return nil }
        let s: TravelState = t.state
        let pts: [GeoPoint] = MapFrame.points(s)
        guard !pts.isEmpty else { return nil }
        var out = Layer()
        if let p = s.pos, let g = MapFrame.point(lat: p.lat, lon: p.lon) {
            let ring: Color = DS.mode(train: s.isTrain, mode: s.mode, line: s.line ?? "")
            let stale: Bool = TravelAge.freshness(t, now: now) == .stale
            out.pins.append(FriendMapPin(id: f.id, name: f.name, point: g, ring: ring, label: "\(f.name), \(TravelWords.summary(s))",
                                         stale: stale, route: FriendRoutes.shared.route(s)))
        }
        if let g = MapFrame.point(lat: s.from.lat, lon: s.from.lon) { out.stops.append(MapStop(id: "from", name: s.from.name, point: g)) }
        if let g = MapFrame.point(lat: s.to.lat, lon: s.to.lon) { out.stops.append(MapStop(id: "to", name: s.to.name, point: g)) }
        out.frame = pts
        return out
    }

    /// Travelling friends where they are, and friends on campus at your school (when it's theirs).
    static func all(now: Date) -> Layer {
        let store = FriendStore.shared
        let extras = FriendExtrasStore.shared
        let routes = FriendRoutes.shared
        var out = Layer()
        var seen: Set<String> = []
        let moving: [FriendTravelSeen] = store.travelling(now: now)
        for t in moving {
            let s: TravelState = t.state
            guard let p = s.pos, let g = MapFrame.point(lat: p.lat, lon: p.lon) else { continue }
            let name: String = store.name(t.from)
            let ring: Color = DS.mode(train: s.isTrain, mode: s.mode, line: s.line ?? "")
            let stale: Bool = TravelAge.freshness(t, now: now) == .stale
            out.pins.append(FriendMapPin(id: t.from, name: name, point: g, ring: ring, label: "\(name), \(TravelWords.summary(s))",
                                         stale: stale, route: routes.route(s)))
            seen.insert(t.from)
        }
        let school: GeoPoint = Place.school.point
        let mine: String = RoleWords.current.school
        if MapFrame.valid(school) {
            let campus: [FriendExtrasStore.OnCampus] = extras.onCampus(now: now).filter { !seen.contains($0.id) }
            for (i, c) in campus.enumerated() where c.state.school == nil || c.state.school == mine {
                // side by side, a little apart, so each face can be tapped
                let g = GeoPoint(lat: school.lat, lon: school.lon + Double(i) * 0.0012)
                let name: String = store.name(c.id)
                out.pins.append(FriendMapPin(id: c.id, name: name, point: g, ring: DS.accent, label: "\(name), \(CampusWords.since(c.state))",
                                             stale: false, route: []))
            }
        }
        var frame: [GeoPoint] = out.pins.map(\.point)
        for t in moving { frame += MapFrame.points(t.state) }
        out.frame = frame
        return out
    }
}

/// (0.40.2) The Friends sheet is over the home map (its faces drawn there): a friend's page then shows their trip on
/// that map, not a map of its own. Off (Friends opened from Settings): a small map of their trip on the page.
private struct FriendsOverMapKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var friendsOverMap: Bool {
        get { self[FriendsOverMapKey.self] }
        set { self[FriendsOverMapKey.self] = newValue }
    }
}

// MARK: friends' cards

/// A friend's card in the sheet's row: face, name, what they're on, when they arrive.
struct FriendMiniCard: View {
    let friend: Friend
    let travel: FriendTravelSeen?
    let campus: Bool
    @ObservedObject private var store = FriendStore.shared
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 156

    var body: some View {
        let s: TravelState? = travel?.state
        let line: String = s.map { TravelWords.cardLine($0) } ?? (campus ? "On campus" : "Not travelling now")
        let time: String? = s.flatMap { TravelWords.cardTime($0) }
        let ring: Color = s.map { DS.mode(train: $0.isTrain, mode: $0.mode, line: $0.line ?? "") } ?? (campus ? DS.accent : Color.clear)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.s8) {
                FriendAvatar(name: friend.name, id: friend.id, picture: store.pictures[friend.id], size: 30)
                    .overlay(Circle().stroke(ring, lineWidth: 2).padding(-2))
                Text(friend.name).font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(1)
                if TestFriendBot.shared.isBot(friend.id) { TestFriendTag() }
            }
            Text(line).font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let time { Text(time).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.text) }
            Spacer(minLength: 0)
        }
        .padding(DS.s12)
        .frame(width: width, alignment: .leading)
        .frame(minHeight: 96, alignment: .topLeading)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(travel.map { TravelAge.freshness($0, now: Date()) == .stale } == true ? 0.7 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([friend.name, line, time].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint("Shows \(friend.name)’s page")
        .accessibilityAddTraits(.isButton)
    }
}

/// A tile of the sheet's buttons: an icon over its words ("Chats · 3", "Groups", "Compare").
struct FriendsTile: View {
    let icon: String
    let title: String
    var tint: Color = DS.accentText

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(tint).accessibilityHidden(true)
            Text(title).font(DS.footnoteStrong).foregroundStyle(DS.text).lineLimit(2).multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, DS.s8).padding(.vertical, DS.s8)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}
