package nl.haltewekker.ride

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.Ride
import nl.haltewekker.data.Transit
import nl.haltewekker.live.LiveFeeds
import nl.haltewekker.live.RealPositions
import nl.haltewekker.match.ChooseGPS
import nl.haltewekker.match.Fix
import nl.haltewekker.match.GPSChoice
import nl.haltewekker.match.MapPiece
import nl.haltewekker.match.OnBoardRules
import nl.haltewekker.match.TimedPiece
import nl.haltewekker.match.VehicleGPS
import nl.haltewekker.match.VehicleMatch
import nl.haltewekker.match.VehicleTrack

/**
 * Which bus or train you're on, during a ride: the vehicles running around you (Transitous's live map), each with its
 * own GPS when the open data has a fresh one (OVapi for buses, NS for the planned train), judged on your last fixes by
 * the ported matcher (`VehicleMatch.judgeAll`), with the iOS rules on top: what passed by its own GPS counts over a
 * timetable, a timetable-only fit only while you move like a vehicle (`OnBoardRules.best`, the planned one ranked 45 s
 * better), and its GPS run (`ChooseGPS`). The same one in two looks in a row is the one.
 */
class OnBoardLook {
    companion object { const val CLOSE = 60.0 }

    data class Found(val tripId: String, val line: String, val isTrain: Boolean, val byGPS: Boolean,
                     /** (A7) the others that fit about as well (within a minute): to keep choosing between. */
                     val others: List<RideChoice.Cand> = emptyList(),
                     /** (A7) judged by live data (live times or its own GPS), not only its timetable. */
                     val live: Boolean = true)

    private var lastBest: String? = null
    private var run = GPSChoice()
    private var fits: Map<String, Double> = emptyMap()
    /** (A7) this look's judgements and lines (for the wrong bus's GPS runs and the rivals look). */
    var lastJudged: List<nl.haltewekker.match.Judgement> = emptyList(); private set
    var lastLines: Map<String, String> = emptyMap(); private set

    fun reset() { lastBest = null; run = GPSChoice(); fits = emptyMap() }

