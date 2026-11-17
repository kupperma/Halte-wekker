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
        var progress: Double        // 0…1 along this leg: where the vehicle is on the track
        var legFrom: Date?
        var legTo: Date?            // when this bus or train reaches your stop
        var song: String?           // what you're listening to
        var artist: String?
        var songPlaying: Bool
        var musicApp: String?
        var stops: [Double] = []    // where the stops along the way are on the track (0…1)
        var ringing = false         // the alarm is sounding: show "Stop alarm"
        var vehicle = ""            // what's drawn on the track: a `VehicleKind` ("bus", "ic", "sprinter", "tram", "metro",
                                    // "train"); "" (a state from before 0.20.4): a train or a bus by `isTrain`
        var line = ""               // the line on its pill: "5", "306", "IC" ("" not known)

        /// The kind to draw.
        var kind: VehicleKind { VehicleKind.stored(vehicle, isTrain: isTrain) }
    }
    var routeName: String
}

// A state written without the newer fields (`stops`, `ringing`, `vehicle`, `line`) still decodes: they take their
// defaults. (The synthesized decoding would throw on a missing key, defaults or not.)
extension TripAttributes.ContentState {
    enum CodingKeys: String, CodingKey {
        case legTitle, isTrain, distanceText, arrival, finalName, nextText, awake, goingHome, kicker, stopName, progress,
             legFrom, legTo, song, artist, songPlaying, musicApp, stops, ringing, vehicle, line
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        legTitle = try c.decode(String.self, forKey: .legTitle)
        isTrain = try c.decode(Bool.self, forKey: .isTrain)
        distanceText = try c.decode(String.self, forKey: .distanceText)
        arrival = try c.decodeIfPresent(Date.self, forKey: .arrival)
        finalName = try c.decode(String.self, forKey: .finalName)
        nextText = try c.decodeIfPresent(String.self, forKey: .nextText)
        awake = try c.decode(Bool.self, forKey: .awake)
        goingHome = try c.decode(Bool.self, forKey: .goingHome)
        kicker = try c.decode(String.self, forKey: .kicker)
        stopName = try c.decode(String.self, forKey: .stopName)
        progress = try c.decode(Double.self, forKey: .progress)
        legFrom = try c.decodeIfPresent(Date.self, forKey: .legFrom)
        legTo = try c.decodeIfPresent(Date.self, forKey: .legTo)
        song = try c.decodeIfPresent(String.self, forKey: .song)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        songPlaying = try c.decode(Bool.self, forKey: .songPlaying)
        musicApp = try c.decodeIfPresent(String.self, forKey: .musicApp)
        stops = try c.decodeIfPresent([Double].self, forKey: .stops) ?? []
        ringing = try c.decodeIfPresent(Bool.self, forKey: .ringing) ?? false
        vehicle = try c.decodeIfPresent(String.self, forKey: .vehicle) ?? ""
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
    }
}
