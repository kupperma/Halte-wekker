package nl.haltewekker.match

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.live.GPSFix
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min

/** One GPS fix. `speed` (m/s) and `course` (degrees) are negative when unknown, as on iOS. `t`: seconds since 1970. */
data class Fix(val t: Double, val p: GeoPoint, val accuracy: Double, val speed: Double, val course: Double)

/** A vehicle's stop-to-stop piece: when it leaves, when it gets to the next stop, and its road between them. */
data class TimedPiece(val departure: Double, val arrival: Double, val path: List<GeoPoint>)

/** A piece as the live map gives it: one trip on it. */
data class MapPiece(val tripId: String, val line: String, val isTrain: Boolean, val realTime: Boolean, val piece: TimedPiece)

/** A vehicle's own GPS: its newest fix in the open data, and the one before it. */
data class VehicleGPS(val fix: GPSFix, val previous: GPSFix? = null)

/** A bus or train: its pieces in departure order, whether its times are live, and its own fresh GPS fix. */
data class VehicleTrack(
    val tripId: String,
    val line: String,
    val isTrain: Boolean,
    val realTime: Boolean,
    val pieces: List<TimedPiece>,
    val gps: VehicleGPS? = null,
) {
    companion object {
        /** One track per trip, in the order the trips first come; a piece that comes twice counts once. */
        fun group(pieces: List<MapPiece>): List<VehicleTrack> {
            val order = ArrayList<String>()
            val first = HashMap<String, MapPiece>()
            val live = HashMap<String, Boolean>()
            val byTrip = HashMap<String, MutableList<TimedPiece>>()
            for (m in pieces) {
                val g = byTrip[m.tripId]
                if (g != null) {
                    if (m.piece !in g) g.add(m.piece)
                    live[m.tripId] = (live[m.tripId] ?: false) || m.realTime
                } else {
                    order.add(m.tripId); first[m.tripId] = m; live[m.tripId] = m.realTime
                    byTrip[m.tripId] = mutableListOf(m.piece)
                }
            }
            return order.map { id ->
                val f = first.getValue(id)
                VehicleTrack(id, f.line, f.isTrain, live[id] ?: false, VehicleMatch.byDeparture(byTrip.getValue(id)))
            }
        }
    }
}

/** What your fixes say about one vehicle (iOS `Evidence`). Metres along its joined path; + offset: ahead of its times. */
data class Evidence(
    val fixes: Int,
    val span: Double,
    val crossTrack: Double,
    val accuracy: Double,
    val shaped: Boolean,
    val progress: Double,
    val offset: Double,
    val drift: Double,
    val yourSpeed: Double,
    val itsSpeed: Double,
    val steady: Boolean,
    val gps: Boolean = false,
    val gpsAge: Double? = null,
    val gpsSpeed: Double? = null,
    val speedKnown: Boolean = true,
    val headingOff: Double? = null,
)

/** Why a vehicle isn't the one you're on. */
enum class Reject {
    TOO_FEW_FIXES, OFF_ITS_PATH, WRONG_WAY, IMPLAUSIBLE_SPEED, STANDING, DRIFTING, TOO_FAR_FROM_TIMES, NO_TIMES;

    /** Not a failure but "not sure yet". */
    val notSure: Boolean get() = this == TOO_FEW_FIXES || this == NO_TIMES
}

/** Swift's `Result<Double, Reject>`: passed at a cost in seconds, or failed with a reason. */
sealed class Verdict {
    data class Pass(val cost: Double) : Verdict()
    data class Fail(val why: Reject) : Verdict()
}

data class Judgement(val id: String, val line: String, val isTrain: Boolean, val realTime: Boolean, val evidence: Evidence?, val result: Verdict) {
    val cost: Double? get() = (result as? Verdict.Pass)?.cost
    val why: Reject? get() = (result as? Verdict.Fail)?.why
}

data class Ranked(val id: String, val cost: Double)

data class SwitchState(val leader: String? = null, val looks: Int = 0, val since: Double? = null)

sealed class Decision {
    data class Keep(val id: String) : Decision()
    data class SwitchTo(val id: String) : Decision()
    data class Undecided(val ids: List<String>) : Decision()
    data object None : Decision()
}

