package nl.haltewekker

import kotlinx.serialization.json.Json
import nl.haltewekker.travel.StudentOV
import nl.haltewekker.travel.StudentOV.Fare
import nl.haltewekker.travel.StudentOV.Product
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.ZonedDateTime

/** iOS `StudentOVTests` (0.36): DUO's windows. 2026-11-16 is a Monday; 2026-11-20 a Friday. */
class StudentOVTest {
    private fun at(y: Int, m: Int, d: Int, h: Int, min: Int = 0) = ZonedDateTime.of(y, m, d, h, min, 0, 0, StudentOV.zone).toEpochSecond().toDouble()
    private fun fare(p: Product, d: Double, train: Boolean = true) = StudentOV.fare(p, d, train)?.fare
    private val d40 = Fare.Discount(40)

    @Test fun noProduct() {
        assertNull(StudentOV.fare(Product.NONE, at(2026, 11, 18, 10), true))
        assertNull(StudentOV.line(Product.NONE, at(2026, 11, 18, 10), true, 600))
    }

    @Test fun weekProductMondayFourToSaturdayFour() {
        assertEquals(d40, fare(Product.WEEK, at(2026, 11, 16, 3, 59)))
        assertEquals(Fare.Free, fare(Product.WEEK, at(2026, 11, 16, 4, 0)))
        assertEquals(Fare.Free, fare(Product.WEEK, at(2026, 11, 18, 8, 0)))
        assertEquals(Fare.Free, fare(Product.WEEK, at(2026, 11, 21, 3, 59)))
        assertEquals(d40, fare(Product.WEEK, at(2026, 11, 21, 4, 0)))
        assertEquals(StudentOV.Why.WEEKEND, StudentOV.fare(Product.WEEK, at(2026, 11, 22, 12), true)?.why)
        assertEquals(Fare.Discount(34), fare(Product.WEEK, at(2026, 11, 22, 12), false))
    }

    @Test fun weekendProductWindows() {
        assertEquals(Fare.Full, fare(Product.WEEKEND, at(2026, 11, 20, 8, 59)))
        assertEquals(StudentOV.Why.MORNING, StudentOV.fare(Product.WEEKEND, at(2026, 11, 20, 8), true)?.why)
        assertEquals(d40, fare(Product.WEEKEND, at(2026, 11, 20, 9, 0)))
        assertEquals(d40, fare(Product.WEEKEND, at(2026, 11, 20, 11, 59)))
        assertEquals(Fare.Free, fare(Product.WEEKEND, at(2026, 11, 20, 12, 0)))
        assertEquals(Fare.Free, fare(Product.WEEKEND, at(2026, 11, 21, 3, 0)))
        assertEquals(Fare.Free, fare(Product.WEEKEND, at(2026, 11, 22, 18)))
        assertEquals(Fare.Free, fare(Product.WEEKEND, at(2026, 11, 23, 3, 59)))
        assertEquals(d40, fare(Product.WEEKEND, at(2026, 11, 23, 4, 0)))
        assertEquals(d40, fare(Product.WEEKEND, at(2026, 11, 23, 7, 0)))
        assertEquals(d40, fare(Product.WEEKEND, at(2026, 11, 24, 3, 0)))
        assertEquals(Fare.Full, fare(Product.WEEKEND, at(2026, 11, 24, 4, 0)))
        assertEquals(Fare.Full, fare(Product.WEEKEND, at(2026, 11, 26, 8, 30)))
        assertEquals(d40, fare(Product.WEEKEND, at(2026, 11, 26, 9, 0)))
        assertEquals(Fare.Discount(34), fare(Product.WEEKEND, at(2026, 11, 26, 9, 0), false))
    }

    @Test fun summerIsDiscountForTheWeekProductOnly() {
        assertEquals(Fare.Free, fare(Product.WEEK, at(2026, 7, 16, 3, 59)))
        assertEquals(d40, fare(Product.WEEK, at(2026, 7, 16, 4, 0)))
        assertEquals(StudentOV.Why.SUMMER, StudentOV.fare(Product.WEEK, at(2026, 8, 3, 9), true)?.why)
        assertEquals(Fare.Free, fare(Product.WEEK, at(2026, 8, 17, 9)))
        assertEquals(Fare.Free, fare(Product.WEEKEND, at(2026, 8, 1, 10)))
        assertEquals(d40, fare(Product.WEEKEND, at(2026, 8, 4, 10)))
    }

