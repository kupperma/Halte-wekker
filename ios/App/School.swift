import BackgroundTasks
import CoreLocation
import EventKit
import SwiftUI
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

/// The school alarm: it reads your school timetable (only the calendars you pick, the one TimeEdit fills), takes the
/// first class of the next school day, plans the trip there from home with live times (the one that leaves the latest
/// and still gets you to BUas a little before class), and sets an alarm an hour (or what you pick) before you have to leave.
@MainActor
final class SchoolAlarm: ObservableObject {
    static let shared = SchoolAlarm()
    weak var trip: TripManager?
    private let store = EKEventStore()
    private let d = UserDefaults.standard

    @Published var on: Bool { didSet { d.set(on, forKey: "school.on"); if on { Task { await self.start() } } else { stop() } } }
    @Published var calendarIds: Set<String> { didSet { d.set(Array(calendarIds), forKey: "school.cals"); settingsChanged() } }
    /// How early you want to be at BUas before class.
    @Published var earlyMinutes: Int { didSet { d.set(earlyMinutes, forKey: "school.early"); settingsChanged() } }
    /// How long before you have to leave it wakes you.
    @Published var wakeMinutes: Int { didSet { d.set(wakeMinutes, forKey: "school.wake"); settingsChanged() } }
    @Published private(set) var allowed = false
    @Published private(set) var note: String?
    /// True when it rings as a real alarm (iOS 26 and later); otherwise it's loud notifications.
    @Published private(set) var realAlarm = false

    /// One school day: its first class, the trip and the alarm (kept, so a day's alarm can be moved or taken away later).
    struct Planned: Codable, Equatable, Identifiable {
        var id: String { day }
        let day: String                 // yyyy-MM-dd
        var title: String
        var room: String?
        var classStart: Date
        var beThere: Date
        var leave: Date?
        var arrive: Date?
        var lines: String?              // "306 · IC · 1"
        var alarm: Date?
        var alarmId: String?
        var checked: Date               // when its trip was last planned
        /// The alarm has gone off (or its time has passed): never touched again, so it can't ring twice.
        var rang: Bool { (alarm ?? .distantFuture) <= Date() }
    }

    /// The next school day, with the full trip (for the metro line), for the screens.
    struct Day: Equatable {
        let title: String
        let room: String?
        let classStart: Date
        let beThere: Date
        var trip: DoorTrip?
        var leave: Date?
        var alarm: Date?
    }

    /// The school days of the next week, the next one first.
    @Published private(set) var week: [Planned] = []
    private var trips: [String: DoorTrip] = [:]         // this session's trips, by day

    private var lastPlan = Date.distantPast
    private var observer: NSObjectProtocol?

