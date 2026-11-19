package nl.haltewekker.friends

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.Serializable
import nl.haltewekker.App
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.Transit
import nl.haltewekker.ride.Phase
import nl.haltewekker.ride.RideState
import nl.haltewekker.ride.RideStore
import nl.haltewekker.school.SchoolAlarm
import nl.haltewekker.ui.Locator
import nl.haltewekker.ui.friends.CompareAsk
import nl.haltewekker.ui.friends.TripCards
import nl.haltewekker.ui.friends.WayCache
import java.io.File

/**
 * Friends extras (0.29), the iOS `FriendExtrasStore.swift`: "Wait for me", the delay alarm for shared rides, the
 * wake-up buddy and who's on campus. The rules are in `FriendExtras.kt` (tested); this keeps what came and what you
 * shared (`files/friends/extras.json`, not backed up; the switches also go in the vault) and runs only inside
 * `FriendStore`'s checks of the relay (app to the front, Friends or a chat open, the ride's once-a-minute tick, the
 * WorkManager refresh) and at region events. No loop of its own; it only reads the ride, never changes it. Everything
 * here runs on `FriendStore.lane`.
 */
object FriendExtrasStore {
    val waits = MutableStateFlow<Map<String, WaitSeen>>(emptyMap())
    val campus = MutableStateFlow<Map<String, CampusSeen>>(emptyMap())
    val buddies = MutableStateFlow<Map<String, BuddySeen>>(emptyMap())
    val delays = MutableStateFlow<List<DelaySeen>>(emptyList())
    val myWait = MutableStateFlow<MyWait?>(null)
    val settings = MutableStateFlow(ExtrasSettings())
    val campusShownTo = MutableStateFlow(0)
    val findingNext = MutableStateFlow<String?>(null)

    @Serializable
    data class MyWait(val id: String, val chat: String, val stop: TripCard.Spot, val ride: TripCard.Ride? = null, val started: Double,
                      val to: List<String>, val last: WaitFor? = null, val lastSent: Double? = null)

    @Serializable
    private data class Saved(
        val settings: ExtrasSettings = ExtrasSettings(),
        val waits: Map<String, WaitSeen> = emptyMap(),
        val campus: Map<String, CampusSeen> = emptyMap(),
        val buddies: Map<String, BuddySeen> = emptyMap(),
        val delays: List<DelaySeen> = emptyList(),
        val delayTold: Map<String, DelayTold> = emptyMap(),
        val buddyTold: Map<String, String> = emptyMap(),
        val waitsTold: List<String> = emptyList(),
        val myWait: MyWait? = null,
        val campusPosted: CampusPosted? = null,
        val campusInside: Boolean? = null,
        val campusSince: Double? = null,
        val buddySent: BuddyPlan? = null,
        val buddySentAt: Double? = null,
        val buddySentTo: List<String>? = null,
        val leftDay: String? = null,
        val leftAt: Double? = null,
    )

    private lateinit var ctx: Context
    private var saved = Saved()
    private var lastWritten: String? = null
    private var lastDelayLook: Double? = null
    private var checkingDelays = false
    private var askedPlan: String? = null

    /** The preference the region code reads: School's circle also tells on leaving, for "at school". */
    const val CAMPUS_REGION_KEY = "friends.campusRegion"

    private val file: File get() = File(FriendStore.folder(ctx), "extras.json")
    private fun now() = System.currentTimeMillis() / 1000.0
    private val me: String get() = FriendStore.myAccount ?: ""

    fun init(c: Context) {
        ctx = c.applicationContext
        saved = (try { file.takeIf { it.exists() }?.readText() } catch (_: Exception) { null })?.let { FriendJson.decode(Saved.serializer(), it) } ?: Saved()
        publish()
    }

    private fun publish() {
        settings.value = saved.settings
        waits.value = saved.waits
        campus.value = saved.campus
        buddies.value = saved.buddies
        delays.value = saved.delays
        myWait.value = saved.myWait
        campusShownTo.value = saved.campusPosted?.to?.size ?: 0
    }

