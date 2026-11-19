package nl.haltewekker.live

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import nl.haltewekker.core.Iso
import nl.haltewekker.data.Net

/**
 * The open positions feeds, each fetched only when something asks and at most every 30 s, with its ETag (304:
 * nothing new) and a backoff after failures (iOS `RealPositionsStore`). Nothing polls by itself.
 */
object LiveFeeds {
    private class State { var etag: String? = null; var next = 0.0; var failures = 0 }

    private val busLock = Mutex()
    private val busState = State()
    @Volatile var buses: RealPositions.Feed = RealPositions.Feed()
        private set

    private val trainLock = Mutex()
    private val trainState = State()
    @Volatile var trains: Map<Int, GPSFix> = emptyMap()
        private set
    @Volatile var trainsAt: Double = 0.0
        private set

    /** OVapi's bus (and tram, metro) positions: fresh enough for `maxAge` seconds, else fetched now. */
    suspend fun busFixes(maxAge: Double = RealPositions.EVERY): Map<String, GPSFix> = withContext(Dispatchers.Default) { busLock.withLock {
        val now = Iso.now()
        if (now >= busState.next) {
            val a = Net.get(RealPositions.FEED_URL, etag = busState.etag)
            when {
                a.status == 200 && a.body != null -> {
                    buses = RealPositions.parse(a.body); busState.etag = a.etag; busState.failures = 0
                }
                a.status == 304 -> busState.failures = 0
                else -> busState.failures++
            }
            busState.next = now + maxOf(maxAge, RealPositions.backoff(busState.failures))
        }
        buses.fixes
    } }

    /** NS's positions of every train, through the relay (no place of yours goes with it). */
    suspend fun trainFixes(maxAge: Double = RealPositions.EVERY): Map<Int, GPSFix> = withContext(Dispatchers.Default) { trainLock.withLock {
        val now = Iso.now()
        if (now >= trainState.next) {
            val a = Net.get(RealPositions.RELAY + RealPositions.TRAINS_PATH, etag = trainState.etag)
            when {
                a.status == 200 && a.body != null -> {
                    val parsed = RealPositions.parseTrains(a.text, now)
                    if (parsed != null) { trains = parsed; trainsAt = now; trainState.etag = a.etag; trainState.failures = 0 }
                    else trainState.failures++
                }
                a.status == 304 -> trainState.failures = 0
                a.status == 404 || a.status == 501 -> { trainState.failures = 0; trainState.next = now + 600; return@withLock trains }
                else -> trainState.failures++
            }
            trainState.next = now + maxOf(maxAge, RealPositions.backoff(trainState.failures))
        }
        trains
    } }
}
