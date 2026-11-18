import Foundation

/// A school in the bundled list (`Schools.json`, made by `tools/schools.js`: every campus geocoded by Transitous).
struct SchoolEntry: Codable, Equatable, Identifiable, Sendable {
    struct Campus: Codable, Equatable, Identifiable, Sendable {
        var name: String
        var city: String
        var lat: Double
        var lon: Double
        var id: String { "\(name)|\(city)" }
        var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
        /// "Breda", "Tilburg", "Eindhoven, De Lismortel"
        var label: String { name == city || name.hasPrefix(city) ? name : "\(name), \(city)" }
    }

    var id: String
    var name: String
    /// How the app says it in a sentence: "At Fontys 08:41".
    var short: String
    var aliases: [String]
    var campuses: [Campus]

    init(id: String, name: String, short: String, aliases: [String] = [], campuses: [Campus]) {
        self.id = id; self.name = name; self.short = short; self.aliases = aliases; self.campuses = campuses
    }

    // Postel, as `SavedPlace`: no short name is the name, no aliases are none; a campus that doesn't read is left out.
    enum CodingKeys: String, CodingKey { case id, name, short, aliases, campuses }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        short = (try? c.decode(String.self, forKey: .short)) ?? name
        aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
        campuses = ((try? c.decode([Lenient<Campus>].self, forKey: .campuses)) ?? []).compactMap(\.value)
            .filter { $0.lat.isFinite && $0.lon.isFinite }
    }

    /// Reads an element of a list, or nothing (so one bad campus doesn't lose the school).
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}

/// The bundled schools and the search over them.
enum SchoolCatalog {
    static let fileName = "Schools"

    /// The list in a `Schools.json` (schools without a campus are left out; nothing readable: none).
    static func decode(_ data: Data?) -> [SchoolEntry] {
        guard let data, let l = try? JSONDecoder().decode([Lenient].self, from: data) else { return [] }
        return l.compactMap(\.value).filter { !$0.campuses.isEmpty }
    }

    private struct Lenient: Decodable {
        let value: SchoolEntry?
        init(from decoder: Decoder) throws { value = try? SchoolEntry(from: decoder) }
    }

    /// The list that comes with the app.
    static func load(bundle: Bundle = .main) -> [SchoolEntry] {
        decode(bundle.url(forResource: fileName, withExtension: "json").flatMap { try? Data(contentsOf: $0) })
    }

    /// A school that matches a search, with the campuses the search points at (all of them when it names none).
    struct Hit: Equatable, Identifiable, Sendable {
        var entry: SchoolEntry
        var campuses: [SchoolEntry.Campus]
        var id: String { entry.id }
        /// More than one campus to choose from.
        var needsCampusPick: Bool { campuses.count > 1 }
    }

    /// Lower case, no accents, and the punctuation as spaces (a "/" stays: "TU/e"; the ’ of ’s-Hertogenbosch goes).
    static func words(_ s: String) -> [String] {
        let f = SchoolHints.fold(s)
        let kept = f.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "/" ? Character($0) : " " }
        return String(kept).split(separator: " ").map(String.init)
    }

    /// Every word of the search must be in the school (its name, short name or another name) or in a campus (its name
    /// or town): "tue", "Fontys Venlo", "inholland". Words that only a campus has narrow the campuses. The best
    /// matches first: the short name or another name exactly, then one that starts with the search, then the rest.
    static func search(_ query: String, in list: [SchoolEntry], limit: Int = 12) -> [Hit] {
        let q = words(query)
        guard !q.isEmpty else { return [] }
        let whole = q.joined(separator: " ")
        var scored: [(Int, Hit)] = []
        for e in list {
            let own = words(([e.name, e.short] + e.aliases).joined(separator: " "))
            let names = ([e.short] + e.aliases).map { words($0).joined(separator: " ") }
            var campuses = e.campuses
            var ok = true
            for w in q where !own.contains(where: { $0.hasPrefix(w) }) {
                let near = campuses.filter { c in words(c.name + " " + c.city).contains { $0.hasPrefix(w) } }
                if near.isEmpty { ok = false; break }
                campuses = near
            }
            guard ok else { continue }
            let full = words(e.name).joined(separator: " ")
            let score = names.contains(whole) ? 0 : (full.hasPrefix(whole) || names.contains { $0.hasPrefix(whole) }) ? 1 : 2
            scored.append((score, Hit(entry: e, campuses: campuses)))
        }
        return scored.sorted { a, b in a.0 != b.0 ? a.0 < b.0 : a.1.entry.name < b.1.entry.name }.prefix(limit).map(\.1)
    }

    /// The Netherlands, roughly (with a margin): every campus is inside it.
    static func inNetherlands(_ p: GeoPoint) -> Bool { (50.70...53.60).contains(p.lat) && (3.30...7.25).contains(p.lon) }
}
