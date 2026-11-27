package nl.haltewekker.friends

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.ride.SavedRide
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sign

// Live link payload v2 (relay 2026-11-27), the iOS `LiveTripV2.swift`: the whole trip for the live page, built from plain
// values so it's tested without the ride, byte for byte against docs/live-link-vectors.json (the same vector the page's
// own script and iOS check). Inside the same lock as v1 (LiveCrypto); every v1 field is still there for a page before it.
// Also here: the messages a link's viewers send the sharer, the sharer's answers, and whose name a link carries.

/** One leg of the trip: a ride ("bus", "train", "tram", "metro", "ferry") or a walk ("walk", with `mins`). */
@Serializable
data class LiveLeg(
    val mode: String,
    val line: String? = null,
    val num: String? = null,
    /** The line's colour, "RRGGBB" (none for a walk). */
    val color: String? = null,
    val from: String,
    val to: String,
    val dep: Long? = null,
    val arr: Long? = null,
    val depPlatform: String? = null,
    val arrPlatform: String? = null,
    /** The coach and deck you shared for this train (only then). */
    val coach: Int? = null,
    val deck: String? = null,
    val late: Int? = null,
    val mins: Int? = null,
    /** (0.10.7) This leg's own road, encoded as the state's `shape`: the next two rides' (≤ 80 points), else where it
     *  goes from and to (two points); the current ride's only when the state has no road or stops of its own. */
    val shape: String? = null,
)

/** A stop of the leg you're on (from where you got on to where you get off). */
@Serializable
data class LiveStop(val name: String, val lat: Double, val lon: Double, val t: Long? = null)

/** (reserved for "listening now") What you listen to: shown on the page when it's under 10 minutes old. */
@Serializable
data class LiveMusic(val title: String, val artist: String? = null, val app: String? = null, val url: String? = null,
                     val coverUrl: String? = null, val at: String)

object LiveTripV2 {
    const val MAX_LEGS = 12
    const val MAX_STOPS = 60
    const val MAX_SHAPE = 200
    /** A later leg's road at most (points), for the next this many rides. */
    const val MAX_LEG_SHAPE = 80
    const val LEG_ROADS = 2
    /** The whole state's JSON at most (bytes): over it the road goes, then the stops. */
    const val BUDGET = 12_000

    data class LegIn(
        val mode: String, val line: String? = null, val num: String? = null, val from: String, val to: String,
        val dep: Double? = null, val arr: Double? = null, val depPlatform: String? = null, val arrPlatform: String? = null,
        val coach: Int? = null, val deck: String? = null, val late: Int? = null, val mins: Int? = null,
        /** (0.10.7) Where it starts and ends, and its vehicle's whole road when saved (cut here to this leg). */
        val fromPt: GeoPoint? = null, val toPt: GeoPoint? = null, val road: List<GeoPoint> = emptyList(),
    )
    data class StopIn(val name: String, val lat: Double, val lon: Double, val t: Double? = null)
    data class Vehicle(val lat: Double, val lon: Double, val at: Double)
    data class Trip(
        val legs: List<LegIn>,
        val leg: Int,
        /** The current leg's stops, where you got on to where you get off. */
        val stops: List<StopIn> = emptyList(),
        /** The road its bus or train takes (all of it: cut here to your part). */
        val shape: List<GeoPoint> = emptyList(),
        /** The vehicle's own GPS (the open feeds), when there's a fresh fix. */
        val vehicle: Vehicle? = null,
        val face: String? = null,
        /** This app reads messages (the page shows its message box). */
        val inbox: Boolean = true,
        val music: LiveMusic? = null,
        /** (0.10.7) The version of your picture the relay has (`LiveFace`), when it has one. */
        val pic: Int? = null,
    )

    /** A name or place as sent: no control characters, single spaces, at most `max` characters. */
    fun clean(s: String?, max: Int): String {
        if (s == null) return ""
        return FriendNames.takeChars(FriendNames.cleanLine(s), max).trim()
    }

    /** In 1e-5 degrees, half away from zero (the same on every platform). */
    fun q(x: Double): Long = (sign(x) * floor(abs(x) * 1e5 + 0.5)).toLong()
    fun r5(x: Double): Double = q(x) / 1e5

