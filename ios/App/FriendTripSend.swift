import CoreLocation
import SwiftUI

// Friends (0.27): sending a trip (Fastest trip, Plan, a Be there by plan, the friend's train) to a friend or a group,
// and "Take this trip" on the other phone. The rules are `TripTake` (tested); this is the planner and the screens.

/// A planner's trip as a card, and back.
enum TripCards {
    private static func spot(_ p: Place) -> TripCard.Spot {
        // Home (and where you are) never go as a place: only the name
        if p.key == Place.home.key || p.key == RoleLogic.homeKey { return TripCard.Spot(name: "Home") }
        if p.key == "here" { return TripCard.Spot(name: "Where I am") }
        return TripCard.Spot(name: p.short, lat: p.coordinate.latitude, lon: p.coordinate.longitude)
    }

    static func ride(_ r: Ride) -> TripCard.Ride {
        var c = TripCard.Ride(mode: r.isTrain ? "train" : "bus", line: r.line, trip: r.tripId,
                              from: TripCard.Spot(name: r.fromStop, id: r.fromId.isEmpty ? nil : r.fromId, lat: r.fromLat, lon: r.fromLon),
                              to: TripCard.Spot(name: r.toStop, lat: r.toLat, lon: r.toLon),
                              dep: r.departure, arr: r.arrival)
        c.name = r.name.isEmpty || r.name == r.line ? nil : r.name
        c.num = r.num.isEmpty ? nil : r.num
        c.head = r.headsign.isEmpty ? nil : r.headsign
        c.sdep = r.scheduledDeparture == r.departure ? nil : r.scheduledDeparture
        c.sarr = r.scheduledArrival == r.arrival ? nil : r.scheduledArrival
        c.plat = r.platform
        c.walk = r.walkBefore > 0 ? r.walkBefore : nil
        return c
    }

    /// `to`: where it goes (Home goes as a name; the last stop says where), `by`: a "be there by".
    static func card(_ t: DoorTrip, to: Place?, from: Place? = nil, by: Date? = nil) -> TripCard {
        let rides = Array(t.rides.prefix(TripCard.maxRides)).map(ride)
        let dest: TripCard.Spot
        if let to {
            dest = spot(to)
        } else {
            let l = t.last
            dest = TripCard.Spot(name: Fmt.place(l.toStop), lat: l.toLat, lon: l.toLon)
        }
        // (Home goes as a name only: the friend plans to the last stop)
        return TripCard(rides: rides, to: dest, from: from.map(spot), start: t.start, end: t.end, by: by)
    }

    static func ride(_ c: TripCard.Ride) -> Ride {
        Ride(tripId: c.trip, line: c.line, name: c.name ?? c.line, isTrain: c.mode != "bus", departure: c.dep,
             scheduledDeparture: c.sdep ?? c.dep, arrival: c.arr, scheduledArrival: c.sarr ?? c.arr,
             fromStop: c.from.name, fromId: c.from.id ?? c.from.point.map { "\($0.lat),\($0.lon)" } ?? c.from.name,
             toStop: c.to.name, platform: c.plat, live: false, cancelled: false, walkBefore: c.walk ?? 0,
             num: c.num ?? "", headsign: c.head ?? "", plannedPlatform: c.plat,
             fromLat: c.from.lat, fromLon: c.from.lon, toLat: c.to.lat, toLon: c.to.lon)
    }

    static func door(_ c: TripCard) -> DoorTrip? {
        let rides = c.rides.map(ride)
        guard let f = rides.first, let l = rides.last else { return nil }
        let start = c.start ?? f.departure.addingTimeInterval(-Double(f.walkBefore) * 60)
        return DoorTrip(rides: rides, start: min(start, f.departure), end: max(c.end ?? l.arrival, l.arrival))
    }

    /// Where the card goes, as a place to plan to: your School or Home when it's there, else its spot (or the last stop).
    static func destination(_ c: TripCard) -> (place: Place, name: String)? {
        let spot = c.to.point != nil ? c.to : (c.rides.last?.to ?? c.to)
        guard let p = spot.point else { return nil }
        let here = CLLocation(latitude: p.lat, longitude: p.lon)
        for (pl, name) in [(Place.school, RoleWords.current.school), (Place.home, "Home")] {
            if here.distance(from: CLLocation(latitude: pl.coordinate.latitude, longitude: pl.coordinate.longitude)) < TripTake.samePlaceMetres {
                return (pl, name)
            }
        }
        let name = c.to.point != nil ? c.to.name : Fmt.place(spot.name)
        let d = Destination(id: spot.id ?? "\(p.lat),\(p.lon)", name: name, lat: p.lat, lon: p.lon)
        return (d.place, name)
    }
}

/// "Take this trip": the card becomes your plan (`TripTake.way`): Fastest trip with it as your pick (from where you
/// are: the same rides, or your own way onto the friend's bus or train), a Be there by plan, or Plan filled in.
@MainActor
enum TripTaker {
    enum Outcome: Equatable {
        /// Fastest trip opened with it (Friends closes).
        case watching
        /// A Be there by plan was made (the words say what).
        case planned(String)
        /// Plan opens with it filled in (Friends closes).
        case plan
        /// It can't be taken (the words say why).
        case cant(String)
    }

