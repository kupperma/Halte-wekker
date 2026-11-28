package nl.haltewekker.core

/**
 * (0.10.13, iOS 0.42.17 `Country.swift`) Which country a stop is in, and so where its live train data comes from: NS in
 * the Netherlands, iRail (the relay's `/be/…`) in Belgium. Pure, checked on docs/belgium-vectors.json.
 *
 * In this order: a station's UIC number in its id (84… Netherlands, 88… Belgium, another a third country; DELFI ids
 * and SNCB's `be-sncb_S8821006`); a Belgian feed (`be-…`); inside a rough outline of Belgium (a little inside the Dutch
 * border, so a Dutch stop near it stays Dutch); else the Netherlands. NS's own station list is asked first wherever a
 * train's data is looked up, so nothing Dutch changes.
 */
/** A stop as `Country.onlyBelgium` takes it. */
data class CountryStop(val id: String, val lat: Double?, val lon: Double?)

enum class Country(val code: String) {
    NL("NL"), BE("BE"), OTHER("other");

    companion object {
        /** The 7-digit UIC number in a stop id (DELFI's, or SNCB's `be-sncb_S8821006` / `be-sncb_8812005`). */
        fun uic(id: String): String? {
            if (id.contains("DELFI")) {
                val digits = id.split('_').last().takeWhile { it in '0'..'9' }
                if (digits.length < 7) return null
                val trimmed = digits.trimStart('0')
                return if (trimmed.length == 7 && trimmed.startsWith("8")) trimmed else null
            }
            if (!id.startsWith("be-sncb_")) return null
            var rest = id.removePrefix("be-sncb_")
            if (rest.startsWith("S")) rest = rest.drop(1)
            val digits = rest.takeWhile { it in '0'..'9' }
            if (digits.length != 7 || !digits.startsWith("8")) return null
            val next = rest.getOrNull(7)
            return if (next == null || !(next.code < 128 && next.isLetterOrDigit())) digits else null
        }

        fun of(id: String, lat: Double?, lon: Double?): Country {
            uic(id)?.let { u -> return if (u.startsWith("84")) NL else if (u.startsWith("88")) BE else OTHER }
            if (id.startsWith("be-")) return BE
            if (lat != null && lon != null && inBelgium(lat, lon)) return BE
            return NL
        }

        /** A Transitous trip from a Belgian feed ("20261128_11:36_be-sncb_…"). */
        fun belgianTrip(tripId: String): Boolean {
            val parts = tripId.split('_', limit = 4)
            if (parts.size < 3 || parts[0].length != 8 || !parts[0].all { it in '0'..'9' }) return false
            return parts[2].startsWith("be-")
        }

        /** Every stop in Belgium (none: false): the Dutch rules (check out, student OV, NS's money back) don't apply. */
        fun onlyBelgium(stops: List<CountryStop>): Boolean = stops.isNotEmpty() && stops.all { of(it.id, it.lat, it.lon) == BE }

        /**
         * Where a train's live data at a station comes from: the NS code ("BD"), or "be:<UIC>" / "be:<name>" for iRail
         * (by name for the international 8800… codes iRail doesn't know). Null: neither. `ns`: NS's own lookup, asked
         * first, as before, for every stop that isn't plainly Belgian.
         */
        fun railSource(id: String, name: String, lat: Double?, lon: Double?, ns: (String, String) -> String?): String? {
            return when (of(id, lat, lon)) {
                BE -> {
                    val u = uic(id)
                    if (u != null && !u.startsWith("8800")) return "be:$u"
                    if (id.startsWith("be-") && !id.startsWith("be-sncb")) return null
                    val n = name.trim()
                    if (n.isEmpty()) null else "be:$n"
                }
                OTHER -> null
                NL -> ns(id, name)
            }
        }

        /** The relay's question for a `be:` source: `/be/liveboard` with `id` or `station`. Null: not one. */
        fun liveboardParams(source: String): List<Pair<String, String>>? {
            if (!source.startsWith("be:")) return null
            val s = source.removePrefix("be:")
            if (s.isEmpty()) return null
            return if (s.length == 7 && s.all { it in '0'..'9' }) listOf("id" to s) else listOf("station" to s)
        }

        /** Belgium, roughly (lat, lon), as iOS. */
        val OUTLINE: List<Pair<Double, Double>> = listOf(
            51.10 to 2.53, 51.37 to 3.36, 51.27 to 3.38, 51.23 to 3.45, 51.22 to 3.60, 51.20 to 3.79, 51.21 to 4.00, 51.24 to 4.10,
            51.27 to 4.20, 51.33 to 4.30, 51.35 to 4.38, 51.45 to 4.40, 51.475 to 4.47, 51.44 to 4.55, 51.42 to 4.68, 51.43 to 4.80,
            51.40 to 4.93, 51.42 to 5.04, 51.33 to 5.10, 51.28 to 5.20, 51.25 to 5.32, 51.23 to 5.48, 51.255 to 5.54, 51.22 to 5.58,
            51.20 to 5.75, 51.12 to 5.80, 51.00 to 5.76, 50.90 to 5.68, 50.83 to 5.64, 50.78 to 5.68, 50.76 to 5.68, 50.74 to 5.78,
            50.75 to 6.00, 50.62 to 6.30, 50.32 to 6.42, 50.13 to 6.15, 49.80 to 5.85, 49.50 to 5.82, 49.48 to 5.45, 49.70 to 5.10,
            49.90 to 4.85, 50.17 to 4.88, 49.95 to 4.40, 50.00 to 4.13, 50.32 to 4.02, 50.40 to 3.65, 50.55 to 3.25, 50.72 to 3.05,
            50.80 to 2.85, 50.75 to 2.60,
        )

        fun inBelgium(lat: Double, lon: Double): Boolean {
            if (lat !in 49.4..51.6 || lon !in 2.4..6.5) return false
            var inside = false
            var j = OUTLINE.size - 1
            for (i in OUTLINE.indices) {
                val (yi, xi) = OUTLINE[i]
                val (yj, xj) = OUTLINE[j]
                if ((yi > lat) != (yj > lat)) {
                    val x = xj + (lat - yj) / (yi - yj) * (xi - xj)
                    if (lon < x) inside = !inside
                }
                j = i
            }
            return inside
        }
    }
}
