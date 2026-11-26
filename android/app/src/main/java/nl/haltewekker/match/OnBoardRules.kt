package nl.haltewekker.match

import nl.haltewekker.core.Geo

/** The home's and the ride's "you're on bus …" rules (iOS `OnBoardRules.swift`, 0.26.1–0.26.2). */
object OnBoardRules {
    const val VEHICLE_SPEED = 8.0                 // m/s: moving like a bus or train
    const val TRAIN_GPS_EDGE = ChooseGPS.CHOOSE_MARGIN

    fun timetableOnly(j: Judgement): Boolean = !j.realTime && j.evidence?.gps != true

    /** As `VehicleMatch.rank`; while a train passed by its own GPS, every train without one comes 30 s later. */
    fun rank(judged: List<Judgement>, planned: String?): List<Ranked> {
        val trainByGPS = judged.any { it.isTrain && ChooseGPS.passedByGPS(it) }
        if (!trainByGPS) return VehicleMatch.rank(judged, planned)
        val edged = judged.map { j ->
            val c = j.cost
            if (!j.isTrain || j.evidence?.gps == true || c == null) j else j.copy(result = Verdict.Pass(c + TRAIN_GPS_EDGE))
        }
        return VehicleMatch.rank(edged, planned)
    }

    /**
     * The one you're on, or null: with one passed by its own GPS, a timetable-only one never comes before it; a
     * timetable-only best counts only while you move like a vehicle. `planned` (the ride's own trip, Android): ranked
     * 45 s better, as the iOS ride's matcher does.
     */
    fun best(judged: List<Judgement>, yourSpeed: Double, planned: String? = null): String? {
        val byId = judged.associateBy { it.id }
        var ranked = rank(judged, planned)
        if (judged.any { ChooseGPS.passedByGPS(it) }) ranked = ranked.filter { r -> byId[r.id]?.let { !timetableOnly(it) } ?: false }
        val first = ranked.firstOrNull() ?: return null
        val j = byId[first.id] ?: return null
        if (timetableOnly(j)) {
            val along = j.evidence?.let { if (it.fixes > 1) it.yourSpeed else maxOf(it.yourSpeed, yourSpeed) } ?: yourSpeed
            if (!along.isFinite() || along < VEHICLE_SPEED) return null
        }
        return first.id
    }

    fun mayAutoStart(tripId: String, idle: Boolean, running: String?, blocked: Set<String>): Boolean =
        idle && running != tripId && tripId !in blocked

    const val TRACK_WINDOW = 60.0
    const val TRACK_SPAN = 20.0
    const val TRACK_ACCURACY = 100.0
    const val TRACK_SPEED = 5.0
    const val TRACK_STEADY = 3.5
    const val TRACK_MARGIN = 100.0

    /** Moving like a bus or train by where your fixes went, not by the GPS's own speed. */
    fun movingByTrack(fixes: List<Fix>, now: Double, speed: Double = TRACK_SPEED): Boolean {
        val w = fixes.filter { f ->
            val age = now - f.t
            age >= -1 && age <= TRACK_WINDOW && f.accuracy.isFinite() && f.accuracy >= 0 && f.accuracy <= TRACK_ACCURACY
        }.sortedBy { it.t }
        if (w.size < 3) return false
        val a = w.first(); val b = w.last()
        val span = b.t - a.t
        if (span < TRACK_SPAN) return false
        val m = w[w.size / 2]
        fun v(p: Fix, q: Fix) = Geo.metres(p.p, q.p) / maxOf(1.0, q.t - p.t)
        val d = Geo.metres(a.p, b.p)
        return d / span >= speed && d > a.accuracy + b.accuracy + TRACK_MARGIN && v(a, m) >= TRACK_STEADY && v(m, b) >= TRACK_STEADY
    }

    const val LOOK_EVERY = 300.0
    const val LOOK_AT_MOST = 20.0

    fun lookDue(startedMoving: Boolean, onBoard: Boolean, movedMetres: Double?, sinceLast: Double?): Boolean {
        if (startedMoving) return true
        if (onBoard || movedMetres == null || !movedMetres.isFinite() || movedMetres <= LOOK_EVERY) return false
        return sinceLast == null || sinceLast >= LOOK_AT_MOST
    }
}

/** The home's on-board look backs off after six empty looks in a row: then every two minutes (iOS `OnBoardBackoff`). */
object OnBoardBackoff {
    const val EMPTY_RUN = 6
    const val SLOW_EVERY = 120.0

    data class State(val empty: Int = 0, val last: Double? = null)

    fun looked(s: State, found: Boolean, now: Double) = State(if (found) 0 else s.empty + 1, now)

    fun holding(s: State, now: Double): Boolean {
        val last = s.last ?: return false
        if (s.empty < EMPTY_RUN) return false
        val age = now - last
        return age >= 0 && age < SLOW_EVERY
    }
}