    /** A line's colour by kind (the app's own: bus orange, intercity indigo, sprinter cyan, tram purple). */
    fun color(mode: String, line: String?): String? {
        val l = (line ?: "").trim().uppercase()
        return when (mode) {
            "walk" -> null
            "train" -> if (l.startsWith("SPR") || l.startsWith("SNG") || Regex("^S\\d").containsMatchIn(l)) "0A93B5" else "3B44B0"
            "tram", "metro" -> "7A55B0"
            "ferry" -> "2A7898"
            else -> "E0632E"
        }
    }

    // MARK: the road

    fun encode(pts: List<LongArray>): String {
        val out = StringBuilder()
        var pa = 0L
        var po = 0L
        fun e(v0: Long) {
            var v = if (v0 < 0) (v0 shl 1).inv() else v0 shl 1
            while (v >= 32) { out.append(((32L or (v and 31)) + 63).toInt().toChar()); v = v shr 5 }
            out.append((v + 63).toInt().toChar())
        }
        for (p in pts) { e(p[0] - pa); e(p[1] - po); pa = p[0]; po = p[1] }
        return out.toString()
    }

    private fun nearest(pts: List<LongArray>, p: LongArray, from: Int): Int {
        var best = from
        var bd = Long.MAX_VALUE
        for (i in from until pts.size) {
            val dy = pts[i][0] - p[0]
            val dx = pts[i][1] - p[1]
            val d = dy * dy + dx * dx
            if (d < bd) { bd = d; best = i }
        }
        return best
    }

    /** Douglas–Peucker in 1e-5 degrees, `tol` of them. */
    fun simplify(pts: List<LongArray>, tol: Long): List<LongArray> {
        if (pts.size < 3) return pts
        val keep = BooleanArray(pts.size)
        keep[0] = true; keep[pts.size - 1] = true
        val stack = ArrayDeque<Pair<Int, Int>>()
        stack.addLast(0 to pts.size - 1)
        val t2 = (tol * tol).toDouble()
        while (stack.isNotEmpty()) {
            val (a, b) = stack.removeLast()
            if (b - a < 2) continue
            val ay = pts[a][0]; val ax = pts[a][1]
            val dy = pts[b][0] - ay; val dx = pts[b][1] - ax
            val len2 = dx * dx + dy * dy
            var mi = -1
            var md = -1.0
            for (i in a + 1 until b) {
                val py = pts[i][0]; val px = pts[i][1]
                val d: Double = if (len2 == 0L) ((py - ay) * (py - ay) + (px - ax) * (px - ax)).toDouble()
                else { val c = (dx * (py - ay) - dy * (px - ax)).toDouble(); c * c / len2.toDouble() }
                if (d > md) { md = d; mi = i }
            }
            if (md > t2) { keep[mi] = true; stack.addLast(a to mi); stack.addLast(mi to b) }
        }
        return pts.filterIndexed { i, _ -> keep[i] }
    }

    /** Your part of the road (nearest the first and the last stop), at most `max` points, encoded; null: none. */
    fun road(shape: List<GeoPoint>, stops: List<StopIn>, max: Int = MAX_SHAPE): String? {
        var pts = shape.map { longArrayOf(q(it.lat), q(it.lon)) }
        val qs = stops.map { longArrayOf(q(it.lat), q(it.lon)) }
        if (pts.size < 2 || qs.size < 2) pts = qs
        else {
            val i0 = nearest(pts, qs[0], 0)
            val i1 = nearest(pts, qs[qs.size - 1], i0)
            pts = if (i1 > i0) pts.subList(i0, i1 + 1) else qs
        }
        val d = ArrayList<LongArray>()
        for (p in pts) if (d.isEmpty() || d.last()[0] != p[0] || d.last()[1] != p[1]) d.add(p)
        if (d.size < 2) return null
        var tol = 1L
        var r = simplify(d, tol)
        while (r.size > max) { tol *= 2; r = simplify(d, tol) }
        return encode(r)
    }

    private fun https(u: String?): String? = u?.takeIf { it.startsWith("https://") && it.length <= 500 }

    // MARK: the state

