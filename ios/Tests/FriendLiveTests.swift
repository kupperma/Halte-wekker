import XCTest
import CryptoKit

/// Friends 0.30: the live link for people without the app: its token, the lock (AES-256-GCM) byte for byte, the
/// page's words and when the phone posts (docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.30)";
/// the vectors made with Node's crypto from the spec alone, and the page's own script checked by relay/test-live.mjs).
final class FriendLiveTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)          // Friday 15 January 2027, 09:00 in Amsterdam
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let ams = TimeZone(identifier: "Europe/Amsterdam")!

    private func bytes(from a: UInt8, count: Int) -> Data { Data((0..<count).map { a + UInt8($0) }) }

    static let token = "2x1Ot-EFfLIivv_lmStBuw"
    static let link = "https://haltewekker-relay.tsfaw1.workers.dev/live/2x1Ot-EFfLIivv_lmStBuw#ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
    static let plain = "{\"dest\":\"Breda\",\"end\":1800004500,\"eta\":1800001260,\"from\":\"Veghel\",\"late\":3,\"line\":\"305\",\"mode\":\"bus\",\"name\":\"Sam\",\"pos\":{\"at\":1799999990,\"lat\":51.61672,\"lon\":5.54861},\"state\":\"riding\",\"t\":1800000000,\"to\":\"Den Bosch\",\"v\":1}"
    static let data = "AUBBQkNERUZHSElKS7l22eQjAucxcHAiTeErc14x6_Pn13qW5l7OpDBU3_8y5jF6alf-mxd1pw20reGB2e60y1bPhb3fRMafBUHNMX0XzIrkdFdZINAvfQZc6wgCKn4B3YWG2r9jXEn0RXpeVbJnZrAQ2fH-jvvebSMWbiXub8wm-a4kw_nwp59f9VyUkXutBMfsSHUt3Agu3YlcN2wqOLT2L2x4rrqImgvKvsoulSwMAdncswKlNM9vKwSvq3RIztNMa-KL1guHyZLcJ5KPVhXxLPpZVMixIoV0J937rVtJ9dYWTJ1LJ0lsBKOwV_k08p4uVV-3ue-8vAw"

    private var keys: LiveKeys { LiveKeys(secret: bytes(from: 0x00, count: 32), key: bytes(from: 0x20, count: 32)) }

    private var riding: LiveState {
        var s = LiveState(name: "Sam", state: "riding", mode: "bus", t: t0)
        s.line = "305"
        s.from = "Veghel"
        s.to = "Den Bosch"
        s.dest = "Breda"
        s.eta = Date(timeIntervalSince1970: 1_800_001_260)
        s.end = Date(timeIntervalSince1970: 1_800_004_500)
        s.late = 3
        s.pos = LiveState.Position(lat: 51.61672, lon: 5.54861, at: Date(timeIntervalSince1970: 1_799_999_990))
        return s
    }

    func test_tokenAndLink() {
        XCTAssertEqual(keys.token, Self.token)
        XCTAssertEqual(keys.link, Self.link)
        let p = LiveCrypto.parse(Self.link)
        XCTAssertEqual(p?.token, Self.token)
        XCTAssertEqual(p?.key, bytes(from: 0x20, count: 32))
        XCTAssertNil(LiveCrypto.parse("https://haltewekker-relay.tsfaw1.workers.dev/live/2x1Ot-EFfLIivv_lmStBuw"))
        XCTAssertNil(LiveCrypto.parse("https://example.com/live/2x1Ot-EFfLIivv_lmStBuw#ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"))
        let fresh = LiveKeys.make()
        XCTAssertEqual(fresh.secret.count, 32)
        XCTAssertEqual(fresh.key.count, 32)
        XCTAssertNotEqual(fresh.secret, fresh.key)
        XCTAssertEqual(fresh.token.count, 22)
    }

    func test_lockVector() throws {
        let json = try FriendJSON.encoder.encode(riding)
        XCTAssertEqual(String(decoding: json, as: UTF8.self), Self.plain)
        let sealed = try LiveCrypto.seal(json, key: keys.key, token: keys.token, nonce: try AES.GCM.Nonce(data: bytes(from: 0x40, count: 12)))
        XCTAssertEqual(B64URL.encode(sealed), Self.data)
        let opened = try LiveCrypto.open(try XCTUnwrap(B64URL.decode(Self.data)), key: keys.key, token: keys.token)
        XCTAssertEqual(try FriendJSON.decoder.decode(LiveState.self, from: opened), riding)
        // another link's token (the AAD) or key doesn't open it
        XCTAssertThrowsError(try LiveCrypto.open(sealed, key: keys.key, token: "AAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertThrowsError(try LiveCrypto.open(sealed, key: bytes(from: 0x60, count: 32), token: keys.token))
        // random nonces each time
        XCTAssertNotEqual(try LiveCrypto.lock(riding, keys: keys), try LiveCrypto.lock(riding, keys: keys))
    }

    func test_words() {
        XCTAssertEqual(LiveWords.headline(riding, zone: ams), "Sam is on bus 305 to Den Bosch · arrives 09:21 · 3 min late")
        XCTAssertEqual(LiveWords.detail(riding, zone: ams), "Then on to Breda · there around 10:15")
        var s = riding
        s.late = 0
        XCTAssertEqual(LiveWords.headline(s, zone: ams), "Sam is on bus 305 to Den Bosch · arrives 09:21 · on time")
        s = LiveState(name: "Sam", state: "waiting", mode: "train", line: "IC", num: "3512", from: "Eindhoven Centraal", to: "Breda",
                      dep: Date(timeIntervalSince1970: 1_800_001_260), t: t0)
        XCTAssertEqual(LiveWords.headline(s, zone: ams), "Sam is waiting for the IC 3512 to Breda at Eindhoven Centraal · leaves 09:21")
        XCTAssertNil(LiveWords.detail(s, zone: ams))
        s.state = "change"
        XCTAssertEqual(LiveWords.headline(s, zone: ams), "Sam is changing at Eindhoven Centraal · then the IC 3512 to Breda at 09:21")
        s.line = nil
        XCTAssertEqual(LiveWords.headline(s, zone: ams), "Sam is changing at Eindhoven Centraal")
        s = LiveState(name: "Sam", state: "arrived", mode: "bus", line: "305", to: "Den Bosch", dest: "Breda", eta: t(120), t: t(120))
        XCTAssertEqual(LiveWords.headline(s, zone: ams), "Sam has arrived at Den Bosch · 09:02")
        XCTAssertNil(LiveWords.detail(s, zone: ams))
        s = LiveState(name: " ", state: "flying", mode: "train", t: t0)
        XCTAssertEqual(LiveWords.headline(s, zone: ams), "Your friend is on the train")
        XCTAssertEqual(LiveWords.vehicle(LiveState(name: "", state: "riding", mode: "bus", t: t0)), "the bus")
        XCTAssertEqual(LiveWords.vehicle(LiveState(name: "", state: "riding", mode: "tram", line: "1", t: t0)), "tram 1")
        XCTAssertEqual(LiveWords.vehicle(LiveState(name: "", state: "riding", mode: "train", line: "SPR", t: t0)), "the SPR")
    }

    func test_rules() {
        // a put: the first at once; then every 55 s, or after 6 s when something changed
        XCTAssertTrue(LiveRules.due(lastSent: nil, lastKey: "", key: "a", now: t0))
        XCTAssertFalse(LiveRules.due(lastSent: t0, lastKey: "a", key: "a", now: t(30)))
        XCTAssertTrue(LiveRules.due(lastSent: t0, lastKey: "a", key: "a", now: t(55)))
        XCTAssertFalse(LiveRules.due(lastSent: t0, lastKey: "a", key: "b", now: t(3)))
        XCTAssertTrue(LiveRules.due(lastSent: t0, lastKey: "a", key: "b", now: t(6)))
        // until: half an hour ahead, never past 4 hours; after arriving, 15 minutes
        XCTAssertEqual(LiveRules.until(created: t0, now: t(600)), t(600 + 1800))
        XCTAssertEqual(LiveRules.until(created: t0, now: t(4 * 3600 - 60)), t(4 * 3600))
        XCTAssertEqual(LiveRules.until(created: t0, now: t(600), arrived: true), t(600 + 900))
        XCTAssertFalse(LiveRules.expired(created: t0, now: t(4 * 3600 - 1)))
        XCTAssertTrue(LiveRules.expired(created: t0, now: t(4 * 3600)))
        XCTAssertEqual(LiveRules.late(live: t(300), scheduled: t(120)), 3)
        XCTAssertEqual(LiveRules.late(live: t(60), scheduled: t(120)), 0)
        XCTAssertNil(LiveRules.late(live: nil, scheduled: t(120)))
    }

    func test_fromTravel() {
        var tr = TravelState(state: "riding", mode: "bus", line: "305", trip: "bus-305", from: TravelState.Spot(name: "Veghel", lat: 51.6, lon: 5.5),
                             to: TravelState.Spot(name: "Den Bosch", lat: 51.69, lon: 5.29))
        tr.dest = TravelState.Spot(name: "Breda")
        tr.eta = Date(timeIntervalSince1970: 1_800_001_260)
        tr.end = Date(timeIntervalSince1970: 1_800_004_500)
        tr.pos = TravelState.Position(lat: 51.61672, lon: 5.54861, acc: 12, at: Date(timeIntervalSince1970: 1_799_999_990))
        tr.coach = TravelState.Coach(n: 3, of: 6, front: true)
        let s = LiveRules.state(tr, name: " Sam ", dep: t(-60), late: 3, now: t0)
        XCTAssertEqual(s, riding)                                   // names only, no accuracy, no coach, no dep while riding
        tr.state = "waiting"
        let w = LiveRules.state(tr, name: "Sam", dep: t(300), late: nil, now: t0)
        XCTAssertEqual(w.dep, t(300))
        XCTAssertNil(w.late)
        tr.dest = TravelState.Spot(name: "Den Bosch")
        XCTAssertNil(LiveRules.state(tr, name: "Sam", dep: nil, late: nil, now: t0).dest)
        let a = LiveRules.arrived(riding, name: "Sam", stop: "Breda", at: t(4000))
        XCTAssertEqual(a, LiveState(name: "Sam", state: "arrived", mode: "bus", line: "305", from: "Veghel", to: "Breda", eta: t(4000), t: t(4000)))
        XCTAssertNotEqual(LiveRules.key(riding), LiveRules.key(w))
    }
}
