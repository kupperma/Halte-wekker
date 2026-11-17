import Foundation

/// The new look's outfit sheet in words (0.20.9): the one line of what to wear, what VoiceOver says for the top, the
/// rain, the chips, the "during the day" notes and where the forecast applies. Only the wording: what it advises
/// stays `Layer` and `OutfitPlan`'s (Outfit.swift). Plain values, so it's tested without SwiftUI or CoreLocation: a
/// grade is `Layer`'s number (1 very cold winter … 5 peak summer), times go through `clock` ("HH:mm").
enum OutfitWords {
    /// A wet stretch (`OutfitPlan.rain`, without the place).
    struct Rain: Equatable {
        let from: Date
        let to: Date
        var chance = 0
    }

    /// One of the outfit's chips: the words, and the SF Symbols to try in order (the first the phone has; none: text).
    struct Chip: Equatable {
        let label: String
        let symbols: [String]
        var rain = false
    }

    // MARK: what to wear

    /// "Coat and a sweater": the grade's clothes, short, as the start of the one line.
    static func wear(grade: Int) -> String {
        switch grade {
        case ...1: return "Winter coat, warm sweater, scarf, gloves and hat"
        case 2: return "Coat and a sweater"
        case 3: return "Sweater or a light jacket"
        case 4: return "T-shirt, a thin layer for the evening"
        default: return "T-shirt and shorts, sunglasses and water"
        }
    }

    /// "a coat and a sweater": the same, to say after "Wear".
    static func wearSpoken(grade: Int) -> String {
        switch grade {
        case ...1: return "a winter coat, a warm sweater, a scarf, gloves and a hat"
        case 2: return "a coat and a sweater"
        case 3: return "a sweater or a light jacket"
        case 4: return "a T-shirt, with a thin layer for the evening"
        default: return "a T-shirt and shorts, with sunglasses and water"
        }
    }

    /// The rain in a few words, from where the day's outfit starts (`start`, its hour) to its end (`end`, after the
    /// last hour): "rain from 16:00", "rain until 11:00" (it rains when you set off), "rain all day"; nil: none (or
    /// only before you set off). Stretches that follow on (the same rain, here and then there) count as one.
    static func rain(_ stretches: [Rain], start: Date, end: Date, clock: (Date) -> String) -> String? {
        guard let first = merged(stretches).first(where: { $0.to > start }) else { return nil }
        if first.from > start { return "rain from \(clock(first.from))" }
        return first.to < end ? "rain until \(clock(first.to))" : "rain all day"
    }

