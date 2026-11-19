import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Friends extras, part B (0.30) on screen: free time together today, the live link for people without the app, rides
// together on a friend's page, and the friends leaderboard. New look; follows the phone's light or dark.

// MARK: free hours together

/// Friends: "Today: you and Sam are both free 12:00–13:30" (from the shared timetables), while there's some to come.
struct FreeTodayCard: View {
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var together = FriendTogetherStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { tl in
            content(now: tl.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let list: [FreeTodaySlot] = together.freeNow(now: now)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: DS.s8) {
                DSHeader(title: "Free together today")
                ForEach(Array(list.enumerated()), id: \.offset) { _, s in row(s, now: now) }
            }
            .dsPanel()
        }
    }

    private func row(_ s: FreeTodaySlot, now: Date) -> some View {
        let names: [String] = s.with.map { store.name($0) }
        let first: String = s.with.first ?? ""
        return HStack(spacing: DS.s12) {
            FriendAvatar(name: names.first ?? "", id: first, picture: store.pictures[first], size: 32)
            Text(FreeToday.line(s, names: names, now: now)).font(DS.sub).monospacedDigit().foregroundStyle(DS.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: the live link

/// "Share a live link": on the ride screen and in Friends. While a link is shared: send it again, or stop it.
struct LiveLinkCard: View {
    /// In Friends, lower down: only a line, when no trip runs and nothing is shared (where a link is made).
    var idleNote = false
    @EnvironmentObject private var trip: TripManager
    @ObservedObject private var live = LiveLinkStore.shared
    @State private var making = false
    @State private var asking = false

    private var running: Bool { FriendTravelShare.running(trip) && !trip.demo }

    var body: some View {
        Group {
            if idleNote {
                if live.link == nil && !running {
                    Label("On a trip, you can share a live link with someone who doesn’t have the app, like a parent.", systemImage: "link")
                        .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DS.s4)
                }
            } else if let l = live.link {
                shared(l, l.keys.link)
            } else if running {
                makeButton
            }
        }
        .sheet(isPresented: $making) { LiveLinkSheet() }
    }

    private var makeButton: some View {
        Button { making = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.subheadline.weight(.semibold))
                Text("Share a live link").font(DS.subStrong).lineLimit(2)
            }
            .foregroundStyle(DS.accentText)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: DS.hit)
            .background(DS.surface3, in: Capsule())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityHint("A web page with this trip’s live times, for someone without the app")
    }

    private func shared(_ l: LiveLinkStore.Link, _ link: String) -> some View {
        let until: String = l.exp.map { TimetableDays.hhmm($0) } ?? ""
        let text: String = l.arrived
            ? "The page says you’ve arrived\(until.isEmpty ? "" : " until \(until)"), then the link ends."
            : "Anyone with the link sees this trip live: what you’re on, where you are and when you arrive. It ends when you arrive or end the trip (at most 4 hours)."
        return VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: l.arrived ? "Live link · arrived" : "Live link", sub: l.name)
            Text(text).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.s8) {
                    sendButton(link)
                    LiveLinkCopyButton(link: link)
                }
                VStack(spacing: DS.s8) {
                    sendButton(link)
                    LiveLinkCopyButton(link: link)
                }
            }
            stopButton
        }
        .dsPanel()
        .confirmationDialog("Stop sharing the live link?", isPresented: $asking, titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) { live.stop() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The page says the link has ended, at once.")
        }
    }

    /// (0.30.1) The link goes as text: a link handed over as a link can come back without its key (the part after #).
    private func sendButton(_ link: String) -> some View {
        ShareLink(item: LiveWords.shareText(link), subject: Text("My trip, live")) {
            Label("Send the link", systemImage: "square.and.arrow.up").font(DS.subStrong)
                .foregroundStyle(DS.onAccent)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: DS.hit)
                .background(DS.accent, in: Capsule())
        }
    }

    private var stopButton: some View {
        Button { asking = true } label: {
            Label("Stop sharing", systemImage: "xmark.circle").font(DS.subStrong)
                .foregroundStyle(DS.accentText)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: DS.hit)
                .background(DS.surface3, in: Capsule())
        }
        .buttonStyle(DSPressStyle())
    }
}

/// (0.30.1) "Copy link": the whole link on the clipboard, as text and as a link, to paste into any app.
struct LiveLinkCopyButton: View {
    let link: String
    var big = false
    @State private var copied = false

