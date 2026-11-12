import ActivityKit
import CoreLocation
import Foundation
import LocalAuthentication
import UIKit
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
final class TripManager: NSObject, ObservableObject, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
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
    /// If you're using your phone when it would ring, you're awake: one notification instead of the alarm.
    @Published var quietWhenInUse: Bool = UserDefaults.standard.object(forKey: "quietWhenInUse") as? Bool ?? true {
        didSet { UserDefaults.standard.set(quietWhenInUse, forKey: "quietWhenInUse") }
    }
    /// The backup alarm on every leg: it also rings after this many minutes, even if GPS drops out (0: off). In Settings.
    @Published var backupMinutes: Int = UserDefaults.standard.integer(forKey: "backupMinutes") {
        didSet { UserDefaults.standard.set(backupMinutes, forKey: "backupMinutes") }
    }
    @Published var autoHome: Bool = UserDefaults.standard.object(forKey: "autoHome") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoHome, forKey: "autoHome"); updateWatching() }
    }
    /// Wake distance per stop, once you've picked one ("bus:ht" → 2.5).
    @Published private(set) var kmMem: [String: Double] = UserDefaults.standard.dictionary(forKey: "kmMem") as? [String: Double] ?? [:]
    @Published private(set) var backupAt: Date?
    @Published private(set) var lastScore: ScoreResult?
    // Before you're on board, and at a transfer: what leaves next for this leg.
    @Published private(set) var upcoming: [PanelTrip] = []
    @Published private(set) var upcomingAt: Date?
    @Published private(set) var upcomingError: String?
    @Published private(set) var upcomingBoard: [BoardDeparture] = []    // buses: the stop's board, with cancelled and departed ones
    // Once it knows which bus or train you're on.
    @Published private(set) var vehicleStops: [TripStop] = []
    @Published private(set) var matchMeters: Int?            // how far its live position was from yours
    @Published private(set) var pickedByHand = false
    @Published private(set) var byTimetable = false         // no live position matched: it took the planned one once you'd clearly left
    @Published private(set) var speed: Double?               // m/s, from GPS
    @Published private(set) var startDistance: Double?       // how far you are from where this leg starts
    @Published private(set) var always = false
    /// A pretend ride (the demo): it moves along by itself, without your GPS.
    @Published private(set) var demo = false
    private var demoTask: Task<Void, Never>?
    private var guessDirection = true            // on launch (and back after a while): where you are decides the direction
    private var awaySince: Date?

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
    private var upcomingKey = ""
    private var upcomingBusy = false
    private var lastVehicleRefresh = Date.distantPast
    private var lastIdleMatch = Date.distantPast
    private var idleBest: String?
    private let arriveM = 450.0

    var leg: Leg? { index < legs.count ? legs[index] : nil }
    var wakeKm: Double { leg.map(km(for:)) ?? busKm }
    var finalName: String {
        if let r = route, !r.isFixed { return r.custom != nil ? r.station.short : (leg?.to.short ?? "") }
        return direction == .home ? "Home" : "Breda"
    }
    func km(for l: Leg) -> Double { kmMem["\(l.mode.rawValue):\(l.to.key)"] ?? (l.mode == .bus ? busKm : trainKm) }
    var here: CLLocationCoordinate2D? { location.location?.coordinate }
    /// Your last GPS fix.
    var lastFix: CLLocation? { samples.last ?? location.location }
    /// The Fastest trip screen is open: it needs GPS (also locked) to plan from where you are and notice when you get on.
    private(set) var going = false

    private static func savedDirection() -> Direction {
        let d = UserDefaults.standard
        if let at = d.object(forKey: "dirAt") as? Date, Date().timeIntervalSince(at) < 3 * 3600, let raw = d.string(forKey: "dir"), let dir = Direction(rawValue: raw) { return dir }
        return Calendar.current.component(.hour, from: Date()) < 12 ? .toSchool : .home
    }
    /// You tapped the big button.
    func pick(_ d: Direction) {
        direction = d
        UserDefaults.standard.set(d.rawValue, forKey: "dir"); UserDefaults.standard.set(Date(), forKey: "dirAt")
        UserDefaults.standard.set(Date(), forKey: "dirPickedAt")
    }

    /// When the app opens (or comes back after half an hour): in Veghel you're going to Breda, in Breda you're going home.
    /// Somewhere else it keeps what it had. A direction you just picked yourself (in the last 20 minutes) stays.
    func guessFromPlace(_ l: CLLocation) {
        guard guessDirection, !isRiding, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 1500, l.timestamp.timeIntervalSinceNow > -600 else { return }
        guessDirection = false
        if let at = UserDefaults.standard.object(forKey: "dirPickedAt") as? Date, Date().timeIntervalSince(at) < 20 * 60 { return }
        func near(_ p: Place, _ m: Double) -> Bool { l.distance(from: CLLocation(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude)) < m }
        let d: Direction? = near(.veghel, 5000) ? .toSchool : (near(.breda, 6000) || near(.buas, 6000)) ? .home : nil
        guard let d, d != direction else { return }
        direction = d
        UserDefaults.standard.set(d.rawValue, forKey: "dir"); UserDefaults.standard.set(Date(), forKey: "dirAt")
        toast = d == .toSchool ? "You’re in Veghel, so it’s set to going to Breda." : "You’re in Breda, so it’s set to going home."
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
        Watchdog.shared.mark("starting the trip engine (location, notifications)")
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 25
        location.activityType = .otherNavigation
        location.pausesLocationUpdatesAutomatically = false
        always = location.authorizationStatus == .authorizedAlways
        DispatchQueue.main.async { [weak self] in self?.updateKeepAlive() }
        music.onChange = { [weak self] in self?.pushActivity(force: true) }
        LineWatchStore.shared.onChange = { [weak self] in self?.updateKeepAlive() }
        GoStore.shared.trip = self
        SchoolAlarm.shared.trip = self
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.awaySince = Date() }
        }
        AlarmControl.stop = { [weak self] in self?.stopAlarm() }
        // "Stop alarm" right on the alarm notification.
        let stop = UNNotificationAction(identifier: "STOP", title: "Stop alarm", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: "ALARM", actions: [stop], intentIdentifiers: [], options: [])])
        UNUserNotificationCenter.current().delegate = self
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

    func start(_ r: RoutePlan, at legIndex: Int = 0, vehicle v: Vehicle? = nil, auto: Bool = false, kms: [Double]? = nil, backup: Int? = nil, stops: [TripStop]? = nil) {
        route = r
        legs = r.legs(direction)
        index = min(legIndex, legs.count - 1)
        autoStarted = auto
        if let kms {
            for (l, k) in zip(legs, kms) { kmMem["\(l.mode.rawValue):\(l.to.key)"] = k }
            UserDefaults.standard.set(kmMem, forKey: "kmMem")
        }
        tripStart = Date(); startedAtLeg = index; lastScore = nil
        setBackup(backup ?? backupMinutes)
        sound.startTrip()
        music.start()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        beginLeg(vehicle: v, stops: stops)
        startActivity()
    }

    private func beginLeg(vehicle v: Vehicle? = nil, stops: [TripStop]? = nil) {
        phase = .sleeping
        distance = nil; forceArrival = false; maxDistance = legSpan
        legStart = Date()
        arrival = nil; next = nil; legArrival = nil; legFrom = nil; legTo = nil
        vehicle = v
        vehicleStops = []; matchMeters = nil; pickedByHand = false; byTimetable = false; startDistance = nil
        location.desiredAccuracy = kCLLocationAccuracyBest; location.distanceFilter = 25
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        if let v { Task { await self.vehicleFound(v, stops: stops) } } else { startDetecting() }
        refreshEta(force: true)
        Task { await loadUpcoming(force: true) }
    }

    /// Still at the start of this leg (within 2 km) and not on board yet: show what leaves next.
    var waitingToBoard: Bool { phase == .sleeping && vehicle == nil && (startDistance ?? 0) < 2000 }

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
            // Keep looking for the next bus or train, so the next leg starts by itself once you're on board.
            vehicle = nil; startDetecting(forNextLeg: true)
            Task { await loadUpcoming(force: true) }
        } else {
            phase = .finished
            location.stopUpdatingLocation()
            if let r = route, r.isFixed, startedAtLeg == 0, let s = tripStart {
                lastScore = ScoreBook.shared.log(route: r, home: direction == .home, start: s)
            }
        }
        pushActivity(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { WatchStore.shared.showNext() }
    }

    func nextLeg(vehicle v: Vehicle? = nil, backup: Int? = nil, stops: [TripStop]? = nil) {
        guard index + 1 < legs.count else { return }
        index += 1
        sound.startTrip()
        setBackup(backup ?? backupMinutes)
        beginLeg(vehicle: v, stops: stops)
        pushActivity(force: true)
    }

    func endTrip() {
        detectTask?.cancel(); detectTask = nil
        demoTask?.cancel(); demoTask = nil; demo = false
        setBackup(0)
        sound.endTrip()
        music.stop()
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        phase = .idle
        route = nil; legs = []; distance = nil; arrival = nil; next = nil; vehicle = nil; legArrival = nil; arrivedAt = nil
        upcoming = []; upcomingAt = nil; upcomingError = nil; upcomingKey = ""; upcomingBoard = []; vehicleStops = []; matchMeters = nil; speed = nil; startDistance = nil
        legFrom = nil; legTo = nil; maxDistance = nil
        let a = activity; activity = nil
        Task { await a?.end(nil, dismissalPolicy: .immediate) }
        updateKeepAlive()
    }

    /// While you watch a bus line (and no trip runs), cheap location keeps the app awake to check it,
    /// and notices when you get on that bus.
    func updateKeepAlive() {
        guard phase == .idle else { return }
        if going {
            location.desiredAccuracy = kCLLocationAccuracyBest; location.distanceFilter = 10
            location.allowsBackgroundLocationUpdates = true
            location.showsBackgroundLocationIndicator = true
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            location.startUpdatingLocation()
        } else if !LineWatchStore.shared.watches.isEmpty {
            location.desiredAccuracy = kCLLocationAccuracyHundredMeters; location.distanceFilter = 30
            location.allowsBackgroundLocationUpdates = true
            location.showsBackgroundLocationIndicator = true
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            location.startUpdatingLocation()
        } else if watchLeft == nil {
            location.stopUpdatingLocation()
            location.allowsBackgroundLocationUpdates = false
        }
    }

    /// The Fastest trip screen opened or closed.
    func setGo(_ on: Bool) {
        going = on
        updateKeepAlive()
    }

    /// When the app comes back to the screen: start the Live Activity if a trip started by itself in the background.
    func appBecameActive() {
        Watchdog.shared.mark("coming back to the screen")
        always = location.authorizationStatus == .authorizedAlways
        Task { await NoticeLog.shared.collectDelivered() }       // off the lock screen, into the app's list
        Task { await SchoolAlarm.shared.refresh(force: true) }    // the timetable may have changed: plan the school alarm again
        if let a = awaySince, Date().timeIntervalSince(a) > 30 * 60 { guessDirection = true }
        awaySince = nil
        followClock()
        if isRiding && activity == nil { startActivity() }
    }

    // MARK: location

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in if !self.demo { self.handle(loc) } }
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
        if loc.speed >= 0 { speed = loc.speed }
        if phase == .transfer { Task { await loadUpcoming() } }
        if phase == .idle, !LineWatchStore.shared.watches.isEmpty, Date().timeIntervalSince(lastIdleMatch) > 20 {
            lastIdleMatch = Date()
            Task {
                guard let m = await self.matchVehicle(mode: .bus) else { self.idleBest = nil; return }
                let watched = LineWatchStore.shared.watches.contains { $0.line == m.vehicle.line }
                if watched && (m.meters < 250 || self.idleBest == m.vehicle.tripId) { LineWatchStore.shared.boarded(line: m.vehicle.line); self.idleBest = nil }
                else { self.idleBest = m.vehicle.tripId }
            }
        }
        guard let leg, phase == .sleeping || phase == .awake else { return }
        startDistance = loc.distance(from: CLLocation(latitude: leg.from.coordinate.latitude, longitude: leg.from.coordinate.longitude))
        if vehicle == nil { Task { await loadUpcoming() } }
        else if Date().timeIntervalSince(lastVehicleRefresh) > 60 { lastVehicleRefresh = Date(); Task { await refreshVehicle() } }
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
        let c = UNMutableNotificationContent()
        c.title = approach ? "Wake up" : "Get off now"
        c.body = approach ? "\(leg?.to.short ?? "Your stop") in about \(Fmt.distance(distance ?? 0))." : "You’re at \(leg?.to.short ?? "your stop")."
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        // Using your phone right now? Then you're awake: one notification is enough.
        if quietWhenInUse && phoneInUse() && !demo {
            c.body += approach ? " Get ready to get off." : ""
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "heads-up-\(approach)", content: c, trigger: nil)) { _ in }
            if approach && (ringAtStop || forceArrival) { phase = .awake; pushActivity(force: true); WatchStore.shared.showNext() } else { legDone() }
            return
        }
        phase = .alarm(approach: approach)
        sound.ring(announcement: announcement(approach: approach))
        c.categoryIdentifier = "ALARM"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "alarm", content: c, trigger: nil))
        pushActivity(force: true)
    }

    /// Unlocked and in use. (Without a passcode the phone never says it's locked, so then it always rings.)
    private func phoneInUse() -> Bool {
        guard UIApplication.shared.isProtectedDataAvailable else { return false }
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    // MARK: the demo

    /// A pretend bus ride from `c`, two and a half minutes long, to try everything at home: the ring with the bus going round,
    /// the stops, the speed, your song, the alarm at the wake distance and again at the stop, and arriving.
    func startDemo(from c: CLLocationCoordinate2D?, line: String = "300") {
        guard phase == .idle else { return }
        let a = c ?? here ?? Place.veghel.coordinate
        let k = cos(a.latitude * .pi / 180)
        let total = 4600.0, secs = 150.0
        func along(_ m: Double) -> CLLocationCoordinate2D { .init(latitude: a.latitude + m * 0.3 / 110_540, longitude: a.longitude + m * 0.95 / (111_320 * k)) }
        let names = ["Your stop", "Zijtaart, Kerk", "Erp, Centrum", "Boerdonk, Kerk", "Keldonk, Dorp", "Den Bosch, Centraal Station"]
        let now = Date()
        let stops = names.enumerated().map { i, n in
            TripStop(name: n, coordinate: along(total * Double(i) / Double(names.count - 1)), arrival: now.addingTimeInterval(secs * Double(i) / Double(names.count - 1)))
        }
        let end = along(total)
        let from = Place(key: "demo-from", name: "Your stop", short: "Your stop", ids: ["\(a.latitude),\(a.longitude)"], coordinate: a, spoken: "your stop")
        let to = Place(key: "demo-to", name: "Den Bosch Centraal", short: "Den Bosch", ids: ["\(end.latitude),\(end.longitude)"], coordinate: end, spoken: "Den Bosch")
        demo = true
        start(RoutePlan(id: "demo", name: "Demo ride", station: to, custom: [Leg(mode: .bus, from: from, to: to)]),
              vehicle: Vehicle(tripId: "demo-\(line)", line: line, isTrain: false), backup: 0, stops: stops)
        location.stopUpdatingLocation()                     // the pretend ride doesn't use your GPS
        let t0 = Date()
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.demo, self.phase != .idle, self.phase != .finished else { return }
                let f = min(1.0, Date().timeIntervalSince(t0) / secs)
                let loc = CLLocation(coordinate: along(total * f), altitude: 0, horizontalAccuracy: 6, verticalAccuracy: 6,
                                     course: 75, speed: f >= 1 ? 0 : 14 + 4 * sin(f * 14), timestamp: Date())
                self.handle(loc)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: notifications

    /// "Stop alarm" on the notification (or tapping it while it rings).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.identifier, action = response.actionIdentifier
        Task { @MainActor in
            if action == "STOP" || (id == "alarm" && action == UNNotificationDefaultActionIdentifier) { self.stopAlarm() }
            done()
        }
    }

    /// With the app open: the alarm and platform alerts are already on screen; the rest pop up inside the app (with their
    /// sound), and stay in the notification list.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        let c = notification.request.content
        let title = c.title, body = c.body, kind = Notices.kind(of: c.title, c.userInfo)
        let at = notification.date
        Task { @MainActor in NoticeLog.shared.add(key: id, title: title, body: body, kind: kind, at: at) }
        if id == "alarm" || id.hasPrefix("platform-") { done([]); return }
        // in the app as a banner, with its sound; kept in the app's list instead of the notification centre
        Task { @MainActor in Notices.shared.show(title: title, body: body, kind: kind) }
        done([.sound])
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

    /// Keeps comparing your GPS with every bus and train nearby until it knows which one you're on.
    /// One look is enough when it's one of the departures it expected; otherwise it wants the same one twice.
    private func startDetecting(forNextLeg: Bool = false) {
        detectTask?.cancel()
        detectTask = Task { [weak self] in
            var lastBest: String?
            var rejected = Set<String>()
            var wait: UInt64 = 3
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                wait = 7                                                // first look soon, then every 7 seconds
                guard let self, !Task.isCancelled else { return }
                if forNextLeg { guard self.phase == .transfer else { return } }
                else { guard self.vehicle == nil, self.phase == .sleeping || self.phase == .awake else { return } }
                let li = forNextLeg ? self.index + 1 : self.index
                let mode = self.legs[safe: li]?.mode
                let planned = self.route?.planned?[safe: li]
                guard let m = await self.matchVehicle(mode: mode, excluding: rejected) else {
                    lastBest = nil
                    // No live match (some have no live position): the one it planned, once you've clearly left on it.
                    if let p = planned, let from = self.legs[safe: li]?.from, self.clearlyLeft(on: p, from: from) {
                        let v = Vehicle(tripId: p.tripId, line: p.line, isTrain: p.isTrain)
                        if forNextLeg { if self.phase == .transfer { self.nextLeg(vehicle: v); self.byTimetable = true } }
                        else { self.byTimetable = true; await self.vehicleFound(v) }
                        return
                    }
                    continue
                }
                // One look is enough for one it expects, or one that's right with you; others it wants to see twice.
                let expected = (self.upcoming.contains { $0.trip.first.tripId == m.vehicle.tripId } || planned?.tripId == m.vehicle.tripId) && m.meters < 350
                if expected || m.meters < 150 || m.vehicle.tripId == lastBest {
                    // Its own timetable must still have your stop ahead: not one going the other way, not an earlier run.
                    let stops = await Transit.tripStops(m.vehicle.tripId)
                    let dests: [Place] = forNextLeg ? [self.legs[safe: self.index + 1]?.to].compactMap { $0 } : self.legDestinations
                    guard dests.contains(where: { self.goesAhead(stops, to: $0) }) else {
                        rejected.insert(m.vehicle.tripId); lastBest = nil; continue
                    }
                    if forNextLeg {
                        if self.phase == .transfer { self.nextLeg(vehicle: m.vehicle, stops: stops); self.matchMeters = Int(m.meters) }
                    } else {
                        await self.vehicleFound(m.vehicle, meters: m.meters, stops: stops)
                    }
                    return
                }
                lastBest = m.vehicle.tripId
            }
        }
    }

    /// You've left the start of the leg at bus or train speed, around when the planned one leaves.
    private func clearlyLeft(on p: PlannedRide, from start: Place) -> Bool {
        let now = Date()
        guard now > p.departure.addingTimeInterval(-120), now < p.departure.addingTimeInterval(20 * 60) else { return false }
        let last3 = samples.suffix(3)
        guard last3.count == 3, let last = last3.last, last.timestamp > now.addingTimeInterval(-30), last.horizontalAccuracy < 150,
              last3.allSatisfy({ $0.speed >= 4 }) else { return false }
        return last.distance(from: CLLocation(latitude: start.coordinate.latitude, longitude: start.coordinate.longitude)) > 400
    }

    /// Compares where you've been in the last minutes with where every nearby bus or train should have been.
    func matchVehicle(mode: Mode?, excluding: Set<String> = []) async -> (vehicle: Vehicle, meters: Double)? {
        let recent = samples.filter { $0.timestamp > Date().addingTimeInterval(-120) && $0.horizontalAccuracy < 150 }
        guard let last = recent.last, recent.count >= 2 else { return nil }
        let speed = max(last.speed, recent.first.map { last.distance(from: $0) / max(1, last.timestamp.timeIntervalSince($0.timestamp)) } ?? 0)
        guard speed > 2.5 else { return nil }                   // not moving: not on board yet
        // Each bus or train in pieces from stop to stop: put them together, so it isn't lost when it passes a stop.
        let segs = await Transit.vehicles(near: last.coordinate)
        let byTrip = Dictionary(grouping: segs, by: { $0.tripId })
        func at(_ list: [VehicleSegment], _ t: Date) -> CLLocationCoordinate2D? {
            list.first(where: { t >= $0.departure && t <= $0.arrival })?.position(at: t) ?? list.lazy.compactMap { $0.position(at: t) }.first
        }
        // Which way you're going, in metres east and north.
        let pts = Array(recent.suffix(4)), a = pts.first!, b = pts.last!
        func vec(_ p: CLLocationCoordinate2D, _ q: CLLocationCoordinate2D) -> (Double, Double) {
            ((q.longitude - p.longitude) * 111_320 * cos(p.latitude * .pi / 180), (q.latitude - p.latitude) * 110_540)
        }
        let me = vec(a.coordinate, b.coordinate), meLen = hypot(me.0, me.1)
        var best: (Vehicle, Double)?
        for (id, list) in byTrip {
            guard let s = list.first else { continue }
            if let mode, (mode == .train) != s.isTrain { continue }
            if excluding.contains(id) { continue }
            // A bus at the same stop that leaves the other way is not yours.
            if meLen > 40, let pa = at(list, a.timestamp), let pb = at(list, b.timestamp) {
                let v = vec(pa, pb), vLen = hypot(v.0, v.1)
                if vLen > 40 && (me.0 * v.0 + me.1 * v.1) / (meLen * vLen) < 0.5 { continue }
            }
            var total = 0.0, n = 0.0
            for p in recent.suffix(4) {
                guard let c = at(list, p.timestamp) else { continue }
                total += p.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)); n += 1
            }
            guard n >= 2 else { continue }
            let avg = total / n
            if avg < (s.isTrain ? 600 : 400), best == nil || avg < best!.1 { best = (Vehicle(tripId: s.tripId, line: s.isTrain ? Transit.trainLabel(s.line) : s.line, isTrain: s.isTrain), avg) }
        }
        return best.map { (vehicle: $0.0, meters: $0.1) }
    }

    /// Where this leg can take you: on the first leg of a route either station (it follows the one you take).
    private var legDestinations: [Place] {
        guard let l = leg else { return [] }
        return index == 0 && route?.isFixed == true ? RoutePlan.all.map { $0.legs(direction)[0].to } : [l.to]
    }

    /// Does this bus or train still reach `dest` from where you are now?
    /// False for one going the other way (it passed your stop already) or one that doesn't go there at all.
    private func goesAhead(_ stops: [TripStop], to dest: Place) -> Bool {
        let timed = stops.filter { $0.arrival != nil }
        guard !timed.isEmpty else { return true }                // no times known: trust the match
        func d(_ s: TripStop, _ c: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: CLLocation(latitude: s.coordinate.latitude, longitude: s.coordinate.longitude))
        }
        guard let ti = timed.indices.min(by: { d(timed[$0], dest.coordinate) < d(timed[$1], dest.coordinate) }),
              d(timed[ti], dest.coordinate) < 1500 else { return false }
        if timed[ti].arrival! < Date().addingTimeInterval(-120) { return false }
        if let here = samples.last?.coordinate,
           let hi = timed.indices.min(by: { d(timed[$0], here) < d(timed[$1], here) }), hi > ti { return false }
        return true
    }

    /// "I'm on this one", picked on the stop's board.
    func choose(board d: BoardDeparture) {
        if let p = upcoming.first(where: { $0.trip.first.tripId == d.tripId }) { choose(p); return }
        detectTask?.cancel()
        pickedByHand = true
        Task { await vehicleFound(Vehicle(tripId: d.tripId, line: d.line, isTrain: false), meters: nil) }
    }

    /// "I'm on this one": you picked it in the list.
    func choose(_ p: PanelTrip) {
        let f = p.trip.first
        detectTask?.cancel()
        pickedByHand = true
        Task { await vehicleFound(Vehicle(tripId: f.tripId, line: f.line, isTrain: f.isTrain), meters: nil, dest: p.to) }
    }

    /// Found it: use that vehicle's own live arrival at your stop. On the first leg it follows the route
    /// of the bus or train you actually took (via Den Bosch or via Eindhoven).
    private func vehicleFound(_ v: Vehicle, meters: Double? = nil, dest: Place? = nil, stops known: [TripStop]? = nil) async {
        vehicle = v
        if let meters { matchMeters = Int(meters) }
        if v.isTrain { WatchStore.shared.boarded(num: upcoming.first(where: { $0.trip.first.tripId == v.tripId })?.trip.first.num ?? "") }
        else { LineWatchStore.shared.boarded(line: v.line) }
        let stops: [TripStop]
        if let known { stops = known } else { stops = await Transit.tripStops(v.tripId) }
        if index == 0, let r = route, r.isFixed {
            let names = stops.map { $0.name.lowercased() }
            func goes(_ p: Place) -> Bool { names.contains { $0.contains(p == .denBosch ? "hertogenbosch" : "eindhoven") } }
            let fromList = upcoming.first(where: { $0.trip.first.tripId == v.tripId })?.to
            let to = dest ?? fromList ?? (goes(r.station) ? r.station : RoutePlan.all.map(\.station).first(where: goes))
            if let to, to != r.station, let nr = RoutePlan.via(to) {
                route = nr; legs = nr.legs(direction); distance = nil; maxDistance = legSpan
            }
        }
        applyStops(stops)
        refreshEta(force: true)
        pushActivity(force: true)
    }

    /// Every minute while riding: the vehicle's live times (delays, next stop).
    private func refreshVehicle() async {
        guard let v = vehicle, !demo else { return }
        let stops = await Transit.tripStops(v.tripId)
        guard vehicle == v, !stops.isEmpty else { return }
        applyStops(stops)
        pushActivity(force: false)
    }

    private func applyStops(_ stops: [TripStop]) {
        guard let leg else { return }
        let target = CLLocation(latitude: leg.to.coordinate.latitude, longitude: leg.to.coordinate.longitude)
        let timed = stops.filter { $0.arrival != nil }
        func d(_ s: TripStop, _ to: CLLocation) -> Double { to.distance(from: CLLocation(latitude: s.coordinate.latitude, longitude: s.coordinate.longitude)) }
        guard let s = timed.min(by: { d($0, target) < d($1, target) }), d(s, target) < 1500,
              s.arrival! > Date().addingTimeInterval(-120) else { vehicleStops = stops; return }
        legArrival = s.arrival
        legTo = s.arrival
        let from = CLLocation(latitude: leg.from.coordinate.latitude, longitude: leg.from.coordinate.longitude)
        var start = 0
        if let b = timed.min(by: { d($0, from) < d($1, from) }), d(b, from) < 1500, let dep = b.arrival, dep < s.arrival! {
            legFrom = dep
            start = stops.firstIndex(where: { $0.name == b.name && $0.arrival == b.arrival }) ?? 0
        }
        // Only the stops from where you got on up to yours.
        if let end = stops.firstIndex(where: { $0.name == s.name && $0.arrival == s.arrival }), end >= start { vehicleStops = Array(stops[start...end]) } else { vehicleStops = stops }
    }

    /// The next stop the bus or train reaches, and when.
    var nextStop: TripStop? { vehicleStops.first { ($0.arrival ?? .distantPast) > Date() } }

    /// The stops along the way, for the track: every station for a train; for a bus only the bigger ones
    /// (the first stop in each new town, and stations), at most four.
    var stopMarks: [StopMark] {
        guard vehicleStops.count > 2, let v = vehicle else { return [] }
        let mid = Array(vehicleStops.dropFirst().dropLast())
        let town: (String) -> String = { $0.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? $0 }
        var picked: [(TripStop, String)] = []
        if v.isTrain {
            let list = mid.count <= 6 ? mid : (0..<6).map { mid[$0 * (mid.count - 1) / 5] }
            picked = list.map { ($0, Fmt.place($0.name)) }
        } else {
            var last = town(vehicleStops[0].name)
            for s in mid {
                let t = town(s.name), station = s.name.lowercased().contains("station")
                if t != last || station { picked.append((s, station ? Fmt.place(s.name) : t)); last = t }
            }
            picked = Array(picked.prefix(4))
        }
        let a = legFrom ?? vehicleStops.first?.arrival, b = legTo ?? vehicleStops.last?.arrival
        return picked.enumerated().map { (i, p) -> StopMark in
            var f = Double(i + 1) / Double(picked.count + 1)
            if let a, let b, let t = p.0.arrival, b > a { f = min(1, max(0, t.timeIntervalSince(a) / b.timeIntervalSince(a))) }
            return StopMark(name: p.1, time: p.0.arrival, fraction: f)
        }
    }

    // MARK: what leaves next

    /// The next buses or trains for the leg you're about to take (before you're on board, and at a transfer).
    /// On the first leg it lists both routes: towards BUas via Den Bosch or Eindhoven, or home the same way.
    func loadUpcoming(force: Bool = false) async {
        var target: (from: Place, to: [Place], mode: Mode)?
        if phase == .transfer, let n = legs[safe: index + 1] { target = (n.from, [n.to], n.mode) }
        else if (phase == .sleeping || phase == .awake) && vehicle == nil, let l = leg {
            let both = index == 0 && route?.isFixed == true
            target = (l.from, both ? RoutePlan.all.map { $0.legs(direction)[0].to } : [l.to], l.mode)
        }
        guard let t = target else { return }
        let k = "\(t.from.key)>\(t.to.map(\.key).joined(separator: ","))>\(t.mode.rawValue)>\(index)"
        if k != upcomingKey { upcomingKey = k; upcoming = []; upcomingAt = nil; upcomingError = nil; upcomingBoard = [] }
        guard !upcomingBusy, force || upcomingAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        upcomingBusy = true
        defer { upcomingBusy = false }
        let rail = t.mode == .train
        let from = t.from.key == "veghel" ? StopsStore.shared.veghel : t.from
        var all: [PanelTrip] = []
        for dest in t.to {
            let l = await Transit.plan(from: from, to: dest, modes: rail ? "RAIL" : "BUS", at: Date().addingTimeInterval(-30 * 60), count: rail ? 10 : 10, maxTransfers: rail ? 1 : 0)
            Ratings.shared.learn(from, dest, l)
            all += l.map { PanelTrip(trip: $0, from: from, to: dest) }
        }
        // For buses also the stop's own board: it shows cancelled buses (the planner leaves them out) and the ones that left.
        if !rail {
            let names = t.to.map(\.short) + t.to.map(\.name)
            let ids = Set(all.map { $0.trip.first.tripId })
            let b = await Transit.board(stopIds: from.ids, from: Date().addingTimeInterval(-30 * 60), n: 40)
            guard k == upcomingKey else { return }
            upcomingBoard = b.filter { d in ids.contains(d.tripId) || names.contains { !$0.isEmpty && d.headsign.localizedCaseInsensitiveContains($0) } }
        } else { upcomingBoard = [] }
        guard k == upcomingKey else { return }
        upcomingAt = Date()
        guard !all.isEmpty else {
            if upcoming.isEmpty { upcomingError = "Couldn’t load the next \(rail ? "trains" : "buses") just now. It tries again in a minute." }
            return
        }
        // The same bus can come up from both Veghel stops: keep it once, with the least walking.
        var seen = Set<String>()
        let once = all.sorted { $0.trip.first.walkBefore < $1.trip.first.walkBefore }.filter { seen.insert($0.trip.first.tripId).inserted }
        // Hide an option when one that leaves later still gets you there as early.
        let kept = once.filter { o in !once.contains { q in q.id != o.id && q.to == o.to && q.trip.first.departure > o.trip.first.departure && q.trip.last.arrival <= o.trip.last.arrival } }
        upcoming = kept.sorted { $0.trip.first.departure < $1.trip.first.departure }
        upcomingError = nil
        if rail { await NSStore.shared.enrich(upcoming.map { ($0.trip, $0.from, $0.to) }) }
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
                guard let v = await self.matchVehicle(mode: nil)?.vehicle else { lastBest = nil; continue }
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
        let stops = await Transit.tripStops(v.tripId)
        let names = stops.map { $0.name.lowercased() }
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
        guard let target = r.legs(dir)[safe: i]?.to, goesAhead(stops, to: target) else { return false }
        direction = dir
        start(r, at: i, vehicle: v, auto: true, stops: stops)
        let c = UNMutableNotificationContent()
        c.title = "Trip started by itself"
        c.body = "\(v.title) to \(legs[safe: i]?.to.short ?? "your stop"). It rings \(Fmt.distance(wakeKm * 1000)) before your stop."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "autostart", content: c, trigger: nil)) { _ in }
        return true
    }

    // MARK: expected arrival

    private func refreshEta(force: Bool) {
        if demo { arrival = legArrival ?? legTo; return }
        guard force || Date().timeIntervalSince(lastEta) > 120 else { return }
        lastEta = Date()
        let legs = self.legs, i = index, start = legStart, known = legArrival
        Task {
            guard i < legs.count else { return }
            var t: Date
            var window: (Date, Date)?
            if let known, known > Date().addingTimeInterval(-120) { t = known } else {
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
    /// How far this leg's two ends are apart: the least the leg can be (also when you start it halfway, on board).
    private var legSpan: Double? {
        guard let l = leg else { return nil }
        return CLLocation(latitude: l.from.coordinate.latitude, longitude: l.from.coordinate.longitude)
            .distance(from: CLLocation(latitude: l.to.coordinate.latitude, longitude: l.to.coordinate.longitude))
    }

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
            // a late vehicle: don't let the clock run ahead of where you really are (once we know which one you're on,
            // its own live times already have the delay in them)
            if vehicle == nil, let bd = byDistance, t > bd + 0.25 { return min(1, max(0, bd)) }
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
        default: return waitingToBoard ? "WAITING TO BOARD" : "NOW RIDING"
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
                     musicApp: song?.app, stops: stopMarks.map(\.fraction), ringing: { () -> Bool in if case .alarm = phase { return true }; return false }())
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let route, activity == nil else { return }
        activity = try? Activity.request(attributes: TripAttributes(routeName: route.name), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
    }

    private func pushActivity(force: Bool) {
        guard let activity else { return }
        let s = state
        let key = "\(s.legTitle)|\(s.distanceText)|\(s.arrival?.timeIntervalSince1970 ?? 0)|\(s.awake)|\(Int(s.progress * 50))|\(s.song ?? "")|\(s.songPlaying)|\(s.ringing)"
        guard force || (key != lastActivityKey && Date().timeIntervalSince(lastActivity) > 8) else { return }
        lastActivity = Date(); lastActivityKey = key
        Task { await activity.update(ActivityContent(state: s, staleDate: nil)) }
    }

    /// Settings → Reset everything.
    func resetAll() {
        if isRiding { endTrip() }
        let d = UserDefaults.standard
        for k in ["busKm", "trainKm", "ringAtStop", "announce", "movingStation", "autoStart", "sound", "pauseMusic", "autoHome", "kmMem", "dir", "dirAt", "autoHomeDay", "quietWhenInUse", "backupMinutes"] { d.removeObject(forKey: k) }
        busKm = 2; trainKm = 5; ringAtStop = true; announce = true; movingStation = true; autoStart = true
        soundKind = .steam; pauseMusic = false; autoHome = true; quietWhenInUse = true; kmMem = [:]; lastScore = nil
        direction = Self.savedDirection()
        Ratings.shared.reset(); ScoreBook.shared.reset(); WatchStore.shared.reset(); StopsStore.shared.reset(); LineWatchStore.shared.reset()
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
