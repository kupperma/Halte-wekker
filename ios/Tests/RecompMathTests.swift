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

    func test_portionsInput() {
        XCTAssertEqual(RecompInput.portions("12"), 12)
        XCTAssertEqual(RecompInput.portions(" 7 "), 7)
        XCTAssertEqual(RecompInput.portions("1"), 1)
        XCTAssertEqual(RecompInput.portions("200"), 200)
        XCTAssertNil(RecompInput.portions("0"))
        XCTAssertNil(RecompInput.portions("201"))
        XCTAssertNil(RecompInput.portions(""))
        XCTAssertNil(RecompInput.portions("1.5"))
        XCTAssertNil(RecompInput.portions("-3"))
        XCTAssertNil(RecompInput.portions("99999999999999999999"))
        XCTAssertNil(RecompInput.portions("\u{0664}"))             // Arabic-Indic four
    }

    func test_portionSplitAndNames() {
        XCTAssertEqual(Portion.split(pack: 68, into: 17, name: "slice"), Portion(name: "slice", protein: 4))
        XCTAssertNil(Portion.split(pack: 68, into: 0, name: "slice"))
        XCTAssertNil(Portion.split(pack: 68, into: 201, name: "slice"))
        XCTAssertNil(Portion.split(pack: 1, into: 20, name: "slice"))           // 0.05 g
        XCTAssertNil(Portion.split(pack: .nan, into: 2, name: "slice"))
        XCTAssertNil(Portion(name: "slice", protein: 301))
        XCTAssertNil(Portion(name: " ", protein: 4))
        XCTAssertEqual(PortionName.plural("slice"), "slices")
        XCTAssertEqual(PortionName.plural("piece"), "pieces")
        XCTAssertEqual(PortionName.plural(""), "portions")
        XCTAssertEqual(PortionName.english("Scheiben"), "slice")
        XCTAssertEqual(PortionName.english("STÜCK"), "piece")
        XCTAssertEqual(PortionName.english("Portie"), "portion")
        XCTAssertNil(PortionName.english("g"))
    }

    // MARK: - Calories

    /// Set at 2450 kcal at a week average of 88 kg: 15 kcal a kg either way, to the nearest 50.
    func test_kcalLimitMovesWithWeight() {
        func limit(_ w: Double?) -> Double {
            KcalMath.limit(anchorLimit: 2450, anchorWeight: 88, weekAverage: w, follows: true)
        }
        XCTAssertEqual(limit(88), 2450)
        XCTAssertEqual(limit(85), 2400)          // 2405
        XCTAssertEqual(limit(91), 2500)          // 2495
        XCTAssertEqual(limit(88.3), 2450)        // 2454.5
        XCTAssertEqual(limit(89.7), 2500)        // 2475.5
        XCTAssertEqual(limit(nil), 2450)         // no week average: the anchor
        XCTAssertEqual(KcalMath.limit(anchorLimit: 2450, anchorWeight: 88, weekAverage: 91, follows: false), 2450)
        XCTAssertEqual(KcalMath.limit(anchorLimit: 2450, anchorWeight: nil, weekAverage: 91, follows: true), 2450)
    }

    func test_kcalLimitClampAndRound() {
        XCTAssertEqual(KcalMath.limit(anchorLimit: 1250, anchorWeight: 90, weekAverage: 70, follows: true), 1200)
        XCTAssertEqual(KcalMath.limit(anchorLimit: 4950, anchorWeight: 90, weekAverage: 100, follows: true), 5000)
        XCTAssertEqual(KcalMath.clampLimit(2437), 2450)
        XCTAssertEqual(KcalMath.clampLimit(2424), 2400)
        XCTAssertEqual(KcalMath.clampLimit(100), 1200)
        XCTAssertEqual(KcalMath.clampLimit(99_999), 5000)
        XCTAssertEqual(KcalMath.clampLimit(.nan), 2450)
        XCTAssertEqual(KcalMath.clampLimit(.infinity), 2450)
    }

    func test_shouldNotify() {
        let today = "2026-11-16"
        XCTAssertTrue(KcalMath.shouldNotify(total: 2450, limit: 2450, lastNotified: nil, today: today, enabled: true))
        XCTAssertTrue(KcalMath.shouldNotify(total: 2480, limit: 2450, lastNotified: "2026-11-15", today: today, enabled: true))
        XCTAssertFalse(KcalMath.shouldNotify(total: 2449, limit: 2450, lastNotified: nil, today: today, enabled: true))
        XCTAssertFalse(KcalMath.shouldNotify(total: 2480, limit: 2450, lastNotified: today, today: today, enabled: true))
        XCTAssertFalse(KcalMath.shouldNotify(total: 2480, limit: 2450, lastNotified: nil, today: today, enabled: false))
        XCTAssertFalse(KcalMath.shouldNotify(total: .nan, limit: 2450, lastNotified: nil, today: today, enabled: true))
        XCTAssertFalse(KcalMath.shouldNotify(total: 10, limit: 0, lastNotified: nil, today: today, enabled: true))
    }

    func test_kcalText() {
        let gb = Locale(identifier: "en_GB")
        XCTAssertEqual(KcalMath.number(2480, locale: gb), "2,480")
        XCTAssertEqual(KcalMath.number(1649.6, locale: gb), "1,650")
        XCTAssertEqual(KcalMath.number(.nan, locale: gb), "0")
        XCTAssertEqual(KcalMath.cardLine(total: 1650, limit: 2450, locale: gb), "≈ 1,650 of 2,450 kcal logged")
        XCTAssertEqual(KcalMath.cardLine(total: 2480, limit: 2450, locale: gb), "Limit reached · 2,480 of 2,450 kcal logged")
        XCTAssertEqual(KcalMath.cardLine(total: 2450, limit: 2450, locale: gb), "Limit reached · 2,450 of 2,450 kcal logged")
        XCTAssertEqual(KcalMath.noticeBody(total: 2480, limit: 2450, locale: gb), "You've logged 2,480 of 2,450 kcal today.")
        XCTAssertEqual(KcalMath.noticeTitle, "Calorie limit reached")
    }

    func test_kcalInput() {
        XCTAssertEqual(RecompInput.kcalEntry("650"), 650)
        XCTAssertNil(RecompInput.kcalEntry("0"))
        XCTAssertNil(RecompInput.kcalEntry("3001"))
        XCTAssertNil(RecompInput.kcalEntry(""))
        XCTAssertEqual(RecompInput.kcal("0"), 0)
        XCTAssertEqual(RecompInput.kcal("1875"), 1875)
        XCTAssertNil(RecompInput.kcal("5001"))
    }
}
