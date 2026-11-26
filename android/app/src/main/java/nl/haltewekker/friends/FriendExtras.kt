package nl.haltewekker.friends

import kotlinx.serialization.Serializable
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Friends extras (0.29), the iOS `FriendExtras.swift`: "Wait for me", the delay alarm for shared rides, the wake-up
// buddy and who's on campus, as plain values and rules, tested without the relay, the ride or the UI. Every box goes
// through the 0.25 mailbox (`/f/v1/send`) with a slot, so the newest replaces the last one waiting; nothing new on the
// relay. The bodies and rules: docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.29)". Times are unix
// seconds (Double, as everywhere in the app); days `yyyy-MM-dd` in Europe/Amsterdam.

// MARK: wait for me

/** The body of a `wait` box (slot `wait`, ttl 900 s): you're on your way to a stop and ask a friend (or a group) to wait. */
@Serializable
data class WaitFor(
    /** The request's id: the same in every update (an answer says it in `re`). */
    val id: String,
    /** "coming", "there" or "off" (an unknown value reads as coming). */
    val state: String,
    val stop: TripCard.Spot,
    val ride: TripCard.Ride? = null,
    /** Straight line to the stop, metres. */
    val dist: Int? = null,
    /** When you expect to be there. */
    val eta: Double? = null,
    /** When that was measured. */
    val at: Double,
) {
    enum class Phase(val raw: String) { COMING("coming"), THERE("there"), OFF("off") }

    val phase: Phase get() = Phase.entries.firstOrNull { it.raw == state } ?: Phase.COMING

    companion object {
        /** As taken: an id of 1–32 of [A-Za-z0-9_-], a stop with a name and a place, a distance within 100 km. */
        fun valid(w: WaitFor): WaitFor? {
            if (!WaitRules.validId(w.id) || w.stop.name.isEmpty() || w.stop.point == null) return null
            var v = w
            if (w.dist != null && (w.dist < 0 || w.dist > 100_000)) v = v.copy(dist = null)
            if (w.ride != null && (w.ride.trip.isEmpty() || w.ride.arr < w.ride.dep)) v = v.copy(ride = null)
            return v
        }
    }
}

/** An answer to a `wait`: a `message` with `re` = the wait's id and `answer` = "wait" or "next". */
enum class WaitAnswer(val raw: String) {
    WAIT("wait"), NEXT("next");

    val text: String get() = if (this == WAIT) "I’ll wait" else "Let’s take the next one together"

    companion object { fun of(raw: String?): WaitAnswer? = entries.firstOrNull { it.raw == raw } }
}

/** Someone's wait as this phone read it. `chat`: their account, or "g." + the group's id. */
@Serializable
data class WaitSeen(val from: String, val chat: String, val wait: WaitFor, val t: Long, val got: Double)

object WaitAge {
    const val FRESH_FOR = 90.0
    const val SHOW_FOR = 15 * 60.0
    const val PAST_RIDE = 5 * 60.0

    fun freshness(s: WaitSeen, now: Double): TravelFreshness {
        if (s.wait.phase == WaitFor.Phase.OFF) return TravelFreshness.GONE
        val sent = min(s.wait.at, s.got)
        val age = now - sent
        if (age > SHOW_FOR) return TravelFreshness.GONE
        val r = s.wait.ride
        if (r != null && now - r.dep > PAST_RIDE) return TravelFreshness.GONE
        return if (age <= FRESH_FOR) TravelFreshness.FRESH else TravelFreshness.STALE
    }
}

object WaitRules {
    const val SLOT = "wait"
    const val TTL = 900
    const val THERE_METRES = 40.0
    const val MIN_GAP = 20.0
    const val REFRESH = 60.0
    const val MOVED = 25
    const val MAX_AGE = 30 * 60.0
    const val AFTER_RIDE = 2 * 60.0

    fun validId(s: String): Boolean {
        if (s.isEmpty() || s.length > 32) return false
        return s.all { c -> c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '_' || c == '-' }
    }

    /** At the stop within 40 m, else coming; null: it's over (too old, or its ride left). */
    fun phase(dist: Double?, started: Double, rideDep: Double?, now: Double): WaitFor.Phase? {
        if (now - started > MAX_AGE) return null
        if (rideDep != null && now - rideDep > AFTER_RIDE) return null
        if (dist != null && dist <= THERE_METRES) return WaitFor.Phase.THERE
        return WaitFor.Phase.COMING
    }

