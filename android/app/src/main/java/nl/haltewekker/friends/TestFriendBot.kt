package nl.haltewekker.friends

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import kotlinx.coroutines.flow.MutableStateFlow
import nl.haltewekker.App
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.Transit
import nl.haltewekker.data.TransitParse
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Test friend (A5, iOS 0.30.1 `TestFriendBot.swift`): a bot to try every Friends feature with before anyone you know has
 * the app. It is a real second Friends account made on this phone (its own seed and device id, its own registration on
 * the relay), kept in its own file (`files/friends/testfriend.json`: not backed up, not in the vault, never in a shared
 * ride log), and it talks to you only through the live relay with the very boxes a friend's phone sends
 * (`TestFriendEngine`). Its brain runs only inside your app's own checks (`FriendStore.syncNow`, right after your
 * waiting boxes went): no loop of its own. Everything runs on the Friends lane, one thing at a time.
 */
object TestFriendBot {
    /** Its account while there is one (null: no test friend, or it's leaving). */
    val account = MutableStateFlow<String?>(null)
    val working = MutableStateFlow(false)
    /** Its pretend trip, wait and campus, for its controls. */
    val trip = MutableStateFlow<TestTrip?>(null)
    val wait = MutableStateFlow<TestWait?>(null)
    val campus = MutableStateFlow(false)
    /** What it last did, in words (under its controls). */
    val note = MutableStateFlow<String?>(null)

    private lateinit var ctx: Context
    private var saved: TestFriendSaved? = null
    private var picture: ByteArray? = null
    private val file: File get() = File(FriendStore.folder(ctx), "testfriend.json")
    private fun now() = System.currentTimeMillis() / 1000.0

    fun init(c: Context) {
        if (::ctx.isInitialized) return
        ctx = c.applicationContext
        saved = try { file.takeIf { it.exists() }?.readBytes() } catch (_: Exception) { null }?.let { FriendJson.decode(TestFriendSaved.serializer(), it) }
        publish()
    }

    private fun save() {
        try {
            val s = saved
            if (s == null) { file.delete(); return }
            val tmp = File(file.parentFile, "testfriend.json.tmp")
            tmp.writeBytes(FriendJson.encode(TestFriendSaved.serializer(), s))
            tmp.renameTo(file)
        } catch (_: Exception) {}
    }

    private fun publish() {
        val s = saved
        account.value = s?.takeIf { !it.leaving }?.account
        trip.value = s?.trip
        wait.value = s?.wait
        campus.value = s?.campus ?: false
    }

    private fun say(s: String) { note.value = s }

    // MARK: what the screens read

    val exists: Boolean get() = account.value != null
    fun isBot(id: String): Boolean = account.value != null && account.value == id
    /** You're friends (it can do things for you now). */
    val isFriend: Boolean get() = account.value?.let { FriendStore.book.value?.isFriend(it) } == true

    /** What your vault keeps, without it. */
    fun scrubbed(c: FriendVaultContents): FriendVaultContents {
        val a = saved?.account ?: return c
        return TestFriendBrain.scrub(c, a)
    }

    // MARK: your side, as the bot sees it

    private val app: App get() = ctx as App
    private val home: GeoPoint? get() = app.store.profile.value.home?.point
    private val stations: List<NSStation> get() = NSCodes.get(ctx).stations

    private val env = object : TestFriendEnv {
        override val you: FriendCard? get() = FriendStore.myCard
        override val yourName: String get() = FriendStore.myName
        override fun yourTimetable(): TimetableShare? = FriendTimetables.mine.value
        override fun area(): TimetableArea? = this@TestFriendBot.area()
        override fun picture(): ByteArray? = picture ?: makePicture().also { picture = it }
    }

    private fun round5(v: Double) = Math.round(v * 100_000) / 100_000.0

