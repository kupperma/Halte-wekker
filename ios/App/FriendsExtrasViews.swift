import SwiftUI

// Friends extras (0.29) on screen: waits for you ("Sam is 2 min from the stop (300 m)", "I'll wait" / "Take the next
// one with you"), your own wait, "Wait for me" buttons, who's on campus, delays on shared rides, and the switches
// ("Show friends when I'm at school", "Tell Sam if I haven't left yet"). New look; follows the phone's light or dark.

// MARK: waits for you

/// Someone asks you to wait: how far they are (updating), and your answer.
struct WaitForYouCard: View {
    let seen: WaitSeen
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var extras = FriendExtrasStore.shared
    @ObservedObject private var chats = FriendChats.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { tl in
            content(now: tl.date)
        }
    }

    private var name: String { store.name(seen.from) }

    private func content(now: Date) -> some View {
        let stale: Bool = WaitAge.freshness(seen, now: now) == .stale
        let line: String = WaitWords.line(name, seen.wait, now: now)
        let detail: String = WaitWords.detail(name, seen.wait)
        let answer: WaitAnswer? = extras.myAnswer(to: seen)
        let group: FriendGroup? = ChatKey.groupId(seen.chat).flatMap { store.group($0) }
        return VStack(alignment: .leading, spacing: DS.s12) {
            HStack(alignment: .top, spacing: DS.s12) {
                FriendAvatar(name: name, id: seen.from, picture: store.pictures[seen.from], size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    if let g = group { Text("In \(g.name)").font(DS.footnote).foregroundStyle(DS.secondary) }
                    if stale { Text("Last update \(TravelWords.clock(seen.wait.at))").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary) }
                }
                .opacity(stale ? 0.7 : 1)
            }
            .accessibilityElement(children: .combine)
            if let answer {
                Label(answer == .wait ? "You said you’ll wait" : "You said: let’s take the next one together", systemImage: "checkmark.circle.fill")
                    .font(DS.subStrong).foregroundStyle(DS.accentText).fixedSize(horizontal: false, vertical: true)
            } else {
                actions
            }
        }
        .padding(DS.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.accentSoft, in: RoundedRectangle(cornerRadius: DS.inner(DS.cardRadius, padding: DS.s8), style: .continuous))
    }

    private var actions: some View {
        let finding: Bool = extras.findingNext == seen.wait.id
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.s8) {
                waitButton
                nextButton(finding)
            }
            VStack(spacing: DS.s8) {
                waitButton
                nextButton(finding)
            }
        }
    }

    private var waitButton: some View {
        Button { extras.willWait(seen) } label: {
            Text("I’ll wait").font(DS.subStrong).foregroundStyle(DS.onAccent)
                .padding(.horizontal, DS.s12)
                .frame(maxWidth: .infinity, minHeight: DS.hit)
                .background(DS.accent, in: Capsule())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityHint("Tells \(name) you’ll wait")
    }

    private func nextButton(_ finding: Bool) -> some View {
        Button { Task { await extras.takeNext(seen) } } label: {
            Text(finding ? "Finding the next one…" : "Take the next one with you").font(DS.subStrong).foregroundStyle(DS.accentText)
                .lineLimit(2).multilineTextAlignment(.center)
                .padding(.horizontal, DS.s12)
                .frame(maxWidth: .infinity, minHeight: DS.hit)
                .background(DS.surface, in: Capsule())
        }
        .buttonStyle(DSPressStyle())
        .disabled(finding)
        .accessibilityHint("Sends \(name) the next ride from that stop, to take together")
    }
}

/// On top of Friends: everyone asking you to wait now.
struct WaitsForYouPanel: View {
    @ObservedObject private var extras = FriendExtrasStore.shared

    var body: some View {
        let list: [WaitSeen] = extras.waitsForMe()
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: DS.s8) {
                DSHeader(title: "Waiting for you to wait", sub: "\(list.count)")
                ForEach(list, id: \.from) { w in WaitForYouCard(seen: w) }
            }
            .dsPanel()
        }
    }
}

// MARK: your wait

/// Your own wait: how far it says you are, who answered what, and "Stop asking".
struct MyWaitCard: View {
    /// Only this chat's (nil: any).
    var chat: String? = nil
    /// In a panel of its own (on Friends).
    var panel = false
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var extras = FriendExtrasStore.shared
    @ObservedObject private var chats = FriendChats.shared

    var body: some View {
        if let w = extras.myWait, chat == nil || chat == w.chat {
            if panel {
                VStack(alignment: .leading, spacing: DS.s8) {
                    DSHeader(title: "Your wait")
                    content(w)
                }
                .dsPanel()
            } else {
                content(w)
            }
        }
    }

