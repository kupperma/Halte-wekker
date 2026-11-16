import Foundation

/// One of your places: Home, School, or one you pinned. Plain values (no CoreLocation), so it can be tested.
struct SavedPlace: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case home, school, custom }
    var id: String
    var name: String
    var kind: Kind
    var lat: Double
    var lon: Double
    /// Transitous stop ids to plan to (empty: the coordinate).
    var stopIds: [String]

    init(id: String, name: String, kind: Kind, lat: Double, lon: Double, stopIds: [String] = []) {
        self.id = id; self.name = name; self.kind = kind; self.lat = lat; self.lon = lon; self.stopIds = stopIds
    }

    // Postel: an older or odd copy still reads (an unknown kind is a pinned place, missing stops are none).
    enum CodingKeys: String, CodingKey { case id, name, kind, lat, lon, stopIds }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .custom
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        stopIds = (try? c.decode([String].self, forKey: .stopIds)) ?? []
    }

    var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    /// The SF Symbol for its chip.
    var symbol: String {
        switch kind {
        case .home: return "house.fill"
        case .school: return "graduationcap.fill"
        case .custom: return "mappin"
        }
    }
}

/// The rules of the places list: seeding it once, reading it back, the order of the quick chips and their labels.
enum PlacesLogic {
    static let storageKey = "places.v1"

    /// The first list, from today's defaults (passed in, so nothing here names a place).
    static func seed(home: SavedPlace, school: SavedPlace) -> [SavedPlace] {
        var h = home, s = school
        h.kind = .home; s.kind = .school
        return [h, s]
    }

    /// The saved list, or nil when there is none or it can't be read.
    static func decode(_ data: Data?) -> [SavedPlace]? {
        guard let data, let list = try? JSONDecoder().decode([SavedPlace].self, from: data) else { return nil }
        return list
    }

    static func encode(_ list: [SavedPlace]) -> Data? { try? JSONEncoder().encode(list) }

    /// What to show: the saved list made whole. One Home and one School always exist (a missing one comes back from the
    /// seed, a second one becomes a pinned place); ids are unique; nothing saved: the seed.
    static func load(_ data: Data?, seed: [SavedPlace]) -> [SavedPlace] {
        guard var list = decode(data), !list.isEmpty else { return seed }
        var seenIds = Set<String>(), out: [SavedPlace] = []
        var haveHome = false, haveSchool = false
        for var p in list {
            guard seenIds.insert(p.id).inserted, p.lat.isFinite, p.lon.isFinite else { continue }
            if p.kind == .home { if haveHome { p.kind = .custom } else { haveHome = true } }
            if p.kind == .school { if haveSchool { p.kind = .custom } else { haveSchool = true } }
            out.append(p)
        }
        list = out
        if !haveSchool, let s = seed.first(where: { $0.kind == .school }) { list.insert(s, at: 0) }
        if !haveHome, let h = seed.first(where: { $0.kind == .home }) { list.insert(h, at: 0) }
        return list
    }

    /// The quick chips: Home, School, then your pinned places in your order (at most `max` in all).
    static func chips(_ list: [SavedPlace], max: Int = 6) -> [SavedPlace] {
        let home = list.filter { $0.kind == .home }, school = list.filter { $0.kind == .school }
        return Array((home + school + list.filter { $0.kind == .custom }).prefix(max))
    }

    /// Minutes from now until a trip gets there (nil: no trip, or it's in the past).
    static func minutesNow(arrival: Date?, now: Date) -> Int? {
        guard let a = arrival, a > now else { return nil }
        return Int((a.timeIntervalSince(now) / 60).rounded())
    }

    /// "Home · 44 min", "BUas · 1 h 05", or just the name.
    static func chipLabel(_ name: String, minutes: Int?) -> String {
        guard let m = minutes, m >= 0 else { return name }
        if m >= 60 { return "\(name) · \(m / 60) h \(String(format: "%02d", m % 60))" }
        return "\(name) · \(m) min"
    }

    /// A new id for a pinned place, not one already in the list.
    static func newId(_ list: [SavedPlace], seed: String) -> String {
        let ids = Set(list.map(\.id))
        var n = 0, id = "p-\(seed)"
        while ids.contains(id) { n += 1; id = "p-\(seed)-\(n)" }
        return id
    }

    /// Moves a place in the list (the chips follow its order).
    static func move(_ list: [SavedPlace], from: Int, to: Int) -> [SavedPlace] {
        guard list.indices.contains(from), to >= 0, to <= list.count else { return list }
        var l = list
        let p = l.remove(at: from)
        l.insert(p, at: min(to > from ? to - 1 : to, l.count))
        return l
    }

    /// Removes a pinned place (Home and School stay: they can be changed, not removed).
    static func remove(_ list: [SavedPlace], id: String) -> [SavedPlace] {
        list.filter { $0.id != id || $0.kind != .custom }
    }
}