    /**
     * `departure`: the moment you left the stop (iOS 0.38 `DepartMatch`: the one that alone left then gets 30 s off),
     * `lines`: your usual lines (`UsualLine`: within 15 s of the best it wins, the planned one still first). `trainsGPS`:
     * NS positions for every train (the rivals look), else only for the planned one. `only`: trains or buses only.
     */
    suspend fun look(fixes: List<Fix>, leg: Ride?, now: Double, realPositions: Boolean,
                     departure: nl.haltewekker.match.Departure? = null, lines: List<nl.haltewekker.match.LineRide> = emptyList(),
                     excluding: Set<String> = emptySet(), trains: Boolean? = null, trainsGPS: Boolean = false): Found? {
        val newest = fixes.maxByOrNull { it.t } ?: return null
        if (!VehicleMatch.enoughFixes(fixes)) return null
        val c = newest.p
        val r = 0.02
        val segs = Transit.vehicles(GeoPoint(c.lat - r, c.lon - r * 1.6), GeoPoint(c.lat + r, c.lon + r * 1.6), back = 150.0, ahead = 90.0, allTrips = true)
        if (segs.isEmpty()) return null
        var tracks = VehicleTrack.group(segs.filter { it.tripId !in excluding && (trains == null || it.isTrain == trains) }.map {
            MapPiece(it.tripId, it.line, it.isTrain, it.realTime, TimedPiece(it.departure, it.arrival, it.path))
        })
        if (realPositions) {
            val buses = LiveFeeds.busFixes()
            val trainFixes = if (leg?.isTrain == true || trainsGPS) LiveFeeds.trainFixes() else emptyMap()
            val legNum = leg?.let { RealPositions.trainNumber(it.num) }
            tracks = tracks.map { t ->
                val num = if (t.tripId == leg?.tripId) legNum else if (trainsGPS && t.isTrain) trainNumbers[t.tripId] else null
                val f = RealPositions.usable(buses, t.tripId, now, RealPositions.MATCH_FRESH)
                    ?: num?.let { n -> trainFixes[n]?.let { RealPositions.usable(it, t.tripId, now, RealPositions.MATCH_FRESH) } }
                if (f != null) t.copy(gps = VehicleGPS(f)) else t
            }
        }
        val judged0 = VehicleMatch.judgeAll(fixes, tracks)
        lastJudged = judged0
        lastLines = tracks.associate { it.tripId to it.line }
        val judged = ChooseGPS.soften(judged0, fits, now)
        fits = ChooseGPS.noteGPSFits(judged0, fits, now)
        val passed = judged.filter { it.cost != null }.map { it.id }
        val (nr, byGps) = ChooseGPS.gpsLook(passed, judged, run, now)
        run = nr
        val speed = if (newest.speed.isFinite() && newest.speed >= 0) newest.speed else 0.0
        // (A7, iOS 0.38) getting on: the one that alone left your stop when you did comes first
        val bonus = departure?.let { d ->
            val clues = tracks.filter { it.tripId in passed }.map { nl.haltewekker.match.DepartMatch.clue(it, d) }
            nl.haltewekker.match.DepartMatch.bonuses(clues, clues.map { it.id })
        } ?: emptyMap()
        val ranked = OnBoardRules.ranked(judged, speed, planned = leg?.tripId, nudge = bonus)
        var best = byGps ?: ranked.firstOrNull()?.id
        // (A7, iOS 0.38) your usual line here at this time, when it fits about as well (never over one by its own GPS)
        if (byGps == null && best != null && best != leg?.tripId && ranked.size > 1) {
            val at = departure?.t ?: now
            val u = nl.haltewekker.match.UsualLine.usual(ranked.mapNotNull { rk -> tracks.firstOrNull { it.tripId == rk.id }?.let { nl.haltewekker.match.UsualLine.Option(it.tripId, it.line, it.isTrain) } },
                nl.haltewekker.match.UsualLine.minute(at, RideChoice.ZONE), nl.haltewekker.match.UsualLine.weekend(at, RideChoice.ZONE), lines)
            val costs = ranked.map { rk -> nl.haltewekker.match.UsualLine.Cand(rk.id, rk.cost, judged.firstOrNull { it.id == rk.id }?.let(ChooseGPS::passedByGPS) ?: false) }
            if (u != null && u != best && nl.haltewekker.match.UsualLine.tieBreak(costs, u, null) == u) {
                nl.haltewekker.logs.FieldLog.match("detect · usual line · ${nl.haltewekker.logs.FieldFormat.label(u, lastLines)} over ${nl.haltewekker.logs.FieldFormat.label(best, lastLines)}")
                best = u
            }
        }
        val sure = best != null && (best == lastBest || byGps != null)
        lastBest = best
        if (!sure || best == null) return null
        val t = tracks.first { it.tripId == best }
        val j = judged.firstOrNull { it.id == best }
        val bestCost = ranked.firstOrNull { it.id == best }?.cost
        val others = if (byGps != null || bestCost == null) emptyList() else ranked
            .filter { it.id != best && it.cost - bestCost <= CLOSE }
            .take(2).mapNotNull { rk -> tracks.firstOrNull { it.tripId == rk.id }?.let { RideChoice.Cand(it.tripId, it.line, it.isTrain) } }
        return Found(t.tripId, t.line, t.isTrain, j?.evidence?.gps == true, others, t.realTime || j?.evidence?.gps == true)
    }

    /** (A7) train numbers of trips seen (from their trip answers), for NS's positions in the rivals look. */
    val trainNumbers = HashMap<String, Int>()

    /** The live arrival of `tripId` at your stop (the trip's stop nearest it), if known. */
    suspend fun arrival(tripId: String, stop: GeoPoint): Double? {
        val t = Transit.trip(tripId, maxAge = 60.0) ?: return null
        val s = t.stops.minByOrNull { Geo.metres(it.point, stop) } ?: return null
        if (Geo.metres(s.point, stop) > 500) return null
        return s.arrival ?: s.departure
    }

