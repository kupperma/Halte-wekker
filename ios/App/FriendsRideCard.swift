import SwiftUI

// Friends (0.26) on the ride screen: the one-time question (once you're on board), who sees this trip, friends on the
// same bus or train, and on a train the coach picker (tap your coach in NS's drawing). Only with friends: someone who
// never added one sees nothing of it.

struct RideFriendsCard: View {
    @EnvironmentObject var trip: TripManager
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var share = FriendTravelShare.shared
    @ObservedObject private var extras = FriendExtrasStore.shared
    @State private var asking = false

    var body: some View {
        if store.hasFriends && !trip.demo {
            VStack(alignment: .leading, spacing: DS.s12) {
                if share.needsAnswer { askNote }
                ForEach(together, id: \.from) { s in togetherRow(s) }
                // (0.29) delays on this trip's rides you share, your wait, and asking a friend to wait
                SharedDelaysCard(trips: extras.myTrips(), panel: false)
                MyWaitCard()
                if let w = extras.rideWaitTarget() { RideWaitMenu(stop: w.stop, ride: w.ride) }
                if let v = trip.vehicle, v.isTrain, !trip.waitingToBoard, trip.phase != .transfer {
                    CoachPicker(tripId: v.tripId, station: trip.leg.flatMap { NSStore.code($0.from) })
                }
                if store.sharingWith > 0 {
                    Label(store.sharingWith == 1 ? "1 friend sees this trip" : "\(store.sharingWith) friends see this trip",
                          systemImage: "person.2.fill")
                        .font(DS.footnote).foregroundStyle(DS.secondary)
                }
            }
            .sheet(isPresented: $asking) { TravelConsentSheet() }
        }
    }

    /// Friends on this same bus or train right now.
    private var together: [FriendTravelSeen] {
        guard let id = trip.vehicle?.tripId else { return [] }
        return store.travelling().filter { $0.state.trip == id && $0.state.stage == .riding }
    }

    private func togetherRow(_ s: FriendTravelSeen) -> some View {
        let name: String = store.book?.friend(s.from)?.name ?? "A friend"
        let coach: String = s.state.coach.map { " · \(CoachMap.label($0).lowercasedFirst)" } ?? ""
        return HStack(spacing: DS.s12) {
            FriendAvatar(name: name, id: s.from, picture: store.pictures[s.from], size: 36)
            Text("\(name) is on this \(trip.vehicle?.isTrain == true ? "train" : "bus") too\(coach)")
                .font(DS.subStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DS.s12)
        .background(DS.accentSoft, in: RoundedRectangle(cornerRadius: DS.inner(DS.cardRadius, padding: DS.s8), style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var askNote: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSNote(icon: "person.2.fill", tint: DS.accent, text: "Show this trip to your friends? Nothing is shared until you say so.")
            DSQuietButton(title: "Choose what friends see", icon: "hand.raised", full: true) { asking = true }
        }
    }
}

/// The train in NS's drawing, one button per coach: tap yours ("Coach 3 of 6 · front"); tap it again to take it away.
struct CoachPicker: View {
    let tripId: String
    /// The NS station you got on at (for its drawing and platform letters).
    let station: String?
    @ObservedObject private var share = FriendTravelShare.shared
    @State private var size: TrainSize?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Your coach", sub: mine.map(CoachMap.label))
            if let l = size?.layout, !spots(l).isEmpty {
                strip(l)
                Text(mine == nil ? "Tap the coach you’re in: friends on this trip see it, and friends who get on later know where to wait."
                                 : "Friends on this trip see it. Tap it again to take it away.")
                    .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !loaded {
                HStack(spacing: DS.s8) {
                    ProgressView().controlSize(.small)
                    Text("Getting the train’s drawing from NS…").font(DS.sub).foregroundStyle(DS.secondary)
                }
            } else {
                Text("NS hasn’t said how this train is made up, so there’s no coach to tap.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsPanel()
        .task(id: tripId) { await load() }
    }

    private var mine: TravelState.Coach? { share.coachTrip == tripId ? share.coach : nil }

    private func load() async {
        loaded = false
        defer { loaded = true }
        guard let station, let num = await share.number(tripId) else { return }
        size = await NSStore.shared.trainSize(num: num, code: station)
    }

    private func spots(_ l: TrainLayout) -> [CoachMap.Spot] { CoachMap.spots(l.coachUnits, totalCars: size?.cars ?? 0) }

    private func strip(_ l: TrainLayout) -> some View {
        let all: [CoachMap.Spot] = spots(l)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 3) {
                if l.dir == "left" { arrow("arrowtriangle.left.fill") }
                ForEach(all, id: \.drawn) { s in coachButton(s, all: all, l: l) }
                if l.dir == "right" { arrow("arrowtriangle.right.fill") }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l.dir == nil ? "The train’s coaches" : "The train’s coaches, the front first")
    }

    private func arrow(_ icon: String) -> some View {
        Image(systemName: icon).font(.caption2).foregroundStyle(DS.secondary)
            .frame(width: 12, height: 36)
            .accessibilityHidden(true)
    }

    private func coachButton(_ s: CoachMap.Spot, all: [CoachMap.Spot], l: TrainLayout) -> some View {
        let num = CoachMap.number(drawn: s.drawn, of: all.count, dir: l.dir)
        let c = TravelState.Coach(n: num.n, of: all.count, front: num.front, at: station)
        let picked: Bool = mine?.n == c.n
        let letter: String? = CoachMap.letter(at: s.mid, letters: l.coachLetters)
        let spoken: String = CoachMap.label(c) + (letter.map { ", near platform letter \($0)" } ?? "")
        return Button {
            share.setCoach(picked ? nil : c, trip: tripId)
        } label: {
            VStack(spacing: 3) {
                Text("\(c.n)").font(DS.footnoteStrong).monospacedDigit()
                    .foregroundStyle(picked ? DS.onAccent : DS.text)
                    .frame(width: 40, height: 30)
                    .background(picked ? DS.accent : DS.surface3, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(picked ? DS.accent : DS.legQuiet, lineWidth: 1))
                Text(letter ?? " ").font(.caption2.weight(.bold)).foregroundStyle(DS.secondary)
            }
            .frame(minHeight: DS.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityHint(picked ? "Takes it away" : "Marks it as your coach")
    }
}