    /** v1's state (`LiveRules.state`) with the whole trip added: v 2. */
    fun build(base: LiveState, t: Trip, now: Double): LiveState {
        val legs = t.legs.take(MAX_LEGS).map { l ->
            val mode = clean(l.mode, 12).ifEmpty { "bus" }
            val line = clean(l.line, 20).takeIf { it.isNotEmpty() && mode != "walk" }
            LiveLeg(
                mode = mode, line = line, num = clean(l.num, 12).takeIf { it.isNotEmpty() && mode == "train" }, color = color(mode, line),
                from = clean(l.from, 40), to = clean(l.to, 40), dep = l.dep?.let { floor(it).toLong() }, arr = l.arr?.let { floor(it).toLong() },
                depPlatform = clean(l.depPlatform, 8).ifEmpty { null }, arrPlatform = clean(l.arrPlatform, 8).ifEmpty { null },
                coach = l.coach?.takeIf { it in 1..30 }, deck = l.deck?.takeIf { it == "upper" || it == "lower" },
                late = if (mode != "walk") l.late?.let { max(0, min(600, it)) } else null,
                mins = if (mode == "walk") l.mins?.let { max(0, min(120, it)) } else null,
            )
        }
        val src = if (t.stops.size > MAX_STOPS) t.stops.take(MAX_STOPS - 1) + t.stops.last() else t.stops
        val stops = src.map { LiveStop(clean(it.name, 40), r5(it.lat), r5(it.lon), it.t?.let { x -> floor(x).toLong() }) }
        val next = if (stops.isEmpty()) null else if (base.state == "waiting") 0
        else stops.indexOfFirst { it.t != null && it.t > now }.let { if (it < 0) stops.size - 1 else it }
        val pos = t.vehicle?.let { LiveState.Position(r5(it.lat), r5(it.lon), floor(it.at), "gps") } ?: base.pos?.copy(src = "phone")
        val music = t.music?.let { m ->
            val title = clean(m.title, 80)
            if (title.isEmpty()) null else LiveMusic(title, clean(m.artist, 60).ifEmpty { null }, clean(m.app, 20).ifEmpty { null }, https(m.url), https(m.coverUrl), m.at)
        }
        var s = base.copy(
            v = 2, legs = legs, leg = if (legs.isEmpty()) null else max(0, min(legs.size - 1, t.leg)),
            stops = stops.ifEmpty { null }, next = next, shape = road(t.shape, src), pos = pos,
            face = t.face?.takeIf { Regex("^[0-9A-Fa-f]{6}$").matches(it) }?.uppercase(), inbox = if (t.inbox) true else null, music = music,
            pic = t.pic?.takeIf { it >= 1 },
        )
        // (0.10.7) each leg's own road from the one before the current (a walk) on: the next two rides' in full
        val cur = s.leg ?: 0
        val own = s.shape != null || s.stops != null
        val straight = arrayOfNulls<String>(legs.size)
        val full = arrayOfNulls<String>(legs.size)
        var rides = 0
        for (i in legs.indices) {
            val l = t.legs[i]
            val walk = legs[i].mode == "walk"
            if (i < cur - 1 || (i == cur - 1 && !walk) || (i == cur && own)) continue
            val a = l.fromPt ?: continue
            val b = l.toPt ?: continue
            val ends = listOf(StopIn("", a.lat, a.lon), StopIn("", b.lat, b.lon))
            straight[i] = road(emptyList(), ends, 2)
            if (!walk && i >= cur) {
                if (rides < LEG_ROADS + (if (own) 0 else 1) && l.road.size >= 2) full[i] = road(l.road, ends, MAX_LEG_SHAPE)
                rides++
            }
        }
        fun withShapes(): LiveState = s.copy(legs = legs.mapIndexed { i, l -> l.copy(shape = full[i] ?: straight[i]) })
        if (legs.isNotEmpty()) s = withShapes()
        // over the budget: the farthest leg's road first, then the rest of the legs' roads, the road, the stops
        for (i in legs.indices.reversed()) {
            if (bytes(s) <= BUDGET) break
            if (full[i] != null) { full[i] = null; s = withShapes() }
        }
        if (bytes(s) > BUDGET && legs.isNotEmpty()) s = s.copy(legs = legs)
        if (bytes(s) > BUDGET) s = s.copy(shape = null)
        if (bytes(s) > BUDGET) s = s.copy(stops = null, next = null)
        return s
    }

    fun bytes(s: LiveState) = FriendJson.encode(LiveState.serializer(), s).size