    /** (A6, iOS 0.34) when `tripId` leaves its stop near `p` (for whether you made a change). */
    suspend fun departureNear(tripId: String, p: GeoPoint): Double? {
        val t = Transit.trip(tripId, maxAge = 60.0) ?: return null
        val s = t.stops.minByOrNull { Geo.metres(it.point, p) } ?: return null
        if (Geo.metres(s.point, p) > 1500) return null
        return s.departure ?: s.arrival
    }

    /**
     * (A6, iOS 0.33 `noteWakeTrip`) the vehicle's road from where you got on to your stop, and your stop's arrival.
     * (A8, iOS 0.39) also the next stop (not yours), the stop before yours with its time, how late it is at your stop,
     * and whether it came from the copy saved on the phone (`RideCache`: no network).
     */
    data class WakeTrip(val route: List<GeoPoint>, val arrival: Double?, val live: Boolean,
                        val nextStop: String? = null, val before: String? = null, val beforeAt: Double? = null,
                        val delayMin: Int? = null, val saved: Boolean = false, val trip: nl.haltewekker.data.TransitParse.LiveTrip? = null)

    suspend fun wakeTrip(tripId: String, from: GeoPoint?, stop: GeoPoint, here: GeoPoint? = null, now: Double = nl.haltewekker.core.Iso.now(),
                         saved: ((String) -> nl.haltewekker.data.TransitParse.LiveTrip?)? = null): WakeTrip? {
        val fresh = try { Transit.trip(tripId, maxAge = 60.0) } catch (_: Exception) { null }
        val t = fresh ?: saved?.invoke(tripId) ?: return null
        if (t.stops.size < 2) return null
        val mine = t.stops.indices.minByOrNull { Geo.metres(t.stops[it].point, stop) } ?: return null
        if (Geo.metres(t.stops[mine].point, stop) > 1500) return null
        val board = from?.let { f -> (0 until mine).minByOrNull { Geo.metres(t.stops[it].point, f) }?.takeIf { Geo.metres(t.stops[it].point, f) < 1500 } } ?: 0
        val s = t.stops[mine]
        val arrival = if (Geo.metres(s.point, stop) <= 500) (s.arrival ?: s.departure) else null
        fun time(i: Int) = t.stops[i].arrival ?: t.stops[i].departure
        // the next stop: the first after where you are (else by time) and before yours
        val at = here?.let { h -> (board..mine).minByOrNull { Geo.metres(t.stops[it].point, h) } }
        val nextI = ((at?.let { it + 1 } ?: board + 1)..mine).firstOrNull { i -> (time(i) ?: Double.MAX_VALUE) > now - 30 }
        val next = nextI?.takeIf { it < mine }?.let { t.stops[it].name }
        val count = mine - board + 1
        val beforeI = nl.haltewekker.ride.GetReady.before(count)?.let { board + it }
        val sched = s.scheduledDeparture
        val delay = if (t.live && sched != null && arrival != null) Math.round((arrival - sched) / 60).toInt() else null
        return WakeTrip(WakeRoad.cut(t.path, t.stops[board].point, s.point) ?: t.stops.subList(board, mine + 1).map { it.point }, arrival, t.live,
            next, beforeI?.let { t.stops[it].name }, beforeI?.let { time(it) }, delay, fresh == null, t)
    }
}

/** The bit of a trip's road between two of its stops (by where they fall on it), for the distance left along it. */
object WakeRoad {
    fun cut(path: List<GeoPoint>, a: GeoPoint, b: GeoPoint): List<GeoPoint>? {
        if (path.size < 2) return null
        val pa = Geo.project(a, path) ?: return null
        val pb = Geo.project(b, path) ?: return null
        if (pa.crossTrack > 500 || pb.crossTrack > 500 || pb.along <= pa.along) return null
        val out = ArrayList<GeoPoint>()
        Geo.pointAtMetres(pa.along, path)?.let { out.add(it) }
        var acc = 0.0
        for (i in path.indices) {
            if (i > 0) acc += Geo.metres(path[i - 1], path[i])
            if (acc > pa.along && acc < pb.along) out.add(path[i])
        }
        Geo.pointAtMetres(pb.along, path)?.let { out.add(it) }
        return out.takeIf { it.size >= 2 }
    }
}