    var body: some View {
        Button {
            var item: [String: Any] = [UTType.plainText.identifier: link]
            if let u = URL(string: link) { item[UTType.url.identifier] = u }
            UIPasteboard.general.items = [item]
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(big ? DS.bodyStrong : DS.subStrong)
                .foregroundStyle(DS.accentText)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: big ? DS.cta : DS.hit)
                .background(DS.surface3, in: Capsule())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityHint("Puts the whole link on the clipboard, to paste in any app")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}

/// Making a live link: what the page shows and for how long, your name on it, then sending it.
struct LiveLinkSheet: View {
    @ObservedObject private var live = LiveLinkStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var made: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    Image(systemName: "link")
                        .font(.title2.weight(.semibold)).foregroundStyle(DS.onAccent)
                        .frame(width: 56, height: 56).background(DS.accent, in: Circle())
                        .accessibilityHidden(true)
                    Text("Share a live link").font(DS.title).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
                    point("safari", "A web page for someone without the app, like a parent: “\(shownName) is on bus 305 to Den Bosch · arrives 07:51 · 3 min late”, with a small map.")
                    point("flag.checkered", "It says “Arrived” at your last stop, and ends when the trip does (at most 4 hours), or when you stop it.")
                    point("lock.fill", "Locked with a key that is only in the link: the Haltewekker relay can’t read it. Anyone you send the link to can.")
                    if let made {
                        DSNote(icon: "checkmark.circle.fill", tint: DS.accent, text: "Your link is ready. Send it, then put the phone away: it updates by itself on the ride.")
                        let link: String = live.link?.keys.link ?? made.absoluteString
                        ShareLink(item: LiveWords.shareText(link), subject: Text("My trip, live")) {
                            Label("Send the link", systemImage: "square.and.arrow.up").font(DS.bodyStrong)
                                .foregroundStyle(DS.onAccent)
                                .frame(maxWidth: .infinity, minHeight: DS.cta)
                                .background(DS.accent, in: Capsule())
                        }
                        LiveLinkCopyButton(link: link, big: true)
                        DSQuietButton(title: "Done", full: true) { dismiss() }
                    } else {
                        TextField("Your name on the page", text: $name)
                            .font(DS.body)
                            .textContentType(.givenName)
                            .padding(.horizontal, DS.s16).frame(minHeight: 52)
                            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                            .accessibilityLabel("Your name on the page")
                        if let p = live.problem { DSNote(icon: "exclamationmark.triangle.fill", text: p) }
                        DSPrimaryButton(title: live.making ? "Making the link…" : "Make the link", icon: "link") { make() }
                            .disabled(live.making || FriendNames.clean(name).isEmpty)
                            .opacity(FriendNames.clean(name).isEmpty ? 0.5 : 1)
                    }
                }
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Live link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(made == nil ? "Cancel" : "Close") { dismiss() } } }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .followsSystemScheme()
        .onAppear { if name.isEmpty { name = live.defaultName } }
    }

    private var shownName: String {
        let n: String = FriendNames.clean(name)
        return n.isEmpty ? "Sam" : n
    }

    private func make() {
        Task {
            if let u = await live.make(name: name) { made = u }
        }
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.s12) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(DS.accentText)
                .frame(width: 22).accessibilityHidden(true)
            Text(text).font(DS.sub).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: rides together

/// A friend's page: "You rode together 14 times this month", and the last rides (counted on this phone).
struct RidesTogetherCard: View {
    let friend: Friend
    @ObservedObject private var together = FriendTogetherStore.shared

    var body: some View {
        let last: [RideTogether] = together.last(with: friend.id)
        if !last.isEmpty {
            VStack(alignment: .leading, spacing: DS.s8) {
                DSHeader(title: "Rides together")
                Text(RideHistoryWords.month(together.count(with: friend.id))).font(DS.bodyStrong).foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(last) { r in
                    Text(RideHistoryWords.row(r)).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Counted on this phone when you’re on the same bus or train: \(friend.name)’s trip is on it, or you’re both in on a trip card.")
                    .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.s4)
            }
            .dsPanel()
        }
    }
}

// MARK: the friends leaderboard

/// Friends › Leaderboard, and the leaderboard's "Friends" side: you and the friends who share their scores.
struct FriendsLeaderboardView: View {
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var together = FriendTogetherStore.shared
    @ObservedObject private var extras = FriendExtrasStore.shared
    @ObservedObject private var scores = ScoreBook.shared
    @State private var month = true

    private var shareOn: Binding<Bool> {
        Binding(get: { extras.settings.scores == true }, set: { extras.setShareScores($0) })
    }

