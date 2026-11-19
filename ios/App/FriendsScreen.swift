import SwiftUI

// Friends (0.25): the friend list, requests waiting, and adding someone. Opened from the home (Next trip first's
// bar, Live around you's round button) and from Settings › Friends. Follows the phone's light or dark.
//
// (0.31, "Map first") With an account it's a map: friends' faces where they are (ringed in their vehicle's colour,
// campus in the accent), their routes drawn, and a sheet over it: "Friends · + Add", requests, a card per friend,
// Chats · Groups · Compare, what's going on now (waits, campus, delays, free time, the live link), and More (your
// name and picture, your trips, your timetable, extras, the leaderboard, requests you sent). Nothing of 0.30 went:
// it moved into the sheet, its tiles and More's pages.

/// (0.31) A page of the Friends screen's More list (or its "+ Add").
enum FriendsPage: String, Hashable {
    case add, trips, timetable, extras, waiting
}

struct FriendsScreen: View {
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var chats = FriendChats.shared
    @ObservedObject private var extras = FriendExtrasStore.shared
    @ObservedObject private var routes = FriendRoutes.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var sheet: Sheet?
    @State private var confirmDelete = false
    @State private var pasteWrong = false
    @State private var path: [FriendsRoute] = []
    @State private var up = false
    @ScaledMetric(relativeTo: .body) private var peek: CGFloat = 360

    enum Sheet: String, Identifiable {
        case myCode, scan, create, restore, backup, profile, travel, newGroup, timetable
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
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

    @ViewBuilder private var root: some View {
        if store.hasAccount {
            mapHome
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s12) {
                    if store.movedAway { movedNote }
                    FriendsIntroCard(make: { sheet = .create }, restore: { sheet = .restore })
                }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
        case .leaderboard: FriendsLeaderboardScreen()
        case .chats: FriendsSectionPage(title: "Chats") { FriendChatsCard(newGroup: { sheet = .newGroup }) }
        case .groups: FriendsSectionPage(title: "Groups") { groupsCard }
        case .compareWith: FriendsSectionPage(title: "Compare") { compareCard }
        case .page(let p): page(p)
        }
    }

