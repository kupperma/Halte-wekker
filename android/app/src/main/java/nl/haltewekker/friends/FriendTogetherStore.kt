package nl.haltewekker.friends

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import nl.haltewekker.App
import nl.haltewekker.ride.Phase
import nl.haltewekker.ride.RideState
import java.io.File

/**
 * Your own finished trips between Home and School (iOS `ScoreBook` door to door, `DoorScore`): minutes from starting the
 * ride to the last stop. The Android app has no leaderboard of its own yet; these feed the leaderboard with friends.
 * Kept in the app's settings file (`scores.v1`), at most 300.
 */
object ScoreLog {
    private const val KEY = "scores.v1"
    private val ser = ListSerializer(ScoreTrip.serializer())
    val trips = MutableStateFlow<List<ScoreTrip>>(emptyList())
    private var loaded = false

    fun load(c: Context) {
        if (loaded) return
        loaded = true
        trips.value = (c.applicationContext as App).store.getString(KEY)?.let { FriendJson.decode(ser, it) } ?: emptyList()
    }

    /** A ride reached its last stop: scored when it went from near Home to near School (or back) from its first leg. */
    fun finished(c: Context, s: RideState, now: Double) {
        load(c)
        if (s.firstLeg != 0) return
        val p = (c.applicationContext as App).store.profile.value
        val home = p.home?.point ?: return
        val school = p.school?.point ?: return
        val start = s.trip.first.from ?: return
        val end = s.trip.last.to ?: return
        val (route, isHome) = DoorScore.key(start, end, home, school) ?: return
        val mins = DoorScore.minutes(s.startedAt, now) ?: return
        val list = (listOf(ScoreTrip(route, isHome, mins, now)) + trips.value).take(300)
        trips.value = list
        (c.applicationContext as App).store.putString(KEY, FriendJson.encodeString(ser, list))
    }
}

/**
 * Friends extras, part B (0.30), the iOS `FriendTogetherStore.swift`: free hours together today, the leaderboard with
 * friends and the ride history. The rules are in `FriendExtrasB.kt` (tested); this keeps what came and what you shared
 * (`files/friends/together.json`, not backed up) and runs only inside `FriendStore`'s checks and on the ride's own
 * network tick (the ride history). No loop of its own; it only reads the ride. On `FriendStore.lane`.
 */
object FriendTogetherStore {
    val rides = MutableStateFlow<List<RideTogether>>(emptyList())
    val scores = MutableStateFlow<Map<String, ScoresSeen>>(emptyMap())
    val freeToday = MutableStateFlow<List<FreeTodaySlot>>(emptyList())

    @Serializable
    private data class Saved(
        val rides: List<RideTogether> = emptyList(),
        val scores: Map<String, ScoresSeen> = emptyMap(),
        val scoresSent: TimetableShareRules.Sent? = null,
        val freeNoteDay: String? = null,
    )

    private lateinit var ctx: Context
    private var saved = Saved()
    private var lastWritten: String? = null
    private var lastScoresLook = 0.0
    private var lastMineRead = 0.0

    private val file: File get() = File(FriendStore.folder(ctx), "together.json")
    private fun now() = System.currentTimeMillis() / 1000.0
    private val me: String get() = FriendStore.myAccount ?: ""
    private val settings: ExtrasSettings get() = FriendExtrasStore.settings.value

    fun init(c: Context) {
        ctx = c.applicationContext
        ScoreLog.load(ctx)
        saved = (try { file.takeIf { it.exists() }?.readText() } catch (_: Exception) { null })?.let { FriendJson.decode(Saved.serializer(), it) } ?: Saved()
        publish()
    }

    private fun publish() {
        rides.value = saved.rides
        scores.value = saved.scores
    }

    private fun save() {
        val text = FriendJson.encodeString(Saved.serializer(), saved)
        if (text == lastWritten) return
        try {
            val tmp = File(file.parentFile, "together.json.tmp")
            tmp.writeText(text)
            tmp.renameTo(file)
            lastWritten = text
        } catch (_: Exception) {}
    }

    fun take(r: FriendInbox.Result) {
        if (r.scores.isEmpty()) return
        val m = saved.scores.toMutableMap()
        for ((id, s) in r.scores) {
            if ((m[id]?.t ?: Long.MIN_VALUE) > s.t) continue
            if (s.share.on) m[id] = s else m.remove(id)
        }
        saved = saved.copy(scores = m)
        save(); publish()
    }

