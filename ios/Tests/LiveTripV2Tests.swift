import XCTest
import CryptoKit

/// Live link payload v2 and messages (relay 2026-11-27): byte for byte against docs/live-link-vectors.json, the vector the
/// live page's own script (relay/test-live.mjs) and Android (LiveTripV2Test.kt) check too. Made up names and places.
final class LiveTripV2Tests: XCTestCase {
    private func bytes(from a: UInt8, count: Int) -> Data { Data((0..<count).map { a + UInt8($0) }) }
    private func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }
    private var key: Data { bytes(from: 0x20, count: 32) }
    private let token = "2x1Ot-EFfLIivv_lmStBuw"
    private let now = Date(timeIntervalSince1970: 1800000000)

    static let plain = "{\"dest\":\"Campus\",\"end\":1800005400,\"eta\":1800000960,\"face\":\"3DD598\",\"from\":\"Veghel, Busstation\",\"inbox\":true,\"late\":0,\"leg\":0,\"legs\":[{\"arr\":1800000960,\"color\":\"E0632E\",\"dep\":1799999640,\"from\":\"Veghel, Busstation\",\"late\":0,\"line\":\"305\",\"mode\":\"bus\",\"to\":\"Eindhoven Centraal\"},{\"arr\":1800001200,\"dep\":1800000960,\"from\":\"Eindhoven Centraal\",\"mins\":4,\"mode\":\"walk\",\"to\":\"Eindhoven Centraal\"},{\"arr\":1800003840,\"arrPlatform\":\"6\",\"coach\":3,\"color\":\"3B44B0\",\"deck\":\"upper\",\"dep\":1800001500,\"depPlatform\":\"4\",\"from\":\"Eindhoven Centraal\",\"late\":1,\"line\":\"IC\",\"mode\":\"train\",\"num\":\"3512\",\"to\":\"Breda\"},{\"arr\":1800005220,\"color\":\"E0632E\",\"dep\":1800004440,\"depPlatform\":\"E\",\"from\":\"Breda\",\"line\":\"1\",\"mode\":\"bus\",\"to\":\"Breda, Hogeschool\"},{\"arr\":1800005400,\"dep\":1800005220,\"from\":\"Breda, Hogeschool\",\"mins\":3,\"mode\":\"walk\",\"to\":\"Campus\"}],\"line\":\"305\",\"mode\":\"bus\",\"music\":{\"app\":\"Spotify\",\"artist\":\"The Bands\",\"at\":\"2027-01-15T07:59:00Z\",\"coverUrl\":\"https://i.scdn.co/image/ab67616d0000b2730000000000000000000000\",\"title\":\"Night Song\",\"url\":\"https://open.spotify.com/track/0000000000000000000000\"},\"name\":\"Sam\",\"next\":3,\"pos\":{\"at\":1799999988,\"lat\":51.54801,\"lon\":5.4685,\"src\":\"gps\"},\"shape\":\"mk`zHwuz`@`b@ns@be@v~@zm@jiAvkB~|Db~@rmBb[r]ja@z^fw@wj@vcA_q@~mDooBbcArNjdArN~{Bnd@zuAfJnpAlF\",\"state\":\"riding\",\"stops\":[{\"lat\":51.61671,\"lon\":5.5486,\"name\":\"Veghel, Busstation\",\"t\":1799999640},{\"lat\":51.605,\"lon\":5.53,\"name\":\"Eerde\",\"t\":1799999880},{\"lat\":51.57,\"lon\":5.47,\"name\":\"Sint-Oedenrode, Centrum\",\"t\":1799999980},{\"lat\":51.54,\"lon\":5.475,\"name\":\"Rijksweg\",\"t\":1800000180},{\"lat\":51.512,\"lon\":5.493,\"name\":\"Son, Centrum\",\"t\":1800000420},{\"lat\":51.44306,\"lon\":5.47901,\"name\":\"Eindhoven Centraal\",\"t\":1800000960}],\"t\":1800000000,\"to\":\"Eindhoven Centraal\",\"v\":2}"
    static let data = "AUBBQkNERUZHSElKS7l22eQjAucxcHExRfU_IlA_rPjtkWKd71bOpDBQ3_sy-j89e0K9gxx8rw20reCD1uioxRLbi7OYXN7rU2LhYSgNwoSqc1FTb8gmc3JV5Q4CZGgDrMDAi-cgRU__TnpIVbl8d_1E2aXrkeuZeyMpbjypYdRmuv9qnOXw_NtR7QHGzzG2B6WuUyRzjEZ1mJNWMm00Prz2KHJ277mLm1vSscZekSIJAuHSvVO1MMsoMw-64CQVnoQdff6FgE_Pl8fOLYDpA0KpebpXAOXma9REI8eygFoYupxYActYJ0ltVaicc9wIeK6iOmK8u81rmQTYUzPZM7r49VsSxzYKAbaxBCG5YEx1-riJpeavcQlTLzlfxEQ8J5ubT1tTPMJCRsyjqM1WQ8aSxOv8eH7Yc6PUePetHcETuoVtyfjLalmnlbFlHBZ8RGt_6Aif7Ed_ZAgr1ZdrwzAanZ-eevplmrVFZf84DsOOiSKYbXT_3pqFZaOvdFbbop5oK-eD1za9QGmBoB__dH0VmIEzDqMraDodAgp31v6iTHCD6kFStM8S6WFfblqUKKXbR_usQi8BYk5ccOx9Bx1goeejnHaxwApEpnwVfuLNp1VVcHLyjH_lhlJVmAkVv8xoUiIyAIok8X_ON0HiDer4LQq1NNY6MMAFSxqXyIzCnB_jlXgaduSPcFX4lxfSf_BYLSaAe58tqkW7SkHVTEpuIabQQG_DJC69VmLDtMpPKjAo6puj2JWnTQ9kfL8PTssJFvVq55beLdhmnroLBQLgxi9SaSXOsbsFhNErgWHBVQP5RY5jxBPzPZJUMEu_gckS-h4fJJbOSA5A1GVtHdLnLZxGhUstqM1DnSEl0jNS8ZumhPvJGjLQWKDoMuvxEfNeZyCQtG-iuj90a4dBjFLAmXIjJXB5o6Eak9T1evlw0tEKZLwtj7g03kScBahTNPVwwGfjPE3jNAjsLbsZIkScGsN_ACCBl9UBvzG6RYirZf9qMYZmYp5XlOAgibKFL-eY-WdL813Sj483kxBBfQaGzQDqJTAITLqfw531jjwvY98KSB8KBBPdSCja-cQ90ZzDp8-wL2GE5gg3RJ7Jqz2NHy3u75mOix_moG5hifOViLT93a1Cvaljt28ZvHmqQpNrf0YM5fPD7BvQVYXWega32LX-48jDPkSNXtNBsKs1IquAdBlSmVoLMQFxDe3Dy7lmM6nfmUz31v2ATSM3Bo3IiSo3bwWloeMSKjMf99IdYpZmvlBky2_-6Lsos_V3P-g0R6J7QoL3hml8-Iyea3s49YEZ8SmatjBH0-y-rKYEfH02xx5Psczs5JCbREY2nxo_saPY1DSC3cvegYChgvZ_Fjtjl0Iaj1XK9TknvT_B44Dym-2HldXf28av3YbvUAtA16-6JzSg7ThF1CuiU3FVP9ADcCuQzX6Z4_MmPEIdtrt_cpM6DdbAbzsJHMLsFOeJhcKLUQOjBf6OiSMTzL-GvG4JwSZsaNHVEkdjzShHnMzhRDGxFJeZSo5V7xV9WnOliH335w6j1mTfB0hVCo8pgUUvMmVTQpiulB-SoOHyD0jzItAICXeQPiMslXG6szmO4dgmDs1CFRIUTkCo_A8S7CqiEtT7WUsLRmpwAtXN7IAyxyvmU-ZgZVN-oTfY1i9Hb43Y0RdnpX9gzjv-aNLWpVpsliALFGEVPrNWjqussCh7vMlBc_LiLBoOGNWIpy2JlHqdCNCezX3DhWZOSuYrT8q_J5RPTGi0jBC9ZlAkWRvXWSEaZzedtTEzVZi8yVoaXonifw-0-w8AYqXhG_IgWK9JahlfZHUHBMoBv7F751BQtLyXmGnFjsOqSo2I-sXynJvgRzt6J4EtO_8xxAAspTWb_aqKwoHyPj_of4_bgmjcZ9WJ_CFzWWOMnLcRoJHfM3oirbquL6Nc5L0s_YyqvERpGrycVkt8Qt-bSVfShm6dL-DTv5goQ0ZU3NsfB33K7eiWJ6i96Rdod-QhXtJGOyiwWEMfmRwxRAm6gOxaT7k2aGrDTEJ55iTs4Sx96DoT_sg_ecSCnK1xjSdH-qTfMs7T28ac5AzXKiL50DLi5J8w2c4hyqs4sRpu7117sQlzMs5lPpTtHydorQqthiHeZXS6RN_Pza4U23XOHFPNYekL6Qk2YYmxeXGzdBW_TefPkFnNRx77TTE41LvSv_rdeEsC3PmesLkO-GaKVmmCEjdSeWhCSwpALPlmAq-xKwQ6zH4c3Fofdbt7L7WNfLt-zhMZ0-3Yh0kZK3d77k-hJKSps-pU39bEATNS1ytHuzCyIr_R-RmGH7OPTbodWVowC3TPVfcXlGKyM9oH54bDG2vMzG9R52ljQP4THcBdrEkqRA"
    static let message = (plain: "{\"at\":1800000030,\"from\":\"Kim\",\"fromKind\":\"web\",\"text\":\"👋 On my way\"}", nonce: "505152535455565758595a5b", data: "AVBRUlNUVVZXWFlaW8qCyWYTFUY1BD86Kl05sJ_wzilNF5tbOoC3sTeSJgJfk6krkw9P3VAfsBsjjeGD-I81QjpRAOjCxDqCAAGhVTjTXXWVuSBBxYx3WZdBu-oZjsyjLUPeFg")
    static let appMessage = (plain: "{\"at\":1800000040,\"friendId\":\"3c157621a97cf055f5804a9826c6d1e1\",\"from\":\"Lou\",\"fromKind\":\"app\",\"text\":\"I’m at the station\"}", nonce: "606162636465666768696a6b", data: "AWBhYmNkZWZnaGlqa5m2zN_R6kptyXRXjCV6R0leJf1wKGg2rULDm1Kt4tAMVZxKsRWi6cw_GlVtBzxHP3n9XpD0PM8AjG6BQi_qcxGOZHxKuyKZ3wftDGenG0iJkBNZpxn4TtTDSIu2zaK6IIJ3wObbosQl9xf9Mpx7fvL_kpDxUDtaMonvLF2uAafbW71dYUe1RuhojL8")
    static let reply = (plain: "{\"at\":1800000060,\"re\":1,\"text\":\"See you there\"}", nonce: "707172737475767778797a7b", data: "AXBxcnN0dXZ3eHl6exJcAx_1kvZmGCsQcFjCNiNEabLKKyJR0-OVBDCgTaM_sf-K0Yq7KUzSc3hDZqa9zEND_jzWJCZGOm763Qsv7w")
    static let link = "https://haltewekker-relay.tsfaw1.workers.dev/live/2x1Ot-EFfLIivv_lmStBuw#k=ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
    static let appLink = "haltewekker://live/2x1Ot-EFfLIivv_lmStBuw#k=ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"

    private var base: LiveState {
        var s = LiveState(name: "Sam", state: "riding", mode: "bus", t: now)
        s.line = "305"
        s.from = "Veghel, Busstation"
        s.to = "Eindhoven Centraal"
        s.dest = "Campus"
        s.eta = Date(timeIntervalSince1970: 1800000960)
        s.end = Date(timeIntervalSince1970: 1800005400)
        s.late = 0
        s.pos = LiveState.Position(lat: 51.55001, lon: 5.46802, at: Date(timeIntervalSince1970: 1799999985))
        return s
    }

    private var trip: LiveTripV2.Trip {
        let legs: [LiveTripV2.LegIn] = [
            LiveTripV2.LegIn(mode: "bus", line: "305", from: "Veghel, Busstation", to: "Eindhoven Centraal", dep: 1799999640, arr: 1800000960, late: 0),
            LiveTripV2.LegIn(mode: "walk", from: "Eindhoven Centraal", to: "Eindhoven Centraal", dep: 1800000960, arr: 1800001200, mins: 4),
            LiveTripV2.LegIn(mode: "train", line: "IC", num: "3512", from: "Eindhoven Centraal", to: "Breda", dep: 1800001500, arr: 1800003840, depPlatform: "4", arrPlatform: "6", coach: 3, deck: "upper", late: 1),
            LiveTripV2.LegIn(mode: "bus", line: "1", from: "Breda", to: "Breda, Hogeschool", dep: 1800004440, arr: 1800005220, depPlatform: "E"),
            LiveTripV2.LegIn(mode: "walk", from: "Breda, Hogeschool", to: "Campus", dep: 1800005220, arr: 1800005400, mins: 3),
        ]
        let stops: [LiveTripV2.StopIn] = [
            LiveTripV2.StopIn(name: "Veghel, Busstation", lat: 51.6167123, lon: 5.5486049, t: 1799999640),
            LiveTripV2.StopIn(name: "Eerde", lat: 51.605, lon: 5.53, t: 1799999880),
            LiveTripV2.StopIn(name: "Sint-Oedenrode, Centrum", lat: 51.57, lon: 5.47, t: 1799999980),
            LiveTripV2.StopIn(name: "Rijksweg", lat: 51.54, lon: 5.475, t: 1800000180),
            LiveTripV2.StopIn(name: "Son, Centrum", lat: 51.512, lon: 5.493, t: 1800000420),
            LiveTripV2.StopIn(name: "Eindhoven  Centraal\u{7}", lat: 51.4430567, lon: 5.4790111, t: 1800000960),
        ]
        let shape: [GeoPoint] = [GeoPoint(lat: 51.62, lon: 5.555), GeoPoint(lat: 51.6167123, lon: 5.5486049), GeoPoint(lat: 51.6111, lon: 5.5402), GeoPoint(lat: 51.605, lon: 5.53), GeoPoint(lat: 51.5975, lon: 5.5181), GeoPoint(lat: 51.59, lon: 5.505), GeoPoint(lat: 51.5801, lon: 5.4877), GeoPoint(lat: 51.57, lon: 5.47), GeoPoint(lat: 51.5655, lon: 5.4651), GeoPoint(lat: 51.56, lon: 5.46), GeoPoint(lat: 51.551, lon: 5.467), GeoPoint(lat: 51.54, lon: 5.475), GeoPoint(lat: 51.526, lon: 5.484), GeoPoint(lat: 51.512, lon: 5.493), GeoPoint(lat: 51.5011, lon: 5.4905), GeoPoint(lat: 51.49, lon: 5.488), GeoPoint(lat: 51.47, lon: 5.482), GeoPoint(lat: 51.4561, lon: 5.4802), GeoPoint(lat: 51.4430567, lon: 5.4790111), GeoPoint(lat: 51.44, lon: 5.47)]
        let music = LiveMusic(title: "Night Song", artist: "The Bands", app: "Spotify", url: "https://open.spotify.com/track/0000000000000000000000", coverUrl: "https://i.scdn.co/image/ab67616d0000b2730000000000000000000000", at: "2027-01-15T07:59:00Z")
        return LiveTripV2.Trip(legs: legs, leg: 0, stops: stops, shape: shape,
                               vehicle: LiveTripV2.Vehicle(lat: 51.5480123, lon: 5.4685049, at: 1799999988),
                               face: "3dd598", inbox: true, music: music)
    }

    func test_payloadV2ByteForByte() throws {
        let s: LiveState = LiveTripV2.build(base, trip, now: now)
        let json: Data = try LiveCrypto.encoder.encode(s)
        XCTAssertEqual(String(decoding: json, as: UTF8.self), Self.plain)
        let sealed: Data = try LiveCrypto.seal(json, key: key, token: token, nonce: try AES.GCM.Nonce(data: hex("404142434445464748494a4b")))
        XCTAssertEqual(B64URL.encode(sealed), Self.data)
        let back: LiveState = try FriendJSON.decoder.decode(LiveState.self, from: try LiveCrypto.open(sealed, key: key, token: token))
        XCTAssertEqual(back.v, 2)
        XCTAssertEqual(back.legs?.count, 5)
        XCTAssertEqual(back.pos?.src, "gps")
        XCTAssertEqual(back.next, 3)
        XCTAssertEqual(back.stops?.last?.name, "Eindhoven Centraal")
        // the v1 words still read for a page before v2
        XCTAssertEqual(LiveWords.headline(back).components(separatedBy: " · ").first, "Sam is on bus 305 to Eindhoven Centraal")
    }

    func test_messagesByteForByte() throws {
        let all: [(String, (plain: String, nonce: String, data: String))] = [(LiveMessages.msg, Self.message), (LiveMessages.msg, Self.appMessage), (LiveMessages.reply, Self.reply)]
        for (kind, x) in all {
            let d: Data = try XCTUnwrap(B64URL.decode(x.data))
            XCTAssertEqual(String(decoding: try LiveCrypto.open(d, key: key, token: token, kind: kind), as: UTF8.self), x.plain)
            let sealed: Data = try LiveCrypto.seal(Data(x.plain.utf8), key: key, token: token, kind: kind, nonce: try AES.GCM.Nonce(data: hex(x.nonce)))
            XCTAssertEqual(B64URL.encode(sealed), x.data)
        }
        let web: LiveMessage = try XCTUnwrap(LiveMessages.open(try XCTUnwrap(B64URL.decode(Self.message.data)), key: key, token: token))
        XCTAssertEqual(web, LiveMessage(from: "Kim", fromKind: "web", friendId: nil, text: "👋 On my way", at: 1_800_000_030))
        let app: LiveMessage = try XCTUnwrap(LiveMessages.open(try XCTUnwrap(B64URL.decode(Self.appMessage.data)), key: key, token: token))
        XCTAssertEqual(app.fromKind, "app")
        XCTAssertEqual(app.friendId, "3c157621a97cf055f5804a9826c6d1e1")
        XCTAssertEqual(LiveMessages.notice(app) { $0 == "3c157621a97cf055f5804a9826c6d1e1" ? "Lou (friend)" : nil }, "💬 Lou (friend): I’m at the station")
        XCTAssertEqual(LiveMessages.notice(web) { _ in nil }, "💬 Kim: 👋 On my way")
        XCTAssertEqual(LiveMessages.notice(LiveMessage(text: "Hi", at: 1)) { _ in nil }, "💬 Someone with your link: Hi")
        // a message isn't a trip state (another AAD), nor an answer
        let md: Data = try XCTUnwrap(B64URL.decode(Self.message.data))
        XCTAssertThrowsError(try LiveCrypto.open(md, key: key, token: token))
        XCTAssertNil(LiveMessages.openReply(md, key: key, token: token))
        XCTAssertEqual(LiveMessages.openReply(try XCTUnwrap(B64URL.decode(Self.reply.data)), key: key, token: token), LiveReply(text: "See you there", at: 1_800_000_060, re: 1))
        // sent from this app: its name and account; read back the same
        let mine = LiveMessage(from: "Lou", fromKind: "app", friendId: "3c157621a97cf055f5804a9826c6d1e1", text: "I’m at the station", at: 1_800_000_040)
        XCTAssertEqual(LiveMessages.open(try LiveMessages.seal(mine, key: key, token: token), key: key, token: token), mine)
    }

    func test_messagesAreCleaned() {
        XCTAssertNil(LiveMessages.valid(LiveMessage(text: "  \n ", at: 1)))
        let long: LiveMessage? = LiveMessages.valid(LiveMessage(from: "K\u{7}im", text: String(repeating: "x", count: 400), at: 1.5))
        XCTAssertEqual(long?.text.count, 280)
        XCTAssertEqual(long?.from, "Kim")
        XCTAssertEqual(long?.at, 1)
        XCTAssertNil(LiveMessages.valid(LiveMessage(from: "Kim", fromKind: "web", friendId: "3c157621a97cf055f5804a9826c6d1e1", text: "hi", at: 1))?.friendId)
        XCTAssertNil(LiveMessages.valid(LiveMessage(from: "Kim", fromKind: "app", friendId: "not-an-id", text: "hi", at: 1))?.friendId)
        XCTAssertEqual(LiveMessages.valid(LiveMessage(from: "Kim", fromKind: "robot", text: "hi", at: 1))?.fromKind, "web")
        XCTAssertEqual(LiveMessages.chips.count, 4)
    }

    func test_links() throws {
        XCTAssertEqual(LiveCrypto.parse(Self.link)?.token, token)
        XCTAssertEqual(LiveCrypto.parse(Self.appLink)?.token, token)
        XCTAssertEqual(LiveCrypto.parse(Self.appLink)?.key, key)
        XCTAssertEqual(LiveCrypto.parse("  " + Self.appLink + "\n")?.key, key)
        XCTAssertNil(LiveCrypto.parse("haltewekker://live/" + token))
        XCTAssertNil(LiveCrypto.parse("haltewekker://friend?v=1&k=x"))
        XCTAssertNil(LiveCrypto.parse("haltewekker://live/short#k=" + B64URL.encode(key)))
        XCTAssertNil(LiveCrypto.parse("https://example.com/live/" + token + "#k=" + B64URL.encode(key)))
        XCTAssertEqual(LiveMessages.find("Follow my trip live:\n" + Self.link + " thanks"), Self.link)
        XCTAssertEqual(LiveMessages.find("open " + Self.appLink), Self.appLink)
        XCTAssertNil(LiveMessages.find("no link here"))
    }

    func test_theNameIsYours() throws {
        XCTAssertEqual(LiveNames.sender(friends: "Sam", typed: "Kim"), "Sam")
        XCTAssertEqual(LiveNames.sender(friends: "", typed: " Kim "), "Kim")
        XCTAssertEqual(LiveNames.sender(friends: nil, typed: "Kim"), "Kim")
        XCTAssertEqual(LiveNames.sender(friends: nil, typed: nil), "")      // the page says "Your friend"
        var b = base
        b.name = "Robin"
        let s: LiveState = LiveTripV2.build(b, trip, now: now)
        XCTAssertEqual(s.name, "Robin")
        XCTAssertFalse(String(decoding: try LiveCrypto.encoder.encode(s), as: UTF8.self).contains(Maker.name))
    }

    func test_roadAndBudget() {
        func count(_ p: String?) -> Int {
            guard let p else { return 0 }
            var n = 0, i = p.unicodeScalars.startIndex, k = 0
            while i < p.unicodeScalars.endIndex {
                let c = Int(p.unicodeScalars[i].value) - 63
                i = p.unicodeScalars.index(after: i)
                if c < 32 { k += 1; if k % 2 == 0 { n += 1 } }
            }
            return n
        }
        let straight: [GeoPoint] = (0...500).map { GeoPoint(lat: 51.0 + Double($0) * 0.0001, lon: 5.0) }
        let ab: [LiveTripV2.StopIn] = [LiveTripV2.StopIn(name: "A", lat: 51.0, lon: 5.0), LiveTripV2.StopIn(name: "B", lat: 51.05, lon: 5.0)]
        XCTAssertEqual(count(LiveTripV2.road(straight, ab)), 2)
        let wiggly: [GeoPoint] = (0...3000).map { i -> GeoPoint in
            let w: Double = (i % 2 == 0 ? 0.001 : -0.001) * Double(i % 7)
            return GeoPoint(lat: 51.0 + Double(i) * 0.00002, lon: 5.0 + w)
        }
        let n: Int = count(LiveTripV2.road(wiggly, [LiveTripV2.StopIn(name: "A", lat: 51.0, lon: 5.0), LiveTripV2.StopIn(name: "B", lat: 51.06, lon: 5.0)]))
        XCTAssertTrue((2...200).contains(n))
        XCTAssertEqual(count(LiveTripV2.road([], ab)), 2)
        XCTAssertNil(LiveTripV2.road([], Array(ab.prefix(1))))
        var t = trip
        t.stops = (0..<60).map { LiveTripV2.StopIn(name: "A stop with a rather long name number \($0)", lat: 51.0 + Double($0) * 0.001, lon: 5.0, t: 1_800_000_000 + Double($0) * 60) }
        t.shape = wiggly
        let s: LiveState = LiveTripV2.build(base, t, now: now)
        XCTAssertLessThanOrEqual(LiveTripV2.bytes(s), LiveTripV2.budget)
        XCTAssertEqual(s.stops?.count, 60)
        XCTAssertEqual(s.state, "riding")
        XCTAssertEqual(LiveTripV2.color("bus", "305"), "E0632E")
        XCTAssertEqual(LiveTripV2.color("train", "SPR"), "0A93B5")
        XCTAssertEqual(LiveTripV2.color("train", "IC"), "3B44B0")
        XCTAssertNil(LiveTripV2.color("walk", nil))
        XCTAssertEqual(LiveTripV2.face(nil), "0E7A55")
    }

    func test_v1VectorUnchanged() throws {
        // 0.30's state still locks to its own vector with the new encoder (no slashes in it)
        var s = LiveState(name: "Sam", state: "riding", mode: "bus", t: Date(timeIntervalSince1970: 1_800_000_000))
        s.line = "305"
        s.from = "Veghel"
        s.to = "Den Bosch"
        s.dest = "Breda"
        s.eta = Date(timeIntervalSince1970: 1_800_001_260)
        s.end = Date(timeIntervalSince1970: 1_800_004_500)
        s.late = 3
        s.pos = LiveState.Position(lat: 51.61672, lon: 5.54861, at: Date(timeIntervalSince1970: 1_799_999_990))
        XCTAssertEqual(String(decoding: try LiveCrypto.encoder.encode(s), as: UTF8.self), FriendLiveTests.plain)
    }

    // MARK: (0.42.9) each leg's own road, the picture: docs/live-link-vectors.json's input2, state2 and face

    private func vectors() throws -> [String: Any] {
        let url = Bundle(for: Self.self).url(forResource: "live-link-vectors", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/live-link-vectors.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func point(_ x: Any?) -> GeoPoint? {
        guard let a = x as? [Double], a.count == 2 else { return nil }
        return GeoPoint(lat: a[0], lon: a[1])
    }

    private func input2(_ v: [String: Any]) throws -> (LiveState, LiveTripV2.Trip) {
        let inp: [String: Any] = try XCTUnwrap(v["input2"] as? [String: Any])
        let t: [String: Any] = try XCTUnwrap(inp["trip"] as? [String: Any])
        var s = LiveState(name: "Sam", state: "change", mode: "train", t: Date(timeIntervalSince1970: 1800001300))
        s.line = "IC"
        s.from = "Eindhoven Centraal"
        s.to = "Breda"
        s.dest = "Campus"
        s.dep = Date(timeIntervalSince1970: 1800001500)
        s.eta = Date(timeIntervalSince1970: 1800003840)
        s.end = Date(timeIntervalSince1970: 1800005400)
        s.late = 1
        s.pos = LiveState.Position(lat: 51.4425123, lon: 5.4770249, at: Date(timeIntervalSince1970: 1800001290))
        let rows: [[String: Any]] = try XCTUnwrap(t["legs"] as? [[String: Any]])
        var legs: [LiveTripV2.LegIn] = []
        for l in rows {
            let mode: String = l["mode"] as? String ?? ""
            let from: String = l["from"] as? String ?? ""
            let to: String = l["to"] as? String ?? ""
            var x = LiveTripV2.LegIn(mode: mode, from: from, to: to)
            x.line = l["line"] as? String
            x.num = l["num"] as? String
            x.dep = l["dep"] as? Double
            x.arr = l["arr"] as? Double
            x.depPlatform = l["depPlatform"] as? String
            x.arrPlatform = l["arrPlatform"] as? String
            x.late = l["late"] as? Int
            x.mins = l["mins"] as? Int
            x.fromPt = point(l["fromPt"])
            x.toPt = point(l["toPt"])
            let road: [Any] = l["road"] as? [Any] ?? []
            x.road = road.compactMap { point($0) }
            legs.append(x)
        }
        var trip = LiveTripV2.Trip(legs: legs, leg: t["leg"] as? Int ?? 0)
        trip.face = t["face"] as? String
        trip.inbox = true
        trip.pic = t["pic"] as? Int
        return (s, trip)
    }

    private func decode(_ p: String) -> [GeoPoint] {
        var out: [GeoPoint] = []
        let b: [UInt8] = Array(p.utf8)
        var i: Int = 0
        var lat: Int = 0
        var lon: Int = 0
        while i < b.count {
            var vals: [Int] = []
            for _ in 0..<2 {
                var shift: Int = 0
                var res: Int = 0
                var c: Int = 0
                repeat {
                    c = Int(b[i]) - 63
                    i += 1
                    res |= (c & 31) << shift
                    shift += 5
                } while c >= 32 && i < b.count
                let half: Int = res >> 1
                vals.append((res & 1) != 0 ? ~half : half)
            }
            lat += vals[0]
            lon += vals[1]
            out.append(GeoPoint(lat: Double(lat) / 1e5, lon: Double(lon) / 1e5))
        }
        return out
    }

    func test_legRoadsByteForByte() throws {
        let v = try vectors()
        let (base, trip) = try input2(v)
        let s: LiveState = LiveTripV2.build(base, trip, now: Date(timeIntervalSince1970: 1800001300))
        let want: [String: Any] = try XCTUnwrap(v["state2"] as? [String: Any])
        let json: Data = try LiveCrypto.encoder.encode(s)
        XCTAssertEqual(String(decoding: json, as: UTF8.self), want["plain"] as? String)
        let nonce = try AES.GCM.Nonce(data: hex(try XCTUnwrap(want["nonce"] as? String)))
        XCTAssertEqual(B64URL.encode(try LiveCrypto.seal(json, key: key, token: token, nonce: nonce)), want["data"] as? String)
        let legs: [LiveLeg] = try XCTUnwrap(s.legs)
        XCTAssertNil(legs[0].shape, "before the walk: none")
        XCTAssertEqual(decode(try XCTUnwrap(legs[1].shape)).count, 2)
        let ic: [GeoPoint] = decode(try XCTUnwrap(legs[2].shape))
        XCTAssertTrue((3...LiveTripV2.maxLegShape).contains(ic.count))
        XCTAssertGreaterThan(decode(try XCTUnwrap(legs[3].shape)).count, 2)
        XCTAssertEqual(s.pic, 2)
        XCTAssertEqual(s.pos?.src, "phone")
        XCTAssertNil(s.shape)
        // with a road of its own the current ride sends none
        var t2 = trip
        t2.stops = [LiveTripV2.StopIn(name: "A", lat: 51.44, lon: 5.47), LiveTripV2.StopIn(name: "B", lat: 51.59, lon: 4.78)]
        let own: LiveState = LiveTripV2.build(base, t2, now: Date(timeIntervalSince1970: 1800001300))
        XCTAssertNil(own.legs?[2].shape)
        var s3: LiveState = s
        s3.pic = 3
        XCTAssertNotEqual(LiveRules.key(s), LiveRules.key(s3))
    }

    func test_faceByteForByte() throws {
        let v = try vectors()
        let f: [String: Any] = try XCTUnwrap(v["face"] as? [String: Any])
        let jpeg: Data = try XCTUnwrap(B64URL.decode(try XCTUnwrap(f["plain"] as? String)))
        let nonce = try AES.GCM.Nonce(data: hex(try XCTUnwrap(f["nonce"] as? String)))
        let sealed: Data = try LiveFace.seal(jpeg, key: key, token: token, nonce: nonce)
        XCTAssertEqual(B64URL.encode(sealed), f["data"] as? String)
        XCTAssertEqual(try LiveFace.open(sealed, key: key, token: token), jpeg)
        // its own AAD: not a trip state, not a message
        XCTAssertThrowsError(try LiveCrypto.open(sealed, key: key, token: token))
        XCTAssertThrowsError(try LiveCrypto.open(sealed, key: key, token: token, kind: LiveMessages.msg))
        let stamp: String = LiveFace.stamp(jpeg)
        XCTAssertEqual(stamp.count, 32)
        XCTAssertEqual(LiveFace.stamp(nil), "")
        let at = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(LiveFace.due(stamp, sent: "", lastTry: nil, now: at))
        XCTAssertFalse(LiveFace.due(stamp, sent: stamp, lastTry: nil, now: at))
        XCTAssertFalse(LiveFace.due("", sent: "", lastTry: nil, now: at))
        XCTAssertFalse(LiveFace.due(stamp, sent: "", lastTry: Date(timeIntervalSince1970: 70), now: at))
        XCTAssertTrue(LiveFace.due(stamp, sent: "", lastTry: Date(timeIntervalSince1970: 40), now: at))
    }
}
