import ActivityKit
import Foundation

/// What the Dynamic Island and the lock screen show during a trip.
struct TripAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var legTitle: String        // "Train to Den Bosch"
        var isTrain: Bool
        var distanceText: String    // "12.4 km"
        var arrival: Date?          // when you reach your last stop
        var finalName: String       // "Home" or "Breda"
        var nextText: String?       // "Then bus 306 at 17:03"
        var awake: Bool             // the wake-up alarm has gone off for this leg
        var goingHome: Bool
    }
    var routeName: String
}
