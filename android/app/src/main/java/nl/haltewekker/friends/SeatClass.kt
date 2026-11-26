package nl.haltewekker.friends

// Friends (A5.1, iOS 0.31.1 `SeatClass.swift`): where 1st class is in each coach, for the seat picker. Plain values,
// tested without NS or the UI.
//
// What NS says: NS's virtual-train answer (`/ns/train`, through the relay) lists a train's units (`materieeldelen`),
// each with its type ("VIRMm1 VI"), its drawing (`afbeelding`, ".../virmm1_6.png"), its coaches (`bakken`: empty
// objects, nothing in them) and its seats (`zitplaatsen.zitplaatsEersteKlas`: how many 1st-class seats the unit has).
// It doesn't say which coach the 1st class is in. NS's drawings do: they mark it, as the trains do, with "1" by the
// doors and a thin line along the 1st-class windows (on each deck). The table below is read off those drawings
// (vt.ns-mlab.nl/v1/images/<drawing>.png, November 2026; the spec's "As built (0.31.1)"): for each drawing, where its
// coaches meet (shares of the unit's length), and in each coach the 1st-class part (shares of the coach, from the left
// of the drawing; per deck in a double-deck coach). So it's NS's own picture, not the real seats: the picker says
// "1st class (about here)" for a part of a coach, and "1st class" for a coach that's 1st class all through. A unit NS
// says has no 1st-class seats gets none; a drawing not in the table (ICE, international trains): not known. Worked out
// on the phone from the train, never sent.

object SeatClass {
    /**
     * A 1st-class part of a coach: from `a` to `b`, shares of the coach as NS draws it, from its left. On `deck` in a
     * double-deck coach (UPPER, LOWER); NONE: on every deck (and the only one of a single-deck coach).
     */
    data class Section(val a: Double, val b: Double, val deck: SeatMap.Deck = SeatMap.Deck.NONE)

    /** A coach as a whole: no 1st class, a part of it, all of it. */
    enum class Kind { SECOND, PART, FIRST }

    /** One of NS's drawings: where its coaches meet (shares of the unit, inside it), and each coach's 1st-class parts, left to right. */
    data class Drawing(val edges: List<Double>, val coaches: List<List<Section>>)

    private val U = SeatMap.Deck.UPPER
    private val L = SeatMap.Deck.LOWER
    private fun s(a: Double, b: Double, deck: SeatMap.Deck = SeatMap.Deck.NONE) = Section(a, b, deck)

    /** The whole coach. */
    val WHOLE = Section(0.0, 1.0)

    private val virm4 = listOf(0.2523, 0.5033, 0.7477)
    private val virm6 = listOf(0.1688, 0.3323, 0.4997, 0.6677, 0.8312)
    private val ddzCab = listOf(s(0.21, 0.50, U), s(0.21, 0.37, L))
    private val ddzMid = listOf(s(0.59, 0.78, U), s(0.44, 0.78, L))
    private val virmmEnd = listOf(s(0.54, 0.76, U), s(0.46, 0.76, L))
    private val none = emptyList<Section>()
    private val icng8 = Drawing(listOf(0.1434, 0.2555, 0.3674, 0.5, 0.6326, 0.7445, 0.8566),
        listOf(none, none, listOf(s(0.27, 1.0)), listOf(s(0.0, 0.13)), listOf(s(0.87, 1.0)), listOf(s(0.0, 0.67)), none, none))