    private fun save() {
        val text = FriendJson.encodeString(Saved.serializer(), saved)
        if (text == lastWritten) return
        try {
            val tmp = File(file.parentFile, "extras.json.tmp")
            tmp.writeText(text)
            tmp.renameTo(file)
            lastWritten = text
        } catch (_: Exception) {}
    }

    private fun app() = ctx.applicationContext as App

    // MARK: the ride (read only) and region events

    /** School's region tells on leaving too while "at school" is on (`AutoRules.withCampus`). */
    private fun mirrorCampus() {
        val on = FriendStore.hasAccount && saved.settings.campus == true
        val prefs = app().store.prefs
        if (prefs.getBoolean(CAMPUS_REGION_KEY, false) != on) {
            prefs.edit().putBoolean(CAMPUS_REGION_KEY, on).apply()
            try { nl.haltewekker.auto.Regions.update(ctx) } catch (_: Exception) {}
        }
    }

    /** A region event (from `AutoStart.onRegion`): at school, or leaving home (for the buddy). */
    fun region(id: String, entered: Boolean) = FriendStore.launch {
        if (!FriendStore.hasAccount) return@launch
        var worth = false
        if (id == nl.haltewekker.auto.AutoRules.SCHOOL_ID && saved.settings.campus == true) {
            if (entered != saved.campusInside) saved = saved.copy(campusInside = entered, campusSince = if (entered) now() else null)
            worth = true
        }
        if (!entered && nl.haltewekker.auto.AutoRules.role(id) == nl.haltewekker.auto.AutoRules.Role.HOME && !saved.settings.buddy.isNullOrEmpty()) {
            markLeft()
            worth = true
        }
        save()
        if (worth) FriendStore.sync(FriendStore.Why.NOW)
    }

    /** A trip started (any trip): you set off today (for friends who watch you). */
    fun tripStarted() = FriendStore.launch { markLeft(); save() }

    private fun markLeft() {
        if (saved.settings.buddy.isNullOrEmpty()) return
        val today = TimetableDays.key(now())
        if (saved.leftDay == today) return
        saved = saved.copy(leftDay = today, leftAt = now())
    }

    data class Fix(val p: GeoPoint, val at: Double)

    /** Your position: the ride's last fix (≤ maxAge, accuracy < 300 m), else the phone's last known one. */
    private fun position(maxAge: Double): Fix? {
        val s = RideStore.state.value
        val t = now()
        val a = if (s?.lastLat != null && s.lastLon != null && s.lastFixAt != null && t - s.lastFixAt <= maxAge && (s.accuracy ?: 0.0) in 0.0..299.9)
            Fix(GeoPoint(s.lastLat, s.lastLon), s.lastFixAt) else null
        val l = try { Locator.lastFix(ctx) } catch (_: Exception) { null }
        val b = l?.takeIf { t - it.time / 1000.0 <= maxAge && (!it.hasAccuracy() || it.accuracy < 300) }?.let { Fix(GeoPoint(it.latitude, it.longitude), it.time / 1000.0) }
        if (a != null && b != null) return if (a.at >= b.at) a else b
        return a ?: b
    }

    // MARK: what came in

    fun take(r: FriendInbox.Result) {
        var changed = false
        val waits = saved.waits.toMutableMap()
        var told = saved.waitsTold
        for ((id, w) in r.waits) {
            if ((waits[id]?.t ?: Long.MIN_VALUE) > w.t) continue
            waits[id] = w
            changed = true
            if (w.wait.id !in told && w.wait.phase != WaitFor.Phase.OFF && WaitAge.freshness(w, now()) != TravelFreshness.GONE) {
                told = (told + w.wait.id).takeLast(50)
                val name = FriendStore.name(id)
                FriendChats.tell(ctx, "friends-wait-$id", "$name asks you to wait",
                    WaitWords.line(name, w.wait, now()) + ". " + WaitWords.detail(name, w.wait), w.chat)
            }
        }
        val campus = saved.campus.toMutableMap()
        for ((id, c) in r.campus) {
            if ((campus[id]?.t ?: Long.MIN_VALUE) > c.t) continue
            if (c.state.on) campus[id] = c else campus.remove(id)
            changed = true
        }
        val buddies = saved.buddies.toMutableMap()
        for ((id, b) in r.buddies) {
            if ((buddies[id]?.t ?: Long.MIN_VALUE) > b.t) continue
            if (b.plan.on) buddies[id] = b else buddies.remove(id)
            changed = true
        }
        saved = saved.copy(waits = waits, waitsTold = told, campus = campus, buddies = buddies)
        for (d in r.delays) { changed = true; heard(d) }
        if (changed) { save(); publish() }
    }

