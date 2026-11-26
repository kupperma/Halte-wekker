package nl.haltewekker.core

import kotlin.math.pow

/** Google's encoded polyline (Transitous's `polyline` and `legGeometry.points`), as iOS `Transit.decodePolyline`. */
object Polyline {
    fun decode(s: String, precision: Int = 5): List<GeoPoint> {
        val scale = 10.0.pow(precision)
        val out = ArrayList<GeoPoint>()
        var lat = 0L
        var lng = 0L
        var i = 0
        val b = s.toByteArray(Charsets.UTF_8)
        while (i < b.size) {
            val vals = LongArray(2)
            for (k in 0..1) {
                var r = 0L
                var sh = 0
                while (i < b.size) {
                    val c = (b[i].toInt() and 0xff) - 63; i++
                    if (sh < 63) r = r or ((c and 0x1f).toLong() shl sh)
                    sh += 5
                    if (c < 0x20) break
                }
                vals[k] = if ((r and 1L) != 0L) (r shr 1).inv() else (r shr 1)
            }
            lat += vals[0]; lng += vals[1]
            out.add(GeoPoint(lat / scale, lng / scale))
        }
        return out
    }
}
