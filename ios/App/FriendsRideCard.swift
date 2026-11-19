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
                    // (0.31) the seat picker: your coach, and your window in it
                    RideSeatCard(tripId: v.tripId, station: trip.leg.flatMap { NSStore.code($0.from) }, line: Transit.trainLabel(v.line),
                                 towards: trip.leg?.to.short, friends: together.compactMap(mark))
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

    private func mark(_ s: FriendTravelSeen) -> SeatMark? {
        guard let c = s.state.coach else { return nil }
        return SeatMark(id: s.from, name: store.book?.friend(s.from)?.name ?? "A friend", coach: c)
    }

    private func togetherRow(_ s: FriendTravelSeen) -> some View {
        let name: String = store.book?.friend(s.from)?.name ?? "A friend"
        let coach: String = s.state.coach.map { " · \(SeatMap.label($0).lowercasedFirst)" } ?? ""
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

/// (0.31) The ride screen's seat picker: "Your seat", the train and its coaches, and your window (0.26's coach picker,
/// now down to the window).
struct RideSeatCard: View {
    let tripId: String
    /// The NS station you got on at (for its drawing and platform letters).
    let station: String?
    let line: String?
    let towards: String?
    var friends: [SeatMark] = []
    @ObservedObject private var share = FriendTravelShare.shared

    private var mine: TravelState.Coach? { share.coachTrip == tripId ? share.coach : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Your seat")
            if let m = mine {
                Text(SeatMap.label(m)).font(DS.subStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Tap your coach, then your window: friends on this trip see it, and friends who get on later know where to wait.")
                    .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TrainSeatPicker(tripId: tripId, station: station, line: line, towards: towards, friends: friends, editable: true)
        }
        .dsPanel()
    }
}
