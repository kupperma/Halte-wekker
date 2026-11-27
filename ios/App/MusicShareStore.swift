import Foundation
import MediaPlayer

/// Listening now (relay 2026-11-27): the song you listen to, for your friends and your live link, only while you
/// travel and only when you turned it on (Settings › Friends). The rules are in `MusicShare.swift` (tested). It looks on
/// the ride's own network tick (`FriendTravelShare`), at most every 30 s: no loop and no wake-up of its own. Apple Music
/// is read on the phone (the Music app's player) with a public cover and link from the iTunes Search API; Spotify and
/// other apps through your own Last.fm account, read by the relay (`/music/v1/now`, its key stays there). Never history:
/// only the song playing now, kept in memory, gone when the trip ends. The log only says "music · sharing on/off" and
/// how many songs went out.
@MainActor
final class MusicShareStore: ObservableObject {
    static let shared = MusicShareStore()

    private static let onKey = "music.share"
    private static let fromKey = "music.from"
    private static let whoKey = "music.who"
    private static let userKey = "music.lastfm"
    private static let budget = Budget(idle: 8, total: 12, retries: 0, backoff: 1, fastFailure: 2, minLeft: 3)

    @Published private(set) var on: Bool = UserDefaults.standard.bool(forKey: MusicShareStore.onKey)
    @Published var from: MusicFrom = MusicFrom(rawValue: UserDefaults.standard.string(forKey: MusicShareStore.fromKey) ?? "") ?? .appleMusic {
        didSet {
            guard from != oldValue else { return }
            UserDefaults.standard.set(from.rawValue, forKey: Self.fromKey)
            current = nil
            problem = nil
            if on && from == .appleMusic { askAppleMusic() }
            FriendTravelShare.shared.settingsChanged()
        }
    }
    @Published var who: MusicAudience = MusicAudience(rawValue: UserDefaults.standard.string(forKey: MusicShareStore.whoKey) ?? "") ?? .all {
        didSet {
            guard who != oldValue else { return }
            UserDefaults.standard.set(who.rawValue, forKey: Self.whoKey)
            FriendTravelShare.shared.settingsChanged()
            LiveLinkStore.shared.tick()
        }
    }
    @Published var lastfmUser: String = UserDefaults.standard.string(forKey: MusicShareStore.userKey) ?? "" {
        didSet {
            let t: String = lastfmUser.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(t, forKey: Self.userKey)
            if from.viaLastfm { current = nil; problem = nil }
        }
    }
    /// The song now (only while you travel with sharing on, or right after "Check now").
    @Published private(set) var current: MusicNow?
    /// What's wrong with the source, in words ("Last.fm isn't set up yet").
    @Published private(set) var problem: String?
    /// The relay has no Last.fm key yet: the Last.fm choices show that instead of a song.
    @Published private(set) var lastfmMissing = false
    @Published private(set) var appleAllowed = MPMediaLibrary.authorizationStatus() == .authorized
    @Published private(set) var checking = false

    private var lastLook: Date?
    private var looking = false
    /// A cover and link per song, for this run of the app only.
    private var covers: [String: (coverUrl: String?, url: String?)] = [:]
    /// The songs that went out on this trip (a count for the log; forgotten at the end).
    private var sent: Set<String> = []

    private init() {}

    // MARK: the switch

    func setOn(_ v: Bool) {
        guard v != on else { return }
        on = v
        UserDefaults.standard.set(v, forKey: Self.onKey)
        FieldLog.shared.add(.ride, v ? "music · sharing on" : "music · sharing off")
        if v {
            if from == .appleMusic { askAppleMusic() }
        } else {
            current = nil
            sent = []
        }
        FriendTravelShare.shared.settingsChanged()
        LiveLinkStore.shared.tick()
    }

    private func askAppleMusic() {
        let s = MPMediaLibrary.authorizationStatus()
        guard s == .notDetermined else { appleAllowed = s == .authorized; return }
        MPMediaLibrary.requestAuthorization { st in
            Task { @MainActor in self.appleAllowed = st == .authorized }
        }
    }

    // MARK: what goes out

    /// What friends get with your travel state now.
    func forFriends(travelling: Bool, now: Date = Date()) -> LiveMusic? {
        let m: LiveMusic? = MusicShare.share(current, on: on, who: who, channel: .friends, travelling: travelling, now: now)
        if let m { sent.insert(m.title + "|" + (m.artist ?? "")) }
        return m
    }