/** Where a vehicle's own GPS puts it on its joined path. */
data class GPSAnchor(val along: Double, val at: Double, val speed: Double, val measured: Double?, val heading: Double?) {
    /** (A6, iOS 0.34) at the speed it was seen going (`measured`, 0.5 m/s or more) for up to 2 minutes. */
    fun position(t: Double): Double {
        val dt = t - at
        val m = measured
        if (m != null && m.isFinite() && m >= 0.5) return along + m * min(VehicleMatch.GPS_ADVANCE_SEEN, max(-VehicleMatch.GPS_ADVANCE_SEEN, dt))
        return along + speed * min(VehicleMatch.GPS_ADVANCE, max(-VehicleMatch.GPS_ADVANCE, dt))
    }
}

/**
 * Which bus or train you're on: the one that moves with you (on its path, going its way, at a possible speed, keeping
 * pace with its own times), compared in seconds off its times. A port of iOS `VehicleMatch.swift` (the judge, the
 * rank and the switch decision), with the same numbers.
 */
object VehicleMatch {
    const val WINDOW = 30.0
    const val MIN_SPAN = 20.0
    const val MIN_FIXES = 3
    const val MAX_ACCURACY = 150.0
    const val OFF_PATH = 60.0
    const val OFF_PATH_UNSHAPED = 250.0
    const val ACCURACY_FACTOR = 1.5
    const val BACKWARDS = 20.0
    const val BUS_MAX = 31.0
    const val SPEED_RATIO = 3.0
    const val STEADY_SHARE = 0.3
    const val DRIFT_MIN = 3.0
    const val DRIFT_SHARE = 0.45
    const val STANDING_MIN = 40.0
    const val STANDING_SHARE = 0.2
    const val COST_SPEED_MIN = 5.0
    const val ONE_FIX_TURN = 75.0
    const val SLACK = 30.0
    const val PASS_SLACK = 20.0
    const val PREFILTER_MARGIN = 300.0
    const val JITTER = 2.0
    const val GPS_FRESH = 90.0
    const val GPS_AHEAD = 60.0
    const val GPS_ADVANCE = 60.0
    const val GPS_ADVANCE_SEEN = nl.haltewekker.live.Advance.MAX_ADVANCE_SEEN
    const val GPS_OFF_ROUTE = 150.0
    const val GPS_SPEED_OF = 5.0
    const val BUS_MAX_SPEED_BY_TIMES = 30.0      // RealPositions.maxSpeed on iOS

    fun tolerance(isTrain: Boolean, speed: Double): Double {
        val v = max(0.0, speed)
        return if (isTrain) min(2500.0, max(600.0, v * 60)) else min(1000.0, max(400.0, v * 45))
    }

    fun timePosition(v: VehicleTrack, t: Double): Double? = Joined(v.pieces).position(t)

    fun evidence(fixes: List<Fix>, v: VehicleTrack): Evidence? = (gather(fixes, v) as? Gathered.Ok)?.e

    private sealed class Gathered {
        data class Ok(val e: Evidence) : Gathered()
        data class No(val why: Reject) : Gathered()
    }

    private class Row(val t: Double, val along: Double, val cross: Double, val at: Double, val accuracy: Double, val connector: Boolean)

