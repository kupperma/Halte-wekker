package nl.haltewekker.profile

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.NearStop
import nl.haltewekker.school.ManualWeek
import nl.haltewekker.school.ScheduleSource

/** One of your places: Home or School (iOS `SavedPlace`), with the stops it is planned from. */
@Serializable
data class SavedPlace(val name: String, val lat: Double, val lon: Double, val stopIds: List<String> = emptyList()) {
    val point: GeoPoint get() = GeoPoint(lat, lon)
    /** What the planner is asked from or to: the place itself (Transitous walks to the stops). */
    val planId: String get() = "$lat,$lon"
}

/** Who you are to the app (iOS `Profile`, `profile.v1`); saved as JSON. */
@Serializable
data class Profile(
    val version: Int = 1,
    val setupDone: Boolean = false,
    val schoolId: String? = null,
    val campus: String? = null,
    val school: SavedPlace? = null,
    val home: SavedPlace? = null,
    val homeStops: List<NearStop> = emptyList(),
    /** (A2) Where the first classes come from: a calendar on the phone, your week, or not set up yet. */
    val schedule: ScheduleSource = ScheduleSource.NONE,
    /** (A2) "Same times every week". */
    val week: ManualWeek? = null,
)

/** Settings that mirror the iOS Settings › Alarm and Map switches (same defaults). */
@Serializable
data class Settings(
    val busKm: Double = 2.0,
    val trainKm: Double = 5.0,
    val headphonesOnly: Boolean = true,
    val announce: Boolean = true,
    val ringAtStop: Boolean = true,
    val backupAlarm: Boolean = true,
    val realPositions: Boolean = true,
    val roughGPSOnLongRides: Boolean = true,
    /** (A2) Leaving a home stop or School on a bus or train starts the trip by itself (needs location all the time). */
    val autoStart: Boolean = true,
    /** (A2) Reaching School switches the next trip to home, once a day. */
    val autoHome: Boolean = true,
)

/** The profile and settings, in SharedPreferences, as state the screens follow. */
class Store(context: Context) {
    val prefs: android.content.SharedPreferences = context.getSharedPreferences("haltewekker", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val _profile = MutableStateFlow(read(KEY_PROFILE) ?: Profile())
    val profile: StateFlow<Profile> = _profile
    private val _settings = MutableStateFlow(read(KEY_SETTINGS) ?: Settings())
    val settings: StateFlow<Settings> = _settings

    private inline fun <reified T> read(key: String): T? =
        prefs.getString(key, null)?.let { try { json.decodeFromString<T>(it) } catch (_: Exception) { null } }

    fun setProfile(p: Profile) { _profile.value = p; prefs.edit().putString(KEY_PROFILE, json.encodeToString(p)).apply() }
    fun setSettings(s: Settings) { _settings.value = s; prefs.edit().putString(KEY_SETTINGS, json.encodeToString(s)).apply() }
    fun updateSettings(f: (Settings) -> Settings) = setSettings(f(_settings.value))

    fun updateProfile(f: (Profile) -> Profile) = setProfile(f(_profile.value))

    fun getString(key: String): String? = prefs.getString(key, null)
    /** Written at once (commit): the setup backup and its restore must be on disk before anything goes on. */
    fun putString(key: String, v: String?) { prefs.edit().apply { if (v == null) remove(key) else putString(key, v) }.commit() }

    /** Read the profile and settings again (after the setup backup was put back). */
    fun reload() {
        _profile.value = read(KEY_PROFILE) ?: Profile()
        _settings.value = read(KEY_SETTINGS) ?: Settings()
    }

    companion object {
        const val KEY_PROFILE = "profile.v1"
        const val KEY_SETTINGS = "settings.v1"
    }
}
