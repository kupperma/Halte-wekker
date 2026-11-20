import CoreLocation
import SwiftUI

/// The new home's refreshes, the same as the old home's (`HomeView`): where you are and the live times, the planned
/// trips and `autoGo`, the school alarms and watched trains, and the weather; every 30 s while the app is in front and
/// Fastest trip isn't open, their first steps 1.5 s apart. Also what the old home did on coming back to the front.
/// (A copy, so the old home stays exactly as it was while it's the fallback; both go to one place in 0.20.)
struct HomeLoops: ViewModifier {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var live: LiveStore
    @EnvironmentObject var planner: Planner
    @EnvironmentObject var watch: WatchStore
    @EnvironmentObject var near: NearMe
    @EnvironmentObject var goStore: GoStore
    @Environment(\.scenePhase) private var scene
    @ObservedObject private var motion = Motion.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: near.position?.coordinate.latitude) { _, _ in
                guard !goStore.isOpen else { return }            // (on its way out: Fastest trip has the screen)
                Task { await live.refresh(trip.direction, at: near.position) }
            }
            .onAppear { Handoff.fromBoards = false; followIfHome() }
            .onDisappear { near.follow(false); Motion.shared.live(false, for: "home") }
            .onChange(of: goStore.isOpen) { _, _ in followIfHome() }
            .onChange(of: trip.phase) { _, _ in followIfHome() }
            // (0.33) Motion & Fitness started saying "automotive": the on-board look now, not on the next fix or tick
            .onChange(of: motion.vehicleKicks) { _, _ in
                guard scene == .active, !goStore.isOpen, trip.phase == .idle else { return }
                Task { await live.refresh(trip.direction, at: near.position) }
            }
            // seen on the same bus or train twice in a row: the trip starts by itself (0.20.5)
            .onChange(of: live.onBoardLooks) { _, _ in HomeActions.autoStartOnBoard(live: live, trip: trip, goStore: goStore) }
            .task(id: trip.direction) {
                await everyHalfMinute {
                    Watchdog.shared.mark("finding where you are")
                    near.locate(ask: true)
                    Watchdog.shared.mark("loading the live times")
                    await live.refresh(trip.direction, at: near.position)
                    HomeActions.updateOutfit(trip: trip, live: live, goStore: goStore, near: near)
                    Watchdog.shared.mark("showing the home screen")
                }
            }
            .task(id: trip.direction) {
                await everyHalfMinute(after: 1.5) {
                    Watchdog.shared.mark("planning your planned trips")
                    await planner.refresh()
                    HomeActions.autoGo(trip: trip, planner: planner, goStore: goStore, near: near)
                    Watchdog.shared.mark("showing the home screen")
                }
            }
            .task(id: trip.direction) {
                await everyHalfMinute(after: 3) {
                    Watchdog.shared.mark("planning the school alarms")
                    await SchoolAlarm.shared.refresh()
                    Watchdog.shared.mark("checking watched trains")
                    await watch.check()
                    Watchdog.shared.mark("showing the home screen")
                }
            }
            .task(id: trip.direction) {
                await everyHalfMinute(after: 4.5) {
                    Watchdog.shared.mark("getting the weather")
                    HomeActions.updateOutfit(trip: trip, live: live, goStore: goStore, near: near)
                    await OutfitStore.shared.refresh()
                    Watchdog.shared.mark("showing the home screen")
                }
            }
            .onChange(of: scene) { _, s in
                followIfHome()
                if s == .active {
                    trip.appBecameActive()
                    HomeActions.autoGo(trip: trip, planner: planner, goStore: goStore, near: near)
                    Task { await watch.check(force: true) }
                    guard !goStore.isOpen else { return }
                    Task { await live.refresh(trip.direction, at: near.position) }
                    Task { await planner.refresh() }
                }
            }
    }

    /// The GPS keeps following you while the home is in front with no trip on and Fastest trip closed (they have their
    /// own), so being on a bus is noticed; else one position at a time, as before.
    private func followIfHome() {
        let home = scene == .active && !goStore.isOpen && trip.phase == .idle
        near.follow(home)
        Motion.shared.live(home, for: "home")             // (its live updates only while the home is in front, 0.33)
    }

    /// `step` now and every 30 s after, while the app is in front and Fastest trip isn't open, until cancelled.
    private func everyHalfMinute(after delay: Double = 0, _ step: () async -> Void) async {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
        }
        while !Task.isCancelled {
            if scene == .active && !goStore.isOpen { await step() }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }
}

/// The trip that's due now: the school trip or a planned one, in the window `autoGo` opens Fastest trip by itself and
/// while it's still to leave for. The next-trip nudge (Live around you) and the big card (Next trip first) show it.
struct DueTrip {
    let school: Bool            // the school alarm's trip (else the Be there by / Leave at plan)
    let leave: Date
    let trip: DoorTrip
    let sub: String             // "For your 09:00 class", "Home by 17:30", "Your trip home"
    let dest: Place
    let deadline: Date?
}

