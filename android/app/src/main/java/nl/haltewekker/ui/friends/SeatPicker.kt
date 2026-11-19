package nl.haltewekker.ui.friends

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import nl.haltewekker.data.VehicleKind
import nl.haltewekker.friends.CoachMap
import nl.haltewekker.friends.FriendStore
import nl.haltewekker.friends.FriendTravelShare
import nl.haltewekker.friends.NSTrains
import nl.haltewekker.friends.SeatMap
import nl.haltewekker.friends.TrainDrawing
import nl.haltewekker.friends.TravelState
import nl.haltewekker.ui.theme.DS

// Friends (A5, iOS 0.31 `SeatPicker.swift`): the seat picker. On top the whole train, its first and last coach shaped
// like the noses, numbered from the front, "Driving to Breda →"; tap a coach and it opens below, seen from the side as
// from the platform: doors, windows, wheels and the line's colour stripe. A double-deck coach has two rows of windows
// (the top row the upper deck, the bottom row the lower), a single-deck one a row. Tap your window: that's your seat. A
// friend's face sits in their window. The sums are in SeatMap.kt. The same picker on the ride screen (yours to set) and
// on a friend's page (theirs to see; yours too when you take that train).

/** Someone shown in the picker: a friend (their face in their window). */
data class SeatMark(val id: String, val name: String, val coach: TravelState.Coach)

private data class SeatColours(val shell: Color, val glass: Color, val door: Color)

@Composable
private fun seatColours(): SeatColours = if (isSystemInDarkTheme())
    SeatColours(Color(0xFFD3D8DD), Color(0xFF2B3640), Color(0xFF8B949D)) else SeatColours(Color(0xFFE6E9EC), Color(0xFF33404D), Color(0xFF9AA3AC))

/** The line's colour ("IC" indigo, "SPR" cyan). */
@Composable
fun trainColour(line: String?): Color = DS.t.kind(VehicleKind.of("", line ?: "", true))

/**
 * The train and its coaches, and the windows of the one you tapped. `station`: the NS station whose drawing it uses;
 * `editable`: you may set your own seat here (you're on this train, or a leg of yours takes it); `coaches`: without NS's
 * drawing, the coaches to draw (a friend's "of"; 0: NS's length or 6).
 */
