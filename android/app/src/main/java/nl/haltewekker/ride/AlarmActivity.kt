package nl.haltewekker.ride

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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Fmt
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.HaltewekkerTheme

/** The alarm screen, over the lock screen (the alarm notification's full-screen intent). A volume key stops it too. */
class AlarmActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true) }
        else @Suppress("DEPRECATION") window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        RideStore.load(this)
        setContent {
            HaltewekkerTheme {
                val s by RideStore.state.collectAsState()
                LaunchedEffect(s?.phase) { if (s?.phase != Phase.ALARM) finish() }
                val leg = s?.leg
                Column(Modifier.fillMaxSize().background(Color(0xFF14171A)).safeDrawingPadding().padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Wake up", color = Color(0xFFFF8A5C), fontSize = 48.sp, fontWeight = FontWeight.Bold)
                    Text(leg?.toStop ?: "Your stop", color = Color.White, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
                    Text("in about ${Fmt.metres(s?.distance ?: s?.wakeMetres ?: 0.0)}" + (s?.legArrival?.let { " · ${Fmt.time(it)}" } ?: ""),
                        color = Color(0xFFA3ABB3), textAlign = TextAlign.Center)
                    if (s?.quiet == true) Text("No headphones: vibrating only, until you stop it.", color = Color(0xFFA3ABB3), textAlign = TextAlign.Center)
                    Spacer(Modifier.height(24.dp))
                    BigButton("I'm awake") { RideService.send(this@AlarmActivity, RideService.ACTION_STOP_ALARM); finish() }
                    QuietButton("End the trip") { RideService.send(this@AlarmActivity, RideService.ACTION_END); finish() }
                }
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            RideService.send(this, RideService.ACTION_STOP_ALARM); finish(); return true
        }
        return super.onKeyDown(keyCode, event)
    }
}
