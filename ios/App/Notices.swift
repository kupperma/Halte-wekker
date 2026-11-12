import SwiftUI
import UserNotifications

/// A notification shown inside the app while it's open: the same headline and line as on the lock screen, as a paper
/// banner at the top. One at a time; the next waits its turn.
struct Notice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let body: String
    let kind: String            // "late", "cancelled", "faster", "go", "ok", "info"
}

@MainActor
final class Notices: ObservableObject {
    static let shared = Notices()
    @Published private(set) var current: Notice?
    private var queue: [Notice] = []
    private var timer: Task<Void, Never>?

    func show(title: String, body: String, kind: String) {
        let n = Notice(title: title, body: body, kind: kind)
        if current == nil { present(n) } else if !queue.contains(where: { $0.title == title && $0.body == body }) { queue.append(n) }
    }

    func dismiss() {
        timer?.cancel(); timer = nil
        withAnimation(.easeIn(duration: 0.2)) { current = nil }
        guard !queue.isEmpty else { return }
        let n = queue.removeFirst()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.present(n)
        }
    }

    private func present(_ n: Notice) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { current = n }
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(6, min(10, Double(n.body.count) / 12))) * 1_000_000_000)
            guard !Task.isCancelled, self?.current?.id == n.id else { return }
            self?.dismiss()
        }
    }

    /// What kind it is, from the notification (or else its words).
    nonisolated static func kind(of title: String, _ info: [AnyHashable: Any]) -> String {
        if let k = info["kind"] as? String { return k }
        let t = title.lowercased()
        if t.contains("cancel") { return "cancelled" }
        if t.contains("late") || t.contains("early") || t.contains("left") { return "late" }
        if t.contains("faster") { return "faster" }
        if t.contains("time to go") || t.contains("wake") || t.contains("get off") { return "go" }
        if t.contains("on time") || t.contains("you’re on") { return "ok" }
        return "info"
    }
}

/// The banner: a strip of paper with a coloured edge, an icon, a bold headline and its line. Tap or swipe up to close.
struct NoticeBanner: View {
    let notice: Notice
    let close: () -> Void
    @State private var drag: CGFloat = 0

    private var style: (icon: String, color: Color) { Self.style(notice.kind) }

    /// The icon and colour for each kind of notification.
    static func style(_ kind: String) -> (icon: String, color: Color) {
        switch kind {
        case "late": return ("clock.badge.exclamationmark.fill", Paper.late)
        case "cancelled": return ("xmark.octagon.fill", Color(hex: 0xC0392B))
        case "faster": return ("bolt.fill", Paper.ok)
        case "go": return ("figure.walk", Paper.navy)
        case "ok": return ("checkmark.circle.fill", Paper.ok)
        default: return ("bell.fill", Paper.navy)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.icon).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(style.color, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title).font(.system(size: 16.5, weight: .heavy)).foregroundStyle(Paper.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !notice.body.isEmpty {
                    Text(notice.body).font(.system(size: 14, weight: .medium)).foregroundStyle(Paper.ink.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Paper.muted).padding(.top, 3)
        }
        .padding(.leading, 12).padding(.trailing, 12).padding(.vertical, 12)
        .background(PaperFill().clipShape(RoundedRectangle(cornerRadius: 6)))
        .overlay(alignment: .leading) { Rectangle().fill(style.color).frame(width: 5).clipShape(RoundedRectangle(cornerRadius: 2)) }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.edge, lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .overlay(alignment: .top) { Tape(angle: -3, width: 70).offset(y: -10) }
        .offset(y: min(0, drag))
        .gesture(DragGesture().onChanged { drag = $0.translation.height }.onEnded { v in
            if v.translation.height < -30 { close() } else { withAnimation(.spring()) { drag = 0 } }
        })
        .onTapGesture(perform: close)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Closes the message")
    }
}

// MARK: the notifications you had

/// One notification, kept so you can read it again later.
struct LoggedNotice: Codable, Identifiable, Equatable {
    var id: String { "\(key)|\(Int(at.timeIntervalSince1970))" }
    let key: String             // the notification's own identifier
    let title: String
    let body: String
    let kind: String
    let at: Date
}

/// Every notification the app sent (the last week, at most 150): taken off the lock screen when you open the app, and
/// kept here instead.
@MainActor
final class NoticeLog: ObservableObject {
    static let shared = NoticeLog()
    @Published private(set) var items: [LoggedNotice]
    @Published private(set) var unread: Int

    private init() {
        let d = UserDefaults.standard
        let all = d.data(forKey: "noticeLog").flatMap { try? JSONDecoder().decode([LoggedNotice].self, from: $0) } ?? []
        items = all.filter { $0.at > Date().addingTimeInterval(-7 * 86400) }
        unread = d.integer(forKey: "noticeUnread")
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: "noticeLog")
        UserDefaults.standard.set(unread, forKey: "noticeUnread")
    }

    /// Keep one (once: the same notification seen twice within a few seconds is the same one).
    func add(key: String, title: String, body: String, kind: String, at: Date = Date()) {
        guard !title.isEmpty, !items.contains(where: { $0.key == key && abs($0.at.timeIntervalSince(at)) < 15 && $0.title == title }) else { return }
        items.insert(LoggedNotice(key: key, title: title, body: body, kind: kind, at: at), at: 0)
        items.sort { $0.at > $1.at }
        if items.count > 150 { items.removeLast(items.count - 150) }
        unread += 1
        persist()
    }