    /**
     * The trip as the ride has it (`DoorTrip`, the leg it's on): its rides with the walks between them, the leg you're on
     * (its stops and road from the saved copy of its ride, cut to your part), the vehicle's fix, the coach you shared.
     */
    fun fromRide(
        trip: DoorTrip, index: Int, destination: String, legArrival: Double?, saved: SavedRide?, vehicle: Vehicle?,
        coach: Pair<String, TravelState.Coach>?, face: String?, now: Double, music: LiveMusic? = null,
        roads: (String) -> List<GeoPoint>? = { null }, pic: Int? = null,
    ): Trip {
        val legs = ArrayList<LegIn>()
        var cur = 0
        for ((k, r) in trip.rides.withIndex()) {
            if (k > 0 && r.walkBefore > 0) {
                val prev = trip.rides[k - 1]
                legs.add(LegIn("walk", from = prev.toStop, to = r.fromStop, dep = prev.arrival, arr = prev.arrival + r.walkBefore * 60, mins = r.walkBefore,
                    fromPt = prev.to, toPt = r.from))
            }
            if (k == index) cur = legs.size
            val mode = if (r.isTrain) "train" else r.mode.uppercase().let { m -> if (m.contains("TRAM")) "tram" else if (m.contains("SUBWAY") || m.contains("METRO")) "metro" else if (m.contains("FERRY")) "ferry" else "bus" }
            val c = coach?.takeIf { it.first == r.tripId && r.isTrain }?.second
            legs.add(LegIn(mode, line = if (r.isTrain) TransitLabel.train(r.line, r.name) else r.line, num = r.num.ifEmpty { null }, from = r.fromStop, to = r.toStop,
                dep = r.departure, arr = if (k == index) legArrival ?: r.arrival else r.arrival, depPlatform = r.platform ?: r.plannedPlatform,
                coach = c?.n, deck = c?.seat?.deck, late = if (r.live) r.delay else null,
                fromPt = r.from, toPt = r.to, road = if (k >= index) roads(r.tripId) ?: emptyList() else emptyList()))
        }
        val last = trip.rides.last()
        if (trip.walkAfter > 0) legs.add(LegIn("walk", from = last.toStop, to = destination.ifEmpty { last.toStop }, dep = last.arrival, arr = trip.end, mins = trip.walkAfter))
        var stops = emptyList<StopIn>()
        var shape = emptyList<GeoPoint>()
        val leg = trip.rides.getOrNull(index)
        if (saved != null && leg != null && saved.stops.size >= 2) {
            val all = saved.stops
            val a = leg.fromLat?.let { la -> leg.fromLon?.let { lo -> nl.haltewekker.ride.RideCache.stop(GeoPoint(la, lo), saved) } } ?: 0
            val b = leg.toLat?.let { la -> leg.toLon?.let { lo -> nl.haltewekker.ride.RideCache.stop(GeoPoint(la, lo), saved, after = a) } } ?: (all.size - 1)
            if (b > a) {
                stops = all.subList(a, b + 1).map { StopIn(it.name, it.lat, it.lon, it.arrival ?: it.departure) }
                shape = saved.shape
            }
        }
        return Trip(legs, cur, stops, shape, vehicle, face, true, music, pic)
    }

    /** A friends account's colour for its initial (the app's own: the same six, picked by the account). */
    fun face(account: String?): String {
        val colours = listOf("0E7A55", "3B44B0", "0A93B5", "E0632E", "6B3FA0", "1C6E8C")
        if (account.isNullOrEmpty()) return colours[0]
        var n = 0
        for (ch in account) n = (n * 31 + ch.code) and 0xFFFF
        return colours[n % colours.size]
    }
}

/** Whose name a live link carries: your Friends name, else the one you typed for live links; never anyone else's. */
object LiveNames {
    fun sender(friendsName: String?, typed: String?): String =
        FriendNames.clean(friendsName ?: "").ifEmpty { FriendNames.clean(typed ?: "") }
}

/**
 * A message to the sharer from someone with the link (relay 2026-11-27): the page sends `fromKind` "web" with the name they
 * typed (or none), an app "app" with its own name and, with a friends account, its account (`friendId`) so the sharer's app
 * shows that friend. Locked with the link's key, AAD "hw-live-msg-v1\n" + token.
 */
@Serializable
data class LiveMessage(val from: String = "", val fromKind: String = "web", val friendId: String? = null, val text: String, val at: Double)

/** The sharer's answer, which every page of the link shows; AAD "hw-live-reply-v1\n" + token. `re`: the message it answers. */
@Serializable
data class LiveReply(val text: String, val at: Double, val re: Int? = null)

object LiveMessages {
    const val MSG = "hw-live-msg-v1"
    const val REPLY = "hw-live-reply-v1"
    const val MAX_TEXT = 280
    val chips = listOf("👋 On my way", "I’m at the station", "Running late", "Call me")

