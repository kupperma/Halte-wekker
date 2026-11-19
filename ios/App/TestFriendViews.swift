import SwiftUI

// Test friend (0.30.1) on screen: its "TEST" tag, its controls on its page, and adding or removing it (Settings ›
// Friends, and the empty friend list). New look; follows the phone's light or dark.

/// "TEST" beside the test friend's name, wherever it shows.
struct TestFriendTag: View {
    static let colour = Color(red: 0.42, green: 0.27, blue: 0.85)

    var body: some View {
        Text("TEST")
            .font(.caption2.weight(.heavy))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Self.colour, in: Capsule())
            .accessibilityLabel("Test friend, a bot on this phone")
    }
}

/// "Add a test friend" (or, once there is one, what it is and "Remove test friend").
struct TestFriendAddCard: View {
    @ObservedObject private var bot = TestFriendBot.shared
    @ObservedObject private var store = FriendStore.shared
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            if bot.exists {
                Text("Your test friend is a bot on this phone: a real second friends account that answers through the relay, so you can try chats, groups, trips, timetables and the extras. Its controls are on its page.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                if let n = bot.note { DSNote(icon: "testtube.2", tint: TestFriendTag.colour, text: n) }
                DSQuietButton(title: "Remove test friend", icon: "person.badge.minus", full: true) { asking = true }
                    .disabled(bot.working)
            } else {
                Text("No friends on the app yet? Add a test friend: a bot on this phone with its own account, to try every Friends feature with. It never goes in your backup.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                if let n = bot.note { DSNote(icon: "exclamationmark.triangle.fill", text: n) }
                DSQuietButton(title: bot.working ? "Adding…" : "Add a test friend", icon: "testtube.2", full: true) {
                    Task { await bot.add() }
                }
                .disabled(bot.working || !store.hasAccount)
            }
        }
        .confirmationDialog("Remove the test friend?", isPresented: $asking, titleVisibility: .visible) {
            Button("Remove test friend", role: .destructive) { Task { await bot.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It leaves the relay, and its chat and everything it sent go from this phone.")
        }
    }
}

/// On the test friend's page: one tap, one box (or a short pretend run), through the relay like a real friend's.
struct TestFriendControls: View {
    @ObservedObject private var bot = TestFriendBot.shared
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false

    private var travelTitle: String {
        if bot.trip != nil { return "Stop pretending to travel" }
        return bot.working ? "Finding a bus or train…" : "Pretend I’m travelling"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            HStack(spacing: DS.s8) {
                DSHeader(title: "Test friend controls")
                TestFriendTag()
            }
            Text("Each button makes the test friend send what a friend’s phone would: it arrives with the next check (at once here).")
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            if let n = bot.note { DSNote(icon: "testtube.2", tint: TestFriendTag.colour, text: n) }
            DSQuietButton(title: travelTitle, icon: "tram.fill", full: true) { Task { await bot.pretendTravel() } }
                .disabled(bot.working)
            DSQuietButton(title: "Ask you to wait for me", icon: "hand.raised.fill", full: true) { Task { await bot.askToWait() } }
            DSQuietButton(title: bot.campus ? "Pretend I’ve left campus" : "Pretend I’m on campus", icon: "building.columns.fill", full: true) {
                Task { await bot.toggleCampus() }
            }
            DSQuietButton(title: "Share scores", icon: "trophy.fill", full: true) { Task { await bot.shareScores() } }
            DSQuietButton(title: "Pretend we rode together", icon: "person.2.fill", full: true) { Task { await bot.pretendRodeTogether() } }
            DSQuietButton(title: "Wake-up buddy: pretend I haven’t left", icon: "alarm.fill", full: true) { Task { await bot.buddyNotLeft() } }
            Text("It shares a timetable near yours and the station nearest your Home by itself. The wake-up buddy tells you once a day, and not when it pretended to travel or wait in the last hour.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(DS.divider)
            DSQuietButton(title: "Remove test friend", icon: "person.badge.minus", full: true) { asking = true }
        }
        .dsPanel()
        .confirmationDialog("Remove the test friend?", isPresented: $asking, titleVisibility: .visible) {
            Button("Remove test friend", role: .destructive) {
                Task { await bot.remove() }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It leaves the relay, and its chat and everything it sent go from this phone.")
        }
    }
}

/// Settings › Friends: "Add a test friend" / "Remove test friend".
struct TestFriendSettingsRow: View {
    @ObservedObject private var bot = TestFriendBot.shared
    @State private var asking = false

    private var title: String {
        if bot.exists { return "Remove test friend" }
        return bot.working ? "Adding a test friend…" : "Add a test friend"
    }

    var body: some View {
        Button {
            if bot.exists { asking = true } else { Task { await bot.add() } }
        } label: {
            HStack {
                Label(title, systemImage: "testtube.2")
                Spacer()
                if bot.exists { TestFriendTag() }
            }
        }
        .disabled(bot.working)
        .confirmationDialog("Remove the test friend?", isPresented: $asking, titleVisibility: .visible) {
            Button("Remove test friend", role: .destructive) { Task { await bot.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It leaves the relay, and its chat and everything it sent go from this phone.")
        }
    }
}
