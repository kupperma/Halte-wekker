import MapKit
import SwiftUI

// Friends (0.26): a friend's coach and where to wait for it, your own "Show my trips" switches and the one-time screen
// that explains them. Follows the phone's light or dark.

extension TrainLayout {
    /// The units as the coach sums take them.
    var coachUnits: [CoachMap.Unit] { units.map { CoachMap.Unit(x: $0.x, w: $0.w, cars: $0.cars) } }
    var coachLetters: [(letter: String, x: Double)] { letters.map { (letter: $0.letter, x: $0.x) } }
}

// (0.31) The list, the map and a friend's trip are now the Friends map (FriendsMapViews.swift, FriendsScreen.swift)
// and the friend's page (FriendPage.swift).

// MARK: a friend's trip

/// A friend's coach: "Sam is in coach 3 of 6 · upper deck · 8th window from the back" (0.31; 0.26: "coach 3 of 6 ·
/// front"); "Taking this train too?" and, on the same train as you, which end of the platform to wait at.
struct FriendCoachNote: View {
    let coach: TravelState.Coach
    let state: TravelState
    let name: String
    @ObservedObject private var share = FriendTravelShare.shared
    @State private var hint: String?
    /// (0.31.1) Their coach or window is in 1st class (from the train's drawing at the station they gave).
    @State private var firstClass = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(name) is in \(SeatMap.label(coach, firstClass: firstClass).lowercasedFirst)")
                .font(DS.subStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint).font(DS.sub).foregroundStyle(DS.accentText).fixedSize(horizontal: false, vertical: true)
            } else if coach.front {
                Text("Taking this train too? Coach \(coach.n) from the front.").font(DS.sub).foregroundStyle(DS.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .task(id: "\(state.trip ?? "")|\(coach.n)") { await findHint() }
        .task(id: "\(state.trip ?? "")|\(coach.n)|\(coach.seat?.deck ?? "")|\(coach.seat?.w ?? 0)") { await findClass() }
    }

    /// (0.31.1) Whether their pick is in 1st class: NS's drawing of the train at the station their coach is counted at.
    private func findClass() async {
        guard let id = state.trip, let at = coach.at, !at.isEmpty else { firstClass = false; return }
        var num: String? = state.num
        if num == nil { num = await share.number(id) }
        guard let num, !num.isEmpty, let size = await NSStore.shared.trainSize(num: num, code: at) else { return }
        let t: SeatMap.Train = TrainSize.seatTrain(size, line: state.line, coaches: coach.of)
        firstClass = t.fromNS && SeatMap.isFirst(coach, in: t, station: at)
    }

    /// On the same train as you (your trip has it, still to board or on board): where its coach stops at your station.
    private func findHint() async {
        guard let id = state.trip, let code = share.boarding(tripId: id) else { hint = nil; return }
        var num: String? = state.num
        if num == nil { num = await share.number(id) }
        guard let num, !num.isEmpty, let size = await NSStore.shared.trainSize(num: num, code: code), let l = size.layout else { return }
        let h = CoachMap.platformHint(coach, units: l.coachUnits, totalCars: size.cars, letters: l.coachLetters, dir: l.dir, station: code)
        hint = h.map { "Taking this train too? \($0)." }
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
