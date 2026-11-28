import XCTest

/// (0.42.15) The mini cards on "Fastest trip, zoomed out": the tags (Fastest and Surest, both on one card), the words
/// (no walking emoji), the layout (never on top of anything), and how sure by the time of day. Against
/// docs/nearby-cards-vectors.json (the vectors Android checks too).
final class NearbyCardsTests: XCTestCase {
    private var v: [String: Any] = [:]
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        let url = Bundle(for: Self.self).url(forResource: "nearby-cards-vectors", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/nearby-cards-vectors.json")
        let d = try Data(contentsOf: url)
        v = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    private func at(_ m: Double) -> Date { now.addingTimeInterval(m * 60) }

    private func opt(_ id: String, arrive: Double, walk: Int = 5, pct: Int?, ranked: Bool = true) -> Nearby.Option {
        Nearby.Option(id: id, arrival: at(arrive), departure: at(0), walk: walk,
                      sure: pct.map { Nearby.Sure(percent: $0, source: .live, usual: nil) }, ranked: ranked)
    }

    // MARK: the tags

    func test_badges_fastestAndSurest_apart_orBothOnOne() {
        let apart: [String: NearbyCards.Badge] = NearbyCards.badges([opt("veghel", arrive: 7, pct: 92), opt("rembrandt", arrive: 14, pct: 97),
                                                                     opt("bolken", arrive: 31, pct: 4)])
        XCTAssertEqual(apart["veghel"], NearbyCards.Badge(fastest: true, surest: false))
        XCTAssertEqual(apart["rembrandt"], NearbyCards.Badge(fastest: false, surest: true))
        XCTAssertNil(apart["bolken"], "Slower isn't a tag on the cards")
        let both: [String: NearbyCards.Badge] = NearbyCards.badges([opt("veghel", arrive: 7, pct: 92), opt("bolken", arrive: 31, pct: 4)])
        XCTAssertEqual(both["veghel"], NearbyCards.Badge(fastest: true, surest: true))
        XCTAssertEqual(both["veghel"]?.tags, [.fastest, .surest])
    }

    func test_badges_noSurestUnder70_andNeverOvernight() {
        let low: [String: NearbyCards.Badge] = NearbyCards.badges([opt("a", arrive: 7, pct: 60), opt("b", arrive: 9, pct: 69)])
        XCTAssertEqual(low["a"], NearbyCards.Badge(fastest: true, surest: false))
        XCTAssertNil(low["b"])
        let late: [String: NearbyCards.Badge] = NearbyCards.badges([opt("night", arrive: 3, pct: 99, ranked: false), opt("a", arrive: 7, pct: 80)])
        XCTAssertNil(late["night"])
        XCTAssertEqual(late["a"], NearbyCards.Badge(fastest: true, surest: true))
        XCTAssertTrue(NearbyCards.badges([]).isEmpty)
    }

    func test_edge_greenSurest_goldFastest_greyElse() {
        XCTAssertEqual(NearbyCards.edge(NearbyCards.Badge(fastest: true, surest: true)), .surest)
        XCTAssertEqual(NearbyCards.edge(NearbyCards.Badge(fastest: true, surest: false)), .fastest)
        XCTAssertEqual(NearbyCards.edge(NearbyCards.Badge(fastest: false, surest: true)), .surest)
        XCTAssertEqual(NearbyCards.edge(nil), .plain)
        XCTAssertGreaterThan(NearbyCards.edgeWidth(.fastest), NearbyCards.edgeWidth(.plain))
        XCTAssertTrue(NearbyCards.walkDashed(.plain))
        XCTAssertFalse(NearbyCards.walkDashed(.surest))
        XCTAssertEqual(NearbyCards.color(.surest), 0x3DD598)
        XCTAssertEqual(NearbyCards.color(.fastest), 0xE8A33D)
    }

    func test_surestBoth_inTheSheet() {
        XCTAssertEqual(NearbyCards.surestBoth([92, 97, 4], fastest: 0), 1)
        XCTAssertEqual(NearbyCards.surestBoth([97, 92, 97], fastest: 0), 0, "the fastest as sure as the best: both")
        XCTAssertNil(NearbyCards.surestBoth([60, 65], fastest: 0))
        XCTAssertNil(NearbyCards.surestBoth([], fastest: 0))
    }

    // MARK: the words

    func test_words_noWalkingEmoji() {
        XCTAssertEqual(NearbyCards.leaveWords("10:41", walk: 9), "leave 10:41 · 9 min walk")
        XCTAssertEqual(NearbyCards.walkWords(9), "9 min walk")
        let live = Nearby.Sure(percent: 92, source: .live, usual: nil)
        XCTAssertEqual(NearbyCards.onTimeWords(live), "92% on time")
        XCTAssertEqual(NearbyCards.estimateWord(live), "estimate")
        XCTAssertNil(NearbyCards.estimateWord(Nearby.Sure(percent: 92, source: .yours(rides: 12), usual: nil)))
        XCTAssertFalse(NearbyCards.leaveWords("10:41", walk: 2).contains("🚶"))
    }

    // MARK: the layout

    private func pt(_ a: Any?) -> NearbyCards.Point? {
        guard let p = a as? [Double], p.count == 2 else { return nil }
        return NearbyCards.Point(x: p[0], y: p[1])
    }

    private func cases() throws -> (bounds: NearbyCards.Rect, list: [[String: Any]]) {
        let b: [Double] = try XCTUnwrap(v["bounds"] as? [Double])
        return (NearbyCards.Rect(x: b[0], y: b[1], w: b[2], h: b[3]), try XCTUnwrap(v["layout"] as? [[String: Any]]))
    }

    private func items(_ c: [String: Any]) -> [NearbyCards.Item] {
        (c["items"] as? [[String: Any]] ?? []).map { i in
            NearbyCards.Item(id: i["id"] as? String ?? "", at: NearbyCards.Point(x: i["x"] as? Double ?? 0, y: i["y"] as? Double ?? 0),
                             tagged: i["tagged"] as? Bool ?? false)
        }
    }

    func test_layout_vectors() throws {
        let (bounds, list) = try cases()
        XCTAssertGreaterThanOrEqual(list.count, 8)
        for c in list {
            let name: String = c["name"] as? String ?? ""
            let dots: [NearbyCards.Point] = (c["dots"] as? [[Double]] ?? []).map { NearbyCards.Point(x: $0[0], y: $0[1]) }
            let got: [NearbyCards.Placed] = NearbyCards.layout(items(c), bounds: bounds, you: pt(c["you"]), dots: dots)
            let want: [[String: Any]] = try XCTUnwrap(c["placed"] as? [[String: Any]])
            XCTAssertEqual(got.count, want.count, name)
            for (g, w) in zip(got, want) {
                XCTAssertEqual(g.id, w["id"] as? String, name)
                XCTAssertEqual(g.kind.rawValue, w["kind"] as? String, "\(name) \(g.id)")
                if let r = w["rect"] as? [Double] {
                    XCTAssertEqual(g.rect.x, r[0], accuracy: 0.01, "\(name) \(g.id)")
                    XCTAssertEqual(g.rect.y, r[1], accuracy: 0.01, "\(name) \(g.id)")
                    XCTAssertEqual(g.rect.w, r[2], accuracy: 0.01)
                    XCTAssertEqual(g.rect.h, r[3], accuracy: 0.01)
                }
                let l: NearbyCards.Point? = pt(w["leader"])
                XCTAssertEqual(g.leader == nil, l == nil, "\(name) \(g.id) leader")
                if let a = g.leader, let b = l {
                    XCTAssertEqual(a.x, b.x, accuracy: 0.01)
                    XCTAssertEqual(a.y, b.y, accuracy: 0.01)
                }
            }
        }
    }

    /// Never on top of anything: each card or pill inside the map's free part, clear of every other one, of you, of
    /// every dot, and of every leader line; a leader through no other card.
    private func assertClear(_ placed: [NearbyCards.Placed], items: [NearbyCards.Item], bounds: NearbyCards.Rect,
                             you: NearbyCards.Point?, dots: [NearbyCards.Point], _ name: String) {
        let shown: [NearbyCards.Placed] = placed.filter { $0.kind != .hidden }
        var blocks: [NearbyCards.Rect] = dots.map { NearbyCards.Rect(x: $0.x - 7, y: $0.y - 7, w: 14, h: 14) }
        blocks += items.map { NearbyCards.Rect(x: $0.at.x - 7, y: $0.at.y - 7, w: 14, h: 14) }
        if let you { blocks.append(NearbyCards.Rect(x: you.x - 20, y: you.y - 20, w: 40, h: 40)) }
        for (k, p) in shown.enumerated() {
            let r: NearbyCards.Rect = p.rect
            XCTAssertTrue(r.x >= bounds.x - 1e-9 && r.y >= bounds.y - 1e-9 && r.maxX <= bounds.maxX + 1e-9 && r.maxY <= bounds.maxY + 1e-9, "\(name) \(p.id) inside")
            for q in shown[(k + 1)...] where r.touches(q.rect, pad: 0) { XCTFail("\(name): \(p.id) on \(q.id)") }
            for b in blocks where r.touches(b, pad: 0) { XCTFail("\(name): \(p.id) on a dot") }
            for q in shown where q.id != p.id {
                if let l = q.leader, let i = items.first(where: { $0.id == q.id }), r.crossed(l, i.at) { XCTFail("\(name): \(p.id) on \(q.id)'s leader") }
            }
        }
    }

    func test_layout_neverOverlaps_theVectors() throws {
        let (bounds, list) = try cases()
        for c in list {
            let dots: [NearbyCards.Point] = (c["dots"] as? [[Double]] ?? []).map { NearbyCards.Point(x: $0[0], y: $0[1]) }
            let it: [NearbyCards.Item] = items(c)
            let got: [NearbyCards.Placed] = NearbyCards.layout(it, bounds: bounds, you: pt(c["you"]), dots: dots)
            assertClear(got, items: it, bounds: bounds, you: pt(c["you"]), dots: dots, c["name"] as? String ?? "")
        }
    }

    /// Clusters of 2, 3 and 5 stops within 150 m (about 100 points), at the edges, the you-dot under a spot, at many
    /// places on the map: never an overlap, the first two always shown.
    func test_layout_neverOverlaps_synthetic() {
        let bounds = NearbyCards.Rect(x: 8, y: 56, w: 374, h: 360)
        var seed: UInt64 = 42
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        for n in [2, 3, 5, 8] {
            for k in 0..<60 {
                let cx: Double = 20 + rnd() * 350, cy: Double = 62 + rnd() * 348
                let spread: Double = n == 8 ? 300 : 100
                var it: [NearbyCards.Item] = []
                for i in 0..<n {
                    let x: Double = min(bounds.maxX - 2, max(bounds.x + 2, cx + (rnd() - 0.5) * spread))
                    let y: Double = min(bounds.maxY - 2, max(bounds.y + 2, cy + (rnd() - 0.5) * spread))
                    it.append(NearbyCards.Item(id: "s\(i)", at: NearbyCards.Point(x: x, y: y), tagged: i < 2))
                }
                let you = NearbyCards.Point(x: it[0].at.x, y: max(bounds.y, it[0].at.y - 50))      // where its card would go
                let got: [NearbyCards.Placed] = NearbyCards.layout(it, bounds: bounds, you: you)
                assertClear(got, items: it, bounds: bounds, you: you, dots: [], "n\(n) #\(k)")
                if n <= 3 { XCTAssertNotEqual(got[0].kind, .hidden, "n\(n) #\(k): the first is shown") }
            }
        }
    }

    func test_layout_pillsFromTheFifth_andOffTheMapHidden() {
        let bounds = NearbyCards.Rect(x: 0, y: 0, w: 1000, h: 1000)
        let it: [NearbyCards.Item] = (0..<6).map { NearbyCards.Item(id: "s\($0)", at: NearbyCards.Point(x: 100 + Double($0) * 150, y: 500), tagged: false) }
        let got: [NearbyCards.Placed] = NearbyCards.layout(it + [NearbyCards.Item(id: "out", at: NearbyCards.Point(x: 1200, y: 10), tagged: false)],
                                                           bounds: bounds, you: nil)
        XCTAssertEqual(got.map(\.kind), [.card, .card, .card, .card, .pill, .pill, .hidden])
        XCTAssertNil(got[0].leader, "right above its dot: no leader")
        XCTAssertEqual(got[0].rect.maxY, 500 - NearbyCards.gap, accuracy: 1e-9)
    }

    /// 0.42.16: stops off the map don't use up the card slots: the top two out of bounds, the next four get cards.
    func test_layout_offTheMapDoesNotUseCardSlots() {
        let bounds = NearbyCards.Rect(x: 0, y: 0, w: 1000, h: 1000)
        let out: [NearbyCards.Item] = [NearbyCards.Item(id: "o0", at: NearbyCards.Point(x: 1200, y: 10), tagged: true),
                                       NearbyCards.Item(id: "o1", at: NearbyCards.Point(x: -50, y: 500), tagged: false)]
        let inside: [NearbyCards.Item] = (0..<5).map { NearbyCards.Item(id: "s\($0)", at: NearbyCards.Point(x: 100 + Double($0) * 200, y: 500), tagged: false) }
        let got: [NearbyCards.Placed] = NearbyCards.layout(out + inside, bounds: bounds, you: nil)
        XCTAssertEqual(got.map(\.kind), [.hidden, .hidden, .card, .card, .card, .card, .pill])
    }

    /// 0.42.16: no card on the map's credits.
    func test_layout_keepsOffTheCredits() {
        let credit = NearbyCards.Rect(x: 380, y: 400, w: 240, h: 90)
        let got: [NearbyCards.Placed] = NearbyCards.layout([NearbyCards.Item(id: "s", at: NearbyCards.Point(x: 500, y: 500), tagged: false)],
                                                           bounds: NearbyCards.Rect(x: 0, y: 0, w: 1000, h: 1000), you: nil, avoid: [credit])
        XCTAssertEqual(got[0].kind, .card)
        XCTAssertFalse(got[0].rect.touches(credit, pad: 0))
    }

    // MARK: how sure, by the time of day

    private func entries() throws -> [NearbySlot.Entry] {
        try XCTUnwrap(v["slotEntries"] as? [[String: Any]]).map {
            NearbySlot.Entry(minute: $0["minute"] as? Int ?? 0, weekend: $0["weekend"] as? Bool ?? false, delay: $0["delay"] as? Double ?? 0)
        }
    }

    func test_slot_vectors() throws {
        let e: [NearbySlot.Entry] = try entries()
        for c in try XCTUnwrap(v["picks"] as? [[String: Any]]) {
            let m: Int = c["minute"] as? Int ?? 0, we: Bool = c["weekend"] as? Bool ?? false
            let p = NearbySlot.pick(e, minute: m, weekend: we)
            XCTAssertEqual(p.delays, c["delays"] as? [Double], "\(m) \(we)")
            XCTAssertEqual(p.window, c["window"] as? Int, "\(m) \(we)")
            XCTAssertEqual(Nearby.sure(own: p.delays, modelLate: 0.4, made: 1, live: true).percent, c["percent"] as? Int, "\(m) \(we)")
        }
        for c in try XCTUnwrap(v["periods"] as? [[String: Any]]) {
            let p = NearbySlot.period(hour: c["hour"] as? Double ?? 0, weekend: c["weekend"] as? Bool ?? false)
            XCTAssertEqual(p.name, c["name"] as? String)
            XCTAssertEqual(p.bus, c["bus"] as? Double ?? 0, accuracy: 1e-9)
            XCTAssertEqual(p.train, c["train"] as? Double ?? 0, accuracy: 1e-9)
            XCTAssertEqual(NearbySlot.lateChance(scale: p.bus, by: 3), c["late3"] as? Double ?? 0, accuracy: 1e-4)
        }
        for c in try XCTUnwrap(v["slotWords"] as? [[String: Any]]) {
            XCTAssertEqual(NearbySlot.slotWords(minute: c["minute"] as? Int ?? 0, weekend: c["weekend"] as? Bool ?? false), c["text"] as? String)
        }
    }

    func test_sameLine_1300_vs_1900_differ() throws {
        let e: [NearbySlot.Entry] = try entries()
        let one = NearbySlot.pick(e, minute: 13 * 60, weekend: false)
        let seven = NearbySlot.pick(e, minute: 19 * 60, weekend: false)
        let a: Nearby.Sure = Nearby.sure(own: one.delays, modelLate: 0.3, made: 1, live: false)
        let b: Nearby.Sure = Nearby.sure(own: seven.delays, modelLate: 0.3, made: 1, live: false)
        XCTAssertGreaterThan(a.percent, b.percent)
        XCTAssertEqual(a.onTime, 4)
        XCTAssertEqual(b.onTime, 1)
        // and the estimate, without your rides: rush hour and evening worse than the day
        let day: Double = NearbySlot.lateChance(scale: NearbySlot.period(hour: 13, weekend: false).bus, by: 3)
        let evening: Double = NearbySlot.lateChance(scale: NearbySlot.period(hour: 19, weekend: false).bus, by: 3)
        let rush: Double = NearbySlot.lateChance(scale: NearbySlot.period(hour: 17.5, weekend: false).bus, by: 3)
        XCTAssertGreaterThan(evening, day)
        XCTAssertGreaterThan(rush, evening)
    }

    func test_slot_widens_andWeekendsApart() {
        let e: [NearbySlot.Entry] = [70, 80, 100, 150].map { NearbySlot.Entry(minute: 600 + $0, weekend: false, delay: 0) }
            + [0, 5, 10, 15].map { NearbySlot.Entry(minute: 600 + $0, weekend: true, delay: 9) }
        let p = NearbySlot.pick(e, minute: 600, weekend: false)
        XCTAssertEqual(p.window, 120, "60: none, 90: two, 120: three, still the widest")
        XCTAssertEqual(p.delays.count, 3)
        let w = NearbySlot.pick(e, minute: 600, weekend: true)
        XCTAssertEqual(w.window, 60)
        XCTAssertEqual(w.delays, [9, 9, 9, 9], "weekends apart")
        XCTAssertEqual(NearbySlot.apart(5, 1430), 15, "around midnight")
    }

    func test_explain_namesTheSlot() {
        var s: Nearby.Sure = Nearby.sure(own: [0, 1, 2, 8, 1, 0, 0], modelLate: 0.3, made: 1, live: false)
        s.window = 60
        XCTAssertEqual(NearbySlot.explain(s, line: "305", to: "Eindhoven", slot: "around 19:00 on weekdays", period: "evening", changes: 0),
                       "Based on your last 7 rides on the 305 to Eindhoven around 19:00 on weekdays: 6 on time (less than 3 min late).")
        s.window = 120
        XCTAssertTrue(NearbySlot.explain(s, line: "305", to: "Eindhoven", slot: "around 19:00 on weekdays", period: "evening", changes: 0)
            .hasSuffix("Counted up to 120 min either side: too few closer to that time."))
        let live: Nearby.Sure = Nearby.sure(own: [], modelLate: 0.3, made: 0.9, live: true)
        let t: String = NearbySlot.explain(live, line: "305", to: "Eindhoven", slot: "around 19:00 on weekdays", period: "evening", changes: 1)
        XCTAssertTrue(t.hasPrefix("Estimated: fewer than 4 of your own rides around 19:00 on weekdays."), t)
        XCTAssertTrue(t.hasSuffix("Times the chance you make your change (about 90%)."), t)
        let est: Nearby.Sure = Nearby.sure(own: [], modelLate: 0.3, made: 1, live: false)
        XCTAssertEqual(NearbySlot.explain(est, line: "305", to: "Eindhoven", slot: "around 13:00 on weekdays", period: "daytime", changes: 0),
                       "Estimated from the time of day only (around 13:00 on weekdays, daytime): no live times of the 305 yet.")
    }
}
