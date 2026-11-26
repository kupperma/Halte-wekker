package nl.haltewekker

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.match.Fix
import nl.haltewekker.match.Judgement
import nl.haltewekker.match.Reject
import nl.haltewekker.match.TimedPiece
import nl.haltewekker.match.VehicleTrack
import kotlin.math.cos
import kotlin.math.max

/** The matching tests' world (iOS `MatchFixtures.swift`): a straight east-west railway at 51.59, fixes every 2 s. */
object Fx {
    const val t0 = 1_800_000_000.0

    fun east(m: Double, north: Double = 0.0) = GeoPoint(51.59 + north / 110_540, 4.70 + m / (111_320 * cos(51.59 * Math.PI / 180)))

    val railway = listOf(east(0.0), east(3000.0), east(6900.0))

    fun road(north: Double) = listOf(east(0.0, north), east(3000.0, north), east(6900.0, north))

    fun fixes(from: Double, speed: Double, count: Int, every: Double = 2.0, north: Double = 0.0, accuracy: Double = 20.0,
              course: Double = 90.0, start: Double = t0): List<Fix> = (0 until count).map { k ->
        val dt = k * every
        Fix(start + dt, east(from + speed * dt, north), accuracy, speed, course)
    }

    fun track(id: String, line: String = "IC", train: Boolean = true, live: Boolean = true, path: List<GeoPoint>,
              at: Double, speed: Double, start: Double = t0): VehicleTrack {
        val length = Geo.length(path)
        val v = max(speed, 0.001)
        return VehicleTrack(id, line, train, live, listOf(TimedPiece(start - at / v, start + (length - at) / v, path)))
    }

    fun ok(j: List<Judgement>, id: String): Double? = j.first { it.id == id }.cost
    fun why(j: List<Judgement>, id: String): Reject? = j.first { it.id == id }.why

    fun resource(name: String): ByteArray = Fx::class.java.classLoader!!.getResourceAsStream(name)!!.readBytes()
}
