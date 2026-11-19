import MapKit
import SwiftUI

// Friends (0.26): friends travelling now (the list on top of Friends, a map with their pictures, a friend's trip),
// your own "Show my trips" switches and the one-time screen that explains them. Follows the phone's light or dark.

extension TrainLayout {
    /// The units as the coach sums take them.
    var coachUnits: [CoachMap.Unit] { units.map { CoachMap.Unit(x: $0.x, w: $0.w, cars: $0.cars) } }
    var coachLetters: [(letter: String, x: Double)] { letters.map { (letter: $0.letter, x: $0.x) } }
}

// MARK: the list

/// Friends travelling now, on top of Friends: a map of where they are, and a row each.
struct FriendsTravellingCard: View {
    let list: [FriendTravelSeen]
    @ObservedObject private var store = FriendStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Travelling now", sub: "\(list.count)")
            if list.contains(where: { $0.state.pos != nil }) {
                FriendsTravelMap(list: list)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: DS.inner(DS.cardRadius, padding: DS.s8), style: .continuous))
            }
            ForEach(list, id: \.from) { s in
                NavigationLink { FriendDetailView(id: s.from) } label: { row(s) }
                    .buttonStyle(.plain)
                if s.from != list.last?.from { Divider().overlay(DS.divider) }
            }
        }
        .dsPanel()
    }

    private func row(_ s: FriendTravelSeen) -> some View {
        let name: String = store.book?.friend(s.from)?.name ?? "Friend"
        return FriendTravelRow(seen: s, name: name, picture: store.pictures[s.from])
    }
}

/// "Sam" and "IC 3512 to Breda · arrives 08:43" (greyed with "Last update 08:41" when it's a little old).
struct FriendTravelRow: View {
    let seen: FriendTravelSeen
    let name: String
    let picture: Data?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            content(now: tl.date)
        }
    }

    private static func spoken(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: ". ") }

    private func content(now: Date) -> some View {
        let s = seen.state
        let stale: Bool = TravelAge.freshness(seen, now: now) == .stale
        let summary: String = TravelWords.summary(s)
        let age: String? = TravelWords.age(seen, now: now)
        return HStack(spacing: DS.s12) {
            FriendAvatar(name: name, id: seen.from, picture: picture)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(2)
                Text(summary).font(DS.sub).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                if let age { Text(age).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary) }
            }
            .opacity(stale ? 0.6 : 1)
            Spacer(minLength: DS.s8)
            if let l = s.line { DSLinePill(line: l, train: s.isTrain) }
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
        }
        .padding(.vertical, DS.s8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken([name, summary, age]))
        .accessibilityHint("Shows \(name)’s trip")
    }
}

// MARK: the map

/// Friends' pictures where they are (and, for one friend, where they got on and get off).
struct FriendsTravelMap: View {
    let list: [FriendTravelSeen]
    var showStops = false
    @ObservedObject private var store = FriendStore.shared
    @State private var camera: MapCameraPosition = .automatic

    struct Pin: Identifiable {
        let id: String
        let name: String
        let label: String
        let coordinate: CLLocationCoordinate2D
        let train: Bool
        let stale: Bool
    }

