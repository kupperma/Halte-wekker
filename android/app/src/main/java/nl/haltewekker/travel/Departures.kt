package nl.haltewekker.travel

import kotlin.math.floor
import kotlin.math.max

// (A8, iOS 0.40) the departure lists' rules: `GhostDepartures` (each journey once, no cancelled ones, "may not run"),
// `FromStop` (the next departures from the stop you get on at) and `StickyTrips` (the home's next trips don't drop the
// one you're heading for). Plain values, tested with the iOS vectors.

object GhostDepartures {
    const val UNSURE_WITHIN = 15 * 60.0
    const val GONE_AFTER = 60.0
    const val UNSURE_PENALTY = 10 * 60.0
    const val UNSURE_TEXT = "No live info · may not run"
    const val UNSURE_SHORT = "may not run"

    data class Dep(val id: String, val tripId: String, val line: String, val headsign: String, val stop: String, val time: Double,
                   val scheduled: Double, val live: Boolean, val cancelled: Boolean, val vehicle: Boolean = false)

    enum class Status { LIVE, TIMETABLE, UNSURE }

    data class Row(val dep: Dep, val status: Status)

    fun normalized(s: String): String = buildString { for (c in s.lowercase()) if (c.isLetterOrDigit()) append(c) }

    fun sameHeadsign(a: String, b: String): Boolean {
        val x = normalized(a); val y = normalized(b)
        if (x.isEmpty() || y.isEmpty() || x == y) return true
        return x.startsWith(y) || y.startsWith(x)
    }

    fun same(a: Dep, b: Dep): Boolean {
        if (normalized(a.stop) != normalized(b.stop)) return false
        if (a.tripId.isNotEmpty() && a.tripId == b.tripId) return true
        if (normalized(a.line) != normalized(b.line)) return false
        if (floor(a.scheduled / 60).toLong() != floor(b.scheduled / 60).toLong()) return false
        return sameHeadsign(a.headsign, b.headsign)
    }

    fun better(a: Dep, than: Dep): Boolean {
        if (a.live != than.live) return a.live
        if (a.vehicle != than.vehicle) return a.vehicle
        if (a.cancelled != than.cancelled) return !a.cancelled
        return false
    }

    fun dedupe(deps: List<Dep>): List<Dep> {
        val out = ArrayList<Dep>()
        for (d in deps) {
            val i = out.indexOfFirst { same(it, d) }
            if (i >= 0) { if (better(d, out[i])) out[i] = d } else out.add(d)
        }
        return out
    }

    fun liveLines(deps: List<Dep>): Set<String> = deps.filter { it.live && !it.cancelled }.map { normalized(it.line) }.toSet()

    fun status(live: Boolean, vehicle: Boolean, leaves: Double, normallyLive: Boolean, now: Double): Status {
        if (live || vehicle) return if (live) Status.LIVE else Status.TIMETABLE
        if (!normallyLive) return Status.TIMETABLE
        return if (leaves - now <= UNSURE_WITHIN) Status.UNSURE else Status.TIMETABLE
    }

    fun gone(live: Boolean, vehicle: Boolean, scheduled: Double, time: Double, normallyLive: Boolean, now: Double): Boolean {
        if (live || vehicle || !normallyLive) return false
        return now - max(scheduled, time) > GONE_AFTER
    }

    fun rankTime(r: Row) = if (r.status == Status.UNSURE) r.dep.time + UNSURE_PENALTY else r.dep.time

    fun clean(deps: List<Dep>, now: Double, alsoLive: Set<String> = emptySet()): List<Row> {
        val lines = liveLines(deps) + alsoLive.map(::normalized)
        val unique = dedupe(deps).filter { !it.cancelled }
        val rows = ArrayList<Pair<Int, Row>>()
        for ((k, d) in unique.withIndex()) {
            val usual = normalized(d.line) in lines
            if (gone(d.live, d.vehicle, d.scheduled, d.time, usual, now)) continue
            rows.add(k to Row(d, status(d.live, d.vehicle, d.time, usual, now)))
        }
        return rows.sortedWith(compareBy<Pair<Int, Row>> { rankTime(it.second) }.thenBy { it.first }).map { it.second }
    }

