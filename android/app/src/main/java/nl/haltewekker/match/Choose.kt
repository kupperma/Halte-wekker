package nl.haltewekker.match

/** The one shown, this look: passes, fails, or not sure yet (iOS `ShownVerdict`). */
enum class ShownVerdict { PASSES, NOT_SURE, FAILS }

/** One look while choosing (iOS `ChoiceLook`, see `VehicleMatch.choose`). */
data class ChoiceLook(
    val decision: Decision,
    val alive: List<String>,
    val settle: String?,
    val why: Why?,
    val shown: ShownVerdict?,
    val shownFailing: Boolean,
) {
    enum class Why { DECIDED, ONLY_ONE_LEFT, TIMED_OUT, BY_GPS, SPLIT, DEPARTED, FAR_BY_GPS }
}

/** A choice that ran out of time (12 minutes) without being sure: between which ones, and when. */
data class TimedOut(val ids: Set<String>, val at: Double)

/** What a choice carries from look to look (iOS `candMisses`, `candSwitch`, `candGPS`). */
class ChoiceRun {
    val misses = HashMap<String, Int>()
    var state = SwitchState()
    var gps = GPSChoice()
    fun reset() { misses.clear(); state = SwitchState(); gps = gps.restart() }
}

/**
 * (A7) The ride's choice between buses or trains that fit about as well (iOS `VehicleMatch.choose` and its pieces,
 * 0.26.1 – 0.39.1), with the same numbers.
 */
const val DROP_AFTER = 2
const val FALLBACK_AFTER = 60.0
const val OFF_ROAD_BUS = 300.0
const val OFF_ROAD_TRAIN = 700.0

/** The usable fixes of the last 30 s: how many, and the time they span. */
fun VehicleMatch.spread(fixes: List<Fix>): Pair<Int, Double> {
    val recent = lastWindow(fixes)
    val newest = recent.maxOfOrNull { it.t } ?: return 0 to 0.0
    return recent.size to newest - recent.minOf { it.t }
}

/** The best `limit` of the ranked ones, always with `keep` when it passed (it takes the last place). */
fun VehicleMatch.top(ranked: List<Ranked>, keep: String?, limit: Int = 10): List<Ranked> {
    if (limit <= 0) return emptyList()
    val out = ranked.take(limit).toMutableList()
    if (keep != null && out.none { it.id == keep }) {
        val k = ranked.firstOrNull { it.id == keep }
        if (k != null) { if (out.size >= limit) out.removeAt(out.size - 1); out.add(k) }
    }
    return out
}

fun VehicleMatch.fallbackSure(enough: Boolean, leftSince: Double?, now: Double, after: Double = FALLBACK_AFTER): Boolean {
    if (enough) return true
    val l = leftSince ?: return false
    return now - l >= after
}

fun VehicleMatch.heldSince(since: Double?, holds: Boolean, now: Double): Double? = if (holds) (since ?: now) else null

/** A failure (not "not sure") adds a miss; a success resets it. Those with < 2 misses, plus `keeping` always. */
fun VehicleMatch.prune(judged: List<Judgement>, misses: MutableMap<String, Int>, keeping: Set<String>): List<Judgement> {
    for (j in judged) {
        val why = j.why
        if (why == null) misses.remove(j.id) else if (!why.notSure) misses[j.id] = (misses[j.id] ?: 0) + 1
    }
    return judged.filter { it.id in keeping || (misses[it.id] ?: 0) < DROP_AFTER }
}

/** Off its road by today's check: your last fix at least 300 m from a bus's road, 700 m from a train's. */
fun VehicleMatch.offRoad(metres: Double?, isTrain: Boolean): Boolean {
    val m = metres ?: return false
    return m >= (if (isTrain) OFF_ROAD_TRAIN else OFF_ROAD_BUS)
}

fun VehicleMatch.verdict(r: Verdict?, offRoad: Boolean): ShownVerdict = when {
    r is Verdict.Pass -> ShownVerdict.PASSES
    r is Verdict.Fail && !r.why.notSure -> ShownVerdict.FAILS
    else -> if (offRoad) ShownVerdict.FAILS else ShownVerdict.NOT_SURE
}

/** Choosing again between the same ones as a choice that ran out of time less than 10 minutes ago: no use. */
fun VehicleMatch.sameChoice(ids: List<String>, last: TimedOut?, now: Double, within: Double = 600.0): Boolean {
    val l = last ?: return false
    return ids.toSet() == l.ids && now - l.at < within
}

/**
 * One look while choosing between `ids` (iOS `VehicleMatch.choose` with `GPSChoice`, `nudge` and `departed`): evidence
 * decides, the one shown only wins a real tie. See the iOS doc comment for every rule; the order of the checks is the
 * same: the roads parted, far by its own GPS (0.39.1), by its own GPS, left the stop with you (0.38), then `decide`;
 * after `timeout` the one shown (or, failing, the best).
 */
