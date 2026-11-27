import XCTest

/// Listening now (relay 2026-11-27): when the song goes out, to whom, and how it's written, against
/// docs/music-vectors.json (the vectors Android and the relay check too).
final class MusicShareTests: XCTestCase {
    private var v: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = Bundle(for: Self.self).url(forResource: "music-vectors", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/music-vectors.json")
        let d = try Data(contentsOf: url)
        v = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    private func date(_ x: Any?) -> Date { Date(timeIntervalSince1970: (x as? NSNumber)?.doubleValue ?? 0) }

    private func music(_ x: Any?) -> LiveMusic? {
        guard let o = x as? [String: Any] else { return nil }
        return LiveMusic(title: o["title"] as? String ?? "", artist: o["artist"] as? String, app: o["app"] as? String,
                         url: o["url"] as? String, coverUrl: o["coverUrl"] as? String, at: o["at"] as? String ?? "")
    }

    private func song(_ base: [String: Any], _ change: [String: Any]?) -> MusicNow {
        var o: [String: Any] = base
        for (k, x) in change ?? [:] { o[k] = x }
        func s(_ k: String) -> String? { o[k] as? String }
        return MusicNow(title: s("title") ?? "", artist: s("artist") ?? "", app: s("app") ?? "", url: s("url"), coverUrl: s("coverUrl"),
                        playing: (o["playing"] as? Bool) ?? true, seen: date(o["seen"]))
    }

    func test_theCases() throws {
        let base = try XCTUnwrap(v["base"] as? [String: Any])
        let baseSong = try XCTUnwrap(base["song"] as? [String: Any])
        let want = try XCTUnwrap(music(v["music"]))
        let now: Date = date(v["now"])
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let name: String = c["case"] as? String ?? "?"
            let on: Bool = (c["on"] as? Bool) ?? (base["on"] as? Bool ?? false)
            let who: MusicAudience = MusicAudience(rawValue: (c["who"] as? String) ?? (base["who"] as? String ?? "")) ?? .all
            let travelling: Bool = (c["travelling"] as? Bool) ?? (base["travelling"] as? Bool ?? false)
            let s: MusicNow? = (c["noSong"] as? Bool) == true ? nil : song(baseSong, c["song"] as? [String: Any])
            for (key, channel) in [("friends", MusicShare.Channel.friends), ("link", MusicShare.Channel.link)] {
                let got: LiveMusic? = MusicShare.share(s, on: on, who: who, channel: channel, travelling: travelling, now: now)
                let expect: LiveMusic? = (c[key] as? Bool) == true ? want : music(c[key])
                XCTAssertEqual(got, expect, "\(name): \(key)")
            }
        }
    }

    func test_theMusicJSON() throws {
        let m = try XCTUnwrap(music(v["music"]))
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(String(decoding: try e.encode(m), as: UTF8.self), v["musicJSON"] as? String)
        XCTAssertEqual(MusicShare.iso(Date(timeIntervalSince1970: 1_799_999_970.6)), m.at)
        XCTAssertEqual(MusicShare.parseISO(m.at), Date(timeIntervalSince1970: 1_799_999_970))
    }