/// What the old home does to open Fastest trip for a plan, by itself or when you tap: the same code, for the new screens.
@MainActor
enum HomeActions {
    /// The due trip, if any (only with no trip on: the ride screens have the screen then).
    static func due(trip: TripManager, planner: Planner, now: Date) -> DueTrip? {
        guard trip.phase == .idle else { return nil }
        if let n = SchoolAlarm.shared.next, GoStore.schoolWindowOpen(n, now: now), let l = n.leave, let t = n.trip,
           DepartureGroups.leaveText(leave: l, now: now) != nil {
            return DueTrip(school: true, leave: l, trip: t, sub: "For your \(Fmt.hhmm(n.classStart)) class", dest: .school, deadline: n.beThere)
        }
        if let a = planner.arrive, let t = planner.arriveChosen, GoStore.arriveWindowOpen(a, chosen: t, now: now),
           DepartureGroups.leaveText(leave: t.start, now: now) != nil {
            return DueTrip(school: false, leave: t.start, trip: t,
                           sub: a.leaving ? "Your trip \(a.out ? "to school" : "home")" : "\(a.out ? "School" : "Home") by \(a.time)",
                           dest: a.out ? .school : .home, deadline: a.leaving ? nil : a.when)
        }
        return nil
    }

    /// The trip from the bus or train the home found you on (0.20.5): the first of your next trips that starts on it.
    static func onBoardTrip(live: LiveStore) -> DoorTrip? {
        guard let ob = live.onBoard, live.nextAsOf == nil else { return nil }
        return live.next.first { $0.first.fromId == "onboard" && $0.first.tripId == ob.vehicle.tripId }
    }

    /// The buses and trains a trip has started by itself on: stop it and it doesn't start again on that one.
    /// (0.26.1) And the ones you ended a ride on: on 2026-11-19 a ride ended on the 305 started again by itself on it.
    private static var autoStartedOn: Set<String> = []
    static func rideEnded(on v: Vehicle) { autoStartedOn.insert(v.tripId) }
    static func mayAutoStart(_ v: Vehicle) -> Bool { !autoStartedOn.contains(v.tripId) }

    /// Found on the same bus or train in two looks in a row (about a minute, your track against its position): your trip
    /// starts by itself with it, wake-up alarm and all, as Fastest trip's does once you're on board.
    static func autoStartOnBoard(live: LiveStore, trip: TripManager, goStore: GoStore) {
        guard live.onBoardLooks >= 2, !goStore.isOpen, let ob = live.onBoard,
              OnBoardRules.mayAutoStart(ob.vehicle.tripId, idle: trip.phase == .idle, running: trip.vehicle?.tripId, blocked: autoStartedOn),
              let t = onBoardTrip(live: live), let r = RoutePlan.from(t) else { return }
        autoStartedOn.insert(ob.vehicle.tripId)
        trip.start(r, vehicle: ob.vehicle, auto: true, alternatives: [t], how: "Home on board, by itself")
    }

    /// What the outfit screen plans for (as `HomeView.updateOutfit`).
    static func updateOutfit(trip: TripManager, live: LiveStore, goStore: GoStore, near: NearMe) {
        var leave: Date?, arrive: Date?
        if let b = goStore.best {
            leave = b.start; arrive = b.end
        } else if let n = SchoolAlarm.shared.next, let l = n.leave, l > Date().addingTimeInterval(-3600),
                  Calendar.current.isDate(l, inSameDayAs: Date()) || Calendar.current.component(.hour, from: Date()) >= 19 {
            leave = l; arrive = n.trip?.end ?? n.beThere
        } else if let t = live.next.first {
            leave = t.start; arrive = t.end
        }
        OutfitStore.shared.set(here: near.position ?? trip.lastFix, dest: live.destination(trip.direction), leave: leave, arrive: arrive)
    }

    /// Around the time to leave for a planned trip, the hands-free screen opens by itself (as `HomeView.autoGo`).
    static func autoGo(trip: TripManager, planner: Planner, goStore: GoStore, near: NearMe) {
        guard trip.phase == .idle, !goStore.isOpen else { return }
        let now = Date()
        if let n = SchoolAlarm.shared.next, GoStore.schoolAutoOpen(n, now: now) {
            if trip.direction != .toSchool { trip.pick(.toSchool) }
            withAnimation(.easeInOut(duration: 0.35)) {
                goStore.openForPlan(to: .school, from: near.position, deadline: n.beThere, label: "your \(Fmt.hhmm(n.classStart)) class",
                                    key: GoStore.schoolKey(n.classStart))
            }
            return
        }
        if let a = planner.arrive, let T = a.when, GoStore.arriveAutoOpen(a, chosen: planner.arriveChosen, now: now) {
            if trip.direction != (a.out ? .toSchool : .home) { trip.pick(a.out ? .toSchool : .home) }
            withAnimation(.easeInOut(duration: 0.35)) {
                goStore.openForPlan(to: a.out ? .school : .home, from: near.position, deadline: a.leaving ? nil : T,
                                    label: a.leaving ? nil : "\(a.out ? RoleWords.current.school : "home") by \(a.time)",
                                    key: GoStore.arriveKey(a))
            }
        }
    }