@Composable
fun TrainSeatPicker(tripId: String, num: String?, station: String?, line: String?, towards: String?, friends: List<SeatMark> = emptyList(),
                    editable: Boolean = true, coaches: Int = 0) {
    val context = LocalContext.current
    val coach by FriendTravelShare.coach.collectAsState()
    val coachTrip by FriendTravelShare.coachTrip.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    var drawing by remember(tripId, station) { mutableStateOf<TrainDrawing?>(null) }
    var loaded by remember(tripId, station) { mutableStateOf(false) }
    var open by remember(tripId) { mutableStateOf<Int?>(null) }
    val mine = if (coachTrip == tripId) coach else null
    val colour = trainColour(line)
    val d = drawing
    val cars = if ((d?.cars ?: 0) > 0) d!!.cars else coaches
    val t = SeatMap.train(d?.units ?: emptyList(), d?.kinds ?: emptyList(), if (cars > 0) cars else coaches, d?.dir, line)

    fun drawn(c: TravelState.Coach): Int? {
        CoachMap.drawn(c, t.count, t.dir, station)?.let { return it }
        // the picker's own guess (front on the right) for a coach counted from the front
        if (!t.fromNS && c.front && c.n >= 1 && c.n <= t.count) return t.count - c.n
        return null
    }

    LaunchedEffect(tripId, station) {
        loaded = false
        try {
            if (station != null) {
                val n = num?.takeIf { it.isNotEmpty() } ?: FriendTravelShare.number(tripId)
                if (!n.isNullOrEmpty()) drawing = NSTrains.drawing(n, station)
            }
        } finally {
            loaded = true
            if (open == null) {
                val tt = SeatMap.train(drawing?.units ?: emptyList(), drawing?.kinds ?: emptyList(),
                    ((drawing?.cars ?: 0).takeIf { it > 0 } ?: coaches).let { if (it > 0) it else coaches }, drawing?.dir, line)
                fun dr(c: TravelState.Coach) = CoachMap.drawn(c, tt.count, tt.dir, station)
                    ?: if (!tt.fromNS && c.front && c.n in 1..tt.count) tt.count - c.n else null
                open = friends.firstOrNull()?.let { dr(it.coach) } ?: mine?.let { dr(it) }
            }
        }
    }

    fun value(c: SeatMap.Coach, seat: TravelState.Seat?) = TravelState.Coach(c.n, t.count, c.front, station, seat)
    fun tapCoach(c: SeatMap.Coach) {
        open = c.drawn
        if (!editable) return
        // your coach (keeping your window when it's the same one)
        if (mine != null && drawn(mine) == c.drawn) return
        FriendTravelShare.setCoach(context, value(c, null), tripId)
    }
    fun tapWindow(w: Int, row: Int, c: SeatMap.Coach) {
        if (!editable) return
        val seat = SeatMap.seat(w, row, c.double, t.dir)
        // the same window again: the window goes, the coach stays
        val same = mine != null && drawn(mine) == c.drawn && mine.seat == seat
        FriendTravelShare.setCoach(context, value(c, if (same) null else seat), tripId)
    }

    val marked = HashMap<Int, MutableList<String>>()
    for (f in friends) drawn(f.coach)?.let { marked.getOrPut(it) { mutableListOf() }.add(f.id) }
    mine?.let { m -> drawn(m)?.let { marked.getOrPut(it) { mutableListOf() }.add("me") } }

    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(DS.t.surface2).padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        // header: "Double-deck IC · from the platform" · "Driving to Breda →"
        val what = if (t.anyDouble) "Double-deck ${line ?: "train"}" else (line?.let { if (it == "SPR") "Sprinter" else it } ?: "Train")
        val to = towards?.let { name -> when (t.dir) { "left" -> "← Driving to $name"; "right" -> "Driving to $name →"; else -> "Towards $name" } }
            ?: when (t.dir) { "left" -> "← Front"; "right" -> "Front →"; else -> "" }
        val spokenHeader = if (t.dir == null) "$what. Which way it goes isn’t known." else "$what, ${to.replace("→", "").replace("←", "").trim()}"
        Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = spokenHeader }, verticalAlignment = Alignment.CenterVertically) {
            Text("$what · from the platform", color = DS.t.secondary, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f))
            Text(to, color = DS.t.accentText, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
        }
        if (!loaded) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            Text("Getting the train from NS…", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        TrainStrip(t, colour, open, marked) { tapCoach(it) }
        val o = open
        val oc = o?.let { x -> t.coaches.firstOrNull { it.drawn == x } }
        if (oc != null) {
            val people = friends.mapNotNull { f ->
                if (drawn(f.coach) != oc.drawn) return@mapNotNull null
                val s = SeatMap.valid(f.coach.seat) ?: return@mapNotNull null
                val w = SeatMap.drawnWindow(s, t.dir) ?: return@mapNotNull null
                SidePerson(f.id, f.name, pictures[f.id], w, SeatMap.row(s, oc.double))
            }
            val my = mine?.takeIf { drawn(it) == oc.drawn }?.seat?.let { SeatMap.valid(it) }?.let { s ->
                SeatMap.drawnWindow(s, t.dir)?.let { it to SeatMap.row(s, oc.double) }
            }
            CoachSideView(oc, t, colour, people, my, editable) { w, r -> tapWindow(w, r, oc) }
        }
        // footer
        val note = when {
            oc == null -> if (editable) "Tap a coach, then your window" else "Tap a coach to look inside"
            oc.double -> if (editable) "Top row: upper deck · bottom: lower · tap your window" else "Top row: upper deck · bottom: lower"
            else -> if (editable) "Tap your window" else "Seen from the platform"
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(note, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
            if (editable && mine != null) TextButton(onClick = { FriendTravelShare.setCoach(context, null, tripId) },
                modifier = Modifier.semantics { stateDescription = "Friends no longer see your coach" }) {
                Text("Take it away", color = DS.t.accentText, fontWeight = FontWeight.SemiBold)
            }
        }
        if (!t.fromNS && loaded) Text("NS hasn’t said how this train is made up: this is a guess (${t.count} coaches).", color = DS.t.secondary,
            style = MaterialTheme.typography.bodySmall)
    }
}

