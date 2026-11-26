package nl.haltewekker

import nl.haltewekker.friends.B64u
import nl.haltewekker.friends.BuddyPlan
import nl.haltewekker.friends.CampusState
import nl.haltewekker.friends.ChatText
import nl.haltewekker.friends.DelayWords
import nl.haltewekker.friends.FriendBox
import nl.haltewekker.friends.FriendCrypto
import nl.haltewekker.friends.FriendIdentity
import nl.haltewekker.friends.FriendMessage
import nl.haltewekker.friends.Hex
import nl.haltewekker.friends.RideDelay
import nl.haltewekker.friends.ScoresRules
import nl.haltewekker.friends.TripCard
import nl.haltewekker.friends.WaitAnswer
import nl.haltewekker.friends.WaitFor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Friends 0.29 and 0.30 (the extras): the wait, campus, buddy, delay and scores boxes and a wait's answer made here from
 * values (not from the parsed payload) must come out byte for byte as the spec's vectors (Node's crypto, checked by the
 * iOS FriendExtrasVectorTests and FriendExtrasBTests); the boxes lock and open the same.
 */
class FriendExtrasVectorTest {
    private fun hex(s: String) = Hex.decode(s)!!
    private val sam = FriendIdentity(hex("000102030405060708090a0b0c0d0e0f"))
    private val lou = FriendIdentity(hex("101112131415161718191a1b1c1d1e1f"))
    private val t0 = 1_800_000_000L
    private val ehv = TripCard.Spot("Eindhoven Centraal", lat = 51.44306, lon = 5.47917)
    private val bd = TripCard.Spot("Breda", lat = 51.59556, lon = 4.78)

    private fun ride3512(dep: Double, arr: Double) = TripCard.Ride(mode = "train", line = "IC", num = "3512", trip = "vector-trip-3512", from = ehv, to = bd, dep = dep, arr = arr)

    private fun lockCheck(payload: String, sig: String, box: String, eph: String, ephPub: String, nonce: String) {
        val p = payload.toByteArray(Charsets.UTF_8)
        val s = B64u.decode(sig)!!
        assertTrue(FriendCrypto.verify(sam.signKey, FriendBox.signed(p, lou.account), s))
        assertEquals(sig, B64u.encode(sam.sign(FriendBox.signed(p, lou.account))))
        assertEquals(ephPub, Hex.encode(FriendCrypto.xPublic(hex(eph))))
        assertEquals(box, B64u.encode(FriendBox.lock(s + p, lou.card, hex(eph), hex(nonce))))
    }

    private fun open(box: String) = FriendBox.open(B64u.decode(box)!!, lou, sam.account) { if (it == sam.account) sam.card else null }

    @Test fun kindsVersion() {
        for (k in listOf("wait", "delay", "buddy", "campus", "scores")) assertTrue(k in FriendMessage.known)
        assertEquals(6, FriendMessage.KINDS_VERSION)
    }

    @Test fun waitBox() {
        val w = WaitFor("vector-wait-1", "coming", ehv, ride3512(1_800_000_660.0, 1_800_003_720.0), 300, 1_800_000_120.0, 1_799_999_990.0)
        val p = String(FriendBox.payload(FriendMessage.Wait(w), sam.account, t0, "vector-11"), Charsets.UTF_8)
        assertEquals(WAIT_PAYLOAD, p)
        lockCheck(WAIT_PAYLOAD, WAIT_SIG, WAIT_BOX, "5152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f70",
            "0233f006ef4bed144ea0a5bb46c7067c7c2acec5f8cc811f3df59fdcd5ac7614", "7172737475767778797a7b7c")
        val got = (open(WAIT_BOX).message as FriendMessage.Wait).wait
        assertEquals(w, got)
        assertEquals(WaitFor.Phase.COMING, got.phase)
    }