    /** A delay on a ride you share: told once (and again when it moves 2 minutes or more), whoever found it. */
    private fun heard(d: DelaySeen) {
        val trip = d.delay.ride.trip
        saved = saved.copy(delays = listOf(d) + saved.delays.filter { it.delay.ride.trip != trip })
        val told = saved.delayTold[trip]
        if (!DelayAlarm.shouldTell(d.delay.late, d.delay.isCancelled, told)) return
        saved = saved.copy(delayTold = saved.delayTold + (trip to DelayTold(d.delay.late, d.delay.isCancelled, now())))
        val names = (d.delay.who ?: listOf(d.from)).map { if (it == me) "you" else FriendStore.name(it) }
        val by = if (d.from == me) "" else " (from ${FriendStore.name(d.from)})"
        FriendChats.tell(ctx, "friends-delay-$trip", DelayWords.title(d.delay) + by, DelayWords.body(d.delay, names), null)
    }

    // MARK: at each check

    suspend fun due(now: Double) {
        if (!FriendStore.hasAccount) return
        prune(now)
        waitDue(now)
        campusDue(now)
        buddyDue(now)
        buddyWatch(now)
        if (DelayAlarm.lookDue(lastDelayLook, now) && !checkingDelays) {
            lastDelayLook = now
            FriendStore.launch { checkDelays() }
        }
        save()
        publish()
    }

    private fun prune(now: Double) {
        val b = FriendStore.book.value
        fun friend(id: String) = b?.isFriend(id) == true
        var allowed = saved.settings.buddy
        if (allowed != null && allowed.any { !friend(it) }) allowed = allowed.filter(::friend).ifEmpty { null }
        saved = saved.copy(
            waits = saved.waits.filter { WaitAge.freshness(it.value, now) != TravelFreshness.GONE && (friend(it.key) || FriendStore.groups.value.shares(it.key)) },
            campus = saved.campus.filter { CampusRules.here(it.value, now) && friend(it.key) },
            buddies = saved.buddies.filter { friend(it.key) },
            delays = saved.delays.filter { now - it.got < 3 * 3600 && it.delay.ride.arr > now - 15 * 60 },
            delayTold = saved.delayTold.filter { now - it.value.at < 6 * 3600 },
            settings = saved.settings.copy(buddy = allowed),
        )
    }

    // MARK: wait for me (yours)

    /** "Wait for me" in a chat (a friend's or a group's): at `stop`, for `ride` when known. Again at each check. */
    fun startWait(chat: String, stop: TripCard.Spot, ride: TripCard.Ride?) = FriendStore.launch {
        val to = FriendStore.recipients(chat).map { it.account }
        if (to.isEmpty() || stop.point == null) return@launch
        saved.myWait?.let { sendWaitOff(it) }
        saved = saved.copy(myWait = MyWait(RelaySign.nonce().take(22), chat, stop, ride, now(), to))
        waitDue(now())
        save(); publish()
        FriendChats.note("You asked ${if (ChatKey.isGroup(chat)) "the group" else FriendStore.name(chat)} to wait for you at ${stop.name}", chat)
        FriendStore.sync(FriendStore.Why.NOW)
    }