fun VehicleMatch.choose(ids: List<String>, judged: List<Judgement>, shown: String?, shownOffRoad: Boolean, choosingFor: Double,
                        run: ChoiceRun, now: Double, timeout: Double = 12 * 60.0, nudge: Map<String, Double> = emptyMap(),
                        departed: String? = null): ChoiceLook {
    val fits = ChooseGPS.noteGPSFits(judged, run.gps.fitAt, now)
    run.gps = run.gps.copy(fitAt = fits)
    val soft = ChooseGPS.soften(judged, fits, now)
    val (g1, gpsPick) = ChooseGPS.gpsLook(ids, soft, run.gps, now)
    run.gps = g1
    val splits = soft.filter { ChooseGPS.roadsParted(it) }.map { it.id }.toSet()
    val tracked = soft.map { it.id }.toSet()
    val mineJudged = soft.firstOrNull { it.id == shown }
    val mine = mineJudged?.result
    var shownVerdict: ShownVerdict? = shown?.let { verdict(mine, shownOffRoad) }
    val before: Int? = shown?.let { run.misses[it] }
    val protected = (run.gps.fitAt.keys - splits).toMutableSet()
    if (shown != null) protected.add(shown)
    var pruned = prune(soft, run.misses, protected)
    for (id in splits) if (id != shown) run.misses[id] = maxOf(run.misses[id] ?: 0, DROP_AFTER)
    pruned = pruned.filter { it.id == shown || it.id !in splits }
    val ranked = ChooseGPS.nudged(rank(pruned, planned = null), nudge)
    val live = liveIds(soft)
    val failsByTimes = mineJudged?.let { timesOnly(it) } ?: false
    val bestTimetableOnly = ranked.firstOrNull()?.let { it.id !in live } ?: false
    val byTimesOnly = !shownOffRoad && failsByTimes && bestTimetableOnly
    if (shown != null && byTimesOnly) {
        if (before == null) run.misses.remove(shown) else run.misses[shown] = before
        shownVerdict = ShownVerdict.NOT_SURE
    }
    if (shown != null && shownVerdict == ShownVerdict.FAILS && verdict(mine, false) != ShownVerdict.FAILS) run.misses[shown] = (run.misses[shown] ?: 0) + 1
    val kept = pruned.map { it.id }.toSet()
    val alive = ids.filter { it in kept || it !in tracked }
    val (g2, departPick) = ChooseGPS.departLook(departed, soft, alive, run.gps)
    run.gps = g2
    val unsure = ids.filter { it !in tracked }.toMutableSet()
    for (j in soft) if (j.why?.notSure == true) unsure.add(j.id)
    if (shown != null && shownVerdict == ShownVerdict.FAILS) unsure.remove(shown)
    if (shown != null && byTimesOnly) unsure.add(shown)
    val (d0, st) = decide(shown, ranked, live, unsure, run.state, now, margin = ChooseGPS.CHOOSE_MARGIN)
    run.state = st
    var decision = d0
    val failing = !byTimesOnly && (shown?.let { (run.misses[it] ?: 0) >= DROP_AFTER } ?: false)
    val shownSplit = shown?.let { s -> s in splits || (shownOffRoad && soft.any { it.id != s && ChooseGPS.passedByGPS(it) }) } ?: false
    var settle: String? = null
    var why: ChoiceLook.Why? = null
    val rescue = ChooseGPS.gpsRescue(shown, soft, alive, run.gps.fitAt, splits)
    val other = if (shownSplit) ranked.firstOrNull { it.id != shown } else null
    if (other != null) {
        decision = Decision.SwitchTo(other.id); settle = other.id; why = ChoiceLook.Why.SPLIT
    } else if (rescue != null) {
        decision = Decision.SwitchTo(rescue); settle = rescue; why = ChoiceLook.Why.FAR_BY_GPS
    } else if (gpsPick != null && gpsPick != shown && gpsPick in alive) {
        decision = Decision.SwitchTo(gpsPick); settle = gpsPick; why = ChoiceLook.Why.BY_GPS
    } else if (departPick != null) {
        decision = if (departPick == shown) Decision.Keep(departPick) else Decision.SwitchTo(departPick); settle = departPick; why = ChoiceLook.Why.DEPARTED
    } else {
        when (val d = decision) {
            is Decision.SwitchTo -> { settle = d.id; why = ChoiceLook.Why.DECIDED }
            is Decision.Keep -> if (alive == listOf(d.id)) { settle = d.id; why = ChoiceLook.Why.ONLY_ONE_LEFT }
            else -> {}
        }
    }
    if (settle == null && choosingFor > timeout) {
        settle = if (failing && ranked.isNotEmpty()) ranked.first().id
        else if (shown != null && shown in alive) shown
        else ranked.firstOrNull()?.id
        if (settle != null) why = ChoiceLook.Why.TIMED_OUT
    }
    if (settle != null) run.gps = run.gps.restart()
    return ChoiceLook(decision, alive, settle, why, shownVerdict, failing)
}
