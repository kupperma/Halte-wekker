package nl.haltewekker.travel

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import nl.haltewekker.App
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Net
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.FriendRelay
import nl.haltewekker.friends.NSCodes
import nl.haltewekker.friends.ScoreLog
import nl.haltewekker.ride.Notifications
import java.io.File
import java.time.ZoneId

/** (A6, iOS 0.34 `HabitStore.swift`) what it learned from your rides, on this phone only (SharedPreferences, backed up with the app's). */
object HabitStore {
    private const val BOOK = "habits.book"
    private const val CHANGES = "habits.changes"
    val book = MutableStateFlow(HabitBook())
    val changes = MutableStateFlow(ChangeBook())
    private var ctx: Context? = null

    fun load(c: Context) {
        if (ctx != null) return
        ctx = c.applicationContext
        val st = (c.applicationContext as App).store
        book.value = st.getString(BOOK)?.let { FriendJson.decode(HabitBook.serializer(), it) } ?: HabitBook()
        changes.value = st.getString(CHANGES)?.let { FriendJson.decode(ChangeBook.serializer(), it) } ?: ChangeBook()
    }

    private fun save() {
        val st = (ctx?.applicationContext as? App)?.store ?: return
        st.prefs.edit().putString(BOOK, FriendJson.encodeString(HabitBook.serializer(), book.value))
            .putString(CHANGES, FriendJson.encodeString(ChangeBook.serializer(), changes.value)).apply()
    }

    fun update(f: (HabitBook) -> HabitBook) { book.value = f(book.value); save() }

    fun recordChange(fromLine: String, toLine: String, at: String, time: Double, made: Boolean) {
        val z = ZoneId.systemDefault()
        changes.value = changes.value.record(ChangeOdds.key(fromLine, toLine, at, time, z), ChangeOdds.day(time, z), made)
        save()
    }

    /** "this change worked on 9 of 10 days" for the change into ride `i` of `t` (i ≥ 1). */
    fun changeWords(t: DoorTrip, i: Int): String? {
        val a = t.rides.getOrNull(i - 1) ?: return null
        val b = t.rides.getOrNull(i) ?: return null
        val (made, days) = changes.value.tally(ChangeOdds.key(a.line, b.line, b.fromStop, b.departure, ZoneId.systemDefault()))
        return ChangeOdds.words(made, days)
    }

    /** Your walking speed for the planner (m/s), when it's clearly not its own. */
    fun pedestrianSpeed(): Double? = Habits.pedestrianSpeed(book.value)

    fun reset() { book.value = HabitBook(); changes.value = ChangeBook(); save() }
}

/** (A6, iOS 0.35 `TravelLogStore.swift`) the rides kept for Your year in travel: `files/travel.json`, never sent, not backed up. */
object TravelLogStore {
    private val ser = ListSerializer(RideRecord.serializer())
    private val _rides = MutableStateFlow<List<RideRecord>>(emptyList())
    val rides: StateFlow<List<RideRecord>> = _rides
    private var file: File? = null
    private val lock = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    const val DISMISSED = "travelYear.dismissed"

    fun load(c: Context) {
        if (file != null) return
        val f = File(c.applicationContext.noBackupFilesDir, "travel.json")
        file = f
        _rides.value = (try { f.takeIf { it.exists() }?.readText() } catch (_: Exception) { null })?.let { FriendJson.decode(ser, it) } ?: emptyList()
    }

    fun add(c: Context, r: RideRecord) {
        load(c)
        _rides.value = TravelLog.add(_rides.value, r, Iso.now())
        val text = FriendJson.encodeString(ser, _rides.value)
        val f = file ?: return
        scope.launch { lock.withLock { try { f.writeText(text) } catch (_: Exception) {} } }
    }

    fun stats(c: Context, now: Double = Iso.now()): TravelStats {
        load(c); ScoreLog.load(c)
        val together = nl.haltewekker.friends.FriendTogetherStore.rides.value.map { it.dep }
        return TravelYear.stats(_rides.value, ScoreLog.trips.value, together, now, ZoneId.systemDefault())
    }

    /** The home's card: the year it's for now, or null. */
    fun seasonal(c: Context, now: Double = Iso.now()): Int? {
        val s = stats(c, now)
        val first = listOfNotNull(_rides.value.minOfOrNull { it.dep }, ScoreLog.trips.value.minOfOrNull { it.at }).minOrNull()
        val dismissed = (c.applicationContext as App).store.prefs.getInt(DISMISSED, 0).takeIf { it > 0 }
        return TravelYear.seasonal(now, first, s.trips, dismissed, ZoneId.systemDefault())
    }

    fun dismiss(c: Context, year: Int) { (c.applicationContext as App).store.prefs.edit().putInt(DISMISSED, year).apply() }
}

