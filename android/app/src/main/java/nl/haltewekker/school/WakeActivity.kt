package nl.haltewekker.school

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import nl.haltewekker.core.Iso
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Fmt
import nl.haltewekker.ui.MainActivity
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.HaltewekkerTheme

/** The school alarm over the lock screen: the time, when to leave, Stop and Open. A volume key stops it too. */
class WakeActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true) }
        else @Suppress("DEPRECATION") window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContent {
            HaltewekkerTheme {
                val r by WakeService.ringing.collectAsState()
                var now by remember { mutableDoubleStateOf(Iso.now()) }
                LaunchedEffect(Unit) { while (true) { now = Iso.now(); delay(5_000) } }
                LaunchedEffect(r == null) { if (r == null) { delay(400); if (WakeService.ringing.value == null) finish() } }
                Column(Modifier.fillMaxSize().background(Color(0xFF14171A)).safeDrawingPadding().padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(Fmt.time(now), color = Color.White, fontSize = 72.sp, fontWeight = FontWeight.Bold)
                    Text(r?.title ?: "Time to get up", color = Color(0xFF4CC792), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    r?.body?.takeIf { it.isNotEmpty() }?.let { Text(it, color = Color(0xFFA3ABB3), textAlign = TextAlign.Center) }
                    Spacer(Modifier.height(24.dp))
                    BigButton("Stop") { stopIt(); finish() }
                    QuietButton("Open") {
                        // Open stops the alarm first, then shows your day
                        stopIt()
                        startActivity(Intent(this@WakeActivity, MainActivity::class.java)
                            .putExtra(MainActivity.EXTRA_SCREEN, MainActivity.SCREEN_DAY).putExtra(MainActivity.EXTRA_STOP_WAKE, true)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP))
                        finish()
                    }
                }
            }
        }
    }

    private fun stopIt() = WakeService.stop(this)

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) { stopIt(); finish(); return true }
        return super.onKeyDown(keyCode, event)
    }
}
