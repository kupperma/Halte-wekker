package nl.haltewekker.ui.friends

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import nl.haltewekker.core.Geo
import nl.haltewekker.data.Transit
import nl.haltewekker.friends.ChatKey
import nl.haltewekker.friends.Compare
import nl.haltewekker.friends.CompareDay
import nl.haltewekker.friends.ComparePerson
import nl.haltewekker.friends.CompareWords
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.FriendStore
import nl.haltewekker.friends.FriendTimetables
import nl.haltewekker.friends.MeetHalfway
import nl.haltewekker.friends.MeetPlan
import nl.haltewekker.friends.MeetWords
import nl.haltewekker.friends.PersonDay
import nl.haltewekker.friends.PersonWays
import nl.haltewekker.friends.RequestBudget
import nl.haltewekker.friends.RideWords
import nl.haltewekker.friends.Rider
import nl.haltewekker.friends.RouteStop
import nl.haltewekker.friends.SharedRide
import nl.haltewekker.friends.SharedRides
import nl.haltewekker.friends.TimetableArea
import nl.haltewekker.friends.TimetableDays
import nl.haltewekker.friends.TripCard
import nl.haltewekker.friends.Way
import nl.haltewekker.friends.WayLeg
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Header
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS
import java.io.File

/** The planner's ways, kept per question for the day (iOS `WayCache`): 30 min for a time within 36 h, else 6 h. */
object WayCache {
    @Serializable private data class Entry(val ways: List<Way>, val at: Double, val asked: Double)
    private var items: MutableMap<String, Entry>? = null
    private fun file(c: Context) = File(c.cacheDir, "friend-ways.json")
    private fun now() = System.currentTimeMillis() / 1000.0

    private fun load(c: Context): MutableMap<String, Entry> = items ?: (try { file(c).takeIf { it.exists() }?.readText() } catch (_: Exception) { null }
        ?.let { FriendJson.decode(MapSerializer(String.serializer(), Entry.serializer()), it) }?.filterValues { it.at > now() - 86400 }?.toMutableMap()
        ?: mutableMapOf()).also { items = it }

    fun key(dir: SharedRides.Direction, from: String, to: String, at: Double) = "${dir.name}|$from|$to|${(at / 60).toLong()}"

    fun get(c: Context, k: String, at: Double): List<Way>? {
        val e = load(c)[k] ?: return null
        val ttl = if (at - now() < 36 * 3600) 30 * 60 else 6 * 3600
        val age = now() - e.asked
        return if (age >= 0 && age < ttl) e.ways else null
    }

    fun put(c: Context, k: String, ways: List<Way>, at: Double) {
        val m = load(c)
        m[k] = Entry(ways, at, now())
        if (m.size > 200) m.entries.sortedBy { it.value.asked }.take(m.size - 200).forEach { m.remove(it.key) }
        try { file(c).writeText(FriendJson.encodeString(MapSerializer(String.serializer(), Entry.serializer()), m)) } catch (_: Exception) {}
    }
}

/** The compare screen's and meet halfway's questions to the planner (iOS `CompareModel`, `MeetModel`). */
object CompareAsk {
    data class Question(val dir: SharedRides.Direction, val from: String, val to: String, val at: Double, val bound: Double)

    fun place(s: TripCard.Spot): String? = s.id?.takeIf { it.isNotEmpty() } ?: s.point?.let { "${it.lat},${it.lon}" }

    fun question(pd: PersonDay, a: TimetableArea, dir: SharedRides.Direction, by: Double? = null): Question? {
        val s = place(a.start ?: return null) ?: return null
        val sch = place(a.school) ?: return null
        return when (dir) {
            SharedRides.Direction.TO_SCHOOL -> {
                val bound = by ?: pd.first?.let { it - a.earlyMinutes * 60 } ?: return null
                Question(dir, s, sch, bound, bound)
            }
            SharedRides.Direction.HOME -> { val e = pd.lastEnd ?: return null; Question(dir, sch, s, e + 5 * 60, e) }
        }
    }

    fun leg(r: nl.haltewekker.data.Ride) = WayLeg(r.tripId, if (r.isTrain) "train" else "bus", r.line, r.num.ifEmpty { null },
        r.name.takeIf { it.isNotEmpty() && it != r.line }, r.headsign.ifEmpty { null },
        TripCard.Spot(r.fromStop, r.fromId.takeIf { it.isNotEmpty() && !it.contains(",") }, r.fromLat, r.fromLon),
        TripCard.Spot(r.toStop, null, r.toLat, r.toLon), r.departure, r.arrival, r.platform, r.walkBefore.takeIf { it > 0 })