    var body: some View {
        let now = Date()
        let people: [ScoresPerson] = together.boardPeople(now: now)
        let m: String = ScoresRules.month(now)
        let groups: [ScoreGroup] = ScoreBoard.groups(people, month: month ? m : nil)
        let rides: [RidesRow] = ScoreBoard.rides(people, month: m)
        VStack(alignment: .leading, spacing: DS.s12) {
            switchPanel
            Picker("When", selection: $month) { Text("This month").tag(true); Text("All time").tag(false) }.pickerStyle(.segmented)
            if groups.isEmpty {
                Text(scores.trips.isEmpty
                     ? "No trips yet. Start the alarm for a trip and ride to your last stop: your fastest per route shows here, next to friends who share theirs."
                     : "No trips this month yet.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    .dsPanel()
            }
            ForEach(groups) { g in groupPanel(g) }
            if !rides.isEmpty { ridesPanel(rides) }
        }
    }

    private var switchPanel: some View {
        let n: Int = together.sharingCount
        let note: String = extras.settings.scores == true
            ? "Your friends see your fastest trip per route and how many rides you shared this month."
            : "Off. When on, your friends see your fastest trip per route and how many rides you shared this month."
        let who: String = n == 0 ? "No friend shares theirs yet." : n == 1 ? "1 friend shares theirs." : "\(n) friends share theirs."
        return VStack(alignment: .leading, spacing: DS.s8) {
            Toggle(isOn: shareOn) {
                Text("Share my scores").font(DS.bodyStrong).foregroundStyle(DS.text)
            }
            .tint(DS.accent)
            .frame(minHeight: DS.hit)
            Text("\(note) \(who)").font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .dsPanel()
    }

    private func title(_ g: ScoreGroup) -> String {
        switch g.route {
        case DoorScore.toSchool: return "Home → school"
        case DoorScore.toHome: return "School → home"
        default: return g.route + (g.home ? " · home" : " · to school")
        }
    }

    private func name(_ id: String) -> String { id == "me" ? "You" : store.name(id) }

    private func groupPanel(_ g: ScoreGroup) -> some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            DSHeader(title: title(g), sub: g.rows.count == 1 ? "1 person" : "\(g.rows.count) people")
            ForEach(Array(g.rows.enumerated()), id: \.element.who) { i, r in
                if i > 0 { Divider().overlay(DS.divider) }
                scoreRow(i, r, many: g.rows.count > 1)
            }
        }
        .dsPanel()
    }

    private func scoreRow(_ i: Int, _ r: ScoreRow, many: Bool) -> some View {
        let mins: Int = Int(r.mins.rounded())
        return HStack(spacing: DS.s12) {
            Text("\(i + 1)").font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.secondary).frame(minWidth: 22)
            FriendAvatar(name: name(r.who), id: r.who, picture: r.who == "me" ? store.myPicture : store.pictures[r.who], size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name(r.who)) · \(mins) min").font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Fmt.when(r.at)).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
            }
            Spacer(minLength: 4)
            // (a badge only when there's someone to be faster than)
            if i == 0 && many {
                Text("Fastest").font(DS.footnoteStrong).foregroundStyle(DS.accentSoftText)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(DS.accentSoft, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func ridesPanel(_ rows: [RidesRow]) -> some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            DSHeader(title: "Most rides together this month")
            ForEach(Array(rows.enumerated()), id: \.element.who) { i, r in
                HStack(spacing: DS.s12) {
                    Text("\(i + 1)").font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.secondary).frame(minWidth: 22)
                    FriendAvatar(name: name(r.who), id: r.who, picture: r.who == "me" ? store.myPicture : store.pictures[r.who], size: 32)
                    Text("\(name(r.who)) · \(r.n == 1 ? "1 ride" : "\(r.n) rides")").font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Rides with any friend on the same bus or train, as each phone counted them.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .dsPanel()
    }
}

/// Friends › Leaderboard.
struct FriendsLeaderboardScreen: View {
    var body: some View {
        ScrollView {
            FriendsLeaderboardView()
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
        }
        .background(DS.page.ignoresSafeArea())
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Friends: the leaderboard with friends (and who shares).
struct FriendsTogetherCard: View {
    @ObservedObject private var together = FriendTogetherStore.shared
    @ObservedObject private var extras = FriendExtrasStore.shared

    var body: some View {
        let n: Int = together.sharingCount
        let sub: String = extras.settings.scores == true
            ? (n == 1 ? "You and 1 friend share your scores" : "You and \(n) friends share your scores")
            : (n == 1 ? "1 friend shares their scores" : "\(n) friends share their scores")
        NavigationLink(value: FriendsRoute.leaderboard) {
            HStack(spacing: DS.s12) {
                Image(systemName: "trophy.fill").font(.body.weight(.semibold)).foregroundStyle(DS.accentText)
                    .frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leaderboard with friends").font(DS.bodyStrong).foregroundStyle(DS.text)
                    Text(sub).font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsPanel(padding: DS.s12)
    }
}

/// Friends › At school: the morning note about free time together (off by default).
struct FreeNoteSwitch: View {
    @ObservedObject private var extras = FriendExtrasStore.shared

    private var on: Binding<Bool> {
        Binding(get: { extras.settings.free == true }, set: { extras.setFreeNote($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Toggle(isOn: on) {
                Text("Tell me in the morning when we’re free together").font(DS.bodyStrong).foregroundStyle(DS.text)
            }
            .tint(DS.accent)
            .frame(minHeight: DS.hit)
            Text(extras.settings.free == true
                 ? "Once a morning (when the app checks in between 06:00 and 11:00): “You and Sam are both free 12:00–13:30”, from the timetables friends share. It’s on Friends all day either way."
                 : "Off. Free time together today is on Friends either way, from the timetables friends share.")
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
