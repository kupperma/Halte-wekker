import SwiftUI

// Friends (0.27): a chat with a friend or a group: lines, quick replies, trip cards ("Take this trip", "I'm in",
// "Can't"), how far your lines got. Looks at the relay every 8 s while it's open and the app is in front (nothing else
// runs for it); a line arrives on the other phone when it checks in (no push).

enum FriendsRoute: Hashable {
    case friend(String)
    case chat(String)
    case group(String)
    /// (0.28) Compare timetables: a friend's account, or `g.<group id>`.
    case compare(String)
    /// (0.28) One day of it in full.
    case compareDay(String, String)
    /// (0.30) The leaderboard with friends.
    case leaderboard
}

struct FriendChatView: View {
    let key: String
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var chats = FriendChats.shared
    @ObservedObject private var extras = FriendExtrasStore.shared
    @EnvironmentObject private var trip: TripManager
    @Environment(\.scenePhase) private var scene
    @State private var draft = ""
    @FocusState private var typing: Bool

    private var groupId: String? { ChatKey.groupId(key) }
    private var group: FriendGroup? { groupId.flatMap { store.group($0) } }
    private var me: String { store.myAccount ?? "" }
    private var lines: [ChatMessage] { chats.book.chat(key)?.messages ?? [] }
    private var canWrite: Bool { !store.recipients(key).isEmpty }
    private var waitsHere: [WaitSeen] { extras.waitsForMe().filter { $0.chat == key } }

    private var title: String {
        if let g = group { return g.name }
        return store.book?.friend(key)?.name ?? "Chat"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.s8) {
                    noPushNote
                    // (0.29) someone here asks you to wait; your own wait in this chat
                    ForEach(waitsHere, id: \.from) { w in WaitForYouCard(seen: w) }
                    MyWaitCard(chat: key)
                    ForEach(lines) { m in
                        row(m).id(m.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, DS.s12).padding(.vertical, DS.s12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: lines.count) { _, _ in
                withAnimation(DS.quick) { proxy.scrollTo("end", anchor: .bottom) }
                if scene == .active { chats.read(key) }
            }
        }
        .background(DS.page.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear {
            chats.onScreen = key
            chats.read(key)
        }
        .onDisappear { if chats.onScreen == key { chats.onScreen = nil } }
        // while it's open and the app in front: the mailbox every 8 s (friends' trips every 30 s of those)
        .task(id: scene == .active) {
            guard scene == .active else { return }
            chats.read(key)
            await store.sync(.now)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { break }
                await store.sync(.chat)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if let g = group {
                NavigationLink(value: FriendsRoute.group(g.id)) {
                    FriendAvatar(name: g.name, id: "g-\(g.id)", picture: store.groupPictures[g.id], size: 32)
                }
                .accessibilityLabel("About \(g.name)")
            } else if store.book?.isFriend(key) == true {
                NavigationLink(value: FriendsRoute.friend(key)) {
                    FriendAvatar(name: title, id: key, picture: store.pictures[key], size: 32)
                }
                .accessibilityLabel("About \(title)")
            }
        }
    }

    private var noPushNote: some View {
        let who: String = group == nil ? title : "the others"
        return Text("Locked end to end. No notifications: messages arrive when \(who) open\(group == nil ? "s" : "") Haltewekker, or on a trip.")
            .font(DS.footnote).foregroundStyle(DS.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, DS.s8).padding(.horizontal, DS.s16)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: lines

    @ViewBuilder private func row(_ m: ChatMessage) -> some View {
        switch m.content {
        case .note(let s):
            Text(s).font(DS.footnote).foregroundStyle(DS.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 2)
        case .text(let t):
            ChatBubble(text: t.text, mine: m.from == me, who: whoLine(m), status: status(m), answer: t.answer != nil)
        case .trip(let c):
            TripCardBubble(card: c, line: m, chat: key, mine: m.from == me, who: whoLine(m), status: status(m))
        }
    }

    /// In a group: who wrote it (not on yours).
    private func whoLine(_ m: ChatMessage) -> String? {
        guard group != nil, m.from != me, !m.from.isEmpty else { return nil }
        return store.name(m.from)
    }

    /// Under your last line: how far it got.
    private func status(_ m: ChatMessage) -> String? {
        guard m.from == me, m.id == lines.last(where: { $0.from == me })?.id else { return nil }
        let d: ChatDelivery = chats.delivery(m, in: key)
        let group = self.group != nil
        switch d {
        case .waiting: return "Waiting to send · \(Fmt.hhmm(m.at))"
        case .sent: return "Sent \(Fmt.hhmm(m.at)) · arrives when \(group ? "they open" : "\(title) opens") the app"
        case .delivered(let n, let of): return group ? "Delivered to \(n) of \(of)" : "Delivered"
        case .read(let n, let of): return group ? "Read by \(n) of \(of)" : "Read"
        }
    }

    // MARK: writing

    private var quick: [String] {
        let line: String? = {
            guard trip.phase != .idle, let v = trip.vehicle else { return nil }
            return v.isTrain ? Transit.trainLabel(v.line) : v.line
        }()
        return QuickReplies.list(line: line)
    }

    @ViewBuilder private var composer: some View {
        if canWrite {
            VStack(spacing: DS.s8) {
                quickRow
                fieldRow
            }
            .padding(.vertical, DS.s8)
            .background(DS.surface.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
        } else {
            Text(group != nil ? "You’re not in this group any more." : "You’re not friends any more, so you can’t write here.")
                .font(DS.sub).foregroundStyle(DS.secondary)
                .frame(maxWidth: .infinity).padding(DS.s12)
                .background(DS.surface.ignoresSafeArea(edges: .bottom))
        }
    }

    private var quickRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.s8) {
                ForEach(quick, id: \.self) { q in
                    Button { chats.send(q, to: key) } label: {
                        Text(q).font(DS.subStrong).foregroundStyle(DS.accentSoftText)
                            .padding(.horizontal, DS.s12).frame(minHeight: 36)
                            .background(DS.accentSoft, in: Capsule())
                            .frame(minHeight: DS.hit).contentShape(Rectangle())
                    }
                    .buttonStyle(DSPressStyle())
                    .accessibilityHint("Sends it now")
                }
            }
            .padding(.horizontal, DS.s12)
        }
    }

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: DS.s8) {
            TextField("Message", text: $draft, axis: .vertical)
                .font(DS.body)
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, DS.s12).padding(.vertical, 10)
                .frame(minHeight: DS.hit)
                .background(DS.surface3, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityLabel("Message")
            Button(action: sendDraft) {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(DS.onAccent)
                    .frame(width: DS.hit, height: DS.hit)
                    .background(canSend ? DS.accent : DS.legQuiet, in: Circle())
            }
            .buttonStyle(DSPressStyle())
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, DS.s12)
    }

    private var canSend: Bool { !ChatText.clean(draft).isEmpty }

    private func sendDraft() {
        guard chats.send(draft, to: key) else { return }
        draft = ""
    }
}

