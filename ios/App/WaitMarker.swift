import Foundation

/// The bus you're waiting for on the map, and its time (0.40). On the map it sometimes looked as if it was at your
/// stop already, while it still came later (and the time was right). How that happened:
/// - before its trip starts (a layover at the terminus) its times put it at its first stop, and if that's your stop it
///   was drawn there, ten minutes or more before it leaves (or it isn't even there yet: still on its journey before);
/// - its GPS can be the vehicle's previous journey (the vehicle the open data names for this trip is still finishing
///   the one before, or ending it right by your stop), which snaps onto the road at your stop;
/// - moved on from an older fix at its pace (`RealPositions.advance`, 0.37's speed seen) it gets near your stop early.
/// The rule: drawn at (or right by) your stop while its live time there is more than `lead` away doesn't add up. Then
/// it's drawn where its times put it, or, when it really stands at your stop before leaving (its GPS there, and your
/// stop is where its trip starts or its times have it waiting there), at the stop with "Waiting · leaves 17:42"; with
/// nothing to go by (its trip hasn't started and no fix says where it is), it isn't drawn at all (the stop's pin has
/// the time). Plain values (metres along its road), so the rules are tested. Foundation only.
enum WaitMarker {
    /// m: drawn this close to your stop (or past it), it reads as "at the stop".
    static let near: Double = 150
    /// s: its time at your stop further off than this, it isn't at your stop yet.
    static let lead: TimeInterval = 120
    /// m: its GPS fix this close to your stop: it's standing there.
    static let atStop: Double = 35

    enum Label: Equatable, Sendable {
        case none
        case waiting(leaves: Date)          // standing at your stop, leaving at this time
    }

    struct Shown: Equatable, Sendable {
        let metres: Double?                 // where to draw it (nil: not at all)
        let label: Label
    }

    /// Where to draw it. `drawn`: where it would be drawn now (by its GPS or its times, not past your stop before it has
    /// left); `byTime`: where its times put it; `mine`: your stop, metres along; `mineIsFirst`: your stop is where its
    /// trip starts; `started`: its trip has started by its times; `gpsRaw`: its fix (not moved on), metres along, when
    /// it's drawn by its GPS; `waitingByTimes`: its times have it standing at your stop now; `eta`: its (live) time at
    /// your stop, as the card shows it.
    static func place(drawn: Double, byTime: Double, mine: Double, mineIsFirst: Bool, started: Bool, gpsRaw: Double?,
                      waitingByTimes: Bool, eta: Date, now: Date) -> Shown {
        let toGo: TimeInterval = eta.timeIntervalSince(now)
        let nearStop: Bool = drawn >= mine - near
        guard nearStop, toGo > lead else { return Shown(metres: drawn, label: .none) }
        // its own fix is at your stop
        let fixHere: Bool = gpsRaw.map { abs($0 - mine) <= atStop } ?? false
        if fixHere && (mineIsFirst || waitingByTimes) {
            return Shown(metres: mine, label: .waiting(leaves: eta))
        }
        // no fix, but its times have it standing at your stop (a timing stop where it waits)
        if gpsRaw == nil && waitingByTimes && started && !mineIsFirst {
            return Shown(metres: mine, label: .waiting(leaves: eta))
        }
        // where its times put it, when that's well before your stop
        if byTime < mine - near && (started || !mineIsFirst) { return Shown(metres: byTime, label: .none) }
        // its trip hasn't started at your stop and nothing says it's there: where it is isn't known
        if !started { return Shown(metres: nil, label: .none) }
        // its times have it close too: just short of the stop, not at it
        return Shown(metres: max(0, mine - near), label: .none)
    }

    /// "Waiting · leaves 17:42" (`clock` formats the time).
    static func text(_ l: Label, clock: (Date) -> String) -> String? {
        switch l {
        case .none: return nil
        case .waiting(let d): return "Waiting · leaves \(clock(d))"
        }
    }
}
