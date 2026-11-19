package nl.haltewekker.friends

import kotlinx.serialization.Serializable
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import kotlin.math.ceil

// Friends (0.28), the iOS `FriendRides.swift`: the rides you can share, and meeting halfway. Each person's ways (from
// the planner: from their start area to school by their first class, or home after their last) are compared by the
// vehicle: the same trip id on a leg of two people's ways is the same bus or train. Plain values, tested.

/** Walking (iOS `BoardAt`): a third longer by the streets at 1.2 m/s, whole minutes up, at least one. */
object FriendWalk {
    fun minutes(metres: Double): Int = maxOf(1, ceil(maxOf(0.0, metres) * 1.33 / 1.2 / 60).toInt())
}

@Serializable
data class WayLeg(
    val trip: String,
    val mode: String,
    val line: String,
    val num: String? = null,
    val name: String? = null,
    val head: String? = null,
    val from: TripCard.Spot,
    val to: TripCard.Spot,
    val dep: Double,
    val arr: Double,
    val plat: String? = null,
    val walk: Int? = null,
) {
    val isTrain: Boolean get() = mode != "bus"
    val label: String get() = if (isTrain) (num?.let { "$line $it" } ?: line) else "Bus $line"
    val card: TripCard.Ride get() = TripCard.Ride(if (isTrain) "train" else "bus", line, name, num, trip, head, from, to, dep, arr, plat = plat, walk = walk)
}

@Serializable
data class Way(val legs: List<WayLeg>, val start: Double, val end: Double) {
    val changes: Int get() = maxOf(0, legs.size - 1)
}

data class PersonWays(val id: String, val ways: List<Way>, val bound: Double)

data class Rider(val id: String, val way: Int, val leg: Int, val board: TripCard.Spot, val dep: Double, val alight: TripCard.Spot, val arr: Double)

data class SharedRide(val trip: String, val mode: String, val line: String, val num: String?, val riders: List<Rider>) {
    val ids: List<String> get() = riders.map { it.id }
    val isTrain: Boolean get() = mode != "bus"
    val label: String get() = if (isTrain) (num?.let { "$line $it" } ?: line) else "Bus $line"
    val firstDep: Double get() = riders.minOfOrNull { it.dep } ?: Double.NEGATIVE_INFINITY
    fun rider(id: String) = riders.firstOrNull { it.id == id }
}

object SharedRides {
    enum class Direction { TO_SCHOOL, HOME }

    const val SLACK = 45 * 60.0

    fun usable(p: PersonWays, dir: Direction): List<Int> = when (dir) {
        Direction.TO_SCHOOL -> {
            val ok = p.ways.indices.filter { p.ways[it].end <= p.bound + 60 }
            val latest = ok.maxOfOrNull { p.ways[it].end }
            if (latest == null) emptyList() else ok.filter { p.ways[it].end >= latest - SLACK }
        }
        Direction.HOME -> {
            val ok = p.ways.indices.filter { p.ways[it].start >= p.bound - 60 }
            val earliest = ok.minOfOrNull { p.ways[it].start }
            if (earliest == null) emptyList() else ok.filter { p.ways[it].start <= earliest + SLACK }
        }
    }

    fun match(people: List<PersonWays>, dir: Direction): List<SharedRide> {
        val byTrip = LinkedHashMap<String, LinkedHashMap<String, Rider>>()
        val meta = HashMap<String, WayLeg>()
        for (p in people) {
            for (wi in usable(p, dir)) {
                val w = p.ways[wi]
                for ((li, l) in w.legs.withIndex()) {
                    if (l.trip.isEmpty()) continue
                    val r = Rider(p.id, wi, li, l.from, l.dep, l.to, l.arr)
                    val had = byTrip[l.trip]?.get(p.id)
                    if (had != null) {
                        val hw = p.ways[had.way]
                        val better = if (dir == Direction.TO_SCHOOL) w.start > hw.start else w.end < hw.end
                        if (!better) continue
                    }
                    byTrip.getOrPut(l.trip) { LinkedHashMap() }[p.id] = r
                    if (meta[l.trip] == null) meta[l.trip] = l
                }
            }
        }
        val out = mutableListOf<SharedRide>()
        for ((trip, riders) in byTrip) {
            if (riders.size < 2) continue
            val l = meta[trip] ?: continue
            val list = riders.values.sortedWith(compareBy<Rider> { it.dep }.thenBy { it.id })
            out.add(SharedRide(trip, l.mode, l.line, l.num, list))
        }
        return out.sortedWith(Comparator { a, b ->
            if (a.riders.size != b.riders.size) return@Comparator b.riders.size - a.riders.size
            val ta = together(a); val tb = together(b)
            if (ta != tb) return@Comparator tb.compareTo(ta)
            if (a.firstDep != b.firstDep) return@Comparator a.firstDep.compareTo(b.firstDep)
            a.trip.compareTo(b.trip)
        })
    }