    private fun gather(fixes: List<Fix>, v: VehicleTrack): Gathered {
        val good = fixes.filter(::usable)
        val newest = good.maxOfOrNull { it.t } ?: return Gathered.No(Reject.TOO_FEW_FIXES)
        val j = Joined(v.pieces)
        val anchor = v.gps?.let { g -> if (gpsFits(g, newest)) j.anchor(g, v.isTrain) else null }
        val rows = ArrayList<Row>()
        var timed = 0
        var previous: Double? = null
        var newestBeyond = false
        val inWindow = good.sortedBy { it.t }.filter { newest - it.t <= WINDOW }
        for (f in inWindow) {
            val at = anchor?.position(f.t) ?: j.position(f.t)
            if (at != null) timed++
            newestBeyond = false
            val p = j.pass(f.p, at ?: previous, max(PASS_SLACK, f.accuracy), previous) ?: continue
            val away = beyondAnEnd(p.projection.crossTrack, f.accuracy)
            if (p.beforeStart && away) continue
            newestBeyond = p.beyondEnd && away && f.speed.isFinite() && f.speed >= 3
            previous = p.projection.along
            if (at == null) continue
            rows.add(Row(f.t, p.projection.along, p.projection.crossTrack, at, f.accuracy, p.connector))
        }
        if (timed == 0) return Gathered.No(Reject.NO_TIMES)
        if (newestBeyond) return Gathered.No(Reject.OFF_ITS_PATH)
        if (rows.size < 2) return Gathered.No(Reject.TOO_FEW_FIXES)
        val first = rows.first()
        val last = rows.last()
        val span = last.t - first.t
        val offset = last.along - last.at
        var from = listOf(first)
        var to = listOf(last)
        var time = span
        if (rows.size >= 6) {
            val middle = rows[rows.size - 2].t - rows[1].t
            if (middle > 0 && middle >= span / 2) { from = rows.take(3); to = rows.takeLast(3); time = middle }
        }
        val progress = median(to.map { it.along }) - median(from.map { it.along })
        val drift = median(to.map { it.along - it.at }) - median(from.map { it.along - it.at })
        fun per(x: Double, t: Double) = if (t > 0) x / t else 0.0
        val recent = rows.takeLast(3)
        var e = Evidence(
            fixes = rows.size, span = span,
            crossTrack = median(recent.map { it.cross }), accuracy = median(rows.map { it.accuracy }),
            shaped = v.pieces.any { it.path.size > 2 } && recent.none { it.connector },
            progress = progress, offset = offset, drift = per(drift, time),
            yourSpeed = per(abs(progress), time), itsSpeed = per(last.at - first.at, span),
            steady = steady(rows.map { it.t to it.along }),
        )
        val g = v.gps
        if (anchor != null && g != null) {
            val its = anchor.measured ?: anchor.speed
            e = e.copy(
                gps = true, gpsAge = newest - g.fix.at, gpsSpeed = anchor.measured,
                speedKnown = anchor.measured != null && g.fix.at >= first.t - GPS_SPEED_OF,
                itsSpeed = its, drift = per(progress, time) - its,
                headingOff = heading(inWindow)?.let { yours -> anchor.heading?.let { Geo.angle(yours, it) } },
            )
        }
        val numbers = listOf(e.span, e.crossTrack, e.accuracy, e.progress, e.offset, e.drift, e.yourSpeed, e.itsSpeed)
        return if (numbers.all { it.isFinite() }) Gathered.Ok(e) else Gathered.No(Reject.NO_TIMES)
    }

    fun gpsFits(g: VehicleGPS, newest: Double): Boolean {
        val age = newest - g.fix.at
        return age.isFinite() && age <= GPS_FRESH && age >= -GPS_AHEAD
    }

    private fun heading(sorted: List<Fix>): Double? {
        val f = sorted.lastOrNull()
        if (f != null && f.course.isFinite() && f.course in 0.0..360.0 && f.speed.isFinite() && f.speed >= 3) return f.course
        val a = sorted.firstOrNull() ?: return null
        val b = sorted.lastOrNull() ?: return null
        return if (Geo.metres(a.p, b.p) >= 20) Geo.bearing(a.p, b.p) else null
    }

