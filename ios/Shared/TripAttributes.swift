import ActivityKit
import Foundation

/// What the Dynamic Island / lock screen shows during a trip.
struct TripAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var legTitle: String        // "Train to Den Bosch"
        var distanceText: String    // "12.4 km"
        var arrival: Date?          // when you reach your final stop
        var finalName: String       // "Home" / "Breda"
        var nextText: String?       // "Then bus 306 at 17:03"
        var awake: Bool             // alarm has gone off for this leg
    }
    var routeName: String
}
