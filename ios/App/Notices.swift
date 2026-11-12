import SwiftUI

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

    private var style: (icon: String, color: Color) {
        switch notice.kind {
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
