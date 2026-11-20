import AppIntents
import Foundation

/// 0.37: a stop or station, for the widget's settings and for Siri and Shortcuts ("Wake me at a stop"). Its id holds
/// everything about it (`StopBoardCore.encode`), so the widget can read it back without the app's data (no App Group).
/// Found by Transitous's stop search as you type.
struct StopEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Stop"
    static var defaultQuery = StopEntityQuery()

    let id: String
    let stop: StopBoardCore.Stop

    init(_ s: StopBoardCore.Stop) {
        stop = s
        id = StopBoardCore.encode(s)
    }

    var displayRepresentation: DisplayRepresentation {
        if stop.town.isEmpty || stop.name.localizedCaseInsensitiveContains(stop.town) {
            let kind: LocalizedStringResource = stop.rail ? "Station" : "Stop"
            return DisplayRepresentation(title: "\(stop.name)", subtitle: kind)
        }
        return DisplayRepresentation(title: "\(stop.name)", subtitle: "\(stop.town)")
    }
}

struct StopEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [String]) async throws -> [StopEntity] {
        identifiers.compactMap { StopBoardCore.decode($0).map(StopEntity.init) }
    }

    func entities(matching string: String) async throws -> [StopEntity] {
        let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        return await StopBoardFetch.find(q).map(StopEntity.init)
    }

    func suggestedEntities() async throws -> [StopEntity] { [] }
}

/// Asking Transitous (the widget and Siri, each on its own: light, with a short time limit).
enum StopBoardFetch {
    private static func get(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        r.setValue(StopBoardCore.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Stops matching what's typed (in the Netherlands first: Transitous ranks by the text).
    static func find(_ text: String) async -> [StopBoardCore.Stop] {
        guard let d = await get(StopBoardCore.geocodeURL(text)) else { return [] }
        return StopBoardCore.parseGeocode(d)
    }

    /// The next departures from a stop (nil: no answer).
    static func departures(_ stopId: String, from: Date, n: Int = 12) async -> [StopBoardCore.Departure]? {
        guard let d = await get(StopBoardCore.stoptimesURL(stopId: stopId, from: from, n: n)) else { return nil }
        return StopBoardCore.parseStoptimes(d)
    }
}
