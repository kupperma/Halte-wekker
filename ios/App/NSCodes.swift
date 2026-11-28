import Foundation

/// An NS station from the bundled list (`NSStations.json`, made by `tools/ns-stations.js` from Rijden de Treinen's open
/// station list, itself NS's data): its code for the NS API ("EHV"), its UIC number, its names and where it is.
struct NSStation: Codable, Equatable, Sendable {
    var code: String
    var uic: String
    /// The full name: "Eindhoven Centraal".
    var name: String
    /// Its shorter names: "Eindhoven C.", "Eindhovn C".
    var names: [String]
    var lat: Double
    var lon: Double

    var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }

    // Postel: a station without other names still reads.
    enum CodingKeys: String, CodingKey { case code, uic, name, names, lat, lon }
    init(code: String, uic: String, name: String, names: [String] = [], lat: Double, lon: Double) {
        self.code = code; self.uic = uic; self.name = name; self.names = names; self.lat = lat; self.lon = lon
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        uic = (try? c.decode(String.self, forKey: .uic)) ?? ""
        name = try c.decode(String.self, forKey: .name)
        names = (try? c.decode([String].self, forKey: .names)) ?? []
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
    }
}

/// Which NS station a stop is, so NS's platforms, crowding and train size show at every station (0.24; before, only
/// at Eindhoven, Den Bosch and Breda). A DELFI stop id carries the station's UIC number (`de-DELFI_000008400319` is
/// 8400319, 's-Hertogenbosch); any other id (OpenOV's, a coordinate) goes by the stop's name instead.
enum NSCodes {
    static let fileName = "NSStations"

    /// The stations, looked up by UIC number and by name.
    struct Index: Sendable {
        var stations: [NSStation]
        var byUIC: [String: String] = [:]
        var byName: [String: String] = [:]

        init(_ stations: [NSStation]) {
            self.stations = stations
            for s in stations {
                if !s.uic.isEmpty, byUIC[s.uic] == nil { byUIC[s.uic] = s.code }
                // (the full name wins over a short one another station might share)
                for n in [s.name] + s.names {
                    let k = NSCodes.fold(n)
                    if !k.isEmpty, byName[k] == nil { byName[k] = s.code }
                }
            }
        }

        func station(_ code: String) -> NSStation? { stations.first { $0.code == code } }
    }

    /// The list in an `NSStations.json` (nothing readable: none).
    static func decode(_ data: Data?) -> [NSStation] {
        guard let data, let l = try? JSONDecoder().decode([NSStation].self, from: data) else { return [] }
        return l
    }

    static func load(bundle: Bundle = .main) -> [NSStation] {
        decode(bundle.url(forResource: fileName, withExtension: "json").flatMap { try? Data(contentsOf: $0) })
    }

    /// The bundled list, read once.
    static let shared = Index(load())

    /// The UIC number in a DELFI stop id: the 7 digits of a Dutch station (84…) after the zeros it's padded with, at the
    /// start of the id's last part. `de-DELFI_000008400319` → `8400319`; anything else → nil.
    /// (0.42.17) Also an SNCB id's: `be-sncb_8400131` (Breda in SNCB's feed) → `8400131` (`Country.uic`).
    static func uic(fromStopId id: String) -> String? {
        guard let u = Country.uic(id), u.hasPrefix("84") else { return nil }
        return u
    }

    /// (0.42.17) A stop plainly outside the Netherlands by its id (a Belgian feed's, or a station with a foreign UIC):
    /// never an NS station by its name ("Essen" in Belgium is no Dutch station).
    static func notDutch(_ id: String) -> Bool {
        if let u = Country.uic(id) { return !u.hasPrefix("84") }
        return id.hasPrefix("be-")
    }

    /// A name as the lookup compares it: lower case, no accents, every other mark a space ("’s-Hertogenbosch" and
    /// "'s-Hertogenbosch" are both "s hertogenbosch").
    static func fold(_ s: String) -> String {
        let plain = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = "", space = false
        for ch in plain.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) && ch.isASCII {
                if space && !out.isEmpty { out.append(" ") }
                space = false
                out.unicodeScalars.append(ch)
            } else {
                space = true
            }
        }
        return out
    }

    /// The station's code by its name: exactly one of NS's names, or that name with "Centraal" or "station" after it
    /// ("’s-Hertogenbosch Centraal", "Breda station"). A bus stop ("Breda, Centraal Station") is no station.
    static func code(forName name: String, in index: Index) -> String? {
        let k = fold(name)
        guard !k.isEmpty else { return nil }
        if let c = index.byName[k] { return c }
        for suffix in [" centraal", " station", " centraal station"] where k.hasSuffix(suffix) {
            if name.contains(",") { return nil }            // ("Town, Stop": a bus stop's name)
            if let c = index.byName[String(k.dropLast(suffix.count))] { return c }
        }
        return nil
    }

    /// The station a stop is: by the UIC number in its id, else by its name. Nil: not an NS station (as far as the
    /// list knows).
    static func code(forStopId id: String, name: String?, in index: Index = NSCodes.shared) -> String? {
        if let u = uic(fromStopId: id), let c = index.byUIC[u] { return c }
        if notDutch(id) { return nil }
        return name.flatMap { code(forName: $0, in: index) }
    }

    /// A place with several stop ids (a station's platforms): the first that's a station, else by the name.
    static func code(forStopIds ids: [String], name: String?, in index: Index = NSCodes.shared) -> String? {
        for id in ids { if let u = uic(fromStopId: id), let c = index.byUIC[u] { return c } }
        if !ids.isEmpty, ids.allSatisfy({ notDutch($0) }) { return nil }
        return name.flatMap { code(forName: $0, in: index) }
    }
}
