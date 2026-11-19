package nl.haltewekker.friends

// Friends (A5, iOS 0.31 `SeatMap.swift`): where you sit, roughly. The seat picker's sums as plain values, tested
// without NS or the UI.
//
// The whole train: its coaches from NS's drawing (units and their coaches), each single- or double-deck by the unit's
// type; without NS, the coaches NS counted (or 6), a Sprinter single-deck and an Intercity double-deck. A coach, seen
// from the platform: 11 windows a row (one row, or two: the top row the upper deck, the bottom row the lower). Your
// window goes to friends with your coach, counted from the back of the coach (`TravelState.Seat`).

object SeatMap {
    /** Windows in a row: it's "where roughly", not a seat number. */
    const val WINDOWS = 11
    /** Coaches drawn when nothing says how many. */
    const val DEFAULT_COACHES = 6
    /** The most coaches drawn (NS's longest trains are 12; two coupled sets of 6, plus a little). */
    const val MAX_COACHES = 16

    enum class Deck(val raw: String) {
        UPPER("upper"), LOWER("lower"), NONE("none");

        /** "upper deck", "lower deck", null (one deck). */
        val words: String? get() = when (this) { UPPER -> "upper deck"; LOWER -> "lower deck"; NONE -> null }

        companion object { fun of(raw: String): Deck = entries.firstOrNull { it.raw == raw } ?: NONE }
    }

    fun deck(s: TravelState.Seat): Deck = Deck.of(s.deck)

    // MARK: the train

    private val DOUBLE = listOf("VIRM", "DDZ", "DDIRM", "NID", "DDAR", "MDDM", "DDM")
    private val SINGLE = listOf("SNG", "SLT", "FLIRT", "SGM", "GTW", "ICM", "ICNG", "ICR", "ICE", "THALYS", "EUROSTAR",
        "EUROCITY", "I11", "TRAXX", "LINT", "PROTOS", "WINK", "DESIRO", "SPRINTER", "MAT64")

    /**
     * Whether a unit of this type has two decks (NS's `type`, or its drawing's name, like "VIRM-6", "virmm1_6",
     * "DDZ-4", "SNG-3", "nsr_flirt_4"). Null: a type this doesn't know.
     */
    fun doubleDeck(kind: String): Boolean? {
        val k = kind.uppercase().filter { it.isLetterOrDigit() }
        if (k.isEmpty()) return null
        if (DOUBLE.any { k.startsWith(it) || k.contains(it) }) return true
        if (SINGLE.any { k.startsWith(it) || k.contains(it) }) return false
        return null
    }

    /** Without NS's word: an Intercity ("IC", "ICD", "Intercity") has two decks; a Sprinter and anything else one. */
    fun defaultDouble(line: String?): Boolean =
        (line ?: "").uppercase().trim() in setOf("IC", "ICD", "INTERCITY", "INTERCITY DIRECT", "IC DIRECT")

    /**
     * One coach as the picker draws it. `drawn`: from the left, 0-based; `n`: its number as friends get it. (A5.1)
     * `first`: its 1st-class parts (`SeatClass`): empty none; null not known.
     */
    data class Coach(val drawn: Int, val n: Int, val front: Boolean, val double: Boolean, val first: List<SeatClass.Section>? = null) {
        /** 2nd, part 1st, all 1st (null: not known). */
        val kind: SeatClass.Kind? get() = first?.let { SeatClass.kind(it) }
    }

    /** The whole train, left to right. `dir`: the side the front is drawn on ("left"/"right"; null: not known). */
    data class Train(val coaches: List<Coach>, val dir: String?, val fromNS: Boolean) {
        val count: Int get() = coaches.size
        val anyDouble: Boolean get() = coaches.any { it.double }
        /** (A5.1) Some coach has 1st class drawn in. */
        val anyFirst: Boolean get() = coaches.any { !it.first.isNullOrEmpty() }
        /** (A5.1) Some coach's 1st class isn't known (NS's drawing isn't one the table has). */
        val firstUnknown: Boolean get() = coaches.any { it.first == null }
    }

    /**
     * The train from NS's drawing: its units (with each one's type in `kinds`, the same order) and `totalCars` (NS's
     * length), going `dir`. Without units: `totalCars` coaches (or 6), front on the right (so you can still say
     * "third from the front"), decks by the line. (A5.1) Each unit's drawing's name in `drawings` and its 1st-class
     * seats in `firstSeats` (the same order) give each coach its 1st class (`SeatClass`); the guess has none known.
     */
    fun train(units: List<CoachMap.Unit>, kinds: List<String>, totalCars: Int, dir: String?, line: String?,
              drawings: List<String> = emptyList(), firstSeats: List<Int?> = emptyList()): Train {
        val fallbackDouble = defaultDouble(line)
        val spots = if (units.isEmpty()) emptyList() else CoachMap.spots(units, totalCars)
        if (spots.isEmpty()) {
            val n = minOf(MAX_COACHES, maxOf(1, if (totalCars > 0) totalCars else DEFAULT_COACHES))
            val list = (0 until n).map { i ->
                val (num, front) = CoachMap.number(i, n, "right")
                Coach(i, num, front, fallbackDouble)
            }
            return Train(list, "right", false)
        }
        val shown = spots.take(MAX_COACHES)
        // the unit each coach is in: the one its middle falls in
        val unitOf = spots.map { s ->
            val u = units.indexOfLast { it.x <= s.mid + 1e-9 }
            minOf(maxOf(0, u), units.size - 1)
        }
        val list = shown.map { s ->
            val u = unitOf[s.drawn]
            val kind = if (u < kinds.size) kinds[u] else ""
            val double = doubleDeck(kind) ?: fallbackDouble
            val (num, front) = CoachMap.number(s.drawn, shown.size, dir)
            // its place in its unit, and the unit's coaches (as drawn)
            val inUnit = unitOf.subList(0, s.drawn).count { it == u }
            val cars = unitOf.count { it == u }
            val image = if (u < drawings.size) drawings[u] else ""
            val seats = if (u < firstSeats.size) firstSeats[u] else null
            val first = SeatClass.sections(SeatClass.drawing(image, kind), inUnit, cars, seats)
            Coach(s.drawn, num, front, double, first)
        }
        return Train(list, dir, true)
    }