/// One line of text: yours on the right in the accent, theirs on the left.
struct ChatBubble: View {
    let text: String
    let mine: Bool
    let who: String?
    let status: String?
    var answer = false

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if let who { Text(who).font(DS.footnoteStrong).foregroundStyle(DS.secondary).padding(.horizontal, DS.s4) }
            HStack(spacing: 6) {
                if answer { Image(systemName: "hand.raised.fill").font(.footnote).accessibilityHidden(true) }
                Text(text).font(DS.body).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(mine ? DS.onAccent : DS.text)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(mine ? DS.accent : DS.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .textSelection(.enabled)
            if let status { Text(status).font(DS.footnote).foregroundStyle(DS.secondary).padding(.horizontal, DS.s4) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        let w: String = mine ? "You" : (who ?? "")
        let s: String = status.map { ". \($0)" } ?? ""
        return w.isEmpty ? text + s : "\(w): \(text)\(s)"
    }
}

/// A trip card's content: the line on top, then each ride (time, line, from → to), and when it gets there.
struct TripCardBody: View {
    let card: TripCard
    let group: Bool
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Label {
                Text(TripCardWords.headline(card, now: Date(), group: group)).font(DS.bodyStrong).foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(DS.accentText)
            }
            ForEach(Array(card.rides.enumerated()), id: \.offset) { _, r in
                rideRow(r)
            }
            if let a = card.arrival {
                Text("At \(card.to.name) \(Fmt.hhmm(a))\(card.by.map { " · be there by \(Fmt.hhmm($0))" } ?? "")")
                    .font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TripCardWords.spoken(card, now: Date(), group: group))
    }

    private func rideRow(_ r: TripCard.Ride) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.s8) {
            Text(Fmt.hhmm(r.dep)).font(DS.subStrong).monospacedDigit().foregroundStyle(DS.text)
            DSLinePill(line: r.line, train: r.isTrain)
            Text("\(Fmt.place(r.from.name)) → \(Fmt.place(r.to.name))").font(DS.sub).foregroundStyle(DS.text)
                .lineLimit(compact ? 1 : 2)
        }
    }
}

