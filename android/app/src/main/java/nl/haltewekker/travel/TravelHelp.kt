package nl.haltewekker.travel

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import java.time.Instant
import java.time.ZoneId
import kotlin.math.roundToInt

// (A6, iOS 0.36 `TravelHelp.swift`) three reminders around a trip, as pure rules: "Did you check out?", NS's money back
// for a late train, and the last way home in the evening. The ride service and TravelNotes do the notifying.

/** "Did you check out?" a minute after you get off where the OV-chipkaart wants it. No NFC: only a reminder. */
object CheckOut {
    data class Ride(val train: Boolean, val company: String? = null)

    const val AFTER = 60.0
    const val ABOARD_SPEED = 7.0

    fun due(after: Int, rides: List<Ride>): Boolean {
        if (after !in rides.indices) return false
        if (after + 1 >= rides.size) return true
        val a = rides[after]; val b = rides[after + 1]
        if (!a.train || !b.train) return true
        val x = a.company; val y = b.company
        if (!x.isNullOrEmpty() && !y.isNullOrEmpty() && x.trim().lowercase() != y.trim().lowercase()) return true
        return false
    }

    fun stillAboard(speeds: List<Double>, sameVehicle: Boolean) = sameVehicle || speeds.count { it.isFinite() && it >= ABOARD_SPEED } >= 2

    /** `change`: (fromTrain, toTrain) at a change, else the trip's end. */
    fun text(stop: String, change: Pair<Boolean, Boolean>? = null): Pair<String, String> {
        val title = "Did you check out?"
        val c = change ?: return title to "You’re at $stop. Hold your card or phone to the check-out pole, or you pay the full fare."
        fun w(t: Boolean) = if (t) "train" else "bus"
        if (c.first && c.second) return title to "At $stop you change train company: check out at the pole of the train you leave, and in at the next one’s."
        return title to "At $stop you change from ${w(c.first)} to ${w(c.second)}: check out of the ${w(c.first)}, then in on the ${w(c.second)}."
    }
}

/** NS's "Geld terug bij vertraging": 30 minutes late or more, told once per trip, after it. */
object DelayClaim {
    const val THRESHOLD = 30.0
    const val CLAIM_URL = "https://www.ns.nl/service-en-contact/geld-terug/geld-terug-bij-vertraging"
    const val SOME_DELAY = 3.0

    fun minutesLate(plannedEnd: Double?, actualEnd: Double?, trainDelays: List<Double>): Double? {
        var worst: Double? = trainDelays.filter { it.isFinite() }.maxOrNull()
        if (plannedEnd != null && actualEnd != null && (worst ?: 0.0) >= SOME_DELAY) {
            val m = (actualEnd - plannedEnd) / 60
            if (m.isFinite()) worst = maxOf(worst ?: m, m)
        }
        return worst
    }

    fun due(minutesLate: Double?, told: Boolean): Boolean {
        if (told || minutesLate == null || !minutesLate.isFinite()) return false
        return minutesLate >= THRESHOLD - 0.5
    }

    fun text(minutesLate: Double): Pair<String, String> {
        val n = minutesLate.roundToInt()
        val share = if (n >= 60) "the whole fare" else "half the fare"
        return "Your train was $n min late — you can claim money back from NS" to
            "Geld terug bij vertraging: $share back (a fixed amount with a student OV). Tap to open NS’s claim page."
    }
}

/** In the evening, away from home: the latest bus or train that still gets you home tonight. */
object LastTrip {
    const val FROM_HOUR = 20
    const val UNTIL_HOUR = 4
    const val AWAY_METRES = 3000.0
    const val WARN_BEFORE = 30 * 60.0
    const val REFRESH_EVERY = 3600.0
    const val MOVED_METRES = 1000.0
    const val LONGEST = 4 * 3600.0
    val zone: ZoneId = ZoneId.of("Europe/Amsterdam")

    data class Option(val leave: Double, val firstDeparture: Double, val arrive: Double, val from: String, val cancelled: Boolean = false)

    private fun z(t: Double) = Instant.ofEpochMilli((t * 1000).toLong()).atZone(zone)

    fun evening(now: Double): Boolean { val h = z(now).hour; return h >= FROM_HOUR || h < UNTIL_HOUR }

    fun wanted(now: Double, metresFromHome: Double?): Boolean {
        val m = metresFromHome ?: return false
        return m.isFinite() && evening(now) && m > AWAY_METRES
    }

    fun arriveBy(now: Double): List<Double> {
        val base = z(now - UNTIL_HOUR * 3600.0).toLocalDate()
        val night = base.plusDays(1).atStartOfDay(zone)
        return listOf(4, 2, 1, 0).map { night.plusHours(it.toLong()).toEpochSecond().toDouble() }.filter { it > now + 15 * 60 }
    }

    fun pick(options: List<Option>, now: Double): Int? =
        options.indices.filter { i ->
            val o = options[i]
            !o.cancelled && o.leave > now + 60 && o.arrive > o.leave && o.arrive - o.firstDeparture <= LONGEST
        }.maxWithOrNull(compareBy<Int> { options[it].leave }.thenByDescending { options[it].arrive })

    fun refreshDue(lastAsked: Double?, askedAt: GeoPoint?, here: GeoPoint, known: Option?, now: Double): Boolean {
        val t = lastAsked ?: return true
        val p = askedAt ?: return true
        if (now - t >= REFRESH_EVERY || now < t) return true
        if (Geo.metres(p, here) >= MOVED_METRES) return true
        if (known != null && known.leave <= now) return true
        return false
    }

    fun warnAt(o: Option, now: Double): Double? { val w = o.leave - WARN_BEFORE; return if (w > now) w else null }

    fun cardText(o: Option, hhmm: (Double) -> String) = "Last way home leaves ${hhmm(o.leave)} from ${o.from}"

    fun notice(o: Option, hhmm: (Double) -> String) = "Last way home in 30 min" to
        "Leave at ${hhmm(o.leave)} for the ${hhmm(o.firstDeparture)} from ${o.from}, home ${hhmm(o.arrive)}. After that there’s none tonight."
}
