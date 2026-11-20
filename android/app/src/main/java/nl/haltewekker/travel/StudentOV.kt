package nl.haltewekker.travel

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import kotlin.math.roundToLong

/**
 * (A6, iOS 0.36 `StudentOV.swift`) the student travel product: when a ride is free, at a discount or full fare, by DUO's
 * windows (days run 04:00–04:00; week product free Mon 04:00 – Sat 04:00; weekend product free Fri 12:00 – Mon 04:00,
 * Tue–Fri 04:00–09:00 full fare; summer 16 Jul – 16 Aug a discount for the week product; holidays), 40% off trains, 34%
 * off buses. Pure; the windows are tested.
 */
object StudentOV {
    enum class Product(val raw: String, val title: String) {
        NONE("none", "None"), WEEK("week", "Weekday free (weekend discount)"), WEEKEND("weekend", "Weekend free (weekday discount)");
        companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: NONE }
    }

    sealed class Fare {
        data object Free : Fare()
        data class Discount(val percent: Int) : Fare()
        data object Full : Fare()
    }

    enum class Why(val raw: String) { WEEKDAY("weekday"), WEEKEND("weekend"), SUMMER("summer"), HOLIDAY("holiday"), MORNING("morning") }

    data class Answer(val fare: Fare, val why: Why)

    const val TRAIN_DISCOUNT = 40
    const val BUS_DISCOUNT = 34
    val zone: ZoneId = ZoneId.of("Europe/Amsterdam")

    fun easter(year: Int): LocalDate {
        val a = year % 19; val b = year / 100; val c = year % 100; val d = b / 4; val e = b % 4
        val f = (b + 8) / 25; val g = (b - f + 1) / 3; val h = (19 * a + b - d - g + 15) % 30
        val i = c / 4; val k = c % 4; val l = (32 + 2 * e + 2 * i - h - k) % 7
        val m = (a + 11 * h + 22 * l) / 451
        val month = (h + l - 7 * m + 114) / 31; val day = (h + l - 7 * m + 114) % 31 + 1
        return LocalDate.of(year, month, day)
    }

    enum class Holiday { NEW_YEAR, GOOD_FRIDAY, EASTER_MONDAY, KINGS_DAY, LIBERATION, ASCENSION, WHIT_MONDAY, CHRISTMAS, BOXING_DAY }

    fun holiday(year: Int, month: Int, day: Int): Holiday? {
        if (month == 1 && day == 1) return Holiday.NEW_YEAR
        if (month == 12 && day == 25) return Holiday.CHRISTMAS
        if (month == 12 && day == 26) return Holiday.BOXING_DAY
        if (month == 5 && day == 5) return Holiday.LIBERATION
        if (month == 4 && (day == 26 || day == 27)) {
            val sunday = LocalDate.of(year, 4, 27).dayOfWeek == java.time.DayOfWeek.SUNDAY
            if ((day == 27 && !sunday) || (day == 26 && sunday)) return Holiday.KINGS_DAY
        }
        val here = try { LocalDate.of(year, month, day) } catch (_: Exception) { return null }
        return when (ChronoUnit.DAYS.between(easter(year), here).toInt()) {
            -2 -> Holiday.GOOD_FRIDAY
            1 -> Holiday.EASTER_MONDAY
            39 -> Holiday.ASCENSION
            50 -> Holiday.WHIT_MONDAY
            else -> null
        }
    }

    /** The travel day (04:00–04:00): weekday 1 Sunday … 7 Saturday, as iOS; minutes since that day's 04:00. */
    data class TravelDay(val year: Int, val month: Int, val day: Int, val weekday: Int, val minutes: Int) {
        val date: LocalDate get() = LocalDate.of(year, month, day)
    }

    fun travelDay(at: Double): TravelDay {
        val z = Instant.ofEpochMilli(((at - 4 * 3600) * 1000).roundToLong()).atZone(zone)
        return TravelDay(z.year, z.monthValue, z.dayOfMonth, z.dayOfWeek.value % 7 + 1, z.hour * 60 + z.minute)
    }

    fun summer(d: TravelDay) = (d.month == 7 && d.day >= 16) || (d.month == 8 && d.day < 16)

    fun fare(product: Product, at: Double, train: Boolean): Answer? {
        val pct = if (train) TRAIN_DISCOUNT else BUS_DISCOUNT
        val d = travelDay(at)
        val hol = holiday(d.year, d.month, d.day)
        when (product) {
            Product.NONE -> return null
            Product.WEEK -> {
                if (summer(d)) return Answer(Fare.Discount(pct), Why.SUMMER)
                if (hol != null) {
                    if (hol == Holiday.GOOD_FRIDAY) return Answer(Fare.Free, Why.HOLIDAY)
                    if (d.weekday in 2..6) return Answer(Fare.Discount(pct), Why.HOLIDAY)
                }
                if (d.weekday in 2..6) return Answer(Fare.Free, Why.WEEKDAY)
                return Answer(Fare.Discount(pct), Why.WEEKEND)
            }
            Product.WEEKEND -> {
                if (hol != null) return Answer(Fare.Free, Why.HOLIDAY)
                if (d.minutes >= 8 * 60) {
                    val n = d.date.plusDays(1)
                    val h = holiday(n.year, n.monthValue, n.dayOfMonth)
                    if (h == Holiday.GOOD_FRIDAY || h == Holiday.ASCENSION) return Answer(Fare.Free, Why.HOLIDAY)
                }
                return when (d.weekday) {
                    7, 1 -> Answer(Fare.Free, Why.WEEKEND)
                    2 -> Answer(Fare.Discount(pct), Why.WEEKDAY)
                    6 -> when {
                        d.minutes >= 8 * 60 -> Answer(Fare.Free, Why.WEEKEND)
                        d.minutes >= 5 * 60 -> Answer(Fare.Discount(pct), Why.WEEKDAY)
                        else -> Answer(Fare.Full, Why.MORNING)
                    }
                    else -> if (d.minutes >= 5 * 60) Answer(Fare.Discount(pct), Why.WEEKDAY) else Answer(Fare.Full, Why.MORNING)
                }
            }
        }
    }

    fun euros(cents: Int) = String.format(java.util.Locale.ROOT, "€%d.%02d", cents / 100, cents % 100)

    fun pay(a: Answer, fullCents: Int?): Int? {
        val c = fullCents ?: return null
        if (c <= 0) return null
        return when (val f = a.fare) {
            Fare.Free -> null
            Fare.Full -> c
            is Fare.Discount -> roundTo(c * (100 - f.percent) / 100.0, 1.0).toInt()
        }
    }

    fun line(product: Product, at: Double, train: Boolean, fullCents: Int?): String? {
        val a = fare(product, at, train) ?: return null
        if (a.fare == Fare.Free) return "Free with your student OV"
        val why = if (a.why == Why.MORNING) "weekday morning" else a.why.raw
        val head = "Costs money now ($why)"
        val f = a.fare
        pay(a, fullCents)?.let { p -> return if (f is Fare.Discount) "$head — ~${euros(p)} with ${f.percent}% off" else "$head — ~${euros(p)}" }
        if (f is Fare.Discount) return "$head — ${f.percent}% off"
        return "$head — full fare"
    }

    fun tripLine(product: Product, rides: List<Pair<Boolean, Double>>, fullCents: Int?): String? {
        if (product == Product.NONE || rides.isEmpty()) return null
        for ((train, at) in rides) {
            val a = fare(product, at, train) ?: return null
            if (a.fare != Fare.Free) return line(product, at, train, if (train) fullCents else null)
        }
        return "Free with your student OV"
    }

    /** The 2nd-class single fare without discount, in cents, from the relay's `/ns/price` (any shape with fare objects). */
    fun fullFareCents(json: JsonElement?): Int? {
        data class F(val cents: Int, val cls: String, val disc: String)
        val found = ArrayList<F>()
        fun str(o: JsonObject, k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        fun walk(x: JsonElement?) {
            when (x) {
                is JsonObject -> {
                    val cents = ((x["priceInCents"] as? JsonPrimitive)?.content?.toDoubleOrNull() ?: (x["totalPriceInCents"] as? JsonPrimitive)?.content?.toDoubleOrNull())?.toInt()
                    if (cents != null && cents > 0) found.add(F(cents, (str(x, "travelClass") ?: str(x, "classType") ?: "").uppercase(), (str(x, "discountType") ?: "").uppercase()))
                    for (v in x.values) walk(v)
                }
                is JsonArray -> for (v in x) walk(v)
                else -> {}
            }
        }
        walk(json)
        fun second(s: String) = s.isEmpty() || s.contains("SECOND") || s == "2"
        fun noDiscount(s: String) = s.isEmpty() || s.contains("NO_DISCOUNT") || s == "NONE"
        found.firstOrNull { second(it.cls) && noDiscount(it.disc) && it.cls.isNotEmpty() }?.let { return it.cents }
        found.firstOrNull { second(it.cls) && noDiscount(it.disc) }?.let { return it.cents }
        return null
    }
}
