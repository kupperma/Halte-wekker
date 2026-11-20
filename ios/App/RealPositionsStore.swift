import CoreLocation
import SwiftUI
import UIKit

/// Real positions: OVapi's open GPS feed of buses (`RealPositions`, 0.20.2) and NS's positions of every train through the
/// relay (0.20.3), each fetched only while something needs it, the Settings switch is on and Low Power Mode is off:
/// - a map or sheet on screen draws a moving bus or train (`.realPositions(_:trains:)`), while the app is in front;
/// - the on-board matcher is looking (`forMatcher`: boarding, confirming, finding, choosing, "Not this one?"): for a
///   minute and a quarter after each look, also in the background while a ride runs (the matcher runs there too; it
///   asks for nothing more of the GPS). Trains only while a train is among the ones it looks at.
/// - 0.20.7: a ride whose vehicle is confirmed holds nothing: its "same bus?" look asks for one fetch at most every two
///   minutes, and one now when it's in doubt (`refresh`, `FeedPolicy`), before a miss counts.
/// Every 30 s at most, with its ETag (304: nothing new); not over a Low Data connection; on a failure again after 60 s,
/// 120 s, … 5 min, silently (the relay without the route or the key: 404, 501; an answer that isn't NS's: no train
/// fixes). The last good positions are kept, and each vehicle's fix before its newest (for its speed).
@MainActor
final class RealPositionsStore: ObservableObject {
    static let shared = RealPositionsStore()

    /// Each trip's newest fix by OVapi's trip_id (`RealPositions.key`).
    @Published private(set) var fixes: [String: GPSFix] = [:]
    /// Each train's newest fix by its number.
    @Published private(set) var trainFixes: [Int: GPSFix] = [:]
    private var previous: [String: GPSFix] = [:]
    private var trainPrevious: [Int: GPSFix] = [:]
    /// A Transitous train trip's number, as its trip names it (learned from its trip wherever the app has it).
    private var numbers: [String: Int] = [:]
    private var noNumber: [String: Date] = [:]          // trips asked for their number that have none (not again soon)

    /// What a feed's fetching keeps: its ETag, when next, how many failures in a row.
    private struct Feed {
        var etag: String?
        var nextAt = Date.distantPast
        var failures = 0
        var lastOK: Date?               // the last answer (new positions, or "nothing new")
    }
    private var buses = Feed(), trains = Feed()

    private var demand: [UUID: Bool] = [:]              // on screen: token → it draws trains too
    private var matcherBuses = Date.distantPast         // the matcher looked: fetch until then
    private var matcherTrains = Date.distantPast
    private static let matcherHold: TimeInterval = 75   // s after a look

    private var loop: Task<Void, Never>?
    private var loopId = 0
    private var fetching = false
    private var lastLog: [String: Date] = [:]           // a log line per kind of outcome at most every 5 min
    private var logged: [String: Date] = [:]            // trip id → the fix last logged for your ride's vehicle
    private let session: URLSession
    private var inBackground = false

