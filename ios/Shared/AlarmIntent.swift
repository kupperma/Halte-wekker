import AppIntents
import Foundation

/// "Stop alarm" on the lock screen and in the Dynamic Island. It runs in the app, which is awake during a trip,
/// so you don't have to open Haltewekker to make it quiet.
struct StopAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop alarm"
    static var description = IntentDescription("Stops the Haltewekker alarm.")
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { AlarmControl.stop?() }
        return .result()
    }
}

/// The app fills this in; the widget never calls it itself.
@MainActor
enum AlarmControl {
    static var stop: (() -> Void)?
}
