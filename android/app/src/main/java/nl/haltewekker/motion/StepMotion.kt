package nl.haltewekker.motion

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import androidx.core.content.ContextCompat

/**
 * (A6, iOS 0.33 "Use motion to notice rides faster", the Android way) Android has no Activity Recognition without
 * Google Play services, so this listens to the hardware step detector (`TYPE_STEP_DETECTOR`: a low-power sensor on the
 * phone's sensor hub; no accelerometer stream of our own) only while a trip runs and the setting is on, and says
 * "walking" (`MotionRules.fromSteps`). Nothing else: no "automotive", no "stationary". Phones without the sensor, or
 * without the permission (Physical activity, Android 10+), get nothing: everything is as before.
 */
object StepMotion {
    private val steps = ArrayDeque<Double>()
    private var sm: SensorManager? = null
    private val listener = object : SensorEventListener {
        override fun onSensorChanged(e: SensorEvent) {
            val t = System.currentTimeMillis() / 1000.0
            synchronized(steps) { steps.addLast(t); while (steps.size > 64) steps.removeFirst() }
        }
        override fun onAccuracyChanged(s: Sensor?, a: Int) {}
    }

    fun permitted(c: Context) = Build.VERSION.SDK_INT < 29 ||
        ContextCompat.checkSelfPermission(c, Manifest.permission.ACTIVITY_RECOGNITION) == PackageManager.PERMISSION_GRANTED

    fun available(c: Context) = c.getSystemService(SensorManager::class.java)?.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR) != null

    fun start(c: Context) {
        if (sm != null || !permitted(c)) return
        val m = c.getSystemService(SensorManager::class.java) ?: return
        val s = m.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR) ?: return
        // batched up to 10 s: the sensor hub wakes nothing for it
        if (m.registerListener(listener, s, SensorManager.SENSOR_DELAY_NORMAL, 10_000_000)) sm = m
    }

    fun stop() {
        sm?.unregisterListener(listener)
        sm = null
        synchronized(steps) { steps.clear() }
    }

    /** What it says now (walking, or nothing). */
    fun now(at: Double = System.currentTimeMillis() / 1000.0): MotionNow? {
        val list = synchronized(steps) { steps.toList() }
        val s = MotionRules.fromSteps(list, at) ?: return null
        return MotionRules.now(listOf(s), at, live = true)
    }
}
