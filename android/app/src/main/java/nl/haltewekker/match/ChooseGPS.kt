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
) {
    fun restart() = copy(leader = null, looks = 0, lastAt = null)
}

object ChooseGPS {
    const val GPS_MEMORY = 90.0
    const val GPS_LOOKS = 2
    const val GPS_RUN_GAP = 60.0
    const val CHOOSE_MARGIN = 30.0
    const val SPLIT_METRES = 300.0

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
}
