import MapKit
import SwiftUI

// (0.42.5) Someone's live link opened in this app — `haltewekker://live/<token>#k=<key>` from the page's "Open in
// Haltewekker", or the https link pasted in Friends: the trip as the page reads it (`/live/v1/get`, opened with the key
// from the link), and a message to the sharer with your own name and friends account. Nothing is saved. Also the live
// link card's messages and reply (your own link).

@MainActor
final class LiveViewStore: ObservableObject {
    static let shared = LiveViewStore()

    struct Sent: Identifiable, Equatable {
        let seq: Int
        let at: Date
        let text: String
        var id: Int { seq }
    }

    struct Opened: Identifiable {
        let token: String
        let key: Data
        var id: String { token }
    }

    @Published var opened: Opened?
    @Published private(set) var state: LiveState?
    @Published private(set) var status: String?
    @Published private(set) var ended = false
    @Published private(set) var seen = 0
    @Published private(set) var replies: [LiveReply] = []
    @Published private(set) var sent: [Sent] = []
    @Published private(set) var note: String?

    private init() {}

    /// A live link of this relay (either form): opened (true), else not one.
    @discardableResult
    func open(_ link: String) -> Bool {
        guard let p = LiveCrypto.parse(link) else { return false }
        if opened?.token != p.token {
            state = nil; ended = false; seen = 0; replies = []; sent = []; note = nil
            status = "Opening the trip…"
        }
        opened = Opened(token: p.token, key: p.key)
        return true
    }

    func close() { opened = nil }

    private struct Got: Decodable {
        struct R: Decodable { let seq: Int; let data: String }
        let data: String
        let seen: Int?
        let replies: [R]?
    }

    /// One look (every 15 s while it's on screen).
    func poll() async {
        guard let o = opened, !ended, let url = URL(string: "\(LiveCrypto.relay)/live/v1/get?t=\(o.token)") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let a = try? await Net.response(req, lane: .background, label: "live/v1/get")
        guard opened?.token == o.token else { return }
        guard let a else { status = "Can’t reach the trip right now. Trying again…"; return }
        if a.status == 404 || a.status == 410 { ended = true; status = "This live trip has ended."; return }
        guard a.status == 200, let g = try? JSONDecoder().decode(Got.self, from: a.data), let box = B64URL.decode(g.data),
              let plain = try? LiveCrypto.open(box, key: o.key, token: o.token),
              let s = try? FriendJSON.decoder.decode(LiveState.self, from: plain) else {
            status = a.status == 200 ? "This link’s key doesn’t fit. Ask for the link again." : "Can’t reach the trip right now. Trying again…"
            return
        }
        state = s
        status = nil
        seen = g.seen ?? 0
        replies = (g.replies ?? []).compactMap { r in B64URL.decode(r.data).flatMap { LiveMessages.openReply($0, key: o.key, token: o.token) } }
    }

    /// A message to the sharer: your name, and your friends account when you have one.
    func send(_ text: String) async -> Bool {
        guard let o = opened else { return false }
        let t: String = LiveTripV2.clean(text, LiveMessages.maxText)
        guard !t.isEmpty, let url = URL(string: "\(LiveCrypto.relay)/live/v1/msg?t=\(o.token)") else { return false }
        let name: String = LiveNames.sender(friends: FriendStore.shared.book?.myName, typed: UserDefaults.standard.string(forKey: "live.name"))
        let now: Double = Date().timeIntervalSince1970.rounded(.down)
        let m = LiveMessage(from: name, fromKind: "app", friendId: FriendStore.shared.account, text: t, at: now)
        guard let data = try? LiveMessages.seal(m, key: o.key, token: o.token),
              let body = try? JSONSerialization.data(withJSONObject: ["data": B64URL.encode(data)]) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let a = try? await Net.response(req, lane: .background, label: "live/v1/msg")
        struct Ok: Decodable { let seq: Int }
        switch a?.status {
        case 200:
            if let ok = try? JSONDecoder().decode(Ok.self, from: a?.data ?? Data()) {
                sent = Array((sent + [Sent(seq: ok.seq, at: Date(timeIntervalSince1970: now), text: t)]).suffix(20))
            }
            note = nil
            return true
        case 429: note = "Wait a few seconds before sending another."
        case 404, 410: note = "The live trip has ended."
        default: note = "Couldn’t send it. Check your connection."
        }
        return false
    }
}

