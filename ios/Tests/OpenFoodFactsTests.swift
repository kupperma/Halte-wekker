import XCTest

final class OpenFoodFactsTests: XCTestCase {
    private let kwark = #"{"status":1,"product":{"product_name":"Magere kwark","brands":"AH","product_quantity":500,"product_quantity_unit":"g","nutriments":{"proteins_100g":8.2}}}"#

    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func response(_ code: Int, for request: URLRequest) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func test_parseNumberQuantity() throws {
        let p = try XCTUnwrap(OpenFoodFacts.parse(json(kwark)))
        XCTAssertEqual(p.name, "AH Magere kwark")
        XCTAssertEqual(try XCTUnwrap(p.proteinPerPack), 41.0, accuracy: 0.001)
    }

    func test_parseStringQuantityAndLitre() throws {
        let s = #"{"status":1,"product":{"product_name":"Melk","brands":"Campina, Other","product_quantity":"1","product_quantity_unit":"l","extra":{"x":[1,2]},"nutriments":{"proteins_100g":3.4}}}"#
        let p = try XCTUnwrap(OpenFoodFacts.parse(json(s)))
        XCTAssertEqual(p.name, "Campina Melk")
        XCTAssertEqual(try XCTUnwrap(p.proteinPerPack), 34.0, accuracy: 0.001)
    }

    func test_missingProtein() throws {
        let s = #"{"status":1,"product":{"product_name":"Magere kwark","brands":"AH","product_quantity":500,"product_quantity_unit":"g","nutriments":{}}}"#
        let p = try XCTUnwrap(OpenFoodFacts.parse(json(s)))
        XCTAssertEqual(p.name, "AH Magere kwark")
        XCTAssertNil(p.proteinPerPack)
    }

    func test_brandNotDoubled() throws {
        let s = #"{"status":1,"product":{"product_name":"AH Magere kwark","brands":"AH","product_quantity":500,"product_quantity_unit":"g","nutriments":{"proteins_100g":8.2}}}"#
        XCTAssertEqual(try XCTUnwrap(OpenFoodFacts.parse(json(s))).name, "AH Magere kwark")
        let lower = #"{"status":1,"product":{"product_name":"ah magere kwark","brands":" AH , Albert Heijn","nutriments":{}}}"#
        XCTAssertEqual(try XCTUnwrap(OpenFoodFacts.parse(json(lower))).name, "ah magere kwark")
        // only a whole word: "Ahornsirup" is not "AH" again
        let word = #"{"status":1,"product":{"product_name":"Ahornsirup","brands":"AH","nutriments":{}}}"#
        XCTAssertEqual(try XCTUnwrap(OpenFoodFacts.parse(json(word))).name, "AH Ahornsirup")
    }