    private func who(_ w: FriendExtrasStore.MyWait) -> String {
        if let gid = ChatKey.groupId(w.chat), let g = store.group(gid) { return g.name }
        return store.name(w.chat)
    }

    private func content(_ w: FriendExtrasStore.MyWait) -> some View {
        let answers: [String: WaitAnswer] = extras.answersToMine()
        let said: [String] = answers.sorted { $0.key < $1.key }.map { a in
            a.value == .wait ? "\(store.name(a.key)) will wait" : "\(store.name(a.key)): let’s take the next one"
        }
        let line: String = w.last.map { WaitWords.mine(who(w), $0) } ?? "Asking \(who(w)) to wait…"
        return VStack(alignment: .leading, spacing: DS.s8) {
            Label {
                Text(line).font(DS.subStrong).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "figure.walk").foregroundStyle(DS.accentText)
            }
            Text("At \(w.stop.name). Updates go out while you come closer (and the app checks in).")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(said, id: \.self) { s in
                Text(s).font(DS.subStrong).foregroundStyle(DS.accentText).fixedSize(horizontal: false, vertical: true)
            }
            DSQuietButton(title: "Stop asking", icon: "xmark.circle", full: true) { extras.stopWait() }
        }
        .padding(DS.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.inner(DS.cardRadius, padding: DS.s8), style: .continuous))
    }
}

/// "Wait for me": asks the chat's people to wait for you at `stop` (for `ride`). While you ask, it says so.
struct WaitForMeButton: View {
    let chat: String
    let stop: TripCard.Spot
    var ride: TripCard.Ride? = nil
    @ObservedObject private var extras = FriendExtrasStore.shared

    var body: some View {
        if extras.myWait?.chat == chat && extras.myWait?.stop.name == stop.name {
            Label("You asked them to wait", systemImage: "figure.walk")
                .font(DS.subStrong).foregroundStyle(DS.accentText)
                .frame(maxWidth: .infinity, minHeight: DS.hit, alignment: .leading)
        } else {
            DSQuietButton(title: "Wait for me", icon: "figure.walk", full: true) {
                extras.startWait(chat: chat, stop: stop, ride: ride)
            }
            .accessibilityHint("Sends how far you are from \(stop.name), updated while you come closer")
        }
    }
}

// MARK: who's on campus

/// "On campus now: Tom and Lisa", with since when.
struct CampusNowCard: View {
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var extras = FriendExtrasStore.shared

