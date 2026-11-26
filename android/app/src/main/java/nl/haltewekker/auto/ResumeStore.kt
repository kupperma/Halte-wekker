package nl.haltewekker.auto

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import nl.haltewekker.App
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip

/** A trip you ended by hand before its last leg, while it's offered to go on with (iOS 0.26.2). */
@Serializable
data class ResumeOffer(val trip: DoorTrip, val destination: String, val leg: Int, val endedAt: Double,
                       /** (A6, iOS 0.35) going on with it keeps its start, for the leaderboard. */
                       val startedAt: Double? = null, val firstLeg: Int? = null,
                       val startLat: Double? = null, val startLon: Double? = null, val startFixAt: Double? = null)

object ResumeStore {
    const val KEY = "resume.v1"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val _offer = MutableStateFlow<ResumeOffer?>(null)
    val offer: StateFlow<ResumeOffer?> = _offer
    private var loaded = false

    fun load(c: Context) {
        if (loaded) return
        loaded = true
        _offer.value = (c.applicationContext as App).store.getString(KEY)?.let { try { json.decodeFromString<ResumeOffer>(it) } catch (_: Exception) { null } }
            ?.takeIf { Iso.now() - it.endedAt <= TripResume.WITHIN }
    }

    fun set(c: Context, o: ResumeOffer?) {
        loaded = true
        _offer.value = o
        (c.applicationContext as App).store.putString(KEY, o?.let { json.encodeToString(it) })
    }

    fun reload(c: Context) { loaded = false; load(c) }
}
