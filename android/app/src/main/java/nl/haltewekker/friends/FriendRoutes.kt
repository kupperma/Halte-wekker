package nl.haltewekker.friends

import kotlinx.coroutines.flow.MutableStateFlow
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.Transit

/** (A5, iOS 0.31 `FriendRoutes`) The road each friend's bus or train takes, once per vehicle (its live trip's shape), for the map. */
object FriendRoutes {
    val paths = MutableStateFlow<Map<String, List<GeoPoint>>>(emptyMap())
    private val asked = HashSet<String>()

    /** Fetches the shapes not asked for yet (a trip id the live data doesn't know just stays without one). */
    suspend fun load(tripIds: List<String>) {
        for (id in tripIds) {
            if (id.isEmpty() || !synchronized(asked) { asked.add(id) }) continue
            synchronized(asked) { if (asked.size > 200) { asked.clear(); asked.add(id) } }
            val t = Transit.trip(id, 600.0) ?: continue
            if (t.path.size >= 2) paths.value = paths.value + (id to t.path)
        }
    }

    /** The bit a friend rides (a straight line through where they are without a shape). */
    fun route(s: TravelState, all: Map<String, List<GeoPoint>> = paths.value): List<GeoPoint> =
        MapFrame.route(s, s.trip?.let { all[it] } ?: emptyList())
}