    private init() {
        let c = URLSessionConfiguration.ephemeral
        c.allowsConstrainedNetworkAccess = false        // not in Low Data Mode
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 45
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: c, delegate: Net.meter, delegateQueue: nil)      // (the battery log's real bytes)
        // (in the background only the matcher's looks during a ride keep it going)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.inBackground = true; self?.update() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.inBackground = false; self?.update() }
        }
    }

    /// Some positions are in (of buses or trains).
    var hasFixes: Bool { Self.enabled && (!fixes.isEmpty || !trainFixes.isEmpty) }

    /// The Settings switch (on unless turned off).
    static var enabled: Bool { UserDefaults.standard.object(forKey: RealPositions.settingKey) as? Bool ?? true }

    /// Something on screen that draws a moving bus (`trains`: or train) says whether it needs the positions now.
    func need(_ token: UUID, _ on: Bool, trains: Bool = false) {
        if on { demand[token] = trains } else { demand[token] = nil }
        update()
    }

    /// The matcher looks now (`trains`: a train is among the ones it looks at): the positions are fetched for the
    /// next minute and a quarter.
    func matcherLooks(trains: Bool, now: Date = Date()) {
        guard Self.enabled else { return }
        matcherBuses = now.addingTimeInterval(Self.matcherHold)
        if trains { matcherTrains = matcherBuses }
        update()
    }

    private var wantsBuses: Bool { (!demand.isEmpty && !inBackground) || matcherBuses > Date() }
    private var wantsTrains: Bool { (demand.values.contains(true) && !inBackground) || matcherTrains > Date() }

    /// The loop runs only while something needs it (on screen in front, or the matcher's looks).
    private func update() {
        if !(wantsBuses || wantsTrains) {
            loop?.cancel(); loop = nil
        } else if loop == nil {
            loopId += 1
            let id = loopId
            loop = Task { [weak self] in await self?.run(id) }
        }
    }

    /// The fix to draw a Transitous trip by now (`RealPositions.usable`); a train's by its number. Nil when the switch
    /// is off.
    func fix(for tripId: String, now: Date = Date()) -> GPSFix? {
        guard Self.enabled else { return nil }
        if let n = numbers[tripId], let f = trainFixes[n] { return RealPositions.usable(f, tripId: tripId, now: now) }
        guard !fixes.isEmpty else { return nil }
        return RealPositions.usable(fixes, tripId: tripId, now: now)
    }

    /// A trip's fix before its newest (for the pace it was seen going, 0.34): a train's by its number, else OVapi's.
    func previousFix(for tripId: String) -> GPSFix? {
        guard Self.enabled else { return nil }
        if let n = numbers[tripId] { return trainPrevious[n] }
        return RealPositions.key(tripId).flatMap { previous[$0] }
    }

    /// A vehicle's own GPS for the matcher: a fix of at most `RealPositions.matchFresh`, and the one before it. A
    /// train's from NS by its number; else (a bus, a tram: the app counts trams as trains) OVapi's.
    func gps(for tripId: String, isTrain: Bool, now: Date = Date()) -> VehicleGPS? {
        guard Self.enabled else { return nil }
        if isTrain, let n = numbers[tripId], let f = trainFixes[n],
           let u = RealPositions.usable(f, tripId: tripId, now: now, fresh: RealPositions.matchFresh) {
            return VehicleGPS(fix: u, previous: trainPrevious[n])
        }
        guard let k = RealPositions.key(tripId),
              let u = RealPositions.usable(fixes, tripId: tripId, now: now, fresh: RealPositions.matchFresh) else { return nil }
        return VehicleGPS(fix: u, previous: previous[k])
    }

    /// A train trip's number, from its trip (`LiveTrip.num`), for its NS position. Only a rail trip's: a bus's or tram's
    /// trip number is no train's.
    func learn(_ tripId: String, trip: LiveTrip?) {
        guard let t = trip, RealPositions.isRail(mode: t.mode), let n = RealPositions.trainNumber(t.num) else { return }
        if numbers.count > 500 { numbers = [:] }
        numbers[tripId] = n
    }

    /// The matcher is about to judge `tracks` (0.20.3): the positions are fetched meanwhile (`matcherLooks`), and each
    /// one with a fresh fix of its own gets it (`VehicleTrack.gps`). A train whose number it doesn't know yet is asked
    /// for it (its trip, which the app keeps; 4 at most a look, and only once NS's positions are in).
    /// `hold`: keep the positions coming for the next minute and a quarter (not for a confirmed ride's own look: 0.20.7).
    func forMatcher(_ tracks: [VehicleTrack], hold: Bool = true, now: Date = Date()) async -> [VehicleTrack] {
        guard Self.enabled else { return tracks }
        let anyTrain = tracks.contains(where: \.isTrain)
        if hold { matcherLooks(trains: anyTrain, now: now) }
        if anyTrain, !trainFixes.isEmpty {
            let ask = Array(tracks.filter { t in
                t.isTrain && numbers[t.tripId] == nil && (noNumber[t.tripId].map { now.timeIntervalSince($0) > 600 } ?? true)
            }.map(\.tripId).prefix(4))
            if !ask.isEmpty {
                let jobs: [@Sendable () async -> Int?] = ask.map { id in
                    { @Sendable in
                        guard let t = await Transit.liveTrip(id), RealPositions.isRail(mode: t.mode) else { return nil }
                        return RealPositions.trainNumber(t.num)
                    }
                }
                let got = await Progressive.all(jobs)
                if noNumber.count > 200 { noNumber = [:] }
                for (id, n) in zip(ask, got) {
                    if let n { numbers[id] = n } else { noNumber[id] = now }
                }
            }
        }
        let at = Date()
        return tracks.map { t in
            var v = t
            v.gps = gps(for: t.tripId, isTrain: t.isTrain, now: at)
            return v
        }
    }

    /// One fetch now (0.20.7), also in the background (a ride's own look), unless the last answer is at most `age` old;
    /// trains too with `trains`. Not with the switch off, in Low Power Mode, or while a failure's wait is still on. True:
    /// an answer came in.
    @discardableResult
    func refresh(trains: Bool, ifOlderThan age: TimeInterval, now: Date = Date()) async -> Bool {
        guard Self.enabled, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        var got = false
        if FeedPolicy.due(last: buses.lastOK, every: age, now: now), buses.failures == 0 || now >= buses.nextAt {
            let before = buses.lastOK
            await fetchBuses()
            got = got || buses.lastOK != before
        }
        if trains, FeedPolicy.due(last: self.trains.lastOK, every: age, now: now), self.trains.failures == 0 || now >= self.trains.nextAt {
            let before = self.trains.lastOK
            await fetchTrains()
            got = got || self.trains.lastOK != before
        }
        return got
    }

    /// In front, or (the matcher's looks) in the background during a ride.
    private var mayFetch: Bool {
        guard Self.enabled, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        return UIApplication.shared.applicationState == .active || matcherBuses > Date()
    }

    private func run(_ id: Int) async {
        while !Task.isCancelled {
            if !(wantsBuses || wantsTrains) {
                if loopId == id { loop = nil }
                return
            }
            let now = Date()
            if mayFetch {
                if wantsBuses, now >= buses.nextAt { await fetchBuses() }
                if !Task.isCancelled, wantsTrains, now >= trains.nextAt { await fetchTrains() }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func fetchBuses() async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        var req = URLRequest(url: RealPositions.feedURL)
        req.setValue("Haltewekker-iOS", forHTTPHeaderField: "User-Agent")
        if let etag = buses.etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await session.data(for: req)
            BatteryLog.shared.request(.ovapi, body: data.count)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 304 {
                succeeded(&buses, RealPositions.fetchLine(status: 304, bytes: 0, vehicles: fixes.count, parseMs: nil, next: RealPositions.every), kind: "304")
                return
            }
            guard status == 200, !data.isEmpty, data.count < 16 << 20 else { failed(&buses, status: status, error: nil); return }
            let started = Date()
            let feed = await Task.detached(priority: .utility) { RealPositions.parse(data) }.value
            let ms = Date().timeIntervalSince(started) * 1000
            // (a whole answer that holds nothing usable: keep what we have)
            guard !feed.fixes.isEmpty else { failed(&buses, status: status, error: nil); return }
            previous = RealPositions.previous(old: fixes, previous: previous, new: feed.fixes)
            fixes = feed.fixes
            buses.etag = http?.value(forHTTPHeaderField: "ETag")
            succeeded(&buses, RealPositions.fetchLine(status: 200, bytes: data.count, vehicles: feed.fixes.count, parseMs: ms, next: RealPositions.every), kind: "200")
        } catch {
            let code = (error as? URLError)?.code
            // (no longer needed: not a failure)
            if Task.isCancelled || code == .cancelled { return }
            failed(&buses, status: nil, error: code?.rawValue ?? -1)
        }
    }

    /// NS's positions of every train, through the relay (no place of yours goes with it).
    private func fetchTrains() async {
        guard !fetching, let url = URL(string: NSStore.relay + RealPositions.trainsPath) else { return }
        fetching = true
        defer { fetching = false }
        var req = URLRequest(url: url)
        req.setValue(Transit.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag = trains.etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let line: (Int?, Int?, Int, Int, Double?, TimeInterval) -> String = { status, error, bytes, n, ms, next in
            RealPositions.fetchLine(status: status, error: error, bytes: bytes, vehicles: n, parseMs: ms, next: next,
                                    feed: "ns/vehicles", unit: "trains")
        }
        do {
            let (data, response) = try await session.data(for: req)
            BatteryLog.shared.request(.nsVehicles, body: data.count)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 304 {
                succeeded(&trains, line(304, nil, 0, trainFixes.count, nil, RealPositions.every), kind: "ns 304")
                return
            }
            // (the relay without the route yet, or without the key: not again for 10 minutes)
            if status == 404 || status == 501 {
                trains.failures += 1
                trains.nextAt = Date().addingTimeInterval(600)
                log(line(status, nil, 0, 0, nil, 600), kind: "ns \(status)")
                return
            }
            guard status == 200, !data.isEmpty, data.count < 16 << 20 else { failed(&trains, status: status, error: nil, line: line); return }
            let started = Date()
            let at = Date()
            let got = await Task.detached(priority: .utility) { RealPositions.parseTrains(data, at: at) }.value
            let ms = Date().timeIntervalSince(started) * 1000
            guard let got, !got.isEmpty else { failed(&trains, status: status, error: nil, line: line); return }
            trainPrevious = RealPositions.previous(old: trainFixes, previous: trainPrevious, new: got)
            trainFixes = got
            trains.etag = http?.value(forHTTPHeaderField: "ETag")
            succeeded(&trains, line(200, nil, data.count, got.count, ms, RealPositions.every), kind: "ns 200")
        } catch {
            let code = (error as? URLError)?.code
            if Task.isCancelled || code == .cancelled { return }
            failed(&trains, status: nil, error: code?.rawValue ?? -1, line: line)
        }
    }

    private func succeeded(_ f: inout Feed, _ line: String, kind: String) {
        f.failures = 0
        f.lastOK = Date()
        f.nextAt = Date().addingTimeInterval(RealPositions.every)
        log(line, kind: kind)
    }

    private func failed(_ f: inout Feed, status: Int?, error: Int?,
                        line: ((Int?, Int?, Int, Int, Double?, TimeInterval) -> String)? = nil) {
        f.failures += 1
        let wait = RealPositions.backoff(failures: f.failures)
        f.nextAt = Date().addingTimeInterval(wait)
        let text = line?(status, error, 0, 0, nil, wait)
            ?? RealPositions.fetchLine(status: status, error: error, bytes: 0, vehicles: fixes.count, parseMs: nil, next: wait)
        log(text, kind: line == nil ? "failed" : "ns failed")
    }

    private func log(_ line: String, kind: String) {
        let now = Date()
        if let l = lastLog[kind], now.timeIntervalSince(l) < RealPositions.logEvery { return }
        lastLog[kind] = now
        FieldLog.shared.add(.net, line)
    }

    /// A fix used for your own ride's vehicle: how far it put the bus from where its times have it, once per fix.
    func noteUsed(_ fix: GPSFix, tripId: String, line: String, isTrain: Bool, timeMetres: Double, gpsMetres: Double, now: Date) {
        guard logged[tripId] != fix.at else { return }
        if logged.count > 50 { logged = [:] }
        logged[tripId] = fix.at
        FieldLog.shared.add(.match, RealPositions.usedLine(vehicle: FieldFormat.vehicle(line: line, tripId: tripId, isTrain: isTrain),
                                                           age: now.timeIntervalSince(fix.at), metres: abs(gpsMetres - timeMetres),
                                                           behind: gpsMetres < timeMetres))
    }
}

/// While `on` (and on screen): this view draws moving buses (`trains`: or a train), so the real positions are fetched.
private struct RealPositionsDemand: ViewModifier {
    let on: Bool
    let trains: Bool
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content
            .onAppear { RealPositionsStore.shared.need(token, on, trains: trains) }
            .onChange(of: on) { _, v in RealPositionsStore.shared.need(token, v, trains: trains) }
            .onChange(of: trains) { _, v in RealPositionsStore.shared.need(token, on, trains: v) }
            .onDisappear { RealPositionsStore.shared.need(token, false) }
    }
}

