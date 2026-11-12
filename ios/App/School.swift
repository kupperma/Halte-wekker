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
    @Published var calendarIds: Set<String> { didSet { d.set(Array(calendarIds), forKey: "school.cals"); Task { await self.refresh(force: true) } } }
    /// How early you want to be at BUas before class.
    @Published var earlyMinutes: Int { didSet { d.set(earlyMinutes, forKey: "school.early"); Task { await self.refresh(force: true) } } }
    /// How long before you have to leave it wakes you.
    @Published var wakeMinutes: Int { didSet { d.set(wakeMinutes, forKey: "school.wake"); Task { await self.refresh(force: true) } } }
    @Published private(set) var allowed = false
    @Published private(set) var next: Day?
    @Published private(set) var note: String?
    /// True when it rings as a real alarm (iOS 26 and later); otherwise it's loud notifications.
    @Published private(set) var realAlarm = false

    /// The next school day: its first class, and the trip and the alarm for it.
    struct Day: Equatable {
        let title: String
        let room: String?
        let classStart: Date
        let beThere: Date
        var trip: DoorTrip?
        var leave: Date? { trip?.start }
        var alarm: Date?
    }

    private var lastPlan = Date.distantPast
    private var observer: NSObjectProtocol?

    private init() {
        on = d.bool(forKey: "school.on")
        calendarIds = Set(d.stringArray(forKey: "school.cals") ?? [])
        earlyMinutes = d.object(forKey: "school.early") as? Int ?? 10
        wakeMinutes = d.object(forKey: "school.wake") as? Int ?? 60
        allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        realAlarm = WakeAlarm.available
        // the timetable changed (TimeEdit synced): plan again
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in await SchoolAlarm.shared.refresh(force: true) }
        }
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

    private func stop() {
        WakeAlarm.cancel()
        d.removeObject(forKey: "school.alarmKey")
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

    /// The first class of the next day with school that's still ahead (a day whose first class has started is skipped).
    private func nextFirstClass() -> EKEvent? {
        let cals = store.calendars(for: .event).filter { calendarIds.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return nil }
        let now = Date()
        let evs = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-14 * 3600), end: now.addingTimeInterval(9 * 86400), calendars: cals))
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.isCancelled($0.title ?? "") }
        let byDay = Dictionary(grouping: evs) { Calendar.current.startOfDay(for: $0.startDate) }
        for day in byDay.keys.sorted() {
            guard let first = byDay[day]?.min(by: { $0.startDate < $1.startDate }) else { continue }
            if first.startDate > now.addingTimeInterval(20 * 60) { return first }
        }
        return nil
    }

    private static func isCancelled(_ t: String) -> Bool {
        let l = t.lowercased()
        return ["cancelled", "canceled", "geannuleerd", "vervalt", "vervallen"].contains { l.contains($0) }
    }

    // MARK: the plan and the alarm

    /// Plan again (every 15 minutes while the app is open, and whenever the timetable or the settings change).
    func refresh(force: Bool = false) async {
        guard on else { return }
        allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard allowed else { next = nil; note = "Allow calendar access to read your timetable."; return }
        let since = Date().timeIntervalSince(lastPlan)
        guard since > (force ? 45 : 15 * 60) else { return }
        lastPlan = Date()
        guard let e = nextFirstClass() else {
            next = nil
            note = calendarIds.isEmpty ? "Pick your school calendar." : "No classes found in the next week."
            await setAlarm(nil)
            return
        }
        let beThere = e.startDate.addingTimeInterval(-Double(earlyMinutes) * 60)
        var day = Day(title: e.title ?? "Class", room: e.location, classStart: e.startDate, beThere: beThere)
        let all = await Transit.plan(from: homeStart(), to: .buas, modes: nil, at: beThere, count: 6, maxTransfers: 4, arriveBy: true)
        var seen = Set<String>()
        let inTime = all.filter { $0.end <= beThere.addingTimeInterval(60) && $0.first.departure > Date() && seen.insert($0.id).inserted }
        day.trip = inTime.max { ($0.start, -$0.rides.count) < ($1.start, -$1.rides.count) }      // leave the latest, then fewest changes
        if day.trip == nil, let old = next, old.classStart == day.classStart { day.trip = old.trip }   // no answer just now: keep the last plan
        day.alarm = day.trip.map { $0.start.addingTimeInterval(-Double(wakeMinutes) * 60) }
        next = day
        note = day.trip == nil ? "Couldn’t plan the trip yet. It tries again in a few minutes." : nil
        if day.trip == nil { lastPlan = Date().addingTimeInterval(-13 * 60) }
        await setAlarm(day)
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

    /// Set (or move, or take away) the alarm. It tells you once per school day, when it's first set or moves by 5 minutes.
    private func setAlarm(_ day: Day?) async {
        let at = day?.alarm.flatMap { $0 > Date().addingTimeInterval(60) ? $0 : nil }
        let key = at.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? ""
        let oldKey = d.string(forKey: "school.alarmKey") ?? ""
        guard key != oldKey else { return }
        WakeAlarm.cancel()
        d.set(key, forKey: "school.alarmKey")
        guard let at, let day, let leave = day.leave else { return }
        realAlarm = await WakeAlarm.schedule(at: at, title: "Time to get up", body: "Leave \(Fmt.hhmm(leave)) for your \(Fmt.hhmm(day.classStart)) class")
        let oldMinute = Int(oldKey) ?? 0, newMinute = Int(key) ?? 0
        if oldKey.isEmpty || abs(newMinute - oldMinute) >= 5 {
            let title = "School alarm \(Self.dayWord(at)) \(Fmt.hhmm(at))"
            let body = "Leave \(Fmt.hhmm(leave)) · at BUas \(Fmt.hhmm(day.trip?.end ?? day.beThere)) · first class \(Fmt.hhmm(day.classStart)) \(day.title)"
            NoticeLog.shared.add(key: "school-\(key)", title: title, body: body, kind: "ok")
            Notices.shared.show(title: title, body: body, kind: "ok")
        }
    }

    /// "today", "tomorrow", "Monday"
    static func dayWord(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "today" }
        if cal.isDateInTomorrow(d) { return "tomorrow" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE"
        return f.string(from: d)
    }
}

