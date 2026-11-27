import BackgroundTasks
import Combine
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
    /// The trip (read only): set by TripManager as it starts, also when iOS starts the app in the background. (0.42.6)
    /// Its start, its end and where it goes tell whether you're already on the way this morning (`OnTheWay`).
    weak var trip: TripManager? { didSet { if let t = trip, t !== oldValue { watchMorning(t) } } }
    /// The calendar store, made in the background the first time it's needed (it loads your calendars).
    private var storeObj: EKEventStore?
    private func calendarStore() async -> EKEventStore {
        if let s = storeObj { return s }
        let s = await Task.detached { EKEventStore() }.value
        storeObj = s
        return s
    }
    private let d = UserDefaults.standard

    @Published var on: Bool { didSet { d.set(on, forKey: "school.on"); if on { Task { await self.start() } } else { stop() } } }
    @Published var calendarIds: Set<String> { didSet { d.set(Array(calendarIds), forKey: "school.cals"); settingsChanged() } }
    /// How early you want to be at school before class.
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
        /// (0.42.6) The words the alarm was set with ("title|body"): set again when they change (a new be-there time).
        var label: String?
        /// The alarm has gone off (or its time has passed): never touched again, so it can't ring twice.
        var rang: Bool { (alarm ?? .distantFuture) <= Date() }
    }

    /// The next school day, with the full trip (for the metro line), for the screens.
    struct Day: Equatable {
        var day: String = ""            // yyyy-MM-dd (0.42.6)
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
    /// The days (yyyy-MM-dd) whose wake-up alarm you turned off on Your day: that day only (`SchoolSkip`).
    @Published private(set) var skipped: Set<String> = []
    /// (0.42.6) "Be there at …" per day (yyyy-MM-dd), instead of the timetable's: gone after its day (`SchoolArrive`).
    @Published private(set) var arrive: [String: Date] = [:]
    /// (0.42.6) The days whose alarm was skipped because you were already on the way, and why (`OnTheWay`).
    @Published private(set) var going: [String: String] = [:]
    /// (0.42.6) The days you turned back on after such a skip: not skipped again.
    var keepRinging: Set<String> = []
    /// (0.42.6) What was seen this morning: a trip's start, toward school, at school, leaving home.
    var seen = OnTheWay.Seen(day: "")
    var morningSubs: Set<AnyCancellable> = []
    var lastTripPhase: TripManager.Phase = .idle
    private var trips: [String: DoorTrip] = [:]         // this session's trips, by day

    private var lastPlan = Date.distantPast
    private var observer: NSObjectProtocol?

    private init() {
        on = d.bool(forKey: "school.on")
        calendarIds = Set(d.stringArray(forKey: "school.cals") ?? [])
        earlyMinutes = d.object(forKey: "school.early") as? Int ?? 10
        wakeMinutes = d.object(forKey: "school.wake") as? Int ?? 60
        allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        week = (d.data(forKey: "school.week").flatMap { try? JSONDecoder().decode([Planned].self, from: $0) } ?? [])
            .filter { $0.classStart > Date().addingTimeInterval(-2 * 86400) }
        skipped = SchoolSkip.prune(Set(d.stringArray(forKey: SchoolSkip.key) ?? []), today: Fmt.ymd.string(from: Date()))
        loadMorning()
        updateNext()
        // the timetable changed (TimeEdit synced): plan again, once a burst of changes has settled
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in SchoolAlarm.shared.timetableChanged() }
        }
        // asking iOS about alarms can be slow right after installing: not while the app starts
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.realAlarm = await Task.detached { WakeAlarm.available }.value
        }
    }

    private func save() { d.set(try? JSONEncoder().encode(week), forKey: "school.week") }

    private var changeDebounce: Task<Void, Never>?
    /// TimeEdit (or anything) changed a calendar: wait until the changes stop, then plan once.
    func timetableChanged() {
        guard on else { return }
        changeDebounce?.cancel()
        changeDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh(force: true)
        }
    }

    /// The calendars that look like your timetable (worked out in the background).
    @Published private(set) var schoolLike: Set<String> = []
    func findSchoolLike() async {
        let st = await calendarStore(), hints = Self.hints
        let ids = await Task.detached { () -> Set<String> in
            return Set(st.calendars(for: .event).filter { SchoolAlarm.looksLikeSchool($0, in: st, hints: hints) }.map(\.calendarIdentifier))
        }.value
        schoolLike = ids
    }

    /// The words that mark your timetable calendar: 0.22's on the Veghel ⇄ BUas profile, else the timetable apps and
    /// your school's names (`SchoolHints`).
    static var hints: SchoolHints {
        SchoolHints.make(profileHints: ProfileStore.shared.profile.calendarHints, school: [RoleWords.current.school])
    }

    /// The next school day (whose class is still ahead), for the screens.
    @Published private(set) var next: Day?
    private func updateNext() {
        guard let p = week.filter({ $0.classStart > Date() }).min(by: { $0.classStart < $1.classStart }) else { next = nil; return }
        next = Day(day: p.day, title: p.title, room: p.room, classStart: p.classStart, beThere: p.beThere, trip: trips[p.day], leave: p.leave, alarm: p.alarm)
    }

    /// Turned on: ask for the calendar and the alarm, pick the school calendar, plan.
    func start() async {
        // (a week of your own, or none yet, needs no calendar: 0.23)
        if Self.schedule == .calendars {
            if !allowed {
                allowed = (try? await calendarStore().requestFullAccessToEvents()) ?? false
            }
            guard allowed else { note = "Allow calendar access to read your timetable."; return }
            if calendarIds.isEmpty { calendarIds = await suggested() }
        }
        realAlarm = await WakeAlarm.requestPermission()
        await refresh(force: true)
    }

    /// Where your first classes come from (the profile's; 0.22 and before: the calendars).
    static var schedule: ScheduleSource { ProfileStore.shared.profile.schedule }

    /// The setup's timetable step: ask for the calendar (in context), and load the calendars to show.
    func askCalendarAccess() async -> Bool {
        if !allowed {
            allowed = (try? await calendarStore().requestFullAccessToEvents()) ?? false
        }
        if allowed { await findSchoolLike() }
        return allowed
    }

    /// Your calendars as the setup shows them (none without access). `hints` marks the ones that look like a timetable.
    func setupCalendars(hints: SchoolHints) async -> (all: [SetupCalendar], school: Set<String>) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return ([], []) }
        allowed = true
        let st = await calendarStore()
        return await Task.detached { () -> ([SetupCalendar], Set<String>) in
            st.refreshSourcesIfNecessary()
            let cals = st.calendars(for: .event).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let all = cals.map { SetupCalendar(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title, subscribed: $0.type == .subscription) }
            let school = Set(cals.filter { SchoolAlarm.looksLikeSchool($0, in: st, hints: hints) }.map(\.calendarIdentifier))
            return (all, school)
        }.value
    }

    /// The setup's Done (or putting your own back after a test): the calendars, the times and on or off, at once.
    func apply(calendarIds ids: Set<String>, early: Int, wake: Int, on turnOn: Bool) {
        if calendarIds != ids { calendarIds = ids }
        if earlyMinutes != early { earlyMinutes = early }
        if wakeMinutes != wake { wakeMinutes = wake }
        if on != turnOn { on = turnOn } else if turnOn { Task { await refresh(force: true, now: true) } }
    }

    /// Back to the saved values (after a test's backup was put back): the calendars, the times, on or off.
    func reloadSaved() {
        apply(calendarIds: Set(d.stringArray(forKey: "school.cals") ?? []), early: d.object(forKey: "school.early") as? Int ?? 10,
              wake: d.object(forKey: "school.wake") as? Int ?? 60, on: d.bool(forKey: "school.on"))
    }

    /// Turned off: every alarm that hasn't rung goes.
    private func stop() {
        let gone = week.filter { !$0.rang }.map { ($0.alarmId, $0.day) }
        Task.detached { for (id, day) in gone { WakeAlarm.cancel(id, day: day) } }
        week = []; trips = [:]; save()
        next = nil; note = nil
    }

    // MARK: the timetable

    /// Your calendars (to pick the school one).
    var calendars: [EKCalendar] { allowed ? (storeObj?.calendars(for: .event) ?? []).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } : [] }

    /// Does this look like the school timetable? Its name (TimeEdit, BUas, rooster), or its events (TimeEdit links, BUas rooms).
    func looksLikeSchool(_ c: EKCalendar) -> Bool { schoolLike.contains(c.calendarIdentifier) }

    nonisolated static func looksLikeSchool(_ c: EKCalendar, in store: EKEventStore, hints: SchoolHints) -> Bool {
        SchoolHints.matches(title: c.title, source: c.source.title, eventText: {
            let now = Date()
            let evs = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-7 * 86400), end: now.addingTimeInterval(14 * 86400), calendars: [c]))
            return evs.prefix(60).map { e in [e.url?.absoluteString ?? "", e.notes ?? "", e.location ?? ""].joined(separator: " ") }
        }, hints: hints)
    }

    func suggested() async -> Set<String> { await findSchoolLike(); return schoolLike }

    /// The first class of each day with school in the next week, by day (yyyy-MM-dd). Only the calendars you picked;
    /// all-day and cancelled ones don't count.
    struct Lesson: Sendable { let title: String?; let location: String?; let startDate: Date }

    private func firstClasses() async -> [String: Lesson] {
        switch Self.schedule {
        case .calendars: return await calendarFirstClasses()
        case .manual(let w):
            // the same times every week (0.23): the next eight days' first classes, from the week
            let tz = TimeZone(identifier: "Europe/Amsterdam") ?? .current
            var out: [String: Lesson] = [:]
            for l in w.lessons(from: Date(), days: 8, tz: tz) { out[l.day] = Lesson(title: "Class", location: nil, startDate: l.start) }
            return out
        case .none: return [:]
        }
    }

    private func calendarFirstClasses() async -> [String: Lesson] {
        let st = await calendarStore(), ids = calendarIds
        return await Task.detached { () -> [String: Lesson] in
            let cals = st.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
            guard !cals.isEmpty else { return [:] }
            let now = Date(), startOfToday = Calendar.current.startOfDay(for: now)
            let evs = st.events(matching: st.predicateForEvents(withStart: startOfToday, end: startOfToday.addingTimeInterval(8 * 86400), calendars: cals))
                .filter { !$0.isAllDay && $0.status != .canceled && !SchoolAlarm.isCancelled($0.title ?? "") }
            var out: [String: Lesson] = [:]
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Europe/Amsterdam"); f.locale = Locale(identifier: "en_US_POSIX")
            for e in evs {
                let k = f.string(from: e.startDate)
                if out[k].map({ e.startDate < $0.startDate }) ?? true { out[k] = Lesson(title: e.title, location: e.location, startDate: e.startDate) }
            }
            return out
        }.value
    }

    /// (0.28) Every class of the next `days` days (today counts, all of it), for friends to compare with: from the
    /// calendars you picked (all-day and cancelled ones don't count, nor anything over 12 hours), or your week (one
    /// per school day, to its end time). Nil: no timetable to share (not set up, or no calendar access).
    func friendClasses(days: Int) async -> (classes: [TimetableClass], src: String)? {
        switch Self.schedule {
        case .manual(let w):
            let tz = TimeZone(identifier: "Europe/Amsterdam") ?? .current
            return (w.classes(from: Date(), days: days, tz: tz), "week")
        case .calendars:
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, !calendarIds.isEmpty else { return nil }
            let st = await calendarStore(), ids = calendarIds
            let list = await Task.detached { () -> [TimetableClass] in
                let cals = st.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
                guard !cals.isEmpty else { return [] }
                let start = TimetableDays.calendar.startOfDay(for: Date())
                let end = TimetableDays.calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86400)
                let evs = st.events(matching: st.predicateForEvents(withStart: start, end: end, calendars: cals))
                    .filter { !$0.isAllDay && $0.status != .canceled && !SchoolAlarm.isCancelled($0.title ?? "") }
                var seen = Set<String>()
                var out: [TimetableClass] = []
                for e in evs {
                    let sa: Date? = e.startDate, sb: Date? = e.endDate
                    guard let a = sa, let b = sb, b > a, b.timeIntervalSince(a) <= TimetableClass.maxLength, a >= start else { continue }
                    let rawTitle: String? = e.title
                    let rawRoom: String? = e.location
                    let title: String? = (rawTitle ?? "").isEmpty ? nil : rawTitle
                    let room: String? = (rawRoom ?? "").isEmpty ? nil : rawRoom
                    let key = "\(a.timeIntervalSince1970)|\(b.timeIntervalSince1970)|\(title ?? "")"
                    guard seen.insert(key).inserted else { continue }
                    out.append(TimetableClass(start: a, end: b, title: title, room: room))
                }
                return out.sorted { $0.start < $1.start }
            }.value
            return (list, "calendar")
        case .none:
            return nil
        }
    }

    nonisolated static func isCancelled(_ t: String) -> Bool {
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
    private var againForce = false              // a coalesced one wanted every day planned again (sticky until it runs)
    /// Days turned back on (Your day): their alarm is set from the trip they have, at the start of the next plan.
    private var restoreDays = Set<String>()

    /// One plan at a time: a change that comes in while it's planning runs again right after, so none is lost.
    /// `staleOnly`: right away, but only the days that are due (a day turned back on), not every day again.
    func refresh(force: Bool = false, now immediate: Bool = false, staleOnly: Bool = false) async {
        guard on else { return }
        if running {
            if force || immediate { again = true }
            if force || (immediate && !staleOnly) { againForce = true }
            return
        }
        guard immediate || Date().timeIntervalSince(lastPlan) > (force ? 30 : 5 * 60) else { return }
        running = true
        var f = force || (immediate && !staleOnly)
        repeat {
            again = false
            lastPlan = Date()
            await plan(force: f)
            f = f || againForce
            againForce = false
        } while again && on
        running = false
    }

    private func plan(force: Bool) async {
        await restoreTurnedOn()
        // (0.42.6) the day's changes still to come; this morning's alarm skipped if you're already on the way
        pruneDays()
        checkOnTheWay()
        allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let schedule = Self.schedule
        guard allowed || schedule != .calendars else { note = "Allow calendar access to read your timetable."; return }
        let classes = await firstClasses()
        let now = Date()
        let oldNext = next
        var changed = false, added: [Planned] = []
        // days whose first class is gone from the timetable: their alarm goes (if it hasn't rung)
        for p in week where classes[p.day] == nil && !p.rang && p.classStart > now {
            await WakeAlarm.cancelInBackground(p.alarmId, day: p.day)
            week.removeAll { $0.day == p.day }; trips[p.day] = nil; changed = true
        }
        for k in classes.keys.sorted() {
            guard let e = classes[k] else { continue }
            let old = week.first { $0.day == k }
            if let old, old.rang { continue }                               // it rang: leave it alone
            guard e.startDate > now.addingTimeInterval(20 * 60) else { continue }
            // (0.42.6) the day's own "Be there at …" when you changed it, else the timetable's
            let beThere: Date = SchoolArrive.beThere(classStart: e.startDate, early: earlyMinutes, override: arrive[k])
            // near days often (live times), far days now and then (the timetable); always when the class moved
            let soon = e.startDate.timeIntervalSince(now) < 36 * 3600
            let moved = old.map { $0.classStart != e.startDate || $0.beThere != beThere } ?? true
            if !force && !moved, let old, now.timeIntervalSince(old.checked) < (soon ? 14 * 60 : 6 * 3600) { continue }
            let all = await Transit.plan(from: homeStart(), to: .school, modes: nil, at: beThere, count: 6, maxTransfers: 4, arriveBy: true)
            guard on else { return }
            var seen = Set<String>()
            let inTime = all.filter { $0.end <= beThere.addingTimeInterval(60) && $0.first.departure > now && seen.insert($0.id).inserted }
            guard var best = inTime.max(by: { ($0.start, -$0.rides.count) < ($1.start, -$1.rides.count) }) else {
                // no answer just now: keep what it had; (0.42.6) right after you changed the day's time, its trip moved by
                // the change, so the alarm follows at once (and it's planned again at the next chance)
                if let old, old.beThere != beThere, old.classStart == e.startDate, let ol = old.leave {
                    if await shiftForChange(old, beThere: beThere, oldLeave: ol, now: now) { changed = true }
                }
                continue
            }
            // A change you'll make: also the earlier buses onto the same train, and the latest one that leaves room to
            // change (a late 306 shouldn't cost you the train, and the next one is 20 to 30 minutes later).
            if best.rides.count > 1, e.startDate.timeIntervalSince(now) < 36 * 3600 {         // the next day and a half
                let earlier = await Transit.earlierWays(onto: best, now: now, at: [0])
                guard on else { return }
                // (no more than 35 minutes before the latest: the planner also lists night buses that get there by morning)
                let latest = best.start
                let pool = (inTime + earlier.filter { $0.end <= beThere.addingTimeInterval(60) && $0.first.departure > now && seen.insert($0.id).inserted })
                    .filter { $0.start >= latest.addingTimeInterval(-35 * 60) }
                let safe = pool.filter { Risk.penalty($0) < Risk.safe }
                if let s = safe.max(by: { ($0.start, -$0.rides.count) < ($1.start, -$1.rides.count) }) {
                    best = s
                } else if let least = pool.min(by: { (Risk.penalty($0), -$0.start.timeIntervalSince1970) < (Risk.penalty($1), -$1.start.timeIntervalSince1970) }),
                          Risk.penalty(least) < Risk.penalty(best) - 1 {
                    best = least                                            // none safe: the least likely to go wrong
                }
            }
            trips[k] = best
            let alarmAt = best.start.addingTimeInterval(-Double(wakeMinutes) * 60)
            var p = old ?? Planned(day: k, title: e.title ?? "Class", room: e.location, classStart: e.startDate, beThere: beThere, checked: now)
            p.title = e.title ?? "Class"; p.room = e.location; p.classStart = e.startDate; p.beThere = beThere
            p.leave = best.start; p.arrive = best.end; p.checked = now
            p.lines = best.rides.map { $0.isTrain ? $0.line : $0.line }.joined(separator: " · ")
            let text = alarmText(day: k, leave: best.start, classStart: e.startDate, beThere: beThere)
            let r = await alarmFor(p, at: alarmAt, text: text, now: now)
            p = r.p
            if r.changed { changed = true }
            if r.added { added.append(p) }
            if let i = week.firstIndex(where: { $0.day == k }) { week[i] = p } else { week.append(p) }
        }
        week.removeAll { $0.classStart < now.addingTimeInterval(-2 * 86400) }
        week.sort { $0.classStart < $1.classStart }
        save()
        updateNext()
        switch schedule {
        case .calendars: note = classes.isEmpty ? (calendarIds.isEmpty ? "Pick your school calendar." : "No classes found in the next week.") : nil
        case .manual: note = classes.isEmpty ? "No school days in your week." : nil
        case .none: note = "Your timetable isn’t set up yet."
        }
        if changed { tell(added: added, oldNext: oldNext) }
        Self.scheduleBackground()
    }

    /// Say what changed: the new alarms of the week, or the next one moving by 5 minutes or more.
    private func tell(added: [Planned], oldNext: Day?) {
        let set = added.filter { ($0.alarm ?? .distantPast) > Date() }
        if !set.isEmpty {
            let list = set.prefix(5).map { "\(Self.shortDay($0.classStart)) \(Fmt.hhmm($0.alarm!))" }.joined(separator: " · ")
            let title = set.count == 1 ? "School alarm \(Self.dayWord(set[0].alarm!)) \(Fmt.hhmm(set[0].alarm!))" : "\(set.count) school alarms set"
            var body = set.count == 1 ? "Leave \(Fmt.hhmm(set[0].leave!)) · first class \(Fmt.hhmm(set[0].classStart)) \(set[0].title)" : list
            // (0.42.6) a day whose time you changed says so
            if set.count == 1, let c = changedLine(set[0].day) { body += " · " + c }
            NoticeLog.shared.add(key: "school-set-\(list)", title: title, body: body, kind: "ok")
            Notices.shared.show(title: title, body: body, kind: "ok")
        } else if let o = oldNext, let n = next, o.classStart == n.classStart, let a = o.alarm, let b = n.alarm, abs(b.timeIntervalSince(a)) >= 5 * 60, b > Date() {
            let title = "School alarm moved to \(Fmt.hhmm(b))"
            // (0.42.6) a day whose time you changed: the time you picked instead of "the buses changed"
            let why: String = arrival(n.day).map { "be there \(Fmt.hhmm($0)) (class \(Fmt.hhmm(n.classStart)))" } ?? "the buses changed"
            let body = "Was \(Fmt.hhmm(a)) · \(why) · leave \(Fmt.hhmm(n.leave ?? b)) for \(Fmt.hhmm(n.classStart)) \(n.title)"
            NoticeLog.shared.add(key: "school-move-\(Int(b.timeIntervalSince1970))", title: title, body: body, kind: "late")
            Notices.shared.show(title: title, body: body, kind: "late")
        }
    }

    /// From home: where you are now if that's within 6 km of Home (in Veghel; and it remembers it), else where it last saw
    /// you there, else your home stops.
    private func homeStart() -> Place {
        let home = CLLocation(latitude: Place.home.coordinate.latitude, longitude: Place.home.coordinate.longitude)
        if let l = trip?.lastFix, l.timestamp.timeIntervalSinceNow > -2 * 3600, l.horizontalAccuracy < 200, l.distance(from: home) < 6000 {
            d.set(l.coordinate.latitude, forKey: "school.homeLat"); d.set(l.coordinate.longitude, forKey: "school.homeLon")
            return .here(l.coordinate)
        }
        if let a = d.object(forKey: "school.homeLat") as? Double, let o = d.object(forKey: "school.homeLon") as? Double {
            return .here(.init(latitude: a, longitude: o))
        }
        return StopsStore.shared.homePlace
    }

    static let backgroundId = "nl.haltewekker.app.plan"

    /// Ask iOS to wake the app now and then (about every hour) to plan the alarms again.
    static func scheduleBackground() {
        // (0.36) also for the works on your routes and the last way home, which look at the same wake-up
        guard UserDefaults.standard.bool(forKey: "school.on") || TravelNotes.wantsBackground else { return }
        let r = BGAppRefreshTaskRequest(identifier: backgroundId)
        r.earliestBeginDate = Date().addingTimeInterval(50 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Woken in the background: plan again what's due (0.20.7: not every class day each time; a near day after 14
    /// minutes, a far one after 6 hours, a moved class at once, as in front), and ask to be woken again.
    static func backgroundRefresh() async {
        NoticeSweep.soon()
        scheduleBackground()
        await shared.refresh(force: false)
        // (0.36) works on your routes and the last way home, at most every 4 h / hourly
        await TravelNotes.shared.tick()
        // Friends (0.25): requests come in at this same wake-up too (nothing without an account)
        await FriendStore.shared.sync(.auto)
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

    /// A school alarm still ringing stops: you opened the app, so you're up (0.24.6). The notification fallback's
    /// "(again)" ones for today go too.
    static func stopRinging() {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let all = try? AlarmManager.shared.alarms {
            for a in all where a.state == .alerting { try? AlarmManager.shared.stop(id: a.id) }
        }
        #endif
    }

    /// The fallback's notifications for a day ("wake-<day>-0…2"): once you open or swipe away one, the rest don't come.
    static func cancelRepeats(of id: String) {
        let ids = AlarmStop.wakeRepeats(of: id)
        guard !ids.isEmpty else { return }
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: ids)
        c.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Set the alarm for a day. Returns its id (the alarm's, or "notifications").
    static func schedule(at date: Date, day: String, title: String, body: String) async -> String? {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), await requestPermission() {
            let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill")
            // Open: stops it and opens the app on your morning screen
            let open = AlarmButton(text: "Open", textColor: .black, systemImageName: "sun.max.fill")
            let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stop, secondaryButton: open, secondaryButtonBehavior: .custom)
            let attributes = AlarmAttributes<WakeMetadata>(presentation: AlarmPresentation(alert: alert), metadata: WakeMetadata(), tintColor: Color(hex: 0xF0D722))
            let id = UUID()
            do {
                // (the intent stops this alarm itself: a custom button only runs it, the alarm would keep ringing, 0.24.6)
                _ = try await AlarmManager.shared.schedule(id: id, configuration: .alarm(schedule: .fixed(date), attributes: attributes, secondaryIntent: OpenMorningIntent(alarmID: id.uuidString)))
                return id.uuidString
            } catch {}
        }
        #endif
        // loud notifications instead (they can't ring on silent)
        let c = UNUserNotificationCenter.current()
        for i in 0..<3 {
            let n = UNMutableNotificationContent()
            n.title = WristNotice.wakeTitle(title, repeat: i)
            n.body = body
            n.sound = .default
            n.interruptionLevel = .timeSensitive
            n.userInfo = ["kind": "go"]
            // swiping it away is reported, so the repeats stop; Stop alarm (also on a paired Apple Watch) does the same
            n.categoryIdentifier = WristNotice.wakeCategory
            n.threadIdentifier = WristNotice.wakeThread(day: day)
            n.relevanceScore = WristNotice.relevance(.schoolWake)
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
        await cancelInBackground(old, day: "test")
        let id = await schedule(at: at, day: "test", title: "Test alarm", body: "Your school alarm works")
        UserDefaults.standard.set(id, forKey: "school.testId")
        return id == nil ? nil : at
    }

    /// The same, off the main thread (asking iOS can be slow).
    static func cancelInBackground(_ id: String?, day: String) async {
        await Task.detached { cancel(id, day: day) }.value
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
    @Environment(\.settingsNewLook) private var newLook
    private var ink: SettingsInk { SettingsInk(newLook: newLook) }
    @ObservedObject private var school = SchoolAlarm.shared
    @ObservedObject private var profile = ProfileStore.shared
    var body: some View {
        Section {
            Toggle(isOn: $school.on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wake me for school")
                    Text("\(RoleWords.current.fromTimetable): the first class of the next school day, the trip there, and an alarm before you have to leave.")
                        .font(ink.note(12)).foregroundStyle(ink.muted)
                }
            }
            .settingsAnchor("school.alarm")
            if school.on {
                if profile.profile.schedule == .calendars && !school.allowed {
                    Button("Allow calendar access") { Task { await school.start() } }.foregroundStyle(ink.link)
                } else {
                    timetableRow
                    Stepper("At \(RoleWords.current.school) \(school.earlyMinutes) min before class", value: $school.earlyMinutes, in: 0...45, step: 5)
                        .settingsAnchor("school.early")
                    Stepper("Wake me \(school.wakeMinutes) min before I leave", value: $school.wakeMinutes, in: 15...150, step: 5)
                        .settingsAnchor("school.wake")
                    if let n = school.next {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(SchoolAlarm.dayWord(n.classStart).capitalizedFirst): \(n.title) at \(Fmt.hhmm(n.classStart))").font(ink.strong(13))
                            if let a = n.alarm, let l = n.leave {
                                Text("Alarm \(Fmt.hhmm(a)) · leave \(Fmt.hhmm(l)) · \(RoleWords.current.atSchoolLower(Fmt.hhmm(n.trip?.end ?? n.beThere)))").font(ink.note(12)).foregroundStyle(ink.muted)
                            }
                        }
                    }
                    if let note = school.note { Text(note).font(ink.note(12)).foregroundStyle(ink.late) }
                    AlarmCheck()
                    if !school.realAlarm {
                        Text("On this iPhone it wakes you with loud notifications (they stay quiet on silent). With iOS 26 it’s a real alarm, like the Clock app’s.")
                            .font(ink.note(11.5)).foregroundStyle(ink.muted)
                    }
                }
            }
        } header: { Text("School alarm") } footer: {
            Text("Only the calendars you pick are read, and only the first class of each day counts. Your own plans in other calendars are never used.")
        }
    }

    /// Where the first classes come from: the calendar you picked (as before), your week, or not set up yet (0.23).
    @ViewBuilder private var timetableRow: some View {
        switch profile.profile.schedule {
        case .calendars:
            NavigationLink {
                SchoolCalendarsView()
            } label: {
                HStack {
                    Text("School calendar")
                    Spacer()
                    Text(school.calendarIds.isEmpty ? "Pick one" : "\(school.calendarIds.count) picked").foregroundStyle(ink.muted)
                }
            }
            .settingsAnchor("school.timetable")
        case .manual(let w):
            NavigationLink { ManualWeekScreen() } label: {
                HStack {
                    Text("Your week")
                    Spacer()
                    Text(SetupLogic.weekWords(w)).foregroundStyle(ink.muted).multilineTextAlignment(.trailing)
                }
            }
            .settingsAnchor("school.timetable")
        case .none:
            Button("Read it from a calendar on this iPhone") {
                profile.setSchedule(.calendars)
                Task { await school.start() }
            }
            .foregroundStyle(ink.link)
            .settingsAnchor("school.timetable")
            Button("Same times every week") { profile.setSchedule(.manual(.workdays)) }.foregroundStyle(ink.link)
        }
    }
}

/// Which calendars are your school timetable. The ones that look like it (TimeEdit, BUas) are picked for you.
struct SchoolCalendarsView: View {
    @Environment(\.settingsNewLook) private var newLook
    private var ink: SettingsInk { SettingsInk(newLook: newLook) }
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
                                Text(c.title).foregroundStyle(ink.ink)
                                Text(school.looksLikeSchool(c) ? "\(c.source.title) · looks like your timetable" : c.source.title)
                                    .font(ink.note(11.5)).foregroundStyle(school.looksLikeSchool(c) ? ink.ok : ink.muted)
                            }
                            Spacer()
                            if picked { Image(systemName: "checkmark").foregroundStyle(ink.link).font(.system(size: 14, weight: .bold)) }
                        }
                    }
                }
            } footer: {
                Text("\(RoleWords.current.pickCalendar) The first class of each day in it sets the alarm; nothing else is read.")
            }
        }
        .scrollContentBackground(newLook ? .automatic : .hidden)
        .background(PaperFill().ignoresSafeArea().opacity(newLook ? 0 : 1))
        .navigationTitle("School calendar")
        .task { await school.findSchoolLike() }
    }
}