extension View {
    /// This view draws moving buses while `on` (`trains`: a train among them): fetch the real positions meanwhile
    /// (`RealPositionsStore`).
    func realPositions(_ on: Bool, trains: Bool = false) -> some View { modifier(RealPositionsDemand(on: on, trains: trains)) }
}

/// No going back for nothing (`RealPositions.hold`): what was drawn last for a key; a new fix a little behind it is
/// held back for at most 30 s (it catches up, or it was really there). Not observed: it's read and written while
/// drawing.
final class GPSHold {
    private var shown: [String: (metres: Double, since: Date?, at: Date)] = [:]

    func steady(_ key: String, _ m: Double, now: Date) -> Double {
        if shown.count > 400 { shown = shown.filter { now.timeIntervalSince($0.value.at) < 60 } }
        guard let s = shown[key], abs(now.timeIntervalSince(s.at)) < 10 else {
            shown[key] = (m, nil, now); return m
        }
        let held = RealPositions.hold(shown: s.metres, new: m)
        if held > m {
            let since = s.since ?? now
            if now.timeIntervalSince(since) <= 30 { shown[key] = (held, since, max(s.at, now)); return held }
        }
        shown[key] = (m, nil, max(s.at, now))
        return m
    }

    func forget(_ key: String) { shown[key] = nil }
    func reset() { shown = [:] }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

// MARK: a single trip's road (the live sheet, Fastest trip's map)

extension LiveTrip {
    /// Its stop-to-stop pieces as `RealPositions` takes them: metres along its road as `position` and `metres(ofStop:)`
    /// count them.
    var legs: [RealPositions.Leg] {
        var out: [RealPositions.Leg] = []
        for i in stops.indices.dropLast() {
            guard let d = departure(i), let a = arrival(i + 1) else { continue }
            let from = metres(ofStop: i), way = road(from: from, to: metres(ofStop: i + 1))
            guard way.count >= 2 else { continue }
            let l = RealPositions.Leg(start: from, path: way.map { GeoPoint($0) }, departure: d, arrival: a)
            if l.length > 0 { out.append(l) }
        }
        return out
    }