    @Test fun campusBox() {
        val c = CampusState(true, "BUas", 1_799_998_500.0, 1_800_034_500.0)
        assertEquals(CAMPUS_PAYLOAD, String(FriendBox.payload(FriendMessage.Campus(c), sam.account, t0, "vector-12"), Charsets.UTF_8))
        lockCheck(CAMPUS_PAYLOAD, CAMPUS_SIG, CAMPUS_BOX, "8182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0",
            "883186b800b41d5cf0429695da9b3cc4f328ebcd184a6e482fa578c103f06c77", "c1c2c3c4c5c6c7c8c9cacbcc")
        assertEquals(FriendMessage.Campus(c), open(CAMPUS_BOX).message)
    }

    @Test fun buddyPayload() {
        val b = BuddyPlan(true, "2027-01-15", 1_799_994_000.0, ride3512(1_799_995_260.0, 1_799_998_320.0))
        val p = FriendBox.payload(FriendMessage.Buddy(b), sam.account, 1_799_992_800L, "vector-13")
        assertEquals(BUDDY_PAYLOAD, String(p, Charsets.UTF_8))
        assertEquals(BUDDY_SIG, B64u.encode(sam.sign(FriendBox.signed(p, lou.account))))
        assertEquals(FriendMessage.Buddy(b), FriendBox.parse(p).second)
        val off = String(FriendBox.payload(FriendMessage.Buddy(BuddyPlan(false)), sam.account, t0, "x"), Charsets.UTF_8)
        assertTrue(off.startsWith("{\"b\":{\"on\":false},"))
    }

    @Test fun delayPayload() {
        val ride = ride3512(1_800_000_360.0, 1_800_003_420.0).copy(sdep = t0.toDouble())
        val next = TripCard.Ride(mode = "train", line = "IC", num = "3516", trip = "vector-trip-3516", from = ehv, to = bd, dep = 1_800_001_800.0, arr = 1_800_004_860.0)
        val d = RideDelay(ride, 6, next = next, who = listOf(sam.account, lou.account))
        val p = FriendBox.payload(FriendMessage.Delay(d), sam.account, t0, "vector-14")
        assertEquals(DELAY_PAYLOAD, String(p, Charsets.UTF_8))
        assertEquals(DELAY_SIG, B64u.encode(sam.sign(FriendBox.signed(p, lou.account))))
        assertEquals(FriendMessage.Delay(d), FriendBox.parse(p).second)
        assertEquals("IC 3512 is 6 min late", DelayWords.title(d))
    }

    @Test fun waitAnswerPayload() {
        val body = ChatText(WaitAnswer.WAIT.text, "vector-wait-1", "wait")
        val p = FriendBox.payload(FriendMessage.Message(body), lou.account, 1_800_000_030L, "vector-15")
        assertEquals(ANSWER_PAYLOAD, String(p, Charsets.UTF_8))
        assertEquals(ANSWER_SIG, B64u.encode(lou.sign(FriendBox.signed(p, sam.account))))
    }

    @Test fun scoresBoxFromYourTrips() {
        val trips = FriendExtrasBTest.myTrips
        // (this month's best to school only, as in the spec's vector)
        val body = ScoresRules.build(trips, 14, t0.toDouble()).let { b ->
            b.copy(mbest = ScoresRules.bests(trips.filter { !it.home && ScoresRules.month(it.at) == "2027-01" }))
        }
        val p = String(FriendBox.payload(FriendMessage.Scores(body), sam.account, t0, "vector-16"), Charsets.UTF_8)
        assertEquals(SCORES_PAYLOAD, p)
        val s = B64u.decode(SCORES_SIG)!!
        assertEquals(SCORES_BOX, B64u.encode(FriendBox.lock(s + p.toByteArray(), lou.card,
            hex("9192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0"), hex("d1d2d3d4d5d6d7d8d9dadbdd"))))
        assertEquals(FriendMessage.Scores(body), open(SCORES_BOX).message)
    }

