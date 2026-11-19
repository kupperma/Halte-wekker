import Combine
import CoreLocation
import Foundation
import UIKit

/// Settings › Help improve Haltewekker › Share ride logs (0.28.1): off unless you turn it on. When on, after each trip
/// ends (and at most once an hour otherwise, when the app comes to the front) the new matching and ride lines of the
/// field log go to the relay, scrubbed (`LogScrub`), gzipped, at most 200 KB at a time and 2 MB a day. Not during a
/// trip, not in Low Data Mode (the request isn't allowed on a constrained network) and not in Low Power Mode. It only
/// reads the field log and the trip's phase: nothing about a trip, the alarm or matching changes.
///
/// 0.32: Share GPS points during rides (`fixesOn`, off unless you turn it on): while a trip runs, a point every few
/// seconds (`heard`, from the trip's own location updates: it asks for no GPS of its own); when it ends, trimmed
/// (`GPSShareRules.finished`) and sent with the next upload, at most 600 KB of points at a time and 4 MB a day.
@MainActor
final class LogShareStore: ObservableObject {
    static let shared = LogShareStore()
    static let onKey = "logShare.on"
    static let stateKey = "logShare.state.v1"
    static let fixesKey = "gpsShare.on"

    @Published private(set) var on: Bool
    /// Share GPS points during rides (0.32).
    @Published private(set) var fixesOn: Bool
    /// The one-time question was answered or put away (`ShareAsk`).
    @Published private(set) var asked: Bool
    @Published private(set) var state: LogShareState?
    @Published private(set) var busy = false
    /// What the last delete did, for Settings ("Deleted…", "Couldn't reach…").
    @Published private(set) var note: String?

    private weak var trip: TripManager?
    private var subs = Set<AnyCancellable>()
    private var wasRunning = false
    private var uploading = false
    private let session: URLSession
    /// The GPS points kept on the phone (the trip that runs, those waiting to go), in a small file.
    private var queue: GPSShareQueue
    private var queueSaved = Date.distantPast
    /// Counts every clear of the queue, so an upload that was under way doesn't drop points that came after it.
    private var queueEra = 0