    fun stopWait() = FriendStore.launch {
        val w = saved.myWait ?: return@launch
        sendWaitOff(w)
        saved = saved.copy(myWait = null)
        save(); publish()
        FriendStore.sync(FriendStore.Why.NOW)
    }

    private fun sendWaitOff(w: MyWait) {
        val off = WaitFor(w.id, WaitFor.Phase.OFF.raw, w.stop, w.ride, at = now())
        FriendStore.queueBox(FriendMessage.Wait(off), w.to, WaitRules.SLOT, WaitRules.TTL, ChatKey.groupId(w.chat))
    }

    private fun waitDue(now: Double) {
        val w = saved.myWait ?: return
        val stopPoint = w.stop.point ?: return
        val fix = position(90.0)
        val dist = fix?.let { Geo.metres(it.p, stopPoint) }
        val phase = WaitRules.phase(dist, w.started, w.ride?.dep, now)
        if (phase == null) { sendWaitOff(w); saved = saved.copy(myWait = null); return }
        var body = WaitFor(w.id, phase.raw, w.stop, w.ride, at = fix?.at ?: now)
        if (dist != null) body = body.copy(dist = Math.round(dist).toInt(), eta = rideEta(stopPoint) ?: WaitRules.eta(dist, now))
        else if (w.last != null) body = body.copy(dist = w.last.dist, eta = w.last.eta, at = w.last.at)
        if (!WaitRules.due(w.last, w.lastSent, body, now)) return
        FriendStore.queueBox(FriendMessage.Wait(body), w.to, WaitRules.SLOT, WaitRules.TTL, ChatKey.groupId(w.chat))
        saved = saved.copy(myWait = w.copy(last = body, lastSent = now))
    }

    private fun running(s: RideState?) = s != null && s.phase != Phase.FINISHED

    /** On a bus or train to that stop (you change there): when it gets there. */
    private fun rideEta(stop: GeoPoint): Double? {
        val s = RideStore.state.value ?: return null
        if (!running(s) || FriendTravelShare.stage(s, now()) != TravelState.Stage.RIDING) return null
        val to = s.leg?.to ?: return null
        if (Geo.metres(to, stop) > WaitNext.SAME_STOP) return null
        return s.legArrival
    }

    data class WaitTarget(val stop: TripCard.Spot, val ride: TripCard.Ride?)

    /** On the ride screen, while you're not on board yet: the stop you're on your way to and the ride from there. */
    fun rideWaitTarget(s: RideState?): WaitTarget? {
        s ?: return null
        if (!running(s) || FriendTravelShare.stage(s, now()) == TravelState.Stage.RIDING) return null
        val leg = s.leg ?: return null
        val r = TripCards.ride(leg)
        if (r.from.point == null) return null
        return WaitTarget(r.from, r.takeIf { it.trip.isNotEmpty() })
    }

    fun answersToMine(): Map<String, WaitAnswer> {
        val w = myWait.value ?: return emptyMap()
        return FriendChats.book.value.waitAnswers(w.id, w.chat)
    }

    // MARK: wait for me (theirs)

    fun waitsForMe(now: Double = now()): List<WaitSeen> =
        waits.value.values.filter { WaitAge.freshness(it, now) != TravelFreshness.GONE && FriendStore.recipients(it.chat).isNotEmpty() }.sortedByDescending { it.got }

    fun myAnswer(w: WaitSeen): WaitAnswer? = FriendChats.book.value.waitAnswers(w.wait.id, w.chat)[me]

    fun willWait(w: WaitSeen) = FriendChats.answerWait(WaitAnswer.WAIT, w.wait.id, w.chat)

