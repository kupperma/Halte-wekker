import SwiftUI

// The notifications in the new look (0.21): the banner that pops up inside the app while it's open, and the sheet with
// what's watched and every notification you had. The same `Notices` and `NoticeLog` as `NoticeBanner` and
// `NotificationsSheet` (the old look keeps those), in the phone's light or dark.

/// The banner at the top: a card with an icon in its kind's colour, the headline and its line. Tap or swipe up to close.
struct NoticeBannerNew: View {
    let notice: Notice
    let close: () -> Void
    @State private var drag: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 40

    /// The icon and colour for each kind of notification, in the new tokens.
    static func style(_ kind: String) -> (icon: String, color: Color) {
        switch kind {
        case "late": return ("clock.badge.exclamationmark.fill", DS.warning)
        case "cancelled": return ("xmark.octagon.fill", DS.warning)
        case "faster": return ("bolt.fill", DS.accentText)
        case "go": return ("figure.walk", DS.accentText)
        case "ok": return ("checkmark.circle.fill", DS.accentText)
        case "friends": return ("bubble.left.fill", DS.accentText)
        default: return ("bell.fill", DS.accentText)
        }
    }

    var body: some View {
        let st = Self.style(notice.kind)
        HStack(alignment: .top, spacing: DS.s12) {
            Image(systemName: st.icon).font(.title3.weight(.semibold)).foregroundStyle(st.color)
                .frame(width: min(icon, 56), height: min(icon, 56))
                .background(st.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(DS.bodyStrong).foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !notice.body.isEmpty {
                    Text(notice.body).font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary).padding(.top, 2)
                .accessibilityHidden(true)
        }
        .padding(DS.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous).stroke(DS.divider, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .offset(y: min(0, drag))
        .gesture(DragGesture().onChanged { drag = $0.translation.height }.onEnded { v in
            if v.translation.height < -30 { close() } else { withAnimation(DS.move) { drag = 0 } }
        })
        .onTapGesture(perform: close)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Closes the message")
    }
}

/// What's being watched (with the button to stop it all), and every notification you had, newest first.
struct NotificationsSheetNew: View {
    @ObservedObject private var log = NoticeLog.shared
    @ObservedObject private var lines = LineWatchStore.shared
    @ObservedObject private var trains = WatchStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStop = false
    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 32

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s12) {
                    watching
                    history
                }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !log.items.isEmpty { ToolbarItem(placement: .cancellationAction) { Button("Clear") { log.clear() } } }
            }
            .onAppear { log.markRead() }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    // MARK: watching now

    /// The lines and trains it's watching for you, and the way to stop them all.
    @ViewBuilder private var watching: some View {
        let any = !lines.watches.isEmpty || !trains.watches.isEmpty
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Watching now", sub: any ? "\(lines.watches.count + trains.watches.count)" : nil)
            if !any {
                Text("Nothing is being watched, so no notifications are coming. Tap a departure on the home screen and pick Watch this line.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(lines.watches) { w in
                watchRow(line: w.line, train: false, title: "Bus \(w.line)\(w.headsign.isEmpty ? "" : " to \(Fmt.place(w.headsign))")",
                         sub: "\(Fmt.place(w.stopName)) · \(w.status)") { lines.stop(w.id) }
            }
            ForEach(trains.watches) { w in
                watchRow(line: w.label.contains("Sprinter") ? "SPR" : "IC", train: true, title: w.label,
                         sub: "from \(w.from)\(w.track.isEmpty ? "" : " · platform \(w.track)")") {
                    trains.remove(w.key)
                }
            }
            if any {
                Button(role: .destructive) { confirmStop = true } label: {
                    Label("Stop all notifications", systemImage: "bell.slash.fill")
                        .font(DS.bodyStrong).foregroundStyle(DS.warning)
                        .frame(maxWidth: .infinity, minHeight: DS.hit)
                        .background(DS.warning.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(DSPressStyle())
                .padding(.top, DS.s4)
                .confirmationDialog("Stop watching everything? No more notifications about these buses and trains.", isPresented: $confirmStop, titleVisibility: .visible) {
                    Button("Stop all notifications", role: .destructive) {
                        lines.reset()
                        for w in trains.watches { trains.remove(w.key) }
                    }
                }
            }
        }
        .dsPanel()
    }

    private func watchRow(line: String, train: Bool, title: String, sub: String, stop: @escaping () -> Void) -> some View {
        HStack(spacing: DS.s12) {
            DSLinePill(line: line, train: train)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.calloutStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                Text(sub).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button(action: stop) {
                Text("Stop").font(DS.subStrong).foregroundStyle(DS.warning)
                    .padding(.horizontal, DS.s12).frame(minHeight: DS.hit)
                    .background(DS.warning.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(DSPressStyle())
            .accessibilityLabel("Stop watching \(title)")
        }
        .padding(.vertical, 2)
    }

    // MARK: earlier notifications

    /// Every notification, by day.
    @ViewBuilder private var history: some View {
        Text("Earlier notifications").font(DS.headline).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
            .padding(.top, DS.s8).padding(.horizontal, DS.s4)
        if log.items.isEmpty {
            Text("Notifications show up here, so you can read them again after they’ve gone from your lock screen.")
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.s4)
        }
        let days = Dictionary(grouping: log.items) { Calendar.current.startOfDay(for: $0.at) }.sorted { $0.key > $1.key }
        ForEach(days, id: \.key) { day, list in
            VStack(alignment: .leading, spacing: DS.s12) {
                Text(Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInYesterday(day) ? "Yesterday" : Self.dayName(day))
                    .font(DS.subStrong).foregroundStyle(DS.secondary).accessibilityAddTraits(.isHeader)
                ForEach(list.sorted { $0.at > $1.at }) { n in row(n) }
            }
            .dsPanel()
        }
    }

    private func row(_ n: LoggedNotice) -> some View {
        let st = NoticeBannerNew.style(n.kind)
        return HStack(alignment: .top, spacing: DS.s12) {
            Image(systemName: st.icon).font(.subheadline.weight(.semibold)).foregroundStyle(st.color)
                .frame(width: min(icon, 44), height: min(icon, 44))
                .background(st.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title).font(DS.calloutStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                if !n.body.isEmpty {
                    Text(n.body).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Text(Fmt.hhmm(n.at)).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private static func dayName(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE d MMMM"
        return f.string(from: d)
    }
}