    /// Where its GPS puts it (metres along), when the fix is on its road: `metres` moved on to `now`
    /// (`RealPositions.place`), `raw` where the fix itself is, at its own time.
    /// `previous`: its fix before (0.34): moved on at the pace it was seen going, late as it is (`RealPositions.place`).
    func gpsPlace(_ fix: GPSFix, previous: GPSFix? = nil, now: Date) -> (raw: Double, metres: Double)? {
        let l = legs
        guard let s = RealPositions.snap(fix, on: l) else { return nil }
        let seen = RealPositions.observedSpeed(fix, previous: previous, on: l)
        let pace = seen == nil ? RealPositions.Pace() : RealPositions.Pace(speed: seen, late: RealPositions.lateness(s, at: fix.at, on: l))
        let moved = RealPositions.advance(s, from: fix.at, on: l, now: now, pace: pace)
        return (l[s.leg].start + s.along, l[moved.leg].start + moved.along)
    }

    /// The soonest its GPS fix lets it be at stop `i` (`Approach.arrival`): nil when the fix isn't on its road, it has
    /// passed the stop, or there are no times to go by.
    func gpsArrival(_ fix: GPSFix, atStop i: Int, now: Date) -> Date? {
        guard stops.indices.contains(i), let p = gpsPlace(fix, now: now) else { return nil }
        return Approach.arrival(fixAt: fix.at, metres: p.raw, stopMetres: stops.indices.map { metres(ofStop: $0) },
                                times: stops.map(\.times), mine: i)
    }