    /** A message as read: text 1–280 characters (cleaned), a name ≤ 40, an account id of 32 hex characters or none. */
    fun valid(m: LiveMessage): LiveMessage? {
        val text = LiveTripV2.clean(m.text, MAX_TEXT)
        if (text.isEmpty()) return null
        val kind = if (m.fromKind == "app") "app" else "web"
        val id = m.friendId?.takeIf { kind == "app" && Regex("^[0-9a-f]{32}$").matches(it) }
        return LiveMessage(LiveTripV2.clean(m.from, 40), kind, id, text, floor(m.at))
    }

    fun seal(m: LiveMessage, key: ByteArray, token: String, nonce: ByteArray = FriendCrypto.randomBytes(12)): ByteArray =
        LiveCrypto.sealAs(MSG, FriendJson.encode(LiveMessage.serializer(), m), key, token, nonce)

    fun open(data: ByteArray, key: ByteArray, token: String): LiveMessage? = try {
        FriendJson.decode(LiveMessage.serializer(), LiveCrypto.openAs(MSG, data, key, token))?.let(::valid)
    } catch (_: Exception) { null }

    fun sealReply(r: LiveReply, key: ByteArray, token: String, nonce: ByteArray = FriendCrypto.randomBytes(12)): ByteArray =
        LiveCrypto.sealAs(REPLY, FriendJson.encode(LiveReply.serializer(), r), key, token, nonce)

    fun openReply(data: ByteArray, key: ByteArray, token: String): LiveReply? = try {
        FriendJson.decode(LiveReply.serializer(), LiveCrypto.openAs(REPLY, data, key, token))?.let { r ->
            LiveTripV2.clean(r.text, MAX_TEXT).takeIf { it.isNotEmpty() }?.let { LiveReply(it, floor(r.at), r.re) }
        }
    } catch (_: Exception) { null }

    /** Who it's from as the sharer's app shows it: the friend (by account), the name they gave, or "Someone with your link". */
    fun sender(m: LiveMessage, friendName: (String) -> String?): String =
        m.friendId?.let(friendName) ?: m.from.ifEmpty { "Someone with your link" }

    /** "💬 Kim: On my way" */
    fun notice(m: LiveMessage, friendName: (String) -> String?) = "💬 " + sender(m, friendName) + ": " + m.text

    /** The relay's inbox answer: (seq, at, data) each. */
    fun inbox(o: JsonObject?): List<Triple<Int, Double, String>> {
        val list = o?.get("msgs") as? kotlinx.serialization.json.JsonArray ?: return emptyList()
        return list.mapNotNull { e ->
            val x = e as? JsonObject ?: return@mapNotNull null
            val seq = (x["seq"] as? JsonPrimitive)?.content?.toIntOrNull() ?: return@mapNotNull null
            val at = (x["at"] as? JsonPrimitive)?.content?.toDoubleOrNull() ?: 0.0
            val data = (x["data"] as? JsonPrimitive)?.content ?: return@mapNotNull null
            Triple(seq, at, data)
        }
    }
}

/**
 * (0.10.7) Your Friends picture on a live link's page: 128 px, a JPEG of at most 12 KB, locked with the link's key under
 * its own AAD ("hw-live-face-v1\n" + token) and put once at `/live/v1/face` (again when the picture changes); the state's
 * `pic` says which one the relay has, so the page fetches it once. No picture: nothing is put.
 */
object LiveFace {
    const val KIND = "hw-live-face-v1"
    const val SIDE = 128
    const val MAX_BYTES = 12 * 1024
    /** A put that failed is tried again after this long (s). */
    const val RETRY = 60.0

    fun seal(jpeg: ByteArray, key: ByteArray, token: String, nonce: ByteArray = FriendCrypto.randomBytes(12)): ByteArray =
        LiveCrypto.sealAs(KIND, jpeg, key, token, nonce)

    fun open(data: ByteArray, key: ByteArray, token: String): ByteArray = LiveCrypto.openAs(KIND, data, key, token)

    /** Which picture it is (the first 16 bytes of its SHA-256, hex); "" for none. */
    fun stamp(picture: ByteArray?): String =
        if (picture == null || picture.isEmpty()) "" else java.security.MessageDigest.getInstance("SHA-256").digest(picture).take(16).joinToString("") { "%02x".format(it) }

    /** Put it now: there is one, the relay doesn't have this one, and the last try isn't too recent. */
    fun due(stamp: String, sent: String, lastTry: Double?, now: Double): Boolean =
        stamp.isNotEmpty() && stamp != sent && (lastTry == null || now - lastTry >= RETRY)
}
