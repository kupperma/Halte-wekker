import XCTest

/// Friends 0.31.1: 1st class in the seat picker, from real NS compositions (the relay's `/ns/train`, 19 November 2026,
/// trimmed to what's read) and the table read off NS's drawings (`SeatClass`; docs/superpowers/specs/
/// 2026-11-18-friends-design.md, "As built (0.31.1)").
final class SeatClassTests: XCTestCase {
    // MARK: real compositions

    /// IC 3078 at Utrecht: a VIRMm1 VI and a VIRMm1 IV, the front on the left.
    static let ic3078 = #"{"ritnummer":3078,"station":"UT","type":"VIRM","materieeldelen":[{"type":"VIRMm1 VI","afbeelding":"https://vt.ns-mlab.nl/v1/images/virmm1_6.png","breedte":3376,"zitplaatsen":{"zitplaatsEersteKlas":120,"zitplaatsTweedeKlas":425},"bakken":[{},{},{},{},{},{}]},{"type":"VIRMm1 IV","afbeelding":"https://vt.ns-mlab.nl/v1/images/virmm1_4.png","breedte":2259,"zitplaatsen":{"zitplaatsEersteKlas":80,"zitplaatsTweedeKlas":282},"bakken":[{},{},{},{}]}],"lengte":10,"lengteInPixels":5635,"rijrichting":"LINKS"}"#
    /// IC 2280 at Rotterdam: an old VIRM IV and a VIRMm1 VI, no direction.
    static let ic2280 = #"{"ritnummer":2280,"station":"RTD","type":"VIRM","materieeldelen":[{"type":"VIRM IV","afbeelding":"https://vt.ns-mlab.nl/v1/images/virm_4.png","breedte":2259,"zitplaatsen":{"zitplaatsEersteKlas":64,"zitplaatsTweedeKlas":310},"bakken":[{},{},{},{}]},{"type":"VIRMm1 VI","afbeelding":"https://vt.ns-mlab.nl/v1/images/virmm1_6.png","breedte":3376,"zitplaatsen":{"zitplaatsEersteKlas":120,"zitplaatsTweedeKlas":425},"bakken":[{},{},{},{},{},{}]}],"lengte":10,"lengteInPixels":5635}"#
    /// SPR 4982 at Utrecht: an SLT 4 and an SLT 6, the front on the left.
    static let spr4982 = #"{"ritnummer":4982,"station":"UT","type":"SLT","materieeldelen":[{"type":"SLT 4","afbeelding":"https://vt.ns-mlab.nl/v1/images/slt_4.png","breedte":1446,"zitplaatsen":{"zitplaatsEersteKlas":20,"zitplaatsTweedeKlas":160},"bakken":[{},{},{},{}]},{"type":"SLT 6","afbeelding":"https://vt.ns-mlab.nl/v1/images/slt_6.png","breedte":2094,"zitplaatsen":{"zitplaatsEersteKlas":40,"zitplaatsTweedeKlas":220},"bakken":[{},{},{},{},{},{}]}],"lengte":10,"lengteInPixels":3540,"rijrichting":"LINKS"}"#
    /// IC 678 at Utrecht: an ICM 3 (the Koploper), the front on the right.
    static let ic678 = #"{"ritnummer":678,"station":"UT","type":"ICM","materieeldelen":[{"type":"ICM 3","afbeelding":"https://vt.ns-mlab.nl/v1/images/icm_3.png","breedte":1662,"zitplaatsen":{"zitplaatsEersteKlas":35,"zitplaatsTweedeKlas":163},"bakken":[{},{},{}]}],"lengte":3,"lengteInPixels":1662,"rijrichting":"RECHTS"}"#
    /// IC 2685 at Amsterdam: two ICM 4s, each with a coach that's 1st class all through.
    static let ic2685 = #"{"ritnummer":2685,"station":"ASD","type":"ICM","materieeldelen":[{"type":"ICM 4","afbeelding":"https://vt.ns-mlab.nl/v1/images/icm_4.png","breedte":2218,"zitplaatsen":{"zitplaatsEersteKlas":56,"zitplaatsTweedeKlas":211},"bakken":[{},{},{},{}]},{"type":"ICM 4","afbeelding":"https://vt.ns-mlab.nl/v1/images/icm_4.png","breedte":2218,"zitplaatsen":{"zitplaatsEersteKlas":56,"zitplaatsTweedeKlas":211},"bakken":[{},{},{},{}]}],"lengte":8,"lengteInPixels":4436}"#
    /// IC 1783 at Utrecht: a DDZ 4, no direction.
    static let ic1783 = #"{"ritnummer":1783,"station":"UT","type":"DDZ","materieeldelen":[{"type":"DDZ 4","afbeelding":"https://vt.ns-mlab.nl/v1/images/ddz_4.png","breedte":2111,"zitplaatsen":{"zitplaatsEersteKlas":67,"zitplaatsTweedeKlas":269},"bakken":[{},{},{},{}]}],"lengte":4,"lengteInPixels":2111}"#
    /// SPR 5683 at Utrecht: an SNG 3, the front on the right.
    static let spr5683 = #"{"ritnummer":5683,"station":"UT","type":"SNG","materieeldelen":[{"type":"SNG 3","afbeelding":"https://vt.ns-mlab.nl/v1/images/sng_3.png","breedte":1241,"zitplaatsen":{"zitplaatsEersteKlas":19,"zitplaatsTweedeKlas":125},"bakken":[{},{},{}]}],"lengte":3,"lengteInPixels":1241,"rijrichting":"RECHTS"}"#
    /// IC 1184 at Eindhoven: an ICNG 5, the front on the right.
    static let ic1184 = #"{"ritnummer":1184,"station":"EHV","type":"ICNG","materieeldelen":[{"type":"ICNG 5","afbeelding":"https://vt.ns-mlab.nl/v1/images/icng_5.png","breedte":2286,"zitplaatsen":{"zitplaatsEersteKlas":58,"zitplaatsTweedeKlas":194},"bakken":[{},{},{},{},{}]}],"lengte":5,"lengteInPixels":2286,"rijrichting":"RECHTS"}"#
    /// IC 9583 at Rotterdam: the Belgian-run ICNG-B 8.
    static let ic9583 = #"{"ritnummer":9583,"station":"RTD","type":"ICNG","materieeldelen":[{"type":"ICNG-B 8","afbeelding":"https://vt.ns-mlab.nl/v1/images/icng_B_8.png","breedte":3442,"zitplaatsen":{"zitplaatsEersteKlas":85,"zitplaatsTweedeKlas":322},"bakken":[{},{},{},{},{},{},{},{}]}],"lengte":8,"lengteInPixels":3442}"#
    /// ICE 120 at Utrecht: a drawing the table doesn't have.
    static let ice120 = #"{"ritnummer":120,"station":"UT","type":"ICE","materieeldelen":[{"type":"ICE-3NEO","afbeelding":"https://vt.ns-mlab.nl/v1/images/ice.png","breedte":4109,"zitplaatsen":{"zitplaatsEersteKlas":99,"zitplaatsTweedeKlas":340},"bakken":[{},{},{},{},{},{},{},{}]}],"lengte":8,"lengteInPixels":4109,"rijrichting":"LINKS"}"#
    /// Keolis 8581 at Zwolle: a Flirt with no 1st class at all.
    static let keolis8581 = #"{"ritnummer":8581,"station":"ZL","type":"Flirt","materieeldelen":[{"type":"Flirt 3 Keolis","afbeelding":"https://vt.ns-mlab.nl/v1/images/keolis_flirt3_blauwnet.png","breedte":1328,"zitplaatsen":{"zitplaatsEersteKlas":0,"zitplaatsTweedeKlas":171},"bakken":[{},{},{}]}],"lengte":3,"lengteInPixels":1328}"#

