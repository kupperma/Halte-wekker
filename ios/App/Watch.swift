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
    var told: Int? = nil        // the delay you were last told about
    /// (0.42.4) One of the trains of the trip you're on or watching for (`WatchStore.setRideWatches`), not the plan's.
    var ride: Bool? = nil
}

struct PlatformAlert: Identifiable, Equatable {
    let id = UUID()
    let cancelled: Bool
    let label: String
    let from: String
    let was: String
    let now: String
    /// (0.42.4) Its notification went already (quietly, while you were asleep on the ride): the card and the chime now.
    var posted = false
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
        guard ride.isTrain, let c = NSStore.railCode(from) else { return false }
        let k = Self.key(code: c, ride: ride)
        return watches.contains { $0.key == k }
    }

    /// Tap on a train: watch it, or stop watching it. Returns whether it's watched now.
    @discardableResult
    func toggle(_ trip: DoorTrip, from: Place, to: Place) -> Bool {
        let r = trip.first
        guard r.isTrain, let c = NSStore.railCode(from) else { return false }
        let k = Self.key(code: c, ride: r)
        if watches.contains(where: { $0.key == k }) { remove(k); return false }
        add(trip, from: from, to: to, auto: false)
        return true
    }

    /// Watch the trip's first ride (a train), and (0.42.4) its later trains too (each from its own station).
    @discardableResult
    func add(_ trip: DoorTrip, from: Place, to: Place, auto: Bool) -> Bool {
        let r = trip.first
        guard r.isTrain, let c = NSStore.railCode(from) else { return false }
        let k = Self.key(code: c, ride: r)
        guard !watches.contains(where: { $0.key == k }) else { return false }
        let dest = r.headsign.isEmpty ? to.short : r.headsign
        append(r, code: c, from: from.short, to: dest, auto: auto)
        for later in trip.rides.dropFirst() where later.isTrain {
            guard let lc = NSStore.railCode(stopId: later.fromId, name: later.fromStop, lat: later.fromLat, lon: later.fromLon) else { continue }
            let lk = Self.key(code: lc, ride: later)
            guard !watches.contains(where: { $0.key == lk }) else { continue }
            let ld: String = later.headsign.isEmpty ? Fmt.place(later.toStop) : later.headsign
            append(later, code: lc, from: Fmt.place(later.fromStop), to: ld, auto: auto)
        }
        persist()
        if auto == false { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        return true
    }

    /// (0.42.4) A new watch starts from the plan's platform (`PlatformWatch.seed`): a change against it is told, also
    /// one made before NS's first answer. (Before, an auto watch started with none and the first answer filled it in.)
    private func append(_ r: Ride, code c: String, from: String, to dest: String, auto: Bool, ride: Bool? = nil) {
        let info = NSStore.shared.rail(r)
        let track: String = PlatformWatch.seed(planned: r.plannedPlatform ?? r.platform, live: info?.track)
        watches.append(TrainWatch(key: Self.key(code: c, ride: r), code: c, num: r.num, target: r.scheduledDeparture,
                                  label: "\(Fmt.hhmm(r.scheduledDeparture)) \(r.name.isEmpty ? "train" : r.name) to \(dest)", from: from,
                                  track: track, cancelled: info?.cancelled ?? r.cancelled, auto: auto, ride: ride))
    }

    /// (0.42.4) One train of the trip you're on (or that Fastest trip watches for you).
    struct RideWatch: Equatable {
        let code: String            // the NS station it leaves from
        let num: String
        let planned: Date           // its planned departure
        let label: String           // "08:02 Intercity to Breda"
        let from: String            // "Eindhoven"
        let platform: String?       // the plan's platform
        var key: String { "\(code)|\(num)|\(Int(planned.timeIntervalSince1970))" }
    }

    /// (0.42.4) The trains of the trip you're on, or the one Fastest trip watches for you: every train, not only a first
    /// ride (`PlatformWatch.toWatch`). Ones already watched keep what they know; the trip's others go.
    func setRideWatches(_ list: [RideWatch]) {
        let keys = Set(list.map(\.key))
        var w: [TrainWatch] = watches.filter { $0.ride != true || keys.contains($0.key) }
        for r in list where !w.contains(where: { $0.key == r.key }) {
            let track: String = PlatformWatch.seed(planned: r.platform, live: nil)
            w.append(TrainWatch(key: r.key, code: r.code, num: r.num, target: r.planned, label: r.label, from: r.from,
                                track: track, cancelled: false, auto: true, ride: true))
        }
        guard w != watches else { return }
        watches = w
        persist()
    }

    /// (0.42.4) The trains of `t` to watch: each train ride from an NS station, leaving within 3 hours.
    static func rideWatches(_ t: DoorTrip, now: Date = Date()) -> [RideWatch] {
        let rides: [Ride] = t.rides
        let legs: [PlatformWatch.Leg] = rides.map { r in
            PlatformWatch.Leg(train: r.isTrain, num: r.num, code: r.isTrain ? NSStore.railCode(stopId: r.fromId, name: r.fromStop, lat: r.fromLat, lon: r.fromLon) : nil,
                              planned: r.scheduledDeparture)
        }
        return PlatformWatch.toWatch(legs, now: now).compactMap { k -> RideWatch? in
            guard let c = legs[k].code else { return nil }
            let r: Ride = rides[k]
            let to: String = r.headsign.isEmpty ? Fmt.place(r.toStop) : r.headsign
            let label: String = "\(Fmt.hhmm(r.scheduledDeparture)) \(r.name.isEmpty ? "train" : r.name) to \(to)"
            return RideWatch(code: c, num: r.num, planned: r.scheduledDeparture, label: label, from: Fmt.place(r.fromStop),
                             platform: r.plannedPlatform ?? r.platform)
        }
    }

    /// (0.42.4) The platform NS gives now for a watched train (by its number, else its planned time), for the change
    /// card and the lock screen. Nil: not watched, or none known.
    func liveTrack(num: String, planned: Date) -> String? {
        let w: TrainWatch? = watches.first { x in
            !num.isEmpty && !x.num.isEmpty ? x.num == num : abs(x.target.timeIntervalSince(planned)) < 60
        }
        guard let t = w?.track, !t.isEmpty else { return nil }
        return t
    }

    /// Told when a watched train's platform changed or it was cancelled (the ride's change card follows at once).
    var onChange: () -> Void = {}

    func remove(_ key: String) { watches.removeAll { $0.key == key }; persist() }
    /// You're on this train: stop watching it.
    func boarded(num: String) { guard !num.isEmpty else { return }; watches.removeAll { $0.num == num }; persist() }
    func removeAuto() { watches.removeAll { $0.auto && $0.ride != true }; persist() }
    func reset() { watches = []; queue = []; alert = nil; persist() }

    /// Looks at the NS boards for the trains you watch (at most once a minute).
    func check(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastCheck) >= 55 else { return }
        lastCheck = Date()
        let now = Date()
        var told = false
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
                watches[i].cancelled = true; changed = true; told = true
                queue.append(PlatformAlert(cancelled: true, label: w.label, from: w.from, was: "", now: ""))
                FieldLog.shared.add(.ride, PlatformWatch.logLine(label: w.label, from: w.from, was: "", now: "", cancelled: true))
            }
            // Running late: tell you when it changes by 2 min or more (from 3 min late).
            let dl = m.delay, last = watches[i].told ?? 0
            if !m.cancelled, now < (m.actual ?? w.target), (dl >= 3 && abs(dl - last) >= 2) || (dl < 3 && last >= 3) {
                watches[i].told = dl; changed = true
                let c = UNMutableNotificationContent()
                c.title = dl >= 3 ? "\(w.label): \(dl) min late" : "\(w.label): back on time"
                c.body = dl >= 3 ? "It now leaves \(w.from) at \(Fmt.hhmm(m.actual ?? w.target))\(w.track.isEmpty ? "" : ", platform \(w.track)")." : "It leaves \(w.from) on time again."
                c.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "delay-\(w.key)-\(dl)", content: c, trigger: nil)) { _ in }
            }
            // (0.42.4) against the plan's platform, or NS's own planned one when it had none (`PlatformWatch.change`)
            switch PlatformWatch.change(track: w.track, live: m.actualTrack, nsPlanned: m.plannedTrack) {
            case .none: break
            case .fill(let tr):
                watches[i].track = tr; changed = true
            case .moved(let was, let tr):
                queue.append(PlatformAlert(cancelled: false, label: w.label, from: w.from, was: was, now: tr))
                watches[i].track = tr; changed = true; told = true
                FieldLog.shared.add(.ride, PlatformWatch.logLine(label: w.label, from: w.from, was: was, now: tr, cancelled: false))
            }
        }
        if changed { persist() }
        // asleep on the ride: the notification now, quietly; the card and the chime once you're awake
        if PlatformWatch.delivery(asleep: holdAlerts()) == .quietNowChimeLater {
            for k in queue.indices where !queue[k].posted {
                post(queue[k], quiet: true)
                queue[k].posted = true
            }
        }
        if told { onChange() }
        showNext()
    }

    /// Shows the next alert, unless you're asleep on a trip (then it waits until you're awake).
    func showNext() {
        guard alert == nil, !queue.isEmpty, !holdAlerts() else { return }
        let a = queue.removeFirst()
        alert = a
        chime()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        if !a.posted { post(a, quiet: false) }
    }

    /// The notification of an alert; `quiet`: no sound (asleep on the ride), still time sensitive, so it's on the lock
    /// screen and the watch at once.
    private func post(_ a: PlatformAlert, quiet: Bool) {
        let c = UNMutableNotificationContent()
        c.title = a.cancelled ? "Train cancelled" : "Platform \(a.now)"
        c.body = a.cancelled ? "Your \(a.label) from \(a.from) has been cancelled."
                             : "Your \(a.label) now leaves \(a.from) from platform \(a.now) instead of \(a.was)."
        if !quiet { c.sound = .default }
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "platform-\(a.id)", content: c, trigger: nil)) { _ in }
    }

    func dismiss() {
        alert = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showNext() }
    }
}