    private init() {
        on = d.bool(forKey: "school.on")
        calendarIds = Set(d.stringArray(forKey: "school.cals") ?? [])
        earlyMinutes = d.object(forKey: "school.early") as? Int ?? 10
        wakeMinutes = d.object(forKey: "school.wake") as? Int ?? 60
        allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        realAlarm = WakeAlarm.available
        week = (d.data(forKey: "school.week").flatMap { try? JSONDecoder().decode([Planned].self, from: $0) } ?? [])
            .filter { $0.classStart > Date().addingTimeInterval(-2 * 86400) }
        updateNext()
        // the timetable changed (TimeEdit synced): plan again
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in await SchoolAlarm.shared.refresh(force: true) }
        }
    }

    private func save() { d.set(try? JSONEncoder().encode(week), forKey: "school.week") }

    /// The next school day (whose class is still ahead), for the screens.
    @Published private(set) var next: Day?
    private func updateNext() {
        guard let p = week.filter({ $0.classStart > Date() }).min(by: { $0.classStart < $1.classStart }) else { next = nil; return }
        next = Day(title: p.title, room: p.room, classStart: p.classStart, beThere: p.beThere, trip: trips[p.day], leave: p.leave, alarm: p.alarm)
    }

    /// Turned on: ask for the calendar and the alarm, pick the school calendar, plan.
    func start() async {
        if !allowed {
            allowed = (try? await store.requestFullAccessToEvents()) ?? false
        }
        guard allowed else { note = "Allow calendar access to read your timetable."; return }
        if calendarIds.isEmpty { calendarIds = suggested() }
        realAlarm = await WakeAlarm.requestPermission()
        await refresh(force: true)
    }

    /// Turned off: every alarm that hasn't rung goes.
    private func stop() {
        for p in week where !p.rang { WakeAlarm.cancel(p.alarmId, day: p.day) }
        week = []; trips = [:]; save()
        next = nil; note = nil
    }

    // MARK: the timetable

    /// Your calendars (to pick the school one).
    var calendars: [EKCalendar] { allowed ? store.calendars(for: .event).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } : [] }

    /// Does this look like the school timetable? Its name (TimeEdit, BUas, rooster), or its events (TimeEdit links, BUas rooms).
    func looksLikeSchool(_ c: EKCalendar) -> Bool {
        let name = (c.title + " " + c.source.title).lowercased()
        if ["timeedit", "buas", "rooster", "breda university", "school", "timetable"].contains(where: { name.contains($0) }) { return true }
        let now = Date()
        let evs = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-7 * 86400), end: now.addingTimeInterval(14 * 86400), calendars: [c]))
        return evs.prefix(60).contains { e in
            let s = [e.url?.absoluteString ?? "", e.notes ?? "", e.location ?? ""].joined(separator: " ").lowercased()
            return s.contains("timeedit") || s.contains("buas") || s.contains("hopmansstraat")
        }
    }

    func suggested() -> Set<String> { Set(store.calendars(for: .event).filter(looksLikeSchool).map(\.calendarIdentifier)) }

    /// The first class of each day with school in the next week, by day (yyyy-MM-dd). Only the calendars you picked;
    /// all-day and cancelled ones don't count.
    private func firstClasses() -> [String: EKEvent] {
        let cals = store.calendars(for: .event).filter { calendarIds.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return [:] }
        let now = Date(), startOfToday = Calendar.current.startOfDay(for: now)
        let evs = store.events(matching: store.predicateForEvents(withStart: startOfToday, end: startOfToday.addingTimeInterval(8 * 86400), calendars: cals))
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.isCancelled($0.title ?? "") }
        var out: [String: EKEvent] = [:]
        for e in evs {
            let k = Fmt.ymd.string(from: e.startDate)
            if out[k].map({ e.startDate < $0.startDate }) ?? true { out[k] = e }
        }
        return out
    }

    private static func isCancelled(_ t: String) -> Bool {
        let l = t.lowercased()
        return ["cancelled", "canceled", "geannuleerd", "vervalt", "vervallen"].contains { l.contains($0) }
    }

    // MARK: the plans and the alarms

    /// Plan the week again: every 15 minutes for today and tomorrow, every few hours for the days after, and right away
    /// when the timetable or the settings change. An alarm that has gone off is never touched again.
    /// A setting changed (how early, when to wake, which calendars): plan again as soon as you stop tapping.
    private func settingsChanged() {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh(force: true, now: true)
        }
    }
    private var debounce: Task<Void, Never>?
    private var running = false
    private var again = false

    /// One plan at a time: a change that comes in while it's planning runs again right after, so none is lost.
    func refresh(force: Bool = false, now immediate: Bool = false) async {
        guard on else { return }
        if running { if force || immediate { again = true }; return }
        guard immediate || Date().timeIntervalSince(lastPlan) > (force ? 30 : 5 * 60) else { return }
        running = true
        repeat {
            again = false
            lastPlan = Date()
            await plan(force: force || immediate)
        } while again && on
        running = false
    }

    private func plan(force: Bool) async {
        allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard allowed else { note = "Allow calendar access to read your timetable."; return }
        let classes = firstClasses()
        let now = Date()
        let oldNext = next
        var changed = false, added: [Planned] = []
        // days whose first class is gone from the timetable: their alarm goes (if it hasn't rung)
        for p in week where classes[p.day] == nil && !p.rang && p.classStart > now {
            WakeAlarm.cancel(p.alarmId, day: p.day)
            week.removeAll { $0.day == p.day }; trips[p.day] = nil; changed = true
        }
        for k in classes.keys.sorted() {
            guard let e = classes[k] else { continue }
            let old = week.first { $0.day == k }
            if let old, old.rang { continue }                               // it rang: leave it alone
            guard e.startDate > now.addingTimeInterval(20 * 60) else { continue }
            let beThere = e.startDate.addingTimeInterval(-Double(earlyMinutes) * 60)
            // near days often (live times), far days now and then (the timetable); always when the class moved
            let soon = e.startDate.timeIntervalSince(now) < 36 * 3600
            let moved = old.map { $0.classStart != e.startDate || $0.beThere != beThere } ?? true
            if !force && !moved, let old, now.timeIntervalSince(old.checked) < (soon ? 14 * 60 : 6 * 3600) { continue }
            let all = await Transit.plan(from: homeStart(), to: .buas, modes: nil, at: beThere, count: 6, maxTransfers: 4, arriveBy: true)
            guard on else { return }
            var seen = Set<String>()
            let inTime = all.filter { $0.end <= beThere.addingTimeInterval(60) && $0.first.departure > now && seen.insert($0.id).inserted }
            guard let best = inTime.max(by: { ($0.start, -$0.rides.count) < ($1.start, -$1.rides.count) }) else {
                continue                                                    // no answer just now: keep what it had
            }
            trips[k] = best
            let alarmAt = best.start.addingTimeInterval(-Double(wakeMinutes) * 60)
            var p = old ?? Planned(day: k, title: e.title ?? "Class", room: e.location, classStart: e.startDate, beThere: beThere, checked: now)
            p.title = e.title ?? "Class"; p.room = e.location; p.classStart = e.startDate; p.beThere = beThere
            p.leave = best.start; p.arrive = best.end; p.checked = now
            p.lines = best.rides.map { $0.isTrain ? $0.line : $0.line }.joined(separator: " · ")
            // move the alarm only if its minute changed; set none if it's already too late for one
            let sameMinute = p.alarm.map { Int($0.timeIntervalSince1970 / 60) == Int(alarmAt.timeIntervalSince1970 / 60) } ?? false
            if !(sameMinute && p.alarmId != nil) {
                WakeAlarm.cancel(p.alarmId, day: k)
                p.alarmId = nil
                p.alarm = alarmAt
                if alarmAt > now.addingTimeInterval(60) {
                    p.alarmId = await WakeAlarm.schedule(at: alarmAt, day: k, title: "Time to get up",
                                                         body: "Leave \(Fmt.hhmm(best.start)) for your \(Fmt.hhmm(e.startDate)) class")
                }
                changed = true
                if old == nil || old?.alarmId == nil { added.append(p) }
            }
            if let i = week.firstIndex(where: { $0.day == k }) { week[i] = p } else { week.append(p) }
        }
        week.removeAll { $0.classStart < now.addingTimeInterval(-2 * 86400) }
        week.sort { $0.classStart < $1.classStart }
        save()
        realAlarm = WakeAlarm.available
        updateNext()
        note = classes.isEmpty ? (calendarIds.isEmpty ? "Pick your school calendar." : "No classes found in the next week.") : nil
        if changed { tell(added: added, oldNext: oldNext) }
        Self.scheduleBackground()
    }

    /// Say what changed: the new alarms of the week, or the next one moving by 5 minutes or more.
    private func tell(added: [Planned], oldNext: Day?) {
        let set = added.filter { ($0.alarm ?? .distantPast) > Date() }
        if !set.isEmpty {
            let list = set.prefix(5).map { "\(Self.shortDay($0.classStart)) \(Fmt.hhmm($0.alarm!))" }.joined(separator: " · ")
            let title = set.count == 1 ? "School alarm \(Self.dayWord(set[0].alarm!)) \(Fmt.hhmm(set[0].alarm!))" : "\(set.count) school alarms set"
            let body = set.count == 1 ? "Leave \(Fmt.hhmm(set[0].leave!)) · first class \(Fmt.hhmm(set[0].classStart)) \(set[0].title)" : list
            NoticeLog.shared.add(key: "school-set-\(list)", title: title, body: body, kind: "ok")
            Notices.shared.show(title: title, body: body, kind: "ok")
        } else if let o = oldNext, let n = next, o.classStart == n.classStart, let a = o.alarm, let b = n.alarm, abs(b.timeIntervalSince(a)) >= 5 * 60, b > Date() {
            let title = "School alarm moved to \(Fmt.hhmm(b))"
            let body = "Was \(Fmt.hhmm(a)) · the buses changed · leave \(Fmt.hhmm(n.leave ?? b)) for \(Fmt.hhmm(n.classStart)) \(n.title)"
            NoticeLog.shared.add(key: "school-move-\(Int(b.timeIntervalSince1970))", title: title, body: body, kind: "late")
            Notices.shared.show(title: title, body: body, kind: "late")
        }
    }

    /// From home: where you are now if that's in Veghel (and it remembers it), else where it last saw you there, else your
    /// Veghel stops.
    private func homeStart() -> Place {
        let veghel = CLLocation(latitude: Place.veghel.coordinate.latitude, longitude: Place.veghel.coordinate.longitude)
        if let l = trip?.lastFix, l.timestamp.timeIntervalSinceNow > -2 * 3600, l.horizontalAccuracy < 200, l.distance(from: veghel) < 6000 {
            d.set(l.coordinate.latitude, forKey: "school.homeLat"); d.set(l.coordinate.longitude, forKey: "school.homeLon")
            return .here(l.coordinate)
        }
        if let a = d.object(forKey: "school.homeLat") as? Double, let o = d.object(forKey: "school.homeLon") as? Double {
            return .here(.init(latitude: a, longitude: o))
        }
        return StopsStore.shared.veghel
    }

    static let backgroundId = "nl.haltewekker.app.plan"

    /// Ask iOS to wake the app now and then (about every hour) to plan the alarms again.
    static func scheduleBackground() {
        guard UserDefaults.standard.bool(forKey: "school.on") else { return }
        let r = BGAppRefreshTaskRequest(identifier: backgroundId)
        r.earliestBeginDate = Date().addingTimeInterval(50 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Woken in the background: plan again, and ask to be woken again.
    static func backgroundRefresh() async {
        scheduleBackground()
        await shared.refresh(force: true)
    }

    /// "today", "tomorrow", "Monday"
    static func dayWord(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "today" }
        if cal.isDateInTomorrow(d) { return "tomorrow" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    /// "Mon"
    static func shortDay(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE"
        return f.string(from: d)
    }
}

// MARK: the alarm itself

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct WakeMetadata: AlarmMetadata {}
#endif

/// A real alarm with AlarmKit (iOS 26: it rings like the Clock app's, also on silent and in a Focus), one per school day.
/// Before iOS 26 it's three loud notifications two minutes apart instead.
enum WakeAlarm {
    static var available: Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return AlarmManager.shared.authorizationState == .authorized }
        #endif
        return false
    }

    static func requestPermission() async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            if AlarmManager.shared.authorizationState == .notDetermined { _ = try? await AlarmManager.shared.requestAuthorization() }
            return AlarmManager.shared.authorizationState == .authorized
        }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        return false
    }

    /// Set the alarm for a day. Returns its id (the alarm's, or "notifications").
    static func schedule(at date: Date, day: String, title: String, body: String) async -> String? {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), await requestPermission() {
            let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill")
            let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stop)
            let attributes = AlarmAttributes<WakeMetadata>(presentation: AlarmPresentation(alert: alert), metadata: WakeMetadata(), tintColor: Color(hex: 0xF0D722))
            let id = UUID()
            do {
                _ = try await AlarmManager.shared.schedule(id: id, configuration: .alarm(schedule: .fixed(date), attributes: attributes))
                return id.uuidString
            } catch {}
        }
        #endif
        // loud notifications instead (they can't ring on silent)
        let c = UNUserNotificationCenter.current()
        for i in 0..<3 {
            let n = UNMutableNotificationContent()
            n.title = i == 0 ? "⏰ \(title)" : "⏰ \(title) (again)"
            n.body = body
            n.sound = .default
            n.interruptionLevel = .timeSensitive
            n.userInfo = ["kind": "go"]
            let at = date.addingTimeInterval(Double(i) * 120)
            c.add(UNNotificationRequest(identifier: "wake-\(day)-\(i)", content: n, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false))) { _ in }
        }
        return "notifications"
    }

    /// Whether iOS lets it set alarms, in words.
    static var permission: (ok: Bool, text: String) {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return (true, "Alarms are allowed")
            case .denied: return (false, "Alarms aren’t allowed: turn them on in Settings › Haltewekker")
            default: return (false, "It hasn’t asked to set alarms yet")
            }
        }
        #endif
        return (false, "Real alarms need iOS 26: it uses loud notifications instead")
    }

    /// The alarms iOS has set for the app right now (to check they're really there).
    static func setOnPhone() -> [Date] {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let list = try? AlarmManager.shared.alarms {
            return list.compactMap { a -> Date? in
                if case .fixed(let d)? = a.schedule { return d }
                return nil
            }
            .filter { $0 > Date() }.sorted()
        }
        #endif
        return []
    }

    /// A test: the same kind of alarm, ringing in a minute. Returns when it rings, or nil if it couldn't be set.
    static func test() async -> Date? {
        let at = Date().addingTimeInterval(60)
        let old = UserDefaults.standard.string(forKey: "school.testId")
        cancel(old, day: "test")
        let id = await schedule(at: at, day: "test", title: "Test alarm", body: "Your school alarm works")
        UserDefaults.standard.set(id, forKey: "school.testId")
        return id == nil ? nil : at
    }

    /// Take a day's alarm away (only ever called for one that hasn't rung).
    static func cancel(_ id: String?, day: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: (0..<3).map { "wake-\(day)-\($0)" })
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let s = id, let u = UUID(uuidString: s) {
            try? AlarmManager.shared.cancel(id: u)
        }
        #endif
    }
}

