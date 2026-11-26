package nl.haltewekker.match

/**
 * What the buses' own GPS said while choosing between them (iOS `ChooseGPS.swift`, 0.26.1): evidence decides, not
 * "the planned one". `fitAt`: when each last passed by a fresh fix of its own; `leader`/`looks`: the one that fitted
 * by its GPS while every other one failed, in looks in a row.
 */
data class GPSChoice(
    val fitAt: Map<String, Double> = emptyMap(),
    val leader: String? = null,
    val looks: Int = 0,
    val lastAt: Double? = null,
    /** (A7, iOS 0.38) the one that left the stop with you, in looks in a row it passed (`departLook`). */
    val departLeader: String? = null,
    val departLooks: Int = 0,
) {
    fun restart() = copy(leader = null, looks = 0, lastAt = null, departLeader = null, departLooks = 0)
}

object ChooseGPS {
    const val GPS_MEMORY = 90.0
    const val GPS_LOOKS = 2
    const val GPS_RUN_GAP = 60.0
    const val CHOOSE_MARGIN = 30.0
    const val SPLIT_METRES = 300.0
    const val DEPART_LOOKS = 2
    const val FAR_BUS = 1000.0
    const val FAR_TRAIN = 2500.0

    fun passedByGPS(j: Judgement): Boolean = j.evidence?.gps == true && j.result is Verdict.Pass

    fun noteGPSFits(judged: List<Judgement>, fits: Map<String, Double>, now: Double): Map<String, Double> {
        val out = fits.toMutableMap()
        for (j in judged) if (passedByGPS(j)) out[j.id] = now
        return out.filterValues { now - it <= GPS_MEMORY }
    }

    fun softened(j: Judgement, fitAt: Double?, now: Double): Boolean {
        if (fitAt == null || !VehicleMatch.timesOnly(j)) return false
        val ago = now - fitAt
        return ago in 0.0..GPS_MEMORY
    }

    fun soften(judged: List<Judgement>, fits: Map<String, Double>, now: Double): List<Judgement> =
        judged.map { if (softened(it, fits[it.id], now)) it.copy(result = Verdict.Fail(Reject.NO_TIMES)) else it }

    fun roadsParted(j: Judgement): Boolean {
        val e = j.evidence ?: return false
        if (j.why != Reject.OFF_ITS_PATH || !e.crossTrack.isFinite()) return false
        return e.crossTrack >= maxOf(SPLIT_METRES, 2 * e.accuracy)
    }

    /** This look's one by GPS: it passed by its own GPS and every other one failed for real, or passed `margin` worse. */
    fun gpsBest(ids: List<String>, judged: List<Judgement>, margin: Double = CHOOSE_MARGIN): String? {
        val byId = judged.associateBy { it.id }
        for (x in ids) {
            val jx = byId[x] ?: continue
            if (!passedByGPS(jx)) continue
            val cx = jx.cost ?: continue
            val others = ids.filter { it != x }
            if (others.isEmpty()) continue
            val beaten = others.all { y ->
                val jy = byId[y] ?: return@all false
                when (val r = jy.result) {
                    is Verdict.Fail -> !r.why.notSure
                    is Verdict.Pass -> (jy.realTime || jy.evidence?.gps == true) && r.cost >= cx + margin
                }
            }
            if (beaten) return x
        }
        return null
    }

    /** One look for the run. Returns the new run and the leader once it has `GPS_LOOKS` looks in a row. */
    fun gpsLook(ids: List<String>, judged: List<Judgement>, run: GPSChoice, now: Double): Pair<GPSChoice, String?> {
        var r = run
        val last = r.lastAt
        if (last != null && now - last > GPS_RUN_GAP) r = r.restart()
        val x = gpsBest(ids, judged)
        if (x != null) {
            r = if (r.leader == x) r.copy(looks = r.looks + 1, lastAt = now) else r.copy(leader = x, looks = 1, lastAt = now)
        } else {
            val l = r.leader
            if (l != null && contradicted(l, ids, judged)) r = r.restart()
        }
        val l = r.leader
        return r to (if (l != null && r.looks >= GPS_LOOKS) l else null)
    }