    func markRead() { unread = 0; persist() }
    func clear() { items = []; unread = 0; persist() }

    /// You opened the app: what came in while it was closed goes into the list, and off the lock screen.
    func collectDelivered() async {
        let c = UNUserNotificationCenter.current()
        let delivered = await c.deliveredNotifications()
        for n in delivered {
            let content = n.request.content
            add(key: n.request.identifier, title: content.title, body: content.body, kind: Notices.kind(of: content.title, content.userInfo), at: n.date)
        }
        c.removeAllDeliveredNotifications()
    }
}

/// The bell on the home screen: how many you haven't seen.
struct NoticeBell: View {
    @ObservedObject private var log = NoticeLog.shared
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            Image(systemName: log.unread > 0 ? "bell.badge.fill" : "bell.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Paper.ink)
                .frame(width: 34, height: 34).background(Paper.paper, in: Circle()).shadow(color: .black.opacity(0.35), radius: 5, y: 3)
                .overlay(alignment: .topTrailing) {
                    if log.unread > 0 {
                        Text(log.unread > 9 ? "9+" : "\(log.unread)").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 17, minHeight: 17).background(Color(hex: 0xC0392B), in: Capsule())
                            .offset(x: 5, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(log.unread > 0 ? "Notifications, \(log.unread) new" : "Notifications")
    }
}

/// What's being watched (with the button to stop it all), and every notification you had, newest first.
struct NotificationsSheet: View {
    @ObservedObject private var log = NoticeLog.shared
    @ObservedObject private var lines = LineWatchStore.shared
    @ObservedObject private var trains = WatchStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    watching
                    history
                }
                .padding(16)
            }
            .background(PaperFill().ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !log.items.isEmpty { ToolbarItem(placement: .cancellationAction) { Button("Clear") { log.clear() } } }
            }
            .onAppear { log.markRead() }
        }
        .preferredColorScheme(.light)
    }

    /// The lines and trains it's watching for you, and the way to stop them all.
    @ViewBuilder private var watching: some View {
        let any = !lines.watches.isEmpty || !trains.watches.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            PlannerBar(title: "Watching now", sub: any ? "\(lines.watches.count + trains.watches.count)" : nil)
            if !any {
                Text("Nothing is being watched, so no notifications are coming. Tap a bus or train on the boards to watch it.")
                    .font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 10)
            }
            ForEach(lines.watches) { w in
                watchRow(line: w.line, train: false, title: "Bus \(w.line)\(w.headsign.isEmpty ? "" : " to \(Fmt.place(w.headsign))")",
                         sub: "\(Fmt.place(w.stopName)) · \(w.status)") { lines.stop(w.id) }
            }
            ForEach(trains.watches) { w in
                watchRow(line: w.label.contains("Sprinter") ? "SPR" : "IC", train: true, title: w.label, sub: "from \(w.from)\(w.track.isEmpty ? "" : " · platform \(w.track)")") {
                    trains.remove(w.key)
                }
            }
            if any {
                Button { confirmStop = true } label: {
                    Label("Stop all notifications", systemImage: "bell.slash.fill").font(BoardInk.sans(14)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12).background(Color(hex: 0xC0392B), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).padding(10)
                .confirmationDialog("Stop watching everything? No more notifications about these buses and trains.", isPresented: $confirmStop, titleVisibility: .visible) {
                    Button("Stop all notifications", role: .destructive) {
                        lines.reset()
                        for w in trains.watches { trains.remove(w.key) }
                    }
                }
            }
        }
        .background(Paper.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.edge, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func watchRow(line: String, train: Bool, title: String, sub: String, stop: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            LineBullet(line: line, train: train, height: 22, minWidth: 38, font: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(BoardInk.sans(13.5)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.7)
                Text(sub).font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.muted).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 4)
            Button("Stop", action: stop).font(BoardInk.sans(12)).foregroundStyle(Paper.late)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Paper.late.opacity(0.1), in: Capsule())
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.rule).frame(height: 1) }
    }

    /// Every notification, by day.
    @ViewBuilder private var history: some View {
        Text("EARLIER NOTIFICATIONS").font(BoardInk.sans(10.5)).tracking(1.6).foregroundStyle(Paper.muted).padding(.top, 4)
        if log.items.isEmpty {
            Text("Notifications show up here, so you can read them again after they’ve gone from your lock screen.")
                .font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.muted).fixedSize(horizontal: false, vertical: true)
        }
        let days = Dictionary(grouping: log.items) { Calendar.current.startOfDay(for: $0.at) }.sorted { $0.key > $1.key }
        ForEach(days, id: \.key) { day, list in
            Text(Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInYesterday(day) ? "Yesterday" : Self.dayName(day))
                .font(BoardInk.sans(13)).foregroundStyle(Paper.ink).padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(list.sorted { $0.at > $1.at }) { n in row(n) }
            }
            .background(Paper.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.edge, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func row(_ n: LoggedNotice) -> some View {
        let st = NoticeBanner.style(n.kind)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: st.icon).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(st.color, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title).font(BoardInk.sans(14)).foregroundStyle(Paper.ink).fixedSize(horizontal: false, vertical: true)
                if !n.body.isEmpty { Text(n.body).font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.75)).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 4)
            Text(Fmt.hhmm(n.at)).font(BoardInk.sans(12)).foregroundStyle(Paper.muted).monospacedDigit()
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.rule).frame(height: 1) }
    }

    private static func dayName(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE d MMMM"
        return f.string(from: d)
    }
}