    /// `position` for a spot its GPS gave: at a stop when within 15 m of one (it hasn't started at its first, it's
    /// done at its last), else on its way to the next stop along.
    func position(metres m: Double) -> (metres: Double, next: Int, atStop: Bool, started: Bool, done: Bool) {
        let n = stops.count
        guard n > 0 else { return (m, 0, true, false, true) }
        if let i = stops.indices.first(where: { abs(metres(ofStop: $0) - m) <= 15 }) {
            return (m, i, true, i > 0, i == n - 1)
        }
        let next = stops.indices.first { metres(ofStop: $0) > m } ?? (n - 1)
        if next == 0 { return (m, 0, true, false, false) }
        return (m, next, false, true, false)
    }
}

/// A trip you look at on its own (the live sheet, Fastest trip's map): where to draw it at `now`, by its GPS when
/// there's a usable fix on its road, else by its times.
/// `mine`: the stop you wait at (0.24.5): by its GPS it's drawn there only once its fix is (`Approach.drawn`), not as
/// soon as moving it on from its fix gets it there.
struct TripPlacement {
    let w: (metres: Double, next: Int, atStop: Bool, started: Bool, done: Bool)
    let fix: GPSFix?
    let timeMetres: Double

    @MainActor
    init(_ t: LiveTrip, tripId: String, now: Date, hold: GPSHold, mine: Int? = nil) {
        RealPositionsStore.shared.learn(tripId, trip: t)            // (a train: its number, for NS's position)
        let byTime = t.position(now)
        timeMetres = byTime.metres
        if let f = RealPositionsStore.shared.fix(for: tripId, now: now),
           let p = t.gpsPlace(f, previous: RealPositionsStore.shared.previousFix(for: tripId), now: now) {
            let m = mine.flatMap { t.stops.indices.contains($0) ? Approach.drawn(advanced: p.metres, raw: p.raw, mine: t.metres(ofStop: $0)) : nil } ?? p.metres
            let held = hold.steady(tripId, m, now: now)
            w = t.position(metres: held); fix = f
        } else {
            hold.forget(tripId)
            w = byTime; fix = nil
        }
    }
}

// MARK: many trips' pieces (the home map, everything moving)

/// The live map's pieces of each trip as one road, each trip's fix put on it once (again for a new fix or new
/// pieces), moved on every time it's drawn.
@MainActor
final class GPSPlacer {
    struct Placed {
        let coordinate: CLLocationCoordinate2D
        let bearing: Double?
        let piece: VehicleSegment       // the piece it's on (its next stop)
        let fix: GPSFix
    }