    suspend fun due(now: Double) {
        if (!FriendStore.hasAccount) return
        val b = FriendStore.book.value ?: return
        val friends = b.friends.map { it.id }
        val keep = friends.toSet()
        saved = saved.copy(scores = saved.scores.filterKeys { it in keep }, rides = RideHistory.keep(saved.rides, keep))
        if (now - lastScoresLook >= 60 || now < lastScoresLook) {
            lastScoresLook = now
            scoresDue(friends, now)
        }
        freeDue(friends, now)
        save(); publish()
    }

    // MARK: the leaderboard with friends

    fun myScores(now: Double = now()): ScoresShare = ScoresRules.build(ScoreLog.trips.value, RideHistory.count(saved.rides, now), now)

    private fun scoresDue(friends: List<String>, now: Double) {
        if (settings.scores == true) {
            val body = myScores(now)
            val hash = ScoresRules.fingerprint(body)
            val to = ScoresRules.due(saved.scoresSent, hash, friends, now)
            if (to.isEmpty()) return
            FriendStore.queueBox(FriendMessage.Scores(body), to, ScoresRules.SLOT, ScoresRules.TTL)
            saved = saved.copy(scoresSent = TimetableShareRules.after(saved.scoresSent, hash, to, friends, now))
        } else {
            val sent = saved.scoresSent ?: return
            val still = sent.to.filter { it in friends }
            if (still.isNotEmpty()) FriendStore.queueBox(FriendMessage.Scores(ScoresShare(false)), still, ScoresRules.SLOT, ScoresRules.OFF_TTL)
            saved = saved.copy(scoresSent = null)
        }
    }

    /** You ("me") and the friends who share their scores. */
    fun boardPeople(now: Double = now()): List<ScoresPerson> =
        listOf(ScoresPerson("me", myScores(now))) + scores.value.filter { FriendStore.book.value?.isFriend(it.key) == true && it.value.share.on }
            .map { ScoresPerson(it.key, it.value.share) }

    val sharingCount: Int get() = scores.value.count { FriendStore.book.value?.isFriend(it.key) == true && it.value.share.on }

    // MARK: free hours together

    private suspend fun freeDue(friends: List<String>, now: Double) {
        val tt = FriendTimetables
        if (tt.mine.value == null && now - lastMineRead >= TimetableShareRules.LOOK_EVERY) {
            lastMineRead = now
            try { tt.readMine(ctx, now, sharing = false) } catch (_: Exception) {}
        }
        val theirs = friends.mapNotNull { id -> tt.timetable(id)?.let { id to it } }
        val slots = FreeToday.slots(tt.mine.value, theirs, now)
        if (slots != freeToday.value) freeToday.value = slots
        if (!FreeToday.noteDue(settings.free == true, saved.freeNoteDay, slots, now)) return
        saved = saved.copy(freeNoteDay = TimetableDays.key(now))
        FriendChats.tell(ctx, "friends-free", "Free time together today", FreeToday.note(slots, { FriendStore.name(it) }, now), null)
    }

    fun freeNow(now: Double = now()) = freeToday.value.filter { it.end > now }

    // MARK: ride history (on the ride's network tick)

    /** On board a bus or train with friends on it too: the ride goes in the history (once per vehicle per day). */
    fun rideTick(s: RideState?) = FriendStore.launch {
        s ?: return@launch
        val b = FriendStore.book.value ?: return@launch
        if (!FriendStore.hasFriends || s.phase == Phase.FINISHED) return@launch
        val v = s.vehicleTripId ?: return@launch
        val leg = s.leg ?: return@launch
        val now = now()
        if (FriendTravelShare.stage(s, now) != TravelState.Stage.RIDING) return@launch
        val travel = FriendStore.travelling(now).map { it.from to it.state }
        val who = RideHistory.riders(v, travel, FriendExtrasStore.myCards(now), me).filter { b.isFriend(it) }
        if (who.isEmpty()) return@launch
        val dep = leg.departure
        val line = if (leg.isTrain) TransitLabel.train(s.vehicleLine ?: leg.line, leg.name) else (s.vehicleLine ?: leg.line)
        val num = leg.num.ifEmpty { null }
        val label = if (leg.isTrain) (num?.let { "$line $it" } ?: line) else "Bus $line"
        val r = RideTogether(v, TimetableDays.key(dep), label, leg.fromStop, leg.toStop, dep, who)
        val next = RideHistory.add(saved.rides, r, now)
        if (next == saved.rides) return@launch
        saved = saved.copy(rides = next)
        save(); publish()
    }

    fun count(id: String, now: Double = now()) = RideHistory.count(rides.value, id, now)
    fun last(id: String) = RideHistory.last(rides.value, id)

    fun forgetAll() {
        saved = Saved()
        freeToday.value = emptyList()
        save(); publish()
    }
}
