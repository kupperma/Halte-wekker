import Foundation

/// 0.37: what Siri, Shortcuts and the widget's tap ask the app to do, and what the app then does — pure, so it can be
/// tested. Nothing here starts a ride: the app does that through its own start path (`HomeActions`, `GoStore`), and a
/// stop to wake you at always opens Wake me at a stop to confirm.
enum IntentActions {
    enum Action: Equatable, Sendable {
        /// The stop's sheet with its departures (the widget's tap).
        case showStop(StopBoardCore.Stop)
        /// Wake me at a stop: its screen, filled in, to confirm.
        case wake(StopBoardCore.Stop)
        /// Fastest trip to school or home.
        case fastest(toSchool: Bool)
        /// I'm on it, for the next planned ride.
        case startTrip
    }

    /// A link the app is opened with: the widget's haltewekker://stop?…
    static func action(_ url: URL) -> Action? {
        StopBoardCore.parseLink(url).map { .showStop($0) }
    }

    /// What may happen now: everything but the stop's sheet waits for no trip to be running.
    enum Outcome: Equatable, Sendable {
        case go
        case refuse(String)
    }

    static func outcome(_ a: Action, idle: Bool) -> Outcome {
        switch a {
        case .showStop: return .go
        case .wake, .fastest, .startTrip:
            return idle ? .go : .refuse("A trip is running. End it first to start another.")
        }
    }

    /// "Start my trip": what to do with the next planned ride (`departure`: its first ride's).
    enum Start: Equatable, Sendable {
        case alreadyRunning
        /// It leaves within 3 minutes or left in the last 15: you're at the stop or on it — I'm on it.
        case startNow
        /// It's later: Fastest trip for it, which starts the trip by itself once you're on board.
        case openPlanned
        /// Nothing planned (or it's long gone): Fastest trip to where you're going.
        case openFastest
    }

    static func start(idle: Bool, departure: Date?, now: Date) -> Start {
        guard idle else { return .alreadyRunning }
        guard let d = departure else { return .openFastest }
        let ahead = d.timeIntervalSince(now)
        if ahead <= 3 * 60 && ahead >= -15 * 60 { return .startNow }
        if ahead < -15 * 60 { return .openFastest }
        return .openPlanned
    }

    /// The words on the app's toast for each.
    static func startText(_ s: Start) -> String? {
        switch s {
        case .alreadyRunning: return "Your trip is already running."
        case .startNow: return nil
        case .openPlanned: return "Watching your planned trip: it starts by itself once you’re on board, or tap I’m on it."
        case .openFastest: return "No planned trip just now: here’s your fastest way. Tap I’m on it once you’re on board."
        }
    }

    /// "When's my bus?": from your home stop when you're near home (or it doesn't know where you are), else from the
    /// stop nearest you.
    enum BusFrom: Equatable, Sendable { case home, nearest }

    static func busFrom(metresFromHome: Double?, haveHomeStop: Bool) -> BusFrom {
        guard haveHomeStop else { return .nearest }
        guard let m = metresFromHome else { return .home }
        return m <= 600 ? .home : .nearest
    }
}