// MARK: on screen

/// Settings: turn it on, pick the school calendar, how early, how long before leaving it wakes you, and what's next.
struct SchoolAlarmSection: View {
    @ObservedObject private var school = SchoolAlarm.shared
    var body: some View {
        Section {
            Toggle(isOn: $school.on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wake me for school")
                    Text("From your TimeEdit timetable: the first class of the next school day, the trip there, and an alarm before you have to leave.")
                        .font(HWFont.body(12)).foregroundStyle(Paper.muted)
                }
            }
            if school.on {
                if !school.allowed {
                    Button("Allow calendar access") { Task { await school.start() } }.foregroundStyle(Paper.navy)
                } else {
                    NavigationLink {
                        SchoolCalendarsView()
                    } label: {
                        HStack {
                            Text("School calendar")
                            Spacer()
                            Text(school.calendarIds.isEmpty ? "Pick one" : "\(school.calendarIds.count) picked").foregroundStyle(Paper.muted)
                        }
                    }
                    Stepper("At BUas \(school.earlyMinutes) min before class", value: $school.earlyMinutes, in: 0...45, step: 5)
                    Stepper("Wake me \(school.wakeMinutes) min before I leave", value: $school.wakeMinutes, in: 15...150, step: 5)
                    if let n = school.next {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(SchoolAlarm.dayWord(n.classStart).capitalizedFirst): \(n.title) at \(Fmt.hhmm(n.classStart))").font(HWFont.body(13, bold: true))
                            if let a = n.alarm, let l = n.leave {
                                Text("Alarm \(Fmt.hhmm(a)) · leave \(Fmt.hhmm(l)) · at BUas \(Fmt.hhmm(n.trip?.end ?? n.beThere))").font(HWFont.body(12)).foregroundStyle(Paper.muted)
                            }
                        }
                    }
                    if let note = school.note { Text(note).font(HWFont.body(12)).foregroundStyle(Paper.late) }
                    AlarmCheck()
                    if !school.realAlarm {
                        Text("On this iPhone it wakes you with loud notifications (they stay quiet on silent). With iOS 26 it’s a real alarm, like the Clock app’s.")
                            .font(HWFont.body(11.5)).foregroundStyle(Paper.muted)
                    }
                }
            }
        } header: { Text("School alarm") } footer: {
            Text("Only the calendars you pick are read, and only the first class of each day counts. Your own plans in other calendars are never used.")
        }
    }
}

