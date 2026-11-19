import SwiftUI

// Friends (0.25): the friend list, requests waiting, and adding someone. Opened from the home (Next trip first's
// bar, Live around you's round button) and from Settings › Friends. Follows the phone's light or dark.

struct FriendsScreen: View {
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var chats = FriendChats.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var sheet: Sheet?
    @State private var confirmDelete = false
    @State private var pasteWrong = false
    @State private var path: [FriendsRoute] = []

    enum Sheet: String, Identifiable {
        case myCode, scan, create, restore, backup, profile, travel, newGroup, timetable
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s12) {
                    if store.movedAway { movedNote }
                    if store.hasAccount { accountContent } else { FriendsIntroCard(make: { sheet = .create }, restore: { sheet = .restore }) }
                }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .refreshable { await store.sync(.now) }
            .navigationDestination(for: FriendsRoute.self) { r in destination(r) }
        }
        // (0.27) a chat to open (a notification tapped, a friend's "Message")
        .onChange(of: chats.toOpen, initial: true) { _, k in openChat(k) }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .followsSystemScheme()
        // while this is open and the app in front: a look at the relay every 30 s (nothing when it's closed)
        .task(id: scene == .active) {
            guard scene == .active else { return }
            await store.sync(.now)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                await store.sync(.screen)
            }
        }
        .sheet(item: $sheet) { s in sheetView(s) }
        // (0.26) with the first friend, once: what friends see of your trips, and the switch
        .task(id: store.book?.friends.count ?? 0) { await askAboutTripsOnce() }
        // (0.28) then, once: what friends see of your timetable, and the switch
        .task(id: "\(store.book?.friends.count ?? 0)|\(store.travelAnswered)|\(sheet == nil)") { await askAboutTimetableOnce() }
        .sheet(item: $store.opened) { code in FriendAddSheet(code: code) }
        .confirmationDialog("Delete your friends account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete my friends account", role: .destructive) { Task { await store.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your friends are told, the relay forgets your account, and your backup code stops working.")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .topBarLeading) {
            if store.hasAccount {
                Menu {
                    Button { sheet = .profile } label: { Label("Name and picture", systemImage: "person.crop.circle") }
                    Button { sheet = .backup } label: { Label("Backup code", systemImage: "key") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete my friends account", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(minWidth: DS.hit, minHeight: DS.hit)
                }
                .accessibilityLabel("Your friends account")
            }
        }
    }

    @ViewBuilder private func sheetView(_ s: Sheet) -> some View {
        switch s {
        case .myCode: MyFriendCodeSheet().presentationDetents([.large])
        case .scan: ScanFriendSheet(found: { code in openLater(code) })
        case .create: FriendCreateSheet()
        case .restore: FriendRestoreSheet()
        case .backup: FriendBackupSheet()
        case .profile: FriendProfileSheet()
        case .travel: TravelConsentSheet()
        case .newGroup: NewGroupSheet(made: { id in openLaterChat(ChatKey.group(id)) })
        case .timetable: TimetableConsentSheet()
        }
    }

    @ViewBuilder private func destination(_ r: FriendsRoute) -> some View {
        switch r {
        case .friend(let id): FriendDetailView(id: id)
        case .chat(let key): FriendChatView(key: key)
        case .group(let id): GroupInfoView(id: id)
        case .compare(let key): CompareView(key: key)
        case .compareDay(let key, let day): CompareDayView(key: key, dayKey: day)
        }
    }

    private func openChat(_ k: String?) {
        guard let k else { return }
        chats.toOpen = nil
        path = [.chat(k)]
    }

    private func openLaterChat(_ k: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            path = [.chat(k)]
        }
    }

    private func askAboutTripsOnce() async {
        guard store.hasFriends, !store.travelAnswered else { return }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard store.hasFriends, !store.travelAnswered, sheet == nil, store.opened == nil else { return }
        sheet = .travel
    }

    private func askAboutTimetableOnce() async {
        guard store.hasFriends, store.travelAnswered, !FriendTimetables.shared.answered, sheet == nil else { return }
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard store.hasFriends, store.travelAnswered, !FriendTimetables.shared.answered, sheet == nil, store.opened == nil else { return }
        sheet = .timetable
    }

    /// (after the scanner's sheet has gone, so the next one can come up)
    private func openLater(_ code: FriendStore.OpenedCode) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            store.opened = code
        }
    }

    private var movedNote: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSNote(icon: "iphone.slash", text: "Your friends account was restored on another phone, so this one was signed out. To use it here again, restore it with your backup code (that signs the other phone out).")
            DSQuietButton(title: "OK", action: { store.dismissMoved() })
        }
    }

    // MARK: with an account

    @ViewBuilder private var accountContent: some View {
        if let b = store.book {
            let moving: [FriendTravelSeen] = store.travelling()
            if !moving.isEmpty { FriendsTravellingCard(list: moving) }
            // (0.29) waits for you, your own wait, who's on campus, delays on rides you share
            WaitsForYouPanel()
            MyWaitCard(panel: true)
            CampusNowCard()
            SharedDelaysCard()
            meCard(b)
            if !b.incoming.isEmpty { requestsCard(b.incoming) }
            if !b.friends.isEmpty { FriendChatsCard(newGroup: { sheet = .newGroup }) }
            if !b.friends.isEmpty { MyTripsCard(explain: { sheet = .travel }) }
            if !b.friends.isEmpty { MyTimetableCard(explain: { sheet = .timetable }) }
            if !b.friends.isEmpty { ExtrasSwitchesCard() }
            friendsCard(b.sortedFriends)
            if !b.outgoing.isEmpty { waitingCard(b.outgoing) }
            addCard
            statusLine
        }
    }

    private func meCard(_ b: FriendBook) -> some View {
        Button { sheet = .profile } label: {
            FriendRowLabel(name: b.myName.isEmpty ? "You" : b.myName, id: "me", picture: store.myPicture,
                           detail: "You · tap to change your name and picture") {
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsPanel(padding: DS.s12)
    }

    private func requestsCard(_ list: [FriendRequest]) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Want to be friends", sub: "\(list.count)")
            ForEach(list) { r in FriendRequestRow(request: r, picture: store.pictures[r.id]) }
        }
        .dsPanel()
    }

    private func friendsCard(_ list: [Friend]) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Your friends", sub: list.isEmpty ? nil : "\(list.count)")
            if list.isEmpty {
                Text("No friends yet. Show a friend your code, or send them your link.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(list) { f in
                NavigationLink(value: FriendsRoute.friend(f.id)) {
                    FriendRowLabel(name: f.name, id: f.id, picture: store.pictures[f.id], detail: friendLine(f)) {
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if f.id != list.last?.id { Divider().overlay(DS.divider) }
            }
        }
        .dsPanel()
    }

    /// Under a friend's name: what they're on now, else since when you're friends (and whether they see your trips).
    private func friendLine(_ f: Friend) -> String {
        if let t = store.travel[f.id], TravelAge.freshness(t, now: Date()) != .gone { return TravelWords.summary(t.state) }
        let since = "Friends since \(FriendDates.day(f.since))"
        return f.showsTrips ? since : since + " · doesn’t see your trips"
    }

    private func waitingCard(_ list: [FriendRequest]) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Waiting for an answer")
            ForEach(list) { r in
                FriendRowLabel(name: r.name, id: r.id, picture: store.pictures[r.id],
                               detail: "Asked \(FriendDates.day(r.at)) · arrives when \(r.name) opens Haltewekker") {
                    Button("Cancel") { Task { await store.cancel(r.id) } }
                        .font(DS.subStrong).foregroundStyle(DS.accentText)
                        .frame(minWidth: DS.hit, minHeight: DS.hit)
                        .accessibilityLabel("Cancel the request to \(r.name)")
                }
            }
        }
        .dsPanel()
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Add a friend")
            Text("Together, show your code and let them scan it. Apart, send your link through any chat app.")
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            DSQuietButton(title: "Show my code", icon: "qrcode", full: true) { sheet = .myCode }
            DSQuietButton(title: "Scan a code", icon: "qrcode.viewfinder", full: true) { sheet = .scan }
            if let link = store.shareLink {
                ShareLink(item: link, subject: Text("My Haltewekker friend code"), message: Text("Add me as a friend in Haltewekker")) {
                    shareLabel
                }
                .buttonStyle(DSPressStyle())
            }
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in paste(strings.first ?? "") }
            }
            .buttonBorderShape(.capsule)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, minHeight: DS.hit)
            .accessibilityHint("Adds a friend from a link you copied")
            if pasteWrong {
                Text("That isn’t a Haltewekker friend link.").font(DS.footnote).foregroundStyle(DS.warning)
            }
        }
        .dsPanel()
    }

    private var shareLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.arrow.up").font(.subheadline.weight(.semibold))
            Text("Send my link").font(DS.subStrong).lineLimit(2)
        }
        .foregroundStyle(DS.accentText)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: DS.hit)
        .background(DS.surface3, in: Capsule())
    }

    private func paste(_ text: String) {
        if let c = FriendLink.parse(text) {
            pasteWrong = false
            store.opened = FriendStore.OpenedCode(card: c.card, name: c.name)
        } else {
            pasteWrong = true
        }
    }

    private var statusLine: some View {
        let checked: String
        if store.offline { checked = "Can’t reach the relay right now." }
        else if let t = store.lastChecked { checked = "Checked at \(Fmt.hhmm(t))." }
        else { checked = "Checking…" }
        return Text("\(checked) There are no push notifications: requests, messages and friends’ trips come in when Haltewekker is open (it checks every 30 seconds while this screen is open, every few seconds in a chat, and every minute on your own trips) and now and then in the background.")
            .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.s4)
    }
}