    private var roads: [String: (legs: [RealPositions.Leg], pieces: [VehicleSegment])] = [:]
    private var snaps: [String: (at: Date, spot: RealPositions.Spot?)] = [:]
    private let hold = GPSHold()

    /// New pieces: each trip's in departure order, a piece that comes twice once.
    func reset(_ segs: [VehicleSegment]) {
        roads = [:]; snaps = [:]; hold.reset()
        let byTrip = Dictionary(grouping: segs.filter { RealPositions.key($0.tripId) != nil && $0.path.count >= 2 }, by: \.tripId)
        for (id, list) in byTrip {
            var seen = Set<String>(), pieces: [VehicleSegment] = []
            for s in list.sorted(by: { $0.departure < $1.departure }) {
                let k = "\(s.departure.timeIntervalSince1970)|\(s.arrival.timeIntervalSince1970)|\(s.fromName)|\(s.toName)"
                if seen.insert(k).inserted { pieces.append(s) }
            }
            var legs: [RealPositions.Leg] = [], kept: [VehicleSegment] = [], at = 0.0
            for s in pieces {
                let l = RealPositions.Leg(start: at, path: s.path.map { GeoPoint($0) }, departure: s.departure, arrival: s.arrival)
                guard l.length > 0 else { continue }
                legs.append(l); kept.append(s); at += l.length
            }
            if !legs.isEmpty { roads[id] = (legs, kept) }
        }
    }

    /// The trips that could have a fix (OpenOV trips with a road).
    var trips: [String] { Array(roads.keys) }

    /// Where its GPS puts a trip at `now`, if it has a usable fix on its road.
    func place(_ tripId: String, now: Date) -> Placed? {
        guard let road = roads[tripId], let fix = RealPositionsStore.shared.fix(for: tripId, now: now) else { return nil }
        let spot: RealPositions.Spot
        if let s = snaps[tripId], s.at == fix.at {
            guard let sp = s.spot else { return nil }
            spot = sp
        } else {
            let sp = RealPositions.snap(fix, on: road.legs)
            snaps[tripId] = (fix.at, sp)
            guard let sp else { return nil }
            spot = sp
        }
        // (0.34: at the pace it was seen going between its last two fixes, late as it is)
        let seen = RealPositions.observedSpeed(fix, previous: RealPositionsStore.shared.previousFix(for: tripId), on: road.legs)
        let pace = seen == nil ? RealPositions.Pace() : RealPositions.Pace(speed: seen, late: RealPositions.lateness(spot, at: fix.at, on: road.legs))
        let moved = RealPositions.advance(spot, from: fix.at, on: road.legs, now: now, pace: pace)
        let m = hold.steady(tripId, road.legs[moved.leg].start + moved.along, now: now)
        guard let at = RealPositions.spot(atMetres: m, on: road.legs), let p = RealPositions.point(at, on: road.legs) else { return nil }
        return Placed(coordinate: p.point.coordinate, bearing: p.bearing ?? fix.bearing, piece: road.pieces[at.leg], fix: fix)
    }
}