    /** NS's drawings, by file name (lower case, no ".png"). */
    val drawings: Map<String, Drawing> = mapOf(
        // VIRM (the first ones, "VIRM IV"/"VI"): 1st class in the middle, both decks (in the 4's second coach only below)
        "virm_4" to Drawing(virm4, listOf(none, listOf(s(0.45, 0.77, L)), listOf(s(0.22, 0.54)), none)),
        "virm_6" to Drawing(virm6, listOf(none, listOf(s(0.45, 0.77)), none, listOf(s(0.45, 0.78)), listOf(s(0.22, 0.55)), none)),
        // VIRMm (rebuilt): the upper deck's 1st class is shorter than the lower's
        "virmm1_4" to Drawing(virm4, listOf(none, virmmEnd, listOf(s(0.22, 0.44, U), s(0.22, 0.52, L)), none)),
        "virmm1_6" to Drawing(virm6, listOf(none, virmmEnd, none, virmmEnd, listOf(s(0.22, 0.44, U), s(0.22, 0.52, L)), none)),
        "virmm2_4" to Drawing(virm4, listOf(none, listOf(s(0.54, 0.76, U)), listOf(s(0.22, 0.45, U), s(0.22, 0.53, L)), none)),
        "virmm2_6" to Drawing(virm6, listOf(none, virmmEnd, none, listOf(s(0.54, 0.76, U)), listOf(s(0.22, 0.45, U), s(0.22, 0.53, L)), none)),
        // DDZ (the rebuilt DD-IRM): behind the cab, and in each middle coach with the bicycles
        "ddz_4" to Drawing(listOf(0.2648, 0.5263, 0.7878), listOf(ddzCab, none, ddzMid, none)),
        "ddz_6" to Drawing(listOf(0.1739, 0.3456, 0.5173, 0.689, 0.8607), listOf(ddzCab, none, ddzMid, none, ddzMid, none)),
        // ICM (the Koploper): part of the middle coach; the 4's third coach is 1st class all through
        "icm_3" to Drawing(listOf(0.333, 0.666), listOf(none, listOf(s(0.43, 0.89)), none)),
        "icm_4" to Drawing(listOf(0.2496, 0.4993, 0.75), listOf(none, none, listOf(WHOLE), none)),
        // ICNG: around the middle, over a gangway
        "icng_5" to Drawing(listOf(0.2159, 0.3847, 0.5844, 0.7841), listOf(none, none, listOf(s(0.25, 1.0)), listOf(s(0.0, 0.32)), none)),
        "icng_8" to icng8,
        // the Belgian-run ICNG (Amsterdam–Brussels, "icng_B_8"): drawn the same
        "icng_b_8" to icng8,
        // Sprinters: behind a cab (both ends; the SNG-3 only at one)
        "slt_4" to Drawing(listOf(0.2756, 0.5, 0.7237), listOf(listOf(s(0.24, 0.47)), none, none, listOf(s(0.53, 0.76)))),
        "slt_6" to Drawing(listOf(0.1903, 0.345, 0.4997, 0.6545, 0.8092), listOf(listOf(s(0.24, 0.47)), none, none, none, none, listOf(s(0.53, 0.76)))),
        "sng_3" to Drawing(listOf(0.3634, 0.6366), listOf(listOf(s(0.20, 0.42)), none, none)),
        "sng_4" to Drawing(listOf(0.2854, 0.5, 0.7146), listOf(listOf(s(0.20, 0.42)), none, none, listOf(s(0.58, 0.80)))),
        "nsr_flirt_3" to Drawing(listOf(0.361, 0.638), listOf(listOf(s(0.27, 0.41)), none, listOf(s(0.59, 0.73)))),
        "nsr_flirt_4" to Drawing(listOf(0.2824, 0.4994, 0.7164), listOf(listOf(s(0.27, 0.41)), none, none, listOf(s(0.59, 0.73)))),
    )

    // MARK: which drawing

    private val ROMAN = mapOf("ii" to "2", "iii" to "3", "iv" to "4", "v" to "5", "vi" to "6", "viii" to "8")

    /** The file name of NS's `afbeelding` (".../icng_B_8.png" → "icng_b_8"), lower case, without ".png". */
    fun imageKey(image: String): String {
        var file = image.split('/').last()
        if (file.lowercase().endsWith(".png")) file = file.dropLast(4)
        return file.lowercase()
    }

    /**
     * The drawing's name from NS's `afbeelding` (".../virmm1_6.png" → "virmm1_6"), else from the unit's type
     * ("VIRMm1 VI" → "virmm1_6", "DDZ 4" → "ddz_4", "Flirt 3" → "nsr_flirt_3"). Null: not one in the table.
     */
    fun drawing(image: String, type: String = ""): String? {
        val f = imageKey(image)
        if (drawings.containsKey(f)) return f
        val words = type.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.map { ROMAN[it] ?: it }
        if (words.isEmpty()) return null
        val k = words.joinToString("_")
        return listOf(k, "nsr_$k").firstOrNull { drawings.containsKey(it) }
    }

    // MARK: a coach