    /** "Take the next one with you": the next ride from that stop after they get there, as a trip card (one planner question). */
    fun takeNext(w: WaitSeen) = FriendStore.launch {
        if (findingNext.value != null) return@launch
        val stop = w.wait.stop.point ?: return@launch
        findingNext.value = w.wait.id
        try {
            val dest = myDestination(stop) ?: w.wait.ride?.to
            val after = maxOf(now(), w.wait.eta ?: now()) + 60
            var card: TripCard? = null
            val from = CompareAsk.place(w.wait.stop)
            val to = dest?.let { CompareAsk.place(it) }
            if (dest != null && from != null && to != null) {
                val ways = Transit.plan(from, to, after, count = 5, maxTransfers = 2).map { t -> Way(t.rides.map(CompareAsk::leg), t.start, t.end) }
                val way = WaitNext.pick(ways, stop, after, w.wait.ride?.trip, w.wait.ride?.line)
                val first = way?.legs?.firstOrNull()
                if (way != null && first != null) {
                    card = TripCard(way.legs.take(TripCard.MAX_RIDES).map { it.card }, dest, w.wait.stop, way.start, way.end,
                        note = "Take the next one with me? ${first.label} at ${TimetableDays.hhmm(first.dep)}")
                }
            }
            FriendChats.answerWaitNow(WaitAnswer.NEXT, w.wait.id, w.chat)
            if (card != null) FriendChats.sendTrip(card, listOf(w.chat))
        } finally { findingNext.value = null }
    }

    private fun myDestination(stop: GeoPoint): TripCard.Spot? {
        val s = RideStore.state.value ?: return null
        if (!running(s)) return null
        for (r in s.trip.rides.drop(s.index)) {
            val f = r.from ?: continue
            if (Geo.metres(f, stop) <= WaitNext.SAME_STOP) return TripCards.ride(r).to
        }
        return null
    }

    // MARK: who's on campus

    fun setCampus(on: Boolean) = FriendStore.launch {
        saved = saved.copy(settings = saved.settings.copy(campus = if (on) true else null),
            campusInside = if (on) saved.campusInside else null, campusSince = if (on) saved.campusSince else null)
        save(); publish()
        mirrorCampus()
        FriendStore.extrasSettingsChanged()
    }

    data class OnCampus(val id: String, val state: CampusState)

    fun onCampus(now: Double = now()): List<OnCampus> =
        campus.value.filter { CampusRules.here(it.value, now) && FriendStore.book.value?.isFriend(it.key) == true }
            .entries.sortedBy { FriendStore.name(it.key) }.map { OnCampus(it.key, it.value.state) }

    private fun schoolShort(): String? {
        val p = app().store.profile.value
        return app().schools.firstOrNull { it.id == p.schoolId }?.short ?: p.school?.name?.takeIf { it.isNotBlank() }
    }

    private fun campusDue(now: Double) {
        val on = saved.settings.campus == true
        var inside: Boolean? = null
        if (on) {
            val school = app().store.profile.value.school?.point
            val fix = position(CampusRules.FIX_AGE)
            inside = if (fix != null && school != null)
                CampusRules.inside(Geo.metres(fix.p, school), nl.haltewekker.auto.AutoRules.SCHOOL_RADIUS, saved.campusInside ?: false)
            else saved.campusInside
            if (inside != null && inside != saved.campusInside) saved = saved.copy(campusInside = inside, campusSince = if (inside) (fix?.at ?: now) else null)
        }
        val friends = FriendStore.book.value?.friends?.map { it.id } ?: emptyList()
        when (val a = CampusRules.decide(on, inside, saved.campusSince, saved.campusPosted, friends, now)) {
            is CampusRules.Action.Post -> {
                val until = saved.campusPosted?.until ?: CampusRules.until(a.since)
                val body = CampusState(true, schoolShort(), a.since, until)
                FriendStore.queueBox(FriendMessage.Campus(body), a.to, CampusRules.SLOT, CampusRules.ttl(until, now))
                saved = saved.copy(campusPosted = CampusPosted(a.since, until, (saved.campusPosted?.to ?: emptyList()) + a.to))
            }
            is CampusRules.Action.Clear -> {
                FriendStore.queueBox(FriendMessage.Campus(CampusState(false)), a.to, CampusRules.SLOT, CampusRules.OFF_TTL)
                saved = saved.copy(campusPosted = null)
            }
            CampusRules.Action.None -> {}
        }
    }

    // MARK: part B's switches (0.30)

