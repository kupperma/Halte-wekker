package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.friends.Compare
import nl.haltewekker.friends.CompareDay
import nl.haltewekker.friends.ComparePerson
import nl.haltewekker.friends.CompareWords
import nl.haltewekker.friends.FreeSlot
import nl.haltewekker.friends.MeetHalfway
import nl.haltewekker.friends.MeetJoin
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
import nl.haltewekker.friends.TimetableClass
import nl.haltewekker.friends.TimetableDays
import nl.haltewekker.friends.TimetableShare
import nl.haltewekker.friends.TripCard
import nl.haltewekker.friends.TripTake
import nl.haltewekker.friends.Way
import nl.haltewekker.friends.WayLeg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The iOS FriendCompareTests, and the spec's worked example (As built 0.28): Monday 18 January 2027. */
class FriendCompareTest {
    private val t0 = 1_800_000_000.0           // Friday 15 January 2027, 09:00 in Amsterdam
    private val midnight = 1_799_967_600.0
    private fun at(d: Int, h: Int, m: Int = 0) = midnight + d * 86400 + h * 3600 + m * 60
    private fun spot(name: String, lat: Double, lon: Double, id: String? = null) = TripCard.Spot(name, id, lat, lon)
    private val veghel = spot("Veghel, Busstation", 51.6137, 5.5474)
    private val eindhoven = spot("Eindhoven Centraal", 51.4432, 5.4812, "ehv")
    private val tilburg = spot("Tilburg", 51.5605, 5.0838, "tb")
    private val breda = spot("Breda", 51.5955, 4.7797, "bd")
    private val helmond = spot("Helmond", 51.4755, 5.6618, "hm")

    private fun leg(trip: String, line: String, from: TripCard.Spot, dep: Double, to: TripCard.Spot, arr: Double, bus: Boolean = false, num: String? = null) =
        WayLeg(trip, if (bus) "bus" else "train", line, num, from = from, to = to, dep = dep, arr = arr)
    private fun way(legs: List<WayLeg>, walkAfter: Int = 13) = Way(legs, legs[0].dep - 5 * 60, legs.last().arr + walkAfter * 60)
    private fun timetable(classes: List<TimetableClass>): TimetableShare { val w = TimetableDays.window(t0); return TimetableShare(w.first, w.second, classes) }
    private fun c(d: Int, h: Int, m: Int, eh: Int, em: Int) = TimetableClass(at(d, h, m), at(d, eh, em))
    private val name: (String) -> String = { if (it == "me") "you" else it.replaceFirstChar { c -> c.uppercase() } }

    @Test fun daysThisWeekAndNext() {
        val me = ComparePerson("me", "You", true, timetable(listOf(c(3, 9, 0, 12, 0), c(8, 10, 0, 12, 0))))
        val sam = ComparePerson("sam", "Sam", timetable = timetable(listOf(c(3, 9, 0, 15, 0))))
        val tom = ComparePerson("tom", "Tom")
        val days = Compare.days(listOf(me, sam, tom), t0)
        assertEquals(listOf("2027-01-15", "2027-01-18", "2027-01-19", "2027-01-20", "2027-01-21", "2027-01-22", "2027-01-23"), days.map { it.key })
        val monday = days[1]
        assertTrue(monday.shared)
        assertEquals(at(3, 9), monday.person("me")!!.first!!, 0.0)
        assertEquals(at(3, 15), monday.person("sam")!!.lastEnd!!, 0.0)
        assertFalse(monday.person("tom")!!.known)
        assertEquals("09:00–15:00 · 1 class", CompareWords.day(monday.person("sam")!!))
        assertEquals("Not shared", CompareWords.day(monday.person("tom")!!))
        assertEquals("No classes", CompareWords.day(days[2].person("sam")!!))
        assertEquals("2027-01-18", Compare.nextShared(days, t0))
        assertEquals("Mon 18", TimetableDays.short("2027-01-18"))
    }