    companion object {
        const val WAIT_PAYLOAD = """{"b":{"at":1799999990,"dist":300,"eta":1800000120,"id":"vector-wait-1","ride":{"arr":1800003720,"dep":1800000660,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3512","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"},"state":"coming","stop":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"}},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"wait","n":"vector-11","t":1800000000,"v":1}"""
        const val WAIT_SIG = "dvEcw94cpL8gWf9Pk5zYUIs1-BuEqsDFUGLCyxkupqCyiFUZQNQ2u9kTLUICfKy0W_EOElr6dHRbdLfVWwJDBA"
        const val WAIT_BOX = "AQIz8AbvS-0UTqClu0bHBnx8Ks7F-MyBHz31n9zVrHYUcXJzdHV2d3h5ent8F4o711H-IQXcNO0jPzR1Ejq4_JNB8y8vGAu7V-8zdOX1UD3N50pM00P_1ADbwrE3h2wmhHcHqQEz3aRrX0n3sIOzc-UWOECBBaxHwmpFfUoOHcakg99KDVQeMqmhhAYlfNcUv5s09i7WlXYo67QXcMQAxr5LJm72nq6ZhSNVBXjGtjFHTuuUCl3ilkUa-8nepuYvnJSCbcLXRclEJUDxFeVEBO0-6NXuHP7FBDo7mTMP-TARfC1o7ZDV-dK67xSB-CeKwDJZelbIe7_mUIBbkv8lrXudYV_1qhsBCp-CBR_-XRSu-07ceS9do_vOnz6YQ0DSo-ec87gJn-J9jQlxYOWYhVezq9ZwxIOH-pLym5h0uZeYGhN6PAxlBQRZwJIbRILXFpqypJm36Ly9CjU7nxsZrGRMtrqmDTHxkSQwmbl9UTpgf6yZxz0BzBEAvOcz2ygKb8SITHbSbyaVL4TwQel2xRmpgMVfpe4KwaYlxTXLz6TObtYy6Kmx1urlARXMP2lRhDfH3TGnzA8Qq00AH43ryoWsZGtF4j7E6FSV5Jq1qAtOo7qIFPIx0XttCjdbaCUyfu-U_w0tz8Sh6hapPzAcJCYeI0UOgzsw63llntPRDyN9qb1pNHrKPIbHaSLdFV7tGH11uhMG9r7u92952kkBSFh9EeAuhn1nswYrEnL9vsH-K4aLg8PR1oTtR10ifQ5FF5YVTZWlzrrn66h83XM"
        const val CAMPUS_PAYLOAD = """{"b":{"on":true,"school":"BUas","since":1799998500,"until":1800034500},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"campus","n":"vector-12","t":1800000000,"v":1}"""
        const val CAMPUS_SIG = "KZJaSU7N-X7-nf4ppDL55RLL8r1QNVvZk4tS_e-5MVXjklHFbv0DrckGuITkgbOQBMkqpwd-ZiiN2NKaHm0IAg"
        const val CAMPUS_BOX = "AYgxhrgAtB1c8EKWldqbPMTzKOvNGEpuSC-leMED8Gx3wcLDxMXGx8jJysvM7sUXIpFk66f2MxcXYYb_tMTT0JGE-coRJl94y_gjkkUpyQ_ek_2yhJS6fKfMo-pj9FNhe4peWbLP9HKoM4MKBl28GjWBJwVOwQ4G6cVMY_hDekvjQ95EHvOI39blGlgywHJi9oPKRZ9Ekxmlt8QzpLsk5t7xneAEPe-cObvOIgpDj3rPTKtBac__D4tMib7wYbiF-RVet2Ye-iIf8ku1lYuiCOEuXyBMNYvzEWPO3nv_ROSbsh9G7-jmTcDLepeX-ajit0lGM0KX8xALe_wdEIUXHrqadwbnll2Rvzk-2tVpM2Swb0y6udi-r5frt2Ai"
        const val BUDDY_PAYLOAD = """{"b":{"day":"2027-01-15","leave":1799994000,"on":true,"ride":{"arr":1799998320,"dep":1799995260,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3512","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"}},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"buddy","n":"vector-13","t":1799992800,"v":1}"""
        const val BUDDY_SIG = "Zazseam6h_FFLC8gnZaYfx4ukSG2Dl2YbRSObRDZa9odsX5tHpyA-HpdHZJeZLEg3OQ91RYkIEUGzw8N6jR-Dg"
        const val DELAY_PAYLOAD = """{"b":{"late":6,"next":{"arr":1800004860,"dep":1800001800,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3516","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3516"},"ride":{"arr":1800003420,"dep":1800000360,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3512","sdep":1800000000,"to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"},"who":["3c157621a97cf055f5804a9826c6d1e1","65392c81aa86e697083b0960bf107afb"]},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"delay","n":"vector-14","t":1800000000,"v":1}"""
        const val DELAY_SIG = "hvyCU_Sk36bcLvd52FSIHuHI37Ni_qQhs7_Rpnmy5B_2hlbgSa2d47QAXRfYbBzbLV8gMvcS_c4zlVL_wJdZAA"
        const val ANSWER_PAYLOAD = """{"b":{"answer":"wait","re":"vector-wait-1","text":"I’ll wait"},"f":"65392c81aa86e697083b0960bf107afb","k":"message","n":"vector-15","t":1800000030,"v":1}"""
        const val ANSWER_SIG = "quv2P-b4oVOMfuXKCxJIVQIMwkH9zSq25Djgu81cSa7uWyaFt7gjlmcnX5kqidzMy_K-R9OC9PMbuWXzC8xDDA"
        const val SCORES_PAYLOAD = """{"b":{"best":[{"at":1799996400,"home":false,"mins":48.5,"route":"home→school"},{"at":1799910000,"home":true,"mins":52,"route":"school→home"}],"mbest":[{"at":1799996400,"home":false,"mins":48.5,"route":"home→school"}],"month":"2027-01","on":true,"rides":14},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"scores","n":"vector-16","t":1800000000,"v":1}"""
        const val SCORES_SIG = "6rLh_QChtON4H7TK4hzq8a0UxhBkm55Zq67PCwiZFCholCtVlWmo5R_13XRlGu7Vb3wcZU9wVpqMKxKcSoqcDQ"
        const val SCORES_BOX = "AZzO11GzAbvRbE-43t3YLxiSXXHtkMhE-gFY-EWw-n9L0dLT1NXW19jZ2tvd2yVEWneoEWqLeQL9E6U4tx_P1PQUZHFE0SJnGsrRekEFLdfQJJ5WTl07a8y-r1W9TrD3wY0xRFCfEXBmplz4mbB53BKkqZiLX1r8JAtjw4gc3cCshJuxPi5wI6VyWk0syVe7ZR6lvKJVRH9hMzJtULbGBPzrLoZSB9OXwcj5PnVuQUZcc6tJiAi8C6pFIfu05GXTXY97-zshmL0FOGC7GmeF2WBWojbxnt4SHwxt0VX4zc625bdH-6DVzm-mNejIBbheioXp_XLn39U4-tf3dhUMB8aarwPDxeQKawwjQjgXC2ZMVveb5jvkKqLEvjEv7zSVITyNma_T9cjEgvmZQi1Drlfv5TGcVOzF8Zlli2sWQFAtU6tdXEiqw_PW-jqIYHH7psu0FGzeLPbO_HWKJ__71nlMtqW9VptFYoHTdOjNjDHStEm5x8fMsXwAOW2thjzBvyctDHCJk0LZCgHQBCGgAt45xCgHTDViqG97IYH-qzRN6VNIavLbEhvui4514nG_Usol_5kP2S0j2gpM_B59rPMkNF4cTFLygK7GN9AXWtLKkTO5zMqD0dF4V4vm"
    }
}
