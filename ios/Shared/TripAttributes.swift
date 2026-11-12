import ActivityKit
import Foundation

/// What the Dynamic Island and the lock screen show during a trip.
struct TripAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var legTitle: String        // "Intercity to Breda"
        var isTrain: Bool
        var distanceText: String    // "12.4 km"
        var arrival: Date?          // when you reach your last stop
        var finalName: String       // "Home" or "Breda"
        var nextText: String?       // "Then bus 306 at 17:03"
        var awake: Bool             // the wake-up alarm has gone off for this leg
        var goingHome: Bool
        // the little ride screen on the lock screen
        var kicker: String          // "NOW RIDING", "WAKE UP", "CHANGE HERE", "YOU’RE THERE"
        var stopName: String        // "Breda station"
        var progress: Double        // 0…1 along this leg: where the metro is on the track
        var legFrom: Date?
        var legTo: Date?            // when this bus or train reaches your stop
        var song: String?           // what you're listening to
        var artist: String?
        var songPlaying: Bool
        var musicApp: String?
        var stops: [Double] = []    // where the stops along the way are on the track (0…1)
        var ringing = false         // the alarm is sounding: show "Stop alarm"
    }
    var routeName: String
}
