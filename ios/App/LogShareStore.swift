import Combine
import Foundation
import UIKit

/// Settings › Help improve Haltewekker › Share ride logs (0.28.1): off unless you turn it on. When on, after each trip
/// ends (and at most once an hour otherwise, when the app comes to the front) the new matching and ride lines of the
/// field log go to the relay, scrubbed (`LogScrub`), gzipped, at most 200 KB at a time and 2 MB a day. Not during a
/// trip, not in Low Data Mode (the request isn't allowed on a constrained network) and not in Low Power Mode. It only
/// reads the field log and the trip's phase: nothing about a trip, the alarm or matching changes.
@MainActor
final class LogShareStore: ObservableObject {
    static let shared = LogShareStore()
    static let onKey = "logShare.on"
    static let stateKey = "logShare.state.v1"

    @Published private(set) var on: Bool
    @Published private(set) var state: LogShareState?
    @Published private(set) var busy = false
    /// What the last delete did, for Settings ("Deleted…", "Couldn't reach…").
    @Published private(set) var note: String?

    private weak var trip: TripManager?
    private var subs = Set<AnyCancellable>()
    private var wasRunning = false
    private var uploading = false
    private let session: URLSession

    private init() {
        let d = UserDefaults.standard
        on = d.bool(forKey: Self.onKey)
        state = LogShareState.decode(d.data(forKey: Self.stateKey))
        let c = URLSessionConfiguration.ephemeral
        c.allowsConstrainedNetworkAccess = false            // not in Low Data Mode
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 40
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        session = URLSession(configuration: c, delegate: Net.meter, delegateQueue: nil)   // (the battery log's real bytes)
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(on, forKey: Self.onKey)
        if let state, let data = try? JSONEncoder().encode(state) { d.set(data, forKey: Self.stateKey) }
        else { d.removeObject(forKey: Self.stateKey) }
    }

    /// The switch. On: lines from now on (a first install id and secret are made); off: nothing more goes.
    func setOn(_ v: Bool) {
        guard v != on else { return }
        on = v
        if v {
            // (only what's logged from now on: not what came while it was off)
            var s = state ?? LogShareState.fresh(now: Date())
            s.through = Date()
            state = s
        }
        note = nil
        save()
    }

    // MARK: when

    private static func running(_ p: TripManager.Phase) -> Bool {
        switch p {
        case .sleeping, .awake, .alarm, .transfer: return true
        case .idle, .finished: return false
        }
    }