/// No account yet: what Friends is, and the two ways in.
struct FriendsIntroCard: View {
    let make: () -> Void
    let restore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            Image(systemName: "person.2.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(DS.onAccent)
                .frame(width: 56, height: 56).background(DS.accent, in: Circle())
                .accessibilityHidden(true)
            Text("Travel with friends").font(DS.title).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
            Text("Add friends with a code or a link, see when they’re on their way, chat (in groups too), send each other trips, compare timetables and meet halfway.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            point("lock.fill", "Locked end to end: only you and your friends can read what you share. Not even the Haltewekker relay can.")
            point("person.crop.circle", "Just a name and a picture you choose. No email, no phone number, nobody can search for you.")
            point("bell.slash", "No push notifications: requests and messages show up when you open the app, or on a trip.")
            DSPrimaryButton(title: "Make my friend code", icon: "qrcode", action: make)
            DSQuietButton(title: "I have a backup code", icon: "key", full: true, action: restore)
        }
        .dsPanel(padding: DS.s20)
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.s12) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(DS.accentText)
                .frame(width: 22).accessibilityHidden(true)
            Text(text).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A request waiting for you: yes, or no (quietly, or blocking them).
struct FriendRequestRow: View {
    let request: FriendRequest
    let picture: Data?
    @ObservedObject private var store = FriendStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            FriendRowLabel(name: request.name, id: request.id, picture: picture, detail: "Asked \(FriendDates.day(request.at))") { EmptyView() }
            HStack(spacing: DS.s8) {
                Button { Task { await store.accept(request.id) } } label: {
                    Text("Accept").font(DS.subStrong).foregroundStyle(DS.onAccent)
                        .frame(maxWidth: .infinity, minHeight: DS.hit)
                        .background(DS.accent, in: Capsule())
                }
                .buttonStyle(DSPressStyle())
                .accessibilityLabel("Accept \(request.name)")
                Menu {
                    Button("Decline") { Task { await store.decline(request.id, block: false) } }
                    Button("Decline and block", role: .destructive) { Task { await store.decline(request.id, block: true) } }
                } label: {
                    Text("Decline").font(DS.subStrong).foregroundStyle(DS.accentText)
                        .frame(maxWidth: .infinity, minHeight: DS.hit)
                        .background(DS.surface3, in: Capsule())
                }
                .accessibilityLabel("Decline \(request.name)")
            }
            Text("\(request.name) isn’t told if you decline.").font(DS.footnote).foregroundStyle(DS.secondary)
        }
    }
}

