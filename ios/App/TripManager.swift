import ActivityKit
import CoreLocation
import Foundation
import UserNotifications

/// Runs a trip: follows GPS (also with the phone locked), rings before each stop,
/// keeps the expected arrival up to date and drives the Live Activity.
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
    @Published private(set) var locationDenied = false

    @Published var busKm: Double = UserDefaults.standard.object(forKey: "busKm") as? Double ?? 2 { didSet { UserDefaults.standard.set(busKm, forKey: "busKm") } }
    @Published var trainKm: Double = UserDefaults.standard.object(forKey: "trainKm") as? Double ?? 5 { didSet { UserDefaults.standard.set(trainKm, forKey: "trainKm") } }
    @Published var ringAtStop: Bool = UserDefaults.standard.object(forKey: "ringAtStop") as? Bool ?? true { didSet { UserDefaults.standard.set(ringAtStop, forKey: "ringAtStop") } }

    private let location = CLLocationManager()
    private let sound = AlarmSound()
    private var activity: Activity<TripAttributes>?
    private var legStart = Date()
    private var forceArrival = false
    private var lastEta = Date.distantPast
    private var lastActivity = Date.distantPast
    private var lastActivityText = ""
    private let arriveM = 450.0

    var leg: Leg? { index < legs.count ? legs[index] : nil }
    var wakeKm: Double { leg?.mode == .bus ? busKm : trainKm }
    var finalName: String { direction == .home ? "Home" : "Breda" }

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 25
        location.activityType = .otherNavigation
        location.pausesLocationUpdatesAutomatically = false
    }

    // MARK: trip flow

    func start(_ r: RoutePlan) {
        route = r
        legs = r.legs(direction)
        index = 0
        sound.startTrip()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        beginLeg()
        startActivity()
    }

    private func beginLeg() {
        phase = .sleeping
        distance = nil
        forceArrival = false
        legStart = Date()
        arrival = nil; next = nil
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        refreshEta(force: true)
    }

    func stopAlarm() {
        sound.stop()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        guard case .alarm(let approach) = phase else { return }
        if approach && (ringAtStop || forceArrival) { phase = .awake; pushActivity(force: true) }
        else { legDone() }
    }

    /// "I'm off": you got off yourself.
    func legDone() {
        sound.stop()
        location.stopUpdatingLocation()
        if index + 1 < legs.count { phase = .transfer } else { phase = .finished }
        pushActivity(force: true)
    }

    func nextLeg() {
        guard index + 1 < legs.count else { return }
        index += 1
        sound.startTrip()
        beginLeg()
        pushActivity(force: true)
    }

    func endTrip() {
        sound.endTrip()
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        phase = .idle
        route = nil; legs = []; distance = nil; arrival = nil; next = nil
        let a = activity; activity = nil
        Task { await a?.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: location

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.handle(loc) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.locationDenied = (s == .denied || s == .restricted) }
    }

    private func handle(_ loc: CLLocation) {
        guard let leg, phase == .sleeping || phase == .awake else { return }
        let target = CLLocation(latitude: leg.to.coordinate.latitude, longitude: leg.to.coordinate.longitude)
        let d = loc.distance(from: target)
        distance = d
        accuracy = loc.horizontalAccuracy
        let good = loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 250
        let wakeM = wakeKm * 1000
        if phase == .sleeping && good {
            if d <= wakeM {
                if Date().timeIntervalSince(legStart) < 20 { phase = .awake; forceArrival = true }   // already close when you started
                else { ring(approach: true) }
            }
        } else if phase == .awake && d <= arriveM && loc.horizontalAccuracy <= 600 {
            if ringAtStop || forceArrival { ring(approach: false) } else { legDone() }
        }
        refreshEta(force: false)
        pushActivity(force: false)
    }

    private func ring(approach: Bool) {
        phase = .alarm(approach: approach)
        sound.ring()
        let c = UNMutableNotificationContent()
        c.title = approach ? "Wake up" : "Get off now"
        c.body = approach ? "\(leg?.to.short ?? "Your stop") in about \(Fmt.distance(distance ?? 0))." : "You’re at \(leg?.to.short ?? "your stop")."
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "alarm", content: c, trigger: nil))
        pushActivity(force: true)
    }

    // MARK: expected arrival

    private func refreshEta(force: Bool) {
        guard force || Date().timeIntervalSince(lastEta) > 120 else { return }
        lastEta = Date()
        let legs = self.legs, i = index, start = legStart
        Task {
            guard let r = await Transit.estimate(legs: legs, index: i, legStart: start) else { return }
            await MainActor.run {
                guard self.index == i, self.phase != .idle else { return }
                self.arrival = r.arrival
                self.next = r.next
                self.pushActivity(force: true)
            }
        }
    }

    var nextText: String? {
        guard let n = next, index + 1 < legs.count else { return nil }
        let what = n.isTrain ? n.line : "bus \(n.line)"
        return "Then \(what) at \(Fmt.hhmm(n.departure)) from \(legs[index + 1].from.short)"
    }

    // MARK: Live Activity

    private var state: TripAttributes.ContentState {
        let title: String
        switch phase {
        case .transfer: title = "Change at \(leg?.to.short ?? "")"
        case .finished: title = "You’re there"
        case .alarm(let a): title = a ? "Wake up: \(leg?.to.short ?? "")" : "Get off now"
        default: title = leg?.title ?? ""
        }
        var awake = false
        if case .alarm = phase { awake = true } else if phase == .awake { awake = true }
        return .init(legTitle: title, isTrain: leg?.mode == .train,
                     distanceText: distance.map { Fmt.distance($0) } ?? "–",
                     arrival: arrival, finalName: finalName, nextText: nextText,
                     awake: awake, goingHome: direction == .home)
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let route else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        activity = try? Activity.request(attributes: TripAttributes(routeName: route.name), content: content, pushType: nil)
    }

    private func pushActivity(force: Bool) {
        guard let activity else { return }
        let s = state
        let key = "\(s.legTitle)|\(s.distanceText)|\(s.arrival?.timeIntervalSince1970 ?? 0)|\(s.awake)"
        guard force || (key != lastActivityText && Date().timeIntervalSince(lastActivity) > 8) else { return }
        lastActivity = Date(); lastActivityText = key
        Task { await activity.update(ActivityContent(state: s, staleDate: nil)) }
    }
}