// MARK: the whole train

/** The coaches in a row, the first and last shaped like noses, each a button with its number under it. */
@Composable
private fun TrainStrip(t: SeatMap.Train, colour: Color, open: Int?, marked: Map<Int, List<String>>, tap: (SeatMap.Coach) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
        .semantics { contentDescription = if (t.dir == null) "The train’s coaches" else "The train’s coaches, numbered from the front" },
        horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        t.coaches.forEach { c ->
            val isOpen = open == c.drawn
            val who = marked[c.drawn] ?: emptyList()
            val spoken = SeatMap.spokenCoach(c, t.count) + (if ("me" in who) ", your coach" else "") + (if (who.any { it != "me" }) ", a friend is here" else "")
            val fill = if (isOpen) colour else DS.t.legQuiet.copy(alpha = 0.45f)
            val ink = if (isOpen) Color.White.copy(alpha = 0.85f) else DS.t.secondary.copy(alpha = 0.7f)
            val accent = DS.t.accent
            val warn = DS.t.warning
            Column(Modifier.heightIn(min = DS.hit).clip(RoundedCornerShape(8.dp)).clickable(onClickLabel = "Shows its windows") { tap(c) }
                .semantics(mergeDescendants = true) { contentDescription = spoken; selected = isOpen; role = Role.Button }
                .padding(vertical = 3.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Box {
                    Canvas(Modifier.size(50.dp, if (c.double) 30.dp else 24.dp)) {
                        val nose = 13.dp.toPx(); val plain = 5.dp.toPx(); val foot = 6.dp.toPx()
                        val first = c.drawn == 0; val last = c.drawn == t.count - 1
                        val p = Path().apply {
                            addRoundRect(RoundRect(0f, 0f, size.width, size.height,
                                topLeftCornerRadius = CornerRadius(if (first) nose else plain), topRightCornerRadius = CornerRadius(if (last) nose else plain),
                                bottomRightCornerRadius = CornerRadius(if (last) foot else plain), bottomLeftCornerRadius = CornerRadius(if (first) foot else plain)))
                        }
                        drawPath(p, fill)
                        if (isOpen) drawPath(p, accent, style = Stroke(2.dp.toPx()))
                        // a line of windows per deck
                        val pad = 7.dp.toPx(); val h = 3.dp.toPx()
                        val rows = if (c.double) 2 else 1
                        val gap = 4.dp.toPx()
                        val top = (size.height - (rows * h + (rows - 1) * gap)) / 2
                        for (r in 0 until rows) drawRoundRect(ink, Offset(pad, top + r * (h + gap)), Size(size.width - 2 * pad, h), CornerRadius(h / 2))
                    }
                    if (who.isNotEmpty()) Box(Modifier.align(Alignment.TopCenter).offset(y = (-4).dp).size(8.dp).clip(CircleShape)
                        .background(if ("me" in who) accent else warn))
                }
                Text("${c.n}", color = if (isOpen) DS.t.accentText else DS.t.secondary, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold)
            }
        }
    }
}

// MARK: one coach from the side

private data class SidePerson(val id: String, val name: String, val picture: ByteArray?, val window: Int, val row: Int)

