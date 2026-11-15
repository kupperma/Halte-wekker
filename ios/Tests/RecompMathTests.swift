import XCTest

final class RecompMathTests: XCTestCase {
    func test_number() {
        XCTAssertEqual(RecompInput.number("88,4"), 88.4)
        XCTAssertEqual(RecompInput.number("88.4"), 88.4)
        XCTAssertEqual(RecompInput.number(" 88 "), 88)
        XCTAssertEqual(RecompInput.number("88,4 kg"), 88.4)
        XCTAssertEqual(RecompInput.number("92cm"), 92)
        XCTAssertEqual(RecompInput.number("88."), 88)
        XCTAssertNil(RecompInput.number("8,8,8"))
        XCTAssertNil(RecompInput.number("abc"))
        XCTAssertNil(RecompInput.number(""))
    }

    func test_ranges() {
        XCTAssertNil(RecompInput.weight("8"))
        XCTAssertEqual(RecompInput.weight("88,4"), 88.4)
        XCTAssertNil(RecompInput.weight("301"))
        XCTAssertEqual(RecompInput.waist("92"), 92)
        XCTAssertNil(RecompInput.waist("20"))
        XCTAssertNil(RecompInput.protein("0"))
    }

    func test_amountText() {
        XCTAssertEqual(ProteinMath.amountText(0.25), "¼")
        XCTAssertEqual(ProteinMath.amountText(0.5), "½")
        XCTAssertEqual(ProteinMath.amountText(0.75), "¾")
        XCTAssertEqual(ProteinMath.amountText(1), "1")
        XCTAssertEqual(ProteinMath.amountText(1.5), "1½")
        XCTAssertEqual(ProteinMath.amountText(3), "3")
    }

    func test_amountLabel() {
        XCTAssertEqual(ProteinMath.amountLabel(0.75, unit: "tub", units: "tubs"), "¾ tub")
        XCTAssertEqual(ProteinMath.amountLabel(3, unit: "egg", units: "eggs"), "3 eggs")
        XCTAssertEqual(ProteinMath.amountLabel(1, unit: "can", units: "cans"), "1 can")
    }

    func test_perPack() {
        XCTAssertEqual(ProteinMath.perPack(proteinPer100: 8.0, quantity: 500, unit: "g")!, 40, accuracy: 0.0001)
        XCTAssertEqual(ProteinMath.perPack(proteinPer100: 3.4, quantity: 1, unit: "l")!, 34, accuracy: 0.0001)
        XCTAssertEqual(ProteinMath.perPack(proteinPer100: 10, quantity: 250, unit: nil)!, 25, accuracy: 0.0001)
        XCTAssertNil(ProteinMath.perPack(proteinPer100: nil, quantity: 500, unit: "g"))
        XCTAssertNil(ProteinMath.perPack(proteinPer100: 8, quantity: nil, unit: "g"))
    }

    func test_perPackOnlyRealPacks() {
        XCTAssertNil(ProteinMath.perPack(proteinPer100: 1e308, quantity: 1e308, unit: "g"))      // overflows to inf
        XCTAssertNil(ProteinMath.perPack(proteinPer100: .infinity, quantity: 500, unit: "g"))
        XCTAssertNil(ProteinMath.perPack(proteinPer100: .nan, quantity: 500, unit: "g"))
        XCTAssertNil(ProteinMath.perPack(proteinPer100: 1e9, quantity: 500, unit: "g"))           // 5 000 000 000 g
        XCTAssertNil(ProteinMath.perPack(proteinPer100: 0.01, quantity: 100, unit: "g"))          // 0.01 g
        XCTAssertEqual(ProteinMath.perPack(proteinPer100: 100, quantity: 1, unit: "kg")!, 1000, accuracy: 0.0001)
    }

    func test_nonFiniteFormatting() {
        XCTAssertEqual(RecompFormat.grams(.infinity), "0 g")
        XCTAssertEqual(RecompFormat.grams(-.infinity), "0 g")
        XCTAssertEqual(RecompFormat.grams(.nan), "0 g")
        XCTAssertEqual(ProteinMath.percent(total: .infinity, goal: 160), 0)
        XCTAssertEqual(ProteinMath.percent(total: .nan, goal: 160), 0)
        XCTAssertEqual(ProteinMath.percent(total: 80, goal: .infinity), 0)
    }

    /// Under half a gram to go is the goal reached: no "0 g protein to go".
    func test_toGoUnderHalfAGram() {
        XCTAssertNil(ProteinMath.toGo(total: 159.6, goal: 160))
        XCTAssertNil(ProteinMath.rideLine(total: 159.6, goal: 160))
        XCTAssertNil(ProteinMath.toGo(total: 170, goal: 160))
        XCTAssertEqual(ProteinMath.toGo(total: 159.5, goal: 160), "1 g protein to go")
        XCTAssertEqual(ProteinMath.toGo(total: 158.6, goal: 160), "1 g protein to go")
        XCTAssertEqual(ProteinMath.rideLine(total: 158, goal: 160), "2 g protein to go today")
    }

    func test_percentAndRideLine() {
        XCTAssertEqual(ProteinMath.percent(total: 105, goal: 160), 66)
        XCTAssertEqual(ProteinMath.percent(total: 200, goal: 160), 125)
        XCTAssertEqual(ProteinMath.toGo(total: 105, goal: 160), "55 g protein to go")
        XCTAssertEqual(ProteinMath.rideLine(total: 105, goal: 160), "55 g protein to go today")
        XCTAssertNil(ProteinMath.rideLine(total: 160, goal: 160))
    }

    func test_format() {
        let nl = Locale(identifier: "nl_NL")
        let gb = Locale(identifier: "en_GB")
        XCTAssertEqual(RecompFormat.kg(88.14, locale: nl), "88,1 kg")
        XCTAssertEqual(RecompFormat.change(-0.34, locale: nl), "↓ 0,3")
        XCTAssertEqual(RecompFormat.change(0.02, locale: nl), "± 0,0")
        XCTAssertEqual(RecompFormat.kg(88.14, locale: gb), "88.1 kg")
        XCTAssertEqual(RecompFormat.grams(19.6), "20 g")
    }
}