/// Shows an opened live link over everything.
struct LiveViewHost: ViewModifier {
    @ObservedObject private var store = LiveViewStore.shared
    func body(content: Content) -> some View {
        content.fullScreenCover(item: $store.opened) { _ in LiveViewSheet() }
    }
}

struct LiveViewSheet: View {
    @ObservedObject private var store = LiveViewStore.shared
    @State private var text = ""
    @State private var camera: MapCameraPosition = .automatic

    private static let bg = Color(red: 0x11 / 255, green: 0x13 / 255, blue: 0x16 / 255)
    private static let card = Color(red: 0x1E / 255, green: 0x21 / 255, blue: 0x26 / 255)

    private func colour(_ s: LiveState) -> Color {
        let hex: String = s.legs?[safe: s.leg ?? 0]?.color ?? "E0632E"
        let v = UInt32(hex, radix: 16) ?? 0xE0632E
        return Color(hex: v)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let s = store.state { map(s).frame(maxHeight: .infinity) }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s12) {
                    HStack {
                        Text(store.ended ? "ENDED" : store.state?.stage == .arrived ? "ARRIVED" : "LIVE")
                            .font(.caption.weight(.heavy)).foregroundStyle(store.ended ? Color.gray : DS.accentText)
                        Spacer()
                        Button("Close") { store.close() }.foregroundStyle(.white)
                    }
                    if let s = store.state { trip(s) }
                    if let st = store.status { Text(st).font(DS.sub).foregroundStyle(.gray) }
                    if let s = store.state, s.inbox == true, !store.ended { messages(s) }
                }
                .padding(DS.s16)
            }
            .frame(maxHeight: .infinity)
            .background(Self.card)
        }
        .background(Self.bg.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task(id: store.opened?.token) {
            while !Task.isCancelled {
                await store.poll()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func map(_ s: LiveState) -> some View {
        let road: [CLLocationCoordinate2D] = s.shape.map { Transit.decodePolyline($0) } ?? []
        let pos: CLLocationCoordinate2D? = s.stage == .arrived ? nil : s.pos.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let stops: [LiveStop] = s.stops ?? []
        let col: Color = colour(s)
        let label: String = s.legs?[safe: s.leg ?? 0]?.line ?? s.line ?? ""
        return Map(position: $camera) {
            if road.count > 1 { MapPolyline(coordinates: road).stroke(col, lineWidth: 5) }
            ForEach(Array(stops.enumerated()), id: \.offset) { i, x in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: x.lat, longitude: x.lon), anchor: .center) {
                    Circle().strokeBorder(col.opacity(i < (s.next ?? 0) ? 1 : 0.45), lineWidth: 3).background(Circle().fill(Self.bg)).frame(width: 12, height: 12)
                }
            }
            if let pos {
                Annotation(label, coordinate: pos, anchor: .center) {
                    Text(label.isEmpty ? "•" : label).font(.caption.weight(.heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(col, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private func trip(_ s: LiveState) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Text(LiveWords.headline(s)).font(DS.headline).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            if let d = LiveWords.detail(s) { Text(d).font(DS.sub).foregroundStyle(.gray) }
            ForEach(Array((s.legs ?? []).enumerated()), id: \.offset) { i, l in
                let now: Bool = i == (s.leg ?? 0) && s.stage != .arrived
                Text(legLine(l)).font(now ? DS.subStrong : DS.sub).foregroundStyle(now ? Color.white : Color.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legLine(_ l: LiveLeg) -> String {
        let time: String = l.dep.map { TimetableDays.hhmm(Date(timeIntervalSince1970: TimeInterval($0))) } ?? ""
        let what: String
        if l.mode == "walk" { what = "Walk" + (l.mins.map { " \($0) min" } ?? "") }
        else if l.mode == "train" { what = l.line ?? "Train" }
        else { what = "Bus " + (l.line ?? "") }
        var plat: String = ""
        if let p = l.depPlatform { plat = l.mode == "train" ? " · platform \(p)" : " · stop \(p)" }
        return "\(time)  \(what) · \(l.from) → \(l.to)\(plat)"
    }

    private func messages(_ s: LiveState) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Text("Send \(s.name.isEmpty ? "them" : s.name) a message").font(DS.bodyStrong).foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(LiveMessages.chips, id: \.self) { c in
                        Button(c) { text = c }.font(DS.sub).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.white.opacity(0.08), in: Capsule()).foregroundStyle(.white)
                    }
                }
            }
            HStack {
                TextField("A message", text: $text, axis: .vertical).lineLimit(1...4).foregroundStyle(.white)
                    .onChange(of: text) { _, v in if v.count > LiveMessages.maxText { text = String(v.prefix(LiveMessages.maxText)) } }
                Button("Send") { Task { if await store.send(text) { text = "" } } }.font(DS.bodyStrong)
            }
            .padding(10).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            if let n = store.note { Text(n).font(DS.footnote).foregroundStyle(DS.warning) }
            ForEach(store.sent) { m in
                Text(m.text + "  ·  " + (m.seq <= store.seen ? "Seen ✓✓" : "Sent \(TimetableDays.hhmm(m.at)) ✓")).font(DS.footnote).foregroundStyle(.white)
            }
            ForEach(Array(store.replies.enumerated()), id: \.offset) { _, r in
                Text("\(s.name): \(r.text) · \(TimetableDays.hhmm(Date(timeIntervalSince1970: r.at)))").font(DS.footnote).foregroundStyle(DS.accentText)
            }
        }
    }
}

/// (0.42.5) "Follow someone’s live link": paste one (Paste reads the clipboard without asking only when you tap it).
struct LiveOpenRow: View {
    @State private var bad = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s4) {
            PasteButton(payloadType: String.self) { strings in
                let text: String = strings.joined(separator: "\n")
                let link: String = LiveMessages.find(text) ?? text
                Task { @MainActor in bad = !LiveViewStore.shared.open(link) }
            }
            .labelStyle(.titleAndIcon)
            .tint(DS.accent)
            Text(bad ? "That isn’t a whole live link. Ask for it again (all of it, with the part after the #)."
                     : "Someone sent you a live link? Copy it, then paste it here to follow their trip in the app.")
                .font(DS.footnote).foregroundStyle(bad ? DS.warning : DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.s4)
    }
}

/// Your own live link's messages, on its card: who, when, what; seen once on screen; and a reply every page shows.
struct LiveLinkMessages: View {
    let link: LiveLinkStore.Link
    @ObservedObject private var live = LiveLinkStore.shared
    @State private var reply = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            ForEach((link.msgs ?? []).suffix(5)) { m in
                Text("💬 \(live.sender(m)) · \(TimetableDays.hhmm(m.at)): \(m.text)").font(DS.sub).foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array((link.replies ?? []).suffix(3).enumerated()), id: \.offset) { _, r in
                Text("You · \(TimetableDays.hhmm(Date(timeIntervalSince1970: r.at))): \(r.text)").font(DS.footnote).foregroundStyle(DS.secondary)
            }
            HStack {
                TextField("Reply (everyone with the link sees it)", text: $reply).font(DS.sub)
                    .onChange(of: reply) { _, v in if v.count > LiveMessages.maxText { reply = String(v.prefix(LiveMessages.maxText)) } }
                Button("Reply") {
                    Task {
                        if await live.reply(reply) { reply = ""; problem = nil } else { problem = "Couldn’t send it. Try again in a few seconds." }
                    }
                }
                .font(DS.subStrong)
            }
            .padding(10).background(DS.surface3, in: RoundedRectangle(cornerRadius: 14))
            if let p = problem { Text(p).font(DS.footnote).foregroundStyle(DS.warning) }
        }
        .onAppear { live.markSeen() }
        .onChange(of: link.msgs?.count ?? 0) { _, _ in live.markSeen() }
    }
}
