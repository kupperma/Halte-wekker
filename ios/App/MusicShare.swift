import Foundation

// Listening now (relay 2026-11-27), Android's `MusicShare.kt`: when the song you listen to goes to your friends (the
// travel state's `music`) and to a live link (payload v2's `music`), as plain values, tested without the player, the
// relay or the UI against docs/music-vectors.json. Opt-in (off by default), only while you travel, never history: the
// one song playing now, dropped when it's paused or the last look is 10 minutes old. Foundation only.

/// Who sees what you listen to.
enum MusicAudience: String, CaseIterable, Identifiable {
    /// Friends and live links.
    case all
    case friends
    case links
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Friends + live links"
        case .friends: return "Only friends"
        case .links: return "Only live links"
        }
    }
}

/// Where the song comes from on this phone.
enum MusicFrom: String, CaseIterable, Identifiable {
    /// The Music app (Apple Music and your own songs), read on the phone.
    case appleMusic
    /// Spotify, through your own Last.fm account (Spotify scrobbles to it), read by the relay.
    case spotify
    /// Any app that scrobbles to Last.fm.
    case lastfm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify (via Last.fm)"
        case .lastfm: return "Last.fm"
        }
    }
    var viaLastfm: Bool { self != .appleMusic }
}

/// The song playing now, as the phone last saw it.
struct MusicNow: Equatable {
    var title: String
    var artist: String = ""
    var app: String = ""
    var url: String? = nil
    var coverUrl: String? = nil
    var playing: Bool = true
    /// When a look last saw it (playing).
    var seen: Date
}

enum MusicShare {
    /// Older than this (s) and it isn't shown or sent.
    static let maxAge: TimeInterval = 600
    /// At most one look this often (s), on the ride's own network tick.
    static let lookEvery: TimeInterval = 30

    enum Channel { case friends, link }

    static func reaches(_ who: MusicAudience, _ c: Channel) -> Bool {
        switch who {
        case .all: return true
        case .friends: return c == .friends
        case .links: return c == .link
        }
    }

    /// What `channel` gets now (nil: nothing). `travelling`: a trip runs, or a live link is live.
    static func share(_ song: MusicNow?, on: Bool, who: MusicAudience, channel: Channel, travelling: Bool, now: Date) -> LiveMusic? {
        guard on, travelling, reaches(who, channel), let s = song, s.playing else { return nil }
        let age: TimeInterval = now.timeIntervalSince(s.seen)
        guard age < maxAge else { return nil }
        let title: String = LiveTripV2.clean(s.title, 80)
        guard !title.isEmpty else { return nil }
        let artist: String = LiveTripV2.clean(s.artist, 60)
        let app: String = LiveTripV2.clean(s.app, 20)
        return LiveMusic(title: title, artist: artist.isEmpty ? nil : artist, app: app.isEmpty ? nil : app,
                         url: link(s.url), coverUrl: cover(s.coverUrl), at: iso(s.seen))
    }

    /// Whether the next look is due (`last`: the last one).
    static func lookDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        let gap: TimeInterval = now.timeIntervalSince(last)
        return gap < 0 || gap >= lookEvery
    }

    /// "2027-01-15T07:59:30Z" (whole seconds, UTC).
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)))
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func https(_ s: String?, _ ok: (String) -> Bool) -> String? {
        guard let s, s.count <= 500, let c = URLComponents(string: s), c.scheme?.lowercased() == "https",
              let h = c.host?.lowercased(), ok(h) else { return nil }
        return s
    }

    /// A link to the song: only on Spotify, Apple Music or Last.fm.
    static func link(_ s: String?) -> String? {
        https(s) { h in h == "open.spotify.com" || h == "music.apple.com" || h == "www.last.fm" }
    }

    /// A cover: only from Spotify's, Apple's or Last.fm's image hosts.
    static func cover(_ s: String?) -> String? {
        https(s) { h in h == "i.scdn.co" || h.hasSuffix(".mzstatic.com") || h == "lastfm.freetls.fastly.net" }
    }

    // MARK: the iTunes Search API (no key): a public cover and Apple Music link for a song

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func searchURL(title: String, artist: String) -> URL? {
        let words: String = LiveTripV2.clean(artist + " " + title, 140)
        let term: String = words.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: "https://itunes.apple.com/search?term=\(term)&entity=song&limit=1")
    }

    private static func plain(_ s: String) -> String {
        let low: String = s.lowercased()
        return String(String.UnicodeScalarView(low.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static func alike(_ a: String, _ b: String) -> Bool {
        let x: String = plain(a)
        let y: String = plain(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.contains(y) || y.contains(x)
    }

    /// The first result's cover (300 px) and Apple Music link, when it's this song (the artist alike; no artist: the
    /// title alike). nil: no such result.
    static func itunesPick(_ data: Data, title: String, artist: String) -> (coverUrl: String?, url: String?)? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = j["results"] as? [[String: Any]], let r = results.first else { return nil }
        let ra: String = r["artistName"] as? String ?? ""
        let rt: String = r["trackName"] as? String ?? ""
        let same: Bool = plain(artist).isEmpty ? alike(title, rt) : alike(artist, ra)
        guard same else { return nil }
        let art: String? = (r["artworkUrl100"] as? String).map { $0.replacingOccurrences(of: "100x100bb", with: "300x300bb") }
        var page: String? = r["trackViewUrl"] as? String
        if let p = page, var c = URLComponents(string: p) {
            c.queryItems = c.queryItems?.filter { $0.name != "uo" }
            if c.queryItems?.isEmpty == true { c.queryItems = nil }
            page = c.string
        }
        return (cover(art), link(page))
    }

    // MARK: the relay's Last.fm answer (/music/v1/now)

    /// The song in the relay's answer (nil: nothing playing, or not an answer). `now`: when it came.
    static func relaySong(_ data: Data, now: Date) -> MusicNow? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              j["nowPlaying"] as? Bool == true, let t = j["title"] as? String, !t.isEmpty else { return nil }
        return MusicNow(title: t, artist: j["artist"] as? String ?? "", app: j["app"] as? String ?? "",
                        url: j["url"] as? String, coverUrl: j["coverUrl"] as? String, playing: true, seen: now)
    }

    /// A Last.fm username as typed: 2–15 letters, digits, "_" or "-", starting with a letter.
    static func validUser(_ s: String) -> Bool {
        let t: String = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: "^[A-Za-z][A-Za-z0-9_-]{1,14}$", options: .regularExpression) != nil
    }
}