    fun together(r: SharedRide): Double {
        val on = r.riders.maxOfOrNull { it.dep } ?: return 0.0
        val off = r.riders.minOfOrNull { it.arr } ?: return 0.0
        return maxOf(0.0, off - on)
    }

    fun shown(all: List<SharedRide>, limit: Int = 3): List<SharedRide> {
        val out = mutableListOf<SharedRide>()
        val sets = mutableListOf<Set<String>>()
        for (r in all) {
            val s = r.ids.toSet()
            if (sets.any { it.containsAll(s) }) continue
            out.add(r); sets.add(s)
            if (out.size >= limit) break
        }
        return out
    }
}

object RideWords {
    fun headline(r: SharedRide): String {
        val first = r.riders.minByOrNull { it.dep } ?: return r.label
        return "${r.label} · ${TimetableDays.hhmm(first.dep)} from ${first.board.name}"
    }

    fun riders(r: SharedRide, name: (String) -> String): String {
        val first = r.riders.minByOrNull { it.dep } ?: return ""
        val parts = r.riders.map { x ->
            val n = name(x.id)
            if (x.board.name == first.board.name) n
            else "$n (${if (n == "you") "get on" else "gets on"} at ${x.board.name} ${TimetableDays.hhmm(x.dep)})"
        }
        return CompareWords.names(parts)
    }

    fun missing(p: PersonDay, dir: SharedRides.Direction, name: String, hasArea: Boolean): String {
        if (!p.known) return "$name hasn’t shared this day"
        if (!p.hasSchool) return "$name: no classes"
        if (!hasArea) return "$name: no start area yet"
        when (dir) {
            SharedRides.Direction.TO_SCHOOL -> p.first?.let { return "$name starts ${TimetableDays.hhmm(it)}" }
            SharedRides.Direction.HOME -> return p.lastEnd?.let { "$name ends ${TimetableDays.hhmm(it)}" } ?: "$name: end time not known"
        }
        return "$name: no ride in common"
    }
}

/** A stop of a bus or train's whole trip (`/v5/trip`). */
data class RouteStop(val name: String, val id: String?, val point: GeoPoint, val dep: Double?, val arr: Double?, val boarding: Boolean = true) {
    val spot: TripCard.Spot get() = TripCard.Spot(name, id, point.lat, point.lon)
}

data class MeetPlan(val kind: Kind, val ride: SharedRide, val ways: Map<String, Way>, val missing: List<String>) {
    sealed class Kind {
        data object SameRide : Kind()
        data class MeetAt(val spot: TripCard.Spot, val at: Double) : Kind()
    }
    val id: String get() = ride.trip + "|" + ride.ids.joinToString(",")
}

data class MeetJoin(val board: Int, val alight: Int, val walkAfter: Int?, val rest: List<WayLeg>)

object MeetHalfway {
    const val BOARD_MARGIN = 3 * 60.0
    const val WALK_FROM = 1500.0
    const val WALK_TO = 900.0
    const val SAME_STOP = 300.0
    const val CHANGE_MARGIN = 3 * 60.0

    fun plans(people: List<PersonWays>): List<MeetPlan> {
        val rides = SharedRides.match(people, SharedRides.Direction.TO_SCHOOL)
        val all = people.map { it.id }
        val out = rides.map { r ->
            val ways = LinkedHashMap<String, Way>()
            for (x in r.riders) {
                val p = people.firstOrNull { it.id == x.id } ?: continue
                if (x.way in p.ways.indices) ways[x.id] = p.ways[x.way]
            }
            MeetPlan(kind(r, ways), r, ways, all.filter { it !in ways })
        }
        val bounds = people.associate { it.id to it.bound }
        return rank(out, bounds)
    }

