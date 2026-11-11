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

    @Published var direction: Direction = Calendar.current.component(.hour, from: Date()) < 12 ? .toSchool : .home
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
    @Published private(set) var always = false

    let sound = AlarmSound()
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
    private let arriveM = 450.0

    var leg: Leg? { index < legs.count ? legs[index] : nil }
    var wakeKm: Double { leg?.mode == .bus ? busKm : trainKm }
    var finalName: String { direction == .home ? "Home" : "Breda" }
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
        updateWatching()
    }

    // MARK: trip flow

    func start(_ r: RoutePlan, at legIndex: Int = 0, vehicle v: Vehicle? = nil, auto: Bool = false) {
        route = r
        legs = r.legs(direction)
        index = min(legIndex, legs.count - 1)
        autoStarted = auto
        sound.startTrip()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        beginLeg(vehicle: v)
        startActivity()
    }

    private func beginLeg(vehicle v: Vehicle? = nil) {
        phase = .sleeping
        distance = nil; forceArrival = false
        legStart = Date()
        arrival = nil; next = nil; legArrival = nil
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
        if approach && (ringAtStop || forceArrival) { phase = .awake; pushActivity(force: true) } else { legDone() }
    }

    /// You're at the end of a leg (by GPS, by the alarm, or "I'm off").
    func legDone() {
        sound.stop()
        arrivedAt = leg?.to.short
        if index + 1 < legs.count {
            phase = .transfer
            // With auto-start on, keep looking for the next bus or train so the next leg starts by itself.
            if autoStart { vehicle = nil; startDetecting(forNextLeg: true) } else { location.stopUpdatingLocation() }
        } else {
            phase = .finished
            location.stopUpdatingLocation()
        }
        pushActivity(force: true)
    }

    func nextLeg(vehicle v: Vehicle? = nil) {
        guard index + 1 < legs.count else { return }
        index += 1
        sound.startTrip()
        beginLeg(vehicle: v)
        pushActivity(force: true)
    }

    func endTrip() {
        detectTask?.cancel(); detectTask = nil
        sound.endTrip()
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        phase = .idle
        route = nil; legs = []; distance = nil; arrival = nil; next = nil; vehicle = nil; legArrival = nil; arrivedAt = nil
        let a = activity; activity = nil
        Task { await a?.end(nil, dismissalPolicy: .immediate) }
    }

    /// When the app comes back to the screen: start the Live Activity if a trip started by itself in the background.
    func appBecameActive() {
        always = location.authorizationStatus == .authorizedAlways
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

    private func handle(_ loc: CLLocation) {
        samples.append(loc)
        samples.removeAll { $0.timestamp < Date().addingTimeInterval(-240) }
        guard let leg, phase == .sleeping || phase == .awake else { return }
        let d = loc.distance(from: CLLocation(latitude: leg.to.coordinate.latitude, longitude: leg.to.coordinate.longitude))
        distance = d
        accuracy = loc.horizontalAccuracy
        let good = loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 250
        if phase == .sleeping && good && d <= wakeKm * 1000 {
            if Date().timeIntervalSince(legStart) < 20 { phase = .awake; forceArrival = true } else { ring(approach: true) }
        } else if phase == .awake && d <= arriveM && loc.horizontalAccuracy <= 600 {
            if ringAtStop || forceArrival { ring(approach: false) } else { legDone() }
        }
        refreshEta(force: false)
        pushActivity(force: false)
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
        }
        refreshEta(force: true)
        pushActivity(force: true)
    }

    // MARK: starting by itself

    /// Watches your stations with region monitoring (cheap): full GPS only switches on once you leave one.
    private func updateWatching() {
        for r in location.monitoredRegions { location.stopMonitoring(for: r) }
        guard autoStart else { return }
        if location.authorizationStatus != .authorizedAlways {
            if location.authorizationStatus == .authorizedWhenInUse { location.requestAlwaysAuthorization() }
            return
        }
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
            if let known { t = known } else {
                // Not recognised yet: the ride that left closest to when you started this leg.
                let l = legs[i]
                let opts = await Transit.plan(from: l.from, to: l.to, modes: l.mode.transitModes, at: start.addingTimeInterval(-40 * 60), count: 8, maxTransfers: l.mode == .train ? 1 : 0)
                    .filter { abs($0.first.departure.timeIntervalSince(start)) < 40 * 60 }
                guard let on = opts.min(by: { abs($0.first.departure.timeIntervalSince(start)) < abs($1.first.departure.timeIntervalSince(start)) }) else { return }
                t = on.rides.last!.arrival
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
                self.pushActivity(force: true)
            }
        }
    }

    var nextText: String? {
        guard let n = next, index + 1 < legs.count else { return nil }
        return "Then \(n.isTrain ? n.name : "bus \(n.line)") at \(Fmt.hhmm(n.departure)) from \(legs[index + 1].from.short)"
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
        return .init(legTitle: title, isTrain: leg?.mode == .train, distanceText: distance.map { Fmt.distance($0) } ?? "–",
                     arrival: arrival, finalName: finalName, nextText: nextText, awake: awake, goingHome: direction == .home)
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let route, activity == nil else { return }
        activity = try? Activity.request(attributes: TripAttributes(routeName: route.name), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
    }

    private func pushActivity(force: Bool) {
        guard let activity else { return }
        let s = state
        let key = "\(s.legTitle)|\(s.distanceText)|\(s.arrival?.timeIntervalSince1970 ?? 0)|\(s.awake)"
        guard force || (key != lastActivityKey && Date().timeIntervalSince(lastActivity) > 8) else { return }
        lastActivity = Date(); lastActivityKey = key
        Task { await activity.update(ActivityContent(state: s, staleDate: nil)) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