/// A trip card in a chat: theirs with "Take this trip", "I'm in" and "Can't"; who answered what.
struct TripCardBubble: View {
    let card: TripCard
    let line: ChatMessage
    let chat: String
    let mine: Bool
    let who: String?
    let status: String?
    @ObservedObject private var chats = FriendChats.shared
    @ObservedObject private var store = FriendStore.shared
    @EnvironmentObject private var trip: TripManager
    @EnvironmentObject private var near: NearMe
    @EnvironmentObject private var planner: Planner
    @EnvironmentObject private var go: GoStore
    @State private var busy = false
    @State private var said: String?

    private var answers: [String: TripAnswer] { chats.book.answers(to: line.n, in: chat) }
    /// The shared ride, when you're in on it (you sent it or said "I'm in") and it leaves within the hour.
    private var waitRide: TripCard.Ride? {
        guard mine || myAnswer == .yes, let s = TripTake.shared(card), s.from.point != nil else { return nil }
        let left: TimeInterval = s.dep.timeIntervalSinceNow
        return left > -60 && left < 3600 ? s : nil
    }
    private var myAnswer: TripAnswer? { store.myAccount.flatMap { answers[$0] } }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if let who { Text(who).font(DS.footnoteStrong).foregroundStyle(DS.secondary).padding(.horizontal, DS.s4) }
            VStack(alignment: .leading, spacing: DS.s12) {
                TripCardBody(card: card, group: ChatKey.isGroup(chat))
                answersLine
                if !mine { actions }
                // (0.29) on your way to its first stop: ask them to wait
                if let s = waitRide { WaitForMeButton(chat: chat, stop: s.from, ride: s) }
                if let said { Text(said).font(DS.footnote).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(DS.s12)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DS.accent.opacity(mine ? 0.6 : 0.25), lineWidth: 1.5))
            if let status { Text(status).font(DS.footnote).foregroundStyle(DS.secondary).padding(.horizontal, DS.s4) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 24)
    }

    @ViewBuilder private var answersLine: some View {
        let list: [(String, TripAnswer)] = answers.filter { $0.key != store.myAccount }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        if !list.isEmpty {
            let text: String = list.map { "\(store.name($0.0)): \($0.1 == .yes ? "in" : "can’t")" }.joined(separator: " · ")
            Text(text).font(DS.footnoteStrong).foregroundStyle(DS.accentText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(spacing: DS.s8) {
            DSPrimaryButton(title: busy ? "Finding your way…" : "Take this trip", icon: "checkmark.circle") { take() }
                .disabled(busy)
            HStack(spacing: DS.s8) {
                answerButton(.yes, "I’m in")
                answerButton(.no, "Can’t")
            }
        }
    }

    private func answerButton(_ a: TripAnswer, _ title: String) -> some View {
        let on: Bool = myAnswer == a
        return Button {
            chats.answer(a, card: line.n, in: chat)
        } label: {
            Text(title).font(DS.subStrong).foregroundStyle(on ? DS.onAccent : DS.accentText)
                .frame(maxWidth: .infinity, minHeight: DS.hit)
                .background(on ? DS.accent : DS.surface3, in: Capsule())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func take() {
        busy = true
        said = nil
        Task {
            let out = await TripTaker.take(card, trip: trip, near: near, planner: planner, go: go)
            busy = false
            var took = false
            switch out {
            case .watching: took = true
            case .plan: break
            case .planned(let s): said = s; took = true
            case .cant(let s): said = s
            }
            // (taking it is a yes)
            if took, myAnswer == nil { chats.answer(.yes, card: line.n, in: chat) }
        }
    }
}