    /** Walking there (a third longer by the streets at 1.2 m/s, whole minutes up); now when at it. */
    fun eta(dist: Double, now: Double): Double {
        if (dist <= THERE_METRES) return now
        return now + FriendWalk.minutes(dist) * 60.0
    }

    /** A new phase at once; else not within 20 s of the last, then when moved 25 m, the eta moved a minute, or 60 s went by. */
    fun due(last: WaitFor?, lastSent: Double?, next: WaitFor, now: Double): Boolean {
        if (last == null || lastSent == null) return true
        if (last.phase != next.phase) return true
        val gap = now - lastSent
        if (gap < MIN_GAP) return false
        if (gap >= REFRESH) return true
        if (last.dist != null && next.dist != null && abs(last.dist - next.dist) >= MOVED) return true
        if (last.eta != null && next.eta != null && abs(last.eta - next.eta) >= 60) return true
        return false
    }
}

object WaitWords {
    /** "300 m", "1.2 km" (tens of metres below a kilometre). */
    fun metres(m: Int): String {
        if (m < 1000) return "${max(0, (m / 10.0).roundHalfAway() * 10)} m"
        return String.format(Locale.US, "%.1f km", m / 1000.0)
    }

    fun line(name: String, w: WaitFor, now: Double): String {
        if (w.phase == WaitFor.Phase.THERE) return "$name is at the stop"
        val far = w.dist?.let(::metres)
        val eta = w.eta ?: return far?.let { "$name is $it from the stop" } ?: "$name is on the way to the stop"
        val mins = ceil((eta - now) / 60).toInt()
        val whenText = if (mins <= 0) "under a minute" else "$mins min"
        return far?.let { "$name is $whenText from the stop ($it)" } ?: "$name is $whenText from the stop"
    }

    fun detail(name: String, w: WaitFor): String {
        var t = "At ${w.stop.name}"
        val r = w.ride
        if (r != null) {
            t += " · for the ${r.label} at ${TimetableDays.hhmm(r.dep)}"
            if (w.phase == WaitFor.Phase.COMING && w.eta != null && w.eta > r.dep) t += " · it leaves before $name gets there"
        }
        return t
    }

    fun mine(who: String, w: WaitFor): String {
        if (w.phase == WaitFor.Phase.THERE) return "Asked $who to wait · you’re at the stop"
        val d = w.dist ?: return "Asked $who to wait"
        return "Asked $who to wait · you’re ${metres(d)} from the stop"
    }
}

/** Swift's `.rounded()`: half away from zero. */
internal fun Double.roundHalfAway(): Int = if (this >= 0) Math.floor(this + 0.5).toInt() else -Math.floor(-this + 0.5).toInt()

/** "Take the next one with you": the next way from the stop (getting on within 300 m), after the one you'd miss. */
object WaitNext {
    const val SAME_STOP = 300.0

    fun pick(ways: List<Way>, stop: GeoPoint, after: Double, exclude: String?, line: String?): Way? {
        val ok = ways.filter { w ->
            val f = w.legs.firstOrNull() ?: return@filter false
            val p = f.from.point ?: return@filter false
            f.trip != exclude && f.dep >= after && Geo.metres(p, stop) <= SAME_STOP
        }.sortedBy { it.legs.firstOrNull()?.dep ?: Double.MAX_VALUE }
        val first = ok.firstOrNull() ?: return null
        val firstDep = first.legs.first().dep
        if (line == null || first.legs.first().line == line) return first
        val until = firstDep + 15 * 60
        return ok.firstOrNull { w -> w.legs.first().let { it.line == line && it.dep <= until } } ?: first
    }
}

// MARK: delay alarm for shared rides

/** The body of a `delay` box (slot `delay`, ttl 3 h). */
@Serializable
data class RideDelay(
    val ride: TripCard.Ride,
    val late: Int,
    val cancelled: Boolean? = null,
    val next: TripCard.Ride? = null,
    val who: List<String>? = null,
) {
    val isCancelled: Boolean get() = cancelled == true

    companion object {
        fun valid(d: RideDelay): RideDelay? {
            if (d.ride.trip.isEmpty() || d.late < 0 || d.late > 600) return null
            var v = d
            if (d.next != null && (d.next.trip.isEmpty() || d.next.arr < d.next.dep)) v = v.copy(next = null)
            if (d.who != null) v = v.copy(who = d.who.take(20))
            return v
        }
    }
}