    /** The hard tests, in order: the first one failed is the reason (iOS `judge`). */
    fun judge(e: Evidence, isTrain: Boolean, realTime: Boolean, strictTimes: Boolean = true,
              minFixes: Int = MIN_FIXES, minSpan: Double = MIN_SPAN): Verdict {
        val byTimes = strictTimes || realTime || e.gps
        val bySpeed = byTimes && e.speedKnown
        if (e.fixes < minFixes || e.span < minSpan) return Verdict.Fail(Reject.TOO_FEW_FIXES)
        val off = max(if (e.shaped) OFF_PATH else OFF_PATH_UNSHAPED, ACCURACY_FACTOR * e.accuracy)
        if (!(e.crossTrack <= off)) return Verdict.Fail(Reject.OFF_ITS_PATH)
        if (!(e.progress >= -max(BACKWARDS, JITTER * e.accuracy))) return Verdict.Fail(Reject.WRONG_WAY)
        if (!isTrain && !(e.yourSpeed <= BUS_MAX)) return Verdict.Fail(Reject.IMPLAUSIBLE_SPEED)
        if (bySpeed && e.steady && e.itsSpeed >= COST_SPEED_MIN && e.yourSpeed < e.itsSpeed / SPEED_RATIO) return Verdict.Fail(Reject.IMPLAUSIBLE_SPEED)
        if (byTimes) {
            if (bySpeed && abs(e.progress) >= max(STANDING_MIN, JITTER * e.accuracy) && e.itsSpeed < STANDING_SHARE * e.yourSpeed) {
                return Verdict.Fail(Reject.STANDING)
            }
            if (bySpeed && e.steady && abs(e.drift) > max(DRIFT_MIN, DRIFT_SHARE * e.yourSpeed)) return Verdict.Fail(Reject.DRIFTING)
            // (A6, iOS 0.34) by its own GPS, an older fix has more room
            val room = if (e.gps) nl.haltewekker.live.Advance.ageSlack(e.gpsAge ?: 0.0, e.itsSpeed) else 0.0
            if (!(abs(e.offset) <= tolerance(isTrain, e.yourSpeed) + room)) return Verdict.Fail(Reject.TOO_FAR_FROM_TIMES)
        }
        return Verdict.Pass(cost(e.offset, e.itsSpeed))
    }

    fun judgeAll(fixes: List<Fix>, vs: List<VehicleTrack>, strictTimes: Boolean = true, prefilter: Boolean = true,
                 minFixes: Int = MIN_FIXES, minSpan: Double = MIN_SPAN): List<Judgement> {
        val recent = if (prefilter) lastWindow(fixes) else emptyList()
        return vs.map { v ->
            if (recent.isNotEmpty() && !nearPath(recent, v)) {
                return@map Judgement(v.tripId, v.line, v.isTrain, v.realTime, null, Verdict.Fail(Reject.OFF_ITS_PATH))
            }
            when (val g = gather(fixes, v)) {
                is Gathered.Ok -> Judgement(v.tripId, v.line, v.isTrain, v.realTime, g.e,
                    judge(g.e, v.isTrain, v.realTime, strictTimes, minFixes, minSpan))
                is Gathered.No -> Judgement(v.tripId, v.line, v.isTrain, v.realTime, null, Verdict.Fail(g.why))
            }
        }
    }

    /** The ones that passed, best first: cost in seconds, the planned one `plannedBonus` seconds less; ties by id. */
    fun rank(judged: List<Judgement>, planned: String?, plannedBonus: Double = 45.0): List<Ranked> =
        judged.mapNotNull { j -> j.cost?.let { Ranked(j.id, if (j.id == planned) it - plannedBonus else it) } }
            .sortedWith(compareBy<Ranked> { it.cost }.thenBy { it.id })

    /** Which one to show, with hysteresis (iOS `decide`). Returns the decision and the new state. */
    fun decide(shown: String?, ranked: List<Ranked>, liveIds: Set<String>, unsure: Set<String> = emptySet(), state: SwitchState,
               now: Double, margin: Double = 60.0, looks: Int = 3, span: Double = 45.0): Pair<Decision, SwitchState> {
        val best = ranked.firstOrNull() ?: return (if (shown != null) Decision.Keep(shown) else Decision.None) to SwitchState()
        if (shown == null) {
            if (ranked.size <= 1) return Decision.SwitchTo(best.id) to SwitchState()
            val second = ranked[1]
            val bothLive = best.id in liveIds && second.id in liveIds
            if (bothLive && second.cost - best.cost >= margin) return Decision.SwitchTo(best.id) to SwitchState()
            val running = ranked.take(3).filter { !bothLive || it.cost - best.cost < margin }
            return Decision.Undecided(running.map { it.id }) to state
        }
        if (best.id == shown) return Decision.Keep(shown) to SwitchState()
        val mine = ranked.firstOrNull { it.id == shown }
        if (mine != null) {
            val bothLive = shown in liveIds && best.id in liveIds
            if (!bothLive || mine.cost - best.cost < margin) return Decision.Keep(shown) to SwitchState()
        } else if (shown in unsure) {
            return Decision.Keep(shown) to SwitchState()
        }
        var s = if (state.leader == best.id && state.since != null) state.copy(looks = state.looks + 1)
        else SwitchState(best.id, 1, now)
        if (s.looks >= looks && s.since != null && now - s.since!! >= span) return Decision.SwitchTo(best.id) to SwitchState()
        return Decision.Keep(shown) to s
    }

