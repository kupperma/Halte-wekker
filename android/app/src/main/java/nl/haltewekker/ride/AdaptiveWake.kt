package nl.haltewekker.ride

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.max
import kotlin.math.min

// (A8, iOS 0.39 `AdaptiveWake.swift`) the alarm by time learns, per mode, how much time you had left once you stopped
// it: a minute earlier when that's too little again and again, a minute back with plenty of room; never later than your
// setting, at most 3 (train) / 2 (bus) minutes. The distance rule stays as it was. Plain values, tested.

/** One ring before your stop: seconds ring → Stop alarm (null: still ringing at the stop), ring → at the stop. */
@Serializable
data class WakeSample(val train: Boolean, val react: Double?, val lead: Double, val at: Double)

@Serializable
data class WakeBook(
    val on: Boolean = true,
    val samples: List<WakeSample> = emptyList(),
    val trainExtra: Int = 0,
    val busExtra: Int = 0,
) {
    val isEmpty: Boolean get() = samples.isEmpty() && trainExtra == 0 && busExtra == 0

    fun extra(isTrain: Boolean) = if (isTrain) trainExtra else busExtra

    /** A ride's ring noted; the new book, and whether the minutes moved. */
    fun add(s: WakeSample): Pair<WakeBook, Boolean> {
        if (!AdaptiveWake.valid(s)) return this to false
        var list = samples + s
        val mine = list.count { it.train == s.train }
        if (mine > AdaptiveWake.KEEP) {
            var drop = mine - AdaptiveWake.KEEP
            list = list.filter { x -> if (drop > 0 && x.train == s.train) { drop--; false } else true }
        }
        val now = extra(s.train)
        val next = AdaptiveWake.step(list.filter { it.train == s.train }, now, s.train)
        val b = copy(samples = list, trainExtra = if (s.train) next else trainExtra, busExtra = if (s.train) busExtra else next)
        return b to (next != now)
    }
}

object AdaptiveWake {
    const val KEEP = 10
    const val NEEDED = 3
    const val WINDOW = 5
    const val MAX_TRAIN = 3
    const val MAX_BUS = 2
    const val READY = 75.0
    const val ROOMY = 75.0 + 150
    const val LEAD_MIN = 30.0
    const val LEAD_MAX = 20 * 60.0

    fun maxExtra(isTrain: Boolean) = if (isTrain) MAX_TRAIN else MAX_BUS

    fun valid(s: WakeSample): Boolean {
        if (!s.lead.isFinite() || s.lead < LEAD_MIN || s.lead > LEAD_MAX) return false
        val r = s.react ?: return true
        return r.isFinite() && r >= 0 && r <= s.lead + 300
    }

    fun spare(s: WakeSample): Double { val r = s.react ?: return 0.0; return max(0.0, s.lead - r) }

    fun step(rides: List<WakeSample>, extra: Int, isTrain: Boolean): Int {
        val top = maxExtra(isTrain)
        val now = min(top, max(0, extra))
        val mine = rides.filter { it.train == isTrain && valid(it) }
        if (mine.size < NEEDED) return now
        val m = median(mine.takeLast(WINDOW).map(::spare)) ?: return now
        if (m < READY) return min(top, now + 1)
        if (m > ROOMY) return max(0, now - 1)
        return now
    }

    fun minutes(setting: Int, extra: Int, on: Boolean, isTrain: Boolean): Int =
        if (!on) setting else setting + min(maxExtra(isTrain), max(0, extra))

    fun effective(s: WakeSettings, b: WakeBook) = s.copy(
        trainMinutes = minutes(s.trainMinutes, b.trainExtra, b.on, true),
        busMinutes = minutes(s.busMinutes, b.busExtra, b.on, false))

    fun summary(b: WakeBook, by: WakeBy): String {
        if (!b.on) return "Off"
        if (by != WakeBy.TIME) return "Only when waking by time"
        val t = b.trainExtra; val u = b.busExtra
        if (t == 0 && u == 0) {
            val most = max(b.samples.count { it.train }, b.samples.count { !it.train })
            if (most < NEEDED) { val left = NEEDED - most; return "Learning: $left more ride${if (left == 1) "" else "s"}" }
            return "Learned: as you set it"
        }
        if (t > 0 && u > 0) return if (t == u) "Learned: wakes you $t min earlier" else "Learned: wakes you $u min earlier on buses, $t on trains"
        return if (t > 0) "Learned: wakes you $t min earlier on trains" else "Learned: wakes you $u min earlier on buses"
    }

    private fun median(xs: List<Double>): Double? {
        val s = xs.sorted()
        if (s.isEmpty()) return null
        return if (s.size % 2 == 1) s[s.size / 2] else (s[s.size / 2 - 1] + s[s.size / 2]) / 2
    }
}

/** (A8, iOS 0.39 `GetReady`) a quiet "Get ready" once the vehicle is at the stop before yours, before the alarm rang. */
object GetReady {
    const val ID_PREFIX = "ready-"
    const val EARLY = 30.0
    const val FARTHEST = 15 * 60.0
    const val ALARM_GAP = 60.0

    fun before(count: Int): Int? = if (count >= 3) count - 2 else null

    fun due(beforeYours: Double?, yours: Double?, now: Double, alarmWithin: Double, asleep: Boolean, told: Boolean): Boolean {
        if (!asleep || told || beforeYours == null || yours == null || yours <= beforeYours) return false
        if (now < beforeYours - EARLY) return false
        val left = yours - now
        return left > max(0.0, alarmWithin) + ALARM_GAP && left <= FARTHEST
    }

    fun words(stop: String, secondsLeft: Double?): Pair<String, String> {
        val s = WristNotice.stop(stop)
        val about = secondsLeft?.let { ", about ${WristNotice.minutes(it)}" } ?: ""
        return "Get ready: $s is next" to "Your stop is the next one$about. The alarm still rings before it."
    }

    fun id(tripStart: Double?, leg: Int) = "$ID_PREFIX${(tripStart ?: 0.0).toLong()}-$leg"
}

/** (A8) What the adaptive wake-up learned, on this phone only (`no_backup` preferences). */
object WakeBookStore {
    private const val KEY = "wake.book.v1"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    val book = kotlinx.coroutines.flow.MutableStateFlow(WakeBook())
    private var prefs: android.content.SharedPreferences? = null

    fun load(c: android.content.Context) {
        if (prefs != null) return
        val p = c.applicationContext.getSharedPreferences("haltewekker.wake", android.content.Context.MODE_PRIVATE)
        prefs = p
        p.getString(KEY, null)?.let { s -> try { book.value = json.decodeFromString(WakeBook.serializer(), s) } catch (_: Exception) {} }
    }

    fun set(b: WakeBook) { book.value = b; prefs?.edit()?.putString(KEY, json.encodeToString(WakeBook.serializer(), b))?.apply() }

    /** A ring noted; true: the minutes moved. */
    fun add(s: WakeSample): Boolean { val (b, moved) = book.value.add(s); set(b); return moved }

    fun reset() = set(WakeBook(on = book.value.on))

    /** The wake settings the rules go by: yours, with what it learned on top. */
    fun effective(s: WakeSettings) = AdaptiveWake.effective(s, book.value)
}
