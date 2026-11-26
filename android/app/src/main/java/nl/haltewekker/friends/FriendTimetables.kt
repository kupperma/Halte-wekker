package nl.haltewekker.friends

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import nl.haltewekker.App
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.Transit
import nl.haltewekker.school.Calendars
import nl.haltewekker.school.ManualWeek
import nl.haltewekker.school.ScheduleSource
import nl.haltewekker.school.SchoolAlarm
import nl.haltewekker.school.Timetable
import java.io.File

/**
 * Friends (0.28), the iOS `FriendTimetables.swift`: timetables and start areas, yours and your friends', in
 * `files/friends/timetables.json` (not backed up); the switches also go in the vault. Yours is read from your timetable
 * (the calendars picked for the school alarm, or your week) and sent by `FriendStore` at its checks of the relay.
 */
object FriendTimetables {
    private lateinit var ctx: Context

    val seen = MutableStateFlow<Map<String, TimetableSeen>>(emptyMap())
    val areas = MutableStateFlow<Map<String, AreaSeen>>(emptyMap())
    val answered = MutableStateFlow(false)
    val on = MutableStateFlow(true)
    val off = MutableStateFlow<Set<String>>(emptySet())
    val groupsOn = MutableStateFlow<Set<String>>(emptySet())
    val mine = MutableStateFlow<TimetableShare?>(null)
    val myArea = MutableStateFlow<TimetableArea?>(null)
    val sentAt = MutableStateFlow<Double?>(null)

    @Serializable data class AreaStops(val lat: Double, val lon: Double, val stops: List<TripCard.Spot>)

    @Serializable
    private data class Saved(
        val seen: Map<String, TimetableSeen> = emptyMap(),
        val areas: Map<String, AreaSeen> = emptyMap(),
        val settings: TimetableSettings = TimetableSettings(),
        val sent: TimetableShareRules.Sent? = null,
        val areaSent: TimetableShareRules.Sent? = null,
        val areaStops: AreaStops? = null,
    )

    private var saved = Saved()
    private var lastLook = 0.0
    private var dirty = true
    private val file: File get() = File(FriendStore.folder(ctx), "timetables.json")

    fun init(c: Context) {
        ctx = c.applicationContext
        saved = (try { file.takeIf { it.exists() }?.readBytes() } catch (_: Exception) { null })?.let { FriendJson.decode(Saved.serializer(), it) } ?: Saved()
        seen.value = saved.seen
        areas.value = saved.areas
        readSettings()
        sentAt.value = saved.sent?.at
    }

    private fun readSettings() {
        val s = saved.settings
        answered.value = s.answered ?: false
        on.value = s.on ?: true
        off.value = (s.off ?: emptyList()).toSet()
        groupsOn.value = (s.groups ?: emptyList()).toSet()
    }

    private fun save() {
        saved = saved.copy(seen = seen.value, areas = areas.value)
        try {
            val tmp = File(file.parentFile, "timetables.json.tmp")
            tmp.writeBytes(FriendJson.encode(Saved.serializer(), saved))
            tmp.renameTo(file)
        } catch (_: Exception) {}
    }

    /** Your timetable or week changed: read again at the next check. */
    fun changed() { dirty = true }

    val settings: TimetableSettings get() = saved.settings

    fun restore(s: TimetableSettings?) { saved = saved.copy(settings = s ?: TimetableSettings()); readSettings(); dirty = true; save() }

    fun forgetAll() {
        saved = Saved(); seen.value = emptyMap(); areas.value = emptyMap(); mine.value = null; myArea.value = null; sentAt.value = null
        readSettings(); save()
    }

    private fun changeSettings(f: (TimetableSettings) -> TimetableSettings) = FriendStore.launch {
        saved = saved.copy(settings = f(saved.settings))
        readSettings(); dirty = true; save()
        FriendStore.timetableSettingsChanged()
    }

    fun answer(share: Boolean) = changeSettings { it.copy(answered = true, on = share) }
    fun setOn(v: Boolean) = changeSettings { it.copy(answered = true, on = v) }
    fun setShares(id: String, v: Boolean) = changeSettings { s ->
        val o = (s.off ?: emptyList()).toMutableSet().apply { if (v) remove(id) else add(id) }
        s.copy(off = o.sorted().ifEmpty { null })
    }
    fun shares(id: String) = answered.value && on.value && id !in off.value
    fun setGroup(gid: String, v: Boolean) = changeSettings { s ->
        val g = (s.groups ?: emptyList()).toMutableSet().apply { if (v) add(gid) else remove(gid) }
        val t = s.copy(groups = g.sorted().ifEmpty { null })
        if (v && s.answered != true) t.copy(answered = true, on = true) else t
    }

    // MARK: what came

