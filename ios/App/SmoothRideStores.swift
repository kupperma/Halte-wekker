import CoreLocation
import Foundation

/// 0.39: what the adaptive wake-up learned (`AdaptiveWake`), on this phone only (UserDefaults), never sent anywhere.
/// Settings › Trips & alarm shows it, with an off switch and a reset.
@MainActor
final class AdaptiveWakeStore: ObservableObject {
    static let shared = AdaptiveWakeStore()
    private static let key = "adaptiveWake.book"

    @Published private(set) var book: WakeBook

    private init() {
        book = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(WakeBook.self, from: $0) } ?? WakeBook()
    }

    /// Settings › Trips & alarm › "Learn when I get up".
    var on: Bool {
        get { book.on }
        set { book.on = newValue; save() }
    }

    /// The wake settings the rules go by: yours, a little earlier where it learned that (`AdaptiveWake.effective`).
    func effective(_ s: WakeSettings) -> WakeSettings { AdaptiveWake.effective(s, book) }

    /// A ring before your stop, as it went. True: the minutes moved.
    @discardableResult func note(_ s: WakeSample) -> Bool {
        guard book.on else { return false }
        let moved = book.add(s)
        save()
        return moved
    }

    func reset() {
        let on = book.on
        book = WakeBook()
        book.on = on
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(book) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

/// 0.39: the trip's rides saved on the phone (`RideCache`), in `<Caches>/ride-cache.json`, for the stretches without
/// signal. Only for the trip that runs: cleared when it ends (and when the app starts: a trip doesn't outlive it).
@MainActor
final class RideCacheStore {
    static let shared = RideCacheStore()

    private var saved: SavedTrip?
    private var lastSaved: [String: Date] = [:]

    private static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("ride-cache.json")
    }

    private init() {}

    /// A ride's live answer, saved for the trip that started at `trip` (at most every `RideCache.every` per ride, unless
    /// `force`).
    func save(_ t: LiveTrip, tripId: String, at: Date, trip: Date?, force: Bool = false) {
        guard let trip, !tripId.isEmpty, t.stops.count >= 2 else { return }
        let now = Date()
        guard force || RideCache.due(lastSaved: lastSaved[tripId], now: now) || saved?.trip != trip else { return }
        lastSaved[tripId] = now
        let stops: [SavedRide.Stop] = t.stops.map { s in
            SavedRide.Stop(name: s.name, lat: s.coordinate.latitude, lon: s.coordinate.longitude, arrival: s.arrival,
                           departure: s.departure, scheduled: s.scheduled, platform: s.track)
        }
        let isTrain = !(t.mode.contains("BUS") || t.mode.contains("COACH")) && !t.mode.isEmpty
        let ride = SavedRide(tripId: tripId, line: t.line, headsign: t.headsign, isTrain: isTrain, live: t.live, mode: t.mode,
                             savedAt: at, stops: stops, shape: t.path.map { GeoPoint(lat: $0.latitude, lon: $0.longitude) })
        let next = RideCache.put(ride, into: saved, trip: trip)
        saved = next
        guard let data = RideCache.encode(next), let url = Self.url else { return }
        Task.detached(priority: .utility) { try? data.write(to: url, options: [.atomic]) }
    }

    /// The saved copy of a ride as a live trip (its stops, times, platforms and road) and when it was saved.
    func liveTrip(_ tripId: String, trip: Date?) -> (trip: LiveTrip, at: Date)? {
        guard let r = RideCache.ride(tripId, in: saved, trip: trip, now: Date()) else { return nil }
        let stops: [LiveTrip.Stop] = r.stops.map { s in
            LiveTrip.Stop(name: s.name, coordinate: .init(latitude: s.lat, longitude: s.lon), arrival: s.arrival, departure: s.departure,
                          scheduled: s.scheduled, track: s.platform)
        }
        let path = r.shape.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        return (LiveTrip(line: r.line, headsign: r.headsign, live: r.live, stops: stops, path: path, mode: r.mode), r.savedAt)
    }

    /// The saved copy of a ride as the ride's stops (`Transit.tripStops`).
    func tripStops(_ tripId: String, trip: Date?) -> [TripStop] {
        guard let r = RideCache.ride(tripId, in: saved, trip: trip, now: Date()) else { return [] }
        let times = RideCache.times(r)
        return r.stops.indices.map { i in
            TripStop(name: r.stops[i].name, coordinate: .init(latitude: r.stops[i].lat, longitude: r.stops[i].lon), arrival: times[i])
        }
    }

    /// The saved copy of a ride (plain).
    func ride(_ tripId: String, trip: Date?) -> SavedRide? { RideCache.ride(tripId, in: saved, trip: trip, now: Date()) }

    /// Saved for the trip that runs.
    func has(_ tripId: String, trip: Date?) -> Bool { ride(tripId, trip: trip) != nil }

    /// The trip ended (or the app started): the copy goes.
    func clear() {
        saved = nil
        lastSaved = [:]
        guard let url = Self.url else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
    }
}
