import CoreLocation
import MapKit
import SwiftUI
import UIKit
import UserNotifications

/// "Fastest trip", hands-free: one tap and it plans from where you are, shows what to take next and the walk there,
/// keeps watching the fastest way (late, early, cancelled, or something faster now: it tells you and switches to that
/// one by itself), and starts the trip by itself once you're on board. It stops on its own when you're on board, when
/// you're there, after three hours, or when you leave the screen.
@MainActor
final class GoStore: ObservableObject {
    static let shared = GoStore()
    static let maxHours = 3.0
    weak var trip: TripManager?

    @Published private(set) var isOpen = false
    @Published private(set) var watching = false
    @Published private(set) var dest: Place = .home
    @Published private(set) var best: DoorTrip?             // the one it's watching: the fastest you can still catch
    @Published private(set) var others: [DoorTrip] = []
    /// The ride you chose in Plan (0.20.2): shown and watched as your trip instead of the fastest, found again in each
    /// answer by its rides' trip ids; something faster is only a note. Nil: it picks the fastest, as before (also once
    /// your choice is gone: cancelled, left, or missing from the answers).
    @Published private(set) var chosen: DoorTrip?
    private var chosenMisses = 0                             // whole answers in a row it was missing from
    private var toldBeats: Set<String> = []                  // "Faster:" noted for these rides (once each)
    @Published private(set) var error: String?
    @Published private(set) var updated: Date?
    @Published private(set) var notes: [Note] = []           // what it told you, newest first
    @Published private(set) var arrived = false
    @Published private(set) var seen: Vehicle?               // looks like you're on this one (checking)
    @Published private(set) var overdue = false              // the one you're waiting for at its stop is past its time
    @Published private(set) var hurry: (meters: Int, minutes: Int)?   // the one you're on your way to: still makes it at a brisk walk
    @Published private(set) var onBoard: Vehicle?            // you're on this one already: the plan starts from it
    @Published private(set) var lookingOnBoard = false       // just opened: checking whether you're on a bus or train
    @Published private(set) var movingUnknown = false        // going at train or bus speed, but which one isn't clear yet
    @Published private(set) var slow = false                 // the answer is taking long (a slow connection)
    /// What's on screen is its last answer, saved as of then, while it asks again (nil: a live answer, or nothing).
    /// Shown as "as of 08:12 · checking again…"; it never tells you anything about it, nor starts your trip from it.
    @Published private(set) var asOf: Date?
    /// Its last answer per destination, saved in `<Caches>/answers` with where it was asked.
    struct SavedGo: Codable { let trips: [DoorTrip]; let lat: Double; let lon: Double }      // "go|<destination>"
    private var why: String?                                 // why the last look found nothing
    private var looks = 0                                    // the looks for the ways from here, numbered
    private var shownLook = 0                                // the look whose answer is on screen: an older one never replaces it
    private var firstOnly = false                            // what's on screen is a first answer, from before the rest was in
    private var seed: [DoorTrip] = []                        // the home screen's trips from here, to start with
    @Published private(set) var here: CLLocation?
    @Published private(set) var demo = false                 // pretend buses, to try it at home
    private var demoTask: Task<Void, Never>?
    private var look: Task<Void, Never>?                      // the "are you on board?" look, beside the planning
    private var lookRunning = false
    struct Note: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let text: String
    }

    private var fallback: CLLocation?
    private var loop: Task<Void, Never>?
    private var detect: Task<Void, Never>?
    private var since = Date()
    private var told: [String: Int] = [:]          // a ride's trip id → the delay you were last told about
    private var toldEnd: Date?                       // the arrival you were last told about
    private var toldGo: Set<String> = []             // "time to go" sent, per ride
    private var missed: (trip: DoorTrip, at: Date)?  // the one you were catching left: tell, unless you turn out to be on it
    private var posted: [String] = []                // its notifications, so only the newest stays

    // MARK: open and close

    /// Open the screen and start watching the way to `d`.
    /// `seed`: trips from where you are that the home screen just found: on screen at once, then looked up again.
    /// `planKey`: it's for a trip you planned (`schoolKey`, `arriveKey`), opened by hand or by itself: once it's closed,
    /// it doesn't open by itself for that trip again.
    /// `chosen`: the option you picked in Plan: that one is your trip while it's still to catch (with `seed`, Plan's
    /// options, on screen at once, a Be there by too).
    func open(to d: Place, from loc: CLLocation?, deadline dl: Date? = nil, label: String? = nil, planKey: String? = nil, seed: [DoorTrip] = [],
              chosen c: DoorTrip? = nil) {
        fallback = loc
        self.seed = dl == nil || c != nil ? seed : []
        chosen = c
        deadline = dl; deadlineLabel = label; self.planKey = planKey
        isOpen = true
        begin(d)
    }

    /// A trip you planned (a class, a Be there by time): be there by this, leaving as late as possible.
    @Published private(set) var deadline: Date?
    @Published private(set) var deadlineLabel: String?     // "your 09:00 class"
    private var planKey: String?                             // opened for this planned trip: closing it means not by itself again

    /// The planned trips' keys: your first class that day, and a Be there by (or Leave at) plan.
    static func schoolKey(_ classStart: Date) -> String { "school-\(Fmt.ymd.string(from: classStart))" }
    static func arriveKey(_ a: PlannedTrip) -> String { "arrive-\(a.date)-\(a.time)\(a.leaving ? "-leave" : "")" }

    /// When it opens by itself for your next class: from when the alarm rings (or 45 minutes before you leave) until
    /// just after the first bus has left.
    static func schoolWindowOpen(_ n: SchoolAlarm.Day, now: Date) -> Bool {
        guard SchoolAlarm.shared.on, let l = n.leave, let t = n.trip else { return false }
        return now > min(l.addingTimeInterval(-45 * 60), n.alarm ?? l) && now < t.first.departure.addingTimeInterval(5 * 60)
    }
    /// When it opens by itself (0.20.7, `autoGo`): from 20 minutes before you leave (not from the alarm: you'd watch for
    /// an hour behind the morning screen) until just after the first bus has left. The window above stays for the card.
    static func schoolAutoOpen(_ n: SchoolAlarm.Day, now: Date) -> Bool {
        guard SchoolAlarm.shared.on, let l = n.leave, let t = n.trip else { return false }
        return GoPace.autoOpen(leave: l, firstDeparture: t.first.departure, now: now)
    }
    /// …and for a Be there by plan from 20 minutes before you leave (a Leave at plan: a quarter of an hour).
    static func arriveAutoOpen(_ a: PlannedTrip, chosen: DoorTrip?, now: Date) -> Bool {
        guard a.when != nil, let t = chosen else { return false }
        return GoPace.autoOpen(leave: t.start, firstDeparture: t.first.departure, now: now, lead: a.leaving ? 15 * 60 : GoPace.autoOpenLead)
    }
    /// …and for a Be there by plan: from 45 minutes before you leave (a Leave at plan: a quarter of an hour) until just
    /// after its first bus has left.
    static func arriveWindowOpen(_ a: PlannedTrip, chosen: DoorTrip?, now: Date) -> Bool {
        guard a.when != nil, let t = chosen else { return false }
        return now > t.start.addingTimeInterval(a.leaving ? -15 * 60 : -45 * 60) && now < t.first.departure.addingTimeInterval(5 * 60)
    }
    /// The key for one opened by hand for your class: only while it would open by itself for it (outside that, closing
    /// it tonight mustn't stop it opening by itself for tomorrow's class).
    static func schoolKeyIfDue(_ classStart: Date, now: Date) -> String? {
        guard let n = SchoolAlarm.shared.next, n.classStart == classStart, schoolWindowOpen(n, now: now) else { return nil }
        return schoolKey(classStart)
    }

    /// The app opened around the time to leave for a trip you planned: open this screen for it (once; not again after you
    /// close it).
    func openForPlan(to d: Place, from loc: CLLocation?, deadline dl: Date?, label: String?, key: String) {
        guard !isOpen, UserDefaults.standard.string(forKey: "go.closedPlan") != key else { return }
        open(to: d, from: loc, deadline: dl, label: label, planKey: key)
    }

    /// Somewhere else to go (from the menu at the top).
    func retarget(_ d: Place) {
        guard isOpen, d != dest || !watching else { return }
        if d != dest { deadline = nil; deadlineLabel = nil; chosen = nil }      // somewhere else: not the planned trip any more
        begin(d)
    }

    /// Out of the screen: everything stops, and its notifications go.
    func close() {
        stopWatching()
        if let k = planKey { UserDefaults.standard.set(k, forKey: "go.closedPlan") }
        planKey = nil; deadline = nil; deadlineLabel = nil; chosen = nil
        isOpen = false
        clearPosted()
        demoTask?.cancel(); demoTask = nil
        if demo { demo = false; Demo.buses = [:] }
    }

    /// Watch again (after it stopped by itself).
    func again() { begin(dest) }

    private var emptyLooks = 0                 // looks in a row that found nothing (the wait grows: 4, 8, 16, 30 s)
    // 0.20.7
    private var unknown = LookBackoff.State()  // moving at bus speed, not sure which one: the looks so far (4, 8, 15, 30 s)
    private var openedFrom: CLLocation?        // where you were when it opened…
    private var movedMax = 0.0                 // …and the furthest you've been from there
    private var watchedFirst: Date?            // the departure it watched first: missed and not gone, it stops by itself
    private var extrasKept: [DoorTrip] = []    // the extras of the last look in front (behind the screen: no new ones)

    private func begin(_ d: Place) {
        loop?.cancel(); detect?.cancel()
        dest = d
        best = nil; others = []; error = nil; updated = nil; notes = []; arrived = false; seen = nil; overdue = false; onBoard = nil; movingUnknown = false; slow = false; hurry = nil
        firstOnly = false; asOf = nil; emptyLooks = 0
        unknown = LookBackoff.State(); openedFrom = nil; movedMax = 0; watchedFirst = nil; extrasKept = []
        told = [:]; toldEnd = nil; toldGo = []; missed = nil
        chosenMisses = 0; toldBeats = []
        since = Date()
        watching = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        trip?.setGo(true)
        look?.cancel()
        look = Task { [weak self] in await self?.firstLook() }    // on a bus or train already? at the same time as planning
        // Nothing from the home screen: its own last answer to `d`, from about here and recent, "as of" then.
        let saved = seed.isEmpty ? savedAnswer(d) : nil
        let start = saved?.trips ?? seed, startAt = saved?.at
        seed = []
        loop = Task { [weak self] in
            // what the home screen just found from here (or the last answer), on screen at once
            if let self, !start.isEmpty, let l = self.fallback ?? self.trip?.lastFix {
                self.here = l
                Self.waitFrom = l
                self.asOf = startAt
                await self.apply(start, loc: l, d: d, now: Date(), quiet: startAt != nil)
                if self.best == nil { self.asOf = nil }
            }
            var tried = Date.distantPast            // the last real look (also while it seemed offline)
            while !Task.isCancelled {
                guard let self, self.watching else { return }
                if !Net.online, Date().timeIntervalSince(tried) < Self.offlineTry {
                    // No connection: no requests, look again as soon as it's back (or once every half minute anyway: the
                    // phone can be wrong). Meanwhile what's on screen still loses what has left, and it still stops after
                    // `maxHours`.
                    if self.stopIfLong(now: Date()) { return }
                    if self.asOf != nil { self.keepSaved() } else if self.best != nil, let l = self.here { await self.apply([], loc: l, d: d, now: Date()) }
                    if self.best == nil { self.error = "No internet connection right now. It looks again as soon as you’re back online." }
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    continue
                }
                tried = Date()
                await self.refresh()
                // (the saved answer on screen isn't an answer: a dead connection waits longer each time behind it too)
                if self.best != nil && self.asOf == nil { self.emptyLooks = 0 } else if !self.movingUnknown { self.emptyLooks += 1 }
                // moving at bus speed and not sure which one: 4, 8, 15, then 30 s, from 4 again when it sees another
                self.unknown = self.movingUnknown ? LookBackoff.step(self.unknown, key: self.seen?.tripId) : LookBackoff.State()
                let wait: Double
                if self.movingUnknown {
                    wait = LookBackoff.wait(self.unknown)
                } else if self.best == nil || self.asOf != nil {
                    // nothing on screen yet (or only the saved answer): look again soon (no position yet: sooner still)
                    wait = self.here == nil ? 1.5 : Net.nextBackoff(failures: self.emptyLooks - 1)
                } else {
                    // quicker when the one you're catching is close; slower behind the screen, but "Time to go" on time
                    wait = GoPace.planWait(inFront: UIApplication.shared.applicationState == .active,
                                           departureIn: self.best?.first.departure.timeIntervalSinceNow,
                                           leaveIn: self.best?.start.timeIntervalSinceNow)
                }
                self.trip?.goGPSCheck()             // (rough GPS while you stand with long to go: `GoGPS`)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        detect = Task { [weak self] in
            var last: String?
            var unsure = LookBackoff.State(), nextAt = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, self.watching, !Task.isCancelled else { return }
                // moving at bus speed and not sure which one: these looks back off too (4, 8, 15, 30 s), from the start
                // again when it sees you with another one
                if self.movingUnknown {
                    guard Date() >= nextAt else { continue }
                } else {
                    unsure = LookBackoff.State(); nextAt = .distantPast
                }
                last = await self.checkBoarding(last)
                if self.movingUnknown {
                    unsure = LookBackoff.step(unsure, key: last)
                    nextAt = Date().addingTimeInterval(LookBackoff.wait(unsure) - 1)
                }
            }
        }
    }

    private func stopWatching() {
        watching = false
        loop?.cancel(); loop = nil
        detect?.cancel(); detect = nil
        look?.cancel(); look = nil
        seen = nil
        trip?.setGo(false)
    }

    /// While it seems offline, one real look every this many seconds anyway (the phone can say offline when it isn't).
    static let offlineTry: TimeInterval = 30

    /// The departure it watched first left 20 minutes ago, you haven't moved 300 m since it opened, and nothing else is
    /// wanted (no deadline, or it has passed): the trip didn't happen. It stops by itself, and says so (0.20.7).
    private func stopIfMissed(now: Date) -> Bool {
        guard !demo, onBoard == nil, trip?.phase == .idle,
              GoPace.autoStop(watched: watchedFirst, deadline: deadline, movedMetres: movedMax, now: now) else { return false }
        stopWatching()
        tell("Stopped watching", "The trip you were waiting for has gone and you stayed here · open Fastest trip again when you need it",
             kind: "info", sound: false)
        return true
    }

    /// Watching for `maxHours`: it stops by itself, and says so.
    private func stopIfLong(now: Date) -> Bool {
        guard now.timeIntervalSince(since) > Self.maxHours * 3600 else { return false }
        stopWatching()
        tell("Stopped watching", "After \(Int(Self.maxHours)) hours · open Fastest trip again when you need it", kind: "info", sound: false)
        return true
    }

    // MARK: the fastest way, again and again

    private func refresh() async {
        guard watching else { return }
        // the newest fix; an old one only when no new one comes (indoors)
        let fix = [trip?.lastFix, fallback].compactMap { $0 }.max { $0.timestamp < $1.timestamp }
        guard let loc = fix, loc.timestamp.timeIntervalSinceNow > -300 || Date().timeIntervalSince(since) > 8 else {
            if trip?.locationDenied == true { error = "Location is off for Haltewekker. Turn it on in Settings to plan from where you are." }
            return
        }
        here = loc
        Self.waitFrom = loc
        // (how far you've been from where it opened: not at all, and the one it watched long gone, it stops by itself)
        if openedFrom == nil, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 200 { openedFrom = loc }
        if let o = openedFrom, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 200 { movedMax = max(movedMax, loc.distance(from: o)) }
        // The on-board look found the one you're on: its plan is on screen while it makes sure. Leave it.
        if onBoard != nil { return }
        // Going at train or bus speed (faster than a bike): a walk to a stop from here makes no sense. Find which one
        // you're on (beside this, not in the way) and plan from it; until then, say so. (In a car it plans once you stop.)
        if LiveStore.movingFix(loc), loc.speed >= 8, loc.timestamp.timeIntervalSinceNow > -30, trip?.phase == .idle, !demo {
            lookAgain()
            movingUnknown = true
            best = nil; others = []; asOf = nil; error = nil
            return
        }
        movingUnknown = false
        let now = Date()
        if stopIfLong(now: now) || stopIfMissed(now: now) { return }
        let target = CLLocation(latitude: dest.coordinate.latitude, longitude: dest.coordinate.longitude)
        if loc.distance(from: target) < 400 && loc.horizontalAccuracy < 200 {
            arrived = true
            stopWatching()
            return
        }
        let d = dest
        // The ways from here, within 8 seconds (a slow answer doesn't hold the screen: it tries again on the next look).
        let c = loc.coordinate
        // On its own connections (never behind the boards and the school alarm), and kept when it's slow: after 8 seconds
        // it says so, and after 25 it stops for this look, keeping what arrived. The first answer that's in (the plan
        // from your spot) shows at once on an empty screen; the whole answer replaces it.
        looks += 1
        let n = looks
        let slowNote = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled, let self, self.best == nil { self.slow = true }
        }
        let answer = await Transit.$urgent.withValue(true) {
            await Net.withPartials(25, { publish in await Transit.tripsFrom(c, to: d, count: 6, keep: 8, publish: publish) },
                                   partial: { [weak self] list in await self?.fill(list, look: n, loc: loc, d: d, now: now) })
        }
        slowNote.cancel()
        slow = false
        guard !Task.isCancelled, watching, dest == d, onBoard == nil, n >= shownLook else { return }
        let firstOnScreen = firstOnly && best != nil
        let savedOnScreen = asOf != nil && best != nil
        // Out of time with a whole live answer on screen: that stays (what arrived only fills an empty screen, or replaces
        // a first answer or the saved one).
        let found: [DoorTrip] = answer.timedOut && best != nil && !firstOnScreen && !savedOnScreen ? [] : (answer.value ?? [])
        why = answer.timedOut && found.isEmpty ? "No answer within 25 seconds: a slow connection."
            : found.isEmpty ? (Transit.trouble.recent().map { "\($0)." } ?? "Transitous found no way from here.") : nil
        if !found.isEmpty {
            // A first answer or the saved one on screen: this replaces it as if the screen were empty, so neither ever
            // leads to a "Faster:" or "Too late".
            if firstOnScreen { best = nil; others = [] }
            forgetSaved()
            // (what arrived before the time ran out is a first answer too: the next whole one replaces it the same way)
            firstOnly = answer.timedOut
            shownLook = n
        }
        if found.isEmpty && savedOnScreen {
            // No live answer yet: the saved one stays, "as of", minus what's gone; once nothing of it is left, as an
            // empty screen.
            keepSaved()
            if best == nil { await apply([], loc: loc, d: d, now: now) }
        } else {
            await apply(found, loc: loc, d: d, now: now)
            saveShown(found, loc: loc, d: d, at: now)
        }
        // Then, with that on screen, the extras: earlier ways onto the same connection, which the planner leaves out (the
        // same arrival, but you'd leave earlier: the Sprinter that's in Breda before the Intercity and makes the same bus,
        // the earlier 306 that leaves room to change), and for a planned trip the latest that still get you there in time.
        // (Not onto a saved answer's trip: it waits for a live one.)
        // Behind the screen (0.20.7) no new extras (more plans and boards per look): the last ones, while still to come.
        var more: [DoorTrip] = []
        if GoPace.extras(inFront: UIApplication.shared.applicationState == .active) {
            async let late: [DoorTrip] = latestInTime(from: c, to: d, now: now)
            if asOf == nil, let top = best { more += await Transit.$urgent.withValue(true) { await Net.within(8) { await self.earlierWays(onto: top) } } ?? [] }
            more += await late
            extrasKept = more
        } else {
            more = extrasKept.filter { $0.first.departure > Date() }
        }
        var ids = Set(found.map(\.id))
        more = more.filter { ids.insert($0.id).inserted }
        guard !more.isEmpty, !Task.isCancelled, watching, dest == d, onBoard == nil, n >= shownLook else { return }
        forgetSaved()               // (the saved answer still on screen: these live ones replace it as if it were empty)
        await apply(found + more, loc: loc, d: d, now: Date())
        saveShown(found + more, loc: loc, d: d, at: now)
    }

    /// Its last answer to `d`, to show at once: asked at most 30 minutes ago within 400 m of where you are, minus the ones
    /// you can't make any more (nil: nothing saved, or nothing left of it).
    private func savedAnswer(_ d: Place) -> (trips: [DoorTrip], at: Date)? {
        let now = Date()
        let you = (fallback ?? trip?.lastFix).map { (lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        guard let s = SnapshotStore.shared.load(SavedGo.self, key: "go|\(d.key)", maxAge: 1800, now: now),
              Snapshots.closeEnough(saved: (lat: s.value.lat, lon: s.value.lon), here: you, metres: 400) else { return nil }
        let left = Self.stillOn(s.value.trips, now: now)
        guard !left.isEmpty else { return nil }
        return (trips: left, at: s.at)
    }

    /// The ones of a saved answer you can still make: not gone, not cancelled, and you'd have had to set off at most a
    /// minute and a half ago (the ones `apply` would keep).
    private static func stillOn(_ l: [DoorTrip], now: Date) -> [DoorTrip] {
        l.filter { t in
            guard let f = t.rides.first else { return false }
            return f.departure > now && !f.cancelled && t.start >= now.addingTimeInterval(-90)
        }
    }

    /// No live answer yet while the saved one is on screen: it stays, minus what's gone (and still tells you nothing);
    /// once nothing of it is left, the screen is empty.
    private func keepSaved() {
        let left = Self.stillOn([best].compactMap { $0 } + others, now: Date())
        guard let b = left.first(where: { $0.id == best?.id }) ?? left.min(by: Self.sooner) else {
            best = nil; others = []; asOf = nil
            return
        }
        best = b
        others = left.filter { $0.id != b.id }
    }

    /// A live answer is in while the saved one is on screen: it replaces that as if the screen were empty, so a saved
    /// answer never leads to a "Faster:", a "Too late" or any other notification.
    private func forgetSaved() {
        guard asOf != nil else { return }
        asOf = nil
        best = nil; others = []
    }

    /// After a live answer: what's on screen is saved (with where it was asked) to show at once next time, when the one
    /// it's watching came in with this answer. (One kept from before, while you're waiting for it or on your way to it,
    /// is older: the file keeps the answer it came with.)
    private func saveShown(_ list: [DoorTrip], loc: CLLocation, d: Place, at: Date) {
        guard asOf == nil, dest == d, let b = best, list.contains(b) else { return }
        SnapshotStore.shared.save(SavedGo(trips: [b] + others, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude),
                                  key: "go|\(d.key)", at: at)
    }

    /// The first answer that's in, while the rest is still coming: shown only on an empty screen, or over the saved
    /// answer (so it never replaces a live one, and never says "Faster:" or "Too late").
    private func fill(_ list: [DoorTrip], look n: Int, loc: CLLocation, d: Place, now: Date) async {
        guard !Task.isCancelled, watching, dest == d, onBoard == nil, best == nil || asOf != nil, !list.isEmpty, n >= shownLook else { return }
        forgetSaved()
        slow = false
        shownLook = n
        firstOnly = true
        await apply(list, loc: loc, d: d, now: now)
        saveShown(list, loc: loc, d: d, at: now)
    }

    /// A planned trip: the latest ways that still get you there in time (within 6 seconds).
    private func latestInTime(from c: CLLocationCoordinate2D, to d: Place, now: Date) async -> [DoorTrip] {
        guard let dl = deadline else { return [] }
        return await Transit.$urgent.withValue(true) { await Net.within(8) {
            // every destination stop at once (the answers keep their order)
            let jobs: [@Sendable () async -> [DoorTrip]] = d.ids.map { b in
                { @Sendable in await Transit.plan(from: "\(c.latitude),\(c.longitude)", to: b, modes: nil, at: dl, count: 5, maxTransfers: 4, arriveBy: true) }
            }
            let out = await Progressive.all(jobs).flatMap { $0 }
            return out.filter { $0.first.departure >= now.addingTimeInterval(-60) }
        } } ?? []
    }

    /// The look at what you're on, again (unless it's looking already).
    private func lookAgain() {
        guard !lookRunning else { return }
        look = Task { [weak self] in await self?.firstLook() }
    }

    /// Choose from what it found, put it on screen, and tell you what changed. `quiet`: the saved answer, put on screen
    /// with nothing to tell (only a live answer tells you things).
    private func apply(_ found: [DoorTrip], loc: CLLocation, d: Place, now: Date, quiet: Bool = false) async {
        // Nothing from here, and you were just going at train or bus speed (slowing down, or stopped at a signal between
        // stations): you're on board. Find which one, and don't say there's no way.
        if found.isEmpty, best == nil, trip?.movedRecently == true, onBoard == nil, trip?.phase == .idle, !demo {
            lookAgain()
            movingUnknown = true; error = nil
            return
        }
        // One empty answer keeps what you had (that hasn't left).
        var list = found.isEmpty ? ([best].compactMap { $0 } + others).filter { $0.first.departure > now } : found
        // The ride you chose: as this answer has it (by its rides' trip ids), else kept as it was while it's still to
        // come (later than this answer reaches). Gone once cancelled, or missing from a few whole answers that reach past it.
        if let c = chosen {
            if let i = ChosenRide.match(c.rides.map(\.tripId), in: list.map { $0.rides.map(\.tripId) }) {
                chosen = list[i]; chosenMisses = 0
            } else if !quiet, ChosenRide.countsAsMiss(departure: c.first.departure, answer: found.map(\.first.departure), whole: !firstOnly) {
                chosenMisses += 1
            }
            if let k = chosen, k.rides.contains(where: \.cancelled) {
                dropChosen(.cancelled)
            } else if chosenMisses >= ChosenRide.maxMisses {
                dropChosen(.missing)
            } else if let k = chosen, !list.contains(where: { $0.id == k.id }), k.first.departure > now {
                list.append(k)
            }
        }
        // The ones you can still make: not cancelled, and you'd have had to set off at most a minute and a half ago.
        let ok = list.filter { !$0.first.cancelled && $0.start >= now.addingTimeInterval(-90) }
        // The one you're waiting for at its stop, just past its time, is still the one: buses run late without the live
        // data knowing. Keep it for a few minutes instead of quietly swapping in another bus (or another line).
        if let cur = best, !cur.first.cancelled, !ok.contains(where: { $0.first.tripId == cur.first.tripId }),
           cur.first.departure < now.addingTimeInterval(60), now < cur.first.departure.addingTimeInterval(6 * 60),
           let la = cur.first.fromLat, let lo = cur.first.fromLon,
           loc.distance(from: CLLocation(latitude: la, longitude: lo)) < 200, (trip?.currentSpeed ?? 0) < 2.5 {
            overdue = true
            others = Array(ok.filter { $0.first.tripId != cur.first.tripId }.sorted(by: Self.sooner).prefix(5))
            error = nil
            updated = now
            return
        }
        overdue = false
        // The one you're on your way to, that the planner now leaves out because at its walking pace you can't make it:
        // at a brisk walk you still can. Keep it (and say hurry) rather than swap in a worse one.
        if let cur = best, !cur.first.cancelled, !ok.contains(where: { $0.first.tripId == cur.first.tripId }),
           let la = cur.first.fromLat, let lo = cur.first.fromLon, (trip?.phase ?? .idle) == .idle {
            let m = loc.distance(from: CLLocation(latitude: la, longitude: lo))
            let left = cur.first.departure.timeIntervalSince(now)
            if left > 60, m > 60, m * 1.3 / 1.7 <= left {
                hurry = (Int(m), Int(left / 60))
                others = Array(ok.filter { $0.first.tripId != cur.first.tripId }.sorted(by: Self.sooner).prefix(5))
                error = nil
                updated = now
                return
            }
        }
        hurry = nil
        var pick = ok.min(by: Self.sooner)
        if let dl = deadline {
            // be there by a time: the one that leaves the latest and still makes it, with changes you're not likely to
            // miss (or else the soonest there)
            let onTime = ok.filter { $0.end <= dl.addingTimeInterval(60) }
            // a safe one leaves at most 35 minutes before the latest that makes it
            let latest = onTime.map(\.start).max()
            let safe = onTime.filter { Risk.penalty($0) < Risk.safe && $0.start >= (latest ?? .distantPast).addingTimeInterval(-35 * 60) }
            pick = (safe.isEmpty ? onTime : safe).max(by: { ($0.start, -$0.rides.count, -Self.outside($0)) < ($1.start, -$1.rides.count, -Self.outside($1)) }) ?? pick
        }
        // Stay with the one you're catching unless another is clearly better: a minute sooner there (or, for a planned
        // trip, still in time and leaving two minutes later).
        if let cur = best, let p = pick, p.first.tripId != cur.first.tripId,
           let same = ok.filter({ $0.first.tripId == cur.first.tripId }).min(by: Self.sooner) {
            if let dl = deadline {
                if same.end <= dl.addingTimeInterval(60) && p.start < same.start.addingTimeInterval(120)
                    && (Risk.penalty(same) < Risk.safe || Risk.penalty(p) >= Risk.penalty(same)) { pick = same }
            } else if Risk.score(p) > Risk.score(same) - 1 {
                pick = same
            }
        }
        // The ride you chose stays your trip, whatever's faster (a way that beats it outright is a note, once); one you
        // can't catch any more goes, and then it's the fastest again.
        if let c = chosen {
            if let mine = ok.first(where: { $0.id == c.id }) {
                if !quiet, let p = pick, p.id != mine.id, ChosenRide.beats(start: p.start, end: p.end, chosenStart: mine.start, chosenEnd: mine.end),
                   toldBeats.insert(p.first.tripId).inserted {
                    remark("Faster: \(Self.what(p.first)) at \(Fmt.hhmm(p.first.departure)), \(d.short) \(Fmt.hhmm(p.end)) · it stays with the one you chose")
                }
                pick = mine
            } else {
                dropChosen(.left)
            }
        }
        guard let p = pick else {
            if quiet { return }
            if !found.isEmpty || best == nil {
                best = nil; others = []
                error = "No way to \(d.short) found from here right now. It tries again in a few seconds." + (why.map { "\n\($0)" } ?? "")
            }
            return
        }
        let prev = best
        best = p
        others = Array(ok.filter { $0.first.tripId != p.first.tripId }.sorted(by: Self.sooner).prefix(5))
        error = nil
        if quiet { return }
        if watchedFirst == nil { watchedFirst = p.first.departure }
        updated = now
        if let prev, prev.first.tripId != p.first.tripId {
            await switched(from: prev, to: p, found: found)
        } else if prev != nil {
            changed(p)
        }
        if prev == nil || prev!.first.tripId != p.first.tripId {
            told[p.first.tripId] = p.first.live ? p.first.delay : 0
            toldEnd = p.end
            if p.start <= now.addingTimeInterval(60) { toldGo.insert(p.first.tripId) }     // the screen (or the switch) says go now
        }
        timeToGo(p)
        if let m = missed, now.timeIntervalSince(m.at) >= 120, trip?.phase == .idle {
            missed = nil
            tell("\(Self.title(m.trip.first)) has left", "Next: \(Self.what(p.first)) at \(Fmt.hhmm(p.first.departure)) from \(Fmt.place(p.first.fromStop)) · \(d.short) \(Fmt.hhmm(p.end))", kind: "late")
        }
    }

    private var earlierCache: (id: String, at: Date, list: [DoorTrip])?

    /// Earlier ways onto `t` (looked up again every minute and a half, or when the one it watches changes).
    private func earlierWays(onto t: DoorTrip) async -> [DoorTrip] {
        let now = Date()
        if let c = earlierCache, c.id == t.id, now.timeIntervalSince(c.at) < 90 {
            return c.list.filter { $0.first.departure > now.addingTimeInterval(Double($0.first.walkBefore) * 60) }
        }
        let list = await Transit.earlierWays(onto: t, now: now)
        earlierCache = (t.id, now, list)
        return list
    }

    /// Which gets you there first: the earliest arrival; the same arrival, then fewer changes, then the one that leaves later
    /// (less waiting around).
    static func sooner(_ a: DoorTrip, _ b: DoorTrip) -> Bool {
        // when you'd likely be there: the arrival, plus what a change you could well miss would cost (one train missed is
        // often 20 to 30 minutes)
        let sa = Risk.score(a), sb = Risk.score(b)
        if abs(sa - sb) >= 1 { return sa < sb }
        // the same: the one where you stand outside least (on the train sooner, out of the cold)
        let wa = outside(a), wb = outside(b)
        if abs(wa - wb) >= 1.5 { return wa < wb }
        if a.rides.count != b.rides.count { return a.rides.count < b.rides.count }
        return a.first.departure > b.first.departure
    }

    /// Where you are, for how long you'd wait outside (set on each look).
    static var waitFrom: CLLocation?

    /// Minutes you'd stand waiting: at each change, from getting there until it leaves; and at the first stop too when
    /// you're there already (from home you'd simply leave later).
    static func outside(_ t: DoorTrip, now: Date = Date()) -> Double {
        var w = 0.0
        if let h = waitFrom, let a = t.first.fromLat, let o = t.first.fromLon,
           h.distance(from: CLLocation(latitude: a, longitude: o)) < 250 {
            w += max(0, t.first.departure.timeIntervalSince(now) / 60)
        }
        for i in t.rides.indices.dropFirst() {
            let r = t.rides[i], p = t.rides[i - 1]
            w += max(0, r.departure.timeIntervalSince(p.arrival) / 60 - Double(r.walkBefore))
        }
        return w
    }

    /// The fastest way changed: say why, and that it's watching the new one now.
    private func switched(from old: DoorTrip, to new: DoorTrip, found: [DoorTrip]) async {
        let now = Date(), f = new.first
        let take = "\(Self.what(f)) at \(Fmt.hhmm(f.departure)) from \(Fmt.place(f.fromStop))"
        if old.first.departure < now.addingTimeInterval(-20) {
            if missed == nil { missed = (old, now) }         // wait a little: you may be on it
            return
        }
        let o = old.first
        let cancelled = await Self.isCancelled(o)
        guard watching else { return }
        if cancelled {
            tell("\(Self.title(o)) at \(Fmt.hhmm(o.scheduledDeparture)) is cancelled", "Take \(take) instead · \(dest.short) \(Fmt.hhmm(new.end))", kind: "cancelled")
        } else if old.start < now.addingTimeInterval(-90) {
            tell("Too late for \(Self.what(o))", "Take \(take) instead · \(dest.short) \(Fmt.hhmm(new.end))", kind: "late")
        } else if let dl = deadline, new.start > old.start {
            tell("You can leave later: \(Self.title(f)) at \(Fmt.hhmm(f.departure))", "Leave by \(Fmt.hhmm(new.start)) · still at \(dest.short) \(Fmt.hhmm(new.end)), in time for \(deadlineLabel ?? Fmt.hhmm(dl))", kind: "ok")
        } else {
            let oldNow = found.filter { $0.first.tripId == o.tripId }.min(by: { $0.end < $1.end }) ?? old
            let gain = Fmt.mins(oldNow.end.timeIntervalSince(new.end))
            tell("Faster: \(Self.title(f)) at \(Fmt.hhmm(f.departure))", "\(dest.short) \(Fmt.hhmm(new.end))\(gain >= 1 ? ", \(gain) min sooner" : "") · leave by \(Fmt.hhmm(new.start)) · from \(Fmt.place(f.fromStop))", kind: "faster")
        }
    }

    /// The same one, but later or earlier than you were told (or the rest of the trip moved).
    private func changed(_ p: DoorTrip) {
        let f = p.first
        if f.live {
            let dl = f.delay, last = told[f.tripId] ?? 0
            if abs(dl - last) >= 2 || (dl <= -1 && last > -1) || (dl == 0 && abs(last) >= 2) {
                told[f.tripId] = dl
                toldEnd = p.end
                if dl >= 1 {
                    tell("\(Self.title(f)) is \(dl) min late", "Leaves \(Fmt.hhmm(f.departure)) instead of \(Fmt.hhmm(f.scheduledDeparture)) · still your \(chosen == nil ? "fastest" : "pick"), \(dest.short) \(Fmt.hhmm(p.end))", kind: "late")
                } else if dl <= -1 {
                    tell("\(Self.title(f)) leaves \(-dl) min early", "Leaves \(Fmt.hhmm(f.departure)) instead of \(Fmt.hhmm(f.scheduledDeparture)) · be at \(Fmt.place(f.fromStop)) in time", kind: "late")
                } else {
                    tell("\(Self.title(f)) is on time again", "Leaves \(Fmt.hhmm(f.departure)) · \(dest.short) \(Fmt.hhmm(p.end))", kind: "ok", sound: false)
                }
                return
            }
        }
        if let e = toldEnd, abs(p.end.timeIntervalSince(e)) >= 180 {
            toldEnd = p.end
            tell("\(dest.short) at \(Fmt.hhmm(p.end)) now", "Was \(Fmt.hhmm(e)) · still take \(Self.what(f)) at \(Fmt.hhmm(f.departure))", kind: "info", sound: false)
        }
    }

    /// When it's time to walk to the stop.
    private func timeToGo(_ p: DoorTrip) {
        let f = p.first, now = Date()
        guard f.walkBefore >= 2, !toldGo.contains(f.tripId), p.start <= now.addingTimeInterval(60) else { return }
        toldGo.insert(f.tripId)
        tell("Time to go", "\(f.walkBefore) min walk to \(Fmt.place(f.fromStop)) · \(Self.what(f)) leaves \(Fmt.hhmm(f.departure))", kind: "go")
    }

    private static func isCancelled(_ r: Ride) async -> Bool {
        let b = await Transit.board(stopIds: [r.fromId], from: r.scheduledDeparture.addingTimeInterval(-5 * 60), n: 20)
        return b.first(where: { $0.tripId == r.tripId })?.cancelled ?? false
    }

    // MARK: on board already?

    /// Right as it opens: are you on a bus or train already? A fresh GPS fix (a few seconds at most); moving like a bus
    /// or train (or just were: standing at a stop on board), with one going your way right where its times put it, it
    /// plans from that one: stay on, or where to change. One more look a few seconds later to be sure you're with it
    /// (not in a car next to it), and the trip starts by itself. Otherwise it plans from where you are, as before.
    private func firstLook() async {
        guard let trip, trip.phase == .idle, !demo, watching, !lookRunning else { return }
        lookRunning = true
        defer { lookRunning = false }
        let opened = Date()
        var fix: CLLocation?
        // a fix from the last 20 seconds is good enough; else wait for one, two and a half seconds at most
        for _ in 0..<10 {
            if let f = trip.lastFix, f.horizontalAccuracy >= 0, f.horizontalAccuracy < 100, f.timestamp > opened.addingTimeInterval(-20) {
                fix = f
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard watching else { return }
        }
        guard let f = fix ?? trip.lastFix, LiveStore.movingFix(f) || trip.movedRecently else { return }      // not moving like a bus
        // moving like one: now it's really checking (and says so)
        lookingOnBoard = true
        defer { lookingOnBoard = false }
        let d = dest
        let moving = trip.movedRecently
        let history: @MainActor @Sendable () -> [Fix] = { trip.recentFixes }        // (read once its request is in)
        guard var ob = await Transit.$urgent.withValue(true, operation: { await Net.within(10, { await LiveStore.onBoardTrips(f, to: d, wasMoving: moving, reuse: true, history: history) }) }) ?? nil,
              watching, dest == d, trip.phase == .idle, !ob.1.isEmpty else { return }
        movingUnknown = false
        forgetSaved()
        onBoard = ob.0.vehicle
        best = ob.1.first; others = Array(ob.1.dropFirst())
        here = f; updated = Date(); error = nil
        // (The matcher: a look before your fixes span 20 s isn't sure either way and doesn't count, for a minute at
        // most; the plan from the one it found stays on screen meanwhile, and after that minute it's as if not seen.)
        let confirming = Date()
        var looks = 0
        while looks < 4 {
            if !MatchSettings.classic(), Date().timeIntervalSince(confirming) >= 60 { break }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard watching, dest == d, trip.phase == .idle, let v = onBoard else { return }
            let sure = MatchSettings.classic() || VehicleMatch.enough(trip.recentFixes)
            let R = MatchRules.current()
            let ranked = await trip.matchVehicles(mode: nil, planned: v.tripId, place: "confirm")
            guard watching, dest == d, trip.phase == .idle else { return }
            if let me = ranked.first(where: { $0.vehicle.tripId == v.tripId }), let t = best {
                let close = ranked.filter { $0.vehicle.tripId != v.tripId && $0.cost < me.cost + R.close }.map(\.vehicle)
                if board(t, v, alternatives: ob.1, couldBe: close) { return }
                break                       // its stop is where you are: not this one, plan from where you are
            }
            guard sure else { continue }
            looks += 1
            // another one fits you better: plan from that one, and look once more
            if let m = ranked.first, let loc = trip.lastFix,
               let o2 = await LiveStore.onBoardTrips(loc, to: d, tripId: m.vehicle.tripId, reuse: true), !o2.1.isEmpty, watching, dest == d {
                ob = o2
                onBoard = o2.0.vehicle
                best = o2.1.first; others = Array(o2.1.dropFirst()); updated = Date()
            }
        }
        // not seen with it again (or not sure for a whole minute): it plans from where you are right away (and still
        // notices when you're on one)
        onBoard = nil; best = nil; others = []
        await refresh()
    }

    // MARK: on board?

    /// Every few seconds: is your GPS moving with a bus or train? One look is enough for the one it's watching (or one of the
    /// others it found); any other one has to be the same twice and take you there.
    private func checkBoarding(_ last: String?) async -> String? {
        guard let trip, trip.phase == .idle, watching, !lookingOnBoard else { return nil }
        let R = MatchRules.current()
        // (only a live answer is one it's watching: a saved one gets no head start)
        let ranked = await trip.matchVehicles(mode: nil, planned: asOf == nil ? best?.first.tripId : nil, place: "board")
        guard var m = ranked.first else { seen = nil; return nil }
        guard watching, trip.phase == .idle else { return nil }
        // at bus speed, not running for it while it passes you
        guard (trip.currentSpeed ?? 0) >= 3.5 else { return last }
        // (the saved answer on screen isn't one it's watching: only a live answer can start your trip)
        let live = asOf == nil
        let all: [DoorTrip] = live ? [best].compactMap { $0 } + others : []
        // Buses that leave the same stop together (the 305 and the 306 at Veghel) fit about the same at first: the one
        // it's watching wins when it fits nearly as well.
        if live, let b = best, m.vehicle.tripId != b.first.tripId,
           let bm = ranked.first(where: { $0.vehicle.tripId == b.first.tripId }), bm.score < m.score + R.plannedEdge { m = bm }
        let twice = last == m.vehicle.tripId
        // the others that fit about as well: the ride keeps them in the running until there's real distance between them
        let close = ranked.filter { $0.vehicle.tripId != m.vehicle.tripId && $0.cost < m.cost + R.close }.map(\.vehicle)
        if let t = all.first(where: { $0.first.tripId == m.vehicle.tripId }) {
            // one look for the line it's watching; another line has to be the same twice
            let sameLine = (live ? best : nil).map { $0.first.line == m.vehicle.line } ?? true
            if (m.cost < R.oneLookWatched && sameLine) || twice {
                board(t, m.vehicle, alternatives: all, couldBe: close)
                return nil
            }
            seen = m.vehicle
            return m.vehicle.tripId
        }
        if twice, let loc = trip.lastFix, let ob = await LiveStore.onBoardTrips(loc, to: dest, reuse: true, history: { trip.recentFixes }),
           ob.0.vehicle.tripId == m.vehicle.tripId, let t = ob.1.first {
            // a long way round is probably not a bus you're on (a car or bike next to one)
            if asOf == nil, let b = best, t.end > b.end.addingTimeInterval(30 * 60) { seen = nil; return m.vehicle.tripId }
            guard watching, trip.phase == .idle else { return nil }
            board(t, ob.0.vehicle, alternatives: all, couldBe: ranked.map(\.vehicle).filter { $0.tripId != ob.0.vehicle.tripId && close.contains($0) })
            return nil
        }
        seen = m.vehicle
        return m.vehicle.tripId
    }

    /// On board: the trip starts by itself (the ride screen takes over) and the watching stops.
    /// `alternatives`: the ways it was choosing between, so the ride can still switch if it turns out you're on another one.
    /// `couldBe`: other buses that fit about as well; the ride decides between them once they're clearly apart.
    /// Not when its first stop is where you are already (a bus standing at the bus station you're at): it would ring and
    /// say "You're at …" at once. False then.
    @discardableResult private func board(_ t: DoorTrip, _ v: Vehicle, alternatives: [DoorTrip] = [], couldBe: [Vehicle] = []) -> Bool {
        guard let r = RoutePlan.from(t), let trip, !trip.refusesAtItsStop(r, what: "Go board onto", vehicle: v) else { return false }
        trip.start(r, vehicle: v, auto: true, alternatives: alternatives, couldBe: couldBe, how: "Go board")
        close()
        let c = UNMutableNotificationContent()
        c.title = "You’re on the \(v.title)"
        let first = r.legs(trip.direction).first?.to.short ?? "your stop"
        // (a leg that started inside its wake distance has no alarm: it tells you at the stop)
        c.body = "Your trip to \(r.station.short) started by itself. "
            + (trip.phase == .awake ? "It tells you when you’re at \(first)." : "It rings before \(first).")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "goboard-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil)) { _ in }
        return true
    }

    /// "I'm on it" on `t`, the card you tapped (not whatever the screen shows by the time the tap comes in): start the
    /// trip by hand. Without one it knows you're on, it still looks for which one, and the one this card rides holds
    /// against another it sees on its road (an Intercity to Den Bosch on the track the one to Breda shares). While it
    /// had another one in mind (the one it saw you with), you said it's this one: the ride takes it as picked, as
    /// "I'm on this one" in the list.
    func startByHand(_ t: DoorTrip) {
        if demo, let a = t.first.fromLat, let o = t.first.fromLon {
            trip?.startDemo(from: .init(latitude: a, longitude: o), line: t.first.line)
            close()
            return
        }
        guard let r = RoutePlan.from(t), let trip else { return }
        let rest = others.filter { $0.id != t.id } + (best.map { $0.id == t.id ? [] : [$0] } ?? [])
        if let v = onBoard, t.first.tripId == v.tripId {
            trip.start(r, vehicle: v, alternatives: [t] + rest, how: "Go hand")
        } else if onBoard != nil {
            let f = t.first
            trip.start(r, vehicle: Vehicle(tripId: f.tripId, line: f.line, isTrain: f.isTrain), alternatives: [t] + rest, picked: true,
                       how: "Go hand, picked")
        } else {
            trip.start(r, onIt: true, how: "Go hand")
        }
        close()
    }

    // MARK: the demo

    /// The screen with pretend buses from the stop nearest to you: what to take, the walk, the bus coming on the map, the
    /// notifications (time to go, late, something faster), then it "sees" you get on and the pretend ride starts.
    func startDemo(near loc: CLLocation?) {
        close()
        demo = true
        isOpen = true
        dest = RoleSnapshot.corridor != nil ? .breda : .school     // (off the corridor: your school, 0.24)
        asOf = nil
        best = nil; others = []; error = nil; updated = nil; notes = []; arrived = false; seen = nil; overdue = false; onBoard = nil; movingUnknown = false; slow = false; hurry = nil
        here = loc ?? trip?.lastFix
        watching = true
        demoTask = Task { [weak self] in await self?.runDemo() }
    }

    private func runDemo() async {
        let c = here?.coordinate ?? trip?.here ?? Place.home.coordinate
        var name = "Your nearest stop"
        var s = CLLocationCoordinate2D(latitude: c.latitude + 0.0016, longitude: c.longitude + 0.0022)
        if let n = await Transit.nearStops(c).first(where: { !$0.rail }) { name = n.name; s = .init(latitude: n.lat, longitude: n.lon) }
        guard demo, isOpen else { return }
        let metres = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: CLLocation(latitude: s.latitude, longitude: s.longitude))
        let walk = max(1, Int((metres / 80).rounded()))
        let t0 = Date()
        // the corridor's Den Bosch and Breda; off it a made-up station a few km on and your school (0.24)
        let corridor = RoleSnapshot.corridor != nil, dn = RoleWords.current.demoNames
        let ht = corridor ? Place.denBosch.coordinate : CLLocationCoordinate2D(latitude: c.latitude + 0.012, longitude: c.longitude + 0.038)
        let bd = corridor ? Place.breda.coordinate : Place.school.coordinate
        func bus(_ id: String, _ line: String, _ dep: TimeInterval, planned: TimeInterval? = nil, ride: TimeInterval = 20 * 60) -> Ride {
            let d = t0.addingTimeInterval(dep), p = t0.addingTimeInterval(planned ?? dep)
            return Ride(tripId: id, line: line, name: line, isTrain: false, departure: d, scheduledDeparture: p,
                        arrival: d.addingTimeInterval(ride), scheduledArrival: p.addingTimeInterval(ride), fromStop: name, fromId: "demo-stop",
                        toStop: dn.busTo, platform: nil, live: true, cancelled: false, walkBefore: walk,
                        headsign: dn.busHeadsign, fromLat: s.latitude, fromLon: s.longitude, toLat: ht.latitude, toLon: ht.longitude)
        }
        func intercity(_ dep: TimeInterval) -> Ride {
            let d = t0.addingTimeInterval(dep)
            return Ride(tripId: "demo-ic-\(Int(dep))", line: "IC", name: "Intercity", isTrain: true, departure: d, scheduledDeparture: d,
                        arrival: d.addingTimeInterval(30 * 60), scheduledArrival: d.addingTimeInterval(30 * 60), fromStop: dn.trainFrom,
                        fromId: "demo-ht", toStop: dn.trainTo, platform: "3", live: true, cancelled: false, walkBefore: 0,
                        headsign: dn.trainHeadsign, fromLat: ht.latitude, fromLon: ht.longitude, toLat: bd.latitude, toLon: bd.longitude)
        }
        func door(_ b: Ride, _ t: Ride) -> DoorTrip { DoorTrip(rides: [b, t], start: b.departure.addingTimeInterval(Double(-walk * 60)), end: t.arrival) }
        func show(_ b: Ride) { Demo.buses[b.tripId] = Demo.Bus(line: b.line, stopName: name, stop: s, departure: b.departure, planned: b.scheduledDeparture) }
        func at(_ t: TimeInterval) async -> Bool {
            let left = t0.addingTimeInterval(t).timeIntervalSinceNow
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
            return !Task.isCancelled && demo && isOpen
        }
        let stop = Fmt.place(name)
        // the 306 in two and a half minutes, then the Intercity from Den Bosch
        let b306 = bus("demo-306", "306", 150), ic2 = intercity(150 + 28 * 60)
        let later = [door(bus("demo-306-later", "306", 150 + 15 * 60), intercity(150 + 43 * 60)),
                     door(bus("demo-305", "305", 150 + 26 * 60, ride: 24 * 60), intercity(150 + 58 * 60))]
        show(b306)
        best = door(b306, ic2); others = later; updated = Date()
        guard await at(10) else { return }
        tell("Time to go", "\(walk) min walk to \(stop) · bus 306 leaves \(Fmt.hhmm(b306.departure))", kind: "go")
        // it runs late (still your fastest)
        guard await at(25) else { return }
        let late = bus("demo-306", "306", 150 + 180, planned: 150)
        show(late)
        best = door(late, ic2); updated = Date()
        tell("Bus 306 is 3 min late", "Leaves \(Fmt.hhmm(late.departure)) instead of \(Fmt.hhmm(late.scheduledDeparture)) · still your fastest, \(dn.trainTo) \(Fmt.hhmm(ic2.arrival))", kind: "late")
        // then something faster: it switches by itself
        guard await at(42) else { return }
        let b300 = bus("demo-300", "300", 105, ride: 16 * 60), ic1 = intercity(105 + 22 * 60)
        show(b300)
        let fast = door(b300, ic1)
        best = fast; others = [door(late, ic2)] + later; updated = Date()
        tell("Faster: Bus 300 at \(Fmt.hhmm(b300.departure))", "\(dn.trainTo) \(Fmt.hhmm(fast.end)), \(Fmt.mins(ic2.arrival.timeIntervalSince(fast.end))) min sooner · leave by \(Fmt.hhmm(fast.start)) · from \(stop)", kind: "faster")
        // the bus is at your stop: it sees you get on, and the ride starts
        guard await at(106) else { return }
        seen = Vehicle(tripId: "demo-300", line: "300", isTrain: false)
        guard await at(113) else { return }
        trip?.startDemo(from: s, line: "300")
        close()
        let n = UNMutableNotificationContent()
        n.title = "You’re on the bus 300"
        n.body = "Your trip started by itself (demo)."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "goboard-demo", content: n, trigger: nil)) { _ in }
    }

    // MARK: telling you

    private func tell(_ title: String, _ body: String, kind: String = "info", sound: Bool = true) {
        notes.insert(Note(at: Date(), text: "\(title) · \(body)"), at: 0)
        if notes.count > 5 { notes.removeLast(notes.count - 5) }
        clearPosted()                                     // only the newest stays on your lock screen
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        c.threadIdentifier = "go"
        c.userInfo = ["kind": kind]
        if sound { c.sound = .default; c.interruptionLevel = .timeSensitive }
        let id = "go-\(Int(Date().timeIntervalSince1970))-\(notes.count)"
        posted.append(id)
        NoticeLog.shared.add(key: id, title: title, body: body, kind: kind)       // kept, even when a newer one replaces it
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { _ in }
    }

    /// A note on the screen only (no notification).
    private func remark(_ text: String) {
        notes.insert(Note(at: Date(), text: text), at: 0)
        if notes.count > 5 { notes.removeLast(notes.count - 5) }
    }

    /// Your choice is gone: back to the fastest, as without one, with a short note on the screen. (What it switches to
    /// is told as it always is.)
    private func dropChosen(_ why: ChosenRide.Gone) {
        guard chosen != nil else { return }
        chosen = nil; chosenMisses = 0
        remark(ChosenRide.goneNote(why))
    }

    private func clearPosted() {
        guard !posted.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: posted)
        posted = []
    }

    /// "bus 306", "Sprinter"
    static func what(_ r: Ride) -> String { r.isTrain ? (r.name.isEmpty ? "train" : r.name) : "bus \(r.line)" }
    /// "Bus 306", "Sprinter"
    static func title(_ r: Ride) -> String { r.isTrain ? (r.name.isEmpty ? "Train" : r.name) : "Bus \(r.line)" }
}

