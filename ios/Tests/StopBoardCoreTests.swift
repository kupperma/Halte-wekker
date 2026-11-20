import XCTest

/// 0.37: the widget's and Siri's departures — Transitous's stoptimes and geocode answers, the stop kept as an id, the
/// link the widget opens, the timeline and the words.
final class StopBoardCoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }
    private func hhmm(_ d: Date) -> String { "+\(Int((d.timeIntervalSince(t0) / 60).rounded()))" }
    private func dep(_ line: String, _ m: Double, late: Double = 0, cancelled: Bool = false, train: Bool = false) -> StopBoardCore.Departure {
        .init(line: line, headsign: "Uden", time: at(m + late), scheduled: at(m), live: true, cancelled: cancelled, train: train)
    }

    func test_parseStoptimes() throws {
        let j = """
        {"stopTimes":[
          {"place":{"name":"Veghel, Busstation","departure":"2026-11-20T06:43:00Z","scheduledDeparture":"2026-11-20T06:41:00Z","track":"B"},
           "mode":"BUS","realTime":true,"headsign":"Den Bosch","routeShortName":"305","tripId":"t1"},
          {"place":{"name":"Veghel, Busstation","departure":"2026-11-20T06:52:00Z","scheduledDeparture":"2026-11-20T06:52:00Z"},
           "mode":"BUS","realTime":false,"headsign":"Uden","routeShortName":"306","tripCancelled":true},
          {"place":{"name":"End","arrival":"2026-11-20T06:30:00Z"},"mode":"BUS","routeShortName":"9"},
          {"place":{"name":"'s-Hertogenbosch","departure":"2026-11-20T06:35:00Z","scheduledDeparture":"2026-11-20T06:35:00Z"},
           "mode":"REGIONAL_RAIL","realTime":true,"headsign":"Breda","routeShortName":"Intercity"}
        ]}
        """
        let d = StopBoardCore.parseStoptimes(Data(j.utf8))
        XCTAssertEqual(d.map(\.line), ["IC", "305", "306"], "soonest first; arrival-only left out; trains as the app names them")
        XCTAssertTrue(d[0].train)
        XCTAssertEqual(d[1].delay, 2)
        XCTAssertEqual(d[1].platform, "B")
        XCTAssertTrue(d[2].cancelled)
        XCTAssertEqual(d[2].delay, 0, "no live times: no delay")
        XCTAssertTrue(StopBoardCore.parseStoptimes(Data("{}".utf8)).isEmpty)
        XCTAssertTrue(StopBoardCore.parseStoptimes(Data("oops".utf8)).isEmpty)
    }

    func test_parseGeocode() {
        let j = """
        [{"type":"STOP","id":"nl_1","name":"Veghel, Busstation","lat":51.61,"lon":5.54,"areas":[{"name":"Veghel","default":true}],"modes":["BUS"]},
         {"type":"STOP","id":"nl_2","name":"Breda","lat":51.59,"lon":4.78,"areas":[{"name":"Breda","matched":true}],"modes":["REGIONAL_RAIL","BUS"]},
         {"type":"ADDRESS","id":"a","name":"Street 1","lat":1,"lon":1},
         {"type":"STOP","name":"no id","lat":1,"lon":1}]
        """
        let s = StopBoardCore.parseGeocode(Data(j.utf8))
        XCTAssertEqual(s.map(\.id), ["nl_1", "nl_2"])
        XCTAssertEqual(s[0].town, "Veghel")
        XCTAssertFalse(s[0].rail)
        XCTAssertTrue(s[1].rail)
    }

    func test_stopAsAnId() throws {
        let s = StopBoardCore.Stop(id: "nl-openov_stoparea:123", name: "Veghel, Busstation", town: "Veghel", lat: 51.616543, lon: 5.543219, rail: false)
        let back = try XCTUnwrap(StopBoardCore.decode(StopBoardCore.encode(s)))
        XCTAssertEqual(back, s)
        XCTAssertNil(StopBoardCore.decode("nl_1"), "an id from elsewhere")
        XCTAssertNil(StopBoardCore.decode(""))
        // a name with the separator in it stays one field
        let odd = StopBoardCore.Stop(id: "x", name: "A\u{1F}B", lat: 1, lon: 2)
        XCTAssertEqual(StopBoardCore.decode(StopBoardCore.encode(odd))?.name, "A B")
    }

    func test_link() throws {
        let s = StopBoardCore.Stop(id: "nl_2:a&b", name: "Breda & Co", lat: 51.59, lon: 4.78, rail: true)
        let url = try XCTUnwrap(StopBoardCore.link(s))
        XCTAssertEqual(url.scheme, "haltewekker")
        let back = try XCTUnwrap(StopBoardCore.parseLink(url))
        XCTAssertEqual(back.id, "nl_2:a&b")
        XCTAssertEqual(back.name, "Breda & Co")
        XCTAssertTrue(back.rail)
        XCTAssertNil(StopBoardCore.parseLink(URL(string: "haltewekker://friend?v=1")!))
        XCTAssertNil(StopBoardCore.parseLink(URL(string: "haltewekker://stop?id=x&lat=200&lon=1")!))
        XCTAssertNil(StopBoardCore.parseLink(URL(string: "https://stop?id=x&lat=1&lon=1")!))
    }

    func test_urls() throws {
        let u = try XCTUnwrap(StopBoardCore.stoptimesURL(stopId: "nl_1", from: t0, n: 12))
        XCTAssertTrue(u.absoluteString.hasPrefix("https://api.transitous.org/api/v6/stoptimes?stopId=nl_1&n=12&time="))
        let g = try XCTUnwrap(StopBoardCore.geocodeURL("veghel bus", near: (lat: 51.6, lon: 5.5)))
        XCTAssertTrue(g.absoluteString.contains("type=STOP"))
        XCTAssertTrue(g.absoluteString.contains("text=veghel%20bus"))
    }

    func test_timelineMovesUpAsTheyLeave() {
        let deps = [dep("305", 4), dep("306", 15, late: 2), dep("305", 34), dep("306", 45), dep("305", 64)]
        let t = StopBoardCore.timeline(deps, now: t0, count: 2, refresh: 12 * 60)
        XCTAssertEqual(t.entries.first?.date, t0)
        XCTAssertEqual(t.entries.first?.departures.map(\.line), ["305", "306"])
        // one just after the 305 leaves at +4, then the 306 at +17: until the refresh at +12
        XCTAssertEqual(t.entries.map { hhmm($0.date) }, ["+0", "+5"])
        XCTAssertEqual(t.entries[1].departures.map { hhmm($0.time) }, ["+17", "+34"])
        XCTAssertEqual(t.reloadAt, at(12))
    }

    func test_timelineAsksSoonerWhenItRunsShort() {
        // two known, two shown: ask again just after the first leaves (at least 5 min on)
        let t = StopBoardCore.timeline([dep("305", 8), dep("306", 30)], now: t0, count: 2)
        XCTAssertEqual(t.reloadAt, t0.addingTimeInterval(8 * 60 + 30))
        let soon = StopBoardCore.timeline([dep("305", 1), dep("306", 30)], now: t0, count: 2)
        XCTAssertEqual(soon.reloadAt, at(5), "not more often than every 5 minutes")
        // nothing leaving: an empty entry, again in half an hour
        let none = StopBoardCore.timeline([], now: t0, count: 3)
        XCTAssertEqual(none.entries, [.init(date: t0, departures: [])])
        XCTAssertEqual(none.reloadAt, at(30))
        // one that left a minute ago isn't shown
        XCTAssertEqual(StopBoardCore.upcoming([dep("1", -1), dep("2", 3)], at: t0, count: 3).map(\.line), ["2"])
    }

    func test_words() {
        XCTAssertEqual(StopBoardCore.timeText(dep("305", 41, late: 2), hhmm: hhmm), "+43 (+2)")
        XCTAssertEqual(StopBoardCore.timeText(dep("305", 41, late: -1), hhmm: hhmm), "+40 (−1)")
        XCTAssertEqual(StopBoardCore.timeText(dep("305", 41), hhmm: hhmm), "+41")
        XCTAssertEqual(StopBoardCore.timeText(dep("305", 41, late: 3, cancelled: true), hhmm: hhmm), "+41 cancelled")
        XCTAssertEqual(StopBoardCore.title(dep("305", 1)), "Bus 305")
        XCTAssertEqual(StopBoardCore.title(dep("IC", 1, train: true)), "IC")
        XCTAssertEqual(StopBoardCore.trainLabel("Sprinter"), "SPR")
    }

    func test_spoken() {
        let s = StopBoardCore.spoken([dep("305", 6, late: 2), dep("306", 17), dep("307", 30)], stop: "Veghel", now: t0, hhmm: hhmm)
        XCTAssertEqual(s, "Bus 305 to Uden leaves Veghel at +8, 2 minutes late — in 8 minutes. Then the 306 at +17.")
        XCTAssertEqual(StopBoardCore.spoken([dep("305", 0)], stop: "Veghel", now: t0, hhmm: hhmm),
                       "Bus 305 to Uden leaves Veghel at +0 — now.")
        XCTAssertEqual(StopBoardCore.spoken([dep("305", 5, cancelled: true)], stop: "Veghel", now: t0, hhmm: hhmm),
                       "Nothing leaves Veghel in the next while.")
    }
}