    static func take(_ c: TripCard, trip: TripManager, near: NearMe, planner: Planner, go: GoStore) async -> Outcome {
        guard trip.phase == .idle else { return .cant("Finish the trip you’re on first.") }
        guard let dest = TripCards.destination(c) else { return .cant("This trip doesn’t say where it goes.") }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam") ?? .current
        let home = GeoPoint(lat: Place.home.coordinate.latitude, lon: Place.home.coordinate.longitude)
        let school = GeoPoint(lat: Place.school.coordinate.latitude, lon: Place.school.coordinate.longitude)
        switch TripTake.way(c, now: Date(), home: home, school: school, calendar: cal) {
        case .gone:
            return .cant("That bus or train has left already.")
        case .fastest:
            let here: CLLocation? = near.position ?? trip.lastFix
            let you: GeoPoint? = here.map { GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
            if let door = await mine(c, you: you, dest: dest.place) {
                FriendStore.shared.showing = false
                try? await Task.sleep(nanoseconds: 450_000_000)
                let label: String? = c.by.map { "\(dest.name) by \(Fmt.hhmm($0))" }
                withAnimation(.easeInOut(duration: 0.35)) {
                    go.open(to: dest.place, from: here, deadline: c.by, label: label, seed: [door], chosen: door)
                }
                return .watching
            }
            openPlan(c, dest: dest)
            return .plan
        case .beThereBy(let out, let tomorrow):
            guard let by = TripTake.deadline(c) else { openPlan(c, dest: dest); return .plan }
            let prefer = TripTake.shared(c).map { [$0.trip] }
            if planner.setArrive(out: out, time: by, tomorrow: tomorrow, prefer: prefer) != nil {
                // (too soon, or passed: Plan, filled in)
                openPlan(c, dest: dest)
                return .plan
            }
            let day = tomorrow ? "tomorrow" : "today"
            return .planned("Planned: be at \(dest.name) by \(Fmt.hhmm(by)) \(day), on your friend’s ride when it fits. You get a reminder ten minutes before you have to leave (Plan › More ways › Be there by).")
        case .plan:
            openPlan(c, dest: dest)
            return .plan
        }
    }

    /// Plan, filled in: where to and "there by" the card's time.
    private static func openPlan(_ c: TripCard, dest: (place: Place, name: String)) {
        let req = FriendStore.PlanRequest(to: dest.place, name: dest.name, arriveBy: TripTake.deadline(c), leaveAt: nil)
        FriendStore.shared.showing = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            FriendStore.shared.planRequest = req
        }
    }

    /// Your way: the card's rides if you start where the sender does; else a way from you that has their bus or
    /// train (the planner's, or onto it at the stop of its route nearest you). Nil: none found.
    private static func mine(_ c: TripCard, you: GeoPoint?, dest: Place) async -> DoorTrip? {
        guard let shared = TripTake.shared(c) else { return nil }
        if you == nil || TripTake.sameStart(c, you: you) { return TripCards.door(c) }
        guard let you else { return nil }
        let start = Place.here(CLLocationCoordinate2D(latitude: you.lat, longitude: you.lon))
        let by = TripTake.deadline(c) ?? shared.arr
        // 1. the planner from you to there: an option with their ride
        let ways = await Transit.$urgent.withValue(true) { () async -> [DoorTrip] in
            await Transit.plan(from: start, to: dest, modes: nil, at: by, count: 6, maxTransfers: 4, arriveBy: true)
        }
        if let i = TripTake.pick(ways.map { $0.rides.map(\.tripId) }, card: c) { return ways[i] }
        // 2. onto their ride at a stop of its route near you, with your own way there
        guard let stops = await Transit.boardStops(shared.trip, maxAge: 120) else { return nil }
        let from = shared.from.point
        guard let board = BoardAt.boardingIndex(stops, fromId: shared.from.id ?? "", from: from, departure: shared.dep),
              let alight = BoardAt.alightingIndex(stops, after: board, to: shared.to.point, toName: shared.to.name) else { return nil }
        let sharedRide = TripCards.ride(shared)
        let after: [Ride] = Array(c.rides.dropFirst(TripTake.sharedIndex(c) + 1)).map(TripCards.ride)
        for i in TripTake.boardCandidates(stops, board: board, alight: alight, you: you, now: Date()) {
            let s = stops[i]
            guard let dep = s.departure else { continue }
            let walkOnly = Geo.metres(you, s.point) < 900
            if walkOnly {
                let walk = BoardAt.walkMinutes(metres: Geo.metres(you, s.point))
                let r = sharedRide.boarding(at: s, walk: walk)
                return DoorTrip(rides: [r] + after, start: dep.addingTimeInterval(-Double(walk) * 60), end: c.end ?? (after.last ?? r).arrival)
            }
            let stopPlace = Place(key: "s:\(s.id)", name: s.name, short: Fmt.place(s.name), ids: s.id.isEmpty ? ["\(s.point.lat),\(s.point.lon)"] : [s.id],
                                  coordinate: CLLocationCoordinate2D(latitude: s.point.lat, longitude: s.point.lon), spoken: Fmt.place(s.name))
            let ins = await Transit.plan(from: start, to: stopPlace, modes: nil, at: dep.addingTimeInterval(-120), count: 4, maxTransfers: 3, arriveBy: true)
            guard let way = ins.filter({ $0.end <= dep.addingTimeInterval(-60) }).max(by: { $0.start < $1.start }) else { continue }
            let r = sharedRide.boarding(at: s, walk: way.walkAfter)
            let rides = way.rides + [r] + after
            return DoorTrip(rides: Array(rides.prefix(TripCard.maxRides)), start: way.start, end: c.end ?? (after.last ?? r).arrival)
        }
        return nil
    }
}