    /// The stretches, with the ones that follow on joined (the highest chance of the two).
    static func merged(_ stretches: [Rain]) -> [Rain] {
        var out: [Rain] = []
        for r in stretches.sorted(by: { $0.from < $1.from }) {
            if let last = out.last, r.from <= last.to {
                out[out.count - 1] = Rain(from: last.from, to: max(last.to, r.to), chance: max(last.chance, r.chance))
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// The one line under the temperature: "Coat and a sweater · raincoat, rain from 16:00" (`raincoat`: the plan's
    /// advice, `OutfitPlan.raincoat`; `rain`: the words from `rain(_:start:end:clock:)`).
    static func line(grade: Int, raincoat: Bool, rain: String?) -> String {
        wear(grade: grade) + (raincoat ? " · raincoat" + (rain.map { ", \($0)" } ?? "") : "")
    }

    /// The top as VoiceOver says it: "10 degrees, feels like 7, rain from 16:00. Wear a coat and a sweater, and take
    /// a raincoat".
    static func spoken(temp: Int, feels: Int, grade: Int, raincoat: Bool, rain: String?) -> String {
        let wet = raincoat ? (rain.map { ", " + $0 } ?? "") : ""
        return "\(degrees(temp)), feels like \(feels)\(wet). Wear \(wearSpoken(grade: grade))" + (raincoat ? ", and take a raincoat" : "")
    }

    /// "10 degrees", "1 degree", "-1 degree".
    static func degrees(_ t: Int) -> String { "\(t) degree\(abs(t) == 1 ? "" : "s")" }

    // MARK: the chips

    /// The grade's layers (`Layer.pieces`, bottom to top) as chips, with a raincoat if it'll rain.
    static func chips(pieces: [String], raincoat: Bool) -> [Chip] {
        pieces.map { Chip(label: $0, symbols: symbols(for: $0)) }
            + (raincoat ? [Chip(label: "Raincoat", symbols: ["umbrella.fill"], rain: true)] : [])
    }

    /// The SF Symbols for a piece, by what it is (iOS 17 has a T-shirt, a jacket and a coat; no sweater or scarf).
    static func symbols(for piece: String) -> [String] {
        let p = piece.lowercased()
        if p.contains("coat") { return ["coat.fill", "jacket.fill"] }
        if p.contains("jacket") { return ["jacket.fill"] }
        if p.contains("scarf") || p.contains("hat") { return ["hat.widebrim.fill"] }
        if p.hasPrefix("sweater") { return [] }
        if p.contains("shirt") { return ["tshirt.fill"] }
        return []
    }

    // MARK: during the day

    /// A layer change: "Drop a layer", "Add 2 layers", or "It gets warmer" when the count stays the same.
    static func change(fromLayers: Int, toLayers: Int, warmer: Bool) -> String {
        let n = abs(toLayers - fromLayers)
        if n == 0 { return "It gets \(warmer ? "warmer" : "colder")" }
        return "\(warmer ? "Drop" : "Add") \(n == 1 ? "a layer" : "\(n) layers")"
    }

    /// Under it: "In BUas · mild, feels 12°".
    static func changeDetail(place: String, gradeName: String, feels: Int) -> String {
        "In \(place) · \(gradeName.prefix(1).lowercased() + gradeName.dropFirst()), feels \(feels)°"
    }

    /// A wet stretch: "Rain until 18:00 · 70%".
    static func rainTitle(to: Date, chance: Int, clock: (Date) -> String) -> String {
        "Rain until \(clock(to))\(chance > 0 ? " · \(chance)%" : "")"
    }

    /// Under it: "In BUas · raincoat on the way", or "for later" when it starts after you get there.
    static func rainDetail(place: String, afterArrival: Bool) -> String {
        "In \(place) · raincoat \(afterArrival ? "for later" : "on the way")"
    }

    // MARK: where it applies

    /// "Here in Veghel until about 08:30, then BUas"; "BUas, all day" (there from the start), "Here in Veghel, all
    /// day" (not there before the day ends). `here` is "where you are" when it isn't one of your places.
    static func whereLine(here: String, there: String, arrive: Date, hereHours: Bool, thereHours: Bool,
                          clock: (Date) -> String) -> String {
        let h = here == "where you are" || here.isEmpty ? "Here" : "Here in \(here)"
        switch (hereHours, thereHours) {
        case (true, true): return "\(h) until about \(clock(arrive)), then \(there)"
        case (false, true): return "\(there), all day"
        default: return "\(h), all day"
        }
    }

    // MARK: an hour

    /// The sky, from the WMO weather code (as `WeatherHour.symbol`), for VoiceOver.
    static func sky(code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1, 2: return "partly cloudy"
        case 3: return "cloudy"
        case 45, 48: return "fog"
        case 51...57: return "drizzle"
        case 65, 67, 82: return "heavy rain"
        case 61...67, 80...82: return "rain"
        case 71...77, 85, 86: return "snow"
        case 95...99: return "thunderstorm"
        default: return "cloudy"
        }
    }

    /// An hour's cell as VoiceOver says it: "16:00, rain, 9 degrees, feels like 6, rain 70%".
    static func hourSpoken(time: String, code: Int, temp: Int, feels: Int, wet: Bool, chance: Int) -> String {
        "\(time), \(sky(code: code)), \(degrees(temp)), feels like \(feels)"
            + (wet ? (chance > 0 ? ", rain \(chance)%" : ", rain expected") : "")
    }
}