/** The coach you tapped, as from the platform: doors at both ends, 11 windows a row (two rows on a double-deck coach), the line's stripe, the wheels. */
@Composable
private fun CoachSideView(coach: SeatMap.Coach, t: SeatMap.Train, colour: Color, people: List<SidePerson>, mine: Pair<Int, Int>?, editable: Boolean,
                          tap: (Int, Int) -> Unit) {
    val k = seatColours()
    val rows = if (coach.double) 2 else 1
    val quiet = DS.t.legQuiet
    val wheelFill = DS.t.surface3
    Column(Modifier.fillMaxWidth().semantics { contentDescription = SeatMap.spokenCoach(coach, t.count) }) {
        Box(Modifier.fillMaxWidth().height(if (coach.double) 104.dp else 72.dp).clip(RoundedCornerShape(14.dp)).background(k.shell)) {
            Column(Modifier.fillMaxSize()) {
                Row(Modifier.fillMaxWidth().weight(1f).padding(start = 8.dp, end = 8.dp, top = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(Modifier.width(12.dp).fillMaxHeight().padding(vertical = 2.dp).clip(RoundedCornerShape(3.dp)).background(k.door))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        for (r in 0 until rows) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                            for (i in 0 until SeatMap.WINDOWS) {
                                val here = people.firstOrNull { it.window == i && it.row == r }
                                val isMine = mine?.first == i && mine.second == r
                                val w = SeatMap.window(i, dir = t.dir)
                                val deck = if (coach.double) (if (r == 0) SeatMap.Deck.UPPER else SeatMap.Deck.LOWER) else SeatMap.Deck.NONE
                                var spoken = SeatMap.spoken(coach.n, deck, w, coach.front)
                                if (here != null) spoken += ", ${here.name} sits here"
                                if (isMine) spoken += ", your seat"
                                val base = Modifier.weight(1f).height(30.dp).clip(RoundedCornerShape(4.dp)).background(if (isMine) DS.t.accent else k.glass)
                                val m = if (editable) base.clickable(onClickLabel = if (isMine) "Takes your window away" else "Marks it as your seat") { tap(i, r) }
                                    .semantics { contentDescription = spoken; selected = isMine; role = Role.Button }
                                    else base.semantics { contentDescription = spoken }
                                Box(m, contentAlignment = Alignment.Center) {
                                    if (here != null) Box(Modifier.size(20.dp).border(1.dp, Color.White, CircleShape).padding(1.dp)) { Avatar(here.name, here.picture, 18.dp) }
                                }
                            }
                        }
                    }
                    Box(Modifier.width(12.dp).fillMaxHeight().padding(vertical = 2.dp).clip(RoundedCornerShape(3.dp)).background(k.door))
                }
                Box(Modifier.fillMaxWidth().padding(start = 2.dp, end = 2.dp, top = 6.dp).height(5.dp).background(colour))
                Spacer(Modifier.height(8.dp))
            }
        }
        // the wheels
        Canvas(Modifier.fillMaxWidth().height(14.dp).offset(y = (-6).dp)) {
            val r = 7.dp.toPx(); val inset = 26.dp.toPx(); val step = 18.dp.toPx()
            for (x in listOf(inset + r, inset + r + step, size.width - inset - r - step, size.width - inset - r)) {
                drawCircle(wheelFill, r, Offset(x, size.height / 2))
                drawCircle(quiet, r - 1.dp.toPx(), Offset(x, size.height / 2), style = Stroke(2.dp.toPx()))
            }
        }
    }
}

/** A friend's coach in words: "Sam is in coach 3 of 6 · upper deck · 8th window from the back", and where to wait on the same train. */
@Composable
fun FriendCoachNote(coach: TravelState.Coach, state: TravelState, name: String) {
    val context = LocalContext.current
    var hint by remember(state.trip, coach) { mutableStateOf<String?>(null) }
    LaunchedEffect(state.trip, coach) {
        val id = state.trip ?: return@LaunchedEffect
        val code = FriendTravelShare.boarding(context, id) ?: return@LaunchedEffect
        val num = state.num ?: FriendTravelShare.number(id) ?: return@LaunchedEffect
        val d = NSTrains.drawing(num, code) ?: return@LaunchedEffect
        hint = CoachMap.platformHint(coach, d.units, d.cars, d.letters, d.dir, code)?.let { "Taking this train too? $it." }
    }
    val label = SeatMap.label(coach)
    Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("$name is in ${label.take(1).lowercase() + label.drop(1)}", color = DS.t.text, fontWeight = FontWeight.SemiBold)
        val h = hint
        if (h != null) Text(h, color = DS.t.accentText, style = MaterialTheme.typography.bodyMedium)
        else if (coach.front) Text("Taking this train too? Coach ${coach.n} from the front.", color = DS.t.secondary, style = MaterialTheme.typography.bodyMedium)
    }
}
