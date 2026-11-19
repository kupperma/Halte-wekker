package nl.haltewekker.ride

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale

/**
 * The alarm, the arrival chime and the announcer (iOS `AlarmSound`). "Sound only with headphones" (0.24.3): without
 * headphones it only vibrates, and rings out loud after a minute if not stopped. With headphones in it plays as media
 * (Android's alarm stream also comes out of the speaker); out loud, on the alarm stream (it rings in silent mode).
 */
object AlarmPlayer {
    private val main = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var focus: AudioFocusRequest? = null
    private var pending = ArrayList<Runnable>()
    @Volatile var ringing = false
        private set

    fun warmUp(context: Context) {
        if (tts != null) return
        tts = TextToSpeech(context.applicationContext) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) tts?.language = Locale.UK
        }
    }

    private fun vibrator(context: Context): Vibrator? =
        if (Build.VERSION.SDK_INT >= 31) context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        else @Suppress("DEPRECATION") context.getSystemService(Vibrator::class.java)

    private fun attributes(loud: Boolean): AudioAttributes = AudioAttributes.Builder()
        .setUsage(if (loud) AudioAttributes.USAGE_ALARM else AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private fun later(ms: Long, r: Runnable) { pending.add(r); main.postDelayed(r, ms) }

    /** The announcement (if any), then the alarm on repeat; or, `quiet`, a strong buzz, out loud after a minute. */
    fun ring(context: Context, announcement: String?, quiet: Boolean) {
        stop(context)
        ringing = true
        val ctx = context.applicationContext
        vibrate(ctx, repeat = true)
        if (quiet) {
            later((WakeRules.LOUD_AFTER * 1000).toLong()) { if (ringing) loop(ctx, loud = true) }
            return
        }
        val private = AudioRoute.privateOutput(ctx)
        requestFocus(ctx, loud = !private)
        if (announcement.isNullOrEmpty() || !ttsReady) { loop(ctx, loud = !private); return }
        val fallback = Runnable { if (ringing && player == null) loop(ctx, loud = !private) }
        later(9000, fallback)                    // never hold the alarm back longer
        speak(announcement, loud = !private) { main.post { if (ringing && player == null) loop(ctx, loud = !private) } }
    }

    /** At the stop: the announcement once and a buzz; nothing to stop. Quiet: two buzzes only. */
    fun chime(context: Context, announcement: String?, quiet: Boolean) {
        stop(context)
        val ctx = context.applicationContext
        val v = vibrator(ctx)
        v?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 400, 300, 400), -1))
        if (quiet) return
        val private = AudioRoute.privateOutput(ctx)
        try {
            val tone = ToneGenerator(if (private) AudioManager.STREAM_MUSIC else AudioManager.STREAM_ALARM, 80)
            tone.startTone(ToneGenerator.TONE_PROP_BEEP2, 600)
            later(1500) { tone.release() }
        } catch (_: Exception) {}
        if (!announcement.isNullOrEmpty() && ttsReady) later(900) { speak(announcement, loud = !private) {} }
    }

    private fun speak(text: String, loud: Boolean, done: () -> Unit) {
        val t = tts ?: return done()
        t.setAudioAttributes(attributes(loud))
        t.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) {}
            override fun onDone(id: String?) = done()
            @Deprecated("") override fun onError(id: String?) = done()
        })
        t.speak(text, TextToSpeech.QUEUE_FLUSH, null, "hw-${System.currentTimeMillis()}")
    }

    private fun loop(ctx: Context, loud: Boolean) {
        player?.release(); player = null
        requestFocus(ctx, loud)
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val p = MediaPlayer()
        try {
            p.setAudioAttributes(attributes(loud))
            p.setDataSource(ctx, uri)
            p.isLooping = true
            p.setWakeMode(ctx, PowerManager.PARTIAL_WAKE_LOCK)
            p.prepare()
            p.start()
            player = p
        } catch (_: Exception) {
            p.release()
            // no ringtone to play: beeps
            try { ToneGenerator(AudioManager.STREAM_ALARM, 100).startTone(ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD, 4000) } catch (_: Exception) {}
        }
    }

    private fun vibrate(ctx: Context, repeat: Boolean) {
        val v = vibrator(ctx) ?: return
        val pattern = longArrayOf(0, 700, 300, 700, 300, 700, 900)
        v.vibrate(VibrationEffect.createWaveform(pattern, if (repeat) 0 else -1),
            AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
    }

    private fun requestFocus(ctx: Context, loud: Boolean) {
        val am = ctx.getSystemService(AudioManager::class.java) ?: return
        focus?.let { am.abandonAudioFocusRequest(it) }
        val r = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK).setAudioAttributes(attributes(loud)).build()
        am.requestAudioFocus(r)
        focus = r
    }

    fun stop(context: Context) {
        ringing = false
        pending.forEach { main.removeCallbacks(it) }; pending.clear()
        player?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        player = null
        tts?.stop()
        vibrator(context.applicationContext)?.cancel()
        val am = context.getSystemService(AudioManager::class.java)
        focus?.let { am?.abandonAudioFocusRequest(it) }
        focus = null
    }

    fun shutdown(context: Context) {
        stop(context)
        tts?.shutdown(); tts = null; ttsReady = false
    }
}