    /// Watches the trip's phase only (it changes nothing): a trip that ended is a moment to send.
    func attach(_ t: TripManager) {
        guard trip == nil else { return }
        trip = t
        wasRunning = Self.running(t.phase)
        t.$phase
            .removeDuplicates()
            .sink { [weak self] p in
                // (published before the change lands: a moment later, once the trip's last lines are in)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.phaseChanged(p)
                }
            }
            .store(in: &subs)
    }

    private func phaseChanged(_ p: TripManager.Phase) {
        let now = Self.running(p)
        let ended = wasRunning && !now
        wasRunning = now
        if ended { Task { await self.upload(.tripEnded) } }
    }

    /// The app came to the front: at most once an hour.
    func tick() { Task { await self.upload(.tick) } }

    private var tripRunning: Bool { trip.map { Self.running($0.phase) } ?? false }

    // MARK: what

    /// Your places' names, people's names and account ids, to take out of every line.
    func known() -> LogScrubKnown {
        var k = LogScrubKnown()
        for p in PlacesStore.shared.list {
            switch p.kind {
            case .home: k.homes.append(p.name)
            case .school: k.schools.append(p.name)
            case .custom: k.places.append(p.name)
            }
        }
        let home = Place.home, school = Place.school
        let board = Place.homeBoard
        k.homes.append(contentsOf: [home.name, home.short, board.name, board.short])
        k.schools.append(contentsOf: [school.name, school.short])
        let words = RoleWords.current
        k.schools.append(words.school)
        if words.onCorridor { k.homes.append(words.homeTown) }
        if let campus = ProfileStore.shared.profile.campus { k.schools.append(campus) }
        let friends = FriendStore.shared
        if let b = friends.book {
            k.people.append(b.myName)
            k.people.append(contentsOf: b.friends.map(\.name))
            k.people.append(contentsOf: b.incoming.map(\.name))
            k.people.append(contentsOf: b.outgoing.map(\.name))
            k.ids.append(contentsOf: b.friends.map(\.id))
            k.ids.append(contentsOf: b.incoming.map(\.id))
            k.ids.append(contentsOf: b.outgoing.map(\.id))
        }
        if let a = friends.account { k.ids.append(a) }
        return k
    }

    /// The newest line of yours as it would go (or the sample, when there's none yet).
    func example() -> String {
        LogShareRules.example(FieldLog.shared.entries, known: known()) ?? LogShareRules.sample
    }

    private static var appVersion: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "?"
        let b = i?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    // MARK: sending

    private func request(_ path: String, body: Data) -> URLRequest? {
        guard let url = URL(string: NSStore.relay + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.allowsConstrainedNetworkAccess = false
        if let z = Gzip.compress(body) {
            r.httpBody = z
            r.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
        } else {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ r: URLRequest, label: String) async -> NetAnswer? {
        let s = session
        return try? await Net.response(r, lane: .background, send: { req in try await s.data(for: req) }, label: label)
    }

    private func upload(_ trigger: LogShareRules.Trigger) async {
        guard on, var s = state, !uploading else { return }
        let now = Date(), today = LogShareRules.day(now)
        guard LogShareRules.due(s, enabled: on, trigger: trigger, tripRunning: tripRunning,
                                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, now: now, today: today) else { return }
        s = LogShareRules.tried(s, now: now)
        state = s; save()
        let batch = LogShareRules.batch(FieldLog.shared.entries, after: s.through,
                                        budget: LogShareRules.budget(s, today: today), known: known())
        guard !batch.lines.isEmpty else { return }
        let put = LogSharePut(install: s.install, secret: s.secret, app: Self.appVersion, lines: batch.lines)
        guard let body = try? JSONEncoder().encode(put), let req = request(LogShareRules.path, body: body) else { return }
        uploading = true
        defer { uploading = false }
        // (a trip that ended behind the lock screen: a little time to finish this)
        let app = UIApplication.shared
        let bg = app.beginBackgroundTask(withName: "logShare", expirationHandler: nil)
        defer { if bg != .invalid { app.endBackgroundTask(bg) } }
        let answer = await send(req, label: LogShareRules.path)
        // (switched off, or deleted with a new id, meanwhile: what was sent isn't counted on the new one)
        guard answer?.status == 200, on, let cur = state, cur.install == put.install else { return }
        state = LogShareRules.sent(cur, batch, now: Date(), today: today)
        save()
    }

    /// "Delete what I sent": everything of this install id on the relay goes; then a new id (what comes later isn't
    /// tied to it). The switch stays as it is.
    func deleteSent() async {
        guard let s = state, !busy else { return }
        busy = true
        defer { busy = false }
        note = nil
        let del = LogShareDelete(install: s.install, secret: s.secret)
        guard let body = try? JSONEncoder().encode(del), let req = request(LogShareRules.deletePath, body: body) else { return }
        let answer = await send(req, label: LogShareRules.deletePath)
        guard let answer, answer.status == 200 else {
            note = "Couldn’t reach the server. Nothing was deleted yet: try again on Wi‑Fi or with Low Data Mode off."
            return
        }
        let n = (try? JSONSerialization.jsonObject(with: answer.data) as? [String: Any])?["deleted"] as? Int ?? 0
        let current = state ?? s
        state = current.rotated()
        save()
        note = n == 0 ? "Nothing of yours was on the server." : "Deleted: \(n) \(n == 1 ? "upload" : "uploads") from this phone."
    }
}