    fun kind(r: SharedRide, ways: Map<String, Way>): MeetPlan.Kind {
        val first = r.riders.firstOrNull() ?: return MeetPlan.Kind.SameRide
        val oneStop = r.riders.all { it.board.name == first.board.name || near(it.board, first.board, SAME_STOP) }
        val someoneComes = r.riders.any { it.leg > 0 }
        if (!oneStop || !someoneComes || r.riders.size < 2) return MeetPlan.Kind.SameRide
        val arrivals = r.riders.mapNotNull { x ->
            val w = ways[x.id]
            if (x.leg > 0 && w != null && x.leg - 1 in w.legs.indices) w.legs[x.leg - 1].arr else null
        }
        val at = arrivals.maxOrNull() ?: (first.dep - 5 * 60)
        return MeetPlan.Kind.MeetAt(first.board, minOf(at, first.dep))
    }

    fun rank(list: List<MeetPlan>, bounds: Map<String, Double> = emptyMap()): List<MeetPlan> {
        fun waits(p: MeetPlan) = p.ways.entries.sumOf { (id, w) -> maxOf(0.0, (bounds[id] ?: w.end) - w.end) }
        fun changes(p: MeetPlan) = p.ways.values.sumOf { it.changes }
        return list.sortedWith(Comparator { a, b ->
            if (a.missing.size != b.missing.size) return@Comparator a.missing.size - b.missing.size
            if (a.ride.riders.size != b.ride.riders.size) return@Comparator b.ride.riders.size - a.ride.riders.size
            val wa = waits(a); val wb = waits(b)
            if (wa != wb) return@Comparator wa.compareTo(wb)
            val ca = changes(a); val cb = changes(b)
            if (ca != cb) return@Comparator ca - cb
            a.id.compareTo(b.id)
        })
    }

    fun near(a: TripCard.Spot, b: TripCard.Spot, within: Double): Boolean {
        val p = a.point ?: return false
        val q = b.point ?: return false
        return Geo.metres(p, q) <= within
    }

    fun joins(route: List<RouteStop>, ride: SharedRide, start: GeoPoint, dest: GeoPoint, deadline: Double, own: List<Way>, now: Double, limit: Int = 2): List<MeetJoin> {
        if (route.size < 2) return emptyList()
        val lastOff = ride.riders.mapNotNull { index(it.alight, route, -1) }.maxOrNull() ?: (route.size - 1)
        val soonest = now + BOARD_MARGIN + 7 * 60
        val boards = (0 until lastOff).filter { i -> route[i].boarding && (route[i].dep ?: return@filter false) >= soonest }
            .sortedBy { Geo.metres(start, route[it].point) }
        val out = mutableListOf<MeetJoin>()
        for (b in boards) {
            val j = onFrom(route, b, dest, deadline, own) ?: continue
            out.add(j)
            if (out.size >= limit) break
        }
        return out
    }

    fun onFrom(route: List<RouteStop>, b: Int, dest: GeoPoint, deadline: Double, own: List<Way>): MeetJoin? {
        if (b + 1 >= route.size) return null
        val later = ((b + 1) until route.size).toList()
        val off = later.minByOrNull { Geo.metres(dest, route[it].point) }
        if (off != null && Geo.metres(dest, route[off].point) <= WALK_FROM) {
            val arr = route[off].arr ?: route[off].dep
            if (arr != null) {
                val walk = FriendWalk.minutes(Geo.metres(dest, route[off].point))
                if (arr + walk * 60 <= deadline + 60) return MeetJoin(b, off, walk, emptyList())
            }
        }
        for (w in own) {
            if (w.end > deadline + 60) continue
            for ((li, l) in w.legs.withIndex()) {
                val from = l.from.point ?: continue
                for (o in later) {
                    if (Geo.metres(from, route[o].point) > SAME_STOP) continue
                    val arr = route[o].arr ?: route[o].dep ?: continue
                    if (l.dep < arr + CHANGE_MARGIN) continue
                    return MeetJoin(b, o, null, w.legs.subList(li, w.legs.size).toList())
                }
            }
        }
        return null
    }

    fun index(s: TripCard.Spot, route: List<RouteStop>, after: Int): Int? {
        val range = route.indices.filter { it > after }
        if (!s.id.isNullOrEmpty()) range.firstOrNull { route[it].id == s.id }?.let { return it }
        s.point?.let { p -> range.firstOrNull { Geo.metres(p, route[it].point) <= SAME_STOP }?.let { return it } }
        return range.firstOrNull { route[it].name == s.name }
    }

