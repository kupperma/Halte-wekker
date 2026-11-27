import Foundation

/// (0.42.11) Which side you get out of the train: "Exit on the left · platform 4". The relay works it out from
/// OpenStreetMap (`/rail/v1/side`, map data © OpenStreetMap contributors) for the station, its platform and the stop
/// before (so the way the train goes). Asked once a train leg knows the platform it gets in at (`DoorSideStore`), again
/// only when that platform changes, never while the alarm rings; unknown: nothing is shown. Plain values, so the rules
/// are tested against docs/door-side-vectors.json (the vectors Android and the relay check too). Foundation only.
enum DoorSide {
    struct Answer: Equatable, Sendable {
        let side: String        // "left", "right", "both"
        let low: Bool           // a guess: "(estimate)"
    }

    /// One stop of the train's trip: where it is and its platform there.
    struct Stop: Equatable, Sendable {
        let point: GeoPoint
        let track: String?
    }

    /// What the app asks for: the station, its platform, the stop before and the station's place.
    struct Ask: Equatable, Sendable {
        let station: String
        let track: String
        let from: GeoPoint
        let at: GeoPoint
        var query: String {
            let f: String = "\(coord(from.lat)),\(coord(from.lon))"
            let a: String = "\(coord(at.lat)),\(coord(at.lon))"
            return "station=\(station)&track=\(track)&from=\(f)&at=\(a)"
        }
        var key: String { "\(station)|\(track)|\(query)" }
    }

    static func coord(_ x: Double) -> String { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), x) }

    /// " 4A " → "4a".
    static func cleanTrack(_ t: String?) -> String {
        String((t ?? "").lowercased().filter { !$0.isWhitespace })
    }

    /// The relay's answer; nil when it says nothing usable (unknown, busy, not JSON). No confidence: a guess.
    static func parse(_ data: Data?) -> Answer? {
        guard let data, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = o["side"] as? String else { return nil }
        let side: String = raw.lowercased()
        guard side == "left" || side == "right" || side == "both" else { return nil }
        let conf: String = ((o["confidence"] as? String) ?? "").lowercased()
        return Answer(side: side, low: conf != "high")
    }

    /// "Exit on the left · platform 4", "Exit on both sides · platform 2", "… (estimate)"; nil: nothing to say.
    static func line(_ a: Answer?, track: String?) -> String? {
        guard let a else { return nil }
        let where_: String = a.side == "both" ? "on both sides" : "on the \(a.side)"
        let t: String = (track ?? "").trimmingCharacters(in: .whitespaces)
        var s: String = "Exit \(where_)"
        if !t.isEmpty { s += " · platform \(t)" }
        if a.low { s += " (estimate)" }
        return s
    }

    /// The lock screen's platform with the side after it: "4 · exit on the left" (it reads "platform 4 · exit on the
    /// left"); just the platform when nothing is known.
    static func lockPlatform(_ platform: String?, _ a: Answer?) -> String? {
        guard let p = platform?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return platform }
        guard let a else { return p }
        let where_: String = a.side == "both" ? "on both sides" : "on the \(a.side)"
        return "\(p) · exit \(where_)" + (a.low ? " (estimate)" : "")
    }

    /// A notification's text with the line after it.
    static func withLine(_ text: String, _ line: String?) -> String {
        guard let line, !line.isEmpty else { return text }
        return text + "\n" + line
    }

    /// The question for a train leg to `to`, from its trip's stops: your stop (the one nearest `to`, within 500 m), the
    /// platform it gets in at there, and the stop before it. Nil: not a train, no platform, no stop before, no code.
    static func ask(train: Bool, stops: [Stop], to: GeoPoint, code: String?) -> Ask? {
        guard train, let code, !code.isEmpty, stops.count >= 2 else { return nil }
        guard let i = stops.indices.min(by: { Geo.metres(stops[$0].point, to) < Geo.metres(stops[$1].point, to) }) else { return nil }
        guard i > 0, Geo.metres(stops[i].point, to) <= 500 else { return nil }
        let track: String = cleanTrack(stops[i].track)
        guard track.range(of: "^[0-9]{1,2}[a-z]?$", options: .regularExpression) != nil else { return nil }
        return Ask(station: code.uppercased(), track: track, from: stops[i - 1].point, at: stops[i].point)
    }
}
