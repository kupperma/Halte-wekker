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

    func test_notFound() {
        XCTAssertNil(OpenFoodFacts.parse(json(#"{"status":0}"#)))
        XCTAssertNil(OpenFoodFacts.parse(json("nope")))
    }

    func test_lookup() async {
        let ok = await OpenFoodFacts.lookup("4012345678901") { req in (self.json(self.kwark), self.response(200, for: req)) }
        guard case let .found(name, protein) = ok else { return XCTFail("expected found, got \(ok)") }
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

    func test_request() async {
        var captured: URLRequest?
        _ = await OpenFoodFacts.lookup("4012345678901") { req in
            captured = req
            return (self.json(#"{"status":0}"#), self.response(404, for: req))
        }
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "User-Agent"), OpenFoodFacts.userAgent)
        XCTAssertTrue(captured?.url?.absoluteString.contains("/api/v2/product/4012345678901.json") ?? false)
    }

    func test_isBarcode() {
        XCTAssertTrue(OpenFoodFacts.isBarcode("4012345678901"))
        XCTAssertFalse(OpenFoodFacts.isBarcode("12"))
        XCTAssertFalse(OpenFoodFacts.isBarcode("40a2"))
        XCTAssertFalse(OpenFoodFacts.isBarcode("40123456a8901"))
    }
}