    fun setFreeNote(on: Boolean) = FriendStore.launch {
        saved = saved.copy(settings = saved.settings.copy(free = if (on) true else null)); save(); publish()
        FriendStore.extrasSettingsChanged()
    }

    fun setShareScores(on: Boolean) = FriendStore.launch {
        saved = saved.copy(settings = saved.settings.copy(scores = if (on) true else null)); save(); publish()
        FriendStore.extrasSettingsChanged()
    }

    // MARK: the wake-up buddy (yours)

    fun allowsBuddy(id: String) = (settings.value.buddy ?: emptyList()).contains(id)

    fun setBuddy(id: String, on: Boolean) = FriendStore.launch {
        val list = (saved.settings.buddy ?: emptyList()).filter { it != id } + if (on) listOf(id) else emptyList()
        saved = saved.copy(settings = saved.settings.copy(buddy = list.sorted().ifEmpty { null })); save(); publish()
        FriendStore.extrasSettingsChanged()
    }

    /** Your plan as friends who watch it see it: the school alarm's next trip, else your timetable's way to the first class. */
    private suspend fun myPlan(now: Double): BuddyPlan {
        var p = BuddyPlan(on = true)
        val n = SchoolAlarm.week.value.filter { (it.leave ?: Double.NEGATIVE_INFINITY) > now - 2 * 3600 }.minByOrNull { it.classStart }
        val leave = n?.leave
        if (n != null && leave != null && leave - now < 24 * 3600) {
            p = p.copy(day = TimetableDays.key(leave), leave = leave, ride = n.trip?.rides?.firstOrNull()?.let(TripCards::ride))
        } else timetableWay(now)?.let { w -> p = p.copy(day = TimetableDays.key(w.start), leave = w.start, ride = w.legs.firstOrNull()?.card) }
        if (saved.leftDay != null && saved.leftDay == (p.day ?: TimetableDays.key(now))) p = p.copy(left = saved.leftAt)
        return p
    }

    /** Your way to today's (or tomorrow's) first class from your shared timetable and area: cached, asked once a day. */
    private suspend fun timetableWay(now: Double): Way? {
        val share = FriendTimetables.mine.value ?: return null
        val area = FriendTimetables.myArea.value ?: return null
        val me = ComparePerson("me", "You", true, share, area)
        for (d in Compare.days(listOf(me), now).take(2)) {
            val pd = d.person("me") ?: continue
            val first = pd.first ?: continue
            if (first <= now) continue
            val q = CompareAsk.question(pd, area, SharedRides.Direction.TO_SCHOOL) ?: continue
            val k = WayCache.key(q.dir, q.from, q.to, q.at)
            val ways = WayCache.get(ctx, k, q.at)
            if (ways != null) {
                val ok = SharedRides.usable(PersonWays("me", ways, q.bound), SharedRides.Direction.TO_SCHOOL)
                return ok.map { ways[it] }.maxByOrNull { it.start }
            }
            if (askedPlan != d.key) {
                askedPlan = d.key
                FriendStore.launch { CompareAsk.ask(ctx, q, RequestBudget(1)) }
            }
            return null
        }
        return null
    }

    private suspend fun buddyDue(now: Double) {
        val friends = (FriendStore.book.value?.friends?.map { it.id } ?: emptyList()).toSet()
        val allowed = (saved.settings.buddy ?: emptyList()).filter { it in friends }
        val had = saved.buddySentTo ?: emptyList()
        val gone = had.filter { it !in allowed }
        if (gone.isNotEmpty()) FriendStore.queueBox(FriendMessage.Buddy(BuddyPlan(false)), gone, BuddyRules.SLOT, BuddyRules.TTL)
        if (allowed.isEmpty()) { saved = saved.copy(buddySentTo = null, buddySent = null, buddySentAt = null); return }
        val plan0 = myPlan(now)
        val leave0 = plan0.leave
        if (saved.leftDay != TimetableDays.key(now) && leave0 != null && plan0.day == TimetableDays.key(now) && now > leave0 - 3600) {
            val fix = position(600.0)
            val home = app().store.profile.value.home?.point
            if (fix != null && home != null && Geo.metres(fix.p, home) > BuddyRules.AWAY_METRES) markLeft()
        }
        val plan = myPlan(now)
        val fresh = allowed.filter { it !in had }
        if (BuddyRules.due(saved.buddySent, saved.buddySentAt, plan, now)) {
            FriendStore.queueBox(FriendMessage.Buddy(plan), allowed, BuddyRules.SLOT, BuddyRules.TTL)
            saved = saved.copy(buddySent = plan, buddySentAt = now)
        } else if (fresh.isNotEmpty()) FriendStore.queueBox(FriendMessage.Buddy(plan), fresh, BuddyRules.SLOT, BuddyRules.TTL)
        saved = saved.copy(buddySentTo = allowed)
    }