/**
 * (A6, iOS 0.36–0.37 `TravelNotes.swift`) the notes around your trips that need the network: NS's works on your routes
 * (relay `/ns/disruptions`, at most every 4 hours), the price for the student OV line (`/ns/price`, once a day per
 * pair), OV-fiets at a station (`/ns/ovfiets`, 5 min), rain on the walk (Open-Meteo, 30 min), the last way home
 * (Transitous, at most hourly). Asked only while the home or a plan is on screen; nothing polls in the background, apart
 * from the two notifications it sets with AlarmManager (works the evening before at 19:30, the last way home 30 min
 * before it leaves).
 */
object TravelNotes {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }

    // works
    val works = MutableStateFlow<List<RailWorks.Impact>>(emptyList())
    private var worksAt = 0.0
    private var worksItems: List<RailWorks.Item> = emptyList()

    // last way home
    val lastHome = MutableStateFlow<LastTrip.Option?>(null)
    private var lastAsked: Double? = null
    private var lastAskedAt: GeoPoint? = null

    // prices (cents), OV-fiets, rain
    private val prices = HashMap<String, Pair<Int?, String>>()
    private val bikes = HashMap<String, Pair<OVFiets.Answer?, Double>>()
    private val rain = HashMap<String, Pair<List<RainAdvice.Hour>, Double>>()

    private fun settings(c: Context) = (c.applicationContext as App).store.settings.value
    private fun profile(c: Context) = (c.applicationContext as App).store.profile.value

    /** Your usual train rides: home ⇄ school's stations (by the straight line), as NS codes. */
    fun usualRides(c: Context): List<RailWorks.Ride> {
        val p = profile(c)
        val codes = NSCodes.get(c)
        val home = p.home?.point?.let { codes.nearest(it, 6000.0) } ?: return emptyList()
        val school = p.school?.point?.let { codes.nearest(it, 6000.0) } ?: return emptyList()
        if (home.code == school.code) return emptyList()
        return listOf(RailWorks.Ride(home.code, school.code), RailWorks.Ride(school.code, home.code))
    }

    /** The home came to the front (or its loop ticked): works at most every 4 hours, the last way home at most hourly. */
    fun refresh(c: Context, here: GeoPoint?) = scope.launch {
        val now = Iso.now()
        val st = settings(c)
        if (st.railWorks) refreshWorks(c, now) else works.value = emptyList()
        if (st.lastHome && here != null) refreshLastHome(c, here, now) else lastHome.value = null
    }

    private suspend fun refreshWorks(c: Context, now: Double) {
        val rides = usualRides(c)
        if (rides.isEmpty()) { works.value = emptyList(); return }
        val codes = NSCodes.get(c)
        if (now - worksAt >= RailWorks.FETCH_EVERY || now < worksAt) {
            val stations = rides.flatMap { listOf(it.from, it.to) }.distinct().joinToString(",")
            val a = Net.get(FriendRelay.BASE + "/ns/disruptions", listOf("stations" to stations, "lang" to "en"))
            if (a.ok) { worksItems = RailWorks.parse(a.text); worksAt = now }
        }
        val list = RailWorks.impacts(worksItems, rides, now) { code -> codes.station(code)?.let { GeoPoint(it.lat, it.lon) } }
        works.value = list
        // the evening before at 19:30: one notification per day, set now
        list.firstOrNull { it.dayStart > RailWorks.startOfDay(now) }?.let { i ->
            val at = RailWorks.eveningBefore(i.dayStart)
            val hl = RailWorks.headline(i, at, null)
            if (at > now) schedule(c, 31, at, "Works on your route", hl, "works-${i.day}")
            else if (RailWorks.tellNow(i, now)) Notifications.news(c, "works-${i.day}-${i.id}", "Works on your route", RailWorks.headline(i, now, null))
        }
    }

    private suspend fun refreshLastHome(c: Context, here: GeoPoint, now: Double) {
        val home = profile(c).home ?: return
        if (!LastTrip.wanted(now, Geo.metres(here, home.point))) { lastHome.value = null; return }
        if (!LastTrip.refreshDue(lastAsked, lastAskedAt, here, lastHome.value, now)) return
        lastAsked = now; lastAskedAt = here
        val opts = ArrayList<LastTrip.Option>()
        for (by in LastTrip.arriveBy(now)) {
            val trips = nl.haltewekker.data.Transit.plan("${here.lat},${here.lon}", home.planId, by, count = 5, arriveBy = true)
            opts += trips.map { LastTrip.Option(it.start, it.first.departure, it.end, it.first.fromStop, it.rides.any { r -> r.cancelled }) }
            if (LastTrip.pick(opts, now) != null) break
        }
        val o = LastTrip.pick(opts, now)?.let { opts[it] }
        lastHome.value = o
        if (o != null) LastTrip.warnAt(o, now)?.let { at ->
            val (t, b) = LastTrip.notice(o) { nl.haltewekker.ride.Notifications.time(it) }
            schedule(c, 32, at, t, b, "lasthome")
        }
    }

    /** The relay's 2nd-class fare between two stations today (cents), asked once a day per pair. */
    suspend fun price(fromCode: String, toCode: String, at: Double): Int? {
        val k = "$fromCode>$toCode"
        val day = RailWorks.dayKey(at)
        prices[k]?.let { if (it.second == day) return it.first }
        val a = Net.get(FriendRelay.BASE + "/ns/price", listOf("from" to fromCode, "to" to toCode, "dateTime" to Iso.format(at)))
        val cents = if (a.ok) StudentOV.fullFareCents(try { json.parseToJsonElement(a.text) } catch (_: Exception) { null }) else null
        if (a.ok) prices[k] = cents to day
        return cents
    }

    /** OV-fiets at a station (NS code), kept 5 minutes. */
    suspend fun bikes(code: String): OVFiets.Answer? {
        val now = Iso.now()
        bikes[code]?.let { if (OVFiets.fresh(it.second, now)) return it.first }
        val a = Net.get(FriendRelay.BASE + "/ns/ovfiets", listOf("station" to code))
        val ans = if (a.ok) OVFiets.parse(a.text, code) else null
        if (a.ok) bikes[code] = ans to now
        return ans
    }

    /** Open-Meteo's hourly rain at a place (2 decimals, about a kilometre), kept 30 minutes. */
    suspend fun rainAt(p: GeoPoint): List<RainAdvice.Hour> {
        val k = "%.2f,%.2f".format(java.util.Locale.ROOT, p.lat, p.lon)
        val now = Iso.now()
        rain[k]?.let { if (now - it.second < 1800) return it.first }
        val a = Net.get("https://api.open-meteo.com/v1/forecast", listOf("latitude" to "%.2f".format(java.util.Locale.ROOT, p.lat),
            "longitude" to "%.2f".format(java.util.Locale.ROOT, p.lon), "hourly" to "precipitation", "forecast_days" to "2", "timeformat" to "unixtime"))
        val h = if (a.ok) RainAdvice.parseHours(a.text) else emptyList()
        if (a.ok) rain[k] = h to now
        return h
    }

    /** "Rain at 08:00 — …" for a trip (null: dry, too far ahead, or no forecast). `others`: the other ways, for a bus instead. */
    suspend fun rainLine(t: DoorTrip, others: List<DoorTrip>, now: Double, hhmm: (Double) -> String): String? {
        if (!RainAdvice.due(t.start, now)) return null
        val first = t.first; val last = t.last
        val s = RainAdvice.stretches(t.start, first.walkBefore, last.arrival, t.end)
        if (s.isEmpty()) return null
        val here = first.from?.let { rainAt(it) } ?: emptyList()
        val there = last.to?.let { rainAt(it) } ?: emptyList()
        val hit = RainAdvice.hit(s, here, there) ?: return null
        val buses = others.filter { it.id != t.id && !it.first.isTrain }.map {
            RainAdvice.Bus(it.first.line, it.first.departure, it.first.walkBefore, it.end, t.end + 10 * 60)
        }
        val bus = RainAdvice.bus(first.walkBefore, now, buses)
        return RainAdvice.text(hit, RainAdvice.advice(hit, first.isTrain, first.walkBefore, bus), hhmm)
    }

    // MARK: the two notifications it sets

    private fun schedule(c: Context, code: Int, at: Double, title: String, body: String, tag: String) {
        val i = Intent(c, TravelNotesReceiver::class.java).putExtra("title", title).putExtra("body", body).putExtra("tag", tag)
        val pi = PendingIntent.getBroadcast(c, code, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val am = c.getSystemService(AlarmManager::class.java) ?: return
        // inexact: a note, not an alarm (within 10 minutes of the time)
        try { am.setWindow(AlarmManager.RTC_WAKEUP, (at * 1000).toLong(), 10 * 60_000L, pi) } catch (_: Exception) {}
    }

    // MARK: check-out (the minute after you get off)

    /** Recent GPS speeds from the ride (m/s, with their time), for "still on board". */
    val speeds = ArrayDeque<Pair<Double, Double>>()

    fun heardSpeed(t: Double, v: Double) {
        synchronized(speeds) { speeds.addLast(t to v); while (speeds.size > 60) speeds.removeFirst() }
    }

    /** A minute after getting off at `stop`: "Did you check out?", unless two fixes in that minute were at vehicle speed or
     *  the next leg found the same vehicle (`sameVehicle`, asked then). */
    fun checkOutLater(c: Context, stop: String, change: Pair<Boolean, Boolean>?, sameVehicle: () -> Boolean) {
        val from = Iso.now()
        scope.launch {
            kotlinx.coroutines.delay((CheckOut.AFTER * 1000).toLong())
            val v = synchronized(speeds) { speeds.filter { it.first >= from }.map { it.second } }
            if (CheckOut.stillAboard(v, sameVehicle())) return@launch
            val (t, b) = CheckOut.text(stop, change)
            Notifications.news(c.applicationContext, "checkout", t, b)
        }
    }
}

/** Posts the note TravelNotes set for later (works the evening before, the last way home). */
class TravelNotesReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val title = intent.getStringExtra("title") ?: return
        val body = intent.getStringExtra("body") ?: return
        Notifications.news(context, intent.getStringExtra("tag") ?: "travel", title, body)
    }
}
