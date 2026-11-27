package nl.haltewekker.travel

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.core.a
import nl.haltewekker.core.d
import nl.haltewekker.core.o
import nl.haltewekker.core.obj
import nl.haltewekker.core.s
import nl.haltewekker.core.arr
import nl.haltewekker.core.num
import nl.haltewekker.data.Net
import nl.haltewekker.data.TransitParse

/**
 * (0.10.0, iOS 0.41 `WalkGuideView`'s route) the foot route by OpenStreetMap's public OSRM `foot` profile
 * (routing.openstreetmap.de, light use only): from where you are to the stop, its steps with their maneuver as the
 * arrow (`WalkGuide.Turn.of`, the shape rule as the fallback). Asked at most once per 20 s, the last answer kept per
 * place (~25 m) and stop; nothing but the two coordinates goes with it (the app's User-Agent, no personal data).
 */
object WalkRoute {
    const val URL = "https://routing.openstreetmap.de/routed-foot/route/v1/foot/"

    /** OSRM's step as words: "Turn right onto Hoogstraat", "Head out on Stationsplein", "Arrive". */
    fun words(type: String?, modifier: String?, name: String): String {
        val turn = WalkGuide.Turn.of(type, modifier)
        val on = name.trim()
        return when (type) {
            "depart" -> if (on.isEmpty()) "Start" else "Head out on $on"
            "arrive" -> "Arrive"
            "roundabout", "rotary" -> if (on.isEmpty()) "Take the roundabout" else "Take the roundabout onto $on"
            else -> {
                val w = turn?.words ?: "Straight on"
                if (on.isEmpty()) w else "$w onto $on"
            }
        }
    }

    /** The steps of OSRM's answer (`routes[0].legs[*].steps`), or null when it has no route. */
    fun parse(body: String): List<WalkGuide.RawStep>? {
        val root = TransitParse.json(body).obj ?: return null
        if (root.s("code") != "Ok") return null
        val route = root.a("routes").firstOrNull().obj ?: return null
        val out = ArrayList<WalkGuide.RawStep>()
        for (leg in route.a("legs")) {
            for (st in leg.obj?.a("steps") ?: emptyList()) {
                val o = st.obj ?: continue
                val m = o.o("maneuver")
                val type = m?.s("type")
                val mod = m?.s("modifier")
                val path = o.o("geometry")?.a("coordinates")?.mapNotNull { c ->
                    val xy = c.arr ?: return@mapNotNull null
                    val lon = xy.getOrNull(0).num ?: return@mapNotNull null
                    val lat = xy.getOrNull(1).num ?: return@mapNotNull null
                    GeoPoint(lat, lon)
                } ?: emptyList()
                out.add(WalkGuide.RawStep(words(type, mod, o.s("name") ?: ""), o.d("distance") ?: 0.0, path, WalkGuide.Turn.of(type, mod)))
            }
        }
        return out.takeIf { it.isNotEmpty() }
    }

    private class Kept(val key: String, val route: WalkGuide.Route, val at: Double)
    private var kept: Kept? = null
    private var askedAt = 0.0

    private fun key(from: GeoPoint, to: GeoPoint) =
        "${Math.round(from.lat * 4000)},${Math.round(from.lon * 2500)}>${Math.round(to.lat * 1e5)},${Math.round(to.lon * 1e5)}"

    /** The route from `from` to `to`: the one kept for this place, else asked (at most every 20 s; else null). */
    suspend fun fetch(from: GeoPoint, to: GeoPoint, now: Double = Iso.now()): WalkGuide.Route? {
        val k = key(from, to)
        kept?.let { if (it.key == k && now - it.at < 600) return it.route }
        if (now - askedAt < WalkGuide.REROUTE_EVERY) return null
        askedAt = now
        val url = URL + String.format(java.util.Locale.ROOT, "%.6f,%.6f;%.6f,%.6f", from.lon, from.lat, to.lon, to.lat)
        val a = Net.get(url, listOf("steps" to "true", "geometries" to "geojson", "overview" to "full"))
        val raw = if (a.ok) parse(a.text) else null
        val r = raw?.let { WalkGuide.route(it) }?.takeIf { it.path.size >= 2 } ?: return null
        kept = Kept(k, r, now)
        return r
    }
}
