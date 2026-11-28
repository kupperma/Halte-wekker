package nl.haltewekker.travel

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * (0.10.11, iOS 0.42.15 `NearbySlot`) How sure a way is depends a lot on when you take it (a 19:00 bus is far less on
 * time than a 13:00 one): your own rides count only around the same time, weekdays and weekends apart, and the
 * estimate goes by the time of day first. Tested in `NearbyCardsTest` against docs/nearby-cards-vectors.json.
 */
object NearbySlot {
    /** One of your rides: the minute of the day it was due (or left), weekend or not, how late (minutes). */
    data class Entry(val minute: Int, val weekend: Boolean, val delay: Double)

    val WINDOWS = listOf(60, 90, 120)

    private val ZONE: java.time.ZoneId = java.time.ZoneId.of("Europe/Amsterdam")

    /** The minute of the day at `at` (Amsterdam time), and whether it's a weekend day. */
    fun slotOf(at: Double): Pair<Int, Boolean> {
        val z = java.time.Instant.ofEpochSecond(at.toLong()).atZone(ZONE)
        return (z.hour * 60 + z.minute) to (z.dayOfWeek == java.time.DayOfWeek.SATURDAY || z.dayOfWeek == java.time.DayOfWeek.SUNDAY)
    }

    /** (0.10.12) One of your own rides filed by the minute it was due (`arr` less `late` minutes), like iOS
     *  `DelayBook`: a 17:50 ride 40 min late counts at 17:50, and a late 23:50 one stays on its own day. */
    fun ownEntry(arr: Double, late: Double): Entry {
        val (m, we) = slotOf(arr - late * 60)
        return Entry(m, we, late)
    }

    fun apart(a: Int, b: Int): Int {
        val d = abs(((a - b) % 1440 + 1440) % 1440)
        return min(d, 1440 - d)
    }

    /** Your rides around `minute`, oldest first: within 60 minutes either side, else 90, else 120; and the window. */
    fun pick(entries: List<Entry>, minute: Int, weekend: Boolean): Pair<List<Double>, Int> {
        val same = entries.filter { it.weekend == weekend }
        for (w in WINDOWS) {
            val d = same.filter { apart(it.minute, minute) <= w }.map { it.delay }
            if (d.size >= Nearby.OWN_NEEDED || w == WINDOWS.last()) return d to w
        }
        return emptyList<Double>() to WINDOWS.last()
    }

    data class Period(val name: String, val bus: Double, val train: Double)

    /** Rush hours (07–09, 16–19) worst, the evening after them still busy (iOS `Steady.period` goes by this too). */
    fun period(hour: Double, weekend: Boolean): Period {
        if (weekend) return Period("weekend", 1.8, 0.8)
        val h = hour
        return when {
            (h >= 7 && h < 9) || (h >= 16 && h < 19) -> Period("rush hour", 3.5, 1.2)
            (h >= 6.5 && h < 7) || (h >= 9 && h < 9.5) || (h >= 15 && h < 16) -> Period("busy", 2.6, 1.0)
            h >= 19 && h < 20.5 -> Period("evening", 2.4, 0.9)
            h >= 9.5 && h < 15 -> Period("daytime", 2.0, 0.8)
            else -> Period("quiet", 1.5, 0.7)
        }
    }

    fun lateChance(scale: Double, by: Double): Double {
        val s = if (scale.isFinite()) max(0.5, scale) else 2.0
        return exp(-by / s)
    }

    /** "around 19:00 on weekdays" (to the nearest half hour). */
    fun slotWords(minute: Int, weekend: Boolean): String {
        val m = ((Math.round(minute / 30.0).toInt() * 30) % 1440 + 1440) % 1440
        return "around %02d:%02d on %s".format(java.util.Locale.ROOT, m / 60, m % 60, if (weekend) "weekends" else "weekdays")
    }

    /** Where a way's % comes from (iOS `NearbySlot.explain`, the same words). */
    fun explain(s: Nearby.Sure, line: String, to: String, slot: String, period: String, changes: Int): String {
        val late = "less than ${Nearby.LATE_BY.toInt()} min late"
        var out = when (val src = s.source) {
            is Nearby.Source.Yours -> {
                val n = src.rides
                var t = "Based on your last $n ride${if (n == 1) "" else "s"} on the $line to $to $slot: ${s.onTime ?: 0} on time ($late)."
                val w = s.window
                if (w != null && w > WINDOWS[0]) t += " Counted up to $w min either side: too few closer to that time."
                t
            }
            Nearby.Source.Live -> "Estimated: fewer than ${Nearby.OWN_NEEDED} of your own rides $slot. From how late the $line runs then ($period), what the app saw of it, and its live delays today."
            else -> "Estimated from the time of day only ($slot, $period): no live times of the $line yet."
        }
        if (changes > 0 && s.made < 0.995) {
            val pct = (s.made * 100).roundToInt()
            out += " Times the chance you make your ${if (changes == 1) "change" else "$changes changes"} (about $pct%)."
        }
        return out
    }
}
