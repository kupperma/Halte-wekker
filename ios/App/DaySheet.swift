import SwiftUI

/// What Your day reads beyond the school alarm: your school calendars' events (read only, 90 days), and the way home
/// after a day's classes (one plan per day shown, on the background lane, kept for the session).
@MainActor
final class DayModel: ObservableObject {
    @Published private(set) var events: [ComingUp.Event] = []
    @Published private(set) var loaded = false
    @Published private(set) var wayHome: [String: DoorTrip] = [:]
    private var askedHome = Set<String>()
    private var loadedAt: Date?

    func load() async {
        if let l = loadedAt, Date().timeIntervalSince(l) < 300 { return }
        events = await SchoolAlarm.shared.schoolEvents(days: 90)
        loadedAt = Date(); loaded = true
    }

    /// The trip home after `end` on `day` (once per day, whatever the answer).
    func askWayHome(day: String, after end: Date) async {
        guard askedHome.insert(day).inserted else { return }
        let places = PlacesStore.shared
        guard let s = places.school, let h = places.home else { return }
        let at = max(end.addingTimeInterval(5 * 60), Date())
        let trips = await Transit.plan(from: places.place(s), to: places.place(h), modes: nil, at: at, count: 3, maxTransfers: 4)
        if let t = trips.filter({ $0.start >= at.addingTimeInterval(-60) }).min(by: { $0.end < $1.end }) { wayHome[day] = t }
    }
}

/// Your day (artboard C3): pulled up from the departure cards. One day at a time: the wake-up alarm (on or off for that
/// day), when to leave and the rides, the first class and until when, and the way home; then Coming up and what's watched.
struct DaySheet: View {
    let close: () -> Void
    @ObservedObject private var school = SchoolAlarm.shared
    @ObservedObject private var log = NoticeLog.shared
    @EnvironmentObject var lines: LineWatchStore
    @EnvironmentObject var trains: WatchStore
    @StateObject private var model = DayModel()
    @State private var day: Date?
    @State private var showNotices = false
    private let cal = Calendar.current

    private var today: Date { cal.startOfDay(for: Date()) }
    private var shownDay: Date { day ?? defaultDay }
    private var key: String { Fmt.ymd.string(from: shownDay) }

