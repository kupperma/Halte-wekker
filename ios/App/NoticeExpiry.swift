import Foundation

/// How long each kind of notification stays on your lock screen before the app takes it off (0.24.2). iOS can't expire
/// a notification by itself: the app removes the old ones whenever it's awake (a ride's GPS, a region, a background
/// refresh). Opening the app still clears them all into the bell's list, as before.
///
/// Kinds are told apart by the request identifier's start. The alarm, its backup and "still on?" are never removed
/// here (a trip clears those itself), and an unknown identifier stays.
enum NoticeExpiry {
    /// Minutes a notification with this identifier stays; nil means it stays until you clear it or open the app.
    static func minutes(forId id: String) -> Double? {
        for (prefix, m) in rules where id.hasPrefix(prefix) { return m }
        return nil
    }

    /// Longest prefix first, so "goboard-" wins over "go-".
    private static let rules: [(String, Double)] = [
        ("arrive-leave", 15),      // "Leave in 10 min": old once you've left
        ("trip-ended", 10),
        ("linewatch-", 15),        // a watched line's departure or change
        ("autostart", 10),         // "your trip started by itself"
        ("platform-", 20),         // platform change or cancelled train: the train has left by then
        ("heads-up-", 10),         // the quiet wake-up when you were using your phone
        ("arrived-", 10),          // "You're at …"
        ("goboard-", 10),          // "You're on the …"
        ("samebus-", 10),
        ("delay-", 20),            // "… min late": the train has left by then
        ("wake-", 60),             // the school wake-up notifications (when AlarmKit isn't used)
        ("go-", 15),               // Fastest trip's "leave now" and changes (only the newest is kept anyway)
    ].sorted { $0.0.count > $1.0.count }

    /// The delivered notifications to take off now: `delivered` is (identifier, when it arrived).
    static func due(_ delivered: [(id: String, at: Date)], now: Date) -> [String] {
        delivered.compactMap { n in
            guard let m = minutes(forId: n.id) else { return nil }
            return now.timeIntervalSince(n.at) >= m * 60 ? n.id : nil
        }
    }
}
