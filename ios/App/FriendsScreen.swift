import SwiftUI

// Friends (0.25): the friend list, requests waiting, and adding someone. Opened from the home (Next trip first's
// bar, Live around you's round button) and from Settings › Friends. Follows the phone's light or dark.

struct FriendsScreen: View {
    @ObservedObject private var store = FriendStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var sheet: Sheet?
    @State private var confirmDelete = false
    @State private var pasteWrong = false

    enum Sheet: String, Identifiable {
        case myCode, scan, create, restore, backup, profile
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
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
        }
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
        }
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
            meCard(b)
            if !b.incoming.isEmpty { requestsCard(b.incoming) }
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
                NavigationLink { FriendDetailView(id: f.id) } label: {
                    FriendRowLabel(name: f.name, id: f.id, picture: store.pictures[f.id], detail: "Friends since \(FriendDates.day(f.since))") {
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
        return Text("\(checked) There are no notifications: requests come in when Haltewekker is open (it checks every 30 seconds while this screen is open) and now and then in the background.")
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
            Text("Add friends with a code or a link. Coming next: see when friends are on their way, send each other rides and compare timetables.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            point("lock.fill", "Locked end to end: only you and your friends can read what you share. Not even the Haltewekker relay can.")
            point("person.crop.circle", "Just a name and a picture you choose. No email, no phone number, nobody can search for you.")
            point("bell.slash", "No notifications: requests show up when you open the app.")
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
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.s16) {
                if let f = store.book?.friend(id) {
                    FriendAvatar(name: f.name, id: f.id, picture: store.pictures[f.id], size: 112)
                    Text(f.name).font(DS.title).foregroundStyle(DS.text).multilineTextAlignment(.center)
                    Text("Friends since \(FriendDates.day(f.since))").font(DS.sub).foregroundStyle(DS.secondary)
                    VStack(alignment: .leading, spacing: DS.s8) {
                        DSHeader(title: "What \(f.name) sees")
                        Text("Your name and picture. Trips, messages and timetables come in the next versions, and you’ll choose what you share.")
                            .font(DS.sub).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .dsPanel()
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
                    if store.waiting > 0 {
                        Text("\(store.waiting)").font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.onAccent)
                            .padding(.horizontal, 8).padding(.vertical, 2).background(DS.accent, in: Capsule())
                            .accessibilityLabel("\(store.waiting) waiting")
                    }
                }
            }
            .sheet(isPresented: $open) { FriendsScreen() }
        } footer: {
            Text(store.hasAccount
                 ? "Your friend list, requests, your code and your backup code."
                 : "Add friends with a code or a link. Locked end to end; nothing to sign up for.")
        }
    }
}
