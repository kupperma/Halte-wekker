import SwiftUI

// Settings › More in the new look (0.21): trying it at home, the leaderboard and Before you nap. The same as
// `DemoSheet`, `LeaderboardView` and `TipsList` (the old look keeps those), in the phone's light or dark.

/// "Try it at home": what the demo shows, and the buttons to start it.
struct DemoSheetNew: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var near: NearMe
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 36

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    Text("A pretend trip from the bus stop nearest to you. It takes about four minutes, and nothing real is watched. Allow notifications to see them too, and lock your phone now and then to see the lock screen.")
                        .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: DS.s12) {
                        DSHeader(title: "What you’ll see")
                        step(1, "map.fill", "Fastest trip, hands-free", "The big map that follows by itself: you, the dotted walk to your stop, and the bus coming to it.")
                        step(2, "bell.badge.fill", "It tells you", "Time to go, the bus running late, then something faster: it switches to that one by itself.")
                        step(3, "bus.fill", "It notices you’re on", "When the bus reaches your stop it sees you’re on board, and the trip starts by itself.")
                        step(4, "circle.dashed", "The ride", "The countdown with the bus riding along, the stops, the speed, and the song you’re playing.")
                        step(5, "alarm.fill", "The alarm", "It rings 2 km before the stop and again at the stop. Hold to stop it.")
                        step(6, "checkmark.seal.fill", "You’re there", "And the end of the trip.")
                    }
                    .dsPanel()
                    VStack(spacing: DS.s12) {
                        DSPrimaryButton(title: "Start the whole demo", icon: "play.fill") { go(full: true) }
                        DSQuietButton(title: "Only the ride and the alarm", icon: "bus.fill", full: true) { go(full: false) }
                    }
                    Text("Stop it any time with the back button at the top, or Hold to end trip. Skip the waiting on the Fastest trip screen with “I’m on it”.")
                        .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Try it at home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { near.locate(force: true, ask: true) }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func step(_ n: Int, _ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.s12) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(DS.accentSoftText)
                .frame(width: min(icon, 48), height: min(icon, 48))
                .background(DS.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n). \(title)").font(DS.calloutStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                Text(text).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// As `DemoSheet.go`: the sheet closes first, then the pretend trip starts.
    private func go(full: Bool) {
        let here = near.position ?? trip.lastFix
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)        // the sheet closes first
            if full { withAnimation(.easeInOut(duration: 0.35)) { GoStore.shared.startDemo(near: here) } }
            else { trip.startDemo(from: here?.coordinate) }
        }
    }
}

/// Settings › Leaderboard: your trips by score, home or to Breda, this week or all time. (Off the corridor, 0.24: your
/// door-to-door trips between Home and School.)
struct LeaderboardScreenNew: View {
    @EnvironmentObject var scores: ScoreBook
    @ObservedObject private var friends = FriendStore.shared
    @State private var home = true
    @State private var week = true
    /// (0.30) Yours, or you and the friends who share their scores.
    @State private var withFriends = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s12) {
                if friends.hasFriends {
                    Picker("Whose", selection: $withFriends) { Text("You").tag(false); Text("With friends").tag(true) }.pickerStyle(.segmented)
                }
                if withFriends && friends.hasFriends { FriendsLeaderboardView() } else { mine }
            }
            .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
        }
        .background(DS.page.ignoresSafeArea())
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    @ViewBuilder private var mine: some View {
        let all = scores.trips.filter { $0.home == home }
        let list = Array(scores.board(home: home, week: week).prefix(10))
        let best = scores.bestThisWeek(home: home)
        VStack(spacing: DS.s8) {
            Picker("Direction", selection: $home) { Text("Home").tag(true); Text("To \(RoleWords.current.toSchoolWord)").tag(false) }.pickerStyle(.segmented)
            Picker("When", selection: $week) { Text("This week").tag(true); Text("All time").tag(false) }.pickerStyle(.segmented)
        }
        VStack(alignment: .leading, spacing: DS.s12) {
            if list.isEmpty {
                Text(all.isEmpty ? "No trips yet. Start the alarm for a trip and ride to your last stop. Each trip gets a score out of 500 here." : "No trips this week yet.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                if i > 0 { Divider().overlay(DS.divider) }
                row(i, t, best: t.id == best?.id)
            }
        }
        .dsPanel()
        Text(RoleWords.current.onCorridor
             ? "Time from starting the alarm until you reach your last stop, so waiting at the change counts. 500 means as fast as that route gets."
             : "Trips between home and \(RoleWords.current.school), from starting the alarm until your last stop, so waiting at a change counts. 500 means as fast as your fastest one so far.")
            .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.s4)
    }

    private func row(_ i: Int, _ t: TripScore, best: Bool) -> some View {
        HStack(spacing: DS.s12) {
            Text("\(i + 1)").font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.secondary).frame(minWidth: 22)
            DSGrade(grade: t.grade, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(t.mins.rounded())) min · \(t.score)/500").font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                Text("\(Fmt.when(t.at)) · \(DoorScore.label(t.route, school: RoleWords.current.school))").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            if best {
                Text("Best").font(DS.footnoteStrong).foregroundStyle(DS.accentSoftText)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(DS.accentSoft, in: Capsule())
                    .accessibilityLabel("Best this week")
            }
            Button { withAnimation(DS.quick) { scores.remove(t.id) } } label: {
                Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
                    .frame(width: DS.hit, height: DS.hit).contentShape(Rectangle())
            }
            .buttonStyle(DSPressStyle())
            .accessibilityLabel("Remove this trip")
        }
    }
}

/// Settings › Before you nap: the few things that make the alarm sure to wake you.
struct TipsScreenNew: View {
    static let tips = [
        "Set location to Always and keep Live Activities on, so it can follow you with the phone locked.",
        "Turn the volume up or wear earbuds. The alarm also rings in silent mode.",
        "Keep some battery: GPS uses a bit on long rides. Low Power Mode is fine.",
        "Run the test alarm once, in Settings.",
    ]
    var body: some View {
        List {
            Section {
                ForEach(Self.tips, id: \.self) { t in
                    Label {
                        Text(t).font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.accentText)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Before you nap")
        .navigationBarTitleDisplayMode(.inline)
    }
}