// MARK: the alarm itself

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct WakeMetadata: AlarmMetadata {}
#endif

/// A real alarm with AlarmKit (iOS 26: it rings like the Clock app's, also on silent and in a Focus). Before iOS 26 it's
/// three loud notifications two minutes apart instead.
enum WakeAlarm {
    private static let idKey = "school.alarmId"

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

    /// Returns true if it's a real alarm.
    static func schedule(at date: Date, title: String, body: String) async -> Bool {
        cancel()
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), await requestPermission() {
            let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill")
            let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stop)
            let attributes = AlarmAttributes<WakeMetadata>(presentation: AlarmPresentation(alert: alert), metadata: WakeMetadata(), tintColor: Color(hex: 0xF0D722))
            let id = UUID()
            do {
                _ = try await AlarmManager.shared.schedule(id: id, configuration: .alarm(schedule: .fixed(date), attributes: attributes))
                UserDefaults.standard.set(id.uuidString, forKey: idKey)
                return true
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
            c.add(UNNotificationRequest(identifier: "wake-\(i)", content: n, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false))) { _ in }
        }
        return false
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["wake-0", "wake-1", "wake-2"])
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let s = UserDefaults.standard.string(forKey: idKey), let id = UUID(uuidString: s) {
            try? AlarmManager.shared.cancel(id: id)
        }
        #endif
        UserDefaults.standard.removeObject(forKey: idKey)
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

    private func stat(_ k: String, _ v: String, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(k).font(BoardInk.sans(10)).tracking(1.4).foregroundStyle(Paper.muted)
            Text(v).font(HWFont.display(big ? 32 : 22)).foregroundStyle(big ? Paper.navy : Paper.ink).monospacedDigit()
        }
    }
}