/// On the Planned tab: the next school day, the alarm, when to leave, and the trip as a metro line.
struct SchoolAlarmCard: View {
    @ObservedObject private var school = SchoolAlarm.shared
    let setUp: () -> Void
    var go: () -> Void = {}
    var wake: (DoorTrip) -> Void = { _ in }
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
                        stat("AT \(RoleWords.current.school.uppercased())", Fmt.hhmm(n.trip?.end ?? n.beThere), big: false)
                    }
                    // (0.42.6) the day's "Be there at …", to change for that day
                    ArriveRow(day: n.day, paper: true)
                    if a < Date() {
                        Text("The alarm time has passed: leave by \(Fmt.hhmm(l)).").font(BoardInk.sans(12)).foregroundStyle(Paper.late)
                    } else {
                        Text(school.realAlarm ? "The alarm is set: it rings like the Clock app’s." : "It wakes you with loud notifications at \(Fmt.hhmm(a)).")
                            .font(BoardInk.sans(11.5, .regular)).foregroundStyle(Paper.muted)
                    }
                    if let t = n.trip {
                        Rectangle().fill(Paper.rule).frame(height: 1)
                        TripLine(trip: t, others: [], dest: RoleWords.current.school)
                        PlanButtons(go: go, wake: { wake(t) })
                    }
                } else {
                    let off: String? = school.goingWords(n.day).map { "No alarm today: you’re \($0)." }
                        ?? (school.isSkipped(n.day) ? "No alarm this day: you turned it off." : nil)
                    Text(off ?? school.note ?? "Planning the trip…").font(BoardInk.sans(12.5)).foregroundStyle(Paper.muted)
                    if off != nil { ArriveRow(day: n.day, paper: true) }
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
                        Text(school.on ? (school.note ?? "Looking at your timetable…") : "\(RoleWords.current.fromTimetable): the trip to your first class, and an alarm an hour before you have to leave.")
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
    @Environment(\.settingsNewLook) private var newLook
    private var ink: SettingsInk { SettingsInk(newLook: newLook) }
    var compact = false
    @State private var testAt: Date?
    @State private var failed = false
    @State private var onPhone: [Date] = []
    @State private var perm: (ok: Bool, text: String) = (true, "Checking the alarm…")
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(perm.text, systemImage: perm.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(ink.strong(12)).foregroundStyle(perm.ok ? ink.ok : ink.late)
            if !perm.ok, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url).font(ink.strong(12)).foregroundStyle(ink.link)
            }
            if !onPhone.isEmpty {
                Text("Set on this iPhone: " + onPhone.prefix(7).map { "\(SchoolAlarm.shortDay($0)) \(Fmt.hhmm($0))" }.joined(separator: " · "))
                    .font(ink.note(11.5)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
            } else if perm.ok && !compact {
                Text("No alarms set on this iPhone yet.").font(ink.note(11.5)).foregroundStyle(ink.muted)
            }
            Button {
                Task {
                    testAt = await WakeAlarm.test()
                    failed = testAt == nil
                    await load()
                }
            } label: {
                Label("Test the alarm: it rings in 1 minute", systemImage: "alarm.waves.left.and.right.fill")
                    .font(ink.strong(13)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: newLook ? DS.hit : nil).padding(.vertical, newLook ? 4 : 10)
                    .background(newLook ? DS.accent : Paper.navy, in: RoundedRectangle(cornerRadius: newLook ? 22 : 6, style: .continuous))
            }
            .buttonStyle(.plain)
            if let t = testAt {
                Text("Test alarm set for \(Fmt.hhmm(t)). Lock your phone (put it on silent too, if you like) and wait: it should ring like a Clock alarm.")
                    .font(ink.note(11.5)).foregroundStyle(ink.ok).fixedSize(horizontal: false, vertical: true)
            } else if failed {
                Text("Couldn’t set the test alarm. Check that alarms are allowed for Haltewekker in Settings.")
                    .font(ink.note(11.5)).foregroundStyle(ink.late).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
    }

    /// What iOS says about the alarms, asked off the main thread (it can be slow right after installing).
    private func load() async {
        let r = await Task.detached { () -> ((Bool, String), [Date]) in
            return (WakeAlarm.permission, WakeAlarm.setOnPhone())
        }.value
        perm = (r.0.0, r.0.1)
        onPhone = r.1
    }
}