/// Which calendars are your school timetable. The ones that look like it (TimeEdit, BUas) are picked for you.
struct SchoolCalendarsView: View {
    @ObservedObject private var school = SchoolAlarm.shared
    var body: some View {
        List {
            Section {
                ForEach(school.calendars, id: \.calendarIdentifier) { c in
                    let picked = school.calendarIds.contains(c.calendarIdentifier)
                    Button {
                        if picked { school.calendarIds.remove(c.calendarIdentifier) } else { school.calendarIds.insert(c.calendarIdentifier) }
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Color(cgColor: c.cgColor)).frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.title).foregroundStyle(Paper.ink)
                                Text(school.looksLikeSchool(c) ? "\(c.source.title) · looks like your timetable" : c.source.title)
                                    .font(HWFont.body(11.5)).foregroundStyle(school.looksLikeSchool(c) ? Paper.ok : Paper.muted)
                            }
                            Spacer()
                            if picked { Image(systemName: "checkmark").foregroundStyle(Paper.navy).font(.system(size: 14, weight: .bold)) }
                        }
                    }
                }
            } footer: {
                Text("Pick only the calendar TimeEdit fills. The first class of each day in it sets the alarm; nothing else is read.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PaperFill().ignoresSafeArea())
        .navigationTitle("School calendar")
    }
}