    suspend fun ask(c: Context, q: Question, budget: RequestBudget): List<Way>? {
        val k = WayCache.key(q.dir, q.from, q.to, q.at)
        WayCache.get(c, k, q.at)?.let { return it }
        if (!budget.take()) return null
        val trips = Transit.plan(q.from, q.to, q.at, count = 5, maxTransfers = 3, arriveBy = q.dir == SharedRides.Direction.TO_SCHOOL)
        if (trips.isEmpty()) return null
        val ways = trips.map { t -> Way(t.rides.map(::leg), t.start, t.end) }
        WayCache.put(c, k, ways, q.at)
        return ways
    }

    data class DayRides(val school: List<SharedRide>, val home: List<SharedRide>, val partial: Boolean)

    suspend fun rides(c: Context, people: List<ComparePerson>, day: CompareDay, budget: RequestBudget): DayRides {
        var partial = false
        val now = System.currentTimeMillis() / 1000.0
        suspend fun ways(dir: SharedRides.Direction): List<PersonWays> {
            val out = mutableListOf<PersonWays>()
            for (pd in day.atSchool) {
                val a = people.firstOrNull { it.id == pd.id }?.area ?: continue
                val q = question(pd, a, dir) ?: continue
                if (dir == SharedRides.Direction.TO_SCHOOL && q.at < now + 5 * 60) continue
                if (dir == SharedRides.Direction.HOME && q.at + 3600 < now) continue
                val got = ask(c, q, budget)
                if (got != null) out.add(PersonWays(pd.id, got, q.bound)) else partial = true
            }
            return out
        }
        val s = ways(SharedRides.Direction.TO_SCHOOL)
        val h = ways(SharedRides.Direction.HOME)
        return DayRides(SharedRides.shown(SharedRides.match(s, SharedRides.Direction.TO_SCHOOL)), SharedRides.shown(SharedRides.match(h, SharedRides.Direction.HOME)), partial)
    }

    data class Meet(val plans: List<MeetPlan>, val note: String?, val bounds: Map<String, Double>, val schools: Map<String, TripCard.Spot>)

    /** Meet halfway: everyone's ways, the shared rides, then the others onto the best two (at most 12 questions). */
    suspend fun meet(c: Context, people: List<ComparePerson>, day: CompareDay, by: Double?): Meet {
        val budget = RequestBudget(RequestBudget.MEET)
        val mine = mutableListOf<PersonWays>()
        val starts = HashMap<String, nl.haltewekker.core.GeoPoint>(); val dests = HashMap<String, nl.haltewekker.core.GeoPoint>()
        val startSpots = HashMap<String, TripCard.Spot>(); val bounds = HashMap<String, Double>(); val schools = HashMap<String, TripCard.Spot>()
        val left = mutableListOf<String>()
        for (p in people) {
            val a = p.area; val st = a?.start; val sp = st?.point; val dp = a?.school?.point
            if (a == null || st == null || sp == null || dp == null) { left.add(p.id); continue }
            val pd = day.person(p.id) ?: PersonDay(p.id, false, emptyList())
            val q = question(pd, a, SharedRides.Direction.TO_SCHOOL, by) ?: run { left.add(p.id); null } ?: continue
            starts[p.id] = sp; dests[p.id] = dp; startSpots[p.id] = st; bounds[p.id] = q.bound; schools[p.id] = a.school
            ask(c, q, budget)?.let { mine.add(PersonWays(p.id, it, q.bound)) }
        }
        val found = MeetHalfway.plans(mine).toMutableList()
        if (found.isEmpty()) for (p in mine.take(2)) seed(p, mine.map { it.id })?.let { found.add(it) }
        val better = mutableListOf<MeetPlan>()
        for (first in found.take(2)) {
            var plan = first
            if (plan.missing.isEmpty() || !budget.take()) { better.add(plan); continue }
            val live = Transit.trip(plan.ride.trip, 300.0)
            val template = plan.ride.riders.firstNotNullOfOrNull { r -> plan.ways[r.id]?.legs?.getOrNull(r.leg)?.takeIf { it.trip == plan.ride.trip } }
            if (live == null || template == null) { better.add(plan); continue }
            val route = live.stops.map { RouteStop(it.name, null, it.point, it.departure, it.arrival ?: it.departure) }
            for (m in plan.missing) {
                val st = starts[m] ?: continue; val ds = dests[m] ?: continue; val bound = bounds[m] ?: continue; val from = startSpots[m] ?: continue
                val own = mine.firstOrNull { it.id == m }?.ways ?: emptyList()
                for (j in MeetHalfway.joins(route, plan.ride, st, ds, bound, own, System.currentTimeMillis() / 1000.0)) {
                    var before: Way? = null
                    if (Geo.metres(st, route[j.board].point) > MeetHalfway.WALK_TO) {
                        val dep = route[j.board].dep ?: continue
                        val fromId = place(from) ?: continue
                        if (!budget.take()) continue
                        val trips = Transit.plan(fromId, "${route[j.board].point.lat},${route[j.board].point.lon}", dep - MeetHalfway.BOARD_MARGIN, count = 3, maxTransfers = 3, arriveBy = true)
                        before = trips.map { t -> Way(t.rides.map(::leg), t.start, t.end) }.filter { it.end <= dep - 60 }.maxByOrNull { it.start } ?: continue
                    }
                    val w = MeetHalfway.joined(j, template, route, st, before, bound) ?: continue
                    plan = MeetHalfway.adding(plan, m, w, plan.ride.trip)
                    break
                }
            }
            better.add(plan)
        }
        val all = (better + found.drop(minOf(2, found.size))).filter { it.ride.riders.size >= 2 }
        val plans = MeetHalfway.rank(all, bounds).take(4)
        val note = when {
            plans.isEmpty() && left.size == people.size -> "Nobody here has shared a start area yet."
            plans.isEmpty() -> "No bus or train found that two of you can be on in time."
            left.isEmpty() -> null
            else -> if (left.size == 1) "1 person hasn’t shared where they start yet." else "${left.size} people haven’t shared where they start yet."
        }
        return Meet(plans, note, bounds, schools)
    }