// MARK: sending

/// "Send to a friend" under a trip: opens the picker (only with friends).
struct SendTripButton: View {
    let make: () -> TripCard?
    var full = true
    @ObservedObject private var store = FriendStore.shared
    @State private var card: TripCard?

    var body: some View {
        if store.hasFriends {
            DSQuietButton(title: "Send to a friend", icon: "paperplane", full: full) { card = make() }
                .accessibilityHint("Sends this trip to a friend or a group, as a card they can take")
                .sheet(item: Binding(get: { card.map(IdentifiedCard.init) }, set: { card = $0?.card })) { c in
                    SendTripSheet(card: c.card)
                }
        }
    }
}

struct IdentifiedCard: Identifiable {
    let card: TripCard
    var id: String { card.rides.map(\.trip).joined(separator: "+") + "\(card.by?.timeIntervalSince1970 ?? 0)" }
}

/// Pick who gets the trip (friends and groups), add a line if you like, send.
struct SendTripSheet: View {
    let card: TripCard
    /// (0.28) Who's picked to begin with (a chat key: from a friend's or a group's compare screen).
    var preselect: Set<String> = []
    @ObservedObject private var store = FriendStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var note = ""
    @State private var sent: Int?

    private var groups: [FriendGroup] { store.groups.current }
    private var friends: [Friend] { store.book?.sortedFriends ?? [] }
    private var isGroupOnly: Bool { !picked.isEmpty && picked.allSatisfy(ChatKey.isGroup) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    TripCardBody(card: card, group: isGroupOnly, compact: true)
                        .dsPanel()
                    noteField
                    if !groups.isEmpty { groupList }
                    friendList
                    Text("It arrives when they open Haltewekker (there are no notifications), or on their next trip.")
                        .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { sendBar }
            .navigationTitle("Send this trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .followsSystemScheme()
        .onAppear { if picked.isEmpty, !preselect.isEmpty { picked = preselect } }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Your line", sub: "optional")
            TextField(TripCardWords.headline(card, now: Date(), group: isGroupOnly), text: $note, axis: .vertical)
                .font(DS.body)
                .lineLimit(1...3)
                .padding(.horizontal, DS.s12).padding(.vertical, 10)
                .frame(minHeight: DS.hit)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                .accessibilityLabel("Your line on the card")
        }
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: DS.s4) {
            DSHeader(title: "Groups")
            ForEach(groups) { g in
                row(key: ChatKey.group(g.id), name: g.name, id: "g-\(g.id)", picture: store.groupPictures[g.id],
                    detail: "\(g.roster.members.count) people")
            }
        }
        .dsPanel()
    }

    private var friendList: some View {
        VStack(alignment: .leading, spacing: DS.s4) {
            DSHeader(title: "Friends")
            ForEach(friends) { f in
                row(key: ChatKey.friend(f.id), name: f.name, id: f.id, picture: store.pictures[f.id], detail: nil)
            }
        }
        .dsPanel()
    }

    private func row(key: String, name: String, id: String, picture: Data?, detail: String?) -> some View {
        let on: Bool = picked.contains(key)
        return Button {
            if on { picked.remove(key) } else { picked.insert(key) }
        } label: {
            FriendRowLabel(name: name, id: id, picture: picture, detail: detail ?? "") {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on ? DS.accentText : DS.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var sendBar: some View {
        VStack(spacing: DS.s8) {
            if let n = sent {
                Text(n > 0 ? "Sent." : "Couldn’t send it.").font(DS.subStrong).foregroundStyle(n > 0 ? DS.accentText : DS.warning)
            }
            DSPrimaryButton(title: picked.isEmpty ? "Pick who gets it" : "Send", icon: "paperplane.fill") { send() }
                .disabled(picked.isEmpty || sent != nil)
                .opacity(picked.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, DS.s16).padding(.vertical, DS.s8)
        .background(DS.page.ignoresSafeArea(edges: .bottom))
    }

    private func send() {
        var c = card
        let line = ChatText.clean(note)
        c.note = line.isEmpty ? nil : line
        let keys: [String] = Array(picked).sorted()
        let n = FriendChats.shared.sendTrip(c, to: keys)
        sent = n
        if n > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                dismiss()
            }
        }
    }
}
