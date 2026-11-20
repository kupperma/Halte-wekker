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
        // 0.39: a richer lock screen (all optional: a state from before still decodes)
        var nextStop: String? = nil     // the next stop it calls at, when it isn't yours ("Vught")
        var delay: Int? = nil           // minutes late at your stop (negative: early; nil: not live)
        var platform: String? = nil     // the platform you get in at
        var changeText: String? = nil   // the change ahead: "Platform 5 → 7 · 3 min walk · 4 min to change"
        var changeLeaves: Date? = nil   // when the next one leaves (the countdown at the change)
        var changeMiss: String? = nil   // "You’ll miss the 08:12 — take the 08:27 from platform 4"

        /// The kind to draw.
        var kind: VehicleKind { VehicleKind.stored(vehicle, isTrain: isTrain) }
    }
    var routeName: String
}

// A state written without the newer fields (`stops`, `ringing`, `vehicle`, `line`; 0.39 `nextStop`, `delay`, `platform`,
// `changeText`, `changeLeaves`, `changeMiss`) still decodes: they take their defaults. (The synthesized decoding would throw on a missing key, defaults or not.)
extension TripAttributes.ContentState {
    enum CodingKeys: String, CodingKey {
        case legTitle, isTrain, distanceText, arrival, finalName, nextText, awake, goingHome, kicker, stopName, progress,
             legFrom, legTo, song, artist, songPlaying, musicApp, stops, ringing, vehicle, line,
             nextStop, delay, platform, changeText, changeLeaves, changeMiss
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
        nextStop = try c.decodeIfPresent(String.self, forKey: .nextStop)
        delay = try c.decodeIfPresent(Int.self, forKey: .delay)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        changeText = try c.decodeIfPresent(String.self, forKey: .changeText)
        changeLeaves = try c.decodeIfPresent(Date.self, forKey: .changeLeaves)
        changeMiss = try c.decodeIfPresent(String.self, forKey: .changeMiss)
    }

    /// (0.39) The line under the ride on the lock screen: "Next: Vught · 3 min late · platform 5" (nil: nothing known).
    var rideLine: String? { LockWords.ride(nextStop: nextStop, delay: delay, platform: platform) }

    /// (0.39) The change ahead as the lock screen says it: the miss first, else the platforms and the minutes.
    var changeLine: String? {
        if let m = changeMiss, !m.isEmpty { return m }
        if let c = changeText, !c.isEmpty { return c }
        return nil
    }
}

/// (0.39) The lock screen's words for a ride. Plain, so they can be tested.
enum LockWords {
    /// "3 min late", "on time", "2 min early"; nil: not live.
    static func delay(_ m: Int?) -> String? {
        guard let m else { return nil }
        if m == 0 { return "on time" }
        return m > 0 ? "\(m) min late" : "\(-m) min early"
    }

    /// "Next: Vught · 3 min late · platform 5": what's known of the three.
    static func ride(nextStop: String?, delay d: Int?, platform: String?) -> String? {
        var parts: [String] = []
        if let n = nextStop?.trimmingCharacters(in: .whitespaces), !n.isEmpty { parts.append("Next: \(n)") }
        if let t = delay(d) { parts.append(t) }
        if let p = platform?.trimmingCharacters(in: .whitespaces), !p.isEmpty { parts.append("platform \(p)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