    var body: some View {
        let list: [FriendExtrasStore.OnCampus] = extras.onCampus()
        if !list.isEmpty {
            let names: [String] = list.map { store.name($0.id) }
            VStack(alignment: .leading, spacing: DS.s8) {
                Text(CampusWords.list(names)).font(DS.headline).foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                ForEach(list) { x in
                    HStack(spacing: DS.s12) {
                        FriendAvatar(name: store.name(x.id), id: x.id, picture: store.pictures[x.id], size: 32)
                        Text("\(store.name(x.id)) · \(CampusWords.since(x.state))").font(DS.sub).monospacedDigit().foregroundStyle(DS.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .dsPanel()
        }
    }
}

// MARK: delays

/// Delays on rides you share with friends (for 3 hours, until the ride is in).
struct SharedDelaysCard: View {
    /// Only these vehicles (nil: all).
    var trips: Set<String>? = nil
    var panel = true
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var extras = FriendExtrasStore.shared

    var body: some View {
        let now = Date()
        let list: [DelaySeen] = extras.delays.filter { d in
            d.delay.ride.arr > now && (trips?.contains(d.delay.ride.trip) ?? true)
        }
        if !list.isEmpty {
            let rows = VStack(alignment: .leading, spacing: DS.s8) {
                if panel { DSHeader(title: "Rides with friends") }
                ForEach(list, id: \.delay.ride.trip) { d in row(d) }
            }
            if panel { rows.dsPanel() } else { rows }
        }
    }

    private func row(_ d: DelaySeen) -> some View {
        let names: [String] = (d.delay.who ?? [d.from]).map { $0 == store.myAccount ? "you" : store.name($0) }
        let by: String? = d.from == store.myAccount ? nil : "From \(store.name(d.from)) at \(TravelWords.clock(d.got))"
        return VStack(alignment: .leading, spacing: 4) {
            Text(DelayWords.title(d.delay)).font(DS.subStrong).foregroundStyle(DS.warning).fixedSize(horizontal: false, vertical: true)
            Text(DelayWords.body(d.delay, names: names)).font(DS.sub).monospacedDigit().foregroundStyle(DS.text)
                .fixedSize(horizontal: false, vertical: true)
            if let by { Text(by).font(DS.footnote).foregroundStyle(DS.secondary) }
        }
        .padding(DS.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: DS.inner(DS.cardRadius, padding: DS.s8), style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: your switches

/// Friends › At school and the wake-up buddy: "Show friends when I'm at school" (off by default), and where the
/// buddy switch is.
struct ExtrasSwitchesCard: View {
    @EnvironmentObject private var trip: TripManager
    @ObservedObject private var extras = FriendExtrasStore.shared

    private var campusOn: Binding<Bool> {
        Binding(get: { extras.settings.campus == true }, set: { extras.setCampus($0) })
    }

    private var campusNote: String {
        if extras.settings.campus != true {
            return "Off. When on, friends see “At \(RoleWords.current.school) since 09:05” while you’re there: never where on campus, nothing once you leave, and gone after 10 hours."
        }
        if extras.campusShownTo > 0 {
            return extras.campusShownTo == 1 ? "1 friend sees you’re at school now." : "\(extras.campusShownTo) friends see you’re at school now."
        }
        return trip.locationAlways
            ? "Friends see it while you’re at \(RoleWords.current.school), from when you get there."
            : "With location set to “While Using”, it’s noticed when you open the app at school. “Always” notices it by itself."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "At school")
            Toggle(isOn: campusOn) {
                Text("Show friends when I’m at school").font(DS.bodyStrong).foregroundStyle(DS.text)
            }
            .tint(DS.accent)
            .frame(minHeight: DS.hit)
            Text(campusNote).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(DS.divider)
            Text("Wake-up buddy").font(DS.bodyStrong).foregroundStyle(DS.text)
            Text("On a friend’s page you can let them know when you haven’t left yet by your planned time (once a morning). Off for everyone until you turn it on.")
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(DS.divider)
            // (0.30) free time together: the morning note
            FreeNoteSwitch()
        }
        .dsPanel()
    }
}

/// On a friend's page: "Tell Sam if I haven't left yet" (off by default).
struct BuddySwitch: View {
    let friend: Friend
    @ObservedObject private var extras = FriendExtrasStore.shared

    private var on: Binding<Bool> {
        Binding(get: { extras.allowsBuddy(friend.id) }, set: { extras.setBuddy(friend.id, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Toggle(isOn: on) {
                Text("Tell \(friend.name) if I haven’t left yet").font(DS.bodyStrong).foregroundStyle(DS.text)
            }
            .tint(DS.accent)
            .frame(minHeight: DS.hit)
            Text(extras.allowsBuddy(friend.id)
                 ? "\(friend.name) sees when you plan to leave and your first ride (from your school alarm or timetable), and is told once a morning if you haven’t set off 5 minutes after that."
                 : "Off. When on, \(friend.name) is told once a morning if you haven’t set off 5 minutes after you planned to.")
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: on the ride screen

/// "Ask friends to wait": while you're on your way to the stop, to a friend (those on this ride first) or a group.
struct RideWaitMenu: View {
    let stop: TripCard.Spot
    var ride: TripCard.Ride? = nil
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var extras = FriendExtrasStore.shared

    struct Choice: Identifiable {
        var id: String
        var name: String
    }

    /// Friends on this ride or waiting at this stop first, then the rest; then your groups.
    private var choices: [Choice] {
        let friends: [Friend] = store.book?.sortedFriends ?? []
        let here: Set<String> = Set(store.travelling().filter { s in
            (ride != nil && s.state.trip == ride?.trip) || s.state.from.name == stop.name
        }.map(\.from))
        let first: [Choice] = friends.filter { here.contains($0.id) }.map { Choice(id: $0.id, name: $0.name) }
        let rest: [Choice] = friends.filter { !here.contains($0.id) }.map { Choice(id: $0.id, name: $0.name) }
        let groups: [Choice] = store.groups.current.map { Choice(id: ChatKey.group($0.id), name: $0.name) }
        return first + rest + groups
    }

    var body: some View {
        if extras.myWait == nil, !choices.isEmpty {
            Menu {
                ForEach(choices) { c in
                    Button(c.name) { extras.startWait(chat: c.id, stop: stop, ride: ride) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "figure.walk").font(.subheadline.weight(.semibold))
                    Text("Ask a friend to wait for me").font(DS.subStrong).lineLimit(2)
                }
                .foregroundStyle(DS.accentText)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: DS.hit)
                .background(DS.surface3, in: Capsule())
            }
            .accessibilityHint("Sends how far you are from \(stop.name), updated while you come closer")
        }
    }
}