/// A friend: who they are, what they see, and removing them.
struct FriendDetailView: View {
    let id: String
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var chats = FriendChats.shared
    @ObservedObject private var extras = FriendExtrasStore.shared
    private var unread: Int { chats.unread(ChatKey.friend(id)) }
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.s16) {
                if let f = store.book?.friend(id) {
                    FriendAvatar(name: f.name, id: f.id, picture: store.pictures[f.id], size: 112)
                    Text(f.name).font(DS.title).foregroundStyle(DS.text).multilineTextAlignment(.center)
                    Text("Friends since \(FriendDates.day(f.since))").font(DS.sub).foregroundStyle(DS.secondary)
                    NavigationLink(value: FriendsRoute.chat(ChatKey.friend(f.id))) {
                        HStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right.fill").font(.body.weight(.semibold))
                            Text(unread > 0 ? "Message · \(unread) new" : "Message").font(DS.bodyStrong)
                        }
                        .foregroundStyle(DS.onAccent)
                        .frame(maxWidth: .infinity, minHeight: DS.cta)
                        .background(DS.accent, in: Capsule())
                    }
                    .buttonStyle(DSPressStyle())
                    CompareButton(key: ChatKey.friend(f.id))
                    if let t = store.travel[f.id], TravelAge.freshness(t, now: Date()) != .gone {
                        FriendTripCard(seen: t, name: f.name)
                    }
                    // (0.29) on campus now
                    if let c = extras.onCampus().first(where: { $0.id == f.id }) {
                        DSNote(icon: "building.columns.fill", tint: DS.accent, text: CampusWords.since(c.state))
                    }
                    FriendSeesCard(friend: f)
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
            .padding(.horizontal, DS.s16).padding(.vertical, DS.s24)
            .frame(maxWidth: .infinity)
        }
        .background(DS.page.ignoresSafeArea())
        .navigationTitle(store.book?.friend(id)?.name ?? "Friend")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A friend's page: what they see of you, and their "Show my trips" switch.