    /** Where its trips start: the stops near your Home you share (public stops, never the address), the station, your school. */
    private fun area(): TimetableArea? {
        val yours = FriendTimetables.myArea.value
        val p = app.store.profile.value
        var station = yours?.station
        if (station == null) home?.let { h -> TestTripSim.nearestStation(h, stations, 30_000.0) }?.let { st ->
            station = TimetableArea.Station(st.name, st.code, null, st.lat, st.lon)
        }
        val school = p.school ?: return yours?.let { TimetableArea.valid(it.copy(early = 10)) }
        val spot = TripCard.Spot(FriendExtrasStore.schoolShort() ?: school.name, null, round5(school.lat), round5(school.lon))
        return TimetableArea.valid(TimetableArea(yours?.stops ?: emptyList(), station, yours?.school ?: spot, 10))
    }

    private fun nearStation(): NSStation? = home?.let { TestTripSim.nearestStation(it, stations, 30_000.0) }

    /** The NS station nearest your Home, as a stop. */
    private fun nearStop(): TripCard.Spot? = nearStation()?.let { TripCard.Spot(it.name, null, it.lat, it.lon) }

    /** The next station on from there. */
    private fun nextStation(): TripCard.Spot? {
        val a = nearStation() ?: return null
        return TestTripSim.nextStation(a, stations)?.let { TripCard.Spot(it.name, null, it.lat, it.lon) }
    }

    // MARK: adding and removing

    /** Makes it (its account on the relay), and it sends you a friend request with its picture. */
    fun add() = FriendStore.launch {
        if (working.value || FriendStore.myCard == null) return@launch
        if (saved?.leaving == true) finishLeave()
        if (saved != null) return@launch
        working.value = true
        try {
            val s = TestFriendEngine.create(env, now())
            if (s == null) { say("Couldn’t reach the relay. Check your connection and try again."); return@launch }
            saved = s
            save(); publish()
            say("Test friend sent you a friend request. Accept it under “Want to be friends”.")
        } finally {
            working.value = false
        }
        FriendStore.syncAndWait(FriendStore.Why.NOW)
    }

    /** It leaves: out of its groups, off the relay (`/f/v1/leave`), its chat and everything of it off this phone. */
    fun remove() = FriendStore.launch {
        val s = saved ?: return@launch
        val id = s.account
        saved = s.copy(leaving = true)
        save(); publish()
        if (id != null) {
            val b = FriendStore.book.value
            when {
                b?.isFriend(id) == true -> FriendStore.remove(id)
                b?.incoming?.any { it.id == id } == true -> FriendStore.decline(id, false)
                b?.outgoing?.any { it.id == id } == true -> FriendStore.cancel(id)
            }
            FriendChats.remove(ChatKey.friend(id))
        }
        finishLeave()
        note.value = null
    }

    /** Your own friends account went (deleted, or moved to another phone): it goes too. */
    fun userGone() {
        val s = saved ?: return
        saved = s.copy(leaving = true)
        save(); publish()
        FriendStore.launch { finishLeave() }
    }

    private suspend fun finishLeave() {
        val s = saved ?: return
        if (!s.leaving) return
        val e = TestFriendEngine(s, env)
        val gone = e.leave()
        saved = if (gone) null else e.s
        save(); publish()
    }

    // MARK: its brain, inside your checks

    /** One look (from `FriendStore.syncNow`, right after your own boxes went, so its answers come back in that check). */
    suspend fun check() {
        val s = saved ?: return
        if (s.leaving) { finishLeave(); return }
        val e = TestFriendEngine(s, env)
        e.check(now())
        // (removed meanwhile: that stays)
        saved = if (saved?.leaving == true) e.s.copy(leaving = true) else e.s
        save(); publish()
        if (saved?.leaving == true) finishLeave()
    }

    /** One of its controls: changes what it keeps (and what it says), then a check of yours (which runs its brain) at once. */
    private fun act(f: (TestFriendEngine, FriendCard) -> String?) = FriendStore.launch {
        val s = saved
        val you = FriendStore.myCard
        if (s == null || s.leaving || you == null || !s.book.isFriend(you.account)) { say("Accept the test friend’s request first."); return@launch }
        val e = TestFriendEngine(s, env)
        f(e, you)?.let { say(it) }
        saved = e.s
        save(); publish()
        FriendStore.syncAndWait(FriendStore.Why.NOW)
    }