    func test_theTravelStateCarriesItAndOldAppsStillRead() throws {
        let t = try XCTUnwrap(v["travel"] as? [String: Any])
        let plain = try XCTUnwrap(t["plain"] as? String)
        let m = try XCTUnwrap(music(v["music"]))
        var s = TravelState(state: "riding", mode: "bus", from: .init(name: "Veghel, Busstation"), to: .init(name: "Eindhoven Centraal"))
        s.line = "305"
        s.eta = Date(timeIntervalSince1970: 1_800_000_960)
        s.music = m
        let bytes: String = String(decoding: try FriendJSON.encoder.encode(s), as: UTF8.self)
        XCTAssertEqual(bytes.replacingOccurrences(of: "\\/", with: "/"), plain)
        let back = try FriendJSON.decoder.decode(TravelState.self, from: Data(plain.utf8))
        XCTAssertEqual(back, s)
        // an app before it: the same state without `music`
        struct Old: Decodable { let state: String; let mode: String; let line: String?; let from: TravelState.Spot }
        let old = try FriendJSON.decoder.decode(Old.self, from: Data(plain.utf8))
        XCTAssertEqual(old.line, "305")
        // and a state without it reads as before
        let none = try FriendJSON.decoder.decode(TravelState.self, from: Data(#"{"from":{"name":"A"},"mode":"bus","state":"riding","to":{"name":"B"}}"#.utf8))
        XCTAssertNil(none.music)
    }

    func test_theLiveLinkKeepsItAndAPutFollowsANewSong() throws {
        let m = try XCTUnwrap(music(v["music"]))
        var a = LiveState(name: "Sam", state: "riding", mode: "bus", t: Date(timeIntervalSince1970: 1_800_000_000))
        var b = a
        b.music = m
        XCTAssertNotEqual(LiveRules.key(a), LiveRules.key(b))
        a.music = m
        XCTAssertEqual(LiveRules.key(a), LiveRules.key(b))
        let built: LiveState = LiveTripV2.build(b, LiveTripV2.Trip(legs: [], leg: 0, music: m), now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(built.music, m)
    }

    func test_iTunes() throws {
        let it = try XCTUnwrap(v["itunes"] as? [String: Any])
        for q in try XCTUnwrap(it["queries"] as? [[String: Any]]) {
            let u = MusicShare.searchURL(title: q["title"] as? String ?? "", artist: q["artist"] as? String ?? "")
            XCTAssertEqual(u?.absoluteString, q["url"] as? String)
        }
        let answer = try JSONSerialization.data(withJSONObject: try XCTUnwrap(it["answer"]))
        for p in try XCTUnwrap(it["picks"] as? [[String: Any]]) {
            let got = MusicShare.itunesPick(answer, title: p["title"] as? String ?? "", artist: p["artist"] as? String ?? "")
            if (p["none"] as? Bool) == true {
                XCTAssertNil(got, "\(p)")
            } else {
                XCTAssertEqual(got?.coverUrl, p["coverUrl"] as? String)
                XCTAssertEqual(got?.url, p["url"] as? String)
            }
        }
        XCTAssertNil(MusicShare.itunesPick(Data("{\"results\":[]}".utf8), title: "a", artist: "b"))
        XCTAssertNil(MusicShare.itunesPick(Data("nope".utf8), title: "a", artist: "b"))
    }

    func test_theRelaysAnswer() throws {
        let r = try XCTUnwrap(v["relay"] as? [String: Any])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sp = try JSONSerialization.data(withJSONObject: try XCTUnwrap(r["spotify"]))
        let s = try XCTUnwrap(MusicShare.relaySong(sp, now: now))
        XCTAssertEqual(s.title, "Midnight City")
        XCTAssertEqual(s.artist, "M83")
        XCTAssertEqual(s.app, "Spotify")
        XCTAssertEqual(s.url, "https://open.spotify.com/search/M83%20Midnight%20City")
        XCTAssertEqual(s.seen, now)
        XCTAssertTrue(s.playing)
        let idle = try JSONSerialization.data(withJSONObject: try XCTUnwrap(r["idle"]))
        XCTAssertNil(MusicShare.relaySong(idle, now: now))
        XCTAssertNil(MusicShare.relaySong(Data("{\"error\":\"not_configured\"}".utf8), now: now))
    }

    func test_lookingAndUsernames() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(MusicShare.lookDue(last: nil, now: t))
        XCTAssertFalse(MusicShare.lookDue(last: t.addingTimeInterval(-29), now: t))
        XCTAssertTrue(MusicShare.lookDue(last: t.addingTimeInterval(-30), now: t))
        XCTAssertTrue(MusicShare.lookDue(last: t.addingTimeInterval(60), now: t), "a clock that went back")
        XCTAssertEqual(MusicShare.lookEvery, (v["lookEvery"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(MusicShare.maxAge, (v["maxAge"] as? NSNumber)?.doubleValue)
        XCTAssertTrue(MusicShare.validUser("Test_1"))
        XCTAssertTrue(MusicShare.validUser(" rj "))
        XCTAssertFalse(MusicShare.validUser("a"))
        XCTAssertFalse(MusicShare.validUser("1abc"))
        XCTAssertFalse(MusicShare.validUser("abc&x=1"))
        XCTAssertFalse(MusicShare.validUser("abcdefghijklmnop"))
        XCTAssertFalse(MusicShare.reaches(.friends, .link))
        XCTAssertFalse(MusicShare.reaches(.links, .friends))
        XCTAssertTrue(MusicShare.reaches(.all, .link))
    }
}