    /**
     * The 1st-class parts of coach `i` (from the left of the drawing, 0-based) of a unit drawn as `drawing` with `cars`
     * coaches. `firstSeats`: NS's count of the unit's 1st-class seats (0: none at all; null: not said). Null: not known
     * (a drawing not in the table, or NS lists another number of coaches than it draws).
     */
    fun sections(drawing: String?, coach: Int, cars: Int, firstSeats: Int?): List<Section>? {
        if (firstSeats == 0) return emptyList()
        val d = drawing?.let { drawings[it] } ?: return null
        if (d.coaches.size != cars || coach < 0 || coach >= cars) return null
        return d.coaches[coach]
    }

    fun kind(sections: List<Section>): Kind {
        if (sections.isEmpty()) return Kind.SECOND
        return if (sections.any { it.deck == SeatMap.Deck.NONE && it.a <= 0.02 && it.b >= 0.98 }) Kind.FIRST else Kind.PART
    }

    /**
     * Whether window `drawn` (from the left, 0-based, of `n`) in `row` (0 the top: the upper deck or the only one; 1 the
     * lower deck) is in a 1st-class part: its middle is.
     */
    fun isFirst(drawn: Int, row: Int, double: Boolean, sections: List<Section>, n: Int = SeatMap.WINDOWS): Boolean {
        if (n <= 0 || drawn < 0 || drawn >= n) return false
        val mid = (drawn + 0.5) / n
        val deck = if (double) (if (row == 0) SeatMap.Deck.UPPER else SeatMap.Deck.LOWER) else SeatMap.Deck.NONE
        return sections.any { s -> (s.deck == SeatMap.Deck.NONE || s.deck == deck || !double) && mid >= s.a - 1e-9 && mid <= s.b + 1e-9 }
    }

    /** The 1st-class windows of a row, as runs (first and last drawn window), left to right. */
    fun runs(row: Int, double: Boolean, sections: List<Section>, n: Int = SeatMap.WINDOWS): List<IntRange> {
        val out = mutableListOf<IntRange>()
        var start: Int? = null
        for (i in 0..n) {
            val on = i < n && isFirst(i, row, double, sections, n)
            if (on && start == null) start = i
            if (!on && start != null) { out.add(start..(i - 1)); start = null }
        }
        return out
    }

    /** Where along the coach (shares, from the left) any deck has 1st class, for the train strip's mark. Null: none. */
    fun span(sections: List<Section>): ClosedFloatingPointRange<Double>? {
        val a = sections.minOfOrNull { it.a } ?: return null
        val b = sections.maxOf { it.b }
        if (b <= a) return null
        return maxOf(0.0, a)..minOf(1.0, b)
    }

    // MARK: the whole unit

    /** A drawing's 1st-class parts as shares of the whole unit (any deck), merged where they touch. Null: not in the table. */
    fun unitZones(drawing: String): List<Pair<Double, Double>>? {
        val d = drawings[drawing] ?: return null
        val ends = listOf(0.0) + d.edges + listOf(1.0)
        val list = mutableListOf<Pair<Double, Double>>()
        d.coaches.forEachIndexed { i, secs ->
            if (i + 1 < ends.size) {
                val x0 = ends[i]; val w = ends[i + 1] - ends[i]
                for (s in secs) list.add((x0 + s.a * w) to (x0 + s.b * w))
            }
        }
        list.sortBy { it.first }
        val out = mutableListOf<Pair<Double, Double>>()
        for (z in list) {
            val last = out.lastOrNull()
            if (last != null && z.first <= last.second + 0.005) out[out.size - 1] = last.first to maxOf(last.second, z.second)
            else out.add(z)
        }
        return out
    }

    // MARK: words

    /** "1st class", "1st class (about here)" (a part of the coach), null (2nd class). */
    fun words(kind: Kind): String? = when (kind) {
        Kind.FIRST -> "1st class"
        Kind.PART -> "1st class (about here)"
        Kind.SECOND -> null
    }

    /** The picker's legend, after its "1" badge: "= 1st class (about here)", "… · gold coach: all 1st class". */
    fun legend(part: Boolean, whole: Boolean): String = when {
        part && whole -> "= 1st class (about here) · gold coach: all 1st class"
        !part && whole -> "= 1st class · gold coach: all 1st class"
        else -> "= 1st class (about here)"
    }

    /** The legend for TalkBack. */
    fun spokenLegend(part: Boolean, whole: Boolean): String {
        val p = "1st class is marked with a 1, about where it is"
        val w = "gold coaches are all 1st class"
        return when {
            part && whole -> "$p; $w"
            !part && whole -> TravelWords.capitalFirst(w)
            else -> p
        }
    }
}