    @Test fun freeTogether() {
        val me = PersonDay("me", true, listOf(c(3, 9, 0, 10, 30), c(3, 13, 0, 15, 0)))
        val sam = PersonDay("sam", true, listOf(c(3, 9, 0, 11, 0), c(3, 12, 0, 15, 0)))
        val lisa = PersonDay("lisa", true, listOf(c(3, 8, 30, 10, 0), c(3, 12, 45, 16, 0)))
        val free = Compare.freeTogether(CompareDay("2027-01-18", listOf(me, sam, lisa)))
        assertEquals(listOf(FreeSlot(at(3, 11), at(3, 12), listOf("lisa", "me", "sam")), FreeSlot(at(3, 12), at(3, 12, 45), listOf("lisa", "me"))), free)
        assertEquals("Free together 11:00–12:00 · Lisa, you and Sam", CompareWords.free(free[0], name))
        val odd = PersonDay("x", true, listOf(c(3, 9, 0, 11, 0), c(3, 10, 0, 10, 30), TimetableClass(at(3, 12)), c(3, 14, 0, 15, 0)))
        assertEquals(listOf(at(3, 11) to at(3, 12)), Compare.free(odd))
    }

    private val school: List<PersonWays>
        get() = listOf(
            PersonWays("me", listOf(
                way(listOf(leg("b305-0", "305", veghel, at(3, 6, 35), eindhoven, at(3, 7, 5), bus = true), leg("ic-3510", "IC", eindhoven, at(3, 7, 11), breda, at(3, 8, 2), num = "3510"))),
                way(listOf(leg("b305-1", "305", veghel, at(3, 7, 5), eindhoven, at(3, 7, 35), bus = true), leg("ic-3512", "IC", eindhoven, at(3, 7, 41), breda, at(3, 8, 32), num = "3512"))),
            ), at(3, 8, 50)),
            PersonWays("lisa", listOf(way(listOf(leg("ic-3512", "IC", eindhoven, at(3, 7, 41), breda, at(3, 8, 32), num = "3512")))), at(3, 8, 50)),
            PersonWays("sam", listOf(way(listOf(leg("ic-3512", "IC", tilburg, at(3, 8, 3), breda, at(3, 8, 32), num = "3512")))), at(3, 8, 50)),
            PersonWays("tom", listOf(way(listOf(leg("ic-3520", "IC", eindhoven, at(3, 9, 41), breda, at(3, 10, 32), num = "3520")))), at(3, 10, 35)),
        )

    @Test fun sharedRideToSchool() {
        val rides = SharedRides.match(school, SharedRides.Direction.TO_SCHOOL)
        assertEquals(1, rides.size)
        val r = rides[0]
        assertEquals("ic-3512", r.trip)
        assertEquals(listOf("lisa", "me", "sam"), r.ids)
        assertEquals("Tilburg", r.rider("sam")!!.board.name)
        assertEquals(1, r.rider("me")!!.way)
        assertEquals(29 * 60.0, SharedRides.together(r), 0.0)
        assertEquals("IC 3512 · 07:41 from Eindhoven Centraal", RideWords.headline(r))
        assertEquals("Lisa, you and Sam (gets on at Tilburg 08:03)", RideWords.riders(r, name))
        val tom = PersonDay("tom", true, listOf(c(3, 10, 45, 13, 0)))
        assertEquals("Tom starts 10:45", RideWords.missing(tom, SharedRides.Direction.TO_SCHOOL, "Tom", true))
        assertEquals("Tom ends 13:00", RideWords.missing(tom, SharedRides.Direction.HOME, "Tom", true))
        assertEquals("Kim: no classes", RideWords.missing(PersonDay("x", true, emptyList()), SharedRides.Direction.TO_SCHOOL, "Kim", true))
        assertEquals("Kim hasn’t shared this day", RideWords.missing(PersonDay("x", false, emptyList()), SharedRides.Direction.TO_SCHOOL, "Kim", true))
        assertEquals("Tom: no start area yet", RideWords.missing(tom, SharedRides.Direction.TO_SCHOOL, "Tom", false))
    }