    private fun contradicted(leader: String, ids: List<String>, judged: List<Judgement>): Boolean {
        val mine = judged.firstOrNull { it.id == leader }
        val why = mine?.why
        if (why != null && !why.notSure) return true
        val cost = mine?.cost ?: Double.POSITIVE_INFINITY
        return judged.any { j ->
            j.id != leader && j.id in ids && (j.realTime || j.evidence?.gps == true) && (j.cost?.let { it < cost } ?: false)
        }
    }

    /**
     * (A7, iOS 0.38) one look for the one that left the stop with you (`departed`, from `DepartMatch.pick`): it's in the
     * running and passed this look, and no other one passed by its own GPS `CHOOSE_MARGIN` better while it didn't.
     * `DEPART_LOOKS` such looks in a row: that one. Any other look starts the run again.
     */
    fun departLook(departed: String?, judged: List<Judgement>, alive: List<String>, run: GPSChoice): Pair<GPSChoice, String?> {
        val d = departed
        val mine = d?.let { x -> judged.firstOrNull { it.id == x } }
        val cost = mine?.cost
        if (d == null || d !in alive || mine == null || cost == null) return run.copy(departLeader = null, departLooks = 0) to null
        val mineByGPS = passedByGPS(mine)
        val beaten = judged.any { j ->
            val c = j.cost
            j.id != d && j.id in alive && passedByGPS(j) && !mineByGPS && c != null && c + CHOOSE_MARGIN <= cost
        }
        if (beaten) return run.copy(departLeader = null, departLooks = 0) to null
        val r = if (run.departLeader == d) run.copy(departLooks = run.departLooks + 1) else run.copy(departLeader = d, departLooks = 1)
        return r to (if (r.departLooks >= DEPART_LOOKS) d else null)
    }

    /** (A7, iOS 0.39.1) failed by its own GPS, clearly far from you: not a times-only doubt, not off its path, not "not sure". */
    fun farByGPS(j: Judgement): Boolean {
        val e = j.evidence ?: return false
        val why = j.why ?: return false
        if (!e.gps || why.notSure || why == Reject.OFF_ITS_PATH) return false
        return kotlin.math.abs(e.offset) >= (if (j.isTrain) FAR_TRAIN else FAR_BUS)
    }

    /** The one shown is far by its own GPS: the other one of `alive` that fits by its own GPS, this look or a moment ago. */
    fun gpsRescue(shown: String?, judged: List<Judgement>, alive: List<String>, fits: Map<String, Double>, splits: Set<String>): String? {
        val s = shown ?: return null
        val mine = judged.firstOrNull { it.id == s } ?: return null
        if (!farByGPS(mine)) return null
        val others = alive.filter { it != s && it !in splits }
        var best: Pair<String, Double>? = null
        for (j in judged) {
            if (j.id !in others || !passedByGPS(j)) continue
            val c = j.cost ?: continue
            if (best == null || c < best.second) best = j.id to c
        }
        best?.let { return it.first }
        val recent = others.mapNotNull { id -> fits[id]?.let { id to it } }
        return recent.maxWithOrNull(Comparator { a, b -> if (a.second != b.second) a.second.compareTo(b.second) else b.first.compareTo(a.first) })?.first
    }

    /** The ranking with each one's cost moved by `nudge` (seconds; negative: better), best first, ties by id. */
    fun nudged(ranked: List<Ranked>, nudge: Map<String, Double>): List<Ranked> {
        if (nudge.isEmpty()) return ranked
        return ranked.map { Ranked(it.id, it.cost + (nudge[it.id] ?: 0.0)) }.sortedWith(compareBy<Ranked> { it.cost }.thenBy { it.id })
    }
}
