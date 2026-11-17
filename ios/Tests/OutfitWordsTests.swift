import XCTest

/// The new look's outfit sheet in words (0.20.9).
final class OutfitWordsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }()
    private func at(_ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: h, minute: m))!
    }
    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB"); f.timeZone = cal.timeZone; f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    // MARK: the one line and what VoiceOver says

    func test_lineWithRainLater() {
        let rain = OutfitWords.rain([.init(from: at(16), to: at(18), chance: 70)], start: at(8), end: at(23), clock: clock)
        XCTAssertEqual(rain, "rain from 16:00")
        XCTAssertEqual(OutfitWords.line(grade: 2, raincoat: true, rain: rain), "Coat and a sweater · raincoat, rain from 16:00")
        XCTAssertEqual(OutfitWords.spoken(temp: 10, feels: 7, grade: 2, raincoat: true, rain: rain),
                       "10 degrees, feels like 7, rain from 16:00. Wear a coat and a sweater, and take a raincoat")
    }

    func test_lineWithoutRain() {
        XCTAssertNil(OutfitWords.rain([], start: at(8), end: at(23), clock: clock))
        XCTAssertEqual(OutfitWords.line(grade: 3, raincoat: false, rain: nil), "Sweater or a light jacket")
        XCTAssertEqual(OutfitWords.spoken(temp: 14, feels: 13, grade: 3, raincoat: false, rain: nil),
                       "14 degrees, feels like 13. Wear a sweater or a light jacket")
    }

    func test_everyGradeHasWords() {
        for g in 1...5 {
            XCTAssertFalse(OutfitWords.wear(grade: g).isEmpty)
            XCTAssertFalse(OutfitWords.wearSpoken(grade: g).isEmpty)
            XCTAssertTrue(OutfitWords.wear(grade: g).first!.isUppercase, "the line starts with a capital")
        }
        XCTAssertTrue(OutfitWords.wear(grade: 1).contains("Winter coat"))
        XCTAssertTrue(OutfitWords.wear(grade: 5).contains("shorts"))
    }

    func test_oneDegree() {
        XCTAssertEqual(OutfitWords.degrees(1), "1 degree")
        XCTAssertEqual(OutfitWords.degrees(-1), "-1 degree")
        XCTAssertEqual(OutfitWords.degrees(0), "0 degrees")
        XCTAssertEqual(OutfitWords.degrees(-4), "-4 degrees")
    }

    // MARK: the rain

    func test_rainWhenYouSetOff() {
        XCTAssertEqual(OutfitWords.rain([.init(from: at(8), to: at(11))], start: at(8), end: at(23), clock: clock), "rain until 11:00")
        XCTAssertEqual(OutfitWords.rain([.init(from: at(7), to: at(23))], start: at(8), end: at(23), clock: clock), "rain all day")
    }

    func test_rainOnlyBeforeYouSetOff() {
        // (the day starts at this hour; you may leave later: that rain is over by then, the raincoat still the plan's)
        let words = OutfitWords.rain([.init(from: at(7), to: at(8))], start: at(9), end: at(23), clock: clock)
        XCTAssertNil(words)
        XCTAssertEqual(OutfitWords.line(grade: 4, raincoat: true, rain: words), "T-shirt, a thin layer for the evening · raincoat")
        XCTAssertEqual(OutfitWords.spoken(temp: 18, feels: 18, grade: 4, raincoat: true, rain: words),
                       "18 degrees, feels like 18. Wear a T-shirt, with a thin layer for the evening, and take a raincoat")
    }

    func test_rainHereThenThereIsOneStretch() {
        // (OutfitPlan.rain splits a stretch where the place changes)
        let r = [OutfitWords.Rain(from: at(8), to: at(9), chance: 50), .init(from: at(9), to: at(12), chance: 80), .init(from: at(15), to: at(16))]
        XCTAssertEqual(OutfitWords.merged(r), [.init(from: at(8), to: at(12), chance: 80), .init(from: at(15), to: at(16))])
        XCTAssertEqual(OutfitWords.rain(r, start: at(8), end: at(23), clock: clock), "rain until 12:00")
    }

    // MARK: the chips

    func test_chipsFollowThePieces() {
        let c = OutfitWords.chips(pieces: ["Shirt", "Sweater", "Coat"], raincoat: true)
        XCTAssertEqual(c.map(\.label), ["Shirt", "Sweater", "Coat", "Raincoat"])
        XCTAssertEqual(c[0].symbols, ["tshirt.fill"])
        XCTAssertEqual(c[1].symbols, [], "no sweater symbol: a text chip")
        XCTAssertEqual(c[2].symbols.first, "coat.fill")
        XCTAssertTrue(c[3].rain)
        XCTAssertEqual(c[3].symbols, ["umbrella.fill"])
        XCTAssertEqual(OutfitWords.chips(pieces: ["T-shirt"], raincoat: false).map(\.label), ["T-shirt"])
    }

    func test_chipSymbols() {
        XCTAssertEqual(OutfitWords.symbols(for: "Winter coat").first, "coat.fill")
        XCTAssertEqual(OutfitWords.symbols(for: "Sweater or light jacket"), ["jacket.fill"])
        XCTAssertEqual(OutfitWords.symbols(for: "T-shirt, shorts"), ["tshirt.fill"])
        XCTAssertFalse(OutfitWords.symbols(for: "Scarf, gloves, hat").isEmpty)
    }

    // MARK: during the day

    func test_changes() {
        XCTAssertEqual(OutfitWords.change(fromLayers: 3, toLayers: 2, warmer: true), "Drop a layer")
        XCTAssertEqual(OutfitWords.change(fromLayers: 2, toLayers: 4, warmer: false), "Add 2 layers")
        XCTAssertEqual(OutfitWords.change(fromLayers: 1, toLayers: 1, warmer: true), "It gets warmer")
        XCTAssertEqual(OutfitWords.change(fromLayers: 1, toLayers: 1, warmer: false), "It gets colder")
        XCTAssertEqual(OutfitWords.changeDetail(place: "BUas", gradeName: "Mild", feels: 12), "In BUas · mild, feels 12°")
    }

    func test_rainNotes() {
        XCTAssertEqual(OutfitWords.rainTitle(to: at(18), chance: 70, clock: clock), "Rain until 18:00 · 70%")
        XCTAssertEqual(OutfitWords.rainTitle(to: at(18), chance: 0, clock: clock), "Rain until 18:00")
        XCTAssertEqual(OutfitWords.rainDetail(place: "BUas", afterArrival: true), "In BUas · raincoat for later")
        XCTAssertEqual(OutfitWords.rainDetail(place: "Veghel", afterArrival: false), "In Veghel · raincoat on the way")
    }

    // MARK: where it applies

    func test_whereLine() {
        XCTAssertEqual(OutfitWords.whereLine(here: "where you are", there: "BUas", arrive: at(8, 30), hereHours: true, thereHours: true, clock: clock),
                       "Here until about 08:30, then BUas")
        XCTAssertEqual(OutfitWords.whereLine(here: "Veghel", there: "BUas", arrive: at(8, 30), hereHours: true, thereHours: true, clock: clock),
                       "Here in Veghel until about 08:30, then BUas")
        XCTAssertEqual(OutfitWords.whereLine(here: "Veghel", there: "BUas", arrive: at(6), hereHours: false, thereHours: true, clock: clock),
                       "BUas, all day")
        XCTAssertEqual(OutfitWords.whereLine(here: "Veghel", there: "BUas", arrive: at(23, 50), hereHours: true, thereHours: false, clock: clock),
                       "Here in Veghel, all day")
    }

    // MARK: an hour

    func test_hourSpoken() {
        XCTAssertEqual(OutfitWords.hourSpoken(time: "16:00", code: 61, temp: 9, feels: 6, wet: true, chance: 70),
                       "16:00, rain, 9 degrees, feels like 6, rain 70%")
        XCTAssertEqual(OutfitWords.hourSpoken(time: "09:00", code: 2, temp: 1, feels: -2, wet: false, chance: 10),
                       "09:00, partly cloudy, 1 degree, feels like -2")
        XCTAssertEqual(OutfitWords.sky(code: 65), "heavy rain")
        XCTAssertEqual(OutfitWords.sky(code: 0), "clear")
    }
}