    private fun seed(p: PersonWays, all: List<String>): MeetPlan? {
        val wi = SharedRides.usable(p, SharedRides.Direction.TO_SCHOOL).maxByOrNull { p.ways[it].start } ?: return null
        val w = p.ways[wi]
        val li = w.legs.indices.maxByOrNull { w.legs[it].arr - w.legs[it].dep } ?: return null
        val l = w.legs[li]
        val ride = SharedRide(l.trip, l.mode, l.line, l.num, listOf(Rider(p.id, wi, li, l.from, l.dep, l.to, l.arr)))
        return MeetPlan(MeetPlan.Kind.SameRide, ride, mapOf(p.id to w), all.filter { it != p.id })
    }
}

/** Compare timetables: you and a friend, or a whole group; this week and next; rides together, free time, meet halfway. */
@Composable
fun CompareScreen(key: String, back: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val me = FriendStore.myAccount ?: ""
    var people by remember { mutableStateOf<List<ComparePerson>>(emptyList()) }
    var days by remember { mutableStateOf<List<CompareDay>>(emptyList()) }
    val rides = remember { mutableStateMapOf<String, CompareAsk.DayRides>() }
    val loading = remember { mutableStateMapOf<String, Boolean>() }
    var open by remember { mutableStateOf<String?>(null) }
    var meet by remember { mutableStateOf<CompareAsk.Meet?>(null) }
    var meeting by remember { mutableStateOf(false) }
    val budget = remember { RequestBudget(RequestBudget.COMPARE) }
    fun name(id: String) = if (id == me) "you" else people.firstOrNull { it.id == id }?.name ?: FriendStore.name(id)
    fun load(k: String) {
        val d = days.firstOrNull { it.key == k } ?: return
        if (loading[k] == true || rides[k] != null) return
        loading[k] = true
        scope.launch { rides[k] = CompareAsk.rides(context, people, d, budget); loading[k] = false }
    }
    LaunchedEffect(key) {
        val (mine, area) = FriendTimetables.readMine(context, sharing = false)
        val list = mutableListOf(ComparePerson(me, "You", true, mine, area))
        val gid = ChatKey.groupId(key)
        val others = if (gid != null) FriendStore.group(gid)?.others(me)?.map { it.id } ?: emptyList() else listOf(key)
        for (id in others) list.add(ComparePerson(id, FriendStore.name(id), timetable = FriendTimetables.timetable(id), area = FriendTimetables.area(id)))
        people = list
        days = Compare.days(list, System.currentTimeMillis() / 1000.0)
        Compare.nextShared(days, System.currentTimeMillis() / 1000.0)?.let { open = it; load(it) }
    }
    FriendsPage {
        FriendsTop("Compare timetables", back)
        if (people.isEmpty()) { CircularProgressIndicator(); return@FriendsPage }
        val shared = people.filter { it.timetable != null }
        Text("Shared: " + CompareWords.names(shared.map { name(it.id) }.ifEmpty { listOf("nobody yet") }) +
            if (people.any { it.timetable == null }) " · not yet: " + CompareWords.names(people.filter { it.timetable == null }.map { name(it.id) }) else "",
            color = DS.t.secondary)
        if (people.first().timetable == null) Note("Your own timetable isn’t set up (Settings › School alarm): friends see only theirs here.")
        days.forEach { d ->
            Card {
                Row(Modifier.fillMaxWidth().clickable { open = if (open == d.key) null else d.key; if (open == d.key) load(d.key) }, verticalAlignment = Alignment.CenterVertically) {
                    Text(TimetableDays.short(d.key), fontWeight = FontWeight.Bold, color = DS.t.text, modifier = Modifier.weight(1f))
                    if (d.shared) Text("${d.atSchool.size} at school", color = DS.t.accentText, style = MaterialTheme.typography.bodySmall)
                }
                d.people.forEach { p -> Text("${name(p.id).replaceFirstChar { it.uppercase() }}: ${CompareWords.day(p)}", color = DS.t.text, style = MaterialTheme.typography.bodySmall) }
                Compare.freeTogether(d).forEach { Text(CompareWords.free(it, ::name), color = DS.t.accentText, style = MaterialTheme.typography.bodySmall) }
                if (open == d.key) {
                    if (loading[d.key] == true) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    rides[d.key]?.let { r ->
                        RideBlock("To school", r.school, d, SharedRides.Direction.TO_SCHOOL, people, ::name)
                        RideBlock("Home", r.home, d, SharedRides.Direction.HOME, people, ::name)
                        if (r.partial) Text("Some ways couldn’t be looked up right now.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                    }
                    d.people.forEach { p -> if (p.hasSchool) p.classes.forEach { c -> Text("${name(p.id)}: ${CompareWords.lesson(c)}", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) } }
                    if (d.atSchool.size >= 2) QuietButton(if (meeting) "Looking…" else "Meet halfway") {
                        if (!meeting) { meeting = true; scope.launch { meet = CompareAsk.meet(context, people.filter { pp -> d.person(pp.id)?.hasSchool == true }, d, null); meeting = false } }
                    }
                }
            }
        }
        meet?.let { m ->
            Card {
                Header("Meet halfway")
                m.note?.let { Text(it, color = DS.t.secondary) }
                m.plans.forEach { p ->
                    Text(MeetWords.title(p), fontWeight = FontWeight.SemiBold, color = DS.t.text)
                    p.ways.forEach { (id, w) -> Text("${name(id).replaceFirstChar { it.uppercase() }}: ${MeetWords.way(w)}", color = DS.t.text, style = MaterialTheme.typography.bodySmall) }
                    if (p.missing.isNotEmpty()) Text("Not on it: " + CompareWords.names(p.missing.map(::name)), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                    var send by remember(p.id) { mutableStateOf(false) }
                    QuietButton("Send to " + if (ChatKey.isGroup(key)) "the group" else name(key)) { send = true }
                    if (send) {
                        // a friend's chat: their own way, by their bound; a group: your own way
                        val who = if (ChatKey.isGroup(key)) me else key
                        val w = p.ways[who] ?: p.ways[me] ?: p.ways.values.first()
                        val to = m.schools[who] ?: TripCard.Spot("School")
                        val card = MeetHalfway.card(w, to, m.bounds[who], MeetWords.note(p, ::name, me))
                        SendTripDialog(card, setOf(key)) { send = false }
                    }
                }
            }
        }
        Text("Rides are looked up when you open a day (at most ${RequestBudget.COMPARE} questions to the planner while this is open).", color = DS.t.secondary,
            style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun RideBlock(title: String, list: List<SharedRide>, d: CompareDay, dir: SharedRides.Direction, people: List<ComparePerson>, name: (String) -> String) {
    Text(title, fontWeight = FontWeight.SemiBold, color = DS.t.text)
    if (list.isEmpty()) Text("No ride in common.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
    list.forEach { r ->
        Text(RideWords.headline(r), color = DS.t.text)
        Text("With " + RideWords.riders(r, name), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        d.people.filter { it.id !in r.ids }.forEach { p ->
            Text(RideWords.missing(p, dir, name(p.id).replaceFirstChar { it.uppercase() }, people.firstOrNull { it.id == p.id }?.area != null),
                color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
    }
}