@Serializable data class DelaySeen(val from: String, val delay: RideDelay, val got: Double)
@Serializable data class DelayTold(val late: Int, val cancelled: Boolean, val at: Double)

/** One bus or train you're on (or about to be) with friends. */
data class SharedRideRef(val ride: TripCard.Ride, val riders: List<String>, val spots: Map<String, List<TripCard.Spot>> = emptyMap())

/** One stop of a ride as the live data has it (iOS `BoardAt.Stop`, the fields the delay alarm reads). */
data class DelayStop(val name: String, val point: GeoPoint, val departure: Double?, val scheduledDeparture: Double? = null, val cancelled: Boolean = false)

data class DelayRead(val late: Int, val cancelled: Boolean, val dep: Double?)

object DelayAlarm {
    const val SLOT = "delay"
    const val TTL = 3 * 3600
    const val MIN_LATE = 3
    const val STEP = 2
    const val LOOK_EVERY = 120.0
    const val AHEAD = 90 * 60.0
    const val BUDGET = 4

    fun shouldTell(late: Int, cancelled: Boolean, told: DelayTold?): Boolean {
        if (cancelled) return told?.cancelled != true
        if (late < MIN_LATE) return false
        if (told == null) return true
        if (told.cancelled) return false
        return abs(late - told.late) >= STEP
    }

    fun lookDue(last: Double?, now: Double): Boolean = last == null || now - last >= LOOK_EVERY

    fun watched(r: TripCard.Ride, now: Double): Boolean = r.arr > now && r.dep - now <= AHEAD

    /** The ride's lateness at your stop (within 300 m, else by name) while it hasn't left there; after that at its next stop. */
    fun read(stops: List<DelayStop>, board: TripCard.Spot, now: Double): DelayRead? {
        if (stops.isEmpty()) return null
        var at: Int? = null
        val p = board.point
        if (p != null) at = stops.indices.filter { Geo.metres(stops[it].point, p) <= 300 }.minByOrNull { Geo.metres(stops[it].point, p) }
        if (at == null) at = stops.indexOfFirst { it.name == board.name }.takeIf { it >= 0 }
        val allCancelled = stops.all { it.cancelled }
        val i = at ?: return if (allCancelled) DelayRead(0, true, null) else null
        val mine = stops[i]
        if (mine.cancelled || allCancelled) return DelayRead(0, true, mine.departure)
        var s = mine
        val d = mine.departure
        if (d != null && d < now) stops.drop(i).firstOrNull { (it.departure ?: Double.NEGATIVE_INFINITY) >= now }?.let { s = it }
        val dep = s.departure ?: return null
        val sched = s.scheduledDeparture ?: return null
        val late = max(0, ((dep - sched) / 60).roundHalfAway())
        return DelayRead(late, false, mine.departure)
    }

    /** The next ride all of you can take: 0.28's matching without the late one; the earliest with everyone, else with the most. */
    fun next(people: List<PersonWays>, exclude: String, after: Double): SharedRide? {
        val others = people.map { p -> p.copy(ways = p.ways.filter { w -> w.legs.none { it.trip == exclude } }) }
        val all = SharedRides.match(others, SharedRides.Direction.HOME).filter { it.trip != exclude && it.firstDep >= after }
        val most = all.maxOfOrNull { it.riders.size } ?: return null
        if (most < 2) return null
        return all.filter { it.riders.size == most }.minWithOrNull(compareBy<SharedRide> { it.firstDep }.thenBy { it.trip })
    }