    // MARK: the windows

    /**
     * The window drawn at `drawn` (from the left, 0-based) as a seat counts it: from the back of the coach when the
     * front is drawn on the right (the back is then on the left) or the left; from the left when it isn't known.
     */
    fun window(drawn: Int, of: Int = WINDOWS, dir: String?): Int = if (dir == "left") of - drawn else drawn + 1

    /** Back to the drawing: where window `w` is drawn (from the left, 0-based). Null: not a window of `of`. */
    fun drawnWindow(w: Int, of: Int = WINDOWS, dir: String?): Int? {
        if (w < 1 || w > of) return null
        return if (dir == "left") of - w else w - 1
    }

    /** The seat for a window tapped in a coach: the top row is the upper deck, the bottom the lower; one row: "none". */
    fun seat(drawn: Int, row: Int, double: Boolean, dir: String?): TravelState.Seat {
        val deck = if (double) (if (row == 0) Deck.UPPER else Deck.LOWER) else Deck.NONE
        return TravelState.Seat(deck.raw, window(drawn, WINDOWS, dir), WINDOWS)
    }

    /** A seat as read from a friend: kept only when it makes sense (a window of 1…40, of at most 40). */
    fun valid(s: TravelState.Seat?): TravelState.Seat? {
        if (s == null || s.of < 1 || s.of > 40 || s.w < 1 || s.w > s.of) return null
        return s
    }

    /** (A5.1) Whether a seat in coach `c` is in its 1st class: the whole coach is, or its window (in its row) is. */
    fun isFirst(s: TravelState.Seat?, c: Coach, dir: String?): Boolean {
        val first = c.first ?: return false
        if (SeatClass.kind(first) == SeatClass.Kind.FIRST) return true
        if (s == null) return false
        val w = drawnWindow(s, dir) ?: return false
        return SeatClass.isFirst(w, row(s, c.double), c.double, first)
    }

    /** (A5.1) Whether someone's coach (with its seat, if any) is in 1st class in this train (as drawn at `station`). */
    fun isFirst(c: TravelState.Coach, t: Train, station: String?): Boolean {
        val d = CoachMap.drawn(c, t.count, t.dir, station) ?: return false
        val coach = t.coaches.firstOrNull { it.drawn == d } ?: return false
        return isFirst(valid(c.seat), coach, t.dir)
    }

    /** Which row a seat is drawn in: 0 the top (upper deck, or the only row), 1 the bottom (lower deck). */
    fun row(s: TravelState.Seat, double: Boolean): Int = if (double && deck(s) == Deck.LOWER) 1 else 0

    /** A seat drawn in a coach of `n` windows: its window scaled to `n` when the friend's app drew another number. */
    fun drawnWindow(s: TravelState.Seat, dir: String?, n: Int = WINDOWS): Int? {
        val v = valid(s) ?: return null
        // (rounded up, in whole numbers)
        val w = if (v.of == n) v.w else maxOf(1, minOf(n, (v.w * n + v.of - 1) / v.of))
        return drawnWindow(w, n, dir)
    }

    // MARK: words

    /** "1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st". */
    fun ordinal(n: Int): String {
        if ((n / 10) % 10 == 1) return "${n}th"
        return when (n % 10) { 1 -> "${n}st"; 2 -> "${n}nd"; 3 -> "${n}rd"; else -> "${n}th" }
    }

    /** "upper deck · 8th window from the back", "6th window from the back", "8th window from the left". */
    fun seatWords(s: TravelState.Seat, front: Boolean): String {
        val end = if (front) "from the back" else "from the left"
        val win = "${ordinal(s.w)} window $end"
        return deck(s).words?.let { "$it · $win" } ?: win
    }

    /**
     * "Coach 3 of 6 · upper deck · 8th window from the back"; without a seat 0.26's "Coach 3 of 6 · front". (A5.1)
     * `firstClass`: it's in 1st class (worked out from the train, never sent): "… · 1st class".
     */
    fun label(c: TravelState.Coach, firstClass: Boolean = false): String {
        val tail = if (firstClass) " · 1st class" else ""
        val s = valid(c.seat) ?: return CoachMap.label(c) + tail
        return "Coach ${c.n} of ${c.of} · ${seatWords(s, c.front)}$tail"
    }

    /** For TalkBack: "Coach 3, upper deck, window 8 from the back". */
    fun spoken(coach: Int, deck: Deck, window: Int, front: Boolean): String {
        val end = if (front) "from the back" else "from the left"
        val d = deck.words?.let { ", $it" } ?: ""
        return "Coach $coach$d, window $window $end"
    }

    /**
     * For TalkBack, a coach: "Coach 3 of 6, from the front, two decks" (A5.1: ", 1st class" all through, ", part 1st
     * class" for a part).
     */
    fun spokenCoach(c: Coach, total: Int): String {
        val from = if (c.front) ", from the front" else ""
        val cls = when (c.kind) { SeatClass.Kind.FIRST -> ", 1st class"; SeatClass.Kind.PART -> ", part 1st class"; else -> "" }
        return "Coach ${c.n} of $total$from${if (c.double) ", two decks" else ""}$cls"
    }
}