    private static var queueFile: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gpsshare.json")
    }

    private init() {
        let d = UserDefaults.standard
        on = d.bool(forKey: Self.onKey)
        fixesOn = d.bool(forKey: Self.fixesKey)
        asked = d.bool(forKey: ShareAsk.askedKey)
        state = LogShareState.decode(d.data(forKey: Self.stateKey))
        queue = d.bool(forKey: Self.fixesKey) ? GPSShareQueue.decode(try? Data(contentsOf: Self.queueFile)) : GPSShareQueue()
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
        d.set(fixesOn, forKey: Self.fixesKey)
        if let state, let data = try? JSONEncoder().encode(state) { d.set(data, forKey: Self.stateKey) }
        else { d.removeObject(forKey: Self.stateKey) }
    }

    /// The points to the file (at most once a minute while a trip runs; `now` at once).
    private func saveQueue(now: Bool = true) {
        guard now || Date().timeIntervalSince(queueSaved) >= 60 else { return }
        queueSaved = Date()
        let file = Self.queueFile
        if queue.current == nil && queue.ready.isEmpty {
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: file) }
            return
        }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private func clearQueue() {
        queue = GPSShareQueue()
        queueEra += 1
        saveQueue()
    }

    /// Share GPS points during rides. Off: the points not sent yet go too.
    func setFixesOn(_ v: Bool) {
        guard v != fixesOn else { return }
        fixesOn = v
        if v, state == nil { state = LogShareState.fresh(now: Date()) }
        if !v { clearQueue() }
        note = nil
        save()
    }

    /// Both switches at once, and the question answered (the setup's step, the card).
    func answer(logs: Bool, fixes: Bool) {
        setOn(logs)
        setFixesOn(fixes)
        markAsked()
    }

    /// The card was answered or put away: it doesn't come back.
    func markAsked() {
        guard !asked else { return }
        asked = true
        UserDefaults.standard.set(true, forKey: ShareAsk.askedKey)
    }

    /// The saved switches read again ("Back to my own" after a test setup put them back).
    func reload() {
        let d = UserDefaults.standard
        on = d.bool(forKey: Self.onKey)
        asked = d.bool(forKey: ShareAsk.askedKey)
        let f = d.bool(forKey: Self.fixesKey)
        if f != fixesOn {
            fixesOn = f
            if !f { clearQueue() }
        }
        if (on || fixesOn) && state == nil {
            state = LogShareState.fresh(now: Date())
            save()
        }
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
        // (a trip's points from before the app last stopped, and no trip runs now: that trip ended)
        if !wasRunning, queue.current != nil { finishRide() }
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
        if ended {
            finishRide()
            Task { await self.upload(.tripEnded) }
        }
    }

    // MARK: GPS points (0.32)

    /// A location the trip heard (`TripManager.handle`): kept while a trip runs, when it's turned on. Reads the trip's
    /// leg and vehicle only.
    func heard(_ loc: CLLocation, trip t: TripManager) {
        guard fixesOn, Self.running(t.phase) else { return }
        let vehicle: String? = t.vehicle.map { FieldFormat.vehicle(line: $0.line, tripId: $0.tripId, isTrain: $0.isTrain) }
        let c = loc.coordinate
        let leg = GPSShareRules.leg(index: t.index, count: t.legs.count)
        guard let f = GPSShareRules.fix(at: loc.timestamp, lat: c.latitude, lon: c.longitude, accuracy: loc.horizontalAccuracy,
                                        speed: loc.speed, course: loc.course, leg: leg, vehicle: vehicle, ride: nil) else { return }
        queue.heard(f, newRide: { GPSShareRules.rideId() })
        saveQueue(now: false)
    }

    /// Your places: no point near one of them goes.
    private func zones() -> [GeoPoint] {
        var z: [GeoPoint] = PlacesStore.shared.list.map { $0.point }
        for p in [Place.home, Place.school, Place.homeBoard] {
            z.append(GeoPoint(lat: p.coordinate.latitude, lon: p.coordinate.longitude))
        }
        return z
    }

    /// The trip ended: its points trimmed, to go with the next upload.
    private func finishRide() {
        guard queue.current != nil else { return }
        queue.finishRide(zones: zones())
        saveQueue()
    }

    /// Points waiting to go (for Settings).
    var fixesWaiting: Int { queue.ready.count }

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
        guard on || fixesOn, var s = state, !uploading else { return }
        let now = Date(), today = LogShareRules.day(now)
        let fixesWaiting = fixesOn && !queue.ready.isEmpty
        guard LogShareRules.due(s, enabled: on || fixesOn, trigger: trigger, tripRunning: tripRunning,
                                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, now: now, today: today,
                                fixes: fixesWaiting) else { return }
        s = LogShareRules.tried(s, now: now)
        state = s; save()
        let batch: LogShareBatch = on ? LogShareRules.batch(FieldLog.shared.entries, after: s.through,
                                                            budget: LogShareRules.budget(s, today: today), known: known())
                                      : LogShareBatch()
        let points: (fixes: [SharedFix], bytes: Int, more: Bool) = fixesWaiting
            ? GPSShareRules.batch(queue.ready, budget: GPSShareRules.budget(s, today: today))
            : ([], 0, false)
        guard !batch.lines.isEmpty || !points.fixes.isEmpty else { return }
        let era = queueEra
        var put = LogSharePut(install: s.install, secret: s.secret, app: Self.appVersion, lines: batch.lines)
        if !points.fixes.isEmpty {
            put.fixes = points.fixes
            put.tz = TimeZone.current.secondsFromGMT()
        }
        guard let body = try? JSONEncoder().encode(put), let req = request(LogShareRules.path, body: body) else { return }
        uploading = true
        defer { uploading = false }
        // (a trip that ended behind the lock screen: a little time to finish this)
        let app = UIApplication.shared
        let bg = app.beginBackgroundTask(withName: "logShare", expirationHandler: nil)
        defer { if bg != .invalid { app.endBackgroundTask(bg) } }
        let answer = await send(req, label: LogShareRules.path)
        // (switched off, or deleted with a new id, meanwhile: what was sent isn't counted on the new one)
        guard answer?.status == 200, on || fixesOn, let cur = state, cur.install == put.install else { return }
        // (the points that went: unless the queue was cleared meanwhile, the first of those waiting)
        if !points.fixes.isEmpty, era == queueEra {
            queue.sent(points.fixes.count)
            saveQueue()
        }
        state = LogShareRules.sent(cur, on ? batch : LogShareBatch(), fixBytes: points.bytes, now: Date(), today: today)
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
