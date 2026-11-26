import SwiftUI

// Friends (0.31, "Map first"): a friend's page. While they travel: their trip framed on the map (where they are,
// where they got on, where they get off; `MapFrame`), and on the page: their face and name, the line,
// where to and when, a chat button; the seat picker with their face in their window; their seat in words and where to
// wait; Compare, Ride along, Wait for me. Then everything the page had before (on campus, the test friend's controls,
// rides together, what they see, removing them). Not travelling: the same, without the map.
//
// (0.40.2) No map of its own any more (that was a second map with its own sheet, which a swipe couldn't leave): a page
// pushed in the Friends sheet, the back swipe as any page. Over the home map their trip is drawn there
// (`FriendsOnMap.focus`); opened from Settings, a small map of it heads the page.

struct FriendDetailView: View {
    let id: String
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var chats = FriendChats.shared
    @ObservedObject private var extras = FriendExtrasStore.shared
    @ObservedObject private var bot = TestFriendBot.shared
    @ObservedObject private var routes = FriendRoutes.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.friendsOverMap) private var overMap
    @State private var asking = false

    private var unread: Int { chats.unread(ChatKey.friend(id)) }

    /// Their trip now (nil: not travelling).
    private func travel(now: Date) -> FriendTravelSeen? {
        guard let t = store.travel[id], TravelAge.freshness(t, now: now) != .gone else { return nil }
        return t
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            page(now: tl.date)
        }
        // over the home map: their trip drawn there while this page is open
        .onAppear { FriendsOnMap.shared.focus = id }
        .onDisappear { if FriendsOnMap.shared.focus == id { FriendsOnMap.shared.focus = nil } }
        .task(id: store.travel[id]?.state.trip ?? "") {
            if let trip = store.travel[id]?.state.trip { await routes.load([trip]) }
        }
    }

    @ViewBuilder private func page(now: Date) -> some View {
        if let f = store.book?.friend(id) {
            plainPage(f, travel(now: now), now: now)
        } else {
            Text("Not a friend any more.").font(DS.sub).foregroundStyle(DS.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.page.ignoresSafeArea())
        }
    }

    // MARK: the page

    /// Their trip on a small map (Friends opened away from the home map): looked at, not moved (the page scrolls).
    @ViewBuilder private func tripMap(_ f: Friend, _ t: FriendTravelSeen, now: Date) -> some View {
        let s: TravelState = t.state
        let pts: [GeoPoint] = MapFrame.points(s)
        if !overMap && !pts.isEmpty {
            let pin: [FriendMapPin] = tripPin(f, t, now: now)
            let stops: [MapStop] = tripStops(s)
            FriendsLiveMap(pins: pin, frame: pts, stops: stops)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous))
                .allowsHitTesting(false)
        }
    }

    private func tripPin(_ f: Friend, _ t: FriendTravelSeen, now: Date) -> [FriendMapPin] {
        let s: TravelState = t.state
        guard let p = s.pos, let g = MapFrame.point(lat: p.lat, lon: p.lon) else { return [] }
        let stale: Bool = TravelAge.freshness(t, now: now) == .stale
        let ring: Color = DS.mode(train: s.isTrain, mode: s.mode, line: s.line ?? "")
        let label: String = "\(f.name), \(TravelWords.summary(s))"
        return [FriendMapPin(id: f.id, name: f.name, point: g, ring: ring, label: label, stale: stale, route: routes.route(s))]
    }

    private func tripStops(_ s: TravelState) -> [MapStop] {
        var stops: [MapStop] = []
        if let g = MapFrame.point(lat: s.from.lat, lon: s.from.lon) { stops.append(MapStop(id: "from", name: s.from.name, point: g)) }
        if let g = MapFrame.point(lat: s.to.lat, lon: s.to.lon) { stops.append(MapStop(id: "to", name: s.to.name, point: g)) }
        return stops
    }

    private func plainPage(_ f: Friend, _ t: FriendTravelSeen?, now: Date) -> some View {
        ScrollView {
            content(f, t, now: now)
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s16)
        }
        .background(DS.page.ignoresSafeArea())
        .navigationTitle(f.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: what's in it

    private func content(_ f: Friend, _ t: FriendTravelSeen?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            if let t { tripMap(f, t, now: now) }
            header(f, t?.state)
            if let t { tripPart(f, t, now: now) }
            actions(f, t?.state)
            // (0.29) on campus now
            if let c = extras.onCampus().first(where: { $0.id == f.id }) {
                DSNote(icon: "building.columns.fill", tint: DS.accent, text: CampusWords.since(c.state))
            }
            // (0.30.1) the test friend's buttons (its own "Remove" among them)
            if bot.isBot(f.id) { TestFriendControls() }
            // (0.30) the rides you shared, counted on this phone
            RidesTogetherCard(friend: f)
            FriendSeesCard(friend: f)
            if !bot.isBot(f.id) { removeButton(f) }
        }
    }

    private func header(_ f: Friend, _ s: TravelState?) -> some View {
        let ring: Color = s.map { DS.mode(train: $0.isTrain, mode: $0.mode, line: $0.line ?? "") } ?? Color.clear
        return HStack(spacing: DS.s12) {
            FriendAvatar(name: f.name, id: f.id, picture: store.pictures[f.id], size: 56)
                .overlay(Circle().stroke(ring, lineWidth: 3).padding(-3))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(f.name).font(DS.title).foregroundStyle(DS.text).lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if bot.isBot(f.id) { TestFriendTag() }
                }
                if let s {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let l = s.line { DSLinePill(line: l, train: s.isTrain, mode: s.mode) }
                        Text(TravelWords.headline(s)).font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Friends since \(FriendDates.day(f.since))").font(DS.sub).foregroundStyle(DS.secondary)
                }
            }
            Spacer(minLength: DS.s8)
            chatButton(f)
        }
    }

    private func chatButton(_ f: Friend) -> some View {
        NavigationLink(value: FriendsRoute.chat(ChatKey.friend(f.id))) {
            Image(systemName: "bubble.left.and.bubble.right.fill").font(.body.weight(.semibold))
                .foregroundStyle(DS.onAccent)
                .frame(width: 52, height: DS.hit)
                .background(DS.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text("\(unread)").font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.onAccent)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(DS.warning, in: Capsule())
                            .offset(x: 6, y: -6)
                    }
                }
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(unread > 0 ? "Message \(f.name), \(unread) new" : "Message \(f.name)")
    }

    @ViewBuilder private func tripPart(_ f: Friend, _ t: FriendTravelSeen, now: Date) -> some View {
        let s: TravelState = t.state
        VStack(alignment: .leading, spacing: DS.s12) {
            if let age = TravelWords.age(t, now: now) {
                Text(age).font(DS.footnote).monospacedDigit().foregroundStyle(DS.warning).fixedSize(horizontal: false, vertical: true)
            }
            details(s)
            if s.isTrain, let trip = s.trip, s.stage != .change {
                TrainSeatPicker(tripId: trip, num: s.num, station: station(s), line: s.line, towards: s.dest?.name ?? s.to.name,
                                friends: s.coach.map { [SeatMark(id: f.id, name: f.name, coach: $0)] } ?? [],
                                editable: FriendTravelShare.shared.boarding(tripId: trip) != nil, coaches: s.coach?.of ?? 0)
            }
            if let c = s.coach, s.isTrain { FriendCoachNote(coach: c, state: s, name: f.name) }
        }
        .opacity(TravelAge.freshness(t, now: now) == .stale ? 0.8 : 1)
    }

    @ViewBuilder private func details(_ s: TravelState) -> some View {
        let from: String = s.stage == .change ? "Changing at \(s.from.name)" : "From \(s.from.name)"
        let legs: String? = (s.legs ?? 1) > 1 ? "leg \(s.leg ?? 1) of \(s.legs ?? 1)" : nil
        let line: String = legs.map { "\(from) · \($0)" } ?? from
        VStack(alignment: .leading, spacing: 2) {
            Text(line).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = TravelWords.ending(s) {
                Text(e).font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The NS station whose drawing the picker uses: theirs (the coach's), yours when you take this train, else the
    /// station nearest where they got on.
    private func station(_ s: TravelState) -> String? {
        if let at = s.coach?.at, !at.isEmpty { return at }
        if let id = s.trip, let mine = FriendTravelShare.shared.boarding(tripId: id) { return mine }
        guard let p = MapFrame.point(lat: s.from.lat, lon: s.from.lon) else { return nil }
        return NearestStation.pick(p, in: NSCodes.shared.stations, within: 600)?.code
    }

    // MARK: the buttons

    private func actions(_ f: Friend, _ s: TravelState?) -> some View {
        let card: TripCard? = s.flatMap { TripTake.rideAlong($0, now: Date()) }
        let waitStop: TripCard.Spot? = s.flatMap { st -> TripCard.Spot? in
            guard st.stage != .riding, let lat = st.from.lat, let lon = st.from.lon else { return nil }
            return TripCard.Spot(name: st.from.name, lat: lat, lon: lon)
        }
        return VStack(alignment: .leading, spacing: DS.s8) {
            HStack(spacing: DS.s8) {
                NavigationLink(value: FriendsRoute.compare(ChatKey.friend(f.id))) {
                    FriendsTile(icon: "calendar", title: "Compare")
                }
                .buttonStyle(DSPressStyle())
                .accessibilityHint("Classes side by side this week and next, rides together and meet halfway")
                if let card { RideAlongTile(card: card, name: f.name) }
                if let waitStop { WaitForMeTile(chat: ChatKey.friend(f.id), stop: waitStop) }
            }
        }
    }

    private func removeButton(_ f: Friend) -> some View {
        DSQuietButton(title: "Remove \(f.name)", icon: "person.badge.minus", full: true) { asking = true }
            .confirmationDialog("Remove \(f.name)?", isPresented: $asking, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task { await store.remove(f.id) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Their keys go from this phone and the boxes between you from the relay. \(f.name)’s app forgets you too.")
            }
    }
}

/// "Ride along": their bus or train as your trip (`TripTaker`, as "Take this trip" in a chat does).
struct RideAlongTile: View {
    let card: TripCard
    let name: String
    @EnvironmentObject private var trip: TripManager
    @EnvironmentObject private var near: NearMe
    @EnvironmentObject private var planner: Planner
    @EnvironmentObject private var go: GoStore
    @State private var busy = false
    @State private var said: String?

    var body: some View {
        Button { take() } label: {
            FriendsTile(icon: busy ? "hourglass" : "tram.fill", title: busy ? "Finding…" : "Ride along")
        }
        .buttonStyle(DSPressStyle())
        .disabled(busy)
        .accessibilityHint("Plans your way onto \(name)’s bus or train")
        .alert("Ride along", isPresented: Binding(get: { said != nil }, set: { if !$0 { said = nil } })) {
            Button("OK", role: .cancel) { said = nil }
        } message: {
            Text(said ?? "")
        }
    }

    private func take() {
        busy = true
        Task {
            let out = await TripTaker.take(card, trip: trip, near: near, planner: planner, go: go)
            busy = false
            switch out {
            case .watching, .plan: break
            case .planned(let s): said = s
            case .cant(let s): said = s
            }
        }
    }
}

/// "Wait for me" as a tile (0.29's `WaitForMeButton`): asks them to wait for you at their stop.
struct WaitForMeTile: View {
    let chat: String
    let stop: TripCard.Spot
    @ObservedObject private var extras = FriendExtrasStore.shared

    private var asked: Bool { extras.myWait?.chat == chat && extras.myWait?.stop.name == stop.name }

    var body: some View {
        Button {
            if !asked { extras.startWait(chat: chat, stop: stop, ride: nil) }
        } label: {
            FriendsTile(icon: "hand.raised.fill", title: asked ? "Asked to wait" : "Wait for me")
        }
        .buttonStyle(DSPressStyle())
        .disabled(asked)
        .accessibilityHint("Sends how far you are from \(stop.name), updated while you come closer")
    }
}
