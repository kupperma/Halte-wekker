import SwiftUI

/// 0.37: what Siri, Shortcuts or the widget's tap asked of the app, until a screen takes it. Fastest trip and Start my
/// trip are done here, through the app's own start path (`HomeActions`, `GoStore`); a stop's sheet and Wake me at a
/// stop are the home's (`NewHome`), which opens them to look at or confirm. Older than 2 minutes: dropped.
@MainActor
final class AppActions: ObservableObject {
    static let shared = AppActions()
    @Published private(set) var pending: IntentActions.Action?
    private var at = Date.distantPast

    func post(_ a: IntentActions.Action) {
        pending = a
        at = Date()
    }

    /// The pending action, if it's still meant for now.
    var current: IntentActions.Action? {
        Date().timeIntervalSince(at) < 120 ? pending : nil
    }

    func done() { pending = nil }
}

/// On the root: Fastest trip and Start my trip, and a refusal over a running trip.
struct AppActionsHandler: ViewModifier {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var live: LiveStore
    @EnvironmentObject var planner: Planner
    @EnvironmentObject var near: NearMe
    @EnvironmentObject var goStore: GoStore
    @ObservedObject private var actions = AppActions.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: actions.pending) { _, _ in handle() }
            .onAppear { handle() }
    }

    private func handle() {
        guard let a = actions.current else { return }
        if case .refuse(let why) = IntentActions.outcome(a, idle: trip.phase == .idle) {
            actions.done()
            trip.toast = why
            return
        }
        switch a {
        case .showStop, .wake:
            return                                  // (the home's sheets)
        case .fastest(let toSchool):
            actions.done()
            let d: Direction = toSchool ? .toSchool : .home
            live.go(to: nil)
            if trip.direction != d { trip.pick(d) }
            if goStore.isOpen { goStore.retarget(toSchool ? .school : .home) }
            else { HomeActions.openGo(live: live, trip: trip, goStore: goStore, near: near) }
        case .startTrip:
            actions.done()
            startTrip()
        }
    }

    /// I'm on it for the next planned ride: started by hand when it's leaving now (or just left), else Fastest trip for
    /// it (which starts the trip by itself once you're on board).
    private func startTrip() {
        let now = Date()
        let due = HomeActions.due(trip: trip, planner: planner, now: now)
        let s = IntentActions.start(idle: trip.phase == .idle, departure: due?.trip.first.departure, now: now)
        switch s {
        case .alreadyRunning:
            break
        case .startNow:
            if let due {
                let d: Direction = due.dest == .home ? .home : .toSchool
                if trip.direction != d { trip.pick(d) }
                HomeActions.startOnThisOne(due.trip, live: live, trip: trip)
            }
        case .openPlanned:
            HomeActions.openPlanGo(school: due?.school ?? false, trip: trip, planner: planner, goStore: goStore, near: near)
        case .openFastest:
            if !goStore.isOpen { HomeActions.openGo(live: live, trip: trip, goStore: goStore, near: near) }
        }
        if let text = IntentActions.startText(s) { trip.toast = text }
    }
}