    private var defaultDay: Date {
        let k = Fmt.ymd.string(from: Date())
        let first = school.week.first { $0.day == k }?.classStart ?? model.events.filter { !$0.allDay && !$0.cancelled && cal.isDateInToday($0.start) }.map(\.start).min()
        return DayTimeline.defaultDay(now: Date(), todayFirst: first, todayEnd: SchoolAlarm.classesEnd(model.events, on: Date()), cal: cal)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Text(DayTimeline.title(shownDay, now: Date(), cal: cal)).font(DS.largeTitle).foregroundStyle(DS.text)
                    .accessibilityAddTraits(.isHeader)
                if let n = latestNotice { noticeCard(n) }
                timeline
                comingUp
                watching
            }
            .padding(.horizontal, DS.s20).padding(.top, 8).padding(.bottom, 32)
        }
        .background(DS.surface.ignoresSafeArea())
        .task { await model.load() }
        .task(id: key) {
            await model.load()
            if let end = SchoolAlarm.classesEnd(model.events, on: shownDay), school.on || !model.events.isEmpty {
                await model.askWayHome(day: key, after: end)
            }
        }
        .sheet(isPresented: $showNotices) { NotificationsSheet().presentationDetents([.medium, .large]) }
    }

    // MARK: top

    private var header: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.down").font(.body.weight(.bold)).foregroundStyle(DS.text)
                    .frame(width: 44, height: 44).background(DS.surface3, in: Circle())
            }
            .buttonStyle(DSPressStyle())
            .accessibilityLabel("Back to the map")
            Spacer()
            HStack(spacing: 4) {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .disabled(shownDay <= today).accessibilityLabel("Previous day")
                Text(DayTimeline.label(shownDay, cal: cal)).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                    .frame(minWidth: 100)
                Button { step(1) } label: {
                    Image(systemName: "chevron.right").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .disabled(shownDay >= cal.date(byAdding: .day, value: 13, to: today)!).accessibilityLabel("Next day")
            }
            .foregroundStyle(DS.text)
        }
        .padding(.top, 8)
    }

    private func step(_ n: Int) {
        withAnimation(DS.quick) { day = cal.date(byAdding: .day, value: n, to: shownDay) }
    }

    private var latestNotice: LoggedNotice? {
        log.items.first { $0.at > Date().addingTimeInterval(-12 * 3600) }
    }

    private func noticeCard(_ n: LoggedNotice) -> some View {
        Button { log.markRead(); showNotices = true } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: n.kind == "late" || n.kind == "warn" ? "exclamationmark.triangle.fill" : "bell.fill")
                    .foregroundStyle(n.kind == "late" || n.kind == "warn" ? DS.warning : DS.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.title).font(DS.calloutStrong).foregroundStyle(DS.text).multilineTextAlignment(.leading)
                    if !n.body.isEmpty { Text(n.body).font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                    Text("\(Fmt.when(n.at)) · all notifications").font(DS.footnote).foregroundStyle(DS.accentText)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.s12)
            .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: the timeline

    private var planned: SchoolAlarm.Planned? { school.week.first { $0.day == key } }

    private var input: DayTimeline.Input? {
        let end = SchoolAlarm.classesEnd(model.events, on: shownDay)
        let home = model.wayHome[key]
        if let p = planned {
            var i = DayTimeline.Input(classStart: p.classStart, title: p.title, room: p.room)
            i.leave = p.leave; i.arrive = p.arrive; i.alarm = p.alarm; i.lines = p.lines
            i.wouldWake = p.leave.map { $0.addingTimeInterval(-Double(school.wakeMinutes) * 60) }
            i.skipped = school.isSkipped(p.day)
            i.rides = rides(school.plannedTrip(p.day))
            i.classesEnd = end; i.homeLeave = home?.start; i.homeArrive = home?.end
            return i
        }
        // classes in the calendar, but no trip planned for them (the alarms are off, or it's further ahead)
        let first = model.events.filter { !$0.allDay && !$0.cancelled && cal.isDate($0.start, inSameDayAs: shownDay) }.min { $0.start < $1.start }
        guard let f = first else { return nil }
        var i = DayTimeline.Input(classStart: f.start, title: f.title, room: nil)
        i.classesEnd = end; i.homeLeave = home?.start; i.homeArrive = home?.end
        return i
    }

    private func rides(_ t: DoorTrip?) -> [DayTimeline.Ride] {
        guard let t else { return [] }
        return t.rides.enumerated().map { k, r in
            var x = DayTimeline.Ride(line: r.line, train: r.isTrain, departure: r.departure, to: Fmt.place(r.toStop))
            if k > 0 {
                let prev = t.rides[k - 1]
                let ch = Fmt.mins(r.departure.timeIntervalSince(prev.arrival))
                x.change = ch
                x.tight = Risk.changeNote(after: prev, minutes: ch, walk: r.walkBefore).red
            }
            return x
        }
    }

    @ViewBuilder private var timeline: some View {
        if let i = input {
            let items = DayTimeline.items(i, clock: Fmt.hhmm)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { k, item in
                    if item.kind != .wake || planned != nil { row(item, last: k == items.count - 1) }
                }
            }
            if !school.on {
                Text("School alarms are off. Turn them on in Settings to be woken and to get the trip to your first class.")
                    .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.loaded || school.week.isEmpty == false ? "No classes on this day" : "Reading your timetable…").font(DS.headline).foregroundStyle(DS.text)
                Text(school.on ? "Nothing to wake you for: no alarm is set." : "School alarms are off. Turn them on in Settings, with your school calendar.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.s16)
            .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
        }
    }

    private func row(_ item: DayTimeline.Item, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.time.map(Fmt.hhmm) ?? "–").font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                .frame(width: 56, alignment: .leading).padding(.top, 1)
                .opacity(item.kind == .wake && planned.map { school.isSkipped($0.day) } == true ? 0.45 : 1)
            VStack(spacing: 0) {
                marker(item.kind).padding(.top, 4)
                if !last { Rectangle().fill(item.kind == .firstClass ? DS.divider : DS.accentSoft).frame(width: 2).frame(maxHeight: .infinity) }
            }
            .frame(width: 20)
            content(item).padding(.bottom, last ? 0 : 18)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func marker(_ k: DayTimeline.Kind) -> some View {
        switch k {
        case .wake: Circle().fill(DS.accent).frame(width: 14, height: 14)
        case .firstClass: RoundedRectangle(cornerRadius: 4).fill(DS.text).frame(width: 14, height: 14)
        default: Circle().strokeBorder(DS.accent, lineWidth: 3).background(Circle().fill(DS.surface)).frame(width: 14, height: 14)
        }
    }

    @ViewBuilder private func content(_ item: DayTimeline.Item) -> some View {
        switch item.kind {
        case .wake:
            if let p = planned {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: Binding(get: { !school.isSkipped(p.day) }, set: { school.setSkipped(p.day, !$0) })) {
                        Text(item.title).font(DS.bodyStrong).foregroundStyle(DS.text)
                    }
                    .tint(DS.accent)
                    .disabled(p.rang || !school.on)
                    .accessibilityHint("This day only")
                    Text(p.rang ? "It has rung" : item.detail ?? "This day only").font(DS.footnote).foregroundStyle(DS.secondary)
                }
            }
        case .leave:
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(DS.bodyStrong).foregroundStyle(DS.text)
                if !item.rides.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(item.rides.enumerated()), id: \.offset) { _, r in
                            HStack(spacing: 8) {
                                DSLinePill(line: r.line, train: r.train)
                                Text("\(Fmt.hhmm(r.departure)) → \(r.to)").font(DS.sub).monospacedDigit().foregroundStyle(DS.text).lineLimit(1)
                                if let c = r.change {
                                    Text("· \(c) min to change").font(DS.sub).monospacedDigit().foregroundStyle(r.tight ? DS.warning : DS.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(DS.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                }
                if let d = item.detail, !d.isEmpty { Text(d).font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary) }
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(DS.bodyStrong).foregroundStyle(DS.text)
                if let d = item.detail, !d.isEmpty { Text(d).font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    // MARK: coming up

    @ViewBuilder private var comingUp: some View {
        let r = ComingUp.build(model.events, now: Date(), cal: cal, limit: 5)
        VStack(alignment: .leading, spacing: 10) {
            Text("Coming up").font(DS.title).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
            if r.items.isEmpty {
                Text(model.loaded ? (r.knownUntil == nil ? "No dates known" : "Nothing special: classes every weekday.") : "Reading your timetable…")
                    .font(DS.sub).foregroundStyle(DS.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(Array(r.items.enumerated()), id: \.offset) { k, it in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.when).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(k == 0 ? DS.accentSoftText : DS.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(it.title).font(DS.calloutStrong).foregroundStyle(DS.text).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.s12)
                        .background(k == 0 ? DS.accentSoft : DS.surface2, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                    }
                }
            }
            if let u = r.knownUntil {
                Text("Schedule known until \(DayTimeline.label(u, cal: cal))").font(DS.footnote).foregroundStyle(DS.secondary)
            }
        }
        .padding(.top, 4)
    }

    // MARK: watching

    @ViewBuilder private var watching: some View {
        let manual = trains.watches.filter { !$0.auto && $0.target > Date().addingTimeInterval(-20 * 60) }
        if !lines.watches.isEmpty || !manual.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Watching").font(DS.title).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
                ForEach(lines.watches) { w in
                    let warn = w.status.contains("late") || w.status.contains("early") || w.status.contains("cancelled")
                    watchRow(pill: w.line, train: false, title: w.headsign.isEmpty ? "Line \(w.line)" : "to \(Fmt.place(w.headsign))",
                             sub: "From \(Fmt.place(w.stopName)) · \(w.status)", warn: warn) { lines.stop(w.id) }
                }
                ForEach(manual) { w in
                    watchRow(pill: w.label.lowercased().contains("sprinter") ? "SPR" : "IC", train: true, title: w.label,
                             sub: "From \(w.from) · " + (w.cancelled ? "Cancelled" : w.track.isEmpty ? "platform not known yet" : "platform \(w.track)"),
                             warn: w.cancelled) { trains.remove(w.key) }
                }
            }
        }
    }

    private func watchRow(pill: String, train: Bool, title: String, sub: String, warn: Bool, stop: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            DSLinePill(line: pill, train: train)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.calloutStrong).foregroundStyle(DS.text).lineLimit(1)
                Text(sub).font(DS.footnote).foregroundStyle(warn ? DS.warning : DS.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Stop", action: stop).font(DS.subStrong).foregroundStyle(DS.accentText).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Stop watching \(title)")
        }
    }
}
