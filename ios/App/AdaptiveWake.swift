import Foundation

// 0.39: adaptive wake-up. The alarm by time (0.33, `WakeRule`) rings N minutes before your stop as you set it. This
// learns, per mode (bus, train), how much time you actually had left once you stopped it: the time from the ring to
// Stop alarm, against the time from the ring to being at your stop. When that's too little time again and again (or the
// bus or train got there before you reacted), it rings a minute earlier next time; with plenty of room left (you
// stopped it at once and had minutes to spare) it comes back a minute towards your setting. Safe by design: it only
// ever adds minutes to your setting (never later than you set it), at most `maxExtra`, one minute per ride, on the
// median of your last rides (one odd ride doesn't move it), ignoring rings far too early or late to say anything. The
// distance rule stays as it was, the safety net. Settings › Trips & alarm shows "Learned: wakes you 1 min earlier",
// with an off switch and a reset. Plain values, so it can be tested.

/// One ring before your stop, as it went.
struct WakeSample: Codable, Equatable, Sendable {
    var train: Bool
    /// Seconds from the ring to Stop alarm; nil: still ringing when you got to your stop (it got there before you reacted).
    var react: Double?
    /// Seconds from the ring to being at your stop.
    var lead: Double
    var at: Date
}

/// What it learned, on this phone only.
struct WakeBook: Codable, Equatable, Sendable {
    var on = true
    var samples: [WakeSample] = []
    var trainExtra = 0              // minutes earlier than your setting, on trains
    var busExtra = 0

    var isEmpty: Bool { samples.isEmpty && trainExtra == 0 && busExtra == 0 }

    func extra(isTrain: Bool) -> Int { isTrain ? trainExtra : busExtra }

    /// A ride's ring noted: kept (the newest `AdaptiveWake.keep` per mode), and the minutes moved a step when its mode's
    /// rides say so. True: the minutes moved.
    @discardableResult mutating func add(_ s: WakeSample) -> Bool {
        guard AdaptiveWake.valid(s) else { return false }
        samples.append(s)
        let mine = samples.filter { $0.train == s.train }
        if mine.count > AdaptiveWake.keep {
            let drop = mine.count - AdaptiveWake.keep
            var dropped = 0
            samples.removeAll { x in
                guard dropped < drop, x.train == s.train else { return false }
                dropped += 1
                return true
            }
        }
        let now = extra(isTrain: s.train)
        let next = AdaptiveWake.step(samples.filter { $0.train == s.train }, extra: now, isTrain: s.train)
        guard next != now else { return false }
        if s.train { trainExtra = next } else { busExtra = next }
        return true
    }
}

enum AdaptiveWake {
    /// Rides kept per mode.
    static let keep = 10
    /// Rides of a mode before it moves anything.
    static let needed = 3
    /// Of those, the newest this many decide (their median).
    static let window = 5
    /// Minutes earlier at most.
    static let maxTrain = 3
    static let maxBus = 2
    /// Seconds you want between stopping it and your stop (your things, the doors).
    static let ready: TimeInterval = 75
    /// Seconds left over that say it may come back a minute.
    static let roomy: TimeInterval = 75 + 150
    /// A ring this soon before the stop, or this long, says nothing about you (GPS, a train held up, a short leg).
    static let leadMin: TimeInterval = 30
    static let leadMax: TimeInterval = 20 * 60

    static func maxExtra(isTrain: Bool) -> Int { isTrain ? maxTrain : maxBus }

    /// A ride that says something: its time to the stop within reason, and a reaction (if any) not far past it.
    static func valid(_ s: WakeSample) -> Bool {
        guard s.lead.isFinite, s.lead >= leadMin, s.lead <= leadMax else { return false }
        if let r = s.react { return r.isFinite && r >= 0 && r <= s.lead + 300 }
        return true
    }

    /// The seconds you had left after stopping it (none when it got there first, or you stopped it after).
    static func spare(_ s: WakeSample) -> Double {
        guard let r = s.react else { return 0 }
        return max(0, s.lead - r)
    }

    /// The minutes after this mode's rides: one minute earlier when the newest rides' median spare time is under
    /// `ready`, one back when it's over `roomy`; otherwise as it is. Within 0…`maxExtra`.
    static func step(_ rides: [WakeSample], extra: Int, isTrain: Bool) -> Int {
        let top = maxExtra(isTrain: isTrain)
        let now = min(top, max(0, extra))
        let mine = rides.filter { $0.train == isTrain && valid($0) }
        guard mine.count >= needed, let m = median(mine.suffix(window).map(spare)) else { return now }
        if m < ready { return min(top, now + 1) }
        if m > roomy { return max(0, now - 1) }
        return now
    }

    /// The minutes the time rule rings at: your setting, and what it learned on top while it's on. Never under your
    /// setting.
    static func minutes(setting: Int, extra: Int, on: Bool, isTrain: Bool) -> Int {
        guard on else { return setting }
        return setting + min(maxExtra(isTrain: isTrain), max(0, extra))
    }

    /// The settings the wake rules go by: yours, with what it learned on top (`minutes`).
    static func effective(_ s: WakeSettings, _ b: WakeBook) -> WakeSettings {
        var e = s
        e.trainMinutes = minutes(setting: s.trainMinutes, extra: b.trainExtra, on: b.on, isTrain: true)
        e.busMinutes = minutes(setting: s.busMinutes, extra: b.busExtra, on: b.on, isTrain: false)
        return e
    }

    /// Settings › Trips & alarm: "Learned: wakes you 1 min earlier on trains", "… 2 min earlier on buses, 1 on trains",
    /// "Learned: as you set it", "Learning: 2 more rides" before it has `needed`; off: "Off".
    static func summary(_ b: WakeBook, by: WakeBy) -> String {
        guard b.on else { return "Off" }
        guard by == .time else { return "Only when waking by time" }
        let t = b.trainExtra, u = b.busExtra
        if t == 0 && u == 0 {
            let most = max(b.samples.filter(\.train).count, b.samples.filter { !$0.train }.count)
            if most < needed {
                let left = needed - most
                return "Learning: \(left) more ride\(left == 1 ? "" : "s")"
            }
            return "Learned: as you set it"
        }
        if t > 0 && u > 0 {
            return t == u ? "Learned: wakes you \(t) min earlier" : "Learned: wakes you \(u) min earlier on buses, \(t) on trains"
        }
        return t > 0 ? "Learned: wakes you \(t) min earlier on trains" : "Learned: wakes you \(u) min earlier on buses"
    }

    private static func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