    /** "Pretend I’m travelling": a real bus or train near your Home (the NS station nearest it first) for 10 minutes. */
    fun pretendTravel() {
        if (trip.value != null) {
            act { e, _ -> e.s = e.s.copy(trip = null); "Stopped pretending to travel." }
            return
        }
        FriendStore.launch {
            working.value = true
            val found = try { realTrip(now()) } finally { working.value = false }
            if (found == null) { say("Couldn’t find a bus or train near your Home right now. Try again in a minute."); return@launch }
            act { e, you ->
                e.s = e.s.copy(trip = found, tripSent = null, wait = null)
                val what = if (found.isTrain) "the ${found.line}" else "bus ${found.line}"
                val to = found.stops.lastOrNull()?.name ?: ""
                e.line(ChatText("I’m taking $what from ${found.stops.firstOrNull()?.name ?: ""} to $to (pretend, for 10 minutes). Follow me in Travelling now!"), you.account)
                "Travelling on $what to $to until ${TimetableDays.hhmm(TestTripSim.end(found))}."
            }
        }
    }

    /** "Ask you to wait for me": at the station nearest your Home, coming closer for 5 minutes. */
    fun askToWait() {
        val stop = nearStop()
        if (stop == null) { say("There’s no station near your Home to wait at."); return }
        act { e, _ ->
            e.s = e.s.copy(wait = TestWait(RelaySign.nonce().take(22), stop, now()), waitSent = null)
            "Asked you to wait at ${stop.name}. It gets there in 5 minutes."
        }
    }

    /** "Pretend I’m on campus" (and back). */
    fun toggleCampus() = act { e, you ->
        val now = now()
        val on = !e.s.campus
        e.s = e.s.copy(campus = on)
        if (on) {
            val until = now + 4 * 3600
            e.enqueue(FriendMessage.Campus(CampusState(true, FriendExtrasStore.schoolShort(), now - 20 * 60, until)), you,
                slot = CampusRules.SLOT, ttl = CampusRules.ttl(until, now))
            "On campus now (for 4 hours, or until you tap again)."
        } else {
            e.enqueue(FriendMessage.Campus(CampusState(false)), you, slot = CampusRules.SLOT, ttl = 3600)
            "Left campus."
        }
    }

    /** "Share scores": its fastest trips on your routes, for the leaderboard with friends. */
    fun shareScores() = act { e, you ->
        val rides = FriendTogetherStore.count(e.s.account ?: "")
        e.enqueue(FriendMessage.Scores(TestFriendBrain.scores(ScoreLog.trips.value, rides, now())), you, slot = ScoresRules.SLOT, ttl = ScoresRules.TTL)
        "Shared its scores: see the leaderboard with friends on Friends."
    }

    /** "Pretend we rode together": a ride on your phone's history with it, and a line about it. */
    fun pretendRodeTogether() {
        val now = now()
        val from = nearStop()?.name ?: "the station"
        val to = trip.value?.stops?.lastOrNull()?.name ?: (FriendExtrasStore.schoolShort() ?: "school")
        act { e, you ->
            val me = e.s.account ?: return@act null
            FriendTogetherStore.addPretend(RideTogether("test-friend-${now.toLong()}", TimetableDays.key(now), "SPR", from, to, now - 25 * 60, listOf(me)))
            e.line(ChatText("That was fun, riding together from $from! (Pretend: it’s on my page under Rides together.)"), you.account)
            "A ride together went in your history."
        }
    }