/// On the Planned tab: the next school day, the alarm, when to leave, and the trip as a metro line.
struct SchoolAlarmCard: View {
    @ObservedObject private var school = SchoolAlarm.shared
    let setUp: () -> Void
    var body: some View {
        if school.on, let n = school.next {
            VStack(alignment: .leading, spacing: 10) {
                PaperBand(home: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SCHOOL ALARM · \(SchoolAlarm.dayWord(n.classStart).uppercased())").font(BoardInk.sans(10)).tracking(1.6).opacity(0.85)
                        Text("\(Fmt.hhmm(n.classStart)) \(n.title)").font(HWFont.display(21)).lineLimit(1).minimumScaleFactor(0.6)
                        if let r = n.room, !r.isEmpty { Text(r).font(BoardInk.sans(11, .medium)).opacity(0.85).lineLimit(1) }
                    }
                }
                .padding(.horizontal, -14).padding(.top, -14)
                if let a = n.alarm, let l = n.leave {
                    HStack(alignment: .lastTextBaseline) {
                        stat("ALARM", Fmt.hhmm(a), big: true)
                        Spacer()
                        stat("LEAVE", Fmt.hhmm(l), big: false)
                        Spacer()
                        stat("AT BUAS", Fmt.hhmm(n.trip?.end ?? n.beThere), big: false)
                    }
                    if a < Date() {
                        Text("The alarm time has passed: leave by \(Fmt.hhmm(l)).").font(BoardInk.sans(12)).foregroundStyle(Paper.late)
                    } else {
                        Text(school.realAlarm ? "The alarm is set: it rings like the Clock app’s." : "It wakes you with loud notifications at \(Fmt.hhmm(a)).")
                            .font(BoardInk.sans(11.5, .regular)).foregroundStyle(Paper.muted)
                    }
                    if let t = n.trip {
                        Rectangle().fill(Paper.rule).frame(height: 1)
                        TripLine(trip: t, others: [], dest: "BUas")
                    }
                } else {
                    Text(school.note ?? "Planning the trip…").font(BoardInk.sans(12.5)).foregroundStyle(Paper.muted)
                }
                weekList
                AlarmCheck(compact: true)
                Button(action: setUp) {
                    Text("School alarm settings").font(BoardInk.sans(12)).foregroundStyle(Paper.navy).underline()
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Paper.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.edge, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Button(action: setUp) {
                HStack(spacing: 12) {
                    Image(systemName: "alarm.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Paper.ink)
                        .frame(width: 32, height: 32).background(Paper.yellow, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(school.on ? "School alarm" : "Wake me for school").font(HWFont.display(17)).foregroundStyle(Paper.ink)
                        Text(school.on ? (school.note ?? "Looking at your timetable…") : "From your TimeEdit timetable: the trip to your first class, and an alarm an hour before you have to leave.")
                            .font(HWFont.body(12)).foregroundStyle(Paper.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Paper.ink.opacity(0.8))
                }
                .contentShape(Rectangle())
                .padding(14)
                .background(Paper.card, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.edge, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    /// Every school day of the week with its alarm: the ones that rang are done and stay as they were.
    @ViewBuilder private var weekList: some View {
        let days = school.week.filter { $0.classStart > Date().addingTimeInterval(-12 * 3600) }
        if days.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                Text("THIS WEEK").font(BoardInk.sans(10)).tracking(1.6).foregroundStyle(Paper.muted).padding(.bottom, 4)
                ForEach(days) { p in
                    HStack(spacing: 8) {
                        Text(SchoolAlarm.shortDay(p.classStart)).font(BoardInk.sans(12.5)).foregroundStyle(Paper.ink).frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Fmt.hhmm(p.classStart)) \(p.title)").font(BoardInk.sans(12.5)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.7)
                            Text([p.leave.map { "leave \(Fmt.hhmm($0))" }, p.lines].compactMap { $0 }.joined(separator: " · "))
                                .font(BoardInk.sans(10.5, .regular)).foregroundStyle(Paper.muted).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let a = p.alarm {
                            HStack(spacing: 4) {
                                Image(systemName: p.rang ? "checkmark" : p.alarmId == nil ? "alarm" : "alarm.fill").font(.system(size: 10, weight: .bold))
                                Text(Fmt.hhmm(a)).font(BoardInk.sans(13)).monospacedDigit()
                            }
                            .foregroundStyle(p.rang ? Paper.muted : p.alarmId == nil ? Paper.late : Paper.navy)
                        }
                    }
                    .padding(.vertical, 6)
                    .opacity(p.rang ? 0.55 : 1)
                    .overlay(alignment: .bottom) { Rectangle().fill(Paper.rule).frame(height: 1) }
                }
                Text("Each day’s alarm moves with the buses until it has rung; then it’s left alone.")
                    .font(BoardInk.sans(10, .regular)).foregroundStyle(Paper.muted).padding(.top, 5)
            }
        }
    }

    private func stat(_ k: String, _ v: String, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(k).font(BoardInk.sans(10)).tracking(1.4).foregroundStyle(Paper.muted)
            Text(v).font(HWFont.display(big ? 32 : 22)).foregroundStyle(big ? Paper.navy : Paper.ink).monospacedDigit()
        }
    }
}

/// Is the alarm working? Whether iOS allows it, the alarms iOS really has set, and a test that rings in a minute.
struct AlarmCheck: View {
    var compact = false
    @State private var testAt: Date?
    @State private var failed = false
    @State private var onPhone: [Date] = []
    var body: some View {
        let perm = WakeAlarm.permission
        VStack(alignment: .leading, spacing: 6) {
            Label(perm.text, systemImage: perm.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(HWFont.body(12, bold: true)).foregroundStyle(perm.ok ? Paper.ok : Paper.late)
            if !perm.ok, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url).font(HWFont.body(12, bold: true)).foregroundStyle(Paper.navy)
            }
            if !onPhone.isEmpty {
                Text("Set on this iPhone: " + onPhone.prefix(7).map { "\(SchoolAlarm.shortDay($0)) \(Fmt.hhmm($0))" }.joined(separator: " · "))
                    .font(HWFont.body(11.5)).foregroundStyle(Paper.muted).fixedSize(horizontal: false, vertical: true)
            } else if perm.ok && !compact {
                Text("No alarms set on this iPhone yet.").font(HWFont.body(11.5)).foregroundStyle(Paper.muted)
            }
            Button {
                Task {
                    testAt = await WakeAlarm.test()
                    failed = testAt == nil
                    onPhone = WakeAlarm.setOnPhone()
                }
            } label: {
                Label("Test the alarm: it rings in 1 minute", systemImage: "alarm.waves.left.and.right.fill")
                    .font(HWFont.body(13, bold: true)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 10).background(Paper.navy, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            if let t = testAt {
                Text("Test alarm set for \(Fmt.hhmm(t)). Lock your phone (put it on silent too, if you like) and wait: it should ring like a Clock alarm.")
                    .font(HWFont.body(11.5)).foregroundStyle(Paper.ok).fixedSize(horizontal: false, vertical: true)
            } else if failed {
                Text("Couldn’t set the test alarm. Check that alarms are allowed for Haltewekker in Settings.")
                    .font(HWFont.body(11.5)).foregroundStyle(Paper.late).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { onPhone = WakeAlarm.setOnPhone() }
    }
}