    /** Enough fixes to judge by: of the usable ones of the last 30 s, at least 3 spanning 20 s. */
    fun enoughFixes(fixes: List<Fix>): Boolean {
        val recent = lastWindow(fixes)
        val newest = recent.maxOfOrNull { it.t } ?: return false
        val oldest = recent.minOf { it.t }
        return recent.size >= MIN_FIXES && newest - oldest >= MIN_SPAN
    }

    /** The ones with live times or a GPS fix that was judged by (for `decide`). */
    fun liveIds(judged: List<Judgement>): Set<String> = judged.filter { it.realTime || it.evidence?.gps == true }.map { it.id }.toSet()

    /**
     * A failure by its times alone, with its road and your way along it fitting: drifting, standing, too far from its
     * times, or a speed its times don't fit (not a bus faster than a bus can go). Not one judged by its own GPS.
     */
    fun timesOnly(j: Judgement): Boolean {
        val why = j.why ?: return false
        if (j.evidence?.gps == true) return false
        return when (why) {
            Reject.DRIFTING, Reject.STANDING, Reject.TOO_FAR_FROM_TIMES -> true
            Reject.IMPLAUSIBLE_SPEED -> j.isTrain || (j.evidence?.let { it.yourSpeed <= BUS_MAX } ?: false)
            else -> false
        }
    }

    // MARK: helpers

    private fun beyondAnEnd(crossTrack: Double, accuracy: Double) = crossTrack > max(PASS_SLACK, accuracy)

    internal fun lastWindow(fixes: List<Fix>): List<Fix> {
        val good = fixes.filter(::usable)
        val newest = good.maxOfOrNull { it.t } ?: return emptyList()
        return good.filter { newest - it.t <= WINDOW }
    }

    private fun nearPath(fixes: List<Fix>, v: VehicleTrack): Boolean {
        var south = Double.POSITIVE_INFINITY; var north = Double.NEGATIVE_INFINITY
        var west = Double.POSITIVE_INFINITY; var east = Double.NEGATIVE_INFINITY
        for (piece in v.pieces) for (p in piece.path) if (p.lat.isFinite() && p.lon.isFinite()) {
            south = min(south, p.lat); north = max(north, p.lat); west = min(west, p.lon); east = max(east, p.lon)
        }
        if (!(south <= north && west <= east)) return true
        val dLat = PREFILTER_MARGIN / 110_540
        val c = cos(max(abs(south), abs(north)) * Math.PI / 180)
        if (!(c > 0.01)) return true
        val dLon = PREFILTER_MARGIN / (111_320 * c)
        return fixes.any { it.p.lat >= south - dLat && it.p.lat <= north + dLat && it.p.lon >= west - dLon && it.p.lon <= east + dLon }
    }

    private fun usable(f: Fix) = f.accuracy.isFinite() && f.accuracy >= 0 && f.accuracy <= MAX_ACCURACY && f.p.lat.isFinite() && f.p.lon.isFinite()

    private fun cost(offset: Double, itsSpeed: Double) = abs(offset) / max(COST_SPEED_MIN, itsSpeed)

    private fun median(xs: List<Double>): Double {
        val s = xs.sorted()
        if (s.isEmpty()) return 0.0
        return if (s.size % 2 == 1) s[s.size / 2] else (s[s.size / 2 - 1] + s[s.size / 2]) / 2
    }

    private fun steady(rows: List<Pair<Double, Double>>): Boolean {
        val first = rows.firstOrNull() ?: return false
        val last = rows.last()
        val half = (last.first - first.first) / 2
        if (!(half > 0)) return false
        val mid = first.first + half
        var atMid = last.second
        for (i in 1 until rows.size) {
            if (rows[i].first >= mid) {
                val a = rows[i - 1]; val b = rows[i]; val dt = b.first - a.first
                atMid = if (dt > 0) a.second + (b.second - a.second) * (mid - a.first) / dt else b.second
                break
            }
        }
        val v1 = abs(atMid - first.second) / half
        val v2 = abs(last.second - atMid) / half
        if (!v1.isFinite() || !v2.isFinite() || v1 < DRIFT_MIN || v2 < DRIFT_MIN) return false
        return abs(v1 - v2) <= STEADY_SHARE * max(v1, v2)
    }