    /// What your live link's page gets now.
    func forLink(travelling: Bool, now: Date = Date()) -> LiveMusic? {
        let m: LiveMusic? = MusicShare.share(current, on: on, who: who, channel: .link, travelling: travelling, now: now)
        if let m { sent.insert(m.title + "|" + (m.artist ?? "")) }
        return m
    }

    // MARK: when to look

    /// The ride's network tick (every 30 s on a trip): a look when one is due, while sharing is on and you travel.
    func tick(travelling: Bool) {
        guard on, travelling else {
            if current != nil && !travelling { stop() }
            return
        }
        guard !looking, MusicShare.lookDue(last: lastLook, now: Date()) else { return }
        lastLook = Date()
        Task { await look() }
    }

    /// The trip (and the live link) ended: the song is forgotten.
    func stop() {
        if !sent.isEmpty { FieldLog.shared.add(.ride, "music · \(sent.count) song\(sent.count == 1 ? "" : "s") shared") }
        sent = []
        current = nil
        lastLook = nil
    }

    /// "Check now" in Settings: one look, shown there only (nothing is sent outside a trip).
    func checkNow() {
        guard !looking else { return }
        checking = true
        Task {
            await look()
            checking = false
        }
    }

    private func look() async {
        looking = true
        defer { looking = false }
        let before: String? = current?.title
        switch from {
        case .appleMusic: await lookApple()
        case .spotify, .lastfm: await lookLastfm()
        }
        if current?.title != before { LiveLinkStore.shared.tick() }
    }

    // MARK: Apple Music (the Music app's player)

    private func lookApple() async {
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            appleAllowed = false
            problem = "Let Haltewekker see Apple Music: iPhone Settings › Apps › Haltewekker › Media & Apple Music."
            current = nil
            return
        }
        appleAllowed = true
        problem = nil
        let p = MPMusicPlayerController.systemMusicPlayer
        guard let it = p.nowPlayingItem, let t = it.title, !t.isEmpty else { current = nil; return }
        let artist: String = it.artist ?? ""
        var song = MusicNow(title: t, artist: artist, app: "Apple Music", playing: p.playbackState == .playing, seen: Date())
        let k: String = (artist + "|" + t).lowercased()
        if let c = covers[k] {
            song.coverUrl = c.coverUrl
            song.url = c.url
        } else if let found = await itunes(title: t, artist: artist) {
            covers[k] = found
            song.coverUrl = found.coverUrl
            song.url = found.url
        }
        if covers.count > 50 { covers.removeAll() }
        current = song
    }

    /// A public cover and Apple Music link for the song (the iTunes Search API, no key). A miss is kept too.
    private func itunes(title: String, artist: String) async -> (coverUrl: String?, url: String?)? {
        guard let u = MusicShare.searchURL(title: title, artist: artist) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 10
        guard let a = try? await Net.response(req, lane: .background, budget: Self.budget), a.status == 200 else { return nil }
        let none: (coverUrl: String?, url: String?) = (coverUrl: nil, url: nil)
        return MusicShare.itunesPick(a.data, title: title, artist: artist) ?? none
    }

    // MARK: Last.fm (through the relay)

    private func lookLastfm() async {
        let user: String = lastfmUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MusicShare.validUser(user) else {
            problem = user.isEmpty ? "Type your Last.fm username." : "That isn’t a Last.fm username."
            current = nil
            return
        }
        var c = URLComponents(string: LiveCrypto.relay + "/music/v1/now")
        c?.queryItems = [URLQueryItem(name: "user", value: user), URLQueryItem(name: "app", value: from == .spotify ? "spotify" : "lastfm")]
        guard let u = c?.url else { return }
        var req = URLRequest(url: u)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let a = try? await Net.response(req, lane: .background, budget: Self.budget) else { return }   // keep what we had
        switch a.status {
        case 200:
            lastfmMissing = false
            problem = nil
            current = MusicShare.relaySong(a.data, now: Date())
        case 503:
            lastfmMissing = true
            problem = "Last.fm isn’t set up yet."
            current = nil
        case 404:
            problem = "Last.fm doesn’t know “\(user)”."
            current = nil
        case 403:
            problem = "Your Last.fm listening is private. Last.fm › Settings › Privacy: show recent listening."
            current = nil
        default:
            break
        }
    }
}
