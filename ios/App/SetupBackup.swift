import Foundation

/// "Test the setup as a new user" (0.23): your own setup, kept while you try the first-run setup as someone new. It
/// holds the saved values of every key the setup can change (your profile, your places, the home board's stops and
/// lines, the school calendars and times) and the ones learnt for your Home and School (the wake distances, the modes,
/// where it last saw you at home), exactly as they were stored, and a key that wasn't there as not there.
///
/// It's saved under its own key (`setup.backup.v1`) before the test changes anything, so a crash in the middle can't
/// lose it: a backup that never went `live` (the test's Done wasn't reached) is put back at the next launch. Plain
/// values, tested.
struct SetupBackup {
    static let storageKey = "setup.backup.v1"
    static let version = 1

    /// The saved keys it keeps, the ones the setup writes and the ones learnt for a place.
    static let keys = [
        ProfileLogic.storageKey, PlacesLogic.storageKey, "boardStops", "boardLines",
        "school.on", "school.cals", "school.early", "school.wake",
        "kmMem", "lastMode", "school.homeLat", "school.homeLon",
    ]

    /// When it was taken.
    var made: Date
    /// The test setup is in use (Done was tapped): it stays until you go back to your own.
    var live: Bool
    /// The keys it covers (`keys` when it was taken).
    var covered: [String]
    /// The stored values of the covered keys that were there (property-list values).
    var values: [String: Any]

    /// Takes the values now (`read` gives a key's stored value, nil when there's none).
    static func take(read: (String) -> Any?, now: Date) -> SetupBackup {
        var v: [String: Any] = [:]
        for k in keys { if let x = read(k), PropertyListSerialization.propertyList(x, isValidFor: .binary) { v[k] = x } }
        return SetupBackup(made: now, live: false, covered: keys, values: v)
    }

    /// Puts every covered key back as it was: `write` with its value, or with nil for a key that wasn't there.
    func restore(write: (String, Any?) -> Void) {
        for k in covered { write(k, values[k]) }
    }

    /// The same values (and the same keys missing) as another backup.
    func sameValues(as other: SetupBackup) -> Bool {
        covered == other.covered && NSDictionary(dictionary: values).isEqual(to: other.values)
    }

    // MARK: stored

    /// As it's saved: a property list.
    var stored: [String: Any] {
        ["version": Self.version, "made": made.timeIntervalSince1970, "live": live, "covered": covered, "values": values]
    }

    /// From what was saved (nil: none, or not one this version can read).
    init?(stored: Any?) {
        guard let d = stored as? [String: Any], (d["version"] as? Int) == Self.version,
              let covered = d["covered"] as? [String], let values = d["values"] as? [String: Any] else { return nil }
        self.made = Date(timeIntervalSince1970: (d["made"] as? Double) ?? 0)
        self.live = (d["live"] as? Bool) ?? false
        self.covered = covered
        self.values = values.filter { covered.contains($0.key) }
    }

    init(made: Date, live: Bool, covered: [String], values: [String: Any]) {
        self.made = made; self.live = live; self.covered = covered; self.values = values
    }

    /// What to do at launch with a saved backup: one whose test never went live is put back now (the app stopped in
    /// the middle of the setup, or of making the test live); a live one waits for "Back to my own".
    static func atLaunch(_ b: SetupBackup?) -> LaunchStep {
        guard let b else { return .nothing }
        return b.live ? .keepTesting : .restore
    }

    enum LaunchStep: Equatable { case nothing, keepTesting, restore }
}
