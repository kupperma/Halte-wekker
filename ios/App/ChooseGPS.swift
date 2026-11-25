import Foundation

/// What the buses' own GPS said while choosing between them (0.26.1). The one shown (the planned one, mostly) used to
/// win every look that wasn't a clear run against it, so a planned bus that drifted from you, or was hundreds of metres
/// from where its own GPS put it, was kept for minutes while the other one fitted by its GPS. Now evidence decides:
/// - `fitAt`: when each one last passed by a fresh GPS fix of its own. Its times saying otherwise in the next
///   `gpsMemory` seconds (a GPS feed that went quiet for a bit, times that are off) is "not sure", not a failure: no
///   miss, no lead for the other one, and it can't be dropped as "the only one left" meanwhile.
/// - `leader`/`looks`: the one that fitted by its GPS while every other one failed (or fitted `chooseMargin` worse), in
///   looks in a row (at most `gpsRunGap` apart). `gpsLooks` such looks: it's the one. A look where it fails for real, or
///   another one fits better, starts the run again; a look that says nothing (both fit about as well, not sure) doesn't.
struct GPSChoice: Equatable, Sendable {
    var fitAt: [String: Date] = [:]
    var leader: String? = nil
    var looks = 0
    var lastAt: Date? = nil
    // 0.38: the one that left the stop with you (`DepartMatch.pick`), in looks in a row that it passed
    var departLeader: String? = nil
    var departLooks = 0

    /// A new choice (or a settled one): the run starts again; what each one's GPS said stays, for `gpsMemory`.
    mutating func restart() { leader = nil; looks = 0; lastAt = nil; departLeader = nil; departLooks = 0 }
}

extension VehicleMatch {
    static let gpsMemory: TimeInterval = 90     // s: a times-only failure this soon after fitting by its own GPS is not sure
    static let gpsLooks = 2                     // looks in a row where one fits by its GPS and the others don't
    static let gpsRunGap: TimeInterval = 60     // s: at most this long between them
    static let chooseMargin = 30.0              // s: both fit; one this much better counts (the one shown wins a real tie)
    static let splitMetres = 300.0              // m: your fixes this far off its path (or twice their accuracy): the roads parted
    static let departLooks = 2                  // 0.38: looks in a row the one that left the stop with you passes

    /// Passed by a fresh GPS fix of its own.
    static func passedByGPS(_ j: Judgement) -> Bool {
        guard j.evidence?.gps == true, case .success = j.result else { return false }
        return true
    }

    /// Note when each one passed by its own GPS; forget what's older than `gpsMemory`.
    static func noteGPSFits(_ judged: [Judgement], into fits: inout [String: Date], now: Date) {
        for j in judged where passedByGPS(j) { fits[j.id] = now }
        fits = fits.filter { now.timeIntervalSince($0.value) <= gpsMemory }
    }

    /// A failure by its times alone (`timesOnly`: not by its GPS, not off its path or the other way) within `gpsMemory`
    /// of fitting by its own GPS: its times are off, not the bus.
    static func softened(_ j: Judgement, fitAt: Date?, now: Date) -> Bool {
        guard let fitAt, timesOnly(j) else { return false }
        let ago = now.timeIntervalSince(fitAt)
        return ago >= 0 && ago <= gpsMemory
    }

    /// The judgements with each softened one as "no times now" (not sure).
    static func soften(_ judged: [Judgement], fits: [String: Date], now: Date) -> [Judgement] {
        judged.map { (j: Judgement) -> Judgement in
            guard softened(j, fitAt: fits[j.id], now: now) else { return j }
            return Judgement(id: j.id, line: j.line, isTrain: j.isTrain, realTime: j.realTime, evidence: j.evidence,
                             result: .failure(.noTimes))
        }
    }

    /// Off its path by so much that its road went elsewhere: your fixes `splitMetres` (300 m) or twice their accuracy
    /// from it, measured (not the quick box test, not beyond its end).
    static func roadsParted(_ j: Judgement) -> Bool {
        guard case .failure(.offItsPath) = j.result, let e = j.evidence, e.crossTrack.isFinite else { return false }
        return e.crossTrack >= max(splitMetres, 2 * e.accuracy)
    }

