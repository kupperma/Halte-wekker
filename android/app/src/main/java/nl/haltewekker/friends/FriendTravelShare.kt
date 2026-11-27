package nl.haltewekker.friends

import android.content.Context
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import nl.haltewekker.data.Transit
import nl.haltewekker.ride.Phase
import nl.haltewekker.ride.RideState
import nl.haltewekker.ride.RideStore
import nl.haltewekker.ride.VehicleSource

/**
 * Friends (0.26), the iOS `FriendTravelShare.swift`: your trip, to the friends you show your trips to. It only reads the
 * ride (`RideStore`, and the ride's own network tick from `RideService`): it never changes the trip, the alarm or the
 * notification, and has no loop of its own. Shared while a trip runs and you're confirmed on board (you started it
 * yourself, said "I'm on it", or the ride matched your bus or train by GPS), once the one-time screen is answered:
 * every minute and at once when the leg, vehicle, stage or coach changes. Taken back when the trip ends.
 */
object FriendTravelShare {
    /** Confirmed on board with friends to share with, but the one-time screen isn't answered: the ride screen asks. */
    val needsAnswer = MutableStateFlow(false)
    /** The coach you marked, for the train (trip id) you're on now. */
    val coach = MutableStateFlow<TravelState.Coach?>(null)
    val coachTrip = MutableStateFlow<String?>(null)

    @Volatile var sharing = false
        private set
    private var confirmed = false
    private var lastSent: Double? = null
    private var lastFetch: Double? = null
    private var lastKey = ""
    private var sending = false
    private var again = false
    private var clearAfter = false
    internal val numbers = HashMap<String, String>()
    private var attached = false

    private fun now() = System.currentTimeMillis() / 1000.0

    /** Starts watching the ride (once, as the app starts). */
    @OptIn(FlowPreview::class)
    fun attach(c: Context) {
        if (attached) return
        attached = true
        val app = c.applicationContext
        FriendStore.scope.launch {
            RideStore.state.map { it?.let { s -> key(s) } ?: "none" }.distinctUntilChanged().debounce(2000).collect { changed(app) }
        }
        // (0.29) a trip started: you set off today (for the friends who watch you as a wake-up buddy)
        FriendStore.scope.launch {
            RideStore.state.map { running(it) }.distinctUntilChanged().collect { if (it) FriendExtrasStore.tripStarted() }
        }
        // a trip that ended while the app was gone: its state is taken back (nothing happens if none went out)
        if (RideStore.state.value == null) FriendStore.launch { FriendStore.clearTravel() }
    }

    fun running(s: RideState?) = s != null && s.phase != Phase.FINISHED

    fun signals(s: RideState?) = TravelShareRules.Signals(
        running = running(s),
        startedByHand = s != null && !s.auto,
        vehicleMatched = s?.vehicleSource == VehicleSource.BY_GPS,
        pickedByHand = s?.vehicleSource == VehicleSource.BY_HAND,
    )

    /** Still at the stop (first leg) or between two legs: no vehicle yet and the leg hasn't left (a minute's slack). */
    fun stage(s: RideState, now: Double): TravelState.Stage {
        val leg = s.leg ?: return TravelState.Stage.RIDING
        val notYet = s.vehicleSource == VehicleSource.NONE && now < leg.departure + 60
        return when {
            notYet && s.index > 0 -> TravelState.Stage.CHANGE
            notYet -> TravelState.Stage.WAITING
            else -> TravelState.Stage.RIDING
        }
    }

    private fun key(s: RideState) = "${s.index}|${s.vehicleTripId ?: "-"}|${stage(s, now()).name}|${s.phase == Phase.FINISHED}|${coach.value?.n ?: 0}|${coach.value?.seat?.let { "${it.deck}${it.w}" } ?: "-"}"

    private fun changed(c: Context) {
        // (0.30) the live link: at once on a new leg, stage or vehicle (it has its own rules)
        LiveLinkStore.tick()
        val s = RideStore.state.value
        val sig = signals(s)
        confirmed = if (sig.running) TravelShareRules.confirmed(confirmed, sig) else false
        if (coachTrip.value != null && coachTrip.value != s?.vehicleTripId) { coach.value = null; coachTrip.value = null }
        evaluate(c, force = s != null && key(s) != lastKey)
    }

    /** The ride's network tick (every 15–30 s on a trip): the next state when a minute has gone by, and a whole check. */
    fun tick(c: Context) = FriendStore.launch {
        val app = c.applicationContext
        val s = RideStore.state.value
        confirmed = if (signals(s).running) TravelShareRules.confirmed(confirmed, signals(s)) else false
        evaluate(app, force = false)
        // (0.30) the live link's next state, and the ride history (friends on this bus or train with you)
        LiveLinkStore.tick()
        FriendTogetherStore.rideTick(s)
        if (!FriendStore.hasFriends || sending || !TravelAge.due(lastFetch, now())) return@launch
        lastFetch = now()
        FriendStore.sync(FriendStore.Why.TICK)
    }

