package nl.haltewekker.friends

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

// Friends (0.26), the iOS `FriendTravel.swift`: "Travelling now" as plain values. While a trip runs and you're confirmed
// on board, each friend you show your trips to gets a `travel` box every minute and when the leg changes, through the
// relay's state routes; it's taken back when the trip ends. Nothing is sent when no trip runs.

/** The body of a `travel` box. Times are unix seconds. */
@Serializable
data class TravelState(
    /** "riding", "waiting" or "change" (unknown reads as riding). */
    val state: String,
    /** "train" or "bus" (a newer app may add "tram", "metro", "ferry"). */
    val mode: String,
    val line: String? = null,
    val num: String? = null,
    val trip: String? = null,
    val from: Spot,
    val to: Spot,
    val dest: Spot? = null,
    val eta: Double? = null,
    val end: Double? = null,
    val pos: Position? = null,
    val leg: Int? = null,
    val legs: Int? = null,
    val coach: Coach? = null,
) {
    @Serializable data class Spot(val name: String, val lat: Double? = null, val lon: Double? = null)
    @Serializable data class Position(val lat: Double, val lon: Double, val acc: Double? = null, val at: Double)
    /** Coach `n` of `of`: counted from the front when `front`, else from the left of NS's drawing at station `at`. */
    @Serializable data class Coach(val n: Int, val of: Int, val front: Boolean, val at: String? = null)

    enum class Stage { RIDING, WAITING, CHANGE }

    val stage: Stage get() = when (state) { "waiting" -> Stage.WAITING; "change" -> Stage.CHANGE; else -> Stage.RIDING }
    val isTrain: Boolean get() = mode == "train"
}

/** A friend's state as read from the relay: their signed time (never later than the relay got it) and its expiry. */
data class FriendTravelSeen(val from: String, val state: TravelState, val sent: Double, val exp: Double)

enum class TravelFreshness { FRESH, STALE, GONE }

object TravelAge {
    const val FRESH_FOR = 150.0
    const val SHOW_FOR = 600.0
    const val PAST_END = 20 * 60.0
    const val TTL = 360
    const val EVERY = 55.0

    fun freshness(sent: Double, exp: Double?, end: Double?, now: Double): TravelFreshness {
        if (exp != null && exp <= now) return TravelFreshness.GONE
        if (end != null && now - end > PAST_END) return TravelFreshness.GONE
        val age = now - sent
        if (age > SHOW_FOR) return TravelFreshness.GONE
        return if (age <= FRESH_FOR) TravelFreshness.FRESH else TravelFreshness.STALE
    }

    fun freshness(s: FriendTravelSeen, now: Double) = freshness(s.sent, s.exp, s.state.end ?: s.state.eta, now)

    fun due(last: Double?, now: Double): Boolean = last == null || now - last >= EVERY
}

/** When your trip is shared, and with whom. */
object TravelShareRules {
    data class Signals(
        val running: Boolean = false,
        val demo: Boolean = false,
        val startedByHand: Boolean = false,
        val vehicleMatched: Boolean = false,
        val pickedByHand: Boolean = false,
    )

    /** Confirmed on board for this trip: once it is, it stays so until the trip ends. */
    fun confirmed(before: Boolean, s: Signals): Boolean {
        if (!s.running || s.demo) return false
        return before || s.startedByHand || s.vehicleMatched || s.pickedByHand
    }

    sealed class Decision {
        data class Share(val to: List<String>) : Decision()
        data object Clear : Decision()
        data object Ask : Decision()
        data object None : Decision()
    }

    /** `consent`: the one-time screen's answer (null: not asked yet). `friends`: each and their "Show my trips". */
    fun decide(consent: Boolean?, paused: Boolean, confirmed: Boolean, friends: List<Pair<String, Boolean>>, sentBefore: Boolean): Decision {
        val stop = if (sentBefore) Decision.Clear else Decision.None
        if (!confirmed || friends.isEmpty()) return stop
        if (consent == null) return if (sentBefore) Decision.Clear else Decision.Ask
        if (!consent || paused) return stop
        val to = recipients(friends)
        return if (to.isEmpty()) stop else Decision.Share(to)
    }

    fun recipients(friends: List<Pair<String, Boolean>>): List<String> = friends.filter { it.second }.map { it.first }

    fun toClear(sentTo: List<String>, now: List<String>): List<String> {
        val keep = now.toSet()
        return sentTo.filter { it !in keep }
    }
}

object TravelWords {
    fun clock(t: Double, zone: ZoneId = ZoneId.systemDefault()): String =
        DateTimeFormatter.ofPattern("HH:mm").withZone(zone).format(Instant.ofEpochMilli((t * 1000).toLong()))

    fun capitalFirst(t: String) = t.take(1).uppercase() + t.drop(1)
    private fun lowerFirst(t: String) = t.take(1).lowercase() + t.drop(1)