    data class Option(val id: String, val line: String, val departs: Double, val scheduled: Double, val live: Boolean,
                      val cancelled: Boolean, val vehicle: Boolean = false)

    fun statuses(options: List<Option>, now: Double, alsoLive: Set<String> = emptySet()): Map<String, Status> {
        val lines = options.filter { it.live && !it.cancelled }.map { normalized(it.line) }.toSet() + alsoLive.map(::normalized)
        return options.associate { o -> o.id to status(o.live, o.vehicle, o.departs, normalized(o.line) in lines, now) }
    }

    fun order(options: List<Option>, now: Double, alsoLive: Set<String> = emptySet()): List<String> {
        val lines = options.filter { it.live && !it.cancelled }.map { normalized(it.line) }.toSet() + alsoLive.map(::normalized)
        val kept = options.filter { o -> !gone(o.live, o.vehicle, o.scheduled, o.departs, normalized(o.line) in lines, now) }
        val st = statuses(kept, now, alsoLive)
        return (kept.filter { st[it.id] != Status.UNSURE } + kept.filter { st[it.id] == Status.UNSURE }).map { it.id }
    }
}

object FromStop {
    const val MAX_USEFUL = 6
    const val MAX_OTHER = 3
    const val SLACK = 30.0

    data class Dep(val id: String, val tripId: String, val line: String, val headsign: String, val time: Double, val scheduled: Double,
                   val live: Boolean, val cancelled: Boolean, val platform: String?, val train: Boolean, val stop: String, val vehicle: Boolean = false)

    data class Row(val dep: Dep, val status: GhostDepartures.Status, val useful: Boolean, val current: Boolean, val reachable: Boolean) {
        val id: String get() = dep.id
        val dimmed: Boolean get() = !reachable
        val switchable: Boolean get() = useful && reachable && !current
        val late: String? get() {
            if (!dep.live) return null
            val m = Math.round((dep.time - dep.scheduled) / 60).toInt()
            return if (m >= 1) "+$m" else if (m <= -1) "$m" else "live"
        }
    }

    data class Board(val useful: List<Row>, val other: List<Row>) { val isEmpty: Boolean get() = useful.isEmpty() && other.isEmpty() }

    fun board(deps: List<Dep>, usefulLines: Set<String>, current: String?, atStop: Double, now: Double, alsoLive: Set<String> = emptySet()): Board {
        val ghost = deps.map { GhostDepartures.Dep(it.id, it.tripId, it.line, it.headsign, it.stop, it.time, it.scheduled, it.live, it.cancelled, it.vehicle) }
        val byId = LinkedHashMap<String, Dep>(); for (d in deps) byId.putIfAbsent(d.id, d)
        val wanted = usefulLines.map(GhostDepartures::normalized).toSet()
        val useful = ArrayList<Row>(); val other = ArrayList<Row>()
        for (r in GhostDepartures.clean(ghost, now, alsoLive)) {
            val d = byId[r.dep.id] ?: continue
            if (d.time - now <= -60) continue
            val isCurrent = current != null && current.isNotEmpty() && current == d.tripId
            val isUseful = isCurrent || GhostDepartures.normalized(d.line) in wanted
            val row = Row(d, r.status, isUseful, isCurrent, d.time + SLACK >= atStop)
            if (isUseful) useful.add(row) else other.add(row)
        }
        var shown = useful.take(MAX_USEFUL)
        val c = useful.firstOrNull { it.current }
        if (c != null && shown.none { it.id == c.id }) shown = shown.take(MAX_USEFUL - 1) + c
        return Board(shown, other.take(MAX_OTHER))
    }

    fun countdown(d: Dep, now: Double): String? {
        val m = floor((d.time - now) / 60).toInt()
        if (m < 1) return "now"
        return if (m < 60) "in $m min" else null
    }