    struct Stop: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    private var pins: [Pin] {
        let now = Date()
        return list.compactMap { s -> Pin? in
            guard let p = s.state.pos else { return nil }
            let name: String = store.book?.friend(s.from)?.name ?? "Friend"
            return Pin(id: s.from, name: name, label: "\(name), \(TravelWords.summary(s.state))",
                       coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), train: s.state.isTrain,
                       stale: TravelAge.freshness(s, now: now) == .stale)
        }
    }

    private var stops: [Stop] {
        guard showStops, let s = list.first?.state else { return [] }
        var out: [Stop] = []
        let ends: [(String, TravelState.Spot)] = [("from", s.from), ("to", s.to)]
        for (k, spot) in ends {
            if let lat = spot.lat, let lon = spot.lon {
                out.append(Stop(id: k, name: spot.name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
            }
        }
        return out
    }

    private var key: String { pins.map { "\($0.id)\($0.coordinate.latitude)\($0.coordinate.longitude)" }.joined() }

    var body: some View {
        Map(position: $camera) {
            ForEach(stops) { s in
                Marker(s.name, systemImage: s.id == "to" ? "flag.fill" : "circle.fill", coordinate: s.coordinate)
                    .tint(s.id == "to" ? DS.accent : DS.legQuiet)
            }
            ForEach(pins) { p in
                Annotation(p.name, coordinate: p.coordinate, anchor: .center) { pin(p) }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .onChange(of: key) { _, _ in camera = .automatic }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pins.isEmpty ? "Map" : "Map of friends travelling now")
    }

    private func pin(_ p: Pin) -> some View {
        FriendAvatar(name: p.name, id: p.id, picture: store.pictures[p.id], size: 38)
            .overlay(Circle().stroke(DS.mode(train: p.train), lineWidth: 3))
            .overlay(Circle().stroke(Color.white, lineWidth: 1).padding(-2))
            .opacity(p.stale ? 0.55 : 1)
            .dsFloat()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(p.label)
    }
}

// MARK: a friend's trip

/// A friend's trip right now, on their page: what they're on, to where and when, the map, their coach.
struct FriendTripCard: View {
    let seen: FriendTravelSeen
    let name: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            content(now: tl.date)
        }
    }

    private func content(now: Date) -> some View {
        let s = seen.state
        let age: String = TravelWords.age(seen, now: now) ?? "Updated \(TravelWords.clock(seen.sent))"
        return VStack(alignment: .leading, spacing: DS.s12) {
            DSHeader(title: "On the way now", sub: age)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let l = s.line { DSLinePill(line: l, train: s.isTrain) }
                Text(TravelWords.summary(s)).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            details(s)
            if s.pos != nil {
                FriendsTravelMap(list: [seen], showStops: true)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: DS.inner(DS.cardRadius, padding: DS.s8), style: .continuous))
            }
            if let c = s.coach, s.isTrain { FriendCoachNote(coach: c, state: s, name: name) }
        }
        .opacity(TravelAge.freshness(seen, now: now) == .stale ? 0.75 : 1)
        .dsPanel()
    }

    @ViewBuilder private func details(_ s: TravelState) -> some View {
        let from: String = s.stage == .change ? "Changing at \(s.from.name)" : "From \(s.from.name)"
        let legs: String? = (s.legs ?? 1) > 1 ? "leg \(s.leg ?? 1) of \(s.legs ?? 1)" : nil
        let line: String = legs.map { "\(from) · \($0)" } ?? from
        Text(line).font(DS.sub).foregroundStyle(DS.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let e = TravelWords.ending(s) {
            Text(e).font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A friend's coach: "Coach 3 of 6 · front"; on the same train as you, which end of the platform to wait at.
struct FriendCoachNote: View {
    let coach: TravelState.Coach
    let state: TravelState
    let name: String
    @ObservedObject private var share = FriendTravelShare.shared
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(name) is in \(CoachMap.label(coach).lowercasedFirst)", systemImage: "tram.fill")
                .font(DS.subStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint).font(DS.sub).foregroundStyle(DS.accentText).fixedSize(horizontal: false, vertical: true)
            } else if coach.front {
                Text("Taking this train too? Coach \(coach.n) from the front.").font(DS.sub).foregroundStyle(DS.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.inner(DS.cardRadius, padding: DS.s8), style: .continuous))
        .accessibilityElement(children: .combine)
        .task(id: "\(state.trip ?? "")|\(coach.n)") { await findHint() }
    }

    /// On the same train as you (your trip has it, still to board or on board): where its coach stops at your station.
    private func findHint() async {
        guard let id = state.trip, let code = share.boarding(tripId: id) else { hint = nil; return }
        var num: String? = state.num
        if num == nil { num = await share.number(id) }
        guard let num, !num.isEmpty, let size = await NSStore.shared.trainSize(num: num, code: code), let l = size.layout else { return }
        let h = CoachMap.platformHint(coach, units: l.coachUnits, totalCars: size.cars, letters: l.coachLetters, dir: l.dir, station: code)
        hint = h.map { "You’re on this train too: \($0.lowercasedFirst)." }
    }
}

extension String {
    var lowercasedFirst: String { String(prefix(1)).lowercased() + String(dropFirst()) }
}

// MARK: your switches

/// Friends › Your trips: the switch for everyone, and what friends see right now.
struct MyTripsCard: View {
    @ObservedObject private var store = FriendStore.shared
    let explain: () -> Void

    private var on: Binding<Bool> {
        Binding(get: { store.travelAnswered && !store.travelPaused },
                set: { v in if store.travelAnswered { store.setTravelPaused(!v) } else { store.answerTravel(show: v) } })
    }

    private var status: String {
        if !store.travelAnswered { return "Off until you say yes. Friends would see your trip only while one runs and you’re on board." }
        if store.travelPaused { return "Paused: no friend sees your trips." }
        let n = store.sharingWith
        if n > 0 { return n == 1 ? "1 friend sees this trip now." : "\(n) friends see this trip now." }
        return "Friends see your trip only while one runs and you’re on board. Nothing when no trip runs."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Your trips")
            Toggle(isOn: on) {
                Text("Show my trips to friends").font(DS.bodyStrong).foregroundStyle(DS.text)
            }
            .tint(DS.accent)
            .frame(minHeight: DS.hit)
            Text(status).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: explain) {
                Text("What friends see").font(DS.subStrong).foregroundStyle(DS.accentText)
                    .frame(minHeight: DS.hit).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .dsPanel()
    }
}

/// The one-time screen: what friends see of a trip and when, with the switch right there.
struct TravelConsentSheet: View {
    @ObservedObject private var store = FriendStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var show = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    Image(systemName: "location.north.line.fill")
                        .font(.title2.weight(.semibold)).foregroundStyle(DS.onAccent)
                        .frame(width: 56, height: 56).background(DS.accent, in: Circle())
                        .accessibilityHidden(true)
                    Text("Show friends your trips?").font(DS.title).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
                    point("tram.fill", "While a trip runs and you’re on board (the app found your bus or train, you picked it, or you started the trip yourself), your friends see what you’re on (like IC 3512), where you got on and get off, where you are on the map, when you arrive, and your coach if you mark it.")
                    point("moon.zzz.fill", "Nothing when no trip runs. It stops when you arrive or end the trip, and an update that doesn’t come is gone within minutes.")
                    point("lock.fill", "Locked end to end for each friend: nobody else can read it, not even the Haltewekker relay.")
                    point("person.crop.circle.badge.checkmark", "Turn it off for one friend on their page, or for everyone in Friends, at any time.")
                    Toggle(isOn: $show) {
                        Text("Show my trips to friends").font(DS.bodyStrong).foregroundStyle(DS.text)
                    }
                    .tint(DS.accent)
                    .frame(minHeight: DS.hit)
                    .padding(.horizontal, DS.s16).padding(.vertical, DS.s4)
                    .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                    DSPrimaryButton(title: "Done") {
                        store.answerTravel(show: show)
                        dismiss()
                    }
                }
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Your trips")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .followsSystemScheme()
        .interactiveDismissDisabled(!store.travelAnswered)
        .onAppear { show = store.travelAnswered ? !store.travelPaused : true }
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.s12) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(DS.accentText)
                .frame(width: 22).accessibilityHidden(true)
            Text(text).font(DS.sub).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
