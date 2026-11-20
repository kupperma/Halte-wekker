package nl.haltewekker.motion

import kotlin.math.max

/**
 * (A6, iOS 0.33 `MotionRules.swift`) what the motion sensor says, turned into the few decisions it may change, each only
 * ever a hint next to the GPS: fewer false "on the move" (walking or cycling under 43 km/h isn't a vehicle), a cheaper
 * look while you stand at a stop. The alarm, the wake distance and the backup alarm never depend on it. Pure.
 * (Android has no Activity Recognition without Google Play services: `StepMotion` gives "walking" from the hardware
 * step detector, and nothing else; the rules are the iOS ones, so "automotive" is never said on Android.)
 */
enum class MotionKind { STATIONARY, WALKING, RUNNING, CYCLING, AUTOMOTIVE, UNKNOWN }
enum class MotionConfidence { LOW, MEDIUM, HIGH }

data class MotionSample(val t: Double, val kind: MotionKind, val confidence: MotionConfidence)
data class MotionNow(val kind: MotionKind, val confidence: MotionConfidence, val since: Double, val at: Double)

object MotionRules {
    const val STALE = 5 * 60.0
    const val STEADY_FOR = 180.0
    const val AFOOT_TOP = 12.0
    const val SLOW_LOOK = 15.0
    const val WAIT_MARGIN = 2000.0
    const val REGION_LOOK_SOON = 12.0
    const val REGION_LOOK_USUAL = 35.0
    const val KEEP = 15 * 60.0

    fun now(samples: List<MotionSample>, at: Double, live: Boolean): MotionNow? {
        val past = samples.filter { it.t <= at + 1 }.sortedBy { it.t }
        val last = past.lastOrNull() ?: return null
        if (!live && at - last.t > STALE) return null
        var since = last.t
        for (s in past.reversed().drop(1)) {
            if (s.kind == last.kind) { since = s.t; continue }
            if (s.confidence == MotionConfidence.LOW) continue
            break
        }
        return MotionNow(last.kind, last.confidence, since, last.t)
    }

    private fun sure(m: MotionNow?) = m?.takeIf { it.confidence >= MotionConfidence.MEDIUM }

    fun inVehicle(m: MotionNow?) = sure(m)?.kind == MotionKind.AUTOMOTIVE

    fun steadyVehicle(m: MotionNow?, now: Double) = inVehicle(m) && m != null && now - m.since >= STEADY_FOR

    fun afoot(m: MotionNow?) = sure(m)?.kind.let { it == MotionKind.WALKING || it == MotionKind.RUNNING || it == MotionKind.CYCLING }

    fun still(m: MotionNow?) = sure(m)?.kind.let { it == MotionKind.STATIONARY || it == MotionKind.WALKING }

    fun notAVehicle(m: MotionNow?, speed: Double?): Boolean {
        if (!afoot(m)) return false
        return (speed?.takeIf { it.isFinite() } ?: 0.0) < AFOOT_TOP
    }

    fun movingLikeVehicle(byFixes: Boolean, motion: MotionNow?, speed: Double?): Boolean {
        if (inVehicle(motion)) return true
        return byFixes && !notAVehicle(motion, speed)
    }

    fun lookWait(base: Double, motion: MotionNow?, movingByFixes: Boolean): Double =
        if (!still(motion) || movingByFixes) base else max(base, SLOW_LOOK)

    fun waitLow(waiting: Boolean, motion: MotionNow?, movingByFixes: Boolean, metresToStop: Double?, wakeMetres: Double): Boolean {
        if (!waiting || !still(motion) || movingByFixes) return false
        val d = metresToStop ?: return false
        if (!d.isFinite() || !wakeMetres.isFinite()) return false
        return d > wakeMetres + WAIT_MARGIN
    }

    fun firstRegionLook(m: MotionNow?) = if (inVehicle(m)) REGION_LOOK_SOON else REGION_LOOK_USUAL

    fun trim(samples: List<MotionSample>, now: Double): List<MotionSample> {
        val sorted = samples.sortedBy { it.t }
        val from = now - KEEP
        val recent = sorted.filter { it.t >= from }
        val before = sorted.lastOrNull { it.t < from } ?: return recent
        return listOf(before) + recent
    }

    // MARK: (Android) from the step detector

    /** Steps this close together are walking (s). */
    const val STEP_GAP = 4.0
    /** Steps within this window make it "walking" (at least `STEPS_FOR_WALKING` of them). */
    const val STEP_WINDOW = 12.0
    const val STEPS_FOR_WALKING = 6

    /**
     * The step detector's steps (their times) as a motion sample at `now`: walking (medium) when there were
     * `STEPS_FOR_WALKING` steps in the last `STEP_WINDOW` seconds with no gap over `STEP_GAP`; else nothing (the
     * absence of steps isn't standing still: a phone on a seat counts none either).
     */
    fun fromSteps(steps: List<Double>, now: Double): MotionSample? {
        val recent = steps.filter { it <= now && now - it <= STEP_WINDOW }.sorted()
        if (recent.size < STEPS_FOR_WALKING) return null
        if (now - recent.last() > STEP_GAP) return null
        for (i in 1 until recent.size) if (recent[i] - recent[i - 1] > STEP_GAP) return null
        return MotionSample(recent.last(), MotionKind.WALKING, MotionConfidence.MEDIUM)
    }
}