    @Test fun holidays() {
        for ((y, m, d) in listOf(Triple(2026, 1, 1), Triple(2026, 4, 3), Triple(2026, 4, 6), Triple(2026, 4, 27), Triple(2026, 5, 5), Triple(2026, 5, 14),
            Triple(2026, 5, 25), Triple(2026, 12, 25), Triple(2027, 3, 26), Triple(2027, 3, 29), Triple(2027, 4, 27), Triple(2027, 5, 6), Triple(2027, 5, 17)))
            assertNotNull("$y-$m-$d", StudentOV.holiday(y, m, d))
        assertNull(StudentOV.holiday(2026, 11, 20))
        assertEquals(StudentOV.Holiday.KINGS_DAY, StudentOV.holiday(2025, 4, 26))
        assertNull(StudentOV.holiday(2025, 4, 27))
        assertEquals(d40, fare(Product.WEEK, at(2026, 4, 6, 10)))
        assertEquals(StudentOV.Why.HOLIDAY, StudentOV.fare(Product.WEEK, at(2026, 4, 6, 10), true)?.why)
        assertEquals(d40, fare(Product.WEEK, at(2026, 4, 7, 3, 59)))
        assertEquals(Fare.Free, fare(Product.WEEK, at(2026, 4, 7, 4, 0)))
        assertEquals(Fare.Free, fare(Product.WEEK, at(2026, 4, 3, 10)))
        assertEquals(Fare.Free, fare(Product.WEEKEND, at(2026, 5, 5, 7)))
        assertEquals(d40, fare(Product.WEEKEND, at(2026, 5, 13, 11, 59)))
        assertEquals(Fare.Free, fare(Product.WEEKEND, at(2026, 5, 13, 12, 0)))
        assertEquals(Fare.Free, fare(Product.WEEKEND, at(2026, 4, 2, 13)))
        assertEquals(Fare.Full, fare(Product.WEEKEND, at(2026, 4, 2, 8)))
    }

    @Test fun words() {
        assertEquals("Free with your student OV", StudentOV.line(Product.WEEK, at(2026, 11, 18, 8), true, 600))
        assertEquals("Costs money now (weekday) — ~€3.60 with 40% off", StudentOV.line(Product.WEEKEND, at(2026, 11, 18, 10), true, 600))
        assertEquals("Costs money now (weekday morning) — ~€6.00", StudentOV.line(Product.WEEKEND, at(2026, 11, 18, 8), true, 600))
        assertEquals("Costs money now (weekend) — 40% off", StudentOV.line(Product.WEEK, at(2026, 11, 22, 8), true, null))
        assertEquals("Costs money now (weekday morning) — full fare", StudentOV.line(Product.WEEKEND, at(2026, 11, 18, 8), false, null))
        assertEquals("€12.34", StudentOV.euros(1234)); assertEquals("€0.05", StudentOV.euros(5))
    }

    @Test fun tripLineFirstNotFreeDecides() {
        val fri11 = at(2026, 11, 20, 11, 40); val fri12 = at(2026, 11, 20, 12, 5)
        assertEquals("Costs money now (weekday) — 34% off", StudentOV.tripLine(Product.WEEKEND, listOf(false to fri11, true to fri12), 600))
        assertEquals("Free with your student OV", StudentOV.tripLine(Product.WEEKEND, listOf(true to fri12, false to fri12), 600))
        assertNull(StudentOV.tripLine(Product.NONE, listOf(true to fri12), 600))
    }

    @Test fun fullFareFromRelayAnswers() {
        val trips = Json.parseToJsonElement("""{"source":"trips","fares":[
            {"priceInCents":1080,"travelClass":"FIRST_CLASS","discountType":"NO_DISCOUNT"},
            {"priceInCents":600,"travelClass":"SECOND_CLASS","discountType":"NO_DISCOUNT"},
            {"priceInCents":480,"travelClass":"SECOND_CLASS","discountType":"DISCOUNT_20_PERCENT"}],
            "productFare":{"priceInCents":600,"travelClass":"SECOND_CLASS","discountType":"NO_DISCOUNT"}}""")
        assertEquals(600, StudentOV.fullFareCents(trips))
        assertNull(StudentOV.fullFareCents(Json.parseToJsonElement("""{"source":"trips","fares":[]}""")))
        assertNull(StudentOV.fullFareCents(null))
        assertEquals(165, StudentOV.pay(StudentOV.Answer(Fare.Discount(34), StudentOV.Why.WEEKDAY), 250))
        assertNull(StudentOV.pay(StudentOV.Answer(Fare.Free, StudentOV.Why.WEEKDAY), 250))
    }
}