    @Test fun tooEarlyIsntUsable() {
        val p = PersonWays("me", listOf(
            way(listOf(leg("a", "IC", eindhoven, at(3, 6, 41), breda, at(3, 7, 32)))),
            way(listOf(leg("b", "IC", eindhoven, at(3, 7, 41), breda, at(3, 8, 32)))),
            way(listOf(leg("c", "IC", eindhoven, at(3, 8, 41), breda, at(3, 9, 32)))),
        ), at(3, 8, 50))
        assertEquals(listOf(1), SharedRides.usable(p, SharedRides.Direction.TO_SCHOOL))
    }

    @Test fun sharedRideHome() {
        val me = PersonWays("me", listOf(way(listOf(leg("ic-3555", "IC", breda, at(3, 16, 13), eindhoven, at(3, 17, 4)))),
            way(listOf(leg("ic-3559", "IC", breda, at(3, 16, 43), eindhoven, at(3, 17, 34))))), at(3, 15, 45))
        val sam = PersonWays("sam", listOf(way(listOf(leg("ic-3555", "IC", breda, at(3, 16, 13), tilburg, at(3, 16, 35))))), at(3, 15, 45))
        val lisa = PersonWays("lisa", listOf(way(listOf(leg("ic-3563", "IC", breda, at(3, 17, 13), eindhoven, at(3, 18, 4))))), at(3, 17, 0))
        val rides = SharedRides.match(listOf(me, sam, lisa), SharedRides.Direction.HOME)
        assertEquals(listOf("ic-3555"), rides.map { it.trip })
        assertEquals(listOf("me", "sam"), rides[0].ids)
    }

    @Test fun shownKeepsOnlyNewCompany() {
        fun r(trip: String, ids: List<String>) = SharedRide(trip, "train", "IC", null, ids.map { Rider(it, 0, 0, breda, at(3, 8), breda, at(3, 9)) })
        val shown = SharedRides.shown(listOf(r("a", listOf("me", "sam", "lisa")), r("b", listOf("me", "sam")), r("c", listOf("tom", "kim")), r("d", listOf("me", "tom"))))
        assertEquals(listOf("a", "c", "d"), shown.map { it.trip })
    }

    @Test fun meetHalfwaySameTrainEachFromTheirStop() {
        val plans = MeetHalfway.plans(school.take(3))
        assertEquals("ic-3512", plans[0].ride.trip)
        assertEquals(emptyList<String>(), plans[0].missing)
        assertEquals(MeetPlan.Kind.SameRide, plans[0].kind)
        assertEquals("Same train: IC 3512 at 07:41", MeetWords.title(plans[0]))
    }

    @Test fun meetAtAStationFirst() {
        val lisa = PersonWays("lisa", listOf(way(listOf(leg("spr-hm", "SPR", helmond, at(3, 7, 20), eindhoven, at(3, 7, 33)),
            leg("ic-3512", "IC", eindhoven, at(3, 7, 41), breda, at(3, 8, 32), num = "3512")))), at(3, 8, 50))
        val plans = MeetHalfway.plans(listOf(school[0], lisa))
        assertEquals("ic-3512", plans[0].ride.trip)
        assertEquals(MeetPlan.Kind.MeetAt(eindhoven, at(3, 7, 35)), plans[0].kind)
        assertEquals("Meet at Eindhoven Centraal 07:35, then IC 3512 together", MeetWords.title(plans[0]))
    }

