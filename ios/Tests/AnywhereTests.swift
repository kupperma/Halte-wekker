import XCTest

/// 0.24 "works well anywhere": the NS station list and codes, the nearest station, the auto-start's regions, the
/// door-to-door scoreboard and the words of the lock screen preview, the demo and "A train's time".
final class AnywhereTests: XCTestCase {
    // MARK: the NS station list

    private var bundled: [NSStation] {
        let url = Bundle(for: Self.self).url(forResource: NSCodes.fileName, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../App/NSStations.json")
        return NSCodes.decode(try? Data(contentsOf: url))
    }

    func test_theBundledStationListDecodes() {
        let l = bundled
        XCTAssertGreaterThan(l.count, 350)
        XCTAssertEqual(Set(l.map(\.code)).count, l.count, "one entry per code")
        for s in l {
            XCTAssertTrue(s.code.range(of: "^[A-Z]{2,5}$", options: .regularExpression) != nil, s.code)
            XCTAssertTrue(s.uic.hasPrefix("84") && s.uic.count == 7, "\(s.code) \(s.uic)")
            XCTAssertTrue((50.7...53.6).contains(s.lat) && (3.3...7.3).contains(s.lon), "\(s.code) is in the Netherlands")
        }
        let i = NSCodes.Index(l)
        // the corridor's three, as 0.21's table had them
        XCTAssertEqual(i.byUIC["8400206"], "EHV")
        XCTAssertEqual(i.byUIC["8400319"], "HT")
        XCTAssertEqual(i.byUIC["8400131"], "BD")
        XCTAssertEqual(i.station("UT")?.name, "Utrecht Centraal")
    }

    private let sample = [
        NSStation(code: "EHV", uic: "8400206", name: "Eindhoven Centraal", names: ["Eindhoven C.", "Eindhovn C"], lat: 51.44333, lon: 5.48139),
        NSStation(code: "HT", uic: "8400319", name: "'s-Hertogenbosch", names: ["Den Bosch"], lat: 51.69048, lon: 5.29362),
        NSStation(code: "BD", uic: "8400131", name: "Breda", lat: 51.59555, lon: 4.78),
        NSStation(code: "TB", uic: "8400597", name: "Tilburg", lat: 51.56056, lon: 5.08361),
        NSStation(code: "UT", uic: "8400621", name: "Utrecht Centraal", names: ["Utrecht C."], lat: 52.08889, lon: 5.11028),
    ]

    func test_uicFromDelfiIds() {
        XCTAssertEqual(NSCodes.uic(fromStopId: "de-DELFI_000008400319"), "8400319")
        XCTAssertEqual(NSCodes.uic(fromStopId: "de-DELFI_000008400206"), "8400206")
        XCTAssertEqual(NSCodes.uic(fromStopId: "de-DELFI_8400131"), "8400131")
        XCTAssertNil(NSCodes.uic(fromStopId: "de-DELFI_000008011160"), "a German station")
        XCTAssertNil(NSCodes.uic(fromStopId: "nl-OpenOV_4001924"), "not a DELFI id")
        XCTAssertNil(NSCodes.uic(fromStopId: "nl-OpenOV_stoparea:17911"))
        XCTAssertNil(NSCodes.uic(fromStopId: "51.5907,4.7932"))
        XCTAssertNil(NSCodes.uic(fromStopId: "de-DELFI_0000084003"), "too short")
    }

    func test_codeByIdThenName() {
        let i = NSCodes.Index(sample)
        XCTAssertEqual(NSCodes.code(forStopId: "de-DELFI_000008400319", name: nil, in: i), "HT")
        // (Transitous's NS platforms are OpenOV's: by the name)
        XCTAssertEqual(NSCodes.code(forStopId: "nl-OpenOV_4001924", name: "Eindhoven Centraal", in: i), "EHV")
        XCTAssertEqual(NSCodes.code(forStopId: "nl-OpenOV_3133722", name: "Breda", in: i), "BD")
        XCTAssertEqual(NSCodes.code(forStopId: "x", name: "’s-Hertogenbosch", in: i), "HT", "a curly apostrophe")
        XCTAssertEqual(NSCodes.code(forStopId: "x", name: "’s-Hertogenbosch Centraal", in: i), "HT", "with Centraal after it")
        XCTAssertEqual(NSCodes.code(forStopId: "x", name: "Breda station", in: i), "BD")
        XCTAssertEqual(NSCodes.code(forStopId: "x", name: "UTRECHT CENTRAAL", in: i), "UT")
        XCTAssertEqual(NSCodes.code(forStopId: "x", name: "Den Bosch", in: i), "HT", "a short name")
        // a stop that isn't a station: nil
        XCTAssertNil(NSCodes.code(forStopId: "nl-OpenOV_123", name: "Breda, Centraal Station", in: i), "a bus stop")
        XCTAssertNil(NSCodes.code(forStopId: "nl-OpenOV_123", name: "Veghel, Busstation", in: i))
        XCTAssertNil(NSCodes.code(forStopId: "51.59,4.79", name: "Breda University (BUas)", in: i))
        XCTAssertNil(NSCodes.code(forStopId: "x", name: nil, in: i))
        XCTAssertNil(NSCodes.code(forStopId: "x", name: "", in: i))
        // an unknown DELFI station falls back to its name
        XCTAssertEqual(NSCodes.code(forStopId: "de-DELFI_000008499999", name: "Tilburg", in: i), "TB")
        XCTAssertEqual(NSCodes.code(forStopIds: ["nl-OpenOV_1", "de-DELFI_000008400206"], name: "Somewhere", in: i), "EHV")
    }

    // MARK: the nearest station

    func test_nearestStationWithin5km() {
        let home = GeoPoint(lat: 51.4500, lon: 5.4700)          // about 1 km from Eindhoven Centraal
        XCTAssertEqual(NearestStation.pick(home, in: sample)?.code, "EHV")
        let veghel = GeoPoint(lat: 51.6137, lon: 5.5474)        // no station within 5 km (Den Bosch and Eindhoven are 19 km)
        XCTAssertNil(NearestStation.pick(veghel, in: sample))
        XCTAssertNotNil(NearestStation.pick(veghel, in: sample, within: 30_000))
        XCTAssertEqual(NearestStation.pick(GeoPoint(lat: 51.69, lon: 5.29), in: sample)?.code, "HT")
    }

    func test_trainTimePairNeedsTwoStations() {
        let eindhovenHome = GeoPoint(lat: 51.4500, lon: 5.4700), utrechtSchool = GeoPoint(lat: 52.0850, lon: 5.1200)
        let p = NearestStation.pair(home: eindhovenHome, school: utrechtSchool, in: sample)
        XCTAssertEqual(p?.home.code, "EHV")
        XCTAssertEqual(p?.school.code, "UT")
        // no rail within 5 km of home: hidden
        XCTAssertNil(NearestStation.pair(home: GeoPoint(lat: 51.6137, lon: 5.5474), school: utrechtSchool, in: sample))
        // the same station for both: hidden
        XCTAssertNil(NearestStation.pair(home: eindhovenHome, school: GeoPoint(lat: 51.4480, lon: 5.4900), in: sample))
    }

    // MARK: the auto-start's regions

    private let fontysHome = SavedPlace(id: "home", name: "Home", kind: .home, lat: 51.4500, lon: 5.4700, stopIds: ["s1", "s2"])
    private let fontysSchool = SavedPlace(id: "school", name: "Fontys", kind: .school, lat: 51.4520, lon: 5.4800)

    func test_corridorRegionsAreTodays() {
        let roles = RoleLogic.roles(.legacy)
        let r = RoleRegions.wanted(roles: roles, homeStops: [], autoStart: true, autoHome: true, schoolRadius: 350)
        XCTAssertEqual(r, [
            RegionSpec(id: "school", lat: 51.5907, lon: 4.7932, radius: 350, entry: true, exit: false),
            RegionSpec(id: "veghel", lat: 51.6137, lon: 5.5474, radius: 350, entry: false, exit: true),
            RegionSpec(id: "ht", lat: 51.6905, lon: 5.2936, radius: 300, entry: false, exit: true),
            RegionSpec(id: "ehv", lat: 51.4432, lon: 5.4812, radius: 300, entry: false, exit: true),
            RegionSpec(id: "bd", lat: 51.5955, lon: 4.7797, radius: 300, entry: false, exit: true),
        ])
        // the home board's stops don't change the corridor's
        XCTAssertEqual(RoleRegions.wanted(roles: roles, homeStops: [GeoPoint(lat: 51.6, lon: 5.5)], autoStart: true, autoHome: true, schoolRadius: 350), r)
        XCTAssertEqual(RoleRegions.wanted(roles: roles, homeStops: [], autoStart: false, autoHome: true, schoolRadius: 350), [r[0]])
        XCTAssertEqual(RoleRegions.wanted(roles: roles, homeStops: [], autoStart: true, autoHome: false, schoolRadius: 350), Array(r.dropFirst()))
        XCTAssertEqual(RoleRegions.wanted(roles: roles, homeStops: [], autoStart: false, autoHome: false, schoolRadius: 350), [])
    }

    func test_offTheCorridorHomeStopsAndSchool() {
        let roles = RoleLogic.roles(RoleInputs(home: fontysHome, school: fontysSchool, boardIds: ["s1", "s2"], corridor: nil, calendarHints: []))
        let a = GeoPoint(lat: 51.4510, lon: 5.4710), b = GeoPoint(lat: 51.4511, lon: 5.4711), c = GeoPoint(lat: 51.4480, lon: 5.4650)
        let r = RoleRegions.wanted(roles: roles, homeStops: [a, b, c], autoStart: true, autoHome: true, schoolRadius: 350)
        XCTAssertEqual(r, [
            RegionSpec(id: "school", lat: 51.4520, lon: 5.4800, radius: 350, entry: true, exit: true),
            RegionSpec(id: "home.0", lat: a.lat, lon: a.lon, radius: 350, entry: false, exit: true),
            RegionSpec(id: "home.1", lat: c.lat, lon: c.lon, radius: 350, entry: false, exit: true),       // (b is a's other side)
        ])
        // no stop with a position: Home itself
        let h = RoleRegions.wanted(roles: roles, homeStops: [], autoStart: true, autoHome: false, schoolRadius: 350)
        XCTAssertEqual(h, [RegionSpec(id: "school", lat: 51.4520, lon: 5.4800, radius: 350, entry: false, exit: true),
                           RegionSpec(id: "home", lat: 51.4500, lon: 5.4700, radius: 350, entry: false, exit: true)])
        // auto-home only: the school's entry
        XCTAssertEqual(RoleRegions.wanted(roles: roles, homeStops: [a], autoStart: false, autoHome: true, schoolRadius: 350),
                       [RegionSpec(id: "school", lat: 51.4520, lon: 5.4800, radius: 350, entry: true, exit: false)])
        XCTAssertEqual(RoleRegions.role(ofRegion: "home.2"), .home)
        XCTAssertEqual(RoleRegions.role(ofRegion: "home"), .home)
        XCTAssertEqual(RoleRegions.role(ofRegion: "school"), .school)
        XCTAssertNil(RoleRegions.role(ofRegion: "homework"))
        XCTAssertNil(RoleRegions.role(ofRegion: "veghel"))
        XCTAssertNil(RoleRegions.role(ofRegion: "backstop"))
    }

    // MARK: the door-to-door scoreboard

    func test_doorScoreKeys() {
        let home = GeoPoint(lat: 51.4500, lon: 5.4700), school = GeoPoint(lat: 51.6000, lon: 5.0800)
        let nearHome = GeoPoint(lat: 51.4600, lon: 5.4700), nearSchool = GeoPoint(lat: 51.6050, lon: 5.0800)
        XCTAssertEqual(DoorScore.key(start: nearHome, end: nearSchool, home: home, school: school)?.route, "home→school")
        XCTAssertEqual(DoorScore.key(start: nearHome, end: nearSchool, home: home, school: school)?.home, false)
        XCTAssertEqual(DoorScore.key(start: nearSchool, end: nearHome, home: home, school: school)?.route, "school→home")
        XCTAssertEqual(DoorScore.key(start: nearSchool, end: nearHome, home: home, school: school)?.home, true)
        // somewhere else: not scored
        let elsewhere = GeoPoint(lat: 52.0, lon: 5.1)
        XCTAssertNil(DoorScore.key(start: nearHome, end: elsewhere, home: home, school: school))
        XCTAssertNil(DoorScore.key(start: elsewhere, end: nearSchool, home: home, school: school))
        XCTAssertEqual(DoorScore.label("home→school", school: "Fontys"), "Home → Fontys")
        XCTAssertEqual(DoorScore.label("school→home", school: "Fontys"), "Fontys → Home")
        XCTAssertEqual(DoorScore.label("Via Den Bosch", school: "BUas"), "Via Den Bosch", "the corridor keeps its routes")
    }

    // MARK: words

    func test_previewAndDemoWordsOnTheCorridorAreTodays() {
        let w = RoleWords.legacy
        let out = w.previewRide(home: false), home = w.previewRide(home: true)
        XCTAssertEqual(out.legTitle, "Intercity to Breda")
        XCTAssertEqual(out.nextText, "Then bus 3 to BUas from Breda")
        XCTAssertTrue(out.isTrain)
        XCTAssertEqual(out.line, "IC")
        XCTAssertEqual(home.legTitle, "Bus 306 to Veghel")
        XCTAssertNil(home.nextText)
        XCTAssertEqual(home.line, "306")
        let d = w.demoNames
        XCTAssertEqual(d.busTo, "’s-Hertogenbosch, Centraal Station")
        XCTAssertEqual(d.trainTo, "Breda")
        XCTAssertEqual(d.rideStops.last, "Den Bosch, Centraal Station")
        XCTAssertEqual(d.rideEndShort, "Den Bosch")
    }

    func test_previewAndDemoWordsOffTheCorridor() {
        let w = RoleWords.make(school: "Fontys", corridor: nil, hints: [])
        XCTAssertEqual(w.previewRide(home: false).legTitle, "Bus 12 to Fontys")
        XCTAssertEqual(w.previewRide(home: true).legTitle, "Bus 12 to Home")
        XCTAssertFalse(w.previewRide(home: false).isTrain)
        XCTAssertNil(w.previewRide(home: false).nextText)
        XCTAssertEqual(w.demoNames.trainTo, "Fontys")
        XCTAssertFalse(w.demoNames.rideStops.contains { $0.contains("Bosch") || $0.contains("Breda") || $0.contains("Veghel") })
    }

    func test_trainTimeWords() {
        let l = TrainTimeWords.make(corridor: .veghelBreda, school: "BUas", homeStation: nil, schoolStation: nil)
        XCTAssertEqual(l, TrainTimeWords.legacy)
        XCTAssertEqual(l.title, "Friend’s train")
        XCTAssertEqual(l.arriveLeave(out: true), "arrive Breda")
        XCTAssertEqual(l.toStation, "To Breda")
        XCTAssertEqual(l.timeLabel(out: false), "Leave Breda at")
        XCTAssertEqual(l.footer(out: true), "Use the time of your friend’s train. The app finds that train, the bus from Veghel that gets you there in time and the bus to BUas after it.")
        XCTAssertEqual(l.footer(out: false), "Use the time of your friend’s train. The app finds that train, the bus from BUas to catch it and the bus to Veghel after it.")
        XCTAssertEqual(l.inexact(out: true, time: "08:21"), "No train arrives in Breda at exactly 08:21. This is the closest one.")
        let g = TrainTimeWords.make(corridor: nil, school: "Fontys", homeStation: "Eindhoven Centraal", schoolStation: "Utrecht Centraal")
        XCTAssertEqual(g.title, "A train’s time")
        XCTAssertEqual(g.arriveLeave(out: false), "leave Utrecht Centraal")
        XCTAssertEqual(g.timeLabel(out: true), "Arrive in Utrecht Centraal at")
        XCTAssertFalse(g.footer(out: true).contains("friend"))
        XCTAssertTrue(g.footer(out: true).contains("Eindhoven Centraal"))
    }
}