    fun place(d: Dep): String? {
        val p = d.platform?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return if (d.train) "Platform $p" else "Stand $p"
    }
}

object StickyTrips {
    const val LEFT_AFTER = 60.0
    const val HEADING_WITHIN = 5 * 60.0
    const val BRISK = 1.7

    data class Item(val id: String, val firstTrip: String, val departs: Double, val leave: Double, val cancelled: Boolean = false)

    enum class Answer { FAILED, PARTIAL, WHOLE }

    fun toCome(i: Item, now: Double) = !i.cancelled && i.departs + LEFT_AFTER > now

    fun merge(kept: List<Item>, answer: List<Item>, kind: Answer, held: String?, onIt: Boolean = false, now: Double): List<String> {
        val k = if (kind == Answer.WHOLE && answer.isEmpty()) Answer.FAILED else kind
        val out = ArrayList<Item>()
        val seen = HashSet<String>()
        fun add(i: Item) { if (seen.add(i.firstTrip.ifEmpty { i.id })) out.add(i) }
        when (k) {
            Answer.FAILED -> kept.filter { toCome(it, now) }.forEach(::add)
            Answer.PARTIAL -> { answer.filter { toCome(it, now) }.forEach(::add); kept.filter { toCome(it, now) }.forEach(::add) }
            Answer.WHOLE -> {
                answer.filter { toCome(it, now) }.forEach(::add)
                if (!held.isNullOrEmpty() && !onIt) kept.firstOrNull { it.firstTrip == held }?.takeIf { toCome(it, now) }?.let(::add)
            }
        }
        return out.withIndex().sortedWith(compareBy<IndexedValue<Item>> { it.value.leave }.thenBy { it.index }).map { it.value.id }
    }

    fun held(shown: Item?, now: Double): String? = shown?.takeIf { toCome(it, now) }?.firstTrip

    fun pick(items: List<Item>, heldIndex: Int?, reachable: Boolean?, now: Double, grace: Double = 2 * 60.0): Int? {
        if (heldIndex != null && heldIndex in items.indices && toCome(items[heldIndex], now) && items[heldIndex].leave - now <= HEADING_WITHIN) {
            if (reachable == true) return heldIndex
            if (reachable == null && items[heldIndex].leave - now > -grace) return heldIndex
        }
        return items.indexOfFirst { it.leave - now > -grace && !it.cancelled }.takeIf { it >= 0 }
            ?: items.indexOfFirst { it.leave - now > -grace }.takeIf { it >= 0 }
    }

    fun reachable(metres: Double?, departs: Double, now: Double): Boolean? {
        val m = metres ?: return null
        if (!m.isFinite() || m < 0) return null
        return now + m * 1.3 / BRISK <= departs + 30
    }
}

/** (A8, iOS 0.40) the walk to the first stop at your own speed (`WalkPlan`), as the trip cards say it. */
object WalkWords {
    fun shown(t: nl.haltewekker.data.DoorTrip, b: HabitBook): nl.haltewekker.ride.WalkPlan.Shown {
        val v = Habits.walkSpeed(b)
        // (the planner was asked at your learned speed when there is one, `pedestrianSpeed`)
        return nl.haltewekker.ride.WalkPlan.shown(t.first.walkBefore, null, v, b.walks.size, v ?: Habits.PLANNER_WALK)
    }

    fun leave(t: nl.haltewekker.data.DoorTrip, b: HabitBook) = nl.haltewekker.ride.WalkPlan.leave(t.start, shown(t, b))

    fun line(t: nl.haltewekker.data.DoorTrip, b: HabitBook, now: Double): String {
        val m = floor((leave(t, b) - now) / 60).toInt()
        return nl.haltewekker.ride.WalkPlan.words(shown(t, b), if (m < 60) m else null, nl.haltewekker.ui.Fmt.time(leave(t, b)))
    }
}