    /// The picker's train from a composition, as the app builds it.
    private func train(_ json: String, line: String = "IC") throws -> SeatMap.Train {
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let parts = SeatClass.parts(d)
        let rr = d["rijrichting"] as? String
        let dir: String? = rr == "LINKS" ? "left" : rr == "RECHTS" ? "right" : nil
        return SeatMap.train(units: SeatClass.units(parts), kinds: parts.map(\.type), totalCars: (d["lengte"] as? Int) ?? 0,
                             dir: dir, line: line, drawings: parts.map(\.image), firstSeats: parts.map(\.firstSeats))
    }

    private func kinds(_ t: SeatMap.Train) -> String {
        t.coaches.map { c in
            switch c.kind {
            case .first?: return "1"
            case .part?: return "p"
            case .second?: return "2"
            case nil: return "?"
            }
        }.joined()
    }

    func test_parts_readNSsAnswer() throws {
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Self.ic3078.utf8)) as? [String: Any])
        let p = SeatClass.parts(d)
        XCTAssertEqual(p, [SeatClass.Part(type: "VIRMm1 VI", image: "virmm1_6", width: 3376, cars: 6, firstSeats: 120),
                           SeatClass.Part(type: "VIRMm1 IV", image: "virmm1_4", width: 2259, cars: 4, firstSeats: 80)])
        let u = SeatClass.units(p)
        XCTAssertEqual(u.count, 2)
        XCTAssertEqual(u[1].x, 3376.0 / 5635.0, accuracy: 1e-9)
    }

    func test_realTrains_coachByCoach() throws {
        // drawn from the left: 2 = no 1st class, p = part of it, 1 = all 1st class, ? = not known
        XCTAssertEqual(kinds(try train(Self.ic3078)), "2p2pp22pp2")
        XCTAssertEqual(kinds(try train(Self.ic2280)), "2pp22p2pp2")
        XCTAssertEqual(kinds(try train(Self.spr4982, line: "SPR")), "p22pp2222p")
        XCTAssertEqual(kinds(try train(Self.ic678)), "2p2")
        XCTAssertEqual(kinds(try train(Self.ic2685)), "22122212")
        XCTAssertEqual(kinds(try train(Self.ic1783)), "p2p2")
        XCTAssertEqual(kinds(try train(Self.spr5683, line: "SPR")), "p22", "the SNG 3 has 1st class at one end only")
        XCTAssertEqual(kinds(try train(Self.ic1184)), "22pp2")
        XCTAssertEqual(kinds(try train(Self.ic9583)), "22pppp22")
        XCTAssertEqual(kinds(try train(Self.ice120)), "????????")
        XCTAssertEqual(kinds(try train(Self.keolis8581, line: "SPR")), "222", "NS counts no 1st-class seats")
    }

    func test_trainFlags() throws {
        let ice = try train(Self.ice120)
        XCTAssertFalse(ice.anyFirst)
        XCTAssertTrue(ice.firstUnknown)
        let ic = try train(Self.ic3078)
        XCTAssertTrue(ic.anyFirst)
        XCTAssertFalse(ic.firstUnknown)
        let k = try train(Self.keolis8581)
        XCTAssertFalse(k.anyFirst)
        XCTAssertFalse(k.firstUnknown)
        // the guess (no NS) knows no 1st class
        let guess = SeatMap.train(units: [], kinds: [], totalCars: 6, dir: nil, line: "IC")
        XCTAssertFalse(guess.anyFirst)
        XCTAssertTrue(guess.firstUnknown)
    }

    func test_windows_perDeck() throws {
        let t = try train(Self.ic3078)
        // the VIRMm1 IV's second coach (drawn 7): the upper deck's 1st class is shorter than the lower's
        let c = t.coaches[7]
        let s = try XCTUnwrap(c.first)
        XCTAssertEqual(SeatClass.runs(row: 0, double: true, sections: s), [6...7])
        XCTAssertEqual(SeatClass.runs(row: 1, double: true, sections: s), [5...7])
        // the Koploper's middle coach: one deck
        let icm = try train(Self.ic678).coaches[1]
        XCTAssertFalse(icm.double)
        XCTAssertEqual(SeatClass.runs(row: 0, double: false, sections: try XCTUnwrap(icm.first)), [5...9])
        // the DDZ behind its cab
        let ddz = try train(Self.ic1783).coaches[0]
        XCTAssertEqual(SeatClass.runs(row: 0, double: true, sections: try XCTUnwrap(ddz.first)), [2...5])
        XCTAssertEqual(SeatClass.runs(row: 1, double: true, sections: try XCTUnwrap(ddz.first)), [2...3])
        // the old VIRM IV's second coach: below only
        let virm = try train(Self.ic2280).coaches[1]
        XCTAssertEqual(SeatClass.runs(row: 0, double: true, sections: try XCTUnwrap(virm.first)), [])
        XCTAssertEqual(SeatClass.runs(row: 1, double: true, sections: try XCTUnwrap(virm.first)), [5...7])
    }

    func test_yourSeat_isFirst_andItsWords() throws {
        let t = try train(Self.ic3078)
        // coach 2 from the front (the front on the left: drawn 1), upper deck, window 5 from the back (drawn 6)
        let c = TravelState.Coach(n: 2, of: 10, front: true, at: "UT", seat: .init(deck: "upper", w: 5, of: 11))
        XCTAssertTrue(SeatMap.isFirst(c, in: t, station: "UT"))
        XCTAssertEqual(SeatMap.label(c, firstClass: true), "Coach 2 of 10 · upper deck · 5th window from the back · 1st class")
        // the same coach, window 1 from the back (drawn 10): 2nd class
        let back = TravelState.Coach(n: 2, of: 10, front: true, at: "UT", seat: .init(deck: "upper", w: 1, of: 11))
        XCTAssertFalse(SeatMap.isFirst(back, in: t, station: "UT"))
        // only a coach that's part 1st class: not 1st class without a window
        XCTAssertFalse(SeatMap.isFirst(TravelState.Coach(n: 2, of: 10, front: true, at: "UT"), in: t, station: "UT"))
        // a coach that's 1st class all through is, window or not
        let icm = try train(Self.ic2685)
        XCTAssertTrue(SeatMap.isFirst(TravelState.Coach(n: 3, of: 8, front: false, at: "ASD"), in: icm, station: "ASD"))
        XCTAssertEqual(SeatMap.label(TravelState.Coach(n: 3, of: 8, front: false, at: "ASD"), firstClass: true), "Coach 3 of 8 · 1st class")
        // the seat box is unchanged: nothing about class is sent
        XCTAssertEqual(String(decoding: try FriendJSON.encoder.encode(c), as: UTF8.self),
                       #"{"at":"UT","front":true,"n":2,"of":10,"seat":{"deck":"upper","of":11,"w":5}}"#)
    }

    func test_spoken() throws {
        let icm = try train(Self.ic2685)
        XCTAssertEqual(SeatMap.spokenCoach(icm.coaches[2], of: 8), "Coach 3 of 8, 1st class")
        XCTAssertEqual(SeatMap.spokenCoach(icm.coaches[0], of: 8), "Coach 1 of 8")
        let ic = try train(Self.ic3078)
        XCTAssertEqual(SeatMap.spokenCoach(ic.coaches[1], of: 10), "Coach 2 of 10, from the front, two decks, part 1st class")
        XCTAssertEqual(SeatClass.words(.part), "1st class (about here)")
        XCTAssertEqual(SeatClass.words(.first), "1st class")
        XCTAssertNil(SeatClass.words(.second))
        XCTAssertEqual(SeatClass.legend(part: true, whole: false), "= 1st class (about here)")
        XCTAssertEqual(SeatClass.legend(part: false, whole: true), "= 1st class · gold coach: all 1st class")
    }

    func test_drawingNames() {
        XCTAssertEqual(SeatClass.drawing(image: "https://vt.ns-mlab.nl/v1/images/virmm1_6.png"), "virmm1_6")
        XCTAssertEqual(SeatClass.drawing(image: "icng_B_8.png"), "icng_b_8")
        XCTAssertEqual(SeatClass.drawing(image: "", type: "VIRMm1 VI"), "virmm1_6")
        XCTAssertEqual(SeatClass.drawing(image: "", type: "VIRM IV"), "virm_4")
        XCTAssertEqual(SeatClass.drawing(image: "", type: "DDZ 4"), "ddz_4")
        XCTAssertEqual(SeatClass.drawing(image: "", type: "Flirt 3"), "nsr_flirt_3")
        XCTAssertEqual(SeatClass.drawing(image: "", type: "ICNG-B 8"), "icng_b_8")
        XCTAssertNil(SeatClass.drawing(image: "ice.png", type: "ICE-3NEO"))
        XCTAssertNil(SeatClass.drawing(image: "", type: ""))
        // another number of coaches than drawn: not known
        XCTAssertNil(SeatClass.sections(drawing: "virm_4", coach: 0, cars: 6, firstSeats: nil))
        XCTAssertEqual(SeatClass.sections(drawing: "virm_4", coach: 0, cars: 6, firstSeats: 0), [])
    }

    func test_table_isWellFormed() {
        for (k, d) in SeatClass.drawings {
            XCTAssertEqual(d.edges.count + 1, d.coaches.count, k)
            XCTAssertEqual(d.edges, d.edges.sorted(), k)
            XCTAssertTrue(d.edges.allSatisfy { $0 > 0 && $0 < 1 }, k)
            for secs in d.coaches {
                for s in secs { XCTAssertTrue(s.a >= 0 && s.b <= 1 && s.a < s.b, k) }
            }
            XCTAssertFalse(d.coaches.allSatisfy(\.isEmpty), "\(k) has some 1st class")
        }
    }

    func test_unitZones_forThePlatformLetters() throws {
        let sng3 = try XCTUnwrap(SeatClass.unitZones("sng_3"))
        XCTAssertEqual(sng3.count, 1, "one end only")
        XCTAssertEqual(sng3[0].a, 0.2 * 0.3634, accuracy: 1e-9)
        let icm4 = try XCTUnwrap(SeatClass.unitZones("icm_4"))
        XCTAssertEqual(icm4.count, 1)
        XCTAssertEqual(icm4[0].a, 0.4993, accuracy: 1e-9)
        XCTAssertEqual(icm4[0].b, 0.75, accuracy: 1e-9)
        // ICNG 5: over the gangway, merged
        XCTAssertEqual(try XCTUnwrap(SeatClass.unitZones("icng_5")).count, 1)
        XCTAssertNil(SeatClass.unitZones("ice"))
    }
}