    // MARK: the wake-up buddy (theirs)

    private fun buddyWatch(now: Double) {
        val today = TimetableDays.key(now)
        for ((id, b) in saved.buddies) {
            if (!b.plan.on || FriendStore.book.value?.isFriend(id) != true) continue
            val plan = BuddyRules.plan(b.plan, cardsWith(id, now - 24 * 3600), today) ?: continue
            val seen = listOfNotNull(FriendStore.travel.value[id]?.sent, saved.waits[id]?.got)
            val left = if (b.plan.day == today) b.plan.left else null
            val moving = BuddyRules.moving(left, seen, plan.leave)
            if (!BuddyRules.alert(plan.leave, plan.ride, moving, saved.buddyTold[id], today, now)) continue
            saved = saved.copy(buddyTold = saved.buddyTold + (id to today))
            val name = FriendStore.name(id)
            FriendChats.tell(ctx, "friends-buddy-$id", BuddyWords.title(name, plan.leave, plan.ride), BuddyWords.body(name, plan.leave, plan.ride), ChatKey.friend(id))
        }
    }

    /** Trip cards someone is in (they sent it, or said "I'm in"), in your chat with them or your groups. */
    private fun cardsWith(id: String, since: Double): List<Pair<TripCard, Boolean>> {
        val out = mutableListOf<Pair<TripCard, Boolean>>()
        val book = FriendChats.book.value
        for (chat in FriendChats.recent) {
            if (chat.key != id && !ChatKey.isGroup(chat.key)) continue
            for (m in chat.messages) {
                if (m.at <= since) continue
                val c = m.trip ?: continue
                if (m.from == id) { out.add(c to true); continue }
                if (book.answers(m.n, chat.key)[id] == TripAnswer.YES) out.add(c to false)
            }
        }
        return out
    }

    // MARK: the delay alarm

    /** Your trip's rides now: the vehicle you're on, the leg you wait for, the planned ones still to come. */
    fun myRides(now: Double): List<TripCard.Ride> {
        val s = RideStore.state.value ?: return emptyList()
        if (!running(s)) return emptyList()
        val out = mutableListOf<TripCard.Ride>()
        s.trip.rides.forEachIndexed { k, r ->
            if (k < s.index) return@forEachIndexed
            var ride = TripCards.ride(r)
            if (k == s.index) {
                val v = s.vehicleTripId
                if (v != null && v != r.tripId) ride = ride.copy(trip = v, line = s.vehicleLine ?: ride.line, num = null)
                ride = ride.copy(arr = maxOf(ride.dep, s.legArrival ?: ride.arr))
            }
            if (ride.trip.isNotEmpty() && out.none { it.trip == ride.trip }) out.add(ride)
        }
        return out
    }

    /** Trip cards you're in (from the last 24 h), with the others who are. */
    fun myCards(now: Double): List<Pair<TripCard, List<String>>> {
        val out = mutableListOf<Pair<TripCard, List<String>>>()
        val book = FriendChats.book.value
        for (chat in FriendChats.recent) for (m in chat.messages) {
            if (m.at <= now - 24 * 3600) continue
            val c = m.trip ?: continue
            DelayAlarm.riders(m.from, book.answers(m.n, chat.key), me)?.let { out.add(c to it) }
        }
        return out
    }