// MARK: the screen

/// One look: a big live map of you, the walk to your stop and the bus or train coming, with see-through cards over it:
/// what to take next, how to get there, and what happens after. It watches everything for you.
struct GoView: View {
    @EnvironmentObject var go: GoStore
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var live: LiveStore
    @EnvironmentObject var ns: NSStore
    @State private var walkTo: WalkTarget?
    @State private var liveTrack: LiveTrackTarget?
    @State private var showSteady = false
    @State private var choosing = false
    var home: Bool { trip.direction == .home }
    var pal: HWPalette { .of(home: home) }

    var body: some View {
        GeometryReader { g in
            let bar: CGFloat = 50                                   // the buttons along the top
            let foot: CGFloat = 62                                  // the button along the bottom
            let window = max(220, (g.size.height - bar) * 0.47)     // the map you see above the cards
            ZStack(alignment: .top) {
                GoMap(ride: go.arrived ? nil : go.best?.first, here: go.here,
                      top: g.safeAreaInsets.top + bar, bottom: g.safeAreaInsets.top + bar + window, saved: go.asOf != nil)
                    .ignoresSafeArea()
                // a little shade under the buttons, so they read on any map
                LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: g.safeAreaInsets.top + bar + 30).ignoresSafeArea(edges: .top).allowsHitTesting(false)
                // the cards scroll under the buttons at the top (and above the one at the bottom), fading out smoothly
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        Color.clear.frame(height: bar + window - 6)      // the map shows through here
                        content
                    }
                    .padding(.horizontal, 12).padding(.bottom, foot + 20)
                }
                .mask {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: bar - 16)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 40)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 34)
                        Color.clear.frame(height: foot - 10)
                    }
                }
                VStack(spacing: 0) {
                    topBar.frame(height: bar)
                    Spacer(minLength: 0)
                    bottom
                }
            }
        }
        .environment(\.colorScheme, .light)
        .sheet(item: $walkTo) { WalkMapSheet(target: $0).presentationDetents([.large]) }
        .sheet(item: $liveTrack) { LiveBusSheet(target: $0).presentationDetents([.large]) }
        .sheet(isPresented: $showSteady) { SteadySheet().presentationDetents([.large]) }
        .sheet(isPresented: $choosing) {
            DestinationSheet { d in live.go(to: d); go.retarget(d.place) }
        }
    }

    private var destWord: String { go.dest.short }
    /// Home is Veghel, unless you picked somewhere yourself.
    private var goingHome: Bool { go.dest == .home && live.custom == nil }

    // MARK: top

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.35)) { go.close() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                    Text("MAP").font(HWFont.display(13)).tracking(1.4)
                }
                .foregroundStyle(Paper.ink).padding(.horizontal, 12).padding(.vertical, 8)
                .background(Paper.paper, in: Capsule()).shadow(color: .black.opacity(0.3), radius: 5, y: 3)
            }
            .buttonStyle(.plain).accessibilityLabel("Back to the map. This stops the watching.")
            Spacer(minLength: 4)
            Menu {
                Button { to(.toSchool) } label: { Label(RoleWords.current.toSchoolMenu, systemImage: "graduationcap.fill") }
                Button { to(.home) } label: { Label(RoleWords.current.homeMenu, systemImage: "house.fill") }
                if !live.recents.isEmpty {
                    Section("Recent") {
                        ForEach(live.recents) { d in
                            Button { live.go(to: d); go.retarget(d.place) } label: { Label(d.name, systemImage: "mappin") }
                        }
                    }
                }
                Button { choosing = true } label: { Label("Somewhere else…", systemImage: "magnifyingglass") }
            } label: {
                HStack(spacing: 5) {
                    Text(goingHome ? "HOME" : "TO \(destWord.uppercased())").font(HWFont.display(13)).tracking(1.2).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: 170)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Paper.ink).padding(.horizontal, 10).padding(.vertical, 8)
                .background(Paper.paper, in: Capsule()).shadow(color: .black.opacity(0.3), radius: 5, y: 3)
            }
            .accessibilityLabel("Where you’re going: \(destWord). Tap to change.")
            HStack(spacing: 5) {
                Circle().fill(go.demo ? BoardInk.yellow : go.watching ? Paper.ok : Paper.ink.opacity(0.4)).frame(width: 7, height: 7)
                Text(go.demo ? "DEMO" : go.watching ? "WATCHING" : "STOPPED").font(BoardInk.sans(10)).tracking(1)
            }
            .foregroundStyle(Paper.ink).padding(.horizontal, 9).padding(.vertical, 8)
            .background(Paper.paper, in: Capsule()).shadow(color: .black.opacity(0.3), radius: 5, y: 3)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 12)
    }

    private func to(_ d: Direction) {
        live.go(to: nil)
        if trip.direction != d { withAnimation(.easeInOut(duration: 0.6)) { trip.pick(d) } }
        go.retarget(d == .toSchool ? .school : .home)
    }

    // MARK: what's on it

    @ViewBuilder private var content: some View {
        if go.arrived {
            message(icon: "checkmark.circle.fill", title: "You’re at \(destWord)", text: "Nothing to catch: you’re there. It stopped watching.")
        } else if let t = go.best {
            nextCard(t)
            howToGetThere(t)
            watchingCard(t)
            if !go.others.isEmpty { compareCard(t) }
        } else if go.movingUnknown {
            message(icon: "tram.fill", title: "You’re going fast",
                    text: "On a train or bus? It’s finding which one, to plan from there. In a car, it plans once you stop.", spinner: true)
        } else if go.slow {
            message(icon: "wifi.exclamationmark", title: "Slow connection",
                    text: "Still getting the trips to \(destWord). It shows them as soon as they’re in.", spinner: true)
        } else if go.lookingOnBoard {
            message(icon: "bus.fill", title: "Are you on a bus or train?",
                    text: "Checking how you’re moving. If you’re on one, it plans from there: stay on, or where to change.", spinner: true)
        } else {
            message(icon: go.error == nil ? "location.magnifyingglass" : "exclamationmark.triangle.fill",
                    title: go.error == nil ? "Finding your fastest way" : "Nothing found yet",
                    text: go.error ?? "From where you are to \(destWord): every bus and train, live.", spinner: go.error == nil)
        }
        if !go.watching && !go.arrived {
            Button { go.again() } label: {
                Label("Watch again", systemImage: "bell.badge").font(BoardInk.sans(14)).foregroundStyle(Paper.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 11).background(Paper.paper, in: RoundedRectangle(cornerRadius: 6)).shadow(color: .black.opacity(0.3), radius: 5, y: 3)
            }
            .buttonStyle(.plain)
        }
    }

    private func message(icon: String, title: String, text: String, spinner: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if spinner { ProgressView().tint(Paper.ink) } else { Image(systemName: icon).font(.system(size: 20, weight: .bold)).foregroundStyle(Paper.navy) }
                Text(title).font(BoardInk.sans(18)).foregroundStyle(Paper.ink)
            }
            Text(text).font(BoardInk.sans(13, .regular)).foregroundStyle(Paper.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glass()
    }

    /// A small heading inside a card.
    private func kicker(_ t: String, _ sub: String? = nil) -> some View {
        HStack {
            Text(t.uppercased()).font(BoardInk.sans(10.5)).tracking(1.6).foregroundStyle(Paper.ink.opacity(0.7))
            Spacer(minLength: 4)
            if let sub { Text(sub).font(BoardInk.sans(11, .semibold)).foregroundStyle(Paper.ink.opacity(0.85)) }
        }
    }

    // MARK: take next

    private func nextCard(_ t: DoorTrip) -> some View {
        let f = t.first
        let info = f.isTrain ? ns.rail(f) : nil
        let st = RideText.status(f, info, saved: go.asOf != nil)      // (the saved answer doesn't say "On time")
        _ = f.isTrain ? nil : f.grade
        let track = info?.track ?? f.platform ?? ""
        let aboard = go.onBoard?.tripId == f.tripId && f.fromId == "onboard"
        let fromLine = aboard ? "stay on until \(Fmt.place(f.toStop))" : "from \(Fmt.place(f.fromStop))" + (track.isEmpty ? "" : " · platform \(track)")
        let toName = Fmt.place(f.headsign.isEmpty ? f.toStop : f.headsign)
        let mins = Fmt.mins(t.end.timeIntervalSinceNow)
        let changes = t.rides.count > 1 ? " · \(t.rides.count - 1) change\(t.rides.count > 2 ? "s" : "")" : ""
        // (the saved answer: when it was the live one, instead of how long from now)
        let sub: String = go.asOf.map { "\(Snapshots.asOf($0)) · checking again…" } ?? "\(Fmt.rideText(Double(mins)))\(changes)"
        return VStack(alignment: .leading, spacing: 10) {
            // where it gets you, and when (and when to set off)
            PaperBand(home: trip.direction == .home) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(go.deadlineLabel.map { "For \($0)" } ?? (goingHome ? "Fastest way home" : "Fastest way to \(destWord)")).font(BoardInk.sans(10)).tracking(1.6).textCase(.uppercase).opacity(0.85)
                        Text("\(destWord) at \(Fmt.hhmm(t.end))").font(HWFont.display(26)).lineLimit(1).minimumScaleFactor(0.6)
                        Text(sub).font(BoardInk.sans(11, .medium)).opacity(0.85)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(aboard ? "you’re" : "leave by").font(BoardInk.sans(10.5)).opacity(0.8)
                        Text(aboard ? "on it" : Fmt.hhmm(t.start)).font(HWFont.display(26)).foregroundStyle(Paper.yellow).monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, -14).padding(.top, -14)
            kicker(aboard ? "You’re on" : "Take next")
            HStack(alignment: .center, spacing: 12) {
                LineBullet(line: f.line, train: f.isTrain, at: f.departure, height: 44, minWidth: 62, font: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(GoStore.title(f)).font(BoardInk.sans(17)).foregroundStyle(Paper.ink).lineLimit(1)
                    Text("to \(toName)").font(BoardInk.sans(13, .regular)).foregroundStyle(Paper.ink.opacity(0.9)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(fromLine).font(BoardInk.sans(11.5, .regular)).foregroundStyle(Paper.muted).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)
                if aboard {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("off at").font(BoardInk.sans(11)).foregroundStyle(Paper.muted)
                        Text(Fmt.hhmm(f.arrival)).font(HWFont.display(28)).foregroundStyle(Paper.ink).monospacedDigit()
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.hhmm(f.cancelled ? f.scheduledDeparture : f.departure)).font(HWFont.display(28)).foregroundStyle(Paper.ink).monospacedDigit()
                        if go.asOf == nil {             // (no countdown from the saved answer)
                            TimelineView(.periodic(from: .now, by: 15)) { _ in
                                let m = Int((f.departure.timeIntervalSinceNow / 60).rounded(.down))
                                Text(m <= 0 ? "now" : "in \(m) min").font(BoardInk.sans(12)).foregroundStyle(m <= 2 ? Paper.late : Paper.muted)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                if aboard {
                    ProgressView().controlSize(.mini).tint(Paper.navy)
                    Text("Making sure it’s this one: then your trip starts by itself.").font(BoardInk.sans(12)).foregroundStyle(Paper.ink.opacity(0.85)).lineLimit(2)
                } else {
                    Circle().fill(st.warn ? Paper.late : st.ok ? Paper.ok : Paper.ink.opacity(0.6)).frame(width: 7, height: 7)
                    Text(st.text).font(BoardInk.sans(12)).foregroundStyle(st.warn ? Paper.late : st.ok ? Paper.ok : Paper.ink.opacity(0.85)).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button { liveTrack = LiveTrackTarget(tripId: f.tripId, line: f.line, headsign: f.headsign.isEmpty ? Fmt.place(f.toStop) : f.headsign,
                                                     stopName: f.fromStop, time: f.departure, rail: f.isTrain) } label: {
                    Label("Its whole route", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(BoardInk.sans(11)).foregroundStyle(Paper.navy)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Paper.navy.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if let h = go.hurry {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "figure.run").font(.system(size: 15, weight: .semibold)).foregroundStyle(Paper.late)
                    Text("Hurry: \(h.meters) m to the stop and it leaves in \(h.minutes) min. A brisk walk makes it."
                         + (go.others.first.map { " If not: \(GoStore.what($0.first)) at \(Fmt.hhmm($0.first.departure)), \(destWord) \(Fmt.hhmm($0.end))." } ?? ""))
                        .font(BoardInk.sans(12, .medium)).foregroundStyle(Paper.ink).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Paper.late.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
            if go.overdue {
                let alt = go.others.first
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Paper.late)
                    Text("Due at \(Fmt.hhmm(f.departure)) and not seen leaving: it may be running late. Wait for this \(GoStore.what(f))"
                         + (alt.map { ", or take \(GoStore.what($0.first)) at \(Fmt.hhmm($0.first.departure)) (\(destWord) \(Fmt.hhmm($0.end)))." } ?? "."))
                        .font(BoardInk.sans(12, .medium)).foregroundStyle(Paper.ink).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Paper.late.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
            changeNote(t)
            Rectangle().fill(Paper.rule).frame(height: 1)
            kicker("Your trip")
            TripLine(trip: t, others: go.others, dest: destWord) { r in
                liveTrack = LiveTrackTarget(tripId: r.tripId, line: r.line, headsign: r.headsign.isEmpty ? Fmt.place(r.toStop) : r.headsign,
                                            stopName: r.fromStop, time: r.departure, rail: r.isTrain)
            }
        }
        .padding(14)
        .glass()
    }

    /// A change you could well miss (with what it's been like, and a safer way if there is one), or why it picked one
    /// that leaves a bit earlier: a change you'll make.
    @ViewBuilder private func changeNote(_ t: DoorTrip) -> some View {
        if let w = Risk.weakest(t) {
            let a = t.rides[w.index - 1], n = t.rides[w.index]
            let story = DelayBook.shared.story(line: a.line, stop: a.toStop, at: a.scheduledArrival, slack: w.slack)
            let safer = go.others.filter { Risk.penalty($0) < Risk.penalty(t) - 2 }.min { $0.end < $1.end }
            // a slow bus (its speed rank B or C) wants more room: say so first
            let slow = Risk.feederGrade(a).flatMap { g in ChangeRoom.extra(afterGrade: g) > 0 ? g : nil }
            let why = slow.map { "this \(a.line) is \($0)-rank, slow on this stretch, so a change after it wants \(Int(ChangeRoom.needed(afterGrade: $0))) min" }
                ?? story.map { "the \(a.line) here was \($0)" } ?? (a.isTrain ? "trains are sometimes a few minutes late" : "buses are often a few minutes late")
            let then = safer.map { o in
                let same = Int(o.end.timeIntervalSince1970 / 60) == Int(t.end.timeIntervalSince1970 / 60)
                return " Safer: \(GoStore.what(o.first)) at \(Fmt.hhmm(o.first.departure))" + (same ? ", there at the same time." : ", there \(Fmt.hhmm(o.end)).")
            } ?? ""
            note(icon: "exclamationmark.triangle.fill", color: Paper.late,
                 "Tight change at \(Fmt.place(n.fromStop)): \(max(0, Int(w.slack.rounded()))) min from the \(GoStore.what(a)) to the \(GoStore.what(n)), and \(why).\(then)")
        } else if let quick = go.others.filter({ $0.end < t.end && Risk.penalty($0) > Risk.penalty(t) + 2 }).min(by: { $0.end < $1.end }),
                  let w = Risk.weakest(quick) {
            let at = Fmt.place(quick.rides[w.index].fromStop)
            let mine = t.rides.indices.dropFirst().first { Fmt.place(t.rides[$0].fromStop) == at }
            let room = mine.map { i in max(0, Int((t.rides[i].departure.timeIntervalSince(t.rides[i - 1].arrival) / 60 - Double(t.rides[i].walkBefore)).rounded())) }
            note(icon: "checkmark.shield.fill", color: Paper.ok,
                 "A safe change: \(room.map { "\($0) min" } ?? "time") at \(at), not \(max(0, Int(w.slack.rounded()))) min with the \(GoStore.what(quick.first)) at \(Fmt.hhmm(quick.first.departure)) (there \(Fmt.hhmm(quick.end)) if it all goes right).")
        }
    }

    private func note(icon: String, color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            Text(text).font(BoardInk.sans(12, .medium)).foregroundStyle(Paper.ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: how to get there

    @ViewBuilder private func howToGetThere(_ t: DoorTrip) -> some View {
        let f = t.first
        if f.fromId == "onboard" {
            EmptyView()                        // you're on it: nothing to walk to
        } else if let a = f.fromLat, let o = f.fromLon {
            // (from the saved answer: just the way there, without "Leave by … (in 5 min)")
            let saved = go.asOf != nil
            let target = WalkTarget(name: Fmt.place(f.fromStop), lat: a, lon: o, rail: f.isTrain,
                                    catchText: saved ? nil : "the \(GoStore.what(f)) at \(Fmt.hhmm(f.departure))", leaves: saved ? nil : f.departure)
            let away = go.here.map { $0.distance(from: CLLocation(latitude: a, longitude: o)) } ?? 9999
            if f.walkBefore == 0 && away < 120 {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 18, weight: .bold)).foregroundStyle(Paper.navy)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You’re at the stop").font(BoardInk.sans(15)).foregroundStyle(Paper.ink)
                        Text("Wait here for the \(GoStore.what(f)): you can see it coming on the map. It notices by itself when you get on.")
                            .font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14).glass()
            } else {
                HStack(alignment: .center, spacing: 12) {
                    if saved {
                        Image(systemName: "figure.walk").font(.system(size: 20, weight: .bold)).foregroundStyle(Paper.ink)
                            .frame(width: 62, height: 62).overlay(Circle().stroke(Paper.ink.opacity(0.18), lineWidth: 6))
                    } else {
                        TimelineView(.periodic(from: .now, by: 10)) { _ in leaveRing(t) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.walkBefore > 0 ? "\(f.walkBefore) min walk to \(Fmt.place(f.fromStop))" : "Get to \(Fmt.place(f.fromStop))")
                            .font(BoardInk.sans(15)).foregroundStyle(Paper.ink).lineLimit(2).minimumScaleFactor(0.8)
                        Text(saved ? "Leave by \(Fmt.hhmm(t.start))" : leaveText(t)).font(BoardInk.sans(12))
                            .foregroundStyle(saved ? Paper.ink.opacity(0.85) : t.start <= Date().addingTimeInterval(60) ? Paper.late : Paper.ok)
                        Text("Follow the dotted line on the map.").font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                    Button { walkTo = target } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill").font(.system(size: 18, weight: .semibold))
                            Text("Turns").font(BoardInk.sans(10))
                        }
                        .foregroundStyle(Paper.ink).frame(width: 54, height: 54).background(Paper.ink.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain).accessibilityLabel("The walk, turn by turn")
                }
                .padding(14).glass()
            }
        }
    }

    private func leaveText(_ t: DoorTrip) -> String {
        let m = Int((t.start.timeIntervalSinceNow / 60).rounded(.down))
        return m <= 0 ? "Leave now" : "Leave by \(Fmt.hhmm(t.start)), in \(m) min"
    }

    /// The minutes until you have to set off, round a ring that closes as it gets nearer (the last 15 minutes).
    private func leaveRing(_ t: DoorTrip) -> some View {
        let s = t.start.timeIntervalSinceNow
        let m = max(0, Int((s / 60).rounded(.down)))
        let fill = 1 - min(1, max(0, s / (15 * 60)))
        return ZStack {
            Circle().stroke(Paper.ink.opacity(0.18), lineWidth: 6)
            Circle().trim(from: 0, to: fill).stroke(s <= 60 ? Paper.late : Paper.ok, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                if s <= 60 {
                    Image(systemName: "figure.walk").font(.system(size: 20, weight: .bold)).foregroundStyle(Paper.ink)
                    Text("GO").font(BoardInk.sans(10)).foregroundStyle(Paper.ink)
                } else {
                    Text("\(m)").font(HWFont.display(24)).foregroundStyle(Paper.ink).monospacedDigit()
                    Text("MIN").font(BoardInk.sans(9)).foregroundStyle(Paper.ink.opacity(0.8))
                }
            }
        }
        .frame(width: 62, height: 62)
        .animation(.easeInOut(duration: 0.6), value: fill)
        .accessibilityLabel(s <= 60 ? "Leave now" : "Leave in \(m) minutes")
    }

    // MARK: then

    private func thenCard(_ t: DoorTrip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            kicker("Then", "\(destWord) \(Fmt.hhmm(t.end))")
            ForEach(Array(t.rides.enumerated()).dropFirst(), id: \.offset) { i, ride in
                let prev = t.rides[i - 1]
                let ch = Fmt.mins(ride.departure.timeIntervalSince(prev.arrival))
                let note = Risk.changeNote(after: prev, minutes: ch, walk: ride.walkBefore)     // (after a slow bus: why it's red)
                let why = note.why.map { " · \($0)" } ?? ""
                Label("\(ch) min to change at \(Fmt.place(prev.toStop))\(ride.walkBefore > 0 ? ", \(ride.walkBefore) min walk" : "")\(why)", systemImage: "arrow.triangle.swap")
                    .font(BoardInk.sans(10.5, .semibold)).foregroundStyle(note.red ? Paper.lateInk : Paper.ink.opacity(0.8))
                    .padding(.top, 4)
                PlannerRideRow(ride: ride, info: ns.rail(ride), picked: false, saved: go.asOf != nil) {
                    liveTrack = LiveTrackTarget(tripId: ride.tripId, line: ride.line, headsign: ride.headsign.isEmpty ? Fmt.place(ride.toStop) : ride.headsign,
                                                stopName: ride.fromStop, time: ride.departure, rail: ride.isTrain)
                }
            }
            if t.walkAfter > 0 {
                Label("\(t.walkAfter) min walk to \(destWord)", systemImage: "figure.walk").font(BoardInk.sans(11, .semibold)).foregroundStyle(Paper.ink.opacity(0.8))
            }
        }
        .padding(14)
        .glass()
    }

    // MARK: it watches for you

    private func watchingCard(_ t: DoorTrip) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            // (the saved answer isn't watched: nothing is told about it until the live one is in)
            let checking = go.watching && go.asOf != nil
            HStack(spacing: 8) {
                Image(systemName: checking ? "arrow.triangle.2.circlepath" : go.watching ? "bell.and.waves.left.and.right.fill" : "bell.slash.fill")
                    .foregroundStyle(checking ? Paper.navy : go.watching ? Paper.late : Paper.ink.opacity(0.6))
                    .symbolEffect(.pulse, isActive: go.watching)
                Text(checking ? "Checking for live times…" : go.watching ? "Watching the \(GoStore.what(t.first)) for you" : "Not watching any more")
                    .font(BoardInk.sans(14)).foregroundStyle(Paper.ink)
            }
            if let v = go.seen {
                Label("Looks like you’re on the \(v.title)… checking.", systemImage: v.isTrain ? "tram.fill" : "bus.fill")
                    .font(BoardInk.sans(12)).foregroundStyle(Paper.ok)
            }
            if go.watching && !checking {
                Text("You get a notification if it runs late or leaves early, or if something faster comes up: then it watches that one instead. Once you’re on board, your trip starts by itself.")
                    .font(BoardInk.sans(11.5, .regular)).foregroundStyle(Paper.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(go.notes) { n in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.hhmm(n.at)).font(BoardInk.sans(11)).foregroundStyle(Paper.navy).monospacedDigit()
                    Text(n.text).font(BoardInk.sans(11.5, .regular)).foregroundStyle(Paper.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let a = go.asOf {
                Text("\(Snapshots.asOf(a)) · checking again…").font(BoardInk.sans(10, .regular)).foregroundStyle(Paper.ink.opacity(0.6))
            } else if let u = go.updated {
                Text("Checked at \(Fmt.hhmm(u)). It stops when you leave this screen.").font(BoardInk.sans(10, .regular)).foregroundStyle(Paper.ink.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glass()
    }

    /// The other ways side by side with the fastest: when you'd leave, how long it takes door to door, when you're there,
    /// and how much later than the fastest.
    private func compareCard(_ best: DoorTrip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                kicker("Compare", go.asOf.map { Snapshots.asOf($0) } ?? "if you take another one")
                Spacer(minLength: 4)
                Button { showSteady = true } label: {
                    Label("How steady now", systemImage: "gauge.with.dots.needle.33percent").font(BoardInk.sans(11)).foregroundStyle(Paper.navy)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Paper.navy.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)
            HStack {
                Text("LEAVE").frame(width: 50, alignment: .leading)
                Text("TAKE")
                Spacer(minLength: 4)
                Text("TRIP").frame(width: 64, alignment: .trailing)
                Text("THERE").frame(width: 62, alignment: .trailing)
            }
            .font(BoardInk.sans(9)).tracking(1).foregroundStyle(Paper.ink.opacity(0.55)).padding(.bottom, 2)
            compareRow(best, best)
            ForEach(go.others) { o in compareRow(o, best) }
        }
        .padding(14)
        .glass()
    }

    private func compareRow(_ o: DoorTrip, _ best: DoorTrip) -> some View {
        let fastest = o.id == best.id
        let later = Fmt.mins(o.end.timeIntervalSince(best.end))
        let changes = o.rides.count - 1
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Fmt.hhmm(o.start)).font(BoardInk.sans(14)).foregroundStyle(Paper.ink).monospacedDigit().frame(width: 50, alignment: .leading)
                HStack(spacing: 3) {
                    ForEach(Array(o.rides.enumerated()), id: \.offset) { _, r in
                        LineBullet(line: r.line, train: r.isTrain, height: 18, minWidth: 26, font: 10.5)
                    }
                }
                Spacer(minLength: 4)
                Text(Fmt.rideText(o.end.timeIntervalSince(o.start) / 60)).font(BoardInk.sans(12, .semibold)).foregroundStyle(Paper.ink.opacity(0.9))
                    .lineLimit(1).minimumScaleFactor(0.7).frame(width: 64, alignment: .trailing)
                Text(Fmt.hhmm(o.end)).font(BoardInk.sans(14)).foregroundStyle(Paper.ink).monospacedDigit().frame(width: 62, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Text("\(GoStore.what(o.first)) \(Fmt.hhmm(o.first.departure)) from \(Fmt.place(o.first.fromStop))\(changes > 0 ? " · \(changes) change\(changes > 1 ? "s" : "")" : "")")
                    .font(BoardInk.sans(10.5, .regular)).foregroundStyle(Paper.ink.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.7)
                if let w = Risk.weakest(o) {
                    Text("tight: \(max(0, Int(w.slack.rounded()))) min").font(BoardInk.sans(10.5)).foregroundStyle(Paper.late).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 4)
                Text(fastest ? "fastest" : later == 0 ? "same time" : "+\(later) min")
                    .font(BoardInk.sans(11)).foregroundStyle(!fastest && later == 0 ? Paper.ink : .white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(fastest ? Paper.ok : later == 0 ? Paper.ink.opacity(0.2) : Paper.late, in: Capsule())
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.ink.opacity(0.12)).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    // MARK: bottom

    @ViewBuilder private var bottom: some View {
        if go.arrived || go.best == nil {
            BandButton(title: "Back to the map", pal: pal) { withAnimation(.easeInOut(duration: 0.35)) { go.close() } }
                .padding(.horizontal, 12).padding(.bottom, 6)
        } else if let t = go.best, RoutePlan.from(t) != nil {
            Button { go.startByHand(t) } label: {
                HStack(spacing: 8) {
                    Image(systemName: t.first.isTrain ? "tram.fill" : "bus.fill")
                    Text("I’M ON IT · START NOW").font(HWFont.display(14)).tracking(0.8)
                }
                .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Paper.green.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Paper.ink.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.bottom, 6)
            .accessibilityHint("Only if it hasn’t noticed by itself that you’re on board.")
        }
    }
}

extension View {
    /// A card on the Go screen: paper over the map, with its edge and a shadow.
    func glass(_ radius: CGFloat = 4) -> some View {
        background(PaperFill().clipShape(RoundedRectangle(cornerRadius: radius)))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Paper.edge, lineWidth: 1))
            .compositingGroup()
            .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
    }
}

// MARK: the map behind it

/// The big map behind the Go screen: you, the walk to your stop (dotted), the stop, and the bus or train on its way to it,
/// moving every second. It keeps all of that in view by itself, in the part of the screen above the cards, so you can just
/// follow it.
struct GoMap: View {
    let ride: Ride?
    let here: CLLocation?
    let top: CGFloat            // the screen's top part that the buttons cover
    let bottom: CGFloat         // where the cards start
    var saved = false           // the ride is from the saved answer: its pin without the time
    var newLook = false         // the new look (0.20): the plain map in the phone's light or dark, the new colours
    /// The Go to card's On the map (0.20.4): each new value stops keeping you in view by itself and shows the stop and
    /// your walk to it.
    var focus = 0
    /// The walk to the stop's length on foot (nil: none, you're there), each time it's found again.
    var onWalk: ((Double?) -> Void)? = nil
    /// 0.24.5: the time its GPS says it can be at your stop at the soonest, while that's clearly later than the ride's
    /// own (`Approach.Steady`; show the later of the two); nil: the ride's own. Each time it changes, with the ride's
    /// trip id.
    var onLater: ((String, Date?) -> Void)? = nil
    @State private var trip: LiveTrip?
    @State private var mine: Int?
    @State private var walk: MKRoute?
    @State private var walkFrom: CLLocation?
    @State private var hereNow: CLLocation?
    @State private var camera: MapCameraPosition = .automatic
    @State private var size: CGSize = .zero
    @State private var tick = 0
    /// The new look (0.20.1): the map moves by hand too. `auto`: it keeps you and your way in view by itself (the
    /// button filled); a pan or zoom by hand makes it free (outline) until the button is tapped again.
    @State private var auto = true
    @State private var lastFit: Date?
    @State private var hold = GPSHold()     // real positions (0.20.2)
    @State private var later = Approach.Steady()    // its GPS's soonest time at your stop (0.24.5)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            Map(position: $camera, interactionModes: newLook ? .all : []) { content(tl.date) }
                .mapStyle(newLook ? .standard(pointsOfInterest: .excludingAll) : .standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                .onMapCameraChange(frequency: .onEnd) { _ in
                    // a move that isn't its own fit settling is a hand's
                    if newLook, auto, MapFollow.handMovedSinceFit(lastFit: lastFit, now: Date()) { auto = false }
                }
                .accessibilityHidden(true)
        }
        .overlay(alignment: .topTrailing) {
            if newLook {
                Button {
                    auto.toggle()
                    if auto { fit(Date(), animated: true) } else { lastFit = nil }
                } label: {
                    Image(systemName: auto ? "location.fill" : "location")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(auto ? DS.accentText : DS.secondary)
                        .frame(width: 48, height: 48)
                        .background(DS.surface, in: Circle())
                        .dsFloat()
                }
                .buttonStyle(DSPressStyle())
                .padding(.trailing, DS.edge)
                .padding(.top, max(top + 8, bottom - 70))
                .accessibilityLabel(auto ? "Keeping you and your way in view" : "Show me and my way")
                .accessibilityHint(auto ? "Tap to stop, so you can move the map" : "Tap to keep you and your way in view")
                .accessibilityAddTraits(auto ? .isSelected : [])
            }
        }
        // a wash of the map's paper over it, and its wear (not in the new look)
        .overlay {
            if !newLook {
                ZStack {
                    Color(hex: 0xEADCBB).opacity(0.22)
                    if let g = Paper.grime { Image(uiImage: g).resizable().opacity(0.3) }
                }
                .allowsHitTesting(false)
            }
        }
        .background { GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s } } }
        .onAppear { hereNow = here }
        .onChange(of: here?.timestamp) { _, _ in hereNow = here }
        // (the new look: only while it keeps you in view by itself, never under a hand moving the map)
        .onChange(of: tick) { _, t in if (!newLook || auto) && (t <= 2 || t % 4 == 0) { fit(Date(), animated: t > 2) } }
        .onChange(of: size) { _, _ in if !newLook || auto { fit(Date(), animated: false) } }
        .onChange(of: camera) { _, c in if newLook && auto && c.positionedByUser { auto = false } }
        .onChange(of: focus) { _, _ in
            guard newLook else { return }
            auto = false
            fit(Date(), animated: true, toStop: true)
            lastFit = nil
        }
        .realPositions(ride.map { RealPositions.key($0.tripId) != nil } ?? false, trains: ride?.isTrain ?? false)
        .task(id: ride?.tripId ?? "") { await run() }
    }

    private var stop: CLLocationCoordinate2D? {
        guard let r = ride, let a = r.fromLat, let o = r.fromLon else { return nil }
        return .init(latitude: a, longitude: o)
    }

    /// A line's colour: its own (the old look), or its mode's (the new look).
    private func lineColor(_ r: Ride) -> Color { newLook ? DS.mode(train: r.isTrain, line: r.line) : Paper.line(r.line, train: r.isTrain) }

    @MapContentBuilder private func content(_ now: Date) -> some MapContent {
        UserAnnotation()
        if let walk {
            MapPolyline(walk.polyline).stroke(newLook ? DS.accent : Paper.ink, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: [0.5, 10]))
        }
        if let t = trip, let m = mine, let r = ride {
            let w = TripPlacement(t, tripId: r.tripId, now: now, hold: hold, mine: m).w      // by its GPS, else its times
            let me = t.metres(ofStop: m)
            // not past your stop before it has left there (two minutes after its time): a late one may still be coming
            let at = LiveTimes.shown(w.metres, mine: me, left: LiveTimes.hasLeft(t.stops[m].times, now: now))
            // the road it still has to take to you, and on from there (fainter)
            let rest = t.road(from: me, to: t.metres(ofStop: t.stops.count - 1))
            if rest.count > 1 {
                MapPolyline(coordinates: rest)
                    .stroke(lineColor(r).opacity(0.35), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if at < me - 5 {
                MapPolyline(coordinates: t.road(from: at, to: me))
                    .stroke(lineColor(r), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if !w.done && at <= me + 30 {
                Annotation("", coordinate: t.coordinate(atMetres: at), anchor: .center) {
                    HStack(spacing: 4) {
                        Image(systemName: r.isTrain ? "tram.fill" : "bus.fill").font(.system(size: 12, weight: .bold))
                        Text(r.line).font(newLook ? DS.footnoteStrong : BoardInk.sans(13))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(lineColor(r), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                }
            }
        }
        if let s = stop, let r = ride {
            Annotation("", coordinate: s, anchor: .bottom) {
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: r.isTrain ? "tram.fill" : "bus.fill").font(.system(size: 11, weight: .bold))
                        Text(saved ? r.line : "\(r.line) · \(Fmt.hhmm(r.departure))").font(newLook ? DS.footnoteStrong : BoardInk.sans(12)).monospacedDigit()
                    }
                    .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(newLook ? DS.mode(train: r.isTrain, line: r.line) : Paper.navy, in: RoundedRectangle(cornerRadius: newLook ? DS.pillRadius : 4))
                    Image(systemName: "triangle.fill").font(.system(size: 9)).foregroundStyle(newLook ? DS.mode(train: r.isTrain, line: r.line) : Paper.navy).rotationEffect(.degrees(180)).offset(y: -2)
                    Circle().fill(Color.white).frame(width: 14, height: 14).overlay(Circle().stroke(newLook ? DS.mode(train: r.isTrain, line: r.line) : Paper.ink, lineWidth: 3.5))
                }
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            }
        }
    }

    /// Its live times every 30 seconds; the walk again every minute (or when you've moved).
    private func run() async {
        trip = nil; mine = nil; walk = nil; walkFrom = nil
        onWalk?(nil)
        later = Approach.Steady(); onLater?(ride?.tripId ?? "", nil)
        var lastTrip = Date.distantPast
        while !Task.isCancelled {
            // (not in front: no live times, no walking route, nothing to draw: 0.20.7)
            if UIApplication.shared.applicationState != .active {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            let now = Date()
            if let r = ride, now.timeIntervalSince(lastTrip) >= 30 {
                lastTrip = now
                if let t = await Transit.liveTrip(r.tripId), !Task.isCancelled {
                    trip = t.noCatchUp(asOf: Date(), isTrain: r.isTrain)        // a late bus without catching up
                    if mine == nil { mine = Self.findMine(t, r) }
                }
            }
            if let r = ride, let t = trip { noteGPS(t, r, now); noteLater(t, r, now) }
            if let s = stop, let h = hereNow, walkFrom.map({ h.distance(from: $0) > 40 || now.timeIntervalSince($0.timestamp) > 60 }) ?? true {
                walkFrom = h
                let d = h.distance(from: CLLocation(latitude: s.latitude, longitude: s.longitude))
                if d > 60 { walk = await Self.walkRoute(to: s) } else { walk = nil }
                onWalk?(walk?.distance)
            }
            tick += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// The field log: how far its GPS put the bus you're catching from where its times have it (once per fix).
    private func noteGPS(_ t: LiveTrip, _ r: Ride, _ now: Date) {
        let p = TripPlacement(t, tripId: r.tripId, now: now, hold: hold, mine: mine)
        guard let f = p.fix, !p.w.done else { return }
        RealPositionsStore.shared.noteUsed(f, tripId: r.tripId, line: r.line, isTrain: r.isTrain, timeMetres: p.timeMetres,
                                           gpsMetres: p.w.metres, now: now)
    }

    /// Its GPS against the ride's time (0.24.5): the later one it can be at your stop by, told when it changes.
    private func noteLater(_ t: LiveTrip, _ r: Ride, _ now: Date) {
        let before = later.shown
        var estimate: Date?, age: TimeInterval?
        if let m = mine, !r.isTrain, let f = RealPositionsStore.shared.fix(for: r.tripId, now: now) {
            estimate = t.gpsArrival(f, atStop: m, now: now)
            age = now.timeIntervalSince(f.at)
        }
        _ = later.update(given: r.departure, estimate: estimate, fixAge: age)
        if later.shown != before { onLater?(r.tripId, later.shown) }
    }

    private static func walkRoute(to s: CLLocationCoordinate2D) async -> MKRoute? {
        let req = MKDirections.Request()
        req.source = MKMapItem.forCurrentLocation()
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: s))
        req.transportType = .walking
        BatteryLog.shared.request(.directions, body: 0)             // (MapKit's own: its bytes aren't known)
        return try? await MKDirections(request: req).calculate().routes.first
    }

    /// Your stop on its route: the one nearest where you get on, at about the time you catch it.
    private static func findMine(_ t: LiveTrip, _ r: Ride) -> Int? {
        let c = CLLocation(latitude: r.fromLat ?? 0, longitude: r.fromLon ?? 0)
        let near = t.stops.indices.filter { CLLocation(latitude: t.stops[$0].coordinate.latitude, longitude: t.stops[$0].coordinate.longitude).distance(from: c) < 250 }
        let pool = near.isEmpty ? t.stops.indices.filter { Fmt.place(t.stops[$0].name) == Fmt.place(r.fromStop) } : near
        return pool.min { abs((t.departure($0) ?? .distantPast).timeIntervalSince(r.departure)) < abs((t.departure($1) ?? .distantPast).timeIntervalSince(r.departure)) }
    }

    /// Keep you, your stop and the bus (when it's on its way, not too far) in the window above the cards. `toStop`
    /// (On the map): you, the stop and the walk between, without the bus.
    private func fit(_ now: Date, animated: Bool, toStop: Bool = false) {
        guard size.width > 0, size.height > 0 else { return }
        var pts: [CLLocationCoordinate2D] = []
        if let h = hereNow { pts.append(h.coordinate) }
        if let s = stop {
            pts.append(s)
            if !toStop, let t = trip, let m = mine, let r = ride {
                let w = TripPlacement(t, tripId: r.tripId, now: now, hold: hold, mine: m).w
                let at = LiveTimes.shown(w.metres, mine: t.metres(ofStop: m), left: LiveTimes.hasLeft(t.stops[m].times, now: now))
                let bus = t.coordinate(atMetres: at)
                let far = CLLocation(latitude: bus.latitude, longitude: bus.longitude).distance(from: CLLocation(latitude: s.latitude, longitude: s.longitude))
                if !w.done && at <= t.metres(ofStop: m) + 30 && far < 6000 { pts.append(bus) }
            }
        }
        guard let p0 = pts.first else { return }
        var box = MKMapRect(origin: MKMapPoint(p0), size: MKMapSize(width: 1, height: 1))
        for p in pts.dropFirst() { box = box.union(MKMapRect(origin: MKMapPoint(p), size: MKMapSize(width: 1, height: 1))) }
        if toStop, let walk { box = box.union(walk.polyline.boundingMapRect) }
        let ppm = MKMapPointsPerMeterAtLatitude(p0.latitude)
        var w = max(box.size.width * 1.35, ppm * 420), h = max(box.size.height * 1.35, ppm * 420)
        let winH = max(120, bottom - top)
        let aspect = size.width / winH
        if w / h > aspect { h = w / aspect } else { w = h * aspect }
        let scale = h / winH                                       // map points per screen point
        let rect = MKMapRect(x: box.midX - w / 2, y: box.midY - h / 2 - top * scale, width: w, height: size.height * scale)
        lastFit = Date()
        if animated { withAnimation(.easeInOut(duration: 1.2)) { camera = .rect(rect) } } else { camera = .rect(rect) }
    }
}

// MARK: the trip as a metro line

/// Your trip drawn as a metro line, top to bottom: you, the walk (dotted), each ride in its line's colour with its bullet,
/// a white station at every stop where you get on or change, and your destination in yellow. Another bus or train that
/// leaves at another time but still gets you onto the same train after it branches off beside the line and joins it there.
struct TripLine: View {
    let trip: DoorTrip
    let others: [DoorTrip]
    let dest: String
    var newLook = false         // the new look (0.20): its colours, pills and text styles
    /// NS's word on its trains (their platform now) by ride id, for the new look's platform chips.
    var rails: [String: RailInfo] = [:]
    var tap: (Ride) -> Void = { _ in }

    private var ink: Color { newLook ? DS.text : Paper.ink }
    private var muted: Color { newLook ? DS.secondary : Paper.muted }
    private func color(_ r: Ride) -> Color { newLook ? DS.mode(train: r.isTrain, line: r.line) : Paper.line(r.line, train: r.isTrain) }

    private struct Stop { let name: String; let time: Date; let sub: String; var end = false; var chip: String? = nil; var changed = false }
    private struct Seg { let ride: Ride?; let height: CGFloat; var label: String? = nil }
    private struct Branch { let from: Int; let to: Int; let color: Color; let label: String }

    private let lineX: CGFloat = 34, stopH: CGFloat = 46

    /// The stations and the pieces of line between them (seg i joins stop i and stop i + 1).
    private var layout: (stops: [Stop], segs: [Seg], boardAt: [String: Int]) {
        var stops: [Stop] = [], segs: [Seg] = [], boardAt: [String: Int] = [:]
        let f = trip.first
        if f.walkBefore > 0 {
            stops.append(Stop(name: "You", time: trip.start, sub: "leave by · \(f.walkBefore) min walk"))
            segs.append(Seg(ride: nil, height: 26))
        }
        for (i, r) in trip.rides.enumerated() {
            let what = r.isTrain ? (r.name.isEmpty ? "Train" : r.name) : "Bus \(r.line)"
            let plat = (r.platform ?? "").isEmpty ? "" : " · platform \(r.platform!)"
            var sub = "\(what)\(plat)"
            if i > 0 {
                let p = trip.rides[i - 1]
                let ch = Fmt.mins(r.departure.timeIntervalSince(p.arrival))
                sub = "arrive \(Fmt.hhmm(p.arrival)) · \(ch) min to change\(r.walkBefore > 0 ? ", \(r.walkBefore) min walk" : "") · \(what)\(plat)"
            }
            boardAt[r.tripId] = stops.count
            if newLook {
                // (0.20.4) where you get on as a chip by the stop ("Platform 5", "Stop U"), which one on the ride's row
                // ("Bus 5 to BUas"): not in the line under the stop
                let kind = StopLabel.kind(isTrain: r.isTrain, line: r.line)
                let info = r.isTrain ? rails[r.id] : nil
                let w = StopLabel.make(kind: kind, stop: r.fromStop, track: StopLabel.clean(info?.track) ?? r.platform,
                                       planned: StopLabel.clean(info?.plannedTrack) ?? r.plannedPlatform)
                let ride = StopLabel.ride(StopLabel.vehicle(kind: kind, line: r.line, name: r.name),
                                          toward: Fmt.place(r.headsign.isEmpty ? r.toStop : r.headsign))
                var under = "get on here"
                if i > 0 {
                    let p = trip.rides[i - 1]
                    let ch = Fmt.mins(r.departure.timeIntervalSince(p.arrival))
                    under = "arrive \(Fmt.hhmm(p.arrival)) · \(ch) min to change\(r.walkBefore > 0 ? ", \(r.walkBefore) min walk" : "")"
                }
                stops.append(Stop(name: Fmt.place(r.fromStop), time: r.departure, sub: under, chip: w.chip, changed: w.changed))
                segs.append(Seg(ride: r, height: 62, label: ride))
                continue
            }
            stops.append(Stop(name: Fmt.place(r.fromStop), time: r.departure, sub: sub))
            segs.append(Seg(ride: r, height: 62))
        }
        if trip.walkAfter > 0 {
            stops.append(Stop(name: Fmt.place(trip.last.toStop), time: trip.last.arrival, sub: "then \(trip.walkAfter) min walk"))
            segs.append(Seg(ride: nil, height: 24))
        }
        stops.append(Stop(name: dest, time: trip.end, sub: "you’re there", end: true))
        return (stops, segs, boardAt)
    }

    /// "Eindhoven 15:46, then Breda 16:27"; the new look with where you get on and which one: "Eindhoven 15:46, Platform
    /// 5, Intercity to Den Haag Centraal, then …".
    private func spoken(_ stops: [Stop], _ segs: [Seg]) -> String {
        var out: [String] = []
        for (i, s) in stops.enumerated() {
            var parts: [String] = ["\(s.name) \(Fmt.hhmm(s.time))"]
            if newLook {
                if let c = s.chip { parts.append(c) }
                if i < segs.count, let r = segs[i].label { parts.append(r) }
            }
            out.append(parts.joined(separator: ", "))
        }
        return out.joined(separator: ", then ")
    }

    /// Other ways that join this trip on one of its later rides: they branch off at the top and join at that station.
    private func branches(_ boardAt: [String: Int], last: Int) -> [Branch] {
        var out: [Branch] = []
        func name(_ r: Ride) -> String { r.isTrain ? (r.name.isEmpty ? "train" : r.name) : "bus \(r.line)" }
        for o in others {
            // where it parts from your trip (the first stop, or a change), and where it joins it again: a later ride you
            // both take, or the end at the same time
            guard let d = o.rides.indices.first(where: { $0 >= trip.rides.count || o.rides[$0].tripId != trip.rides[$0].tripId }),
                  d < trip.rides.count else { continue }
            let from = d == 0 ? 0 : (boardAt[trip.rides[d].tripId] ?? -1)
            guard from >= 0 else { continue }
            var k = o.rides.count
            var join: Int?
            if let j = o.rides.indices.dropFirst(d + 1).first(where: { (boardAt[o.rides[$0].tripId] ?? 0) > from }) {
                k = j; join = boardAt[o.rides[j].tripId]
            } else if d > 0, Int(o.end.timeIntervalSince1970 / 60) == Int(trip.end.timeIntervalSince1970 / 60) {
                join = last
            }
            guard let join, join > from else { continue }
            let lines = o.rides[d..<k].map { $0.isTrain ? ($0.name.isEmpty ? $0.line : $0.name) : $0.line }.joined(separator: " + ")
            let label: String
            if d == 0 {
                let shift = Int((o.start.timeIntervalSince(trip.start) / 60).rounded())
                let when = shift == 0 ? "leave at the same time" : shift > 0 ? "leave \(shift) min later" : "leave \(-shift) min earlier"
                label = "or \(lines) at \(Fmt.hhmm(o.first.departure)) · same \(k < o.rides.count ? name(o.rides[k]) : "arrival") · \(when)"
            } else {
                let sooner = Int((trip.rides[d].departure.timeIntervalSince(o.rides[d].departure) / 60).rounded())
                let onto = k < o.rides.count ? "same \(name(o.rides[k]))" : "there at the same time"
                label = "or \(lines) at \(Fmt.hhmm(o.rides[d].departure)) · \(onto)" + (sooner > 0 ? " · on board \(sooner) min sooner" : "")
            }
            out.append(Branch(from: from, to: join, color: color(o.rides[d]), label: label))
            if out.count == 2 { break }
        }
        return out
    }

    var body: some View {
        let l = layout
        let bs = branches(l.boardAt, last: l.stops.count - 1)
        // the centre of each station, top to bottom
        var ys: [CGFloat] = [stopH / 2]
        for (i, s) in l.segs.enumerated() where i < l.stops.count - 1 { ys.append(ys[i] + stopH / 2 + s.height + stopH / 2) }
        let height = (ys.last ?? 0) + stopH / 2
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                // the branches first, beside the line on the left, fainter
                for (n, b) in bs.enumerated() where b.to < ys.count {
                    let x = lineX - 20 - CGFloat(n) * 9, y0 = ys[b.from], y1 = ys[b.to]
                    var p = Path()
                    p.move(to: CGPoint(x: lineX, y: y0))
                    p.addQuadCurve(to: CGPoint(x: x, y: y0 + 26), control: CGPoint(x: x, y: y0))
                    p.addLine(to: CGPoint(x: x, y: y1 - 26))
                    p.addQuadCurve(to: CGPoint(x: lineX, y: y1), control: CGPoint(x: x, y: y1))
                    ctx.stroke(p, with: .color(b.color.opacity(0.55)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
                // the line itself
                for (i, s) in l.segs.enumerated() where i + 1 < ys.count {
                    var p = Path(); p.move(to: CGPoint(x: lineX, y: ys[i])); p.addLine(to: CGPoint(x: lineX, y: ys[i + 1]))
                    if let r = s.ride {
                        ctx.stroke(p, with: .color(color(r)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    } else {
                        ctx.stroke(p, with: .color(newLook ? DS.legQuiet : Paper.soft), style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [0.5, 9]))
                    }
                }
                // the stations
                for (i, s) in l.stops.enumerated() where i < ys.count {
                    let r: CGFloat = s.end ? 11 : 9
                    let c = CGRect(x: lineX - r, y: ys[i] - r, width: 2 * r, height: 2 * r)
                    ctx.fill(Path(ellipseIn: c), with: .color(s.end ? (newLook ? DS.accent : Paper.yellow) : .white))
                    ctx.stroke(Path(ellipseIn: c), with: .color(newLook ? (s.end ? DS.accent : DS.text) : Paper.ink), lineWidth: 4)
                }
            }
            .frame(height: height)
            // names, times and what you take
            ForEach(Array(l.stops.enumerated()), id: \.offset) { i, s in
                if i < ys.count {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(s.name).font(.system(size: s.end ? 17 : 15.5, weight: newLook ? .bold : .heavy)).foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.7)
                                if newLook, let c = s.chip {
                                    Text(c).font(.system(size: 11.5, weight: .bold)).monospacedDigit()
                                        .foregroundStyle(s.changed ? DS.onAccent : DS.text)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(s.changed ? AnyShapeStyle(DS.warning) : AnyShapeStyle(DS.surface3), in: Capsule())
                                        .fixedSize()
                                }
                            }
                            Text(s.sub).font(.system(size: newLook ? 12 : 11)).foregroundStyle(muted).lineLimit(2).minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 4)
                        Text(Fmt.hhmm(s.time)).font(.system(size: s.end ? 17 : 15.5, weight: newLook ? .bold : .heavy)).foregroundStyle(ink).monospacedDigit()
                    }
                    .frame(height: stopH, alignment: .center)
                    .padding(.leading, lineX + 22)
                    .offset(y: ys[i] - stopH / 2)
                }
            }
            // (the new look) which one each ride is, beside its bullet: above the branches' words when they're there too
            if newLook {
                let busy = Set(bs.filter { $0.to < ys.count && $0.to >= 1 }.map { $0.to - 1 })
                ForEach(Array(l.segs.enumerated()), id: \.offset) { i, s in
                    if let t = s.label, i + 1 < ys.count {
                        let mid = (ys[i] + ys[i + 1]) / 2
                        Text(t).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ink)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .padding(.leading, lineX + 28).padding(.trailing, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .offset(y: busy.contains(i) ? mid - 24 : mid - 8)
                            .allowsHitTesting(false)
                    }
                }
            }
            // each ride's bullet on its piece of line; tap it for where that bus or train is
            ForEach(Array(l.segs.enumerated()), id: \.offset) { i, s in
                if let r = s.ride, i + 1 < ys.count {
                    Button { tap(r) } label: {
                        if newLook { DSLinePill(line: r.isTrain ? Transit.trainLabel(r.line) : r.line, train: r.isTrain).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                        else { LineBullet(line: r.line, train: r.isTrain, height: 20, minWidth: 36, font: 11) }
                    }
                        .buttonStyle(.plain)
                        .position(x: lineX, y: (ys[i] + ys[i + 1]) / 2)
                }
            }
            // what the branches mean, in the space beside the line where they run
            ForEach(Array(bs.enumerated()), id: \.offset) { n, b in
                if b.to < ys.count, b.to >= 1 {
                    let mid = (ys[b.to - 1] + ys[b.to]) / 2 + CGFloat(n) * 16
                    Text(b.label).font(.system(size: 10.5, weight: .bold)).foregroundStyle(b.color)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.leading, lineX + 26).padding(.trailing, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(y: mid - 8)
                }
            }
        }
        .frame(height: height, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(l.stops, l.segs))
    }
}