struct FriendSeesCard: View {
    let friend: Friend
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var tt = FriendTimetables.shared

    private var timetableOn: Binding<Bool> {
        Binding(get: { !tt.off.contains(friend.id) }, set: { tt.setShares(friend.id, $0) })
    }

    private var timetableNote: String {
        if tt.off.contains(friend.id) { return "\(friend.name) doesn’t see your timetable." }
        if !tt.answered { return "Not shared with anyone until you say yes in Friends › Your timetable." }
        if !tt.on { return "Off for everyone in Friends › Your timetable." }
        return "Your classes for the next two weeks (when, what, which room), the stops and station nearest your home and your school. Never your address."
    }

    private var on: Binding<Bool> {
        Binding(get: { friend.showsTrips }, set: { store.setShowTrips(friend.id, $0) })
    }

    private var note: String {
        if !friend.showsTrips { return "\(friend.name) doesn’t see your trips." }
        if !store.travelAnswered { return "Your trips aren’t shown to anyone until you say yes in Friends › Your trips." }
        if store.travelPaused { return "Paused for everyone in Friends › Your trips." }
        return "While a trip runs and you’re on board: what you’re on, where you are, when you arrive and your coach. Nothing when no trip runs."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "What \(friend.name) sees")
            Text("Your name and picture, and what you write to them.")
                .font(DS.sub).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: on) {
                Text("Show my trips to \(friend.name)").font(DS.bodyStrong).foregroundStyle(DS.text)
            }
            .tint(DS.accent)
            .frame(minHeight: DS.hit)
            Text(note).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(DS.divider)
            Toggle(isOn: timetableOn) {
                Text("Share my timetable with \(friend.name)").font(DS.bodyStrong).foregroundStyle(DS.text)
            }
            .tint(DS.accent)
            .frame(minHeight: DS.hit)
            Text(timetableNote).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(DS.divider)
            // (0.29) the wake-up buddy: off by default, per friend
            BuddySwitch(friend: friend)
        }
        .dsPanel()
    }
}

/// Someone's code, opened (scanned, pasted or from a link): send them a friend request.
struct FriendAddSheet: View {
    let code: FriendStore.OpenedCode
    @ObservedObject private var store = FriendStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var result: FriendBook.Added?
    @State private var busy = false
    @State private var creating = false