    fun settingsChanged(c: Context) = FriendStore.launch { evaluate(c.applicationContext, force = true) }

    private fun evaluate(c: Context, force: Boolean) {
        val d = TravelShareRules.decide(FriendStore.travelConsent, FriendStore.travelPaused.value, confirmed, FriendStore.travelFriends, sharing)
        needsAnswer.value = d == TravelShareRules.Decision.Ask
        when (d) {
            is TravelShareRules.Decision.Share -> if (force || TravelAge.due(lastSent, now())) send(c, d.to)
            TravelShareRules.Decision.Clear -> clear()
            else -> {}
        }
    }

    private fun send(c: Context, ids: List<String>) {
        if (sending) { again = true; return }
        val s = RideStore.state.value ?: return
        val base = build(s, now()) ?: return
        sending = true
        sharing = true
        lastSent = now()
        lastKey = key(s)
        FriendStore.launch {
            try {
                var st = base
                if (st.isTrain && st.num == null) st.trip?.let { id -> number(id)?.let { st = st.copy(num = it) } }
                FriendStore.putTravel(st, ids)
                FriendStore.fetchTravel()
                lastFetch = now()
                if (clearAfter) { clearAfter = false; FriendStore.clearTravel() }
            } finally {
                sending = false
                if (again) { again = false; evaluate(c, force = true) }
            }
        }
    }

    private fun clear() {
        again = false
        sharing = false
        lastSent = null
        lastKey = ""
        if (sending) { clearAfter = true; return }
        FriendStore.launch { FriendStore.clearTravel() }
    }

    /** A train's number from its live trip (kept per trip id; the seat picker asks for NS's drawing with it). */
    suspend fun number(tripId: String): String? {
        numbers[tripId]?.let { return it }
        val n = Transit.trip(tripId, 300.0)?.num?.takeIf { it.isNotEmpty() } ?: return null
        numbers[tripId] = n
        return n
    }

    private fun round(x: Double) = Math.round(x * 100_000) / 100_000.0

    /** The trip as friends get it (null: no leg). Home is never sent as a place. */
    fun build(s: RideState, now: Double): TravelState? {
        val leg = s.leg ?: return null
        val st = stage(s, now)
        fun spot(name: String, lat: Double?, lon: Double?) = TravelState.Spot(name, lat?.let(::round), lon?.let(::round))
        val last = s.trip.rides.last()
        val dest = when {
            s.destination == "Home" -> TravelState.Spot("Home")
            last.toStop != leg.toStop -> spot(last.toStop, last.toLat, last.toLon)
            else -> null
        }
        val train = leg.isTrain
        val vehicleLine = s.vehicleLine ?: leg.line
        val pos = if (s.lastLat != null && s.lastLon != null && s.lastFixAt != null && now - s.lastFixAt < 300 && (s.accuracy ?: 0.0) in 0.0..499.9)
            TravelState.Position(s.lastLat, s.lastLon, s.accuracy?.let { Math.round(it).toDouble() }, Math.floor(s.lastFixAt)) else null
        val tripId = s.vehicleTripId ?: leg.tripId
        return TravelState(
            state = when (st) { TravelState.Stage.WAITING -> "waiting"; TravelState.Stage.CHANGE -> "change"; else -> "riding" },
            mode = if (train) "train" else "bus",
            line = if (train) TransitLabel.train(vehicleLine, leg.name) else vehicleLine,
            num = leg.num.ifEmpty { null } ?: numbers[tripId],
            trip = tripId.ifEmpty { null },
            from = spot(leg.fromStop, leg.fromLat, leg.fromLon),
            to = spot(leg.toStop, leg.toLat, leg.toLon),
            dest = dest,
            eta = s.legArrival?.let { Math.floor(it) },
            end = Math.floor(s.trip.end),
            pos = pos,
            leg = s.index + 1,
            legs = s.trip.rides.size,
            coach = if (train && coachTrip.value == tripId) coach.value else null,
        )
    }

    /** The NS station where your trip boards this train (you're on it, or a leg still to come takes it). */
    fun boarding(c: Context, tripId: String): String? {
        val s = RideStore.state.value ?: return null
        if (!running(s)) return null
        val codes = NSCodes.get(c)
        for ((k, r) in s.trip.rides.withIndex()) {
            if (k < s.index) continue
            if (r.tripId == tripId || (k == s.index && s.vehicleTripId == tripId)) return codes.code(r.fromId, r.fromStop)
        }
        return null
    }

    /** You marked your coach (null: took it away): friends get it with the next state, which goes now. */
    fun setCoach(c: Context, value: TravelState.Coach?, tripId: String) {
        coach.value = value
        coachTrip.value = if (value == null) null else tripId
        settingsChanged(c)
    }
}

/** A train's line as shown ("IC", "SPR") from the planner's label. */
object TransitLabel {
    fun train(line: String, name: String): String {
        val l = nl.haltewekker.data.TransitParse.trainLabel(name.ifEmpty { line })
        return l.ifEmpty { line }
    }
}
