import Foundation

/// The rides kept for Your year in travel (0.35, `RideRecord`): Application Support/travel.json, on this phone only
/// (not sent anywhere, not in the friends vault). `TripManager.legDone` adds each ride; Reset everything clears it.
@MainActor
final class TravelLogStore: ObservableObject {
    static let shared = TravelLogStore()

    @Published private(set) var rides: [RideRecord] = []
    /// The year the home's card was put away for.
    @Published private(set) var dismissedYear: Int?
    /// The year the home shows its card for now (`refreshSeasonal`; nil: not now).
    @Published private(set) var seasonalYear: Int?

    private static let dismissedKey = "travelYear.dismissed"

    private static var file: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("travel.json")
    }

    private init() {
        if let d = try? Data(contentsOf: Self.file), let r = try? JSONDecoder().decode([RideRecord].self, from: d) { rides = r }
        let y = UserDefaults.standard.integer(forKey: Self.dismissedKey)
        dismissedYear = y > 0 ? y : nil
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(rides) else { return }
        try? d.write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func add(_ r: RideRecord) {
        rides = TravelLog.add(rides, r, now: Date())
        save()
        refreshSeasonal()
    }

    /// A ride's delay at your stop came in after it was kept.
    func noteLate(_ id: String, mins: Double) {
        guard let i = rides.firstIndex(where: { $0.id == id }), mins >= 1 else { return }
        rides[i].late = (mins * 10).rounded() / 10
        save()
    }

    /// The home's card put away for `year`.
    func dismiss(year: Int) {
        dismissedYear = year
        UserDefaults.standard.set(year, forKey: Self.dismissedKey)
        refreshSeasonal()
    }

    func reset() {
        rides = []
        dismissedYear = nil
        seasonalYear = nil
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
        try? FileManager.default.removeItem(at: Self.file)
    }

    /// This year's stats, from the kept rides, the leaderboard and the rides with friends.
    func stats(now: Date = Date()) -> TravelStats {
        TravelYear.stats(rides: rides, trips: ScoreBook.shared.trips, together: FriendTogetherStore.shared.rides.map(\.dep),
                         now: now, calendar: .current)
    }

    /// Worked out again for the home (as it appears, the app comes to the front, a ride is kept, the card is put away).
    func refreshSeasonal(now: Date = Date()) {
        let s = stats(now: now)
        let first: Date? = [rides.first?.dep, ScoreBook.shared.trips.map(\.at).min()].compactMap { $0 }.min()
        let y = TravelYear.seasonal(now: now, firstData: first, trips: s.trips, dismissed: dismissedYear, calendar: .current)
        if y != seasonalYear { seasonalYear = y }
    }
}
