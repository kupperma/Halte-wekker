import CoreLocation
import Foundation

/// "On the line now" (0.42): for a stop on "Fastest trip, zoomed out", the buses and trains on their way to it that
/// get you there: each one's own GPS first (`RealPositionsStore`, only read; its fix, how old it is, how many stops it
/// has to go to yours), else just when it's due. The first one's road is drawn on the map with them on it. Looked at
/// every 10 seconds while the sheet is open; each trip's stops and road asked once a minute (`Transit.liveTrip`).
@MainActor
final class NearbyLineModel: ObservableObject {
    struct Coming: Identifiable, Equatable {
        let tripId: String
        let line: String
        let train: Bool
        var due: Date                   // at your stop
        var live: Bool
        var gpsAge: TimeInterval? = nil
        var stops: Int? = nil           // to go to yours
        var spot: GeoPoint? = nil       // its GPS
        var id: String { tripId }
    }

    @Published private(set) var coming: [Coming] = []
    @Published private(set) var route: [CLLocationCoordinate2D] = []
    @Published private(set) var routeTrain = false
    @Published private(set) var routeLine = ""
    @Published private(set) var stopId: String?

    private var trips: [String: (trip: LiveTrip, mine: Int, at: Date)] = [:]
    private var rides: [Ride] = []
    private var stop: GeoPoint?
    private var task: Task<Void, Never>?

    /// The most it follows at once.
    static let most = 3

    /// Follow the next departures from a stop (its first rides; the first `most` trips).
    func follow(stopId id: String, at p: GeoPoint, rides r: [Ride]) {
        var seen = Set<String>()
        let next: [Ride] = Array(r.filter { !$0.tripId.isEmpty && seen.insert($0.tripId).inserted }.prefix(Self.most))
        let same: Bool = id == stopId && next.map(\.tripId) == rides.map(\.tripId)
        guard !same else { return }
        task?.cancel()
        stopId = id; stop = p; rides = next
        coming = next.map { Coming(tripId: $0.tripId, line: $0.line, train: $0.isTrain, due: $0.departure, live: $0.live) }
        route = []
        routeLine = next.first?.line ?? ""
        routeTrain = next.first?.isTrain ?? false
        task = Task { [weak self] in await self?.run() }
    }

    func stopFollowing() {
        task?.cancel(); task = nil
        stopId = nil; coming = []; route = []; rides = []
    }

    /// A train among them (the positions of trains are fetched too).
    var anyTrain: Bool { rides.contains { $0.isTrain } }

    private func run() async {
        while !Task.isCancelled {
            await fetchTrips()
            guard !Task.isCancelled else { return }
            update(Date())
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    private func fetchTrips() async {
        guard let p = stop else { return }
        for r in rides {
            if let t = trips[r.tripId], Date().timeIntervalSince(t.at) < 60 { continue }
            let id: String = r.tripId
            let lt: LiveTrip? = await Transit.$urgent.withValue(true) { await Transit.liveTrip(id) }
            guard !Task.isCancelled else { return }
            guard let lt, !lt.stops.isEmpty else { continue }
            RealPositionsStore.shared.learn(id, trip: lt)            // (a train's number, for its NS position)
            let mine: Int = Self.nearest(lt, to: p)
            trips[id] = (lt, mine, Date())
            if trips.count > 30 { trips = trips.filter { Date().timeIntervalSince($0.value.at) < 300 } }
        }
        if let first = rides.first, let t = trips[first.tripId] {
            route = t.trip.path
        }
    }

    private static func nearest(_ t: LiveTrip, to p: GeoPoint) -> Int {
        var best = 0
        var bestM = Double.infinity
        for i in t.stops.indices {
            let c = t.stops[i].coordinate
            let m: Double = Geo.metres(p, GeoPoint(lat: c.latitude, lon: c.longitude))
            if m < bestM { bestM = m; best = i }
        }
        return best
    }

    private func update(_ now: Date) {
        let store = RealPositionsStore.shared
        var out: [Coming] = []
        for r in rides {
            var c = Coming(tripId: r.tripId, line: r.line, train: r.isTrain, due: r.departure, live: r.live)
            if let t = trips[r.tripId] {
                let s = t.trip.stops[t.mine]
                if let d = s.departure ?? s.arrival { c.due = d; c.live = t.trip.live }
                if let fix = store.fix(for: r.tripId, now: now) {
                    c.gpsAge = max(0, now.timeIntervalSince(fix.at))
                    c.spot = fix.point
                    if let placed = t.trip.gpsPlace(fix, previous: store.previousFix(for: r.tripId), now: now) {
                        let pos = t.trip.position(metres: placed.raw)
                        guard let n = Nearby.stopsAway(next: pos.next, atStop: pos.atStop, mine: t.mine) else { continue }   // past your stop
                        c.stops = n
                    }
                }
            }
            if c.due < now.addingTimeInterval(-60) { continue }
            out.append(c)
        }
        coming = out
    }
}
