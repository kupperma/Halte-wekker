import XCTest

final class NearPickTests: XCTestCase {
    private struct S: Equatable { let id: String; let name: String; let rail: Bool }

    /// A bus station's 17 platforms (two names) and a station: one board per name, the nearest of each, and the station.
    func test_onePerName() {
        var near: [S] = []                                        // nearest first, as Transitous's stops come
        for i in 0..<17 { near.append(S(id: "p\(i)", name: i % 3 == 0 ? "Veghel, Bolkenplein" : "Veghel, Busstation", rail: false)) }
        near.insert(S(id: "rail", name: "Veghel station", rail: true), at: 5)
        near.append(S(id: "far", name: "Veghel, Markt", rail: false))
        let kept = NearPick.onePerName(near, name: \.name, rail: \.rail)
        XCTAssertEqual(kept.map(\.id), ["p0", "p1", "rail"])
        XCTAssertEqual(NearPick.onePerName([S](), name: \.name, rail: \.rail), [])
        XCTAssertEqual(NearPick.onePerName([S(id: "a", name: "A", rail: false), S(id: "a2", name: "A", rail: false)], name: \.name, rail: \.rail).map(\.id), ["a"])
        XCTAssertEqual(NearPick.onePerName([S(id: "r", name: "R", rail: true), S(id: "r2", name: "R2", rail: true)], name: \.name, rail: \.rail).map(\.id), ["r"])
    }

    /// A saved board asked of every platform: its rows go with the kept stop of their name (and a name that isn't
    /// kept any more has none).
    func test_keptStop() {
        let saved = [(id: "p0", name: "B"), (id: "p1", name: "A"), (id: "p2", name: "A"), (id: "p3", name: "B"), (id: "rail", name: "S"), (id: "x", name: "X")]
        let kept = [(id: "p1", name: "A"), (id: "p0", name: "B"), (id: "rail", name: "S")]
        let to = NearPick.keptStop(saved, kept: kept)
        XCTAssertEqual(to, ["p0": "p0", "p1": "p1", "p2": "p1", "p3": "p0", "rail": "rail"])
    }

    /// A watch made on a platform the near boards no longer ask: the row under its name (another platform's id) shows
    /// its bell on (isWatched), and tapping it finds that watch to stop (toggle), not a second one.
    func test_watchByStopName() {
        let watches = [(stopId: "p7", stopName: "Veghel, Busstation", line: "305", headsign: "Eindhoven"),
                       (stopId: "p2", stopName: "Veghel, Busstation", line: "306", headsign: "Den Bosch"),
                       (stopId: "q1", stopName: "Uden, Busstation", line: "305", headsign: "Eindhoven")]
        // the same id
        XCTAssertEqual(NearPick.watchIndex(watches, stopId: "p7", stopName: "Veghel, Busstation", line: "305", headsign: "Eindhoven"), 0)
        // another platform of the name: the same watch
        XCTAssertEqual(NearPick.watchIndex(watches, stopId: "p0", stopName: "Veghel, Busstation", line: "305", headsign: "Eindhoven"), 0)
        XCTAssertEqual(NearPick.watchIndex(watches, stopId: "p0", stopName: "Veghel, Busstation", line: "306", headsign: "Den Bosch"), 1)
        // the id first, then the name
        XCTAssertEqual(NearPick.watchIndex(watches, stopId: "q1", stopName: "Veghel, Busstation", line: "305", headsign: "Eindhoven"), 2)
        // another line, another direction, another name, or no name: none
        XCTAssertNil(NearPick.watchIndex(watches, stopId: "p0", stopName: "Veghel, Busstation", line: "305", headsign: "Den Bosch"))
        XCTAssertNil(NearPick.watchIndex(watches, stopId: "p0", stopName: "Veghel, Busstation", line: "301", headsign: "Eindhoven"))
        XCTAssertNil(NearPick.watchIndex(watches, stopId: "p0", stopName: "Veghel, Markt", line: "305", headsign: "Eindhoven"))
        XCTAssertNil(NearPick.watchIndex(watches, stopId: "p0", stopName: nil, line: "305", headsign: "Eindhoven"))
        XCTAssertNil(NearPick.watchIndex(watches, stopId: "p0", stopName: "", line: "305", headsign: "Eindhoven"))
        XCTAssertNil(NearPick.watchIndex([], stopId: "p0", stopName: "Veghel, Busstation", line: "305", headsign: "Eindhoven"))
    }
}
