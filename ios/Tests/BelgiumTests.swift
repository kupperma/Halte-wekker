import XCTest

/// (0.42.17) Haltewekker in Belgium: which country a stop is in, where a train's live data comes from (NS or iRail),
/// the relay's `/be/…` answers read and a Belgian train's iRail data laid over its Transitous trip, against
/// docs/belgium-vectors.json (the vectors Android checks too).
final class BelgiumTests: XCTestCase {
    private var v: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = Bundle(for: Self.self).url(forResource: "belgium-vectors", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/belgium-vectors.json")
        let d = try Data(contentsOf: url)
        v = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    private var stations: [NSStation] {
        let url = Bundle(for: Self.self).url(forResource: NSCodes.fileName, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../App/NSStations.json")
        return NSCodes.decode(try? Data(contentsOf: url))
    }

    private func cases(_ k: String) throws -> [[String: Any]] { try XCTUnwrap(v[k] as? [[String: Any]], k) }
    private func s(_ c: [String: Any], _ k: String) -> String { (c[k] as? String) ?? "" }

    func test_country() throws {
        for c in try cases("country") {
            let got: Country = Country.of(id: s(c, "id"), lat: c["lat"] as? Double, lon: c["lon"] as? Double)
            let want: String = s(c, "want")
            XCTAssertEqual(got == .other ? "other" : got.rawValue, want, "\(c)")
        }
        for c in try cases("uic") { XCTAssertEqual(Country.uic(s(c, "id")), c["want"] as? String, s(c, "id")) }
        for c in try cases("belgianTrip") { XCTAssertEqual(Country.belgianTrip(s(c, "tripId")), c["want"] as? Bool, s(c, "tripId")) }
        for c in try cases("onlyBelgium") {
            let stops: [(id: String, lat: Double?, lon: Double?)] = ((c["stops"] as? [[String: Any]]) ?? []).map { x in
                (id: (x["id"] as? String) ?? "", lat: x["lat"] as? Double, lon: x["lon"] as? Double)
            }
            XCTAssertEqual(Country.onlyBelgium(stops), c["want"] as? Bool, "\(c)")
        }
    }

    /// No Dutch station is taken for a Belgian one by where it is: the Netherlands stays as it was.
    func test_everyNSStationStaysDutch() {
        let l = stations
        XCTAssertGreaterThan(l.count, 350)
        for st in l {
            XCTAssertFalse(Country.inBelgium(lat: st.lat, lon: st.lon), "\(st.code) \(st.name)")
            XCTAssertEqual(Country.of(id: "", lat: st.lat, lon: st.lon), .nl, st.code)
        }
    }

    func test_railSourceAndNSCodes() throws {
        let i = NSCodes.Index(stations)
        for c in try cases("railSource") {
            let got: String? = Country.railSource(id: s(c, "id"), name: s(c, "name"), lat: c["lat"] as? Double, lon: c["lon"] as? Double) { id, n in
                NSCodes.code(forStopId: id, name: n, in: i)
            }
            XCTAssertEqual(got, c["want"] as? String, "\(c)")
        }
        for c in try cases("nsCode") {
            XCTAssertEqual(NSCodes.code(forStopId: s(c, "id"), name: s(c, "name"), in: i), c["want"] as? String, "\(c)")
        }
        XCTAssertEqual(Country.liveboardPath("be:8821006"), "/be/liveboard?id=8821006")
        XCTAssertEqual(Country.liveboardPath("be:Brussel-Zuid"), "/be/liveboard?station=Brussel-Zuid")
        XCTAssertEqual(Country.liveboardPath("be:Liège-Guillemins"), "/be/liveboard?station=Li%C3%A8ge-Guillemins")
        XCTAssertNil(Country.liveboardPath("BD"))
    }

    func test_liveboardAndComposition() throws {
        let lb = try XCTUnwrap(v["liveboard"] as? [String: Any])
        let body = try JSONSerialization.data(withJSONObject: try XCTUnwrap(lb["body"]))
        let got = try XCTUnwrap(IRail.departures(body))
        let want = try XCTUnwrap(lb["want"] as? [[String: Any]])
        XCTAssertEqual(got.count, want.count)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.num, s(w, "num"))
            XCTAssertEqual(g.planned.map(IRail.iso), w["planned"] as? String, g.num)
            XCTAssertEqual(g.actual.map(IRail.iso), w["actual"] as? String, g.num)
            XCTAssertEqual(g.track, s(w, "track"), g.num)
            XCTAssertEqual(g.plannedTrack, s(w, "plannedTrack"), g.num)
            XCTAssertEqual(g.changed, w["changed"] as? Bool, g.num)
            XCTAssertEqual(g.cancelled, w["cancelled"] as? Bool, g.num)
            XCTAssertEqual(g.crowd, (w["crowd"] as? NSNumber)?.intValue, g.num)
        }
        XCTAssertNil(IRail.departures(Data("nope".utf8)))
        XCTAssertNil(IRail.departures(nil))
        let comp = try XCTUnwrap(v["composition"] as? [String: Any])
        let c = try XCTUnwrap(IRail.composition(try JSONSerialization.data(withJSONObject: try XCTUnwrap(comp["body"]))))
        XCTAssertEqual(c.cars, (comp["cars"] as? NSNumber)?.intValue)
        XCTAssertEqual(c.seats, (comp["seats"] as? NSNumber)?.intValue)
        XCTAssertNil(IRail.composition(Data("{\"cars\":0}".utf8)))
    }