    /** The rides you share now (your trip's with friends on that vehicle, and trip cards you're in), merged by vehicle. */
    fun shared(mine: List<TripCard.Ride>, travel: List<Pair<String, TravelState>>, cards: List<Pair<TripCard, List<String>>>,
               me: String, now: Double): List<SharedRideRef> {
        data class M(val ride: TripCard.Ride, val riders: MutableList<String>, val spots: MutableMap<String, List<TripCard.Spot>>)
        val out = mutableListOf<M>()
        fun add(ride: TripCard.Ride, who: String, spots: List<TripCard.Spot>?) {
            if (who == me) return
            val m = out.firstOrNull { it.ride.trip == ride.trip }
            if (m != null) {
                if (who !in m.riders) m.riders.add(who)
                if (spots != null && who !in m.spots) m.spots[who] = spots
            } else {
                out.add(M(ride, mutableListOf(who), if (spots != null) mutableMapOf(who to spots) else mutableMapOf()))
            }
        }
        for (r in mine) {
            if (!watched(r, now)) continue
            for ((from, st) in travel) if (st.trip == r.trip) add(r, from, listOf(spot(st.from), spot(st.to)))
        }
        for ((card, riders) in cards) {
            val s = TripTake.shared(card) ?: continue
            if (!watched(s, now)) continue
            val ride = mine.firstOrNull { it.trip == s.trip } ?: s
            for (who in riders) add(ride, who, listOf(s.from, s.to))
        }
        return out.filter { it.riders.isNotEmpty() }.map { SharedRideRef(it.ride, it.riders.toList(), it.spots.toMap()) }
    }

    fun spot(s: TravelState.Spot) = TripCard.Spot(s.name, lat = s.lat, lon = s.lon)

    /** Who's in on a card: the sender and everyone who said "I'm in"; you count only when you are. */
    fun riders(sender: String, answers: Map<String, TripAnswer>, me: String): List<String>? {
        val yes = answers.filter { it.value == TripAnswer.YES }.keys.sorted()
        val all = listOf(sender) + yes.filter { it != sender }
        if (me !in all) return null
        return all.filter { it != me }
    }
}

object DelayWords {
    fun title(d: RideDelay): String = if (d.isCancelled) "${d.ride.label} is cancelled" else "${d.ride.label} is ${d.late} min late"

    fun body(d: RideDelay, names: List<String>): String {
        val parts = mutableListOf<String>()
        if (names.isNotEmpty()) {
            val list = CompareWords.names(names)
            val one = names.size == 1 && names[0] != "you"
            parts.add("${TravelWords.capitalFirst(list)} ${if (one) "is" else "are"} on it.")
        }
        if (!d.isCancelled) parts.add("It now leaves ${d.ride.from.name} at ${TimetableDays.hhmm(d.ride.dep)}.")
        val n = d.next
        if (n != null) parts.add("Next you can all take: ${n.label} at ${TimetableDays.hhmm(n.dep)} from ${n.from.name}.")
        else if (d.isCancelled) parts.add("Look for another way in Fastest trip.")
        return parts.joinToString(" ")
    }
}

// MARK: wake-up buddy

/** The body of a `buddy` box (slot `buddy`, ttl 36 h). `on: false` takes it back. */
@Serializable
data class BuddyPlan(val on: Boolean, val day: String? = null, val leave: Double? = null, val ride: TripCard.Ride? = null, val left: Double? = null)

@Serializable data class BuddySeen(val plan: BuddyPlan, val t: Long, val got: Double)

data class BuddyToday(val leave: Double, val ride: TripCard.Ride?)

object BuddyRules {
    const val SLOT = "buddy"
    const val TTL = 36 * 3600
    const val GRACE = 5 * 60.0
    const val WINDOW = 10 * 60.0
    const val REFRESH = 12 * 3600.0
    const val AWAY_METRES = 400.0

    /** Their own plan (the buddy box) first, else a trip card they're in (sent: its start; "I'm in": 15 min before the shared ride). */
    fun plan(b: BuddyPlan?, cards: List<Pair<TripCard, Boolean>>, today: String): BuddyToday? {
        if (b != null && b.on && b.day == today && b.leave != null) return BuddyToday(b.leave, b.ride)
        var best: BuddyToday? = null
        for ((card, sent) in cards) {
            val s = TripTake.shared(card) ?: continue
            if (TimetableDays.key(s.dep) != today) continue
            val first = card.first ?: s
            val leave = if (sent) (card.start ?: first.dep) else s.dep - 15 * 60
            val ride = if (sent) first else s
            if (best == null || leave < best.leave) best = BuddyToday(leave, ride)
        }
        return best
    }

