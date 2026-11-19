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
    data class Found(val tripId: String, val line: String, val isTrain: Boolean, val byGPS: Boolean)

    private var lastBest: String? = null
    private var run = GPSChoice()
    private var fits: Map<String, Double> = emptyMap()

    fun reset() { lastBest = null; run = GPSChoice(); fits = emptyMap() }

    suspend fun look(fixes: List<Fix>, leg: Ride, now: Double, realPositions: Boolean): Found? {
        val newest = fixes.maxByOrNull { it.t } ?: return null
        if (!VehicleMatch.enoughFixes(fixes)) return null
        val c = newest.p
        val r = 0.02
        val segs = Transit.vehicles(GeoPoint(c.lat - r, c.lon - r * 1.6), GeoPoint(c.lat + r, c.lon + r * 1.6), back = 150.0, ahead = 90.0, allTrips = true)
        if (segs.isEmpty()) return null
        var tracks = VehicleTrack.group(segs.map {
            MapPiece(it.tripId, it.line, it.isTrain, it.realTime, TimedPiece(it.departure, it.arrival, it.path))
        })
        if (realPositions) {
            val buses = LiveFeeds.busFixes()
            val trains = if (leg.isTrain) LiveFeeds.trainFixes() else emptyMap()
            val legNum = RealPositions.trainNumber(leg.num)
            tracks = tracks.map { t ->
                val f = RealPositions.usable(buses, t.tripId, now, RealPositions.MATCH_FRESH)
                    ?: if (t.tripId == leg.tripId && legNum != null) trains[legNum]?.let { RealPositions.usable(it, t.tripId, now, RealPositions.MATCH_FRESH) } else null
                if (f != null) t.copy(gps = VehicleGPS(f)) else t
            }
        }
        val judged0 = VehicleMatch.judgeAll(fixes, tracks)
        val judged = ChooseGPS.soften(judged0, fits, now)
        fits = ChooseGPS.noteGPSFits(judged0, fits, now)
        val passed = judged.filter { it.cost != null }.map { it.id }
        val (nr, byGps) = ChooseGPS.gpsLook(passed, judged, run, now)
        run = nr
        val speed = if (newest.speed.isFinite() && newest.speed >= 0) newest.speed else 0.0
        val best = byGps ?: OnBoardRules.best(judged, speed, planned = leg.tripId)
        val sure = best != null && (best == lastBest || byGps != null)
        lastBest = best
        if (!sure || best == null) return null
        val t = tracks.first { it.tripId == best }
        return Found(t.tripId, t.line, t.isTrain, judged.firstOrNull { it.id == best }?.evidence?.gps == true)
    }

    /** The live arrival of `tripId` at your stop (the trip's stop nearest it), if known. */
    suspend fun arrival(tripId: String, stop: GeoPoint): Double? {
        val t = Transit.trip(tripId, maxAge = 60.0) ?: return null
        val s = t.stops.minByOrNull { Geo.metres(it.point, stop) } ?: return null
        if (Geo.metres(s.point, stop) > 500) return null
        return s.arrival ?: s.departure
    }
}
