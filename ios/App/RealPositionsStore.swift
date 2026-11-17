import CoreLocation
import SwiftUI
import UIKit

/// Real bus positions (0.20.2): OVapi's open GPS feed (`RealPositions`), fetched only while a map or sheet on screen
/// draws a moving bus (`.realPositions(_:)`), the app is in front, the Settings switch is on and Low Power Mode is off.
/// Every 30 s at most, with its ETag (304: nothing new); not over a Low Data connection; on a failure again after
/// 60 s, 120 s, … 5 min, silently. The last good positions are kept. Display only: never fed to the matcher.
@MainActor
final class RealPositionsStore: ObservableObject {
    static let shared = RealPositionsStore()

    /// Each trip's newest fix by OVapi's trip_id (`RealPositions.key`).
    @Published private(set) var fixes: [String: GPSFix] = [:]

    private var demand: Set<UUID> = []
    private var loop: Task<Void, Never>?
    private var fetching = false
    private var etag: String?
    private var nextAt = Date.distantPast
    private var failures = 0
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
        session = URLSession(configuration: c)
        // (in the background, during a ride, nothing wakes up for it at all)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.inBackground = true; self?.update() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.inBackground = false; self?.update() }
        }
    }

    /// The Settings switch (on unless turned off).
    static var enabled: Bool { UserDefaults.standard.object(forKey: RealPositions.settingKey) as? Bool ?? true }

    /// Something on screen that draws a moving bus says whether it needs the positions now.
    func need(_ token: UUID, _ on: Bool) {
        if on { demand.insert(token) } else { demand.remove(token) }
        update()
    }

    /// The loop runs only while something needs it and the app isn't in the background.
    private func update() {
        if demand.isEmpty || inBackground {
            loop?.cancel(); loop = nil
        } else if loop == nil {
            loop = Task { [weak self] in await self?.run() }
        }
    }

    /// The fix to draw a Transitous trip by now (`RealPositions.usable`); nil when the switch is off.
    func fix(for tripId: String, now: Date = Date()) -> GPSFix? {
        guard Self.enabled, !fixes.isEmpty else { return nil }
        return RealPositions.usable(fixes, tripId: tripId, now: now)
    }

    private var mayFetch: Bool {
        Self.enabled && !ProcessInfo.processInfo.isLowPowerModeEnabled && UIApplication.shared.applicationState == .active
    }

    private func run() async {
        while !Task.isCancelled {
            if mayFetch, Date() >= nextAt { await fetch() }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func fetch() async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        var req = URLRequest(url: RealPositions.feedURL)
        req.setValue("Haltewekker-iOS", forHTTPHeaderField: "User-Agent")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await session.data(for: req)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 304 {
                succeeded(RealPositions.fetchLine(status: 304, bytes: 0, vehicles: fixes.count, parseMs: nil, next: RealPositions.every), kind: "304")
                return
            }
            guard status == 200, !data.isEmpty, data.count < 16 << 20 else { failed(status: status, error: nil); return }
            let started = Date()
            let feed = await Task.detached(priority: .utility) { RealPositions.parse(data) }.value
            let ms = Date().timeIntervalSince(started) * 1000
            // (a whole answer that holds nothing usable: keep what we have)
            guard !feed.fixes.isEmpty else { failed(status: status, error: nil); return }
            fixes = feed.fixes
            etag = http?.value(forHTTPHeaderField: "ETag")
            succeeded(RealPositions.fetchLine(status: 200, bytes: data.count, vehicles: feed.fixes.count, parseMs: ms, next: RealPositions.every), kind: "200")
        } catch {
            let code = (error as? URLError)?.code
            // (no longer needed: not a failure)
            if Task.isCancelled || code == .cancelled { return }
            failed(status: nil, error: code?.rawValue ?? -1)
        }
    }

    private func succeeded(_ line: String, kind: String) {
        failures = 0
        nextAt = Date().addingTimeInterval(RealPositions.every)
        log(line, kind: kind)
    }

    private func failed(status: Int?, error: Int?) {
        failures += 1
        let wait = RealPositions.backoff(failures: failures)
        nextAt = Date().addingTimeInterval(wait)
        log(RealPositions.fetchLine(status: status, error: error, bytes: 0, vehicles: fixes.count, parseMs: nil, next: wait), kind: "failed")
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

/// While `on` (and on screen): this view draws moving buses, so the real positions are fetched.
private struct RealPositionsDemand: ViewModifier {
    let on: Bool
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content
            .onAppear { RealPositionsStore.shared.need(token, on) }
            .onChange(of: on) { _, v in RealPositionsStore.shared.need(token, v) }
            .onDisappear { RealPositionsStore.shared.need(token, false) }
    }
}

extension View {
    /// This view draws moving buses while `on`: fetch the real positions meanwhile (`RealPositionsStore`).
    func realPositions(_ on: Bool) -> some View { modifier(RealPositionsDemand(on: on)) }
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

    /// Where its GPS puts it at `now` (metres along), when the fix is on its road.
    func gpsMetres(_ fix: GPSFix, now: Date) -> Double? {
        RealPositions.place(fix, on: legs, now: now)?.metres
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
struct TripPlacement {
    let w: (metres: Double, next: Int, atStop: Bool, started: Bool, done: Bool)
    let fix: GPSFix?
    let timeMetres: Double

    @MainActor
    init(_ t: LiveTrip, tripId: String, now: Date, hold: GPSHold) {
        let byTime = t.position(now)
        timeMetres = byTime.metres
        if let f = RealPositionsStore.shared.fix(for: tripId, now: now), let m = t.gpsMetres(f, now: now) {
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
        let moved = RealPositions.advance(spot, from: fix.at, on: road.legs, now: now)
        let m = hold.steady(tripId, road.legs[moved.leg].start + moved.along, now: now)
        guard let at = RealPositions.spot(atMetres: m, on: road.legs), let p = RealPositions.point(at, on: road.legs) else { return nil }
        return Placed(coordinate: p.point.coordinate, bearing: p.bearing ?? fix.bearing, piece: road.pieces[at.leg], fix: fix)
    }
}
