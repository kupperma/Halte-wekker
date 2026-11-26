package nl.haltewekker

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Polyline
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GeoTest {
    @Test fun metresAndBearing() {
        assertEquals(1000.0, Geo.metres(Fx.east(0.0), Fx.east(1000.0)), 0.5)
        assertEquals(90.0, Geo.bearing(Fx.east(0.0), Fx.east(1000.0)), 0.01)
        assertEquals(0.0, Geo.bearing(GeoPoint(51.0, 5.0), GeoPoint(51.1, 5.0)), 0.01)
        assertEquals(6900.0, Geo.length(Fx.railway), 1.0)
    }

    @Test fun projectsOntoAPath() {
        val p = Geo.project(Fx.east(1500.0, north = 40.0), Fx.railway)!!
        assertEquals(40.0, p.crossTrack, 0.5)
        assertEquals(1500.0, p.along, 0.5)
        assertEquals(90.0, p.bearing, 0.1)
        assertNull(Geo.project(Fx.east(0.0), listOf(Fx.east(0.0))))
    }

    @Test fun passesBothWaysOnAThereAndBackPath() {
        val path = listOf(Fx.east(0.0), Fx.east(1000.0), Fx.east(0.0, north = 10.0))
        val all = Geo.passes(Fx.east(500.0, north = 5.0), path)
        assertEquals(2, all.size)
        val back = Geo.pass(Fx.east(500.0, north = 5.0), path, near = 1500.0, within = 20.0)!!
        assertEquals(1500.0, back.projection.along, 2.0)
    }

    @Test fun pointAlong() {
        val p = Geo.pointAtMetres(1500.0, Fx.railway)!!
        assertEquals(0.0, Geo.metres(p, Fx.east(1500.0)), 0.5)
        assertEquals(Fx.railway.last(), Geo.pointAtMetres(1e6, Fx.railway))
    }

    @Test fun decodesAPolyline() {
        val pts = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        assertEquals(3, pts.size)
        assertEquals(38.5, pts[0].lat, 1e-6); assertEquals(-120.2, pts[0].lon, 1e-6)
        assertEquals(40.7, pts[1].lat, 1e-6); assertEquals(-120.95, pts[1].lon, 1e-6)
        assertEquals(43.252, pts[2].lat, 1e-6); assertEquals(-126.453, pts[2].lon, 1e-6)
        assertTrue(Polyline.decode("").isEmpty())
    }
}