    fun leg(template: WayLeg, route: List<RouteStop>, board: Int, alight: Int, walk: Int?): WayLeg? {
        val dep = route[board].dep ?: return null
        val arr = route[alight].arr ?: route[alight].dep ?: return null
        if (arr < dep) return null
        return template.copy(from = route[board].spot, to = route[alight].spot, dep = dep, arr = arr, plat = null, walk = walk)
    }

    fun joined(j: MeetJoin, template: WayLeg, route: List<RouteStop>, start: GeoPoint, before: Way?, deadline: Double): Way? {
        if (j.board !in route.indices || j.alight !in route.indices) return null
        val dep = route[j.board].dep ?: return null
        val legs = mutableListOf<WayLeg>()
        var startAt: Double
        if (before != null) {
            if (before.end > dep - 60) return null
            legs += before.legs
            startAt = before.start
            legs += leg(template, route, j.board, j.alight, null) ?: return null
        } else {
            val m = Geo.metres(start, route[j.board].point)
            if (m > WALK_TO) return null
            val walk = FriendWalk.minutes(m)
            legs += leg(template, route, j.board, j.alight, walk) ?: return null
            startAt = dep - walk * 60 - 60
        }
        var end = legs.last().arr
        j.walkAfter?.let { end += it * 60 }
        legs += j.rest
        j.rest.lastOrNull()?.let { end = it.arr }
        if (end > deadline + 60 || legs.size > TripCard.MAX_RIDES) return null
        if (startAt > dep) startAt = dep
        return Way(legs, startAt, end)
    }

    fun adding(p: MeetPlan, id: String, way: Way, trip: String): MeetPlan {
        val ways = p.ways + (id to way)
        val missing = p.missing.filter { it != id }
        var riders = p.ride.riders
        val li = way.legs.indexOfFirst { it.trip == trip }
        if (li >= 0) {
            val l = way.legs[li]
            riders = (riders + Rider(id, -1, li, l.from, l.dep, l.to, l.arr)).sortedWith(compareBy<Rider> { it.dep }.thenBy { it.id })
        }
        val ride = p.ride.copy(riders = riders)
        return MeetPlan(kind(ride, ways), ride, ways, missing)
    }

    fun card(w: Way, to: TripCard.Spot, by: Double?, note: String?): TripCard =
        TripCard(w.legs.take(TripCard.MAX_RIDES).map { it.card }, to, null, w.start, w.end, by,
            note?.let { FriendNames.takeChars(ChatText.clean(it), TripCard.MAX_NOTE) })
}

object MeetWords {
    fun title(p: MeetPlan): String = when (val k = p.kind) {
        MeetPlan.Kind.SameRide -> "Same ${if (p.ride.isTrain) "train" else "bus"}: ${p.ride.label} at ${TimetableDays.hhmm(p.ride.firstDep)}"
        is MeetPlan.Kind.MeetAt -> "Meet at ${k.spot.name} ${TimetableDays.hhmm(k.at)}, then ${p.ride.label} together"
    }

    fun way(w: Way): String =
        w.legs.joinToString(", then ") { "${it.label} ${TimetableDays.hhmm(it.dep)} ${it.from.name} → ${it.to.name}" } + " · there ${TimetableDays.hhmm(w.end)}"

    fun note(p: MeetPlan, name: (String) -> String, me: String): String {
        val others = p.ride.riders.filter { it.id != me }.map { "${name(it.id)} gets on at ${it.board.name} ${TimetableDays.hhmm(it.dep)}" }
        var s = "Meet halfway: ${p.ride.label} together"
        if (others.isNotEmpty()) s += " · " + others.joinToString(" · ")
        return FriendNames.takeChars(s, TripCard.MAX_NOTE)
    }
}

/** How many planner questions a compare screen (24) or one meet-halfway search (12) may ask. */
class RequestBudget(val limit: Int) {
    var used = 0
        private set
    val left: Int get() = maxOf(0, limit - used)
    fun take(n: Int = 1): Boolean {
        if (n < 0 || used + n > limit) return false
        used += n
        return true
    }

    companion object {
        const val COMPARE = 24
        const val MEET = 12
    }
}
