package nl.haltewekker.ride

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.Ride
import nl.haltewekker.data.Transit
import nl.haltewekker.data.TransitParse
import nl.haltewekker.live.LiveFeeds
import nl.haltewekker.live.RealPositions
import nl.haltewekker.logs.FieldFormat
import nl.haltewekker.match.ChooseGPS
import nl.haltewekker.match.Fix
import nl.haltewekker.match.MapPiece
import nl.haltewekker.match.OnBoardRules
import nl.haltewekker.match.Ranked
import nl.haltewekker.match.TimedPiece
import nl.haltewekker.match.VehicleGPS
import nl.haltewekker.match.VehicleMatch
import nl.haltewekker.match.VehicleTrack

/**
 * (0.10.3, iOS 0.42.4 `GoStore.candidates` / `takesYouOn`) One look while Fastest trip watches: the vehicles running
 * around you (Transitous's live map), each with its own GPS when the open data has a fresh one, judged on your fixes
 * by the ported matcher; the 4 best as `WaitStart` judges them (by their own GPS or their times, how long that GPS has
 * been with you, the watched ride or its line) and, for those about as good as the best, whether they take you on
 * (their stops, kept 2 minutes per trip).
 */
class WaitLook {
    data class Seen(val cands: List<WaitStart.Candidate>, val ranked: List<Ranked>, val lines: Map<String, String>, val trains: Map<String, Boolean>)

    private val reach = HashMap<String, Pair<Boolean, Double>>()
    private var runs: Map<String, WrongBus.Run> = emptyMap()
    val stops = HashMap<String, Pair<TransitParse.LiveTrip, Double>>()

    fun reset() { reach.clear(); runs = emptyMap(); stops.clear() }

    suspend fun look(fixes: List<Fix>, planned: Ride?, targets: List<GeoPoint>, now: Double, real: Boolean, close: Double): Seen {
        val none = Seen(emptyList(), emptyList(), emptyMap(), emptyMap())
        val newest = fixes.maxByOrNull { it.t } ?: return none
        if (!VehicleMatch.enoughFixes(fixes)) return none
        val c = newest.p
        val r = 0.02
        val segs = Transit.vehicles(GeoPoint(c.lat - r, c.lon - r * 1.6), GeoPoint(c.lat + r, c.lon + r * 1.6), back = 150.0, ahead = 90.0, allTrips = true)
        if (segs.isEmpty()) return none
        var tracks = VehicleTrack.group(segs.map { MapPiece(it.tripId, it.line, it.isTrain, it.realTime, TimedPiece(it.departure, it.arrival, it.path)) })
        if (real) {
            val buses = try { LiveFeeds.busFixes() } catch (_: Exception) { emptyMap() }
            val trainFixes = if (planned?.isTrain == true) try { LiveFeeds.trainFixes() } catch (_: Exception) { emptyMap() } else emptyMap()
            val num = planned?.let { RealPositions.trainNumber(it.num) }
            tracks = tracks.map { t ->
                val f = RealPositions.usable(buses, t.tripId, now, RealPositions.MATCH_FRESH)
                    ?: (if (t.tripId == planned?.tripId) num else null)?.let { n -> trainFixes[n]?.let { RealPositions.usable(it, t.tripId, now, RealPositions.MATCH_FRESH) } }
                if (f != null) t.copy(gps = VehicleGPS(f)) else t
            }
        }
        val judged = VehicleMatch.judgeAll(fixes, tracks)
        runs = WrongBus.note(runs, judged.filter { ChooseGPS.passedByGPS(it) }.map { it.id }, now)
        // the matcher's order, no planned head start (`WaitStart` prefers the planned ride itself); with one by its own
        // GPS, a timetable-only one never comes before it
        var ranked = OnBoardRules.rank(judged, null)
        val byId = judged.associateBy { it.id }
        if (judged.any { ChooseGPS.passedByGPS(it) }) ranked = ranked.filter { rk -> byId[rk.id]?.let { !OnBoardRules.timetableOnly(it) } ?: false }
        val lines = tracks.associate { it.tripId to it.line }
        val trains = tracks.associate { it.tripId to it.isTrain }
        val top = ranked.firstOrNull() ?: return Seen(emptyList(), ranked, lines, trains)
        val out = ArrayList<WaitStart.Candidate>()
        for (rk in ranked.take(4)) {
            val j = byId[rk.id]
            val line = lines[rk.id] ?: ""
            val train = trains[rk.id] ?: false
            val ev = j?.evidence
            val gpsAge = if (ev?.gps == true) ev.gpsAge else null
            val run = runs[rk.id]?.takeIf { now - it.last <= WrongBus.FRESH }
            out.add(WaitStart.Candidate(
                id = rk.id, label = FieldFormat.vehicle(line, rk.id, train), line = line, cost = rk.cost,
                gpsAge = gpsAge, gpsFor = run?.let { it.last - it.first },
                reaches = if (rk.cost <= top.cost + close) takesYouOn(rk.id, newest.p, targets, now) else null,
                planned = planned?.tripId == rk.id,
                plannedLine = planned != null && planned.isTrain == train && WaitStart.sameLine(planned.line, line)))
        }
        return Seen(out, ranked, lines, trains)
    }

    /** Its trip's stops (asked again after a minute). */
    suspend fun trip(id: String, now: Double): TransitParse.LiveTrip? {
        stops[id]?.let { if (now - it.second < 60) return it.first }
        val t = try { Transit.trip(id, maxAge = 60.0) } catch (_: Exception) { null }
        if (t != null) { if (stops.size > 40) stops.clear(); stops[id] = t to now }
        return t ?: stops[id]?.first
    }

    /** The trip takes you on from here (`WaitStart.reaches`); kept 2 minutes per trip; null: its stops couldn't be had. */
    private suspend fun takesYouOn(id: String, here: GeoPoint, targets: List<GeoPoint>, now: Double): Boolean? {
        reach[id]?.let { if (now - it.second < WaitStart.REACH_KEPT) return it.first }
        val t = trip(id, now) ?: return null
        if (t.stops.isEmpty()) return null
        val goes = WaitStart.reaches(stopsOf(t), here, targets, now)
        if (reach.size > 60) reach.clear()
        reach[id] = goes to now
        return goes
    }

    companion object {
        fun stopsOf(t: TransitParse.LiveTrip): List<WaitStart.Stop> = t.stops.map { WaitStart.Stop(it.name, it.point, it.arrival ?: it.departure) }
    }
}
