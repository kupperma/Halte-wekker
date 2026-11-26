package nl.haltewekker.friends

import kotlin.math.roundToInt

// Friends (0.28), the iOS `FriendCompare.swift`: timetables side by side (you and a friend, or a group), per day this
// week and next: who has class when, the free time you have together. Plain values, tested.

data class ComparePerson(val id: String, val name: String, val isMe: Boolean = false, val timetable: TimetableShare? = null, val area: TimetableArea? = null)

data class PersonDay(val id: String, val known: Boolean, val classes: List<TimetableClass>) {
    val hasSchool: Boolean get() = known && classes.isNotEmpty()
    val first: Double? get() = classes.firstOrNull()?.start
    /** The latest end time, when it's after the last start (null: not known). */
    val lastEnd: Double?
        get() {
            val lastStart = classes.maxOfOrNull { it.start } ?: return null
            val e = classes.mapNotNull { it.end }.maxOrNull() ?: return null
            return if (e > lastStart) e else null
        }
}

data class CompareDay(val key: String, val people: List<PersonDay>) {
    fun person(id: String) = people.firstOrNull { it.id == id }
    val atSchool: List<PersonDay> get() = people.filter { it.hasSchool }
    val shared: Boolean get() = atSchool.size >= 2
}

data class FreeSlot(val start: Double, val end: Double, val ids: List<String>) {
    val minutes: Int get() = ((end - start) / 60).roundToInt()
}

object Compare {
    const val MIN_FREE = 30 * 60.0

    /** Today to Sunday, then next Monday to Sunday; Saturday and Sunday only when someone has class. */
    fun days(people: List<ComparePerson>, now: Double): List<CompareDay> {
        val today = TimetableDays.localDate(now)
        val weekday = today.dayOfWeek.value % 7 + 1          // 1 Sunday … 7 Saturday
        val toSunday = (8 - weekday) % 7
        val count = toSunday + 1 + 7
        val byPerson = people.map { p -> p to (p.timetable?.let { TimetableDays.byDay(it.classes) } ?: emptyMap()) }
        val out = mutableListOf<CompareDay>()
        for (i in 0 until count) {
            val d = today.plusDays(i.toLong())
            val key = TimetableDays.key(d)
            val list = byPerson.map { (p, days) ->
                val known = p.timetable?.covers(key) ?: false
                PersonDay(p.id, known, if (known) days[key] ?: emptyList() else emptyList())
            }
            val wd = d.dayOfWeek.value % 7 + 1
            if ((wd == 1 || wd == 7) && list.none { it.hasSchool }) continue
            out.add(CompareDay(key, list))
        }
        return out
    }

    /** A person's gaps between classes (overlapping classes count as one; a class without an end runs into the next). */
    fun free(p: PersonDay): List<Pair<Double, Double>> {
        if (!p.hasSchool) return emptyList()
        val blocks = mutableListOf<Pair<Double, Double?>>()
        for (c in p.classes.sortedBy { it.start }) {
            val last = blocks.lastOrNull()
            if (last != null && last.second != null && c.start < last.second!!) {
                val e = last.second!!
                blocks[blocks.size - 1] = last.first to maxOf(c.end ?: e, e)
            } else if (last != null && last.second == null) {
                blocks[blocks.size - 1] = last.first to c.end
            } else {
                blocks.add(c.start to c.end)
            }
        }
        val gaps = mutableListOf<Pair<Double, Double>>()
        for (i in 0 until maxOf(0, blocks.size - 1)) {
            val e = blocks[i].second ?: continue
            val next = blocks[i + 1].first
            if (next - e >= 1) gaps.add(e to next)
        }
        return gaps
    }

    fun freeTogether(d: CompareDay, limit: Int = 2): List<FreeSlot> {
        data class G(val id: String, val start: Double, val end: Double)
        val gaps = d.atSchool.flatMap { p -> free(p).map { G(p.id, it.first, it.second) } }
        if (gaps.size < 2) return emptyList()
        val cuts = gaps.flatMap { listOf(it.start, it.end) }.toSortedSet().toList()
        val segs = mutableListOf<FreeSlot>()
        for (i in 0 until maxOf(0, cuts.size - 1)) {
            val a = cuts[i]; val b = cuts[i + 1]
            val ids = gaps.filter { it.start <= a && it.end >= b }.map { it.id }.toSortedSet().toList()
            if (ids.size < 2) continue
            val last = segs.lastOrNull()
            if (last != null && last.end == a && last.ids == ids) segs[segs.size - 1] = last.copy(end = b)
            else segs.add(FreeSlot(a, b, ids))
        }
        val best = segs.filter { it.end - it.start >= MIN_FREE }
            .sortedWith(compareByDescending<FreeSlot> { it.ids.size }.thenByDescending { it.end - it.start })
        return best.take(limit).sortedBy { it.start }
    }

    fun nextShared(days: List<CompareDay>, now: Double): String? {
        for (d in days) {
            if (!d.shared) continue
            val latest = d.atSchool.mapNotNull { it.first }.maxOrNull()
            if (latest != null && latest > now) return d.key
        }
        return null
    }
}

object CompareWords {
    fun names(list: List<String>): String = if (list.size <= 1) list.firstOrNull() ?: "" else list.dropLast(1).joinToString(", ") + " and " + list.last()

    fun day(p: PersonDay): String {
        if (!p.known) return "Not shared"
        val f = p.first ?: return "No classes"
        val n = p.classes.size
        val count = if (n == 1) "1 class" else "$n classes"
        return p.lastEnd?.let { "${TimetableDays.hhmm(f)}–${TimetableDays.hhmm(it)} · $count" } ?: "From ${TimetableDays.hhmm(f)} · $count"
    }

    fun free(s: FreeSlot, name: (String) -> String): String =
        "Free together ${TimetableDays.hhmm(s.start)}–${TimetableDays.hhmm(s.end)} · ${names(s.ids.map(name))}"

    fun lesson(c: TimetableClass): String {
        var s = TimetableDays.hhmm(c.start)
        c.end?.let { s += "–" + TimetableDays.hhmm(it) }
        c.title?.let { s += " $it" }
        c.room?.let { s += " · $it" }
        return s
    }
}