    fun moving(left: Double?, seen: List<Double>, leave: Double): Boolean {
        val since = leave - 3600
        if (left != null && left >= since) return true
        return seen.any { it >= since }
    }

    fun alert(leave: Double, ride: TripCard.Ride?, moving: Boolean, told: String?, today: String, now: Double): Boolean {
        if (moving || told == today || TimetableDays.key(leave) != today) return false
        val start = leave + GRACE
        val base = max(ride?.dep ?: start, start)
        return now >= start && now <= base + WINDOW
    }

    fun due(last: BuddyPlan?, lastAt: Double?, next: BuddyPlan, now: Double): Boolean {
        if (last == null || lastAt == null) return true
        if (last != next) return true
        return now - lastAt >= REFRESH
    }
}

object BuddyWords {
    fun title(name: String, leave: Double, ride: TripCard.Ride?): String {
        val r = ride ?: return "$name isn’t moving yet — they planned to leave at ${TimetableDays.hhmm(leave)}"
        return "$name isn’t moving yet — their ${if (r.isTrain) "train" else "bus"} is at ${TimetableDays.hhmm(r.dep)}"
    }

    fun body(name: String, leave: Double, ride: TripCard.Ride?): String {
        var t = "$name planned to leave at ${TimetableDays.hhmm(leave)}"
        if (ride != null) t += " for the ${ride.label} from ${ride.from.name}"
        return "$t. Maybe send a message?"
    }
}

// MARK: who's on campus

/** The body of a `campus` box (slot `campus`): you're at your school now, never where exactly. */
@Serializable
data class CampusState(val on: Boolean, val school: String? = null, val since: Double? = null, val until: Double? = null)

@Serializable data class CampusSeen(val state: CampusState, val t: Long, val got: Double)
@Serializable data class CampusPosted(val since: Double, val until: Double, val to: List<String>)

object CampusRules {
    const val SLOT = "campus"
    const val MAX_STAY = 10 * 3600.0
    const val MARGIN = 150.0
    const val FIX_AGE = 10 * 60.0
    const val OFF_TTL = 3600

    fun inside(distance: Double?, radius: Double, was: Boolean): Boolean? {
        distance ?: return null
        if (distance <= radius) return true
        if (distance > radius + MARGIN) return false
        return was
    }

    sealed class Action {
        data class Post(val since: Double, val to: List<String>) : Action()
        data class Clear(val to: List<String>) : Action()
        data object None : Action()
    }

    fun decide(on: Boolean, inside: Boolean?, since: Double?, posted: CampusPosted?, friends: List<String>, now: Double): Action {
        if (posted != null) {
            val leave = !on || inside == false || now >= posted.until
            if (leave) return if (posted.to.isEmpty()) Action.None else Action.Clear(posted.to)
            val more = friends.filter { it !in posted.to }
            return if (more.isEmpty()) Action.None else Action.Post(posted.since, more)
        }
        if (!on || inside != true || since == null || now - since >= MAX_STAY || friends.isEmpty()) return Action.None
        return Action.Post(since, friends)
    }

    fun until(since: Double) = since + MAX_STAY

    fun ttl(until: Double, now: Double): Int = max(60, min(MAX_STAY.toInt(), (until - now).toInt()))

    fun here(s: CampusSeen, now: Double): Boolean {
        if (!s.state.on) return false
        val until = s.state.until ?: return false
        val since = s.state.since ?: s.t.toDouble()
        return now < until && until - since <= MAX_STAY + 60
    }
}

object CampusWords {
    fun list(names: List<String>) = "On campus now: ${CompareWords.names(names)}"

    fun since(s: CampusState): String {
        val at = s.school?.let { "At $it" } ?: "At school"
        val t = s.since ?: return at
        return "$at since ${TimetableDays.hhmm(t)}"
    }
}

// MARK: your switches

/** The extras' switches (kept with the extras and in the vault): all off / nobody by default. */
@Serializable
data class ExtrasSettings(val campus: Boolean? = null, val buddy: List<String>? = null, val free: Boolean? = null, val scores: Boolean? = null)

internal fun Int.clampTo(lo: Int, hi: Int) = min(hi, max(lo, this))
internal fun Double.roundTenth(): Double = (this * 10).roundToInt() / 10.0
