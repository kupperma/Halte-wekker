import MapKit
import SwiftUI

// Friends (0.31, "Map first"): the map behind Friends and a friend's page (friends' faces where they are, ringed in
// their vehicle's colour, their routes drawn) and the sheet over it (a handle to pull it up or down). The framing is
// worked out in MapFrame.swift (tested).

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
    @ObservedObject private var store = FriendStore.shared
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

    private func picture(_ p: FriendMapPin) -> some View {
        FriendAvatar(name: p.name, id: p.id, picture: store.pictures[p.id], size: 42)
            .padding(3)
            .background(Circle().fill(DS.surface))
            .overlay(Circle().stroke(p.ring, lineWidth: 3))
            .opacity(p.stale ? 0.6 : 1)
            .dsFloat()
    }

    @ViewBuilder private func face(_ p: FriendMapPin) -> some View {
        if let tap {
            Button { tap(p.id) } label: { picture(p) }
                .buttonStyle(DSPressStyle())
                .accessibilityLabel(p.label)
                .accessibilityHint("Shows \(p.name)’s page")
        } else {
            picture(p)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(p.label)
        }
    }
}

// MARK: the sheet

/// A sheet over the map: a handle to pull it up (or tap: "Show more"), its content scrolling inside. `peek` is how
/// high it stands when down.
struct MapSheet<Content: View>: View {
    @Binding var up: Bool
    let peek: CGFloat
    @ViewBuilder let content: () -> Content
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let full: CGFloat = g.size.height
            let low: CGFloat = min(peek, full * 0.8)
            let high: CGFloat = full * 0.92
            let base: CGFloat = up ? high : low
            let h: CGFloat = min(full, max(low * 0.6, base - drag))
            sheet(height: h)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func sheet(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            handle
            ScrollView {
                content()
                    .padding(.horizontal, DS.s16)
                    .padding(.bottom, DS.s24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 28, style: .continuous)
                .fill(DS.page)
                .shadow(color: .black.opacity(0.18), radius: 12, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(DS.move, value: up)
    }

    private var handle: some View {
        Button {
            up.toggle()
        } label: {
            Capsule().fill(DS.legQuiet).frame(width: 40, height: 5)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($drag) { v, s, _ in s = v.translation.height }
                .onEnded { v in
                    let d: CGFloat = v.predictedEndTranslation.height
                    if d < -60 { up = true } else if d > 60 { up = false }
                }
        )
        .accessibilityLabel(up ? "Show less" : "Show more")
        .accessibilityHint("Pulls the sheet over the map up or down")
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

/// "‹ Friends": back to the list, floating over the map.
struct MapBackPill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.subheadline.weight(.bold))
                Text(title).font(DS.subStrong)
            }
            .foregroundStyle(DS.text)
            .padding(.horizontal, 14)
            .frame(minHeight: DS.hit)
            .background(DS.surface, in: Capsule())
            .dsFloat()
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel("Back to \(title)")
    }
}