    private suspend fun checkDelays() {
        val now = now()
        val travel = FriendStore.travelling(now).map { it.from to it.state }
        val refs = DelayAlarm.shared(myRides(now), travel, myCards(now), me, now)
        if (refs.isEmpty()) return
        checkingDelays = true
        var sent = false
        try {
            for (ref in refs.take(3)) {
                val live = lateness(ref.ride, now) ?: continue
                val trip = ref.ride.trip
                if (!DelayAlarm.shouldTell(live.late, live.cancelled, saved.delayTold[trip])) continue
                var ride = ref.ride
                live.dep?.let { d -> ride = ride.copy(sdep = d - live.late * 60.0, dep = d, arr = maxOf(ride.arr, d)) }
                val next = saved.delays.firstOrNull { it.delay.ride.trip == trip }?.delay?.next ?: nextTogether(ref, now)
                val d = RideDelay(ride, live.late, if (live.cancelled) true else null, next, listOf(me) + ref.riders)
                heard(DelaySeen(me, d, now))
                FriendStore.queueBox(FriendMessage.Delay(d), ref.riders, DelayAlarm.SLOT, DelayAlarm.TTL)
                sent = true
            }
        } finally { checkingDelays = false }
        save(); publish()
        if (sent) FriendStore.sync(FriendStore.Why.NOW)
    }

    /** How late a ride is, from the live data's stops (`/v5/trip`). */
    private suspend fun lateness(r: TripCard.Ride, now: Double): DelayRead? {
        val t = Transit.trip(r.trip, 120.0) ?: return null
        val stops = t.stops.map { DelayStop(it.name, it.point, it.departure, it.scheduledDeparture, it.cancelled) }
        return DelayAlarm.read(stops, r.from, now)
    }

    private suspend fun nextTogether(ref: SharedRideRef, now: Double): TripCard.Ride? {
        val who = mutableListOf(Triple(me, ref.ride.from, ref.ride.to))
        for (id in ref.riders) {
            val s = ref.spots[id] ?: listOf(ref.ride.from, ref.ride.to)
            if (s.size == 2) who.add(Triple(id, s[0], s[1]))
        }
        val asked = HashMap<String, List<Way>>()
        val people = mutableListOf<PersonWays>()
        val at = now + 60
        for ((id, f, t) in who) {
            val a = CompareAsk.place(f) ?: continue
            val b = CompareAsk.place(t) ?: continue
            val k = "$a>$b"
            if (k !in asked) {
                if (asked.size >= DelayAlarm.BUDGET) continue
                asked[k] = Transit.plan(a, b, at, count = 5, maxTransfers = 2).map { x -> Way(x.rides.map(CompareAsk::leg), x.start, x.end) }
            }
            val ways = asked[k]
            if (!ways.isNullOrEmpty()) people.add(PersonWays(id, ways, at))
        }
        if (people.size < 2) return null
        val s = DelayAlarm.next(people, ref.ride.trip, now + 120) ?: return null
        val first = s.riders.minByOrNull { it.dep } ?: return null
        return people.firstOrNull { it.id == first.id }?.ways?.getOrNull(first.way)?.legs?.getOrNull(first.leg)?.card
    }

    fun delaysNow(trips: Set<String>, now: Double = now()): List<DelaySeen> = delays.value.filter { it.delay.ride.trip in trips && it.delay.ride.arr > now }

    fun myTrips(): Set<String> = myRides(now()).map { it.trip }.toSet()

    // MARK: the vault, a restore, signing out

    val vaultSettings: ExtrasSettings? get() = saved.settings.takeIf { it != ExtrasSettings() }

    fun restore(s: ExtrasSettings?) {
        saved = saved.copy(settings = s ?: ExtrasSettings())
        save(); publish()
        mirrorCampus()
    }

    fun forgetAll() {
        saved = Saved()
        save(); publish()
        mirrorCampus()
    }
}