/// Under a planned trip: hands-free (it starts the ride by itself once you're on the bus), or start the alarm now.
struct PlanButtons: View {
    let go: () -> Void
    let wake: () -> Void
    var body: some View {
        VStack(spacing: 6) {
            Button(action: go) {
                Label("GO HANDS-FREE", systemImage: "bolt.fill").font(HWFont.display(14)).tracking(0.8).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12).background(Paper.green, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Button(action: wake) {
                Text("Wake me on this trip now").font(BoardInk.sans(12.5)).foregroundStyle(Paper.navy)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Paper.navy.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.navy.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text("Hands-free shows the walk and the bus, tells you if it changes, and starts the ride by itself once you’re on. It also opens by itself when you open the app around the time to leave.")
                .font(BoardInk.sans(10.5, .regular)).foregroundStyle(Paper.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Your day (0.19): a day's alarm off, and what the timetable says beyond the first class

extension SchoolAlarm {
    /// Off for the day: turned off on Your day, or (0.42.6) skipped because you were already on the way.
    func isSkipped(_ day: String) -> Bool { skipped.contains(day) || going[day] != nil }

    /// The wake-up alarm of one day off (or on again). Off: only that day's alarm goes now (if it hasn't rung); the
    /// rest of the morning (Fastest trip opening by itself, the nudge) and every other day stay as they are. On again:
    /// its alarm is set at once from the trip it has, and that day is planned again.
    func setSkipped(_ day: String, _ skip: Bool) {
        if skip { skipped.insert(day); restoreDays.remove(day) } else { skipped.remove(day); unGo(day) }
        d.set(Array(skipped).sorted(), forKey: SchoolSkip.key)
        if skip, let i = week.firstIndex(where: { $0.day == day }), !week[i].rang {
            let id = week[i].alarmId
            week[i].alarmId = nil; week[i].alarm = nil
            save()
            Task { await WakeAlarm.cancelInBackground(id, day: day) }
        }
        if !skip, let i = week.firstIndex(where: { $0.day == day }) {
            // on again: its alarm at once from the trip it has, then that day (only) planned again with live times
            week[i].checked = .distantPast
            save()
            restoreDays.insert(day)
            Task { await refresh(now: true, staleOnly: true) }
        }
        updateNext()
    }

    /// Back on: the alarm from the trip already planned for the day, with no network (inside a plan, so never at the
    /// same time as one).
    fileprivate func restoreTurnedOn() async {
        let days = restoreDays
        restoreDays = []
        for day in days {
            guard !offDays.contains(day), let i = week.firstIndex(where: { $0.day == day }), week[i].alarmId == nil,
                  let at = SchoolSkip.restore(leave: week[i].leave, wakeMinutes: wakeMinutes, now: Date()) else { continue }
            let p = week[i]
            let text = alarmText(day: day, leave: p.leave ?? at, classStart: p.classStart, beThere: p.beThere)
            let id = await WakeAlarm.schedule(at: at, day: day, title: text.title, body: text.body)
            if let j = week.firstIndex(where: { $0.day == day }), !offDays.contains(day), week[j].alarmId == nil {
                week[j].alarm = at; week[j].alarmId = id; week[j].label = text.title + "|" + text.body
                save()
            } else {
                await WakeAlarm.cancelInBackground(id, day: day)
            }
        }
        updateNext()
    }

    /// Reset everything: no day is off any more.
    func clearSkipped() {
        skipped = []; restoreDays = []
        d.removeObject(forKey: SchoolSkip.key)
        // (0.42.6) and no day's own time, no skip for being on the way
        arrive = [:]; going = [:]; keepRinging = []
        d.removeObject(forKey: SchoolArrive.key); d.removeObject(forKey: OnTheWay.goingKey); d.removeObject(forKey: OnTheWay.keepKey)
    }

    /// The trip planned for a day this session (with its rides), if any.
    func plannedTrip(_ day: String) -> DoorTrip? { trips[day] }

    /// Read only: the events of the calendars you picked, from the start of today to `days` ahead (for the end of a
    /// day's classes and Coming up). Empty without calendar access or a picked calendar.
    func schoolEvents(days: Int) async -> [ComingUp.Event] {
        switch Self.schedule {
        case .calendars: break
        case .manual(let w):
            // your week's first classes, two weeks ahead (as far as Your day steps): a start only, no end and no breaks
            let tz = TimeZone(identifier: "Europe/Amsterdam") ?? .current
            let start = Calendar.current.startOfDay(for: Date())
            return w.lessons(from: start, days: min(days, 14), tz: tz).map {
                ComingUp.Event(title: "Class", start: $0.start, end: $0.start, allDay: false, cancelled: false, startOnly: true)
            }
        case .none: return []
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, !calendarIds.isEmpty else { return [] }
        let st = await calendarStore(), ids = calendarIds
        return await Task.detached { () -> [ComingUp.Event] in
            let cals = st.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
            guard !cals.isEmpty else { return [] }
            let start = Calendar.current.startOfDay(for: Date())
            let evs = st.events(matching: st.predicateForEvents(withStart: start, end: start.addingTimeInterval(Double(days) * 86400), calendars: cals))
            return evs.map { e in
                ComingUp.Event(title: e.title ?? "", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                               cancelled: e.status == .canceled || SchoolAlarm.isCancelled(e.title ?? ""))
            }
        }.value
    }

    /// When a day's last class ends (from `events`), if it has classes.
    nonisolated static func classesEnd(_ events: [ComingUp.Event], on day: Date) -> Date? {
        events.filter { !$0.allDay && !$0.cancelled && !$0.startOnly && Calendar.current.isDate($0.start, inSameDayAs: day) }.map(\.end).max()
    }
}

// MARK: (0.42.6) Be there at … per day, and never ringing when you're already on the way

extension SchoolAlarm {
    /// The days without an alarm: turned off on Your day, or skipped because you were already on the way.
    var offDays: Set<String> { skipped.union(going.keys) }

    /// The day's own "Be there at …", if you changed it.
    func arrival(_ day: String) -> Date? { arrive[day] }

    /// The timetable's be-there time for a planned day (its first class minus how early you want to be there).
    func timetableBeThere(_ p: Planned) -> Date { SchoolArrive.timetable(classStart: p.classStart, early: earlyMinutes) }

    /// "Changed: be there 09:00 (class 11:00)", when the day's time is yours.
    func changedLine(_ day: String) -> String? {
        guard let a = arrive[day], let p = week.first(where: { $0.day == day }) else { return nil }
        return SchoolArrive.changedLine(beThere: a, classStart: p.classStart, clock: Fmt.hhmm)
    }

    /// The alarm's words for a day (as before unless you changed its time).
    func alarmText(day: String, leave: Date, classStart: Date, beThere: Date) -> (title: String, body: String) {
        SchoolArrive.alarmText(leave: leave, classStart: classStart, beThere: beThere, changed: arrive[day] != nil, clock: Fmt.hhmm)
    }

    /// "Be there at …" for one day (nil: the timetable's again). The day's trip and alarm are planned again at once.
    func setArrival(_ day: String, _ t: Date?) {
        if applyArrival(day, t) { Task { await refresh(now: true, staleOnly: true) } }
    }

    /// The same, without planning (the caller plans). True when it changed.
    @discardableResult
    func applyArrival(_ day: String, _ t: Date?) -> Bool {
        var v: Date? = t
        if let t, let p = week.first(where: { $0.day == day }) {
            v = SchoolArrive.normalized(t, timetable: timetableBeThere(p), classStart: p.classStart)
        }
        if arrive[day] == v { return false }
        if let v { arrive[day] = v } else { arrive.removeValue(forKey: day) }
        saveArrive()
        if let i = week.firstIndex(where: { $0.day == day }) { week[i].checked = .distantPast; save() }
        let line = v.map { "school alarm · \(day): be there \(Fmt.hhmm($0))" } ?? "school alarm · \(day): be there as the timetable says"
        FieldLog.shared.add(.ride, line)
        return true
    }

    /// A quick choice for a day: 1 h or 2 h earlier, 30 min later (from the timetable's time).
    func setArrival(_ day: String, quick q: SchoolArrive.Quick) {
        guard let p = week.first(where: { $0.day == day }) else { return }
        setArrival(day, SchoolArrive.quick(q, timetable: timetableBeThere(p)))
    }

    fileprivate func saveArrive() {
        let raw: [String: Double] = arrive.mapValues { $0.timeIntervalSince1970 }
        d.set(raw, forKey: SchoolArrive.key)
    }

    fileprivate func saveGoing() {
        d.set(going, forKey: OnTheWay.goingKey)
        d.set(Array(keepRinging).sorted(), forKey: OnTheWay.keepKey)
    }

    fileprivate func saveSeen() { d.set(try? JSONEncoder().encode(seen), forKey: OnTheWay.key) }

    /// At the start: the changes, the skips and this morning's record, as kept.
    fileprivate func loadMorning() {
        let today = Fmt.ymd.string(from: Date())
        let raw = d.dictionary(forKey: SchoolArrive.key) as? [String: Double] ?? [:]
        arrive = SchoolArrive.prune(raw.mapValues { Date(timeIntervalSince1970: $0) }, today: today)
        going = OnTheWay.prune(d.dictionary(forKey: OnTheWay.goingKey) as? [String: String] ?? [:], today: today)
        keepRinging = Set((d.stringArray(forKey: OnTheWay.keepKey) ?? []).filter { $0 >= today })
        let s: OnTheWay.Seen? = d.data(forKey: OnTheWay.key).flatMap { try? JSONDecoder().decode(OnTheWay.Seen.self, from: $0) }
        seen = OnTheWay.fresh(s, day: today)
    }

    /// Yesterday's changes and skips go (a change is for its date only).
    fileprivate func pruneDays() {
        let today = Fmt.ymd.string(from: Date())
        let a = SchoolArrive.prune(arrive, today: today)
        if a.count != arrive.count { arrive = a; saveArrive() }
        let g = OnTheWay.prune(going, today: today)
        let k = keepRinging.filter { $0 >= today }
        if g.count != going.count || k.count != keepRinging.count { going = g; keepRinging = k; saveGoing() }
    }

    /// No answer from the planner right after a change: the old trip moved by the change, and the alarm with it.
    /// True when the day changed.
    fileprivate func shiftForChange(_ old: Planned, beThere: Date, oldLeave: Date, now: Date) async -> Bool {
        let leave: Date = SchoolArrive.shiftedLeave(oldLeave: oldLeave, oldBeThere: old.beThere, newBeThere: beThere)
        guard leave > now else { return false }
        var p = old
        p.leave = leave
        p.arrive = old.arrive.map { SchoolArrive.shiftedLeave(oldLeave: $0, oldBeThere: old.beThere, newBeThere: beThere) }
        p.beThere = beThere
        p.checked = .distantPast                    // (planned again with live times at the next chance)
        trips[p.day] = nil
        let alarmAt = leave.addingTimeInterval(-Double(wakeMinutes) * 60)
        let text = alarmText(day: p.day, leave: leave, classStart: p.classStart, beThere: beThere)
        let r = await alarmFor(p, at: alarmAt, text: text, now: now)
        if let i = week.firstIndex(where: { $0.day == p.day }) { week[i] = r.p } else { week.append(r.p) }
        FieldLog.shared.add(.ride, "school alarm · \(p.day): no plan just now · leave moved to \(Fmt.hhmm(leave)) by the change")
        return true
    }

    /// The day's alarm for `at`: set, moved, kept or taken away as `SchoolSkip.decide` says (as before 0.42.6); the
    /// same minute with new words (a changed be-there time) is set again while it's more than 5 minutes ahead.
    fileprivate func alarmFor(_ p0: Planned, at alarmAt: Date, text: (title: String, body: String), now: Date) async -> (p: Planned, changed: Bool, added: Bool) {
        var p = p0
        let k = p.day
        let wasSet = p0.alarmId != nil
        var changed = false, added = false
        // move the alarm only if its minute changed; set none if it's already too late for one, or the day is off
        // (on the day as it is now: it may have been turned off and on while this waited for the network)
        let cur = SchoolSkip.current(snapshot: (p.alarm, p.alarmId),
                                     live: week.first(where: { $0.day == k }).map { (alarm: $0.alarm, id: $0.alarmId) })
        p.alarm = cur.alarm; p.alarmId = cur.id
        let label: String = text.title + "|" + text.body
        let off: Set<String> = offDays
        var action: SchoolSkip.Action = SchoolSkip.decide(alarmAt, day: k, skipped: off, current: p.alarm, hasId: p.alarmId != nil, now: now)
        let relabel: Bool = action == .keep && p.alarmId != nil && !off.contains(k) && (p.label ?? label) != label
        if relabel, alarmAt > now.addingTimeInterval(5 * 60) { action = .set(alarmAt, schedule: true) }
        switch action {
        case .keep:
            break
        case .clear:
            // turned off for this day: no alarm (the trip is still planned, to show)
            await WakeAlarm.cancelInBackground(p.alarmId, day: k)
            p.alarmId = nil; p.alarm = nil
            changed = true
        case .set(let at, let schedule):
            await WakeAlarm.cancelInBackground(p.alarmId, day: k)
            p.alarmId = nil
            p.alarm = at
            if schedule {
                p.alarmId = await WakeAlarm.schedule(at: at, day: k, title: text.title, body: text.body)
                p.label = label
            }
            changed = true
            if !wasSet { added = true }
        }
        // turned off while this was planning: its alarm goes after all
        if offDays.contains(k), p.alarmId != nil || p.alarm != nil {
            await WakeAlarm.cancelInBackground(p.alarmId, day: k)
            p.alarmId = nil; p.alarm = nil
        }
        return (p, changed, added)
    }

    // MARK: already on the way

    /// Watches the trip (read only): its start, its end, where you are while it runs, and leaving home or getting to
    /// school (its regions).
    fileprivate func watchMorning(_ t: TripManager) {
        morningSubs = []
        t.$phase.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] p in
            self?.phaseChanged(p)
        }.store(in: &morningSubs)
        t.$distance.throttle(for: .seconds(60), scheduler: DispatchQueue.main, latest: true).sink { [weak self] _ in
            self?.positionChanged()
        }.store(in: &morningSubs)
        // (the Friends extras hear the regions too: each passes them on)
        let prev = t.onRegion
        t.onRegion = { id, entered in
            prev?(id, entered)
            SchoolAlarm.shared.regionChanged(id, entered: entered)
        }
    }

    /// 03:00 today: "this morning" starts.
    private func morningStart(_ now: Date) -> Date {
        Calendar.current.date(bySettingHour: OnTheWay.morningHour, minute: 0, second: 0, of: now) ?? Calendar.current.startOfDay(for: now)
    }

    /// Today's record (a new one on a new day).
    private func todaySeen(_ now: Date) -> OnTheWay.Seen { OnTheWay.fresh(seen, day: Fmt.ymd.string(from: now)) }

    /// Does the trip that runs go to school? Your fixed route there, or its last stop near school.
    private func tripToSchool(_ t: TripManager) -> Bool {
        let s = CLLocation(latitude: Place.school.coordinate.latitude, longitude: Place.school.coordinate.longitude)
        let last: Double? = t.legs.last.map { CLLocation(latitude: $0.to.coordinate.latitude, longitude: $0.to.coordinate.longitude).distance(from: s) }
        let fixed: Bool = (t.route?.isFixed ?? false) && t.direction == .toSchool
        return OnTheWay.towardSchool(lastStopMetres: last, fixedToSchool: fixed)
    }

    private func phaseChanged(_ p: TripManager.Phase) {
        let before = lastTripPhase
        lastTripPhase = p
        guard let t = trip, !t.demo else { return }
        let now = Date()
        guard now >= morningStart(now) else { return }
        var s = todaySeen(now)
        if p == .idle { return }
        if p == .finished {
            // the trip got to its last stop: at school when that's school
            if tripToSchool(t), s.atSchool == nil { s.atSchool = now }
        } else if before == .idle || before == .finished {
            // a trip or ride started (not a step of one that runs since last night)
            if s.tripAt == nil { s.tripAt = now }
            if tripToSchool(t), s.schoolTripAt == nil { s.schoolTripAt = now }
        }
        if s != seen { seen = s; saveSeen() }
        checkOnTheWay()
    }

    private func positionChanged() {
        guard let t = trip, !t.demo, t.phase != .idle else { return }
        let now = Date()
        guard now >= morningStart(now) else { return }
        var s = todaySeen(now)
        if s.atSchool == nil, let f = t.lastFix {
            let m = f.distance(from: CLLocation(latitude: Place.school.coordinate.latitude, longitude: Place.school.coordinate.longitude))
            if OnTheWay.atSchool(metres: m, fixAt: f.timestamp, now: now) { s.atSchool = now }
        }
        if s != seen { seen = s; saveSeen() }
        checkOnTheWay()
    }

    /// A region (also when iOS wakes the app in the background for it): left home, or got to school.
    fileprivate func regionChanged(_ id: String, entered: Bool) {
        let now = Date()
        guard now >= morningStart(now) else { return }
        var s = todaySeen(now)
        let role = RoleRegions.role(ofRegion: id)
        if !entered, role == .home || id == Place.home.key, s.leftHome == nil { s.leftHome = now }
        if entered, role == .school, s.atSchool == nil { s.atSchool = now }
        if s != seen { seen = s; saveSeen() }
        checkOnTheWay()
    }

    /// How far the last fix is from home (the nearer of Home and where it last saw you at home), and when it was.
    private func homeFix() -> (metres: Double?, at: Date?) {
        guard let f = trip?.lastFix, f.horizontalAccuracy >= 0, f.horizontalAccuracy < 300 else { return (nil, nil) }
        var spots: [CLLocation] = [CLLocation(latitude: Place.home.coordinate.latitude, longitude: Place.home.coordinate.longitude)]
        if let a = d.object(forKey: "school.homeLat") as? Double, let o = d.object(forKey: "school.homeLon") as? Double {
            spots.append(CLLocation(latitude: a, longitude: o))
        }
        let m: Double? = spots.map { f.distance(from: $0) }.min()
        return (m, f.timestamp)
    }

    /// This morning's alarm goes when you're already on the way (`OnTheWay.decide`): AlarmKit's alarm and the
    /// notifications both, said once in the field log and as a quiet notification. A day you turned back on stays on.
    func checkOnTheWay() {
        guard on else { return }
        let now = Date()
        let today = Fmt.ymd.string(from: now)
        guard going[today] == nil, !keepRinging.contains(today), !skipped.contains(today),
              let i = week.firstIndex(where: { $0.day == today }) else { return }
        let p = week[i]
        let t = trip
        let running: Bool = t.map { $0.phase != .idle && $0.phase != .finished && !$0.demo } ?? false
        let toSchool: Bool = running && t.map { tripToSchool($0) } == true
        let h = homeFix()
        let live = OnTheWay.Live(running: running, runningToSchool: toSchool, homeMetres: h.metres, fixAt: h.at)
        let decision = OnTheWay.decide(day: today, today: today, alarm: p.alarm, now: now, morning: morningStart(now), seen: todaySeen(now), live: live)
        guard case .skip(let reason) = decision else { return }
        let words = OnTheWay.words(reason, clock: Fmt.hhmm)
        going[today] = words
        saveGoing()
        let id = p.alarmId
        week[i].alarmId = nil; week[i].alarm = nil
        save()
        updateNext()
        Task.detached { WakeAlarm.cancel(id, day: today) }
        FieldLog.shared.add(.ride, OnTheWay.logLine(reason, clock: Fmt.hhmm))
        let title = "No school alarm today"
        let body = "You’re \(words). Turn it back on in Your day."
        NoticeLog.shared.add(key: "school-going-\(today)", title: title, body: body, kind: "ok")
        if UIApplication.shared.applicationState == .active {
            Notices.shared.show(title: title, body: body, kind: "ok")
        } else {
            let n = UNMutableNotificationContent()
            n.title = title; n.body = body
            n.interruptionLevel = .passive
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "school-going-\(today)", content: n, trigger: nil)) { _ in }
        }
    }

    /// Why a day's alarm was skipped ("already on the way (trip 07:12)"), if it was.
    func goingWords(_ day: String) -> String? { going[day] }

    /// A skipped day turned back on (Your day): it rings again, and isn't skipped again that day.
    fileprivate func unGo(_ day: String) {
        guard going[day] != nil else { return }
        going.removeValue(forKey: day)
        keepRinging.insert(day)
        saveGoing()
        FieldLog.shared.add(.ride, "school alarm · \(day): turned back on after the skip")
    }
}
