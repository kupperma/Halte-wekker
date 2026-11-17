import Darwin
import Foundation
import UIKit

/// What feeds the battery and data log (`BatteryLog`, 0.20.7) from the app: the requests (`Net.onRequest`) and their
/// real bytes (`Net.onMetrics`: their `URLSessionTaskMetrics`, and whether they went over a mobile network), the CPU
/// time, the battery level, and the time in front and behind. Started once, as the trip engine starts.
@MainActor
enum BatteryMeter {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        let log = BatteryLog.shared
        log.cpuReader = { BatteryMeter.cpuSeconds() }
        Net.onRequest = { label, bytes in BatteryLog.shared.request(CostKind.of(path: label), body: bytes) }
        Net.onMetrics = { url, bytes, mobile in
            BatteryLog.shared.wire(CostKind.of(path: url?.path ?? "", host: url?.host), bytes: bytes, mobile: mobile)
        }
        FieldLog.shared.alsoFlush = { BatteryLog.shared.flush() }
        UIDevice.current.isBatteryMonitoringEnabled = true
        log.scene(foreground: UIApplication.shared.applicationState != .background)
        sampleBattery()
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in BatteryLog.shared.scene(foreground: true); BatteryMeter.sampleBattery() }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in BatteryLog.shared.scene(foreground: false); BatteryMeter.sampleBattery(); BatteryLog.shared.flush() }
        }
        nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in BatteryMeter.sampleBattery() }
        }
        nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in BatteryMeter.sampleBattery() }
        }
    }

    /// The battery now (0…1, nil: not known) and whether it's unplugged.
    static var battery: (level: Double?, unplugged: Bool) {
        let d = UIDevice.current
        let level = Double(d.batteryLevel)
        return (level >= 0 ? level : nil, d.batteryState == .unplugged)
    }

    static func sampleBattery() {
        let b = battery
        if let l = b.level { BatteryLog.shared.battery(level: l, unplugged: b.unplugged) }
    }

    /// GPS for trips (`TripManager.applyGPS`) is now as `plan` has it, for `reason`.
    static func tripGPS(_ plan: GPSPolicy.Plan, reason: GPSReason?) {
        BatteryLog.shared.gps("trip", mode: plan.on ? mode(plan.accuracy) : nil, reason: plan.on ? reason : nil)
    }

    static func mode(_ a: GPSPolicy.Accuracy) -> GPSMode {
        switch a {
        case .best: return .best
        case .tenMetres: return .tenMetres
        case .hundredMetres: return .hundredMetres
        }
    }

    static func rideStart() {
        let b = battery
        BatteryLog.shared.rideStart(battery: b.level, unplugged: b.unplugged)
    }

    /// The ride ended: its line in the field log.
    static func rideEnd(legs: Int) {
        let b = battery
        guard let r = BatteryLog.shared.rideEnd(battery: b.level, unplugged: b.unplugged, legs: legs) else { return }
        FieldLog.shared.add(.ride, BatteryReport.fieldLine(r))
    }

    /// User and system CPU time of the app so far, in seconds.
    nonisolated static func cpuSeconds() -> Double? {
        var u = rusage()
        guard getrusage(RUSAGE_SELF, &u) == 0 else { return nil }
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(u.ru_utime) + s(u.ru_stime)
    }
}