    /** "IC 3512", "Bus 306", "Train" (no line yet). */
    fun vehicle(s: TravelState): String {
        val line = (s.line ?: "").trim()
        val num = (s.num ?: "").trim()
        if (s.isTrain) {
            if (line.isEmpty()) return if (num.isEmpty()) "Train" else "Train $num"
            return if (num.isEmpty()) line else "$line $num"
        }
        val word = if (s.mode == "bus" || s.mode.isEmpty()) "Bus" else capitalFirst(s.mode)
        return if (line.isEmpty()) word else "$word $line"
    }

    /** "IC 3512 to Breda · arrives 08:43", "Waiting for bus 306 at Veghel", "Changing at Eindhoven". */
    fun summary(s: TravelState, zone: ZoneId = ZoneId.systemDefault()): String {
        val v = vehicle(s)
        return when (s.stage) {
            TravelState.Stage.WAITING -> {
                val what = when {
                    s.isTrain -> "the " + (if (v == "Train") "train" else v)
                    s.line == null -> "the " + v.lowercase()
                    else -> lowerFirst(v)
                }
                "Waiting for $what at ${s.from.name}"
            }
            TravelState.Stage.CHANGE -> {
                var t = "Changing at ${s.from.name}"
                if (s.line != null) t += " · then $v to ${s.to.name}"
                t
            }
            TravelState.Stage.RIDING -> {
                var t = "$v to ${s.to.name}"
                s.eta?.let { t += " · arrives ${clock(it, zone)}" }
                t
            }
        }
    }

    fun ending(s: TravelState, zone: ZoneId = ZoneId.systemDefault()): String? {
        val d = s.dest ?: return null
        if (d.name == s.to.name) return null
        return s.end?.let { "To ${d.name}, there around ${clock(it, zone)}" } ?: "To ${d.name}"
    }

    fun age(seen: FriendTravelSeen, now: Double, zone: ZoneId = ZoneId.systemDefault()): String? =
        if (TravelAge.freshness(seen, now) == TravelFreshness.STALE) "Last update ${clock(seen.sent, zone)} · may have moved on" else null
}

/** The coach picker's sums (iOS `CoachMap`): NS's drawing, coaches counted from the front, where on the platform. */
object CoachMap {
    data class Unit(val x: Double, val w: Double, val cars: Int)
    data class Spot(val drawn: Int, val x0: Double, val x1: Double) { val mid: Double get() = (x0 + x1) / 2 }

    fun spots(units: List<Unit>, totalCars: Int = 0): List<Spot> {
        val known = units.sumOf { maxOf(0, it.cars) }
        val unknownWidth = units.filter { it.cars <= 0 }.sumOf { it.w }
        val left = maxOf(0, totalCars - known)
        val out = mutableListOf<Spot>()
        for (u in units) {
            var n = u.cars
            if (n <= 0) {
                n = if (unknownWidth > 0 && left > 0) Math.round(left.toDouble() * u.w / unknownWidth).toInt() else 1
                n = maxOf(1, n)
            }
            val step = u.w / n
            for (i in 0 until n) out.add(Spot(out.size, u.x + i * step, u.x + (i + 1) * step))
        }
        return out
    }

    /** The coach drawn at `drawn` (from the left) as a number: from the front when the direction is known. */
    fun number(drawn: Int, total: Int, dir: String?): Pair<Int, Boolean> = when (dir) {
        "left" -> (drawn + 1) to true
        "right" -> (total - drawn) to true
        else -> (drawn + 1) to false
    }

    fun drawn(c: TravelState.Coach, total: Int, dir: String?, station: String?): Int? {
        if (c.n < 1 || c.n > c.of || c.of != total) return null
        if (c.front) return when (dir) { "left" -> c.n - 1; "right" -> total - c.n; else -> null }
        if (c.at == null || station == null || c.at != station) return null
        return c.n - 1
    }

    fun part(n: Int, total: Int): String {
        if (total <= 1) return "middle"
        if (total % 2 == 1 && n == (total + 1) / 2) return "middle"
        return if (n <= total / 2) "front" else "back"
    }

    fun label(c: TravelState.Coach): String = if (c.front) "Coach ${c.n} of ${c.of} · ${part(c.n, c.of)}" else "Coach ${c.n} of ${c.of}"

    fun letter(x: Double, letters: List<Pair<String, Double>>): String? = letters.minByOrNull { Math.abs(it.second - x) }?.first

    fun platformHint(c: TravelState.Coach, units: List<Unit>, totalCars: Int, letters: List<Pair<String, Double>>, dir: String?, station: String?): String? {
        val all = spots(units, totalCars)
        val fromFront = if (c.front) "Coach ${c.n} from the front" else null
        val d = if (all.isEmpty()) null else drawn(c, all.size, dir, station)
        if (d == null || d >= all.size) return fromFront
        val l = letter(all[d].mid, letters) ?: return fromFront
        val p = part(c.n, c.of)
        if (c.front) return if (p == "middle") "Wait near $l, in the middle of the platform" else "Wait near $l, at the $p end of the platform"
        return "Wait near $l on the platform"
    }
}
