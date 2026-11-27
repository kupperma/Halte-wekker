package nl.haltewekker.profile

import java.text.Normalizer

// (A6, iOS 0.32.1 `SettingsIndex.swift`) Settings in topics: the main page's topics and every setting on their pages,
// for the search on the main page. Pure, so the search is tested. The search and the topics are iOS's; the entries are
// the settings this app has (Android has no alarm-sound picker, map style, Spotify or lock-screen preview; it has the
// permissions card, the home-screen widget and shortcuts).

enum class SettingsTopic(val title: String, val group: Int) {
    TRIPS("Trips & alarm", 1),
    PLACES("Your places", 1),
    SCHOOL("School & mornings", 1),
    FRIENDS("Friends", 1),
    MAP("Map & home", 1),
    NOTIFICATIONS("Notifications", 1),
    BATTERY("Battery & data", 2),
    SHARE("Help improve", 2),
    ADVANCED("Advanced", 2);

    val pageTitle: String get() = if (this == SHARE) "Help improve Haltewekker" else title

    companion object {
        fun inGroup(g: Int) = entries.filter { it.group == g }
    }
}

data class SettingsEntry(
    val id: String,
    val title: String,
    val topic: SettingsTopic,
    val keywords: List<String> = emptyList(),
    val testSetupOnly: Boolean = false,
)

object SettingsIndex {
    private fun e(id: String, title: String, topic: SettingsTopic, vararg keywords: String, testSetupOnly: Boolean = false) =
        SettingsEntry(id, title, topic, keywords.toList(), testSetupOnly)

    val all: List<SettingsEntry> = listOf(
        // Trips & alarm
        e("trips.autoStart", "Start trips by itself", SettingsTopic.TRIPS, "automatic", "auto start", "location always", "leave stop"),
        e("trips.announce", "Station announcement", SettingsTopic.TRIPS, "jingle", "voice", "stop name", "announcer"),
        e("trips.chime", "Chime at the stop", SettingsTopic.TRIPS, "arrive", "arrival", "jingle", "ring at stop", "tell me when i’m there"),
        e("trips.autoHome", "Switch to Home at school", SettingsTopic.TRIPS, "direction", "going home", "auto home"),
        e("trips.motion", "Use motion to notice rides faster", SettingsTopic.TRIPS, "motion & fitness", "activity", "walking", "cycling", "step", "on board", "battery", "permission"),
        e("alarm.headphones", "Sound only with headphones", SettingsTopic.TRIPS, "vibrate", "silent", "earbuds", "bluetooth", "quiet"),
        e("alarm.loudLater", "Out loud if I don't stop it (after 1 min)", SettingsTopic.TRIPS, "speaker", "escalate", "deep sleeper", "no headphones", "loud"),
        e("alarm.backup", "Backup alarm", SettingsTopic.TRIPS, "minutes", "timer", "gps drops", "safety"),
        e("wake.by", "Wake me … before my stop", SettingsTopic.TRIPS, "by time", "by distance", "minutes", "min", "eta", "arrival", "how soon", "when to wake", "train", "bus"),
        e("wake.bus", "Wake distance by bus", SettingsTopic.TRIPS, "km", "kilometres", "how far", "usual distance"),
        e("wake.train", "Wake distance by train", SettingsTopic.TRIPS, "km", "kilometres", "how far", "usual distance"),
        e("trips.permissions", "What the ride needs", SettingsTopic.TRIPS, "permissions", "allow", "location", "notifications", "exact alarms", "full screen", "battery limits", "background"),
        e("trips.studentOV", "Student travel product", SettingsTopic.TRIPS, "student ov", "studentenreisproduct", "ov-chipkaart", "free", "weekday", "weekend", "discount", "price", "costs", "duo", "fare"),
        e("trips.checkOut", "Check-out reminder", SettingsTopic.TRIPS, "check out", "uitchecken", "ov-chipkaart", "card", "pole", "forgot", "reminder"),
        e("trips.delayClaim", "Money back for a late train", SettingsTopic.TRIPS, "delay compensation", "geld terug bij vertraging", "refund", "claim", "late", "ns", "30 min"),
        e("trips.learned", "Learned from your rides", SettingsTopic.TRIPS, "habits", "walking speed", "walk", "change time", "transfer", "preferred stop", "reset", "learn", "worked on"),
        // Your places
        e("places.now", "Your school and home", SettingsTopic.PLACES, "profile", "campus", "town", "home stops", "stops near home"),
        e("adv.setupAgain", "Set up again", SettingsTopic.PLACES, "setup", "first run", "school and home", "onboarding", "move", "change home"),
        // School & mornings
        e("school.alarm", "School alarm", SettingsTopic.SCHOOL, "wake me for school", "first class", "morning alarm"),
        e("school.timetable", "School calendar or your week", SettingsTopic.SCHOOL, "timetable", "calendar", "timeedit", "same times every week", "classes"),
        e("school.early", "At school before class", SettingsTopic.SCHOOL, "minutes early", "be there", "arrive"),
        e("school.wake", "Wake me before I leave", SettingsTopic.SCHOOL, "minutes", "wake up time", "getting ready"),
        // Friends
        e("friends.open", "Friends", SettingsTopic.FRIENDS, "chats", "groups", "requests", "friend code", "backup code", "sharing", "leaderboard", "scores"),
        e("friends.test", "Test friend", SettingsTopic.FRIENDS, "bot", "add a test friend", "remove test friend", "try friends"),
        e("friends.music", "Share what I’m listening to", SettingsTopic.FRIENDS, "listening now", "music", "song", "spotify", "last.fm", "lastfm", "now playing", "listen too", "notification access"),
        // Map & home
        e("map.real", "Real bus and train positions", SettingsTopic.MAP, "gps", "ovapi", "ns", "where they are", "data"),
        e("map.busPosition", "Bus position", SettingsTopic.MAP, "real gps", "estimated", "where the bus is", "train position", "expected"),
        e("map.rainAdvice", "Rain advice for the walk", SettingsTopic.MAP, "umbrella", "weather", "wet", "bus instead", "walking", "forecast", "open-meteo"),
        e("map.ovfiets", "OV-fiets at the station", SettingsTopic.MAP, "rental bike", "bikes left", "fiets", "bike", "ns", "station"),
        e("map.widget", "Widget and shortcuts", SettingsTopic.MAP, "home screen widget", "app shortcuts", "long press", "when’s my bus", "departures", "voice"),
        // Notifications
        e("notices.works", "Works and disruptions on my routes", SettingsTopic.NOTIFICATIONS, "engineering works", "werkzaamheden", "storing", "disruption", "no trains", "buses replace trains", "evening before", "ns"),
        e("notices.lastHome", "Last way home", SettingsTopic.NOTIFICATIONS, "last train", "last bus", "night", "evening", "get home", "missed", "late"),
        // Battery & data
        e("battery.longRides", "Save battery on long rides", SettingsTopic.BATTERY, "gps", "precise", "far from your stop", "power", "rough gps"),
        e("battery.limits", "No battery limits", SettingsTopic.BATTERY, "battery optimisation", "background", "doze", "power", "allow"),
        // Help improve
        e("share.logs", "Share ride logs", SettingsTopic.SHARE, "help improve", "send", "matching", "privacy"),
        e("share.fixes", "Share GPS points during rides", SettingsTopic.SHARE, "help improve", "location", "send", "privacy"),
        e("share.what", "What’s sent", SettingsTopic.SHARE, "privacy", "example", "who gets it", "kept"),
        e("share.delete", "Delete what I sent", SettingsTopic.SHARE, "remove", "privacy", "server"),
        // Advanced
        e("adv.year", "Your year in travel", SettingsTopic.ADVANCED, "wrapped", "year", "stats", "statistics", "hours", "km", "kilometres", "co2", "carbon", "favourite line", "travel so far", "share"),
        e("adv.backToMine", "Back to my own setup", SettingsTopic.ADVANCED, "test setup", "restore", testSetupOnly = true),
        e("adv.testSetup", "Test the setup as a new user", SettingsTopic.ADVANCED, "new student", "first run", "setup", "onboarding"),
        e("adv.about", "About and open data", SettingsTopic.ADVANCED, "version", "credits", "licence", "license", "transitous", "openstreetmap", "ovapi", "ns", "open-meteo", "openfreemap", "maplibre"),
    )

