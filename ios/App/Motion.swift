import CoreMotion
import Foundation

/// Motion & Fitness (0.33): what the phone's motion coprocessor says you're doing, for the few decisions in
/// `MotionRules`. Off unless you turn it on (the setup's Mornings step, or Settings › Trips & alarm › "Use motion to
/// notice rides faster"); without it, or without the permission, `now()` is nil and everything is as before.
/// It never runs a loop of its own: live updates (pushed by the coprocessor, which runs anyway) only while a trip runs
/// or the home is in front with no trip; else one history question on a wake-up (leaving one of your stations).
@MainActor
final class Motion: ObservableObject {
    static let shared = Motion()
    static let settingKey = "motion.rides"

    /// The setting. Turning it on asks for the permission (once: iOS asks only the first time).
    @Published var on: Bool = UserDefaults.standard.bool(forKey: Motion.settingKey) {
        didSet {
            UserDefaults.standard.set(on, forKey: Self.settingKey)
            if on { Task { await self.ask() } } else { stopLive(); samples = []; changed() }
        }
    }
    @Published private(set) var status: CMAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
    /// Counts up each time it starts saying "automotive" (medium or high): for the home's look (`HomeLoops`).
    @Published private(set) var vehicleKicks = 0

    private let manager = CMMotionActivityManager()
    private var samples: [MotionSample] = []
    private var wants = Set<String>()
    private var liveOn = false
    private var wasVehicle = false
    private var listeners: [String: @MainActor () -> Void] = [:]

    static var available: Bool { CMMotionActivityManager.isActivityAvailable() }
    /// On, allowed, and the phone has the coprocessor.
    var usable: Bool { on && Self.available && status == .authorized }
    var denied: Bool { status == .denied || status == .restricted }

    /// What it says now (nil: off, not allowed, or nothing to go by).
    func now(at t: Date = Date()) -> MotionNow? { usable ? MotionRules.now(samples, at: t, live: liveOn) : nil }

    /// Told whenever what it says may have changed.
    func listen(_ id: String, _ f: @escaping @MainActor () -> Void) { listeners[id] = f }

    /// Asks for the permission, by asking for the last minute (that's what brings up iOS's question).
    func ask() async {
        guard on, Self.available else { return }
        await refresh(back: 60)
        status = CMMotionActivityManager.authorizationStatus()
        if !wants.isEmpty { startLive() }
    }

    /// A wake-up (leaving a station, coming back to the front): what it said over the last quarter of an hour.
    func refresh(back: TimeInterval = MotionRules.keep) async {
        guard on, Self.available, !denied else { return }
        let to = Date(), from = to.addingTimeInterval(-back)
        let got: [MotionSample]? = await withCheckedContinuation { c in
            manager.queryActivityStarting(from: from, to: to, to: .main) { list, error in
                c.resume(returning: error == nil ? (list ?? []).map(Motion.sample) : nil)
            }
        }
        status = CMMotionActivityManager.authorizationStatus()
        guard let got else { return }
        let older = samples.filter { $0.t < from }
        samples = MotionRules.trim(older + got, now: Date())
        changed()
    }

    /// Live updates wanted (`why`: "trip", "home") or not; they run while one wants them.
    func live(_ want: Bool, for why: String) {
        if want { wants.insert(why) } else { wants.remove(why) }
        if wants.isEmpty { stopLive() } else { startLive() }
    }

    private func startLive() {
        guard usable, !liveOn else { return }
        liveOn = true
        manager.startActivityUpdates(to: .main) { [weak self] a in
            guard let a else { return }
            let s = Motion.sample(a)
            Task { @MainActor in self?.add(s) }
        }
    }

    private func stopLive() {
        guard liveOn else { return }
        manager.stopActivityUpdates()
        liveOn = false
    }

    private func add(_ s: MotionSample) {
        samples = MotionRules.trim(samples + [s], now: Date())
        changed()
    }

    private func changed() {
        let v = MotionRules.inVehicle(now())
        if v && !wasVehicle { vehicleKicks += 1 }
        wasVehicle = v
        for f in listeners.values { f() }
    }

    nonisolated private static func sample(_ a: CMMotionActivity) -> MotionSample {
        let kind: MotionKind = a.automotive ? .automotive : a.cycling ? .cycling : a.running ? .running
            : a.walking ? .walking : a.stationary ? .stationary : .unknown
        let c: MotionConfidence
        switch a.confidence {
        case .high: c = .high
        case .medium: c = .medium
        default: c = .low
        }
        return MotionSample(t: a.startDate, kind: kind, confidence: c)
    }
}

/// What the setting says (Settings › Trips & alarm, and the setup's Mornings step).
enum MotionWords {
    static let title = "Use motion to notice rides faster"
    static let detail = "With Motion & Fitness, it notices sooner that you got on a bus or train, uses less battery while you wait at a stop, and doesn’t take a quick walk or a bike ride for one. The alarm never depends on it."
    static let denied = "Motion & Fitness is off for Haltewekker: turn it on in the iPhone’s Settings › Privacy & Security › Motion & Fitness."
}
