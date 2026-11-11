import CryptoKit
import Foundation
import MediaPlayer
import Security
import UIKit

/// The song you're listening to, for the ride screen and the lock screen.
struct Song: Equatable {
    var title: String
    var artist: String
    var playing: Bool
    var app: String                 // "Spotify" or "Apple Music"
    var artURL: URL? = nil          // Spotify cover
    var image: UIImage? = nil       // Apple Music cover
    static func == (a: Song, b: Song) -> Bool {
        a.title == b.title && a.artist == b.artist && a.playing == b.playing && a.app == b.app && a.artURL == b.artURL
    }
}

enum MusicSource: String, CaseIterable, Identifiable {
    case off, spotify, appleMusic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }
}

/// Reads what's playing during a trip. Apple Music works right away. Spotify needs your own (free) Spotify app,
/// because Spotify only shares what's playing through its Web API.
@MainActor
final class NowPlaying: ObservableObject {
    static let redirect = "https://kupperma.github.io/Halte-wekker/spotify.html"

    @Published var source: MusicSource = MusicSource(rawValue: UserDefaults.standard.string(forKey: "musicSource") ?? "") ?? .off {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "musicSource")
            song = nil; spotifyError = nil
            if source == .appleMusic { askAppleMusic() }
            restart()
        }
    }
    @Published var clientId: String = UserDefaults.standard.string(forKey: "spotifyClientId") ?? "" {
        didSet { UserDefaults.standard.set(clientId.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "spotifyClientId") }
    }
    @Published private(set) var song: Song?
    @Published private(set) var spotifyConnected = Keychain.get("spotify.refresh") != nil
    @Published private(set) var spotifyError: String?
    @Published private(set) var appleMusicAllowed = MPMediaLibrary.authorizationStatus() == .authorized
    @Published private(set) var busy = false

    /// Called when the song changes, so the Live Activity follows.
    var onChange: (() -> Void)?

    private var loop: Task<Void, Never>?
    private var running = false
    private var fast = false
    private var access: (token: String, until: Date)?
    private var pending: (verifier: String, state: String)?
    private var quietUntil = Date.distantPast
    private var id: String { clientId.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: when to look

    /// During a trip: every 15 s, or every 5 s while the ride screen is on.
    func start() { running = true; restart() }
    func stop() { running = false; loop?.cancel(); loop = nil; song = nil }
    func setFast(_ f: Bool) { guard f != fast else { return }; fast = f; restart() }

    /// One look now, for the settings screen.
    func checkOnce() { Task { await check() } }

    private func restart() {
        loop?.cancel(); loop = nil
        guard running, source != .off else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                let wait = self.fast ? 5.0 : 15.0
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private func check() async {
        let new: Song?
        switch source {
        case .off: new = nil
        case .appleMusic: new = appleNow()
        case .spotify:
            guard spotifyConnected, Date() > quietUntil else { return }
            switch await spotifyNow() {
            case .some(let s): new = s
            case .none: return                      // couldn't ask: keep what we had
            }
        }
        let changed = new != song
        song = new
        if changed { onChange?() }
    }

    // MARK: Apple Music

    private func askAppleMusic() {
        guard MPMediaLibrary.authorizationStatus() == .notDetermined else { appleMusicAllowed = MPMediaLibrary.authorizationStatus() == .authorized; return }
        MPMediaLibrary.requestAuthorization { s in
            Task { @MainActor in self.appleMusicAllowed = s == .authorized; self.checkOnce() }
        }
    }

    private func appleNow() -> Song? {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return nil }
        let p = MPMusicPlayerController.systemMusicPlayer
        guard let it = p.nowPlayingItem, let t = it.title, !t.isEmpty else { return nil }
        return Song(title: t, artist: it.artist ?? "", playing: p.playbackState == .playing, app: "Apple Music",
                    image: it.artwork?.image(at: CGSize(width: 240, height: 240)))
    }

    // MARK: Spotify

    /// The Spotify sign-in page, to open in a web sign-in sheet. The answer comes back to `finish(_:)`.
    func spotifySignInURL() -> URL? {
        guard id.count >= 20 else { spotifyError = "Paste your Spotify Client ID first."; return nil }
        let verifier = Self.random(64)
        let state = Self.random(16)
        pending = (verifier, state)
        UserDefaults.standard.set([verifier, state], forKey: "spotifyPending")
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: id),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: "user-read-currently-playing user-read-playback-state"),
            .init(name: "state", value: state),
        ]
        spotifyError = nil
        return c.url
    }

    /// haltewekker://spotify?code=…&state=… (from the sign-in sheet, or when the page opens the app).
    func finish(_ url: URL) async {
        guard url.scheme == "haltewekker" else { return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ k: String) -> String? { q.first { $0.name == k }?.value }
        if pending == nil, let p = UserDefaults.standard.stringArray(forKey: "spotifyPending"), p.count == 2 { pending = (p[0], p[1]) }
        if let e = v("error") { spotifyError = e == "access_denied" ? "You said no on the Spotify page." : "Spotify: \(e)"; return }
        guard let code = v("code"), let pending, v("state") == pending.state else { spotifyError = "That sign-in didn’t match. Try again."; return }
        busy = true; defer { busy = false }
        do {
            try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                             "client_id": id, "code_verifier": pending.verifier])
            self.pending = nil
            UserDefaults.standard.removeObject(forKey: "spotifyPending")
            spotifyConnected = true
            spotifyError = nil
            if source != .spotify { source = .spotify }
            checkOnce()
        } catch { spotifyError = error.localizedDescription }
    }

    func report(_ message: String) { spotifyError = message }

    func disconnectSpotify() {
        Keychain.set("spotify.refresh", nil)
        access = nil; spotifyConnected = false; song = nil
    }

    /// nil = couldn't ask; .some(nil) = nothing playing.
    private func spotifyNow() async -> Song?? {
        guard let token = await accessToken() else { return nil }
        var r = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing?additional_types=episode")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 10
        guard let res = try? await URLSession.shared.data(for: r), let http = res.1 as? HTTPURLResponse else { return nil }
        let d = res.0
        switch http.statusCode {
        case 200: break
        case 204: return .some(nil)
        case 401: access = nil; return nil
        case 403:
            spotifyError = "Spotify says this account isn’t allowed. Add yourself under User Management in your Spotify app, and check the account has Premium."
            quietUntil = Date().addingTimeInterval(300); return nil
        case 429:
            let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            quietUntil = Date().addingTimeInterval(min(600, wait)); return nil
        default: return nil
        }
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let item = j["item"] as? [String: Any],
              let name = item["name"] as? String else { return .some(nil) }
        spotifyError = nil
        let playing = j["is_playing"] as? Bool ?? false
        var artist = ((item["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        var images = ((item["album"] as? [String: Any])?["images"] as? [[String: Any]]) ?? []
        if let show = item["show"] as? [String: Any] {           // a podcast episode
            artist = show["name"] as? String ?? artist
            if images.isEmpty { images = (item["images"] as? [[String: Any]]) ?? (show["images"] as? [[String: Any]]) ?? [] }
        }
        // the smallest cover that's still sharp (Spotify lists them big to small)
        let pick = images.last { ($0["width"] as? Int ?? 0) >= 200 } ?? images.first
        return .some(Song(title: name, artist: artist, playing: playing, app: "Spotify",
                          artURL: (pick?["url"] as? String).flatMap(URL.init(string:))))
    }

    private func accessToken() async -> String? {
        if let a = access, a.until > Date() { return a.token }
        guard let refresh = Keychain.get("spotify.refresh"), !id.isEmpty else { spotifyConnected = false; return nil }
        do {
            try await token(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": id])
            return access?.token
        } catch SpotifyFail.refused(let why) {
            disconnectSpotify(); spotifyError = "Spotify signed you out (\(why)). Connect again in Settings."
            return nil
        } catch { return nil }
    }

    enum SpotifyFail: LocalizedError {
        case refused(String), other(String)
        var errorDescription: String? {
            switch self { case .refused(let s), .other(let s): return s }
        }
    }

    private func token(_ form: [String: String]) async throws {
        var r = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        guard let at = j["access_token"] as? String else {
            let why = (j["error_description"] as? String) ?? (j["error"] as? String) ?? "error \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            if (j["error"] as? String) == "invalid_grant" || (j["error"] as? String) == "invalid_client" { throw SpotifyFail.refused(why) }
            throw SpotifyFail.other("Spotify said: \(why)")
        }
        access = (at, Date().addingTimeInterval(Double(j["expires_in"] as? Int ?? 3600) - 60))
        if let rt = j["refresh_token"] as? String { Keychain.set("spotify.refresh", rt) }
    }

    private static func random(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }
}

/// The Spotify sign-in lives in the keychain, readable while the phone is locked (trips run in the background).
enum Keychain {
    private static func query(_ k: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "nl.haltewekker", kSecAttrAccount as String: k]
    }
    static func get(_ k: String) -> String? {
        var q = query(k)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return String(data: d, encoding: .utf8) }
        return UserDefaults.standard.string(forKey: "kc." + k)
    }
    static func set(_ k: String, _ v: String?) {
        SecItemDelete(query(k) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "kc." + k)
        guard let v else { return }
        var a = query(k)
        a[kSecValueData as String] = Data(v.utf8)
        a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // A sideloaded app without a keychain group can't always write here; then fall back to the app's own storage.
        if SecItemAdd(a as CFDictionary, nil) != errSecSuccess { UserDefaults.standard.set(v, forKey: "kc." + k) }
    }
}
