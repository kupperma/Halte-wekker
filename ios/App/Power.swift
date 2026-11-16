import Foundation

// What the app does to save the battery and the main thread when nothing needs the work: plain numbers, so it can be
// tested without CoreLocation or ActivityKit. Nothing here makes an alarm later: on a leg, riding toward the stop
// that rings, GPS is always the best there is, and every alarm, phase or vehicle change on the lock screen goes at once.

/// The GPS speed the screens show: a new one only when it's worth drawing again (from or to unknown, across 1 m/s where
/// the ride screen shows "standing still", or half a metre a second off), not on every fix.
enum SpeedPublish {
    static func worth(old: Double?, new: Double?) -> Bool {
        switch (old, new) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (a?, b?): return abs(a - b) >= 0.5 || (a > 1) != (b > 1)
        }
    }
}

/// One region the app watches (your stations, BUas).
struct RegionSpec: Equatable {
    let id: String
    let lat: Double
    let lon: Double
    let radius: Double
    let entry: Bool
    let exit: Bool
}

enum RegionPlan {
    /// The regions watched now are the ones wanted (same ids, centres, radii and what they tell): nothing to register
    /// again. (iOS keeps them across launches.)
    static func same(wanted: [RegionSpec], current: [RegionSpec]) -> Bool {
        guard wanted.count == current.count else { return false }
        var byId: [String: RegionSpec] = [:]
        for c in current { byId[c.id] = c }
        guard byId.count == current.count else { return false }
        return wanted.allSatisfy { w in
            guard let c = byId[w.id] else { return false }
            return abs(c.lat - w.lat) < 1e-6 && abs(c.lon - w.lon) < 1e-6 && abs(c.radius - w.radius) < 0.5
                && c.entry == w.entry && c.exit == w.exit
        }
    }
}
