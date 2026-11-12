import AudioToolbox
import Foundation
import UIKit
import UserNotifications

/// A train you want to hear about if its platform changes or it's cancelled.
struct TrainWatch: Codable, Identifiable, Equatable {
    var id: String { key }
    let key: String
    let code: String            // NS station code it leaves from
    let num: String
    let target: Date            // planned departure
    let label: String           // "08:02 Intercity to Breda"
    let from: String            // "Eindhoven"
    var track: String
    var cancelled: Bool
    let auto: Bool              // added by a planned trip
}

struct PlatformAlert: Identifiable, Equatable {
    let id = UUID()
    let cancelled: Bool
    let label: String
    let from: String
    let was: String
    let now: String
}

/// Watching: the train of your planned trip is watched by itself; tap a train in a list to watch it too.
@MainActor
final class WatchStore: ObservableObject {
    static let shared = WatchStore()

    @Published private(set) var watches: [TrainWatch]
    @Published private(set) var alert: PlatformAlert?
    private var queue: [PlatformAlert] = []
    private var lastCheck = Date.distantPast

    /// True while you're asleep on the bus or train: alerts wait until you're awake.
    var holdAlerts: () -> Bool = { false }
    /// The alarm sound, played short for an alert.
    var chime: () -> Void = {}

    private init() {
        let d = UserDefaults.standard.data(forKey: "watches")
        watches = d.flatMap { try? JSONDecoder().decode([TrainWatch].self, from: $0) } ?? []
    }

    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(watches), forKey: "watches") }

    static func key(code: String, ride: Ride) -> String { "\(code)|\(ride.num)|\(Int(ride.scheduledDeparture.timeIntervalSince1970))" }

    func isWatched(_ ride: Ride, from: Place) -> Bool {
        guard ride.isTrain, let c = NSStore.code(from) else { return false }
        let k = Self.key(code: c, ride: ride)
        return watches.contains { $0.key == k }
    }

    /// Tap on a train: watch it, or stop watching it. Returns whether it's watched now.
    @discardableResult
    func toggle(_ trip: DoorTrip, from: Place, to: Place) -> Bool {
        let r = trip.first
        guard r.isTrain, let c = NSStore.code(from) else { return false }
        let k = Self.key(code: c, ride: r)
        if watches.contains(where: { $0.key == k }) { remove(k); return false }
        add(trip, from: from, to: to, auto: false)
        return true
    }

    @discardableResult
    func add(_ trip: DoorTrip, from: Place, to: Place, auto: Bool) -> Bool {
        let r = trip.first
        guard r.isTrain, let c = NSStore.code(from) else { return false }
        let k = Self.key(code: c, ride: r)
        guard !watches.contains(where: { $0.key == k }) else { return false }
        let info = NSStore.shared.rail(r)
        let dest = r.headsign.isEmpty ? to.short : r.headsign
        watches.append(TrainWatch(key: k, code: c, num: r.num, target: r.scheduledDeparture,
                                  label: "\(Fmt.hhmm(r.scheduledDeparture)) \(r.name.isEmpty ? "train" : r.name) to \(dest)", from: from.short,
                                  track: info?.track ?? r.platform ?? "", cancelled: info?.cancelled ?? r.cancelled, auto: auto))
        persist()
        if auto == false { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        return true
    }

    func remove(_ key: String) { watches.removeAll { $0.key == key }; persist() }
    func removeAuto() { watches.removeAll { $0.auto }; persist() }
    func reset() { watches = []; queue = []; alert = nil; persist() }

    /// Looks at the NS boards for the trains you watch (at most once a minute).
    func check(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastCheck) >= 55 else { return }
        lastCheck = Date()
        let now = Date()
        let before = watches.count
        watches.removeAll { now > $0.target.addingTimeInterval(3 * 3600) }
        if watches.count != before { persist() }
        let soon = watches.indices.filter { watches[$0].target.timeIntervalSince(now) < 3 * 3600 }
        guard !soon.isEmpty else { return }
        for c in Set(soon.map { watches[$0].code }) { await NSStore.shared.board(c) }
        var changed = false
        for i in soon where i < watches.count {
            let w = watches[i]
            guard let m = NSStore.shared.match(w.code, num: w.num, planned: w.target) else { continue }
            if let p = m.planned, now > p.addingTimeInterval(20 * 60), !m.cancelled { continue }
            if m.cancelled && !w.cancelled {
                watches[i].cancelled = true; changed = true
                queue.append(PlatformAlert(cancelled: true, label: w.label, from: w.from, was: "", now: ""))
            }
            let tr = m.actualTrack
            if !tr.isEmpty && !w.track.isEmpty && tr != w.track {
                queue.append(PlatformAlert(cancelled: false, label: w.label, from: w.from, was: w.track, now: tr))
                watches[i].track = tr; changed = true
            } else if !tr.isEmpty && w.track.isEmpty {
                watches[i].track = tr; changed = true
            }
        }
        if changed { persist() }
        showNext()
    }

    /// Shows the next alert, unless you're asleep on a trip (then it waits until you're awake).
    func showNext() {
        guard alert == nil, !queue.isEmpty, !holdAlerts() else { return }
        let a = queue.removeFirst()
        alert = a
        chime()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        let c = UNMutableNotificationContent()
        c.title = a.cancelled ? "Train cancelled" : "Platform \(a.now)"
        c.body = a.cancelled ? "Your \(a.label) from \(a.from) has been cancelled."
                             : "Your \(a.label) now leaves \(a.from) from platform \(a.now) instead of \(a.was)."
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "platform-\(a.id)", content: c, trigger: nil)) { _ in }
    }

    func dismiss() {
        alert = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showNext() }
    }
}
