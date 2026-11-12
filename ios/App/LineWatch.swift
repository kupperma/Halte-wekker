import Foundation
import UserNotifications

/// Watching a bus line at a stop ("305 to Eindhoven at Busstation"): it follows the next one and tells you
/// when it runs late, leaves early, is cancelled or has left. It stops by itself once you're on board.
struct LineWatch: Codable, Identifiable, Equatable {
    var id: String { "\(stopId)|\(line)|\(headsign)" }
    let stopId: String
    let stopName: String
    let line: String
    let headsign: String
    let since: Date
    var tripId: String?
    var planned: Date?
    var expected: Date?
    var told: Int?                  // the delay you were last told about
    var toldCancel = false
    var status = "Looking it up…"   // "07:41 · 4 min late"
    var cancelledToo: [String] = [] // later ones it already told you are cancelled
    var quiet = true                // the first look only sets things up
}

@MainActor
final class LineWatchStore: ObservableObject {
    static let shared = LineWatchStore()
    static let maxHours = 3.0

    @Published private(set) var watches: [LineWatch]
    /// TripManager keeps the app awake (location) while something is watched.
    var onChange: () -> Void = {}
    private var loop: Task<Void, Never>?

    private init() {
        watches = UserDefaults.standard.data(forKey: "lineWatches").flatMap { try? JSONDecoder().decode([LineWatch].self, from: $0) } ?? []
        watches.removeAll { Date().timeIntervalSince($0.since) > Self.maxHours * 3600 }
        if !watches.isEmpty { run() }
    }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(watches), forKey: "lineWatches") }

    static func key(stopId: String, line: String, headsign: String) -> String { "\(stopId)|\(line)|\(headsign)" }
    func isWatched(stopId: String, line: String, headsign: String) -> Bool { watches.contains { $0.id == Self.key(stopId: stopId, line: line, headsign: headsign) } }
    func watch(stopId: String, line: String, headsign: String) -> LineWatch? { watches.first { $0.id == Self.key(stopId: stopId, line: line, headsign: headsign) } }

    /// Tap the bell: watch this line here (starting with this bus, if you tapped one), or stop watching it.
    func toggle(stopId: String, stopName: String, line: String, headsign: String, tripId: String? = nil, delay: Int? = nil) {
        let k = Self.key(stopId: stopId, line: line, headsign: headsign)
        if watches.contains(where: { $0.id == k }) { stop(k); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        var w = LineWatch(stopId: stopId, stopName: stopName, line: line, headsign: headsign, since: Date())
        w.tripId = tripId; w.told = delay
        watches.append(w)
        persist(); onChange(); run()
        Task { await check() }
    }

    func stop(_ id: String) {
        watches.removeAll { $0.id == id }
        persist(); onChange()
        if watches.isEmpty { loop?.cancel(); loop = nil }
    }

    func reset() { watches = []; persist(); loop?.cancel(); loop = nil; onChange() }

    /// You're on a bus of this line: no need to watch it any more.
    func boarded(line: String) {
        let gone = watches.filter { $0.line == line }
        guard !gone.isEmpty else { return }
        for w in gone { stop(w.id) }
        notify(title: "You’re on the \(line)", body: "It stopped watching the \(line) for you.", id: "linewatch-off-\(line)", sound: false)
    }

    private func run() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.watches.isEmpty else { return }
                await self.check()
                // A bit quicker when the bus is close.
                let soon = self.watches.contains { ($0.expected ?? .distantFuture).timeIntervalSinceNow < 15 * 60 }
                try? await Task.sleep(nanoseconds: (soon ? 30 : 60) * 1_000_000_000)
            }
        }
    }

    private func check() async {
        let now = Date()
        for w in watches where now.timeIntervalSince(w.since) > Self.maxHours * 3600 {
            stop(w.id)
            notify(title: "Stopped watching the \(w.line)", body: "After \(Int(Self.maxHours)) hours it stops by itself. Tap the bell again if you still need it.", id: "linewatch-old-\(w.id)", sound: false)
        }
        for id in watches.map(\.id) {
            guard var w = watches.first(where: { $0.id == id }) else { continue }
            let line = await Transit.board(stopIds: [w.stopId], from: now.addingTimeInterval(-30 * 60), n: 40)
                .filter { $0.line == w.line }.sorted { $0.scheduled < $1.scheduled }
            // The same direction as the one you tapped (the planner and the board can name it differently).
            var deps = line.filter { w.headsign.isEmpty || $0.headsign == w.headsign }
            if deps.isEmpty, let t = w.tripId, let hit = line.first(where: { $0.tripId == t }) { deps = line.filter { $0.headsign == hit.headsign } }
            if deps.isEmpty { deps = line }
            guard !deps.isEmpty else { continue }       // no answer just now: try again next time
            var notes: [String] = []
            let first = w.quiet
            var moveOn = w.tripId == nil
            if let t = w.tripId {
                if let d = deps.first(where: { $0.tripId == t }) {
                    if d.cancelled {
                        if !w.toldCancel { notes.append("The \(Fmt.hhmm(d.scheduled)) is cancelled."); w.toldCancel = true }
                        moveOn = true
                    } else if d.time < now.addingTimeInterval(-60) {
                        notes.append(d.live && d.delay <= -1 ? "The \(Fmt.hhmm(d.scheduled)) left \(-d.delay) min early, at \(Fmt.hhmm(d.time))." : "The \(Fmt.hhmm(d.scheduled)) has left.")
                        moveOn = true
                    } else if d.live {
                        let dl = d.delay, last = w.told ?? 0
                        if abs(dl - last) >= 2 || (dl <= -1 && last > -1) || (dl == 0 && abs(last) >= 2) {
                            notes.append(dl >= 1 ? "The \(Fmt.hhmm(d.scheduled)) is \(dl) min late: it leaves \(Fmt.hhmm(d.time))."
                                         : dl <= -1 ? "The \(Fmt.hhmm(d.scheduled)) leaves \(-dl) min early, at \(Fmt.hhmm(d.time))."
                                         : "The \(Fmt.hhmm(d.scheduled)) is on time again.")
                            w.told = dl
                        }
                        w.expected = d.time
                    }
                    w.status = Self.status(d)
                } else if (w.expected ?? now) < now.addingTimeInterval(-120) {
                    moveOn = true                          // it dropped off the board: it has gone
                }
            }
            if moveOn {
                if let n = deps.first(where: { !$0.cancelled && $0.time > now.addingTimeInterval(-60) }) {
                    w.tripId = n.tripId; w.planned = n.scheduled; w.expected = n.time; w.told = n.live ? n.delay : 0; w.toldCancel = false
                    w.status = Self.status(n)
                    if !first { notes.append("Next \(w.line): \(Self.status(n)).") }
                } else {
                    w.tripId = nil; w.status = "No more for now"
                    if !first { notes.append("No more \(w.line) buses found here for now.") }
                }
            }
            // Later ones that are cancelled, once each.
            for d in deps where d.cancelled && d.tripId != w.tripId && d.scheduled > now && d.scheduled.timeIntervalSince(now) < 2 * 3600 && !w.cancelledToo.contains(d.tripId) {
                notes.append("The \(Fmt.hhmm(d.scheduled)) is cancelled too.")
                w.cancelledToo.append(d.tripId)
            }
            if w.quiet { notes = notes.filter { $0.contains("cancelled") }; w.quiet = false }
            if let i = watches.firstIndex(where: { $0.id == id }) { watches[i] = w }
            if !notes.isEmpty {
                notify(title: "Bus \(w.line)\(w.headsign.isEmpty ? "" : " to \(w.headsign)") · \(Fmt.place(w.stopName))", body: notes.joined(separator: " "), id: "linewatch-\(w.id)", sound: true)
            }
        }
        persist()
    }

    /// "07:41 · 4 min late", "07:41 · on time", "07:41 · cancelled"
    static func status(_ d: BoardDeparture) -> String {
        if d.cancelled { return "\(Fmt.hhmm(d.scheduled)) · cancelled" }
        if !d.live { return "\(Fmt.hhmm(d.time)) · timetable time" }
        if d.delay >= 1 { return "\(Fmt.hhmm(d.time)) · \(d.delay) min late" }
        if d.delay <= -1 { return "\(Fmt.hhmm(d.time)) · \(-d.delay) min early" }
        return "\(Fmt.hhmm(d.time)) · on time"
    }

    private func notify(title: String, body: String, id: String, sound: Bool) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if sound { c.sound = .default; c.interruptionLevel = .timeSensitive }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id + "-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil)) { _ in }
    }
}