    /// Hands-free now, for the school alarm's trip or the Be there by plan (as `HomeView.openPlanGo`).
    static func openPlanGo(school: Bool, trip: TripManager, planner: Planner, goStore: GoStore, near: NearMe) {
        guard trip.phase == .idle else { return }
        let now = Date()
        if school, let n = SchoolAlarm.shared.next {
            if trip.direction != .toSchool { trip.pick(.toSchool) }
            withAnimation(.easeInOut(duration: 0.35)) {
                goStore.open(to: .school, from: near.position, deadline: n.beThere, label: "your \(Fmt.hhmm(n.classStart)) class",
                             planKey: GoStore.schoolWindowOpen(n, now: now) ? GoStore.schoolKey(n.classStart) : nil)
            }
        } else if let a = planner.arrive, let T = a.when {
            if trip.direction != (a.out ? .toSchool : .home) { trip.pick(a.out ? .toSchool : .home) }
            withAnimation(.easeInOut(duration: 0.35)) {
                goStore.open(to: a.out ? .school : .home, from: near.position, deadline: a.leaving ? nil : T,
                             label: a.leaving ? nil : "\(a.out ? RoleWords.current.school : "home") by \(a.time)",
                             planKey: GoStore.arriveWindowOpen(a, chosen: planner.arriveChosen, now: now) ? GoStore.arriveKey(a) : nil)
            }
        }
    }

    /// "I'm on this one" for a bus or train tapped on the home map: one of your next trips from here, started by hand the
    /// way Fastest trip's "I'm on it" starts it (`GoStore.startByHand`): with the one the live store sees you on; you said
    /// it's this one while it saw another (picked); or else holding the ride it was planned with.
    static func startOnThisOne(_ t: DoorTrip, live: LiveStore, trip: TripManager) {
        guard trip.phase == .idle, let r = RoutePlan.from(t) else { return }
        if let ob = live.onBoard, t.first.tripId == ob.vehicle.tripId {
            trip.start(r, vehicle: ob.vehicle, alternatives: [t], how: "Home map hand")
        } else if live.onBoard != nil {
            let f = t.first
            trip.start(r, vehicle: Vehicle(tripId: f.tripId, line: f.line, isTrain: f.isTrain), alternatives: [t], picked: true,
                       how: "Home map hand, picked")
        } else {
            trip.start(r, onIt: true, how: "Home map hand")
        }
    }

    /// "I'm on this one" for a bus or train no trip of yours starts with (0.26.2: on 2026-11-19 the Intercity you were
    /// on, while the home's trips were planned from the spot): planned on from it as the on-board looks do (its next
    /// stop, from when it gets there, to where you're going), and started by hand on it.
    static func startOnBoardByHand(_ v: Vehicle, live: LiveStore, trip: TripManager, near: NearMe) {
        guard trip.phase == .idle, let f = near.position ?? trip.lastFix else { return }
        let dest = live.destination(trip.direction)
        Task { @MainActor in
            let ob = await LiveStore.onBoardTrips(f, to: dest, tripId: v.tripId)
            guard trip.phase == .idle else { return }
            guard let ob, let t = ob.1.first, let r = RoutePlan.from(t) else {
                trip.toast = "Couldn’t find the way on from the \(v.title) just now. Try again in a moment."
                return
            }
            trip.start(r, vehicle: ob.0.vehicle, alternatives: ob.1, picked: true, how: "Home map hand, on board")
        }
    }

    /// The hands-free Fastest trip to where you're going now, seeded with the home's trips from here (as `HomeView.openGo`).
    static func openGo(live: LiveStore, trip: TripManager, goStore: GoStore, near: NearMe) {
        var seed: [DoorTrip] = []
        if live.onBoard == nil, live.nextAsOf == nil, let h = live.here, let u = live.updated, Date().timeIntervalSince(u) < 180,
           let p = near.position, p.distance(from: h) < 300 {
            seed = live.next
        }
        withAnimation(.easeInOut(duration: 0.35)) { goStore.open(to: live.destination(trip.direction), from: near.position, seed: seed) }
    }
}