    @ViewBuilder private func page(_ p: FriendsPage) -> some View {
        switch p {
        case .add: FriendsSectionPage(title: "Add a friend") { addCard }
        case .trips: FriendsSectionPage(title: "Your trips") { MyTripsCard(explain: { sheet = .travel }) }
        case .timetable: FriendsSectionPage(title: "Your timetable") { MyTimetableCard(explain: { sheet = .timetable }) }
        case .extras: FriendsSectionPage(title: "Extras") { ExtrasSwitchesCard() }
        case .waiting: FriendsSectionPage(title: "Requests you sent") { waitingCard(store.book?.outgoing ?? []) }
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

    // MARK: the map (0.31)

    /// Travelling friends where they are, and friends on campus at your school (when it's theirs).
    private var pins: [FriendMapPin] {
        let now = Date()
        var out: [FriendMapPin] = []
        var seen: Set<String> = []
        for t in store.travelling(now: now) {
            let s: TravelState = t.state
            guard let p = s.pos, let g = MapFrame.point(lat: p.lat, lon: p.lon) else { continue }
            let name: String = store.name(t.from)
            let ring: Color = DS.mode(train: s.isTrain, mode: s.mode, line: s.line ?? "")
            out.append(FriendMapPin(id: t.from, name: name, point: g, ring: ring, label: "\(name), \(TravelWords.summary(s))",
                                    stale: TravelAge.freshness(t, now: now) == .stale, route: routes.route(s)))
            seen.insert(t.from)
        }
        let school: GeoPoint = Place.school.point
        let mine: String = RoleWords.current.school
        if MapFrame.valid(school) {
            let campus: [FriendExtrasStore.OnCampus] = extras.onCampus(now: now).filter { !seen.contains($0.id) }
            for (i, c) in campus.enumerated() where c.state.school == nil || c.state.school == mine {
                // side by side, a little apart, so each face can be tapped
                let g = GeoPoint(lat: school.lat, lon: school.lon + Double(i) * 0.0012)
                let name: String = store.name(c.id)
                out.append(FriendMapPin(id: c.id, name: name, point: g, ring: DS.accent, label: "\(name), \(CampusWords.since(c.state))",
                                        stale: false, route: []))
            }
        }
        return out
    }

    /// What the map frames: each face, and where travelling friends got on and get off.
    private var framePoints: [GeoPoint] {
        var out: [GeoPoint] = pins.map(\.point)
        for t in store.travelling() { out += MapFrame.points(t.state) }
        return out
    }

    private var tripIds: [String] { store.travelling().compactMap(\.state.trip) }

    private var mapHome: some View {
        GeometryReader { g in
            let cover: CGFloat = g.size.height > 0 ? min(0.8, peek / g.size.height) : 0.45
            ZStack(alignment: .top) {
                FriendsLiveMap(pins: pins, frame: framePoints, cover: cover, tap: { id in path.append(.friend(id)) })
                    .ignoresSafeArea()
                MapSheet(up: $up, peek: peek) { sheetContent }
                    .ignoresSafeArea(edges: .bottom)
                    .refreshable { await store.sync(.now) }
                topButtons
            }
        }
        .background(DS.page.ignoresSafeArea())
        .navigationTitle("Friends")
        .toolbar(.hidden, for: .navigationBar)
        .task(id: tripIds.joined(separator: ",")) { await routes.load(tripIds) }
    }

    private var topButtons: some View {
        HStack {
            Menu {
                Button { sheet = .profile } label: { Label("Name and picture", systemImage: "person.crop.circle") }
                Button { sheet = .backup } label: { Label("Backup code", systemImage: "key") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete my friends account", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundStyle(DS.text)
                    .frame(width: DS.hit, height: DS.hit)
                    .background(DS.surface, in: Circle())
                    .dsFloat()
            }
            .accessibilityLabel("Your friends account")
            Spacer()
            DSRoundButton(icon: "xmark", label: "Done") { dismiss() }
        }
        .padding(.horizontal, DS.s16).padding(.top, DS.s8)
    }

    // MARK: the sheet

    @ViewBuilder private var sheetContent: some View {
        let b: FriendBook? = store.book
        let friends: [Friend] = b?.sortedFriends ?? []
        VStack(alignment: .leading, spacing: DS.s12) {
            if store.movedAway { movedNote }
            HStack(alignment: .firstTextBaseline) {
                Text("Friends").font(DS.largeTitle).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
                Spacer()
                NavigationLink(value: FriendsRoute.page(.add)) {
                    Label("Add", systemImage: "plus").font(DS.bodyStrong).foregroundStyle(DS.accentText)
                        .frame(minHeight: DS.hit).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a friend")
            }
            if let b, !b.incoming.isEmpty { requestsCard(b.incoming) }
            if friends.isEmpty { emptyCard } else { cardsRow(friends) }
            if !friends.isEmpty { tiles }
            // (0.29) waits for you, your own wait, who's on campus, delays on rides you share
            WaitsForYouPanel()
            MyWaitCard(panel: true)
            CampusNowCard()
            SharedDelaysCard()
            // (0.30) free time together today, and the live link while a trip runs
            FreeTodayCard()
            LiveLinkCard()
            moreCard(b, friends: friends)
            if !friends.isEmpty { FriendsTogetherCard() }
            LiveLinkCard(idleNote: true)
            statusLine
        }
        .padding(.top, DS.s4)
    }

    private func cardsRow(_ friends: [Friend]) -> some View {
        let now = Date()
        let moving: [String: FriendTravelSeen] = Dictionary(store.travelling(now: now).map { ($0.from, $0) }, uniquingKeysWith: { a, _ in a })
        let campus: Set<String> = Set(extras.onCampus(now: now).map(\.id))
        // travelling first (newest first), then on campus, then the rest as the list has them
        let going: [Friend] = friends.filter { moving[$0.id] != nil }
            .sorted { (a: Friend, b: Friend) -> Bool in (moving[a.id]?.sent ?? .distantPast) > (moving[b.id]?.sent ?? .distantPast) }
        let there: [Friend] = friends.filter { moving[$0.id] == nil && campus.contains($0.id) }
        let others: [Friend] = friends.filter { moving[$0.id] == nil && !campus.contains($0.id) }
        let order: [Friend] = going + there + others
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: DS.s8) {
                ForEach(order) { f in
                    NavigationLink(value: FriendsRoute.friend(f.id)) {
                        FriendMiniCard(friend: f, travel: moving[f.id], campus: campus.contains(f.id))
                    }
                    .buttonStyle(DSPressStyle())
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Text("No friends yet. Show a friend your code, or send them your link.")
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            DSQuietButton(title: "Add a friend", icon: "person.badge.plus", full: true) { path.append(.page(.add)) }
            // (0.30.1) a bot to try it all with
            TestFriendAddCard()
        }
        .dsPanel()
    }

    private var tiles: some View {
        let n: Int = store.unread
        return HStack(spacing: DS.s8) {
            NavigationLink(value: FriendsRoute.chats) {
                FriendsTile(icon: "bubble.left.and.bubble.right.fill", title: n > 0 ? "Chats · \(n)" : "Chats")
            }
            .buttonStyle(DSPressStyle())
            .accessibilityLabel(n > 0 ? "Chats, \(n) new" : "Chats")
            NavigationLink(value: FriendsRoute.groups) { FriendsTile(icon: "person.3.fill", title: "Groups") }
                .buttonStyle(DSPressStyle())
            NavigationLink(value: FriendsRoute.compareWith) { FriendsTile(icon: "calendar", title: "Compare") }
                .buttonStyle(DSPressStyle())
                .accessibilityHint("Compare timetables with a friend or a group, and meet halfway")
        }
    }

    /// More: your name and picture, your trips, your timetable, extras, requests you sent.
    private func moreCard(_ b: FriendBook?, friends: [Friend]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DSHeader(title: "More").padding(.bottom, DS.s4)
            Button { sheet = .profile } label: {
                FriendRowLabel(name: (b?.myName ?? "").isEmpty ? "You" : (b?.myName ?? "You"), id: "me", picture: store.myPicture,
                               detail: "You · your name and picture") { chevron }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !friends.isEmpty {
                moreRow("Your trips", icon: "location.north.line.fill", detail: tripsDetail, to: .trips)
                moreRow("Your timetable", icon: "calendar", detail: FriendTimetables.shared.on ? "Shared with friends" : "Not shared", to: .timetable)
                moreRow("Extras", icon: "switch.2", detail: "On campus, the wake-up buddy and more", to: .extras)
            }
            if let out = b?.outgoing, !out.isEmpty {
                moreRow("Requests you sent", icon: "paperplane", detail: out.count == 1 ? "1 waiting for an answer" : "\(out.count) waiting for an answer", to: .waiting)
            }
        }
        .dsPanel(padding: DS.s12)
    }

    private var tripsDetail: String {
        if !store.travelAnswered { return "Off until you say yes" }
        if store.travelPaused { return "Paused for everyone" }
        return "Shown while a trip runs"
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
    }

    private func moreRow(_ title: String, icon: String, detail: String, to p: FriendsPage) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(DS.divider)
            NavigationLink(value: FriendsRoute.page(p)) {
                HStack(spacing: DS.s12) {
                    Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(DS.accentText)
                        .frame(width: 44, height: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(DS.bodyStrong).foregroundStyle(DS.text)
                        Text(detail).font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DS.s8)
                    chevron
                }
                .padding(.vertical, DS.s8)
                .frame(minHeight: DS.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: the cards (in the sheet, or on More's pages)

    private func requestsCard(_ list: [FriendRequest]) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Want to be friends", sub: "\(list.count)")
            ForEach(list) { r in FriendRequestRow(request: r, picture: store.pictures[r.id]) }
        }
        .dsPanel()
    }

    /// Groups: each one's chat, and making one.
    private var groupsCard: some View {
        let list: [FriendGroup] = store.groups.shown
        return VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Your groups", sub: list.isEmpty ? nil : "\(list.count)")
            if list.isEmpty {
                Text("No groups yet. Make one to chat, compare timetables and meet halfway with a few friends at once.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(list) { g in
                NavigationLink(value: FriendsRoute.chat(ChatKey.group(g.id))) {
                    FriendRowLabel(name: g.name, id: "g-\(g.id)", picture: store.groupPictures[g.id],
                                   detail: g.out == .removed ? "You’re no longer in it" : "\(g.roster.members.count) people") {
                        let n: Int = chats.unread(ChatKey.group(g.id))
                        if n > 0 {
                            Text("\(n)").font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.onAccent)
                                .padding(.horizontal, 8).padding(.vertical, 2).background(DS.accent, in: Capsule())
                                .accessibilityLabel("\(n) new")
                        } else {
                            chevron
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if g.id != list.last?.id { Divider().overlay(DS.divider) }
            }
            DSQuietButton(title: "New group", icon: "person.3", full: true) { sheet = .newGroup }
        }
        .dsPanel()
    }

    /// Compare: with whom (a friend or a group), and the leaderboard.
    private var compareCard: some View {
        let friends: [Friend] = store.book?.sortedFriends ?? []
        let groups: [FriendGroup] = store.groups.shown.filter { $0.out != .removed }
        return VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Compare timetables")
            Text("Classes side by side this week and next, rides together, free time and meet halfway.")
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(groups) { g in
                NavigationLink(value: FriendsRoute.compare(ChatKey.group(g.id))) {
                    FriendRowLabel(name: g.name, id: "g-\(g.id)", picture: store.groupPictures[g.id], detail: "Group · \(g.roster.members.count) people") { chevron }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(DS.divider)
            }
            ForEach(friends) { f in
                NavigationLink(value: FriendsRoute.compare(ChatKey.friend(f.id))) {
                    FriendRowLabel(name: f.name, id: f.id, picture: store.pictures[f.id], detail: "Compare with \(f.name)") { chevron }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if f.id != friends.last?.id { Divider().overlay(DS.divider) }
            }
        }
        .dsPanel()
    }

    private func waitingCard(_ list: [FriendRequest]) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Waiting for an answer")
            if list.isEmpty {
                Text("Nothing waiting.").font(DS.sub).foregroundStyle(DS.secondary)
            }
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
            // (0.30.1) a bot to try it all with
            if store.hasAccount { TestFriendAddCard() }
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

/// (0.31) A page pushed from the Friends sheet (Chats, Groups, Compare, More's): its card on the page's colour.
struct FriendsSectionPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s12) { content() }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
        }
        .background(DS.page.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
            // (0.30.1) a bot to try Friends with
            if store.hasAccount { TestFriendSettingsRow() }
        } footer: {
            Text(store.hasAccount
                 ? "Your friends, chats and groups, requests, your code and your backup code. A test friend is a bot on this phone to try every Friends feature with; it never goes in your backup."
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
