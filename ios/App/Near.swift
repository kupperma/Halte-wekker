import CoreLocation
import Foundation

/// Near me: only show what leaves from where you are. Also notices when you reach BUas, to switch to going home.
@MainActor
final class NearMe: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let radius = 2000.0
    static let schoolRadius = 350.0
    /// Where each list leaves from.
    static let places: [String: (CLLocationCoordinate2D, String)] = [
        "veghel": (.init(latitude: 51.6137, longitude: 5.5474), "Veghel"),
        "ehv": (.init(latitude: 51.4430, longitude: 5.4796), "Eindhoven station"),
        "ht": (.init(latitude: 51.6905, longitude: 5.2936), "Den Bosch station"),
        "bd": (.init(latitude: 51.5950, longitude: 4.7799), "Breda station"),
        "buas": (.init(latitude: 51.5907, longitude: 4.7932), "BUas"),
    ]

    @Published var on: Bool = UserDefaults.standard.bool(forKey: "nearMe") {
        didSet { UserDefaults.standard.set(on, forKey: "nearMe"); if on { locate(force: true) } }
    }
    @Published private(set) var position: CLLocation?
    @Published private(set) var error: String?

    /// Called with every position: TripManager uses it to switch to Home at school.
    var onPosition: (CLLocation) -> Void = { _ in }

    private let manager = CLLocationManager()
    private var lastAsk = Date.distantPast

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Your places within 2 km, or nil if you're near none of them (then everything is shown).
    var nearSet: Set<String>? {
        guard on, let p = position else { return nil }
        let s = Set(Self.places.filter { p.distance(from: CLLocation(latitude: $0.value.0.latitude, longitude: $0.value.0.longitude)) <= Self.radius }.keys)
        return s.isEmpty ? nil : s
    }

    /// A position now, at most every 90 s. Never asks for permission unless Near me is on (or `ask`).
    func locate(force: Bool = false, ask: Bool = false) {
        guard force || Date().timeIntervalSince(lastAsk) > 90 else { return }
        let st = manager.authorizationStatus
        if st == .notDetermined { if on || ask { manager.requestWhenInUseAuthorization() }; return }
        guard st == .authorizedAlways || st == .authorizedWhenInUse else {
            if on { error = "Location is off for Haltewekker. Turn it on in Settings to use Near me." }
            return
        }
        lastAsk = Date()
        // The position the phone already has (from a minute ago), right away: asking for a new one can take a while,
        // inside a station especially. The new one follows.
        if position.map({ Date().timeIntervalSince($0.timestamp) > 120 }) ?? true, let l = manager.location,
           Date().timeIntervalSince(l.timestamp) < 180, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 500 {
            position = l
            onPosition(l)
        }
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in self.position = l; self.error = nil; self.onPosition(l) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in if self.position == nil { self.error = "Couldn’t find where you are right now." } }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in if self.on { self.locate(force: true) } }
    }

    static func atSchool(_ l: CLLocation) -> Bool {
        let b = places["buas"]!.0
        return l.distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) <= schoolRadius
    }
}