    @Test fun meetHalfwayOntoYourTrain() {
        val route = listOf(
            RouteStop("Eindhoven Centraal", "ehv", eindhoven.point!!, at(3, 7, 41), at(3, 7, 39)),
            RouteStop("Tilburg", "tb", tilburg.point!!, at(3, 8, 3), at(3, 8, 1)),
            RouteStop("Breda", "bd", breda.point!!, null, at(3, 8, 32)),
        )
        val mine = school[0]
        val kimStart = tilburg.point!!
        val kimDest = GeoPoint(51.5930, 4.7790)
        val kimOwn = listOf(way(listOf(leg("ic-3516", "IC", tilburg, at(3, 8, 33), breda, at(3, 8, 51)))))
        assertTrue(MeetHalfway.plans(listOf(mine, PersonWays("kim", kimOwn, at(3, 8, 50)))).isEmpty())
        val ride = SharedRide("ic-3512", "train", "IC", "3512", listOf(Rider("me", 1, 1, eindhoven, at(3, 7, 41), breda, at(3, 8, 32))))
        val plan0 = MeetPlan(MeetPlan.Kind.SameRide, ride, mapOf("me" to mine.ways[1]), listOf("kim"))
        val joins = MeetHalfway.joins(route, ride, kimStart, kimDest, at(3, 8, 50), kimOwn, at(3, 6))
        assertEquals(MeetJoin(1, 2, 6, emptyList()), joins.first())
        val template = mine.ways[1].legs[1]
        val w = MeetHalfway.joined(joins[0], template, route, kimStart, null, at(3, 8, 50))!!
        assertEquals(1, w.legs.size)
        assertEquals("Tilburg", w.legs[0].from.name)
        assertEquals(at(3, 8, 3), w.legs[0].dep, 0.0)
        assertEquals(at(3, 8, 38), w.end, 0.0)
        val plan = MeetHalfway.adding(plan0, "kim", w, "ic-3512")
        assertEquals(emptyList<String>(), plan.missing)
        assertEquals(listOf("me", "kim"), plan.ride.ids)
        assertEquals(MeetPlan.Kind.SameRide, plan.kind)
        assertNull(MeetHalfway.joined(joins[0], template, route, kimStart, null, at(3, 8, 30)))
        val card = MeetHalfway.card(w, spot("BUas", 51.5866, 4.7745), at(3, 8, 50), MeetWords.note(plan, { if (it == "me") "you" else "Kim" }, "me"))
        assertNotNull(TripCard.valid(card))
        assertEquals("ic-3512", card.rides[0].trip)
        assertEquals("Meet halfway: IC 3512 together · Kim gets on at Tilburg 08:03", card.note)
        assertEquals("ic-3512", TripTake.shared(card)!!.trip)
    }

    @Test fun joinOntoTheRestOfYourOwnWay() {
        val route = listOf(
            RouteStop("Eindhoven Centraal", "ehv", eindhoven.point!!, at(3, 7, 41), null),
            RouteStop("Tilburg", "tb", tilburg.point!!, at(3, 8, 3), at(3, 8, 1)),
            RouteStop("Breda", "bd", breda.point!!, null, at(3, 8, 32)),
        )
        val ride = SharedRide("ic-3512", "train", "IC", "3512", listOf(Rider("me", 0, 0, eindhoven, at(3, 7, 41), breda, at(3, 8, 32))))
        val own = listOf(way(listOf(leg("bus-1", "141", helmond, at(3, 7, 0), tilburg, at(3, 7, 55), bus = true),
            leg("bus-2", "142", tilburg, at(3, 8, 10), spot("Oisterwijk", 51.58, 5.19), at(3, 8, 30), bus = true))))
        val joins = MeetHalfway.joins(route, ride, eindhoven.point!!, GeoPoint(51.58, 5.19), at(3, 8, 50), own, at(3, 6))
        assertEquals(0, joins.first().board)
        assertEquals(1, joins.first().alight)
        assertEquals(listOf("bus-2"), joins.first().rest.map { it.trip })
    }

    @Test fun requestBudget() {
        val b = RequestBudget(RequestBudget.MEET)
        assertEquals(12, b.left)
        assertTrue(b.take(10)); assertFalse(b.take(3)); assertTrue(b.take(2)); assertFalse(b.take())
        assertEquals(12, b.used)
        assertEquals(24, RequestBudget.COMPARE)
    }
}
