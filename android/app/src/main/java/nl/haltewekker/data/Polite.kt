package nl.haltewekker.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlin.math.max
import kotlin.math.min

/**
 * (0.10.0, iOS `Net.Polite`) kindness to a server that is free and run by volunteers (Transitous): a few requests at
 * a time, someone waiting on a screen first; an "HTTP 429, slow down" pauses everything that can wait.
 *
 * - At most `maxInFlight` requests at once, of which at most `maxBackground` background ones; a waiting urgent one
 *   always goes before any waiting background one.
 * - A 429 starts a pause of its `Retry-After` seconds (kept within `shortest`…`longest`), else `firstPause`; each
 *   further one (sent during the pause, or after it with no answer in between) doubles it, `longest` at most. One
 *   already on its way when the pause began only makes it last as long as it asks. An answer starts that over, and so
 *   does a pause that ended over `longest` ago.
 * - During a pause background requests aren't sent (turned away at once, the waiting ones too: `Refused`) and urgent
 *   ones go one at a time.
 */
class Polite(val maxInFlight: Int = 4, val maxBackground: Int = 2, val firstPause: Double = 20.0, val shortest: Double = 5.0,
             val longest: Double = 120.0, private val clock: () -> Double = { System.currentTimeMillis() / 1000.0 }) {
    enum class Lane { URGENT, BACKGROUND }

    /** The lane of the requests made inside it: `withContext(Polite.Background) { … }`. Urgent when not said. */
    class LaneElement(val lane: Lane) : AbstractCoroutineContextElement(Key) { companion object Key : CoroutineContext.Key<LaneElement> }

    class Refused : Exception("Transitous asked to slow down")

    companion object {
        val Background = LaneElement(Lane.BACKGROUND)
        val Urgent = LaneElement(Lane.URGENT)
        const val COOLING_NOTE = "cooling down"
    }

    private val lock = Any()
    private var until: Double? = null
    private var pause = 0.0
    private var pauses = 0
    private var urgentIn = 0
    private var backgroundIn = 0
    private class Waiter(val lane: Lane, val go: CompletableDeferred<Boolean>)
    private val queue = ArrayList<Waiter>()

    private val cooling: Boolean get() = until?.let { clock() < it } ?: false

    /** How much of the pause is left, if there is one. */
    val coolingLeft: Double? get() = synchronized(lock) { until?.let { it - clock() }?.takeIf { it > 0 } }

    val inFlight: Pair<Int, Int> get() = synchronized(lock) { urgentIn to backgroundIn }

    fun asked(retryAfter: String?): Double? {
        val v = retryAfter?.trim()?.toDoubleOrNull() ?: return null
        if (!v.isFinite()) return null
        return min(longest, max(shortest, v))
    }

    data class Sent(val pauses: Int, val cooling: Boolean)
    fun sending(): Sent = synchronized(lock) { Sent(pauses, cooling) }

    /** A 429 came back for a request sent with `sent`. */
    fun slowDown(retryAfter: String?, sent: Sent) {
        val want = asked(retryAfter)
        val ready = synchronized(lock) {
            val now = clock()
            until?.let { if (now - it > longest) pause = 0.0 }
            if (cooling && !(sent.cooling && sent.pauses == pauses)) {
                if (want != null) until?.let { until = max(it, now + want) }
            } else {
                pause = if (pause > 0) min(longest, max(want ?: 0.0, pause * 2)) else (want ?: firstPause)
                pauses += 1
                until = max(until ?: now, now + pause)
            }
            admit()
        }
        resume(ready)
    }

    /** An answer came: the next 429 starts from the first pause again (a pause that's on goes on). */
    fun answered() { synchronized(lock) { pause = 0.0 } }

    private fun fits(lane: Lane): Boolean {
        if (urgentIn + backgroundIn >= maxInFlight) return false
        return if (lane == Lane.URGENT) (!cooling || urgentIn == 0) else (!cooling && backgroundIn < maxBackground)
    }

    private fun take(lane: Lane) { if (lane == Lane.URGENT) urgentIn++ else backgroundIn++ }

    /** (Under the lock.) The waiting ones that may go now (true) and the background ones a pause turns away (false). */
    private fun admit(): List<Pair<CompletableDeferred<Boolean>, Boolean>> {
        val out = ArrayList<Pair<CompletableDeferred<Boolean>, Boolean>>()
        if (cooling) {
            queue.filter { it.lane == Lane.BACKGROUND }.forEach { out.add(it.go to false) }
            queue.removeAll { it.lane == Lane.BACKGROUND }
        }
        for (lane in listOf(Lane.URGENT, Lane.BACKGROUND)) {
            while (true) {
                val i = queue.indexOfFirst { it.lane == lane }
                if (i < 0 || !fits(lane)) break
                take(lane)
                out.add(queue.removeAt(i).go to true)
            }
            if (queue.any { it.lane == Lane.URGENT }) break
        }
        return out
    }

    private fun resume(list: List<Pair<CompletableDeferred<Boolean>, Boolean>>) { list.forEach { it.first.complete(it.second) } }

    /**
     * Waits for a place, `within` seconds at most (then false: no place, nothing sent). A background one during a pause
     * throws `Refused`. Each place taken (true) is given back with `exit`.
     */
    suspend fun enter(lane: Lane, within: Double): Boolean {
        val go = CompletableDeferred<Boolean>()
        val w = Waiter(lane, go)
        val ready = synchronized(lock) {
            val r = ArrayList(admit())
            val ahead = queue.any { lane == Lane.BACKGROUND || it.lane == Lane.URGENT }
            when {
                lane == Lane.BACKGROUND && cooling -> r.add(go to false)
                !ahead && fits(lane) -> { take(lane); r.add(go to true) }
                else -> queue.add(w)
            }
            r
        }
        resume(ready)
        val got = try { withTimeoutOrNull((max(0.0, within) * 1000).toLong()) { go.await() } } catch (e: kotlinx.coroutines.CancellationException) {
            synchronized(lock) { queue.remove(w) }
            if (granted(go)) exit(lane)
            throw e
        }
        if (got == null) {
            synchronized(lock) { queue.remove(w) }
            return granted(go)                       // (given a place just as its time ran out: it goes)
        }
        if (!got) throw Refused()
        return true
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private fun granted(go: CompletableDeferred<Boolean>) = go.isCompleted && !go.isCancelled && go.getCompleted()

    /** A request is done: its place goes to the next one waiting. */
    fun exit(lane: Lane) {
        val ready = synchronized(lock) {
            if (lane == Lane.URGENT) urgentIn = max(0, urgentIn - 1) else backgroundIn = max(0, backgroundIn - 1)
            admit()
        }
        resume(ready)
    }
}