    private var name: String { code.name.isEmpty ? "your friend" : code.name }

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.s16) {
                FriendAvatar(name: code.name.isEmpty ? "?" : code.name, id: code.id, size: 96)
                Text(code.name.isEmpty ? "A friend code" : code.name)
                    .font(DS.title).foregroundStyle(DS.text).multilineTextAlignment(.center)
                Text(message).font(DS.body).foregroundStyle(DS.text).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if result == nil {
                    if store.hasAccount {
                        DSPrimaryButton(title: busy ? "Sending…" : "Send friend request", icon: "person.badge.plus") { send() }
                            .disabled(busy)
                    } else {
                        DSPrimaryButton(title: "Make my friend code first", icon: "qrcode") { creating = true }
                    }
                } else {
                    DSPrimaryButton(title: "Done") { dismiss() }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.s16).padding(.vertical, DS.s24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Add a friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { if result == nil { Button("Cancel") { dismiss() } } } }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $creating) { FriendCreateSheet(then: { send() }) }
    }

    private var message: String {
        switch result {
        case nil:
            return store.hasAccount
                ? "Haltewekker sends \(name) a friend request. \(name.capitalizedFirst) sees it the next time they open the app (there are no notifications)."
                : "To add \(name), first make your own friend code: a name and, if you like, a picture."
        case .sent?: return "Request sent. It arrives when \(name) opens Haltewekker."
        case .alreadyAsked?: return "Asked again. It arrives when \(name) opens Haltewekker."
        case .accepted?: return "\(name.capitalizedFirst) had asked you already: you’re friends now."
        case .alreadyFriends?: return "You’re already friends."
        case .yourself?: return "That’s your own code."
        }
    }

    private func send() {
        busy = true
        Task {
            result = await store.add(code)
            busy = false
        }
    }
}

/// Friends › Backup code.
struct FriendBackupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                BackupCodeView().padding(.horizontal, DS.s16).padding(.vertical, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Backup code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(DS.accentText)
    }
}

/// Settings › Friends (in either look): opens the Friends screen.
struct FriendsSettingsSection: View {
    @ObservedObject private var store = FriendStore.shared
    @State private var open = false
    var body: some View {
        Section {
            Button { open = true } label: {
                HStack {
                    Label("Friends", systemImage: "person.2")
                    Spacer()
                    if store.badge > 0 {
                        Text("\(store.badge)").font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.onAccent)
                            .padding(.horizontal, 8).padding(.vertical, 2).background(DS.accent, in: Capsule())
                            .accessibilityLabel("\(store.badge) new")
                    }
                }
            }
            .sheet(isPresented: $open) { FriendsScreen() }
        } footer: {
            Text(store.hasAccount
                 ? "Your friends, chats and groups, requests, your code and your backup code."
                 : "Add friends with a code or a link. Locked end to end; nothing to sign up for.")
        }
    }
}

/// (0.27) Chats: each friend's and group's, newest first, with what's new; and making a group.
struct FriendChatsCard: View {
    let newGroup: () -> Void
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var chats = FriendChats.shared

    /// Groups without a line yet show too (under the chats).
    private var rows: [String] {
        let recent: [String] = chats.recent.map(\.key)
        let quietGroups: [String] = store.groups.shown.map { ChatKey.group($0.id) }.filter { !recent.contains($0) }
        return recent + quietGroups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Chats", sub: store.unread > 0 ? "\(store.unread) new" : nil)
            if rows.isEmpty {
                Text("Write to a friend from their page, or make a group. You can also send a trip from Fastest trip, Plan or a planned trip.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows, id: \.self) { k in
                NavigationLink(value: FriendsRoute.chat(k)) { row(k) }
                    .buttonStyle(.plain)
                if k != rows.last { Divider().overlay(DS.divider) }
            }
            DSQuietButton(title: "New group", icon: "person.3", full: true, action: newGroup)
        }
        .dsPanel()
    }

    private func row(_ k: String) -> some View {
        let n: Int = chats.unread(k)
        let me: String = store.myAccount ?? ""
        let gid: String? = ChatKey.groupId(k)
        let g: FriendGroup? = gid.flatMap { store.group($0) }
        let name: String = g?.name ?? store.name(k)
        let pic: Data? = gid.map { store.groupPictures[$0] } ?? store.pictures[k]
        let avatarId: String = gid.map { "g-\($0)" } ?? k
        let last: ChatMessage? = chats.book.chat(k)?.last
        var detail: String = last.map { ChatWords.preview($0, me: me, name: { store.name($0) }, group: g != nil) } ?? "\(g?.roster.members.count ?? 0) people"
        if let l = last { detail = Fmt.hhmm(l.at) + " · " + detail }
        if g?.out == .removed { detail = "You’re no longer in it · " + detail }
        return FriendRowLabel(name: name, id: avatarId, picture: pic, detail: detail) {
            if n > 0 {
                Text("\(n)").font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.onAccent)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(DS.accent, in: Capsule())
                    .accessibilityLabel("\(n) new")
            } else {
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