    fun take(r: FriendInbox.Result) {
        if (r.timetables.isEmpty() && r.areas.isEmpty() && r.timetablesOff.isEmpty()) return
        val s = seen.value.toMutableMap()
        val a = areas.value.toMutableMap()
        for (id in r.timetablesOff) { s.remove(id); a.remove(id) }
        for ((id, t) in r.timetables) if ((s[id]?.t ?: Long.MIN_VALUE) <= t.t) s[id] = t
        for ((id, x) in r.areas) if ((a[id]?.t ?: Long.MIN_VALUE) <= x.t) a[id] = x
        seen.value = s; areas.value = a
        save()
    }

    fun keep(ids: Set<String>) {
        val before = seen.value.size + areas.value.size
        seen.value = seen.value.filterKeys { it in ids }
        areas.value = areas.value.filterKeys { it in ids }
        if (seen.value.size + areas.value.size != before) save()
    }

    fun timetable(id: String) = seen.value[id]?.share
    fun area(id: String) = areas.value[id]?.area

    // MARK: yours

    fun lookDue(now: Double, newRecipients: Boolean) = dirty || newRecipients || now - lastLook >= TimetableShareRules.LOOK_EVERY || now < lastLook

    /** Reads your timetable and area now (no network but, once, the stops near home). */
    suspend fun readMine(c: Context, now: Double = System.currentTimeMillis() / 1000.0, sharing: Boolean = true): Pair<TimetableShare?, TimetableArea?> {
        if (sharing) { lastLook = now; dirty = false }
        val app = c.applicationContext as App
        val p = app.store.profile.value
        SchoolAlarm.load(c)
        val (from, to) = TimetableDays.window(now)
        val share: TimetableShare? = when (p.schedule) {
            ScheduleSource.CALENDARS -> {
                val ids = SchoolAlarm.config.value.calendarIds
                if (!Calendars.granted(c) || ids.isEmpty()) null else {
                    val events = withContext(Dispatchers.IO) { Calendars.events(c, ids, from, to) }
                    val classes = events.filter { !it.allDay && !it.cancelled && !Timetable.isCancelled(it.title) && it.end - it.start <= TimetableClass.MAX_LENGTH }
                        .map { TimetableClass(it.start, it.end.takeIf { e -> e > it.start }, it.title.ifBlank { null }, it.location?.ifBlank { null }) }
                    TimetableShare.valid(TimetableShare(from, to, classes, "calendar"))
                }
            }
            ScheduleSource.MANUAL -> TimetableShare.valid(TimetableShare(from, to, (p.week ?: ManualWeek()).friendClasses(now, TimetableShare.DAYS, TimetableDays.zone), "week"))
            ScheduleSource.NONE -> null
        }
        val area = readArea(c)
        mine.value = share
        myArea.value = area
        return share to area
    }

    private fun round(v: Double) = Math.round(v * 100_000) / 100_000.0

    private suspend fun readArea(c: Context): TimetableArea? {
        val p = (c.applicationContext as App).store.profile.value
        val school = p.school ?: return null
        val home = p.home ?: return null
        val sid = school.stopIds.firstOrNull()?.takeIf { !it.contains(",") }
        val schoolSpot = TripCard.Spot(school.name, sid, round(school.lat), round(school.lon))
        var stops = p.homeStops.filter { !it.rail && Geo.metres(home.point, GeoPoint(it.lat, it.lon)) < 3000 }
            .map { TripCard.Spot(it.name, it.id, it.lat, it.lon) }
        if (stops.isEmpty()) stops = nearHomeStops(home.point)
        val station = NSCodes.get(c).nearest(home.point)?.let { TimetableArea.Station(it.name, it.code, null, it.lat, it.lon) }
        return TimetableArea.valid(TimetableArea(stops.take(TimetableArea.MAX_STOPS), station, schoolSpot, SchoolAlarm.config.value.earlyMinutes))
    }

    private suspend fun nearHomeStops(home: GeoPoint): List<TripCard.Spot> {
        saved.areaStops?.let { if (Geo.metres(home, GeoPoint(it.lat, it.lon)) < 300) return it.stops }
        val near = Transit.nearStops(home) ?: return saved.areaStops?.stops ?: emptyList()
        val list = near.filter { !it.rail && it.meters < 1200 }.take(3).map { TripCard.Spot(it.name, it.id, it.lat, it.lon) }
        saved = saved.copy(areaStops = AreaStops(home.lat, home.lon, list))
        save()
        return list
    }

    // MARK: what went

    val sent: TimetableShareRules.Sent? get() = saved.sent
    val areaSent: TimetableShareRules.Sent? get() = saved.areaSent

    fun didSend(s: TimetableShareRules.Sent?, area: TimetableShareRules.Sent?) {
        saved = saved.copy(sent = s, areaSent = area)
        sentAt.value = s?.at
        save()
    }
}