    /** "Wake-up buddy: pretend I haven’t left": its plan said leave 6 minutes ago, for a train in 4. */
    fun buddyNotLeft() {
        val stop = nearStop()
        val next = nextStation()
        act { e, you ->
            val now = now()
            e.s = e.s.copy(trip = null, wait = null)
            val ride = if (stop != null && next != null) TestFriendBrain.ride(stop, next, true, now, 4.0, "test-friend-buddy-${now.toLong()}") else null
            e.enqueue(FriendMessage.Buddy(TestFriendBrain.buddy(now, ride)), you, slot = BuddyRules.SLOT, ttl = BuddyRules.TTL)
            "Its plan said leave at ${TimetableDays.hhmm(now - 6 * 60)} and it hasn’t: your phone should tell you now."
        }
    }

    // MARK: a real bus or train near your Home

    /** From the NS station nearest Home (a train), else the stop nearest Home; its stops from the live data. Else a Sprinter. */
    private suspend fun realTrip(now: Double): TestTrip? {
        val h = home ?: return null
        val places = listOfNotNull(nearStation()?.point, h)
        for ((i, c) in places.withIndex()) {
            val near = Transit.nearStops(c) ?: continue
            val stop = if (i == 0 && places.size > 1) near.firstOrNull { it.rail } else near.firstOrNull()
            stop ?: continue
            rideFrom(stop, now)?.let { return it }
        }
        return TestTripSim.fallback(h, stations, now)
    }

    private suspend fun rideFrom(stop: nl.haltewekker.data.NearStop, now: Double): TestTrip? {
        val soon = Transit.board(listOf(stop.id), 20).filter { d -> d.tripId.isNotEmpty() && !d.cancelled && d.time > now - 60 && d.time < now + 45 * 60 }
        for (d in soon.take(3)) {
            val stops = Transit.trip(d.tripId, 120.0)?.stops ?: continue
            val here = GeoPoint(stop.lat, stop.lon)
            val at = stops.indices.minByOrNull { Geo.metres(here, stops[it].point) } ?: continue
            val real = stops.drop(at).map { s -> TestTripSim.RealStop(s.name, s.point.lat, s.point.lon, s.departure ?: s.arrival) }
            val line = if (d.train) TransitParse.trainLabel(d.line).ifEmpty { d.line } else d.line
            TestTripSim.make(if (d.train) "train" else "bus", line, null, d.tripId, real, d.headsign, now)?.let { return it }
        }
        return null
    }

    // MARK: its picture

    /** A 256 px square: a test tube on violet to teal, and "TEST" under it (as a JPEG of at most 40 KB). */
    private fun makePicture(): ByteArray? = try {
        val side = 256f
        val b = Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888)
        val c = Canvas(b)
        val bg = Paint().apply { shader = LinearGradient(0f, 0f, side, side, 0xFF6B45D9.toInt(), 0xFF1A9EB8.toInt(), Shader.TileMode.CLAMP) }
        c.drawRect(0f, 0f, side, side, bg)
        val white = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFFFFFF.toInt(); style = Paint.Style.STROKE; strokeWidth = 9f }
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFFFFFF.toInt() }
        // two test tubes, the second a little lower, each half full
        for ((x, y) in listOf(96f to 46f, 142f to 58f)) {
            val r = RectF(x, y, x + 30f, y + 104f)
            c.drawRoundRect(r, 15f, 15f, white)
            c.drawRoundRect(RectF(x + 6f, y + 52f, x + 24f, y + 98f), 9f, 9f, fill)
            c.drawLine(x - 6f, y, x + 36f, y, white)
        }
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFFFFFFF.toInt(); textSize = 40f; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD); textAlign = Paint.Align.CENTER
        }
        c.drawText("TEST", side / 2, side - 34f, text)
        var out: ByteArray? = null
        for (q in listOf(85, 70, 55)) {
            val o = ByteArrayOutputStream()
            b.compress(Bitmap.CompressFormat.JPEG, q, o)
            if (o.size() <= FriendPicture.MAX_BYTES) { out = o.toByteArray(); break }
        }
        out
    } catch (_: Exception) { null }
}
