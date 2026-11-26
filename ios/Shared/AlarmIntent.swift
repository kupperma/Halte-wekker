import AppIntents
import Foundation

/// "Stop alarm" on the lock screen and in the Dynamic Island. It runs in the app, which is awake during a trip,
/// so you don't have to open Haltewekker to make it quiet.
struct StopAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop alarm"
    static var description = IntentDescription("Stops the Haltewekker alarm.")
    /// (0.42.1) Never asks to unlock, and never opens the app: it runs in the app in the background, locked or not.
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var openAppWhenRun: Bool = false
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { AlarmControl.stop?() }
        return .result()
    }
}

/// The app fills this in at launch (`AlarmResponder.install`): the trip engine's Stop, the same as in the app, or what's
/// left of the alarm on the lock screen when the engine isn't up. The widget never calls it itself.
@MainActor
enum AlarmControl {
    static var stop: (() -> Void)?
}