    func test_vehicleQuery() throws {
        for c in try cases("vehicleQuery") {
            XCTAssertEqual(IRail.vehiclePath(tripId: s(c, "tripId"), num: s(c, "num")), c["want"] as? String, "\(c)")
        }
    }

    private func stops(_ trip: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for l in (trip["legs"] as? [[String: Any]]) ?? [] {
            if let f = l["from"] as? [String: Any] { out.append(f) }
            out += (l["intermediateStops"] as? [[String: Any]]) ?? []
            if let t = l["to"] as? [String: Any] { out.append(t) }
        }
        return out
    }

    func test_overlay() throws {
        for c in try cases("overlay") {
            let trip = try XCTUnwrap(c["trip"] as? [String: Any])
            let vehicle = try XCTUnwrap(c["vehicle"] as? [String: Any])
            XCTAssertEqual(IRail.trainNumber(trip), "9235")
            var veh: [String: Any] = vehicle
            veh["num"] = s(c, "num")
            let out: [String: Any] = IRail.overlay(trip: trip, vehicle: veh)
            let leg = try XCTUnwrap((out["legs"] as? [[String: Any]])?.first)
            XCTAssertEqual(leg["realTime"] as? Bool, c["realTime"] as? Bool, s(c, "why"))
            if (c["same"] as? Bool) == true {
                XCTAssertEqual(try JSONSerialization.data(withJSONObject: out, options: .sortedKeys),
                               try JSONSerialization.data(withJSONObject: trip, options: .sortedKeys), s(c, "why"))
                continue
            }
            let want = try XCTUnwrap(c["want"] as? [[String: Any]])
            let got = stops(out)
            XCTAssertEqual(got.count, want.count)
            for (g, w) in zip(got, want) {
                let n: String = s(w, "name")
                XCTAssertEqual(g["name"] as? String, n)
                XCTAssertEqual(g["track"] as? String, w["track"] as? String, n)
                XCTAssertEqual(g["scheduledTrack"] as? String, w["scheduledTrack"] as? String, n)
                XCTAssertEqual(g["arrival"] as? String, w["arrival"] as? String, n)
                XCTAssertEqual(g["departure"] as? String, w["departure"] as? String, n)
                XCTAssertEqual((g["cancelled"] as? Bool) ?? false, w["cancelled"] as? Bool, n)
            }
            // on the bytes too, as the app keeps the answer
            let d = try XCTUnwrap(IRail.overlay(tripData: try JSONSerialization.data(withJSONObject: trip),
                                                vehicleData: try JSONSerialization.data(withJSONObject: veh)))
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: d) as? [String: Any])
        }
        // a Dutch train: nothing to ask iRail
        let nl: [String: Any] = ["legs": [["mode": "REGIONAL_RAIL", "tripShortName": "3561",
                                           "from": ["stopId": "de-DELFI_000008400131", "lat": 51.5955, "lon": 4.78],
                                           "to": ["stopId": "de-DELFI_000008400319", "lat": 51.6905, "lon": 5.2936]]]]
        XCTAssertNil(IRail.trainNumber(nl))
        let bus: [String: Any] = ["legs": [["mode": "BUS", "tripShortName": "12",
                                            "from": ["stopId": "be-delijn_1", "lat": 51.2, "lon": 4.4]]]]
        XCTAssertNil(IRail.trainNumber(bus))
        XCTAssertNil(IRail.overlay(tripData: Data("x".utf8), vehicleData: nil))
    }

    func test_exitSideAsksBelgianNamesEscaped() {
        let a = DoorSide.Ask(station: "NOORDERKEMPEN (BRECHT)", track: "1", from: GeoPoint(lat: 51.2172, lon: 4.4211),
                             at: GeoPoint(lat: 51.3568, lon: 4.6322))
        XCTAssertEqual(a.query, "station=NOORDERKEMPEN%20%28BRECHT%29&track=1&from=51.2172,4.4211&at=51.3568,4.6322")
        let b = DoorSide.Ask(station: "BD", track: "4", from: GeoPoint(lat: 51.56, lon: 4.98), at: GeoPoint(lat: 51.5955, lon: 4.78))
        XCTAssertTrue(b.query.hasPrefix("station=BD&track=4&"))
    }
}