    func test_notFound() {
        XCTAssertNil(OpenFoodFacts.parse(json(#"{"status":0}"#)))
        XCTAssertNil(OpenFoodFacts.parse(json("nope")))
    }

    func test_lookup() async {
        let ok = await OpenFoodFacts.lookup("4012345678901") { req in (self.json(self.kwark), self.response(200, for: req)) }
        guard case let .found(name, protein, portion) = ok else { return XCTFail("expected found, got \(ok)") }
        XCTAssertNil(portion)
        XCTAssertEqual(name, "AH Magere kwark")
        XCTAssertEqual(protein, 41.0, accuracy: 0.001)

        let offline = await OpenFoodFacts.lookup("4012345678901") { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(offline, .offline)

        let missing = await OpenFoodFacts.lookup("4012345678901") { req in (self.json(#"{"status":0}"#), self.response(404, for: req)) }
        XCTAssertEqual(missing, .needsProtein(name: nil))

        let noProtein = #"{"status":1,"product":{"product_name":"Kwark","brands":"AH","product_quantity":500}}"#
        let r = await OpenFoodFacts.lookup("4012345678901") { req in (self.json(noProtein), self.response(200, for: req)) }
        XCTAssertEqual(r, .needsProtein(name: "AH Kwark"))
    }

    /// A protein number that can't be a real pack asks for the label, with the name it did find.
    func test_lookupAbsurdProtein() async {
        let infinite = #"{"status":1,"product":{"product_name":"Kwark","brands":"AH","product_quantity":500,"product_quantity_unit":"g","nutriments":{"proteins_100g":"inf"}}}"#
        let a = await OpenFoodFacts.lookup("4012345678901") { req in (self.json(infinite), self.response(200, for: req)) }
        XCTAssertEqual(a, .needsProtein(name: "AH Kwark"))

        let huge = #"{"status":1,"product":{"product_name":"Kwark","brands":"AH","product_quantity":500,"product_quantity_unit":"g","nutriments":{"proteins_100g":1e9}}}"#
        let b = await OpenFoodFacts.lookup("4012345678901") { req in (self.json(huge), self.response(200, for: req)) }
        XCTAssertEqual(b, .needsProtein(name: "AH Kwark"))
    }

    /// Not a barcode: no request at all.
    func test_lookupBadCode() async {
        var asked = false
        let r = await OpenFoodFacts.lookup("5\u{0303}12345678") { req in
            asked = true
            return (self.json(self.kwark), self.response(200, for: req))
        }
        XCTAssertEqual(r, .needsProtein(name: nil))
        XCTAssertFalse(asked)
        XCTAssertNil(OpenFoodFacts.url(for: "12 345678"))
        XCTAssertNotNil(OpenFoodFacts.url(for: "4012345678901"))
    }

    func test_request() async {
        var captured: URLRequest?
        _ = await OpenFoodFacts.lookup("4012345678901") { req in
            captured = req
            return (self.json(#"{"status":0}"#), self.response(404, for: req))
        }
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "User-Agent"), OpenFoodFacts.userAgent)
        XCTAssertTrue(captured?.url?.absoluteString.contains("/api/v2/product/4012345678901.json") ?? false)
        let fields = captured?.url?.absoluteString ?? ""
        XCTAssertTrue(fields.contains("serving_size"))
        XCTAssertTrue(fields.contains("serving_quantity"))
        XCTAssertTrue(fields.contains("nutriments"))
    }

    func test_isBarcode() {
        XCTAssertTrue(OpenFoodFacts.isBarcode("4012345678901"))
        XCTAssertFalse(OpenFoodFacts.isBarcode("12"))
        XCTAssertFalse(OpenFoodFacts.isBarcode("40a2"))
        XCTAssertFalse(OpenFoodFacts.isBarcode("40123456a8901"))
        XCTAssertFalse(OpenFoodFacts.isBarcode("5\u{0303}12345678"))
        XCTAssertFalse(OpenFoodFacts.isBarcode("\u{0664}0123456"))            // Arabic-Indic four
        XCTAssertTrue(OpenFoodFacts.isBarcode("40123456"))
    }

    func test_digits() {
        XCTAssertEqual(OpenFoodFacts.digits(in: "87 10400 12345"), "871040012345")
        XCTAssertEqual(OpenFoodFacts.digits(in: "5\u{0303}1-2"), "512")
        XCTAssertEqual(OpenFoodFacts.digits(in: "\u{0664}\u{FF11}"), "")
    }

    // MARK: - Portions

    private func product(_ fields: String) -> String {
        #"{"status":1,"product":{"product_name":"Brood","brands":"Grafschafter",\#(fields)}}"#
    }

    func test_servingNames() {
        func check(_ text: String?, _ name: String, _ count: Double, line: UInt = #line) {
            let s = OpenFoodFacts.serving(text)
            XCTAssertEqual(s.name, name, "\(text ?? "nil")", line: line)
            XCTAssertEqual(s.count, count, "\(text ?? "nil")", line: line)
        }
        check("1 slice (40 g)", "slice", 1)
        check("40 g", "portion", 1)
        check("40g", "portion", 1)
        check("2 Scheiben (25 g)", "slice", 2)
        check("1 Scheibe (10 g)", "slice", 1)
        check("Portion (50 g)", "portion", 1)
        check("1 plak (12 g)", "slice", 1)
        check("3 plakken", "slice", 3)
        check("1 stuk", "piece", 1)
        check("1 Stück (30 g)", "piece", 1)
        check("2 pieces", "piece", 2)
        check("1 portie (150 g)", "portion", 1)
        check("1 bar (45 g)", "bar", 1)
        check("30 g (1 Scheibe)", "slice", 1)       // the name in the brackets
        check("1 Becher (150 g)", "portion", 1)     // a word it doesn't know
        check("2,5 Scheiben", "portion", 1)         // not a whole count
        check("", "portion", 1)
        check(nil, "portion", 1)
    }

    /// The sandwich bread from the user's screenshot: 9 g per 100 g, 750 g, one slice of 40 g.
    func test_portionFromServingWeight() throws {
        let s = product(#""product_quantity":750,"product_quantity_unit":"g","serving_size":"1 slice (40 g)","serving_quantity":40,"nutriments":{"proteins_100g":9}"#)
        let p = try XCTUnwrap(OpenFoodFacts.parse(json(s)))
        XCTAssertEqual(try XCTUnwrap(p.proteinPerPack), 67.5, accuracy: 0.001)
        let portion = try XCTUnwrap(p.portion)
        XCTAssertEqual(portion.name, "slice")
        XCTAssertEqual(portion.protein, 3.6, accuracy: 0.001)
        XCTAssertEqual(portion.units, "slices")
        XCTAssertEqual(try XCTUnwrap(p.portionsPerPack), 18.75, accuracy: 0.001)
    }

    /// proteins_serving wins over working it out from per 100 g; strings and comma decimals are read too.
    func test_portionFromServingProtein() throws {
        let number = product(#""product_quantity":500,"serving_size":"1 plak (12 g)","serving_quantity":12,"nutriments":{"proteins_100g":10,"proteins_serving":1.5}"#)
        XCTAssertEqual(try XCTUnwrap(OpenFoodFacts.parse(json(number))?.portion?.protein), 1.5, accuracy: 0.001)
        let text = product(#""product_quantity":"500","serving_size":"1 plak (12 g)","serving_quantity":"12","nutriments":{"proteins_100g":"10","proteins_serving":"1,5"}"#)
        let p = try XCTUnwrap(OpenFoodFacts.parse(json(text)))
        XCTAssertEqual(try XCTUnwrap(p.portion?.protein), 1.5, accuracy: 0.001)
        XCTAssertEqual(p.portion?.name, "slice")
        XCTAssertEqual(try XCTUnwrap(p.portionsPerPack), 500.0 / 12, accuracy: 0.001)
        // an empty proteins_serving is missing: worked out from per 100 g instead
        let empty = product(#""product_quantity":500,"serving_size":"1 plak","serving_quantity":"12","nutriments":{"proteins_100g":10,"proteins_serving":""}"#)
        XCTAssertEqual(try XCTUnwrap(OpenFoodFacts.parse(json(empty))?.portion?.protein), 1.2, accuracy: 0.001)
    }

    /// The Bierwurst: "2 Scheiben (25 g)" is two slices, so one slice is half the serving.
    func test_portionDividedByCount() throws {
        let s = product(#""product_quantity":200,"product_quantity_unit":"g","serving_size":"2 Scheiben (25 g)","serving_quantity":25,"nutriments":{"proteins_100g":14,"proteins_serving":3.5}"#)
        let p = try XCTUnwrap(OpenFoodFacts.parse(json(s)))
        let portion = try XCTUnwrap(p.portion)
        XCTAssertEqual(portion.name, "slice")
        XCTAssertEqual(portion.protein, 1.75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(p.portionsPerPack), 16, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(p.proteinPerPack), 28, accuracy: 0.001)
    }

    func test_portionsPerPackInKilos() throws {
        let s = product(#""product_quantity":1,"product_quantity_unit":"kg","serving_size":"1 Scheibe (50 g)","serving_quantity":50,"nutriments":{"proteins_100g":8}"#)
        XCTAssertEqual(try XCTUnwrap(OpenFoodFacts.parse(json(s))?.portionsPerPack), 20, accuracy: 0.001)
    }

    /// No protein per 100 g, but per serving and both weights: the pack is its portions.
    func test_packFromPortions() throws {
        let s = product(#""product_quantity":400,"serving_size":"1 slice (40 g)","serving_quantity":40,"nutriments":{"proteins_serving":4}"#)
        let p = try XCTUnwrap(OpenFoodFacts.parse(json(s)))
        XCTAssertEqual(try XCTUnwrap(p.proteinPerPack), 40, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(p.portion?.protein), 4, accuracy: 0.001)
    }

    func test_portionUnknown() throws {
        // no serving at all
        XCTAssertNil(try XCTUnwrap(OpenFoodFacts.parse(json(kwark))).portion)
        // a serving name but no weight and no protein per serving
        let noWeight = product(#""product_quantity":500,"serving_size":"1 slice","nutriments":{"proteins_100g":9}"#)
        XCTAssertNil(try XCTUnwrap(OpenFoodFacts.parse(json(noWeight))).portion)
        XCTAssertNil(try XCTUnwrap(OpenFoodFacts.parse(json(noWeight))).portionsPerPack)
    }

    /// Numbers that can't be a real portion are left out, and so is a "portion" that is the whole pack.
    func test_portionBounds() throws {
        let huge = product(#""product_quantity":500,"serving_size":"1 slice (40 g)","serving_quantity":40,"nutriments":{"proteins_serving":1e6}"#)
        XCTAssertNil(try XCTUnwrap(OpenFoodFacts.parse(json(huge))).portion)
        let infinite = product(#""product_quantity":500,"serving_size":"1 slice","serving_quantity":40,"nutriments":{"proteins_serving":"inf","proteins_100g":"inf"}"#)
        XCTAssertNil(try XCTUnwrap(OpenFoodFacts.parse(json(infinite))).portion)
        let tiny = product(#""product_quantity":500,"serving_size":"1 slice","serving_quantity":0.1,"nutriments":{"proteins_100g":9}"#)
        XCTAssertNil(try XCTUnwrap(OpenFoodFacts.parse(json(tiny))).portion)            // 0.009 g
        let zero = product(#""product_quantity":500,"serving_size":"1 slice","serving_quantity":0,"nutriments":{"proteins_100g":9}"#)
        XCTAssertNil(try XCTUnwrap(OpenFoodFacts.parse(json(zero))).portion)
        // 5 kg in 1 g portions: 5000 a pack is more than 200
        let many = product(#""product_quantity":5000,"serving_size":"1 piece (1 g)","serving_quantity":1,"nutriments":{"proteins_100g":20}"#)
        let m = try XCTUnwrap(OpenFoodFacts.parse(json(many)))
        XCTAssertNil(m.portionsPerPack)
        XCTAssertEqual(try XCTUnwrap(m.portion?.protein), 0.2, accuracy: 0.001)
        // a single yoghurt: the serving is the pack
        let single = product(#""product_quantity":150,"serving_size":"1 pot (150 g)","serving_quantity":150,"nutriments":{"proteins_100g":10}"#)
        let one = try XCTUnwrap(OpenFoodFacts.parse(json(single)))
        XCTAssertNil(one.portion)
        XCTAssertEqual(try XCTUnwrap(one.proteinPerPack), 15, accuracy: 0.001)
    }

    func test_lookupCarriesPortion() async throws {
        let bread = product(#""product_quantity":750,"product_quantity_unit":"g","serving_size":"1 slice (40 g)","serving_quantity":40,"nutriments":{"proteins_100g":9}"#)
        let r = await OpenFoodFacts.lookup("4012345678901") { req in (self.json(bread), self.response(200, for: req)) }
        guard case let .found(name, protein, portion) = r else { return XCTFail("expected found, got \(r)") }
        XCTAssertEqual(name, "Grafschafter Brood")
        XCTAssertEqual(protein, 67.5, accuracy: 0.001)
        XCTAssertEqual(portion?.name, "slice")
        XCTAssertEqual(try XCTUnwrap(portion?.protein), 3.6, accuracy: 0.001)

        // a serving known, but no pack weight: asks for the label and keeps the slice
        let noPack = product(#""serving_size":"1 Scheibe (10 g)","serving_quantity":10,"nutriments":{"proteins_100g":14}"#)
        let n = await OpenFoodFacts.lookup("4012345678901") { req in (self.json(noPack), self.response(200, for: req)) }
        guard case let .needsProtein(name2, portion2) = n else { return XCTFail("expected needsProtein, got \(n)") }
        XCTAssertEqual(name2, "Grafschafter Brood")
        XCTAssertEqual(portion2?.name, "slice")
        XCTAssertEqual(try XCTUnwrap(portion2?.protein), 1.4, accuracy: 0.001)
    }
}
