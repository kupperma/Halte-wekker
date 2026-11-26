import Foundation

/// 0.42.3: a leg shorter than the wake distance (a bus hop of a few hundred metres to the station). In a field log of
/// 27 November the alarm rang 30 s into a 530 m first leg: no fix had come in its first 20 s, so the first one, already
/// inside the wake distance, rang it. Now such a leg doesn't ring at the start: it's awake from the start, says "Get off
/// at the next stop" quietly about one stop before (or a minute and a half before it's in, or halfway there), and the
/// announcement comes at the stop. Nothing rings in the first minute of any leg; a normal leg's alarm still always
/// rings (at most that much later). Plain values, so it can be tested.
enum ShortLeg {
    /// s: nothing rings this soon after the leg started (you just got on).
    static let noRingFor: TimeInterval = 60
    /// s: within this of the leg's start a firing wake rule wakes it silently, as a leg that starts inside its wake
    /// distance (as before 0.42.3).
    static let startWindow: TimeInterval = 20
    /// s: the quiet notice this long before the arrival, by its times.
    static let noticeBefore: TimeInterval = 90
    /// m: on a short leg you're at the stop within this (or half the way you started from, if less), never under
    /// `arriveLeast`.
    static let arriveMost: Double = 450
    static let arriveLeast: Double = 200

    /// m: a leg this short is a hop (a minute or two on a bus) whatever the wake distance.
    static let hop: Double = 800

    /// A leg shorter than its wake: its two ends `spanMetres` apart within the wake distance, or a hop (`hop`).
    static func isShort(spanMetres: Double?, wakeMetres: Double) -> Bool {
        guard let s = spanMetres, s.isFinite, s >= 0 else { return false }
        let w: Double = wakeMetres.isFinite ? max(0, wakeMetres) : 0
        return s <= max(w, hop)
    }

    enum OnFire: Equatable, Sendable {
        /// Ring it (the alarm, or a notification with the phone in use).
        case ring
        /// Awake without the alarm: the quiet notice before the stop and the announcement at it.
        case quiet
        /// Not yet: the leg is under a minute old; the next fix after that decides.
        case wait
    }

    /// The wake rule fires on a good fix `legAge` seconds into a sleeping leg. A short leg (`isShort`): quiet. Within
    /// `startWindow`: quiet, as a leg that starts inside its wake distance (as before). Else under `noRingFor`: wait;
    /// after that: ring.
    static func onFire(legAge: TimeInterval, short: Bool) -> OnFire {
        if short { return .quiet }
        if legAge < startWindow { return .quiet }
        if legAge < noRingFor { return .wait }
        return .ring
    }

    /// The quiet "Get off at the next stop" on a short leg: once, not in its first minute, when the stop before yours
    /// is reached by its times (`beforeReached`), it's in within `noticeBefore` by them (`secondsLeft`), or (no times)
    /// you're halfway from where you started (`metres` of `startedMetres`).
    static func noticeDue(legAge: TimeInterval, told: Bool, beforeReached: Bool, secondsLeft: Double?, metres: Double?,
                          startedMetres: Double?) -> Bool {
        guard !told, legAge >= noRingFor else { return false }
        if beforeReached { return true }
        if let s = secondsLeft, s.isFinite { return s <= noticeBefore }
        if let m = metres, let st = startedMetres, m.isFinite, st.isFinite, st > 0 { return m <= st / 2 }
        return false
    }

    /// How near the stop counts as there on a short leg (`arriveMost` at most, half the way you started from,
    /// `arriveLeast` at least): a leg that starts 380 m from its stop isn't "there" on its first fix.
    static func arriveMetres(startedMetres: Double?) -> Double {
        guard let s = startedMetres, s.isFinite, s > 0 else { return arriveMost }
        return min(arriveMost, max(arriveLeast, s / 2))
    }

    /// On a short leg, the stop is announced only after its first minute, within `arriveMetres`.
    static func mayArrive(legAge: TimeInterval, metres: Double, startedMetres: Double?) -> Bool {
        legAge >= noRingFor && metres <= arriveMetres(startedMetres: startedMetres)
    }

    /// "Get off at the next stop" / "Breda is next. A short ride: this is your reminder, no alarm."
    static func words(stop: String) -> (title: String, body: String) {
        let s = stop.trimmingCharacters(in: .whitespaces)
        let name: String = s.isEmpty ? "Your stop" : s
        return ("Get off at the next stop", "\(name) is next. A short ride: this is your reminder, no alarm.")
    }
}