    /// This look's one by GPS: of `ids`, it passed by its own GPS, and every other one of `ids` was judged and failed
    /// (not only "not sure"), or passed `margin` seconds worse with live times or its own GPS. Nil: none.
    static func gpsBest(_ ids: [String], judged: [Judgement], margin: Double = chooseMargin) -> String? {
        let byId = Dictionary(judged.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for x in ids {
            guard let jx = byId[x], passedByGPS(jx), case .success(let cx) = jx.result else { continue }
            let others = ids.filter { $0 != x }
            guard !others.isEmpty else { continue }
            let beaten = others.allSatisfy { y -> Bool in
                guard let jy = byId[y] else { return false }
                switch jy.result {
                case .failure(let why): return !why.notSure
                case .success(let cy):
                    let live = jy.realTime || jy.evidence?.gps == true
                    return live && cy >= cx + margin
                }
            }
            if beaten { return x }
        }
        return nil
    }

    /// One look for the run (see `GPSChoice`). Returns the leader once it has `gpsLooks` looks in a row.
    @discardableResult
    static func gpsLook(_ ids: [String], judged: [Judgement], run: inout GPSChoice, now: Date) -> String? {
        if let last = run.lastAt, now.timeIntervalSince(last) > gpsRunGap { run.restart() }
        if let x = gpsBest(ids, judged: judged) {
            if run.leader == x { run.looks += 1 } else { run.leader = x; run.looks = 1 }
            run.lastAt = now
        } else if let l = run.leader, contradicted(l, ids: ids, judged: judged) {
            run.restart()
        }
        guard let l = run.leader, run.looks >= gpsLooks else { return nil }
        return l
    }

    /// The leader's run ends: it failed for real, or another one with live times or its own GPS passed with a lower cost
    /// (than its own, or while it wasn't sure).
    private static func contradicted(_ leader: String, ids: [String], judged: [Judgement]) -> Bool {
        let mine = judged.first { $0.id == leader }
        if case .failure(let why)? = mine?.result, !why.notSure { return true }
        var cost = Double.infinity
        if case .success(let c)? = mine?.result { cost = c }
        return judged.contains { (j: Judgement) -> Bool in
            guard j.id != leader, ids.contains(j.id), j.realTime || j.evidence?.gps == true,
                  case .success(let c) = j.result else { return false }
            return c < cost
        }
    }
}

extension VehicleMatch {
    /// 0.38: one look for the one that left the stop with you (`departed`, from `DepartMatch.pick`): it's in the running
    /// (`alive`) and passed this look, and no other one passed by its own GPS `chooseMargin` better while it didn't (its
    /// own GPS is the clearer evidence). `departLooks` such looks in a row: that one. Any other look starts the run again.
    @discardableResult
    static func departLook(_ departed: String?, judged: [Judgement], alive: [String], run: inout GPSChoice) -> String? {
        guard let d = departed, alive.contains(d), let mine = judged.first(where: { $0.id == d }),
              case .success(let cost) = mine.result else {
            run.departLeader = nil; run.departLooks = 0
            return nil
        }
        let mineByGPS: Bool = passedByGPS(mine)
        let beaten: Bool = judged.contains { (j: Judgement) -> Bool in
            guard j.id != d, alive.contains(j.id), passedByGPS(j), !mineByGPS, case .success(let c) = j.result else { return false }
            return c + chooseMargin <= cost
        }
        if beaten { run.departLeader = nil; run.departLooks = 0; return nil }
        if run.departLeader == d { run.departLooks += 1 } else { run.departLeader = d; run.departLooks = 1 }
        return run.departLooks >= departLooks ? d : nil
    }

    // 0.39.1: the planned 305 kept for a quarter of an hour while its own GPS had it 1.7 km from you, and the 154 you
    // were on had fitted by its GPS a moment before ("keep 305 · the only one left").
    static let farBus = 1000.0                  // m: its own GPS this far from you along its road: you're not on it…
    static let farTrain = 2500.0                // …for a train

    /// Failed by its own GPS, clearly far from you (`farBus`, `farTrain`): not a times-only doubt, not off its path (the
    /// roads parting has its own rule), not "not sure".
    static func farByGPS(_ j: Judgement) -> Bool {
        guard let e = j.evidence, e.gps, case .failure(let why) = j.result, !why.notSure, why != .offItsPath else { return false }
        let far: Double = j.isTrain ? farTrain : farBus
        return abs(e.offset) >= far
    }

    /// The one shown is far by its own GPS (`farByGPS`): the other one of `alive` that fits by its own GPS, this look
    /// (the lowest cost) or a moment ago (`fits`, the newest), not one whose road went elsewhere. Nil: none.
    static func gpsRescue(shown: String?, judged: [Judgement], alive: [String], fits: [String: Date], splits: Set<String>) -> String? {
        guard let s = shown, let mine = judged.first(where: { $0.id == s }), farByGPS(mine) else { return nil }
        let others: [String] = alive.filter { $0 != s && !splits.contains($0) }
        var best: (id: String, cost: Double)?
        for j in judged where others.contains(j.id) && passedByGPS(j) {
            guard case .success(let c) = j.result else { continue }
            if best.map({ c < $0.cost }) ?? true { best = (id: j.id, cost: c) }
        }
        if let b = best { return b.id }
        let recent: [(id: String, at: Date)] = others.compactMap { id in fits[id].map { (id: id, at: $0) } }
        return recent.max { $0.at != $1.at ? $0.at < $1.at : $0.id > $1.id }?.id
    }

    /// The ranking with each one's cost moved by `nudge` (seconds; negative: better), best first, ties by id.
    static func nudged(_ ranked: [Ranked], _ nudge: [String: Double]) -> [Ranked] {
        guard !nudge.isEmpty else { return ranked }
        return ranked.map { (r: Ranked) -> Ranked in Ranked(id: r.id, cost: r.cost + (nudge[r.id] ?? 0)) }
            .sorted { $0.cost != $1.cost ? $0.cost < $1.cost : $0.id < $1.id }
    }
}