    fun byDeparture(pieces: List<TimedPiece>): List<TimedPiece> =
        pieces.withIndex().sortedWith(compareBy<IndexedValue<TimedPiece>> { it.value.departure }
            .thenBy { it.value.arrival }.thenBy { it.index }).map { it.value }

    /** A vehicle's pieces joined into one path; pieces that don't meet are joined by a straight connector. */
    private class Joined(given: List<TimedPiece>) {
        val pieces = byDeparture(given)
        val starts = ArrayList<Double>()
        val lengths = ArrayList<Double>()
        val path = ArrayList<GeoPoint>()
        val connectors = HashSet<Int>()

        init {
            var total = 0.0
            for (p in pieces) {
                val end = path.lastOrNull()
                val begin = p.path.firstOrNull()
                if (end != null && begin != null) {
                    total += Geo.metres(end, begin)
                    if (end != begin) connectors.add(path.size - 1)
                }
                val l = Geo.length(p.path)
                starts.add(total); lengths.add(l)
                total += l
                path.addAll(p.path)
            }
        }

        class Found(val projection: Geo.Projection, val connector: Boolean, val beforeStart: Boolean, val beyondEnd: Boolean)

        fun pass(p: GeoPoint, near: Double?, within: Double, previous: Double? = null): Found? {
            val f = Geo.pass(p, path, near, within, previous) ?: return null
            return Found(f.projection, f.segment in connectors, f.beforeStart, f.beyondEnd)
        }

        fun position(t: Double): Double? {
            if (pieces.isEmpty()) return null
            val k = pieces.indexOfLast { it.departure <= t && t <= it.arrival }
            if (k >= 0) {
                val p = pieces[k]; val d = p.arrival - p.departure
                if (!(d > 0)) return starts[k] + lengths[k]
                return starts[k] + lengths[k] * min(1.0, max(0.0, (t - p.departure) / d))
            }
            val n = pieces.indexOfFirst { it.departure > t }
            if (n >= 0) {
                if (n == 0) return if (t >= pieces[0].departure - SLACK) starts[0] else null
                val from = starts[n - 1] + lengths[n - 1]; val to = starts[n]
                val a = pieces[n - 1].arrival; val d = pieces[n].departure - a
                if (!(d > 0)) return to
                return from + (to - from) * min(1.0, max(0.0, (t - a) / d))
            }
            val last = pieces.size - 1
            return if (t <= pieces[last].arrival + SLACK) starts[last] + lengths[last] else null
        }

        fun anchor(g: VehicleGPS, isTrain: Boolean): GPSAnchor? {
            val f = g.fix
            val p = pass(f.point, position(f.at), 30.0) ?: return null
            val cross = p.projection.crossTrack
            if (!cross.isFinite() || cross > GPS_OFF_ROUTE) return null
            if ((p.beforeStart || p.beyondEnd) && cross > PASS_SLACK) return null
            val along = p.projection.along
            val k = starts.indices.firstOrNull { along <= starts[it] + lengths[it] } ?: (pieces.size - 1)
            val cap = if (isTrain) 45.0 else BUS_MAX_SPEED_BY_TIMES
            val d = pieces[k].arrival - pieces[k].departure
            val pieceSpeed = if (lengths[k] > 0) min(cap, lengths[k] / max(1.0, d)) else 0.0
            var measured: Double? = null
            val s = f.speed
            if (s != null && s.isFinite() && s >= 0) {
                measured = min(s, 60.0)
            } else {
                val q = g.previous
                if (q != null) {
                    val dt = f.at - q.at
                    if (dt in 5.0..180.0) {
                        val pq = pass(q.point, along - pieceSpeed * dt, 30.0)
                        if (pq != null && pq.projection.crossTrack <= GPS_OFF_ROUTE) {
                            val v = (along - pq.projection.along) / dt
                            if (v.isFinite() && v >= -3) measured = min(60.0, max(0.0, v))
                        }
                    }
                }
            }
            return GPSAnchor(along, f.at, pieceSpeed, measured, f.bearing ?: p.projection.bearing)
        }
    }
}