    fun entries(testSetup: Boolean) = all.filter { testSetup || !it.testSetupOnly }

    fun entries(topic: SettingsTopic, testSetup: Boolean) = entries(testSetup).filter { it.topic == topic }

    /** Lower case, without accents or apostrophes ("What’s" is "whats"), the rest of the punctuation as spaces. */
    fun fold(s: String): String {
        val f = Normalizer.normalize(s.lowercase(), Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "")
            .filter { it != '’' && it != '\'' && it != '‘' }
        return f.map { if (it.isLetter() || it.isDigit() || it == '.') it else ' ' }.joinToString("")
    }

    fun words(s: String): List<String> = fold(s).split(' ').filter { it.isNotEmpty() }

    /**
     * The settings that match what's typed, best first: every word typed must start a word of the title or the
     * keywords. A title that starts with it comes first, then one whose words have them all, then a keyword that
     * starts with it, then the rest, each in the pages' order. Empty when nothing is typed.
     */
    fun search(query: String, list: List<SettingsEntry> = all): List<SettingsEntry> {
        val q = words(query)
        if (q.isEmpty()) return emptyList()
        val whole = q.joinToString(" ")
        data class Hit(val rank: Int, val order: Int, val e: SettingsEntry)
        val hits = ArrayList<Hit>()
        list.forEachIndexed { i, e ->
            val title = words(e.title)
            val rest = title + e.keywords.flatMap { words(it) }
            if (!q.all { t -> rest.any { it.startsWith(t) } }) return@forEachIndexed
            val rank = when {
                title.joinToString(" ").startsWith(whole) -> 0
                q.all { t -> title.any { it.startsWith(t) } } -> 1
                e.keywords.any { words(it).joinToString(" ").startsWith(whole) } -> 2
                else -> 3
            }
            hits.add(Hit(rank, i, e))
        }
        return hits.sortedWith(compareBy({ it.rank }, { it.order })).map { it.e }
    }
}
