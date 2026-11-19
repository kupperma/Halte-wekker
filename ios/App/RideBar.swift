import Foundation

/// The ride made smaller (0.26.1): the bar over the home while a trip runs. What it says, plain so it can be tested.
enum RideBar {
    /// Where the wake-up stands.
    enum Wake: Equatable { case finding, boarding, sleeping, awake, question }

    /// A question for you ("Still on bus 306?") first; then waiting at the stop; then no bus or train yet (and not going
    /// by your location); then awake or not.
    static func wake(awake: Bool, waitingToBoard: Bool, vehicleKnown: Bool, byLocation: Bool, asked: Bool) -> Wake {
        if asked { return .question }
        if waitingToBoard { return .boarding }
        if !vehicleKnown && !byLocation { return .finding }
        return awake ? .awake : .sleeping
    }

    static func wakeText(_ w: Wake, ringAtStop: Bool) -> String {
        switch w {
        case .question: return "A question for you"
        case .boarding: return "Waiting to board"
        case .finding: return "Finding your bus or train"
        case .sleeping: return "Wakes you before your stop"
        case .awake: return ringAtStop ? "You’re awake · a chime there" : "You’re awake"
        }
    }

    /// "Bus 305 to Uden", or "To Uden" before it knows which one.
    static func title(vehicle: String?, to: String) -> String {
        guard let v = vehicle, !v.isEmpty else { return to.isEmpty ? "Your trip" : "To \(to)" }
        return to.isEmpty ? v : "\(v) to \(to)"
    }

    /// "Next: Veghel, Busstation · 12 min": the next stop (not when it's yours) and the countdown.
    static func detail(next: String?, yours: Bool, countdown: RideAhead.Countdown?) -> String {
        var parts: [String] = []
        if let n = next, !n.isEmpty, !yours { parts.append("Next: \(n)") }
        if let c = countdown { parts.append("\(c.value) \(c.unit)") }
        return parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for the bar.
    static func spoken(title: String, next: String?, yours: Bool, countdown: RideAhead.Countdown?, wake: String) -> String {
        var parts: [String] = [title]
        if let c = countdown { parts.append("\(c.spoken) to go") }
        if let n = next, !n.isEmpty, !yours { parts.append("next stop \(n)") }
        parts.append(wake)
        return parts.joined(separator: ", ")
    }

    /// The ride screen made smaller holds for this trip only: a new trip (any trip after no trip), and the alarm, open it
    /// full again.
    static func keepsSmall(_ small: Bool, rideOn: Bool, alarm: Bool) -> Bool {
        small && rideOn && !alarm
    }
}
