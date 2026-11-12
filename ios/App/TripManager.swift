import ActivityKit
import CoreLocation
import Foundation
import UserNotifications

/// The bus or train you're on, once it's recognised.
struct Vehicle: Equatable {
    let tripId: String
    let line: String
    let isTrain: Bool
    var title: String { isTrain ? (line == "IC" ? "Intercity" : line == "SPR" ? "Sprinter" : line) : "Bus \(line)" }
}

/// Runs a trip: follows GPS (also with the phone locked), rings before each stop with an announcement,
/// recognises the vehicle you're on, keeps the arrival time up to date and drives the Live Activity.
/// With "Start trips by itself" on, it watches your stations and starts a trip when you leave on a bus or train.
@MainActor
final class TripManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Phase: Equatable { case idle, sleeping, awake, alarm(approach: Bool), transfer, finished }

    /// A direction you picked yourself sticks for 3 hours, then it follows the clock again.
    @Published private(set) var direction: Direction = TripManager.savedDirection()
    @Published var toast: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var route: RoutePlan?
    @Published private(set) var legs: [Leg] = []
    @Published private(set) var index = 0
    @Published private(set) var distance: Double?
    @Published private(set) var accuracy: Double?
    @Published private(set) var arrival: Date?
    @Published private(set) var next: Ride?
    @Published private(set) var vehicle: Vehicle?
    @Published private(set) var legArrival: Date?
    @Published private(set) var legFrom: Date?          // when this bus or train left (or should have)
    @Published private(set) var legTo: Date?            // when it reaches your stop: live, or from the timetable
    @Published private(set) var locationDenied = false
    @Published private(set) var autoStarted = false
    @Published var arrivedAt: String?

    @Published var busKm: Double = UserDefaults.standard.object(forKey: "busKm") as? Double ?? 2 { didSet { UserDefaults.standard.set(busKm, forKey: "busKm") } }
    @Published var trainKm: Double = UserDefaults.standard.object(forKey: "trainKm") as? Double ?? 5 { didSet { UserDefaults.standard.set(trainKm, forKey: "trainKm") } }
    @Published var ringAtStop: Bool = UserDefaults.standard.object(forKey: "ringAtStop") as? Bool ?? true { didSet { UserDefaults.standard.set(ringAtStop, forKey: "ringAtStop") } }
    @Published var announce: Bool = UserDefaults.standard.object(forKey: "announce") as? Bool ?? true { didSet { UserDefaults.standard.set(announce, forKey: "announce") } }
    @Published var movingStation: Bool = UserDefaults.standard.object(forKey: "movingStation") as? Bool ?? true { didSet { UserDefaults.standard.set(movingStation, forKey: "movingStation") } }
    @Published var autoStart: Bool = UserDefaults.standard.object(forKey: "autoStart") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart"); updateWatching() }
    }
    @Published var soundKind: AlarmSound.Kind { didSet { sound.kind = soundKind } }
    @Published var pauseMusic: Bool = UserDefaults.standard.bool(forKey: "pauseMusic") {
        didSet { UserDefaults.standard.set(pauseMusic, forKey: "pauseMusic"); sound.pauseMusic = pauseMusic }
    }
    @Published var autoHome: Bool = UserDefaults.standard.object(forKey: "autoHome") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoHome, forKey: "autoHome"); updateWatching() }
    }
    /// Wake distance per stop, once you've picked one ("bus:ht" → 2.5).
    @Published private(set) var kmMem: [String: Double] = UserDefaults.standard.dictionary(forKey: "kmMem") as? [String: Double] ?? [:]
    @Published private(set) var backupAt: Date?
    @Published private(set) var lastScore: ScoreResult?
    @Published private(set) var always = false

    let sound = AlarmSound()
    let music = NowPlaying()
    private let location = CLLocationManager()
    private var activity: Activity<TripAttributes>?
    private var legStart = Date()
    private var forceArrival = false
    private var lastEta = Date.distantPast
    private var lastActivity = Date.distantPast
    private var lastActivityKey = ""
    private var samples: [CLLocation] = []
    private var detectTask: Task<Void, Never>?
    private var watchLeft: (place: Place, at: Date)?      // auto-start: which station you just left
    private var maxDistance: Double?                      // furthest from the stop on this leg, for progress without times
    private var tripStart: Date?
    private var startedAtLeg = 0
    private var backupTask: Task<Void, Never>?
    private var lastWatchCheck = Date.distantPast
    private let arriveM = 450.0

    var leg: Leg? { index < legs.count ? legs[index] : nil }
    var wakeKm: Double { leg.map(km(for:)) ?? busKm }
    var finalName: String { route?.single != nil ? (leg?.to.short ?? "") : direction == .home ? "Home" : "Breda" }
    func km(for l: Leg) -> Double { kmMem["\(l.mode.rawValue):\(l.to.key)"] ?? (l.mode == .bus ? busKm : trainKm) }
    var here: CLLocationCoordinate2D? { location.location?.coordinate }

    private static func savedDirection() -> Direction {
        let d = UserDefaults.standard
        if let at = d.object(forKey: "dirAt") as? Date, Date().timeIntervalSince(at) < 3 * 3600, let raw = d.string(forKey: "dir"), let dir = Direction(rawValue: raw) { return dir }
        return Calendar.current.component(.hour, from: Date()) < 12 ? .toSchool : .home
    }
    /// You tapped the big button.
    func pick(_ d: Direction) {
        direction = d
        UserDefaults.standard.set(d.rawValue, forKey: "dir"); UserDefaults.standard.set(Date(), forKey: "dirAt")
    }
    /// After 3 hours the direction follows the clock again.
    private func followClock() {
        guard !isRiding else { return }
        let d = Self.savedDirection()
        if d != direction { direction = d }
    }

    /// Reaching BUas switches to going home, once a day.
    func maybeAutoHome(_ l: CLLocation) {
        let today = Fmt.ymd.string(from: Date())
        guard autoHome, direction == .toSchool, !isRiding, UserDefaults.standard.string(forKey: "autoHomeDay") != today, NearMe.atSchool(l) else { return }
        UserDefaults.standard.set(today, forKey: "autoHomeDay")
        pick(.home)
        toast = "You’re at BUas, so it switched to Home. Tap the big button to switch back."
    }
    var isRiding: Bool { phase != .idle }

    override init() {
        soundKind = AlarmSound.Kind(rawValue: UserDefaults.standard.string(forKey: "sound") ?? "") ?? .steam
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 25
        location.activityType = .otherNavigation
        location.pausesLocationUpdatesAutomatically = false
        always = location.authorizationStatus == .authorizedAlways
        music.onChange = { [weak self] in self?.pushActivity(force: true) }
        sound.pauseMusic = pauseMusic
        WatchStore.shared.holdAlerts = { [weak self] in self?.phase == .sleeping }
        WatchStore.shared.chime = { [weak self] in
            guard let self else { return }
            self.sound.play(preview: self.soundKind)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                guard let self, WatchStore.shared.alert != nil else { return }
                self.sound.play(preview: self.soundKind)
            }
        }
        updateWatching()
    }

    // MARK: trip flow

    func start(_ r: RoutePlan, at legIndex: Int = 0, vehicle v: Vehicle? = nil, auto: Bool = false, kms: [Double]? = nil, backup: Int = 0) {
        route = r
        legs = r.legs(direction)
        index = min(legIndex, legs.count - 1)
        autoStarted = auto
        if let kms {
            for (l, k) in zip(legs, kms) { kmMem["\(l.mode.rawValue):\(l.to.key)"] = k }
            UserDefaults.standard.set(kmMem, forKey: "kmMem")
        }
        tripStart = Date(); startedAtLeg = index; lastScore = nil
        setBackup(backup)
        sound.startTrip()
        music.start()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        beginLeg(vehicle: v)
        startActivity()
    }

    private func beginLeg(vehicle v: Vehicle? = nil) {
        phase = .sleeping
        distance = nil; forceArrival = false; maxDistance = nil
        legStart = Date()
        arrival = nil; next = nil; legArrival = nil; legFrom = nil; legTo = nil
        vehicle = v
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        if v != nil { Task { await self.vehicleFound(v!) } } else { startDetecting() }
        refreshEta(force: true)
    }

    func stopAlarm() {
        sound.stop()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        guard case .alarm(let approach) = phase else { return }
        if approach && (ringAtStop || forceArrival) { phase = .awake; pushActivity(force: true); WatchStore.shared.showNext() } else { legDone() }
    }

    /// You're at the end of a leg (by GPS, by the alarm, or "I'm off").
    func legDone() {
        sound.stop()
        setBackup(0)
        arrivedAt = leg?.to.short
        if index + 1 < legs.count {
            phase = .transfer
            // With auto-start on, keep looking for the next bus or train so the next leg starts by itself.
            if autoStart { vehicle = nil; startDetecting(forNextLeg: true) } else { location.stopUpdatingLocation() }
        } else {
            phase = .finished
            location.stopUpdatingLocation()
            if let r = route, r.single == nil, startedAtLeg == 0, let s = tripStart {
                lastScore = ScoreBook.shared.log(route: r, home: direction == .home, start: s)
            }
        }
        pushActivity(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { WatchStore.shared.showNext() }
    }

    func nextLeg(vehicle v: Vehicle? = nil, backup: Int = 0) {
        guard index + 1 < legs.count else { return }
        index += 1
        sound.startTrip()
        setBackup(backup)
        beginLeg(vehicle: v)
        pushActivity(force: true)
    }

    func endTrip() {
        detectTask?.cancel(); detectTask = nil
        setBackup(0)
        sound.endTrip()
        music.stop()
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        phase = .idle
        route = nil; legs = []; distance = nil; arrival = nil; next = nil; vehicle = nil; legArrival = nil; arrivedAt = nil
        legFrom = nil; legTo = nil; maxDistance = nil
        let a = activity; activity = nil
        Task { await a?.end(nil, dismissalPolicy: .immediate) }
    }

    /// When the app comes back to the screen: start the Live Activity if a trip started by itself in the background.
    func appBecameActive() {
        always = location.authorizationStatus == .authorizedAlways
        followClock()
        if isRiding && activity == nil { startActivity() }
    }

    // MARK: location

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.handle(loc) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.locationDenied = (s == .denied || s == .restricted)
            self.always = s == .authorizedAlways
            self.updateWatching()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in self.leftRegion(region.identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == "school" else { return }
        Task { @MainActor in self.maybeAutoHome(CLLocation(latitude: Place.buas.coordinate.latitude, longitude: Place.buas.coordinate.longitude)) }
    }

    private func handle(_ loc: CLLocation) {
        samples.append(loc)
        samples.removeAll { $0.timestamp < Date().addingTimeInterval(-240) }
        guard let leg, phase == .sleeping || phase == .awake else { return }
        let d = loc.distance(from: CLLocation(latitude: leg.to.coordinate.latitude, longitude: leg.to.coordinate.longitude))
        distance = d
        if loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 250 { maxDistance = max(maxDistance ?? 0, d) }
        accuracy = loc.horizontalAccuracy
        let good = loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 250
        if phase == .sleeping && good && d <= wakeKm * 1000 {
            if Date().timeIntervalSince(legStart) < 20 { phase = .awake; forceArrival = true } else { ring(approach: true) }
        } else if phase == .awake && d <= arriveM && loc.horizontalAccuracy <= 600 {
            if ringAtStop || forceArrival { ring(approach: false) } else { legDone() }
        }
        refreshEta(force: false)
        pushActivity(force: false)
        if Date().timeIntervalSince(lastWatchCheck) > 60 { lastWatchCheck = Date(); Task { await WatchStore.shared.check() } }
    }

    // MARK: alarm + announcement

    private func announcement(approach: Bool) -> String? {
        guard announce, let leg else { return nil }
        let place = leg.mode == .train && !leg.to.spoken.contains("station") && !leg.to.spoken.contains("Central") ? "\(leg.to.spoken) station" : leg.to.spoken
        let veh = leg.mode == .train ? "train" : "bus"
        return approach ? "Attention please. We are now approaching \(place). Please get ready to leave the \(veh)."
                        : "Arriving at \(place). This is your stop. Please leave the \(veh) here."
    }

    private func ring(approach: Bool) {
        setBackup(0)
        phase = .alarm(approach: approach)
        sound.ring(announcement: announcement(approach: approach))
        let c = UNMutableNotificationContent()
        c.title = approach ? "Wake up" : "Get off now"
        c.body = approach ? "\(leg?.to.short ?? "Your stop") in about \(Fmt.distance(distance ?? 0))." : "You’re at \(leg?.to.short ?? "your stop")."
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "alarm", content: c, trigger: nil))
        pushActivity(force: true)
    }

    func testAlarm() {
        let text = announce ? "This is a test. Attention please. We are now arriving at Breda station." : nil
        sound.ring(announcement: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in if self?.phase == .idle { self?.sound.stop() } }
    }

    // MARK: backup alarm

    /// Rings after this many minutes even if GPS drops out (0 = off).
    private func setBackup(_ minutes: Int) {
        backupTask?.cancel(); backupTask = nil; backupAt = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["backup"])
        guard minutes > 0 else { return }
        backupAt = Date().addingTimeInterval(Double(minutes) * 60)
        backupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard let self, !Task.isCancelled, self.phase == .sleeping else { return }
            self.ring(approach: true)
        }
        // A notification as well, in case iOS stops the app.
        let c = UNMutableNotificationContent()
        c.title = "Wake up"
        c.body = "Your backup alarm: \(leg?.to.short ?? "your stop") should be close."
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "backup", content: c,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(minutes) * 60, repeats: false))) { _ in }
    }

    // MARK: which bus or train you're on

    private func startDetecting(forNextLeg: Bool = false) {
        detectTask?.cancel()
        detectTask = Task { [weak self] in
            var lastBest: String?
            for _ in 0..<14 {                       // about 9 minutes, then give up
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.vehicle != nil && !forNextLeg { return }
                guard let v = await self.matchVehicle(mode: forNextLeg ? self.legs[safe: self.index + 1]?.mode : self.leg?.mode) else { lastBest = nil; continue }
                if v.tripId == lastBest {
                    if forNextLeg { if self.phase == .transfer { self.nextLeg(vehicle: v) }; return }
                    await self.vehicleFound(v); return
                }
                lastBest = v.tripId
            }
        }
    }

    /// Compares where you've been in the last minutes with where every nearby bus or train should have been.
    private func matchVehicle(mode: Mode?) async -> Vehicle? {
        let recent = samples.filter { $0.timestamp > Date().addingTimeInterval(-150) && $0.horizontalAccuracy < 150 }
        guard let last = recent.last, recent.count >= 2 else { return nil }
        let speed = max(last.speed, recent.first.map { last.distance(from: $0) / max(1, last.timestamp.timeIntervalSince($0.timestamp)) } ?? 0)
        guard speed > 3 else { return nil }                     // not moving: not on board yet
        let segs = await Transit.vehicles(near: last.coordinate)
        var best: (Vehicle, Double)?
        for s in segs {
            if let mode, (mode == .train) != s.isTrain { continue }
            var total = 0.0, n = 0.0
            for p in recent.suffix(4) {
                guard let c = s.position(at: p.timestamp) else { continue }
                total += p.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)); n += 1
            }
            guard n >= 2 else { continue }
            let avg = total / n
            if avg < (s.isTrain ? 600 : 400), best == nil || avg < best!.1 { best = (Vehicle(tripId: s.tripId, line: s.isTrain ? Transit.trainLabel(s.line) : s.line, isTrain: s.isTrain), avg) }
        }
        return best?.0
    }

    /// Found it: use that vehicle's own live arrival at your stop.
    private func vehicleFound(_ v: Vehicle) async {
        vehicle = v
        guard let leg else { return }
        let stops = await Transit.tripStops(v.tripId)
        let target = CLLocation(latitude: leg.to.coordinate.latitude, longitude: leg.to.coordinate.longitude)
        if let s = stops.filter({ $0.arrival != nil }).min(by: {
            target.distance(from: CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) <
            target.distance(from: CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude)) }),
           target.distance(from: CLLocation(latitude: s.coordinate.latitude, longitude: s.coordinate.longitude)) < 1500 {
            legArrival = s.arrival
            legTo = s.arrival
            let from = CLLocation(latitude: leg.from.coordinate.latitude, longitude: leg.from.coordinate.longitude)
            if let b = stops.filter({ $0.arrival != nil }).min(by: {
                from.distance(from: CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) <
                from.distance(from: CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude)) }),
               from.distance(from: CLLocation(latitude: b.coordinate.latitude, longitude: b.coordinate.longitude)) < 1500,
               let dep = b.arrival, dep < s.arrival! {
                legFrom = dep
            }
        }
        refreshEta(force: true)
        pushActivity(force: true)
    }

    // MARK: starting by itself

    /// Watches your stations with region monitoring (cheap): full GPS only switches on once you leave one.
    private func updateWatching() {
        for r in location.monitoredRegions { location.stopMonitoring(for: r) }
        guard autoStart || autoHome else { return }
        if location.authorizationStatus != .authorizedAlways {
            if autoStart && location.authorizationStatus == .authorizedWhenInUse { location.requestAlwaysAuthorization() }
            return
        }
        if autoHome {
            let r = CLCircularRegion(center: Place.buas.coordinate, radius: NearMe.schoolRadius, identifier: "school")
            r.notifyOnEntry = true; r.notifyOnExit = false
            location.startMonitoring(for: r)
        }
        guard autoStart else { return }
        for p in Place.all where p != .buas {
            let r = CLCircularRegion(center: p.coordinate, radius: p == .veghel ? 350 : 300, identifier: p.key)
            r.notifyOnExit = true; r.notifyOnEntry = false
            location.startMonitoring(for: r)
        }
    }

    func askForAlways() { location.requestAlwaysAuthorization() }

    private func leftRegion(_ key: String) {
        guard autoStart, phase == .idle, let place = Place.all.first(where: { $0.key == key }) else { return }
        watchLeft = (place, Date())
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        detectTask?.cancel()
        detectTask = Task { [weak self] in
            var lastBest: String?
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                guard let self, !Task.isCancelled, self.phase == .idle else { return }
                guard let v = await self.matchVehicle(mode: nil) else { lastBest = nil; continue }
                if v.tripId == lastBest, await self.autoStartTrip(from: place, on: v) { return }
                lastBest = v.tripId
            }
            guard let self, self.phase == .idle else { return }
            self.location.stopUpdatingLocation()            // nothing found: back to cheap watching
            self.location.allowsBackgroundLocationUpdates = false
        }
    }

    /// Works out which of your routes this bus or train belongs to, then starts the trip at that leg.
    private func autoStartTrip(from place: Place, on v: Vehicle) async -> Bool {
        let names = await Transit.tripStops(v.tripId).map { $0.name.lowercased() }
        func goes(_ p: Place) -> Bool {
            let w = p == .denBosch ? "hertogenbosch" : p == .eindhoven ? "eindhoven" : p == .breda ? "breda" : "veghel"
            return names.contains { $0.contains(w) }
        }
        var pick: (Direction, RoutePlan, Int)?
        switch place {
        case .veghel where !v.isTrain:
            if goes(.denBosch) { pick = (.toSchool, RoutePlan.via(.denBosch)!, 0) } else if goes(.eindhoven) { pick = (.toSchool, RoutePlan.via(.eindhoven)!, 0) }
        case .breda where v.isTrain:
            if goes(.denBosch) { pick = (.home, RoutePlan.via(.denBosch)!, 0) } else if goes(.eindhoven) { pick = (.home, RoutePlan.via(.eindhoven)!, 0) }
        case .denBosch, .eindhoven:
            if v.isTrain && goes(.breda) { pick = (.toSchool, RoutePlan.via(place)!, 1) }
            else if !v.isTrain && goes(.veghel) { pick = (.home, RoutePlan.via(place)!, 1) }
        default: break
        }
        guard let chosen = pick else { return false }
        let (dir, r, i) = chosen
        direction = dir
        start(r, at: i, vehicle: v, auto: true)
        let c = UNMutableNotificationContent()
        c.title = "Trip started by itself"
        c.body = "\(v.title) to \(legs[safe: i]?.to.short ?? "your stop"). It rings \(Fmt.distance(wakeKm * 1000)) before your stop."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "autostart", content: c, trigger: nil)) { _ in }
        return true
    }

    // MARK: expected arrival

    private func refreshEta(force: Bool) {
        guard force || Date().timeIntervalSince(lastEta) > 120 else { return }
        lastEta = Date()
        let legs = self.legs, i = index, start = legStart, known = legArrival
        Task {
            guard i < legs.count else { return }
            var t: Date
            var window: (Date, Date)?
            if let known { t = known } else {
                // Not recognised yet: the ride that left closest to when you started this leg.
                let l = legs[i]
                let opts = await Transit.plan(from: l.from, to: l.to, modes: l.mode.transitModes, at: start.addingTimeInterval(-40 * 60), count: 8, maxTransfers: l.mode == .train ? 1 : 0)
                    .filter { abs($0.first.departure.timeIntervalSince(start)) < 40 * 60 }
                guard let on = opts.min(by: { abs($0.first.departure.timeIntervalSince(start)) < abs($1.first.departure.timeIntervalSince(start)) }) else { return }
                t = on.rides.last!.arrival
                window = (on.first.departure, t)
            }
            var firstNext: Ride?
            for k in (i + 1)..<max(i + 1, legs.count) {
                let l = legs[k]
                let opts = await Transit.plan(from: l.from, to: l.to, modes: l.mode.transitModes, at: t.addingTimeInterval(120), count: 4, maxTransfers: l.mode == .train ? 1 : 0)
                    .filter { $0.start >= t.addingTimeInterval(60) }
                guard let best = opts.min(by: { ($0.rides.last!.arrival, $0.first.departure) < ($1.rides.last!.arrival, $1.first.departure) }) else { return }
                if firstNext == nil { firstNext = best.first }
                t = best.rides.last!.arrival
            }
            await MainActor.run {
                guard self.index == i, self.phase != .idle else { return }
                self.arrival = t; self.next = firstNext
                if let window, self.legArrival == nil { self.legFrom = window.0; self.legTo = window.1 }
                self.pushActivity(force: true)
            }
        }
    }

    var nextText: String? {
        guard let n = next, index + 1 < legs.count else { return nil }
        return "Then \(n.isTrain ? n.name : "bus \(n.line)") at \(Fmt.hhmm(n.departure)) from \(legs[index + 1].from.short)"
    }

    /// How far along this leg you are, 0…1: by the clock when the times are known, else by distance.
    func progress(at now: Date = Date()) -> Double {
        switch phase {
        case .transfer, .finished: return 1
        case .idle: return 0
        default: break
        }
        var byDistance: Double?
        if let d = distance, let m = maxDistance, m > 200 { byDistance = 1 - d / m }
        if let a = legFrom, let b = legTo, b.timeIntervalSince(a) > 60 {
            let t = now.timeIntervalSince(a) / b.timeIntervalSince(a)
            // a late vehicle: don't let the clock run ahead of where you really are
            if let bd = byDistance, t > bd + 0.25 { return min(1, max(0, bd)) }
            return min(0.98, max(0, t))
        }
        return min(1, max(0, byDistance ?? 0))
    }

    private var kicker: String {
        switch phase {
        case .transfer: return "CHANGE HERE"
        case .finished: return "YOU’RE THERE"
        case .alarm(let a): return a ? "WAKE UP" : "GET OFF NOW"
        case .awake: return "GET READY"
        default: return "NOW RIDING"
        }
    }

    // MARK: Live Activity

    private var state: TripAttributes.ContentState {
        let title: String
        switch phase {
        case .transfer: title = "Change at \(leg?.to.short ?? "")"
        case .finished: title = "You’re there"
        case .alarm(let a): title = a ? "Wake up: \(leg?.to.short ?? "")" : "Get off now"
        default: title = vehicle.map { "\($0.title) to \(leg?.to.short ?? "")" } ?? leg?.title ?? ""
        }
        var awake = false
        if case .alarm = phase { awake = true } else if phase == .awake { awake = true }
        let song = music.song
        return .init(legTitle: title, isTrain: leg?.mode == .train, distanceText: distance.map { Fmt.distance($0) } ?? "–",
                     arrival: arrival, finalName: finalName, nextText: nextText, awake: awake, goingHome: direction == .home,
                     kicker: kicker, stopName: leg?.to.spoken ?? "", progress: (progress() * 100).rounded() / 100,
                     legFrom: legFrom, legTo: legTo, song: song?.title, artist: song?.artist, songPlaying: song?.playing ?? false,
                     musicApp: song?.app)
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let route, activity == nil else { return }
        activity = try? Activity.request(attributes: TripAttributes(routeName: route.name), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
    }

    private func pushActivity(force: Bool) {
        guard let activity else { return }
        let s = state
        let key = "\(s.legTitle)|\(s.distanceText)|\(s.arrival?.timeIntervalSince1970 ?? 0)|\(s.awake)|\(Int(s.progress * 50))|\(s.song ?? "")|\(s.songPlaying)"
        guard force || (key != lastActivityKey && Date().timeIntervalSince(lastActivity) > 8) else { return }
        lastActivity = Date(); lastActivityKey = key
        Task { await activity.update(ActivityContent(state: s, staleDate: nil)) }
    }

    /// Settings → Reset everything.
    func resetAll() {
        if isRiding { endTrip() }
        let d = UserDefaults.standard
        for k in ["busKm", "trainKm", "ringAtStop", "announce", "movingStation", "autoStart", "sound", "pauseMusic", "autoHome", "kmMem", "dir", "dirAt", "autoHomeDay"] { d.removeObject(forKey: k) }
        busKm = 2; trainKm = 5; ringAtStop = true; announce = true; movingStation = true; autoStart = true
        soundKind = .steam; pauseMusic = false; autoHome = true; kmMem = [:]; lastScore = nil
        direction = Self.savedDirection()
        Ratings.shared.reset(); ScoreBook.shared.reset(); WatchStore.shared.reset(); StopsStore.shared.reset()
        music.disconnectSpotify(); music.source = .off
    }

    /// Settings → "Preview on the lock screen": a made-up trip for a minute, so you can see how it looks.
    func previewActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let now = Date(), home = direction == .home
        let song = music.song
        let s = TripAttributes.ContentState(
            legTitle: home ? "Bus 306 to Veghel" : "Intercity to Breda", isTrain: !home, distanceText: home ? "3.8 km" : "9.6 km",
            arrival: now.addingTimeInterval(home ? 9 * 60 : 34 * 60), finalName: finalName,
            nextText: home ? nil : "Then bus 3 to BUas from Breda", awake: false, goingHome: home,
            kicker: "NOW RIDING", stopName: home ? Place.veghel.spoken : Place.breda.spoken, progress: 0.15,
            legFrom: now.addingTimeInterval(-4 * 60), legTo: now.addingTimeInterval(home ? 9 * 60 : 18 * 60),
            song: song?.title ?? "Your song", artist: song?.artist ?? "The artist", songPlaying: true, musicApp: song?.app ?? "Spotify")
        guard let a = try? Activity.request(attributes: TripAttributes(routeName: "Preview"), content: ActivityContent(state: s, staleDate: nil), pushType: nil) else { return }
        Task {
            // the metro drives along, so you can see it move
            for p in [0.35, 0.55, 0.75, 0.95] {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                var n = s; n.progress = p
                n.distanceText = Fmt.distance((home ? 3800 : 9600) * (1 - p))
                await a.update(ActivityContent(state: n, staleDate: nil))
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
