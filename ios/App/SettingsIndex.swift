import Foundation

// Settings in topics (0.32.1): the main page's topics and every setting on their pages, for the search on the main
// page. Plain values (no SwiftUI), so the search can be tested. The pages themselves are in SettingsHub.swift; each row
// there carries its entry's `id`, so a search result can open the right page and scroll to it.

/// A topic on Settings' main page: its own page with the settings of one kind.
enum SettingsTopic: String, CaseIterable, Identifiable, Hashable, Sendable {
    case trips, places, school, friends, map, notifications
    case battery, share, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trips: return "Trips & alarm"
        case .places: return "Your places"
        case .school: return "School & mornings"
        case .friends: return "Friends"
        case .map: return "Map & home"
        case .notifications: return "Notifications"
        case .battery: return "Battery & data"
        case .share: return "Help improve"
        case .advanced: return "Advanced"
        }
    }

    /// The SF Symbol on its row: an outline glyph, drawn in the secondary colour.
    var symbol: String {
        switch self {
        case .trips: return "bus"
        case .places: return "house"
        case .school: return "graduationcap"
        case .friends: return "person.2"
        case .map: return "map"
        case .notifications: return "bell"
        case .battery: return "battery.50percent"
        case .share: return "heart"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    /// The main page's two lists: what you use (1), and the rest (2).
    var group: Int {
        switch self {
        case .trips, .places, .school, .friends, .map, .notifications: return 1
        case .battery, .share, .advanced: return 2
        }
    }

    /// The page's title: "Help improve" is "Help improve Haltewekker" on its page.
    var pageTitle: String { self == .share ? "Help improve Haltewekker" : title }

    static func inGroup(_ g: Int) -> [SettingsTopic] { allCases.filter { $0.group == g } }
}

/// One setting, as the search finds it: its row's title, the topic it's on, and other words people may type.
struct SettingsEntry: Identifiable, Equatable, Hashable, Sendable {
    /// The row's anchor on its topic's page ("alarm.sound").
    let id: String
    let title: String
    let topic: SettingsTopic
    var keywords: [String] = []
    /// Only on the Veghel ⇄ BUas corridor (the New look switch).
    var corridorOnly = false
    /// Only while the test setup is in use (Back to my own).
    var testSetupOnly = false
}

/// Every setting there is, in the order of the pages, and the search over them.
enum SettingsIndex {
    static let all: [SettingsEntry] = [
        // Trips & alarm
        SettingsEntry(id: "trips.autoStart", title: "Start trips by itself", topic: .trips, keywords: ["automatic", "auto start", "location always", "leave stop"]),
        SettingsEntry(id: "trips.announce", title: "Station announcement", topic: .trips, keywords: ["jingle", "voice", "stop name", "announcer"]),
        SettingsEntry(id: "trips.quiet", title: "Just a notification when I’m on my phone", topic: .trips, keywords: ["unlocked", "in use", "quiet", "awake"]),
        SettingsEntry(id: "trips.chime", title: "Chime at the stop", topic: .trips, keywords: ["arrive", "arrival", "jingle", "ring at stop"]),
        SettingsEntry(id: "trips.autoHome", title: "Switch to Home at school", topic: .trips, keywords: ["direction", "going home", "auto home"]),
        SettingsEntry(id: "trips.motion", title: "Use motion to notice rides faster", topic: .trips, keywords: ["motion & fitness", "activity", "walking", "cycling", "on board", "battery", "permission"]),
        SettingsEntry(id: "alarm.sound", title: "Alarm sound", topic: .trips, keywords: ["ringtone", "tone", "steam train", "chime", "marimba", "sunrise", "beeps", "siren"]),
        SettingsEntry(id: "alarm.test", title: "Test the alarm", topic: .trips, keywords: ["try", "hear", "preview sound"]),
        SettingsEntry(id: "alarm.headphones", title: "Sound only with headphones", topic: .trips, keywords: ["vibrate", "silent", "earbuds", "bluetooth", "airpods", "quiet"]),
        SettingsEntry(id: "alarm.music", title: "If music is playing", topic: .trips, keywords: ["pause music", "keep playing", "volume", "louder"]),
        SettingsEntry(id: "alarm.backup", title: "Backup alarm", topic: .trips, keywords: ["minutes", "timer", "gps drops", "safety"]),
        SettingsEntry(id: "wake.by", title: "Wake me … before my stop", topic: .trips, keywords: ["by time", "by distance", "minutes", "min", "eta", "arrival", "how soon", "when to wake", "train", "bus"]),
        SettingsEntry(id: "wake.bus", title: "Wake distance by bus", topic: .trips, keywords: ["km", "kilometres", "how far", "usual distance"]),
        SettingsEntry(id: "wake.train", title: "Wake distance by train", topic: .trips, keywords: ["km", "kilometres", "how far", "usual distance"]),
        SettingsEntry(id: "more.tips", title: "Before you nap", topic: .trips, keywords: ["tips", "sleep", "wake up", "sure"]),
        SettingsEntry(id: "more.leaderboard", title: "Leaderboard", topic: .trips, keywords: ["score", "scores", "fastest", "this week", "all time"]),
        SettingsEntry(id: "more.steady", title: "How steady are they now?", topic: .trips, keywords: ["reliability", "delays", "late", "punctual", "on time"]),
        // Your places
        SettingsEntry(id: "places.now", title: "Your school and home", topic: .places, keywords: ["profile", "timetable", "campus", "town"]),
        SettingsEntry(id: "places.list", title: "Your places", topic: .places, keywords: ["home", "school", "rename", "move", "order", "chips"]),
        SettingsEntry(id: "places.add", title: "Add a place", topic: .places, keywords: ["new place", "pin", "favourite"]),
        SettingsEntry(id: "places.stops", title: "Home bus stops and lines", topic: .places, keywords: ["board", "lines", "stops near home", "my lines", "live bus times"]),
        // School & mornings
        SettingsEntry(id: "school.alarm", title: "School alarm", topic: .school, keywords: ["wake me for school", "first class", "morning alarm"]),
        SettingsEntry(id: "school.timetable", title: "School calendar or your week", topic: .school, keywords: ["timetable", "calendar", "timeedit", "same times every week", "classes"]),
        SettingsEntry(id: "school.early", title: "At school before class", topic: .school, keywords: ["minutes early", "be there", "arrive"]),
        SettingsEntry(id: "school.wake", title: "Wake me before I leave", topic: .school, keywords: ["minutes", "wake up time", "getting ready"]),
        SettingsEntry(id: "morning.screen", title: "Morning screen", topic: .school, keywords: ["photos", "look", "metro", "wallpaper", "background"]),
        SettingsEntry(id: "morning.show", title: "Show the morning screen now", topic: .school, keywords: ["try", "preview"]),
        // Friends
        SettingsEntry(id: "friends.open", title: "Friends", topic: .friends, keywords: ["chats", "groups", "requests", "friend code", "backup code", "sharing"]),
        SettingsEntry(id: "friends.test", title: "Test friend", topic: .friends, keywords: ["bot", "add a test friend", "remove test friend", "try friends"]),
        // Map & home
        SettingsEntry(id: "map.homeStyle", title: "Home style", topic: .map, keywords: ["live around you", "next trip first", "home screen"]),
        SettingsEntry(id: "map.style", title: "Map style", topic: .map, keywords: ["standard", "muted", "satellite", "hybrid"]),
        SettingsEntry(id: "map.vehicles", title: "Live buses and trains", topic: .map, keywords: ["moving", "vehicles on the map"]),
        SettingsEntry(id: "map.real", title: "Real bus and train positions", topic: .map, keywords: ["gps", "ovapi", "ns", "where they are", "data"]),
        SettingsEntry(id: "map.movingStation", title: "Moving station", topic: .map, keywords: ["animation", "train behind", "still picture", "backdrop"]),
        SettingsEntry(id: "map.newLook", title: "New look", topic: .map, keywords: ["old look", "station look", "0.18"], corridorOnly: true),
        // Notifications
        SettingsEntry(id: "notices.watched", title: "Notifications and what’s watched", topic: .notifications, keywords: ["watch", "stop all notifications", "history", "bell", "lines", "trains"]),
        SettingsEntry(id: "lock.music", title: "Show music from", topic: .notifications, keywords: ["lock screen", "spotify", "apple music", "song", "now playing"]),
        SettingsEntry(id: "lock.spotify", title: "Connect Spotify", topic: .notifications, keywords: ["client id", "disconnect spotify", "music"]),
        SettingsEntry(id: "lock.preview", title: "Preview on the lock screen", topic: .notifications, keywords: ["live activity", "lock screen", "dynamic island"]),
        // Battery & data
        SettingsEntry(id: "battery.use", title: "Battery and data use", topic: .battery, keywords: ["mobile data", "mb", "energy", "gps", "today", "this week", "last rides"]),
        SettingsEntry(id: "battery.longRides", title: "Save battery on long rides", topic: .battery, keywords: ["gps", "precise", "far from your stop", "power"]),
        // Help improve
        SettingsEntry(id: "share.logs", title: "Share ride logs", topic: .share, keywords: ["help improve", "send", "matching", "privacy"]),
        SettingsEntry(id: "share.fixes", title: "Share GPS points during rides", topic: .share, keywords: ["help improve", "location", "send", "privacy"]),
        SettingsEntry(id: "share.what", title: "What’s sent", topic: .share, keywords: ["privacy", "example", "who gets it", "kept"]),
        SettingsEntry(id: "share.delete", title: "Delete what I sent", topic: .share, keywords: ["remove", "privacy", "server"]),
        // Advanced
        SettingsEntry(id: "adv.demo", title: "Try it at home: a pretend trip", topic: .advanced, keywords: ["demo", "pretend", "practice", "test trip"]),
        SettingsEntry(id: "adv.log", title: "Connection and matching log", topic: .advanced, keywords: ["logs", "ride log", "requests", "copy the log", "debug"]),
        SettingsEntry(id: "adv.classic", title: "Classic vehicle matching", topic: .advanced, keywords: ["wrong bus", "wrong train", "old way", "matching"]),
        SettingsEntry(id: "adv.freeze", title: "When the app froze", topic: .advanced, keywords: ["freeze", "stuck", "diagnostics", "hang", "not responding"]),
        SettingsEntry(id: "adv.backToMine", title: "Back to my own setup", topic: .advanced, keywords: ["test setup", "restore"], testSetupOnly: true),
        SettingsEntry(id: "adv.setupAgain", title: "Set up again", topic: .advanced, keywords: ["setup", "first run", "school and home", "onboarding"]),
        SettingsEntry(id: "adv.testSetup", title: "Test the setup as a new user", topic: .advanced, keywords: ["new student", "first run", "setup", "onboarding"]),
        SettingsEntry(id: "adv.reset", title: "Reset everything", topic: .advanced, keywords: ["erase", "delete", "start over", "clear"]),
        SettingsEntry(id: "adv.about", title: "About and open data", topic: .advanced, keywords: ["version", "credits", "licence", "license", "transitous", "openstreetmap", "ovapi", "ns", "open-meteo", "rijden de treinen"]),
    ]

    /// The settings this phone shows: the New look switch only on the corridor, Back to my own only in the test setup.
    static func entries(corridor: Bool, testSetup: Bool) -> [SettingsEntry] {
        all.filter { (corridor || !$0.corridorOnly) && (testSetup || !$0.testSetupOnly) }
    }

    static func entries(in topic: SettingsTopic, corridor: Bool, testSetup: Bool) -> [SettingsEntry] {
        entries(corridor: corridor, testSetup: testSetup).filter { $0.topic == topic }
    }

    /// Lower case, without accents or apostrophes ("What’s" is "whats"), the rest of the punctuation as spaces.
    static func fold(_ s: String) -> String {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .filter { $0 != "’" && $0 != "'" && $0 != "‘" }
        return String(f.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : " " })
    }

    static func words(_ s: String) -> [String] {
        fold(s).split(separator: " ").map(String.init)
    }

    /// The settings that match what's typed, best first: every word typed must start a word of the title or the
    /// keywords (not the topic's name: "alarm" would bring all of Trips & alarm). A title that starts with it comes first, then one whose words have them all,
    /// then the rest, each in the pages' order. Empty when nothing (or only spaces) is typed.
    static func search(_ query: String, in list: [SettingsEntry] = all) -> [SettingsEntry] {
        let q = words(query)
        guard !q.isEmpty else { return [] }
        let whole = q.joined(separator: " ")
        var hits: [(rank: Int, order: Int, entry: SettingsEntry)] = []
        for (i, e) in list.enumerated() {
            let title = words(e.title)
            let rest = title + e.keywords.flatMap { words($0) }
            guard q.allSatisfy({ t in rest.contains { $0.hasPrefix(t) } }) else { continue }
            let rank: Int
            if title.joined(separator: " ").hasPrefix(whole) { rank = 0 }
            else if q.allSatisfy({ t in title.contains { $0.hasPrefix(t) } }) { rank = 1 }
            else if e.keywords.contains(where: { words($0).joined(separator: " ").hasPrefix(whole) }) { rank = 2 }
            else { rank = 3 }
            hits.append((rank, i, e))
        }
        return hits.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }.map(\.entry)
    }
}
