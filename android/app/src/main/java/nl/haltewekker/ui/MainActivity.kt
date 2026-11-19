package nl.haltewekker.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import nl.haltewekker.App
import nl.haltewekker.ride.RideService
import nl.haltewekker.ride.RideStore
import nl.haltewekker.ui.screens.HomeScreen
import nl.haltewekker.ui.screens.PlanScreen
import nl.haltewekker.ui.screens.Perms
import nl.haltewekker.ui.screens.RideScreen
import nl.haltewekker.ui.screens.SettingsScreen
import nl.haltewekker.ui.screens.SetupScreen
import nl.haltewekker.ui.theme.HaltewekkerTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { HaltewekkerTheme { Root() } }
    }
}

private enum class Screen { HOME, PLAN, RIDE, SETTINGS, SETUP }

@Composable
private fun Root() {
    val context = LocalContext.current
    val app = context.applicationContext as App
    val profile by app.store.profile.collectAsState()
    val ride by RideStore.state.collectAsState()
    var screen by rememberSaveable { mutableStateOf(Screen.HOME) }
    var planDir by rememberSaveable { mutableStateOf<Direction?>(null) }
    var trouble by rememberSaveable { mutableStateOf<String?>(null) }

    LaunchedEffect(ride == null) { if (ride == null && screen == Screen.RIDE) screen = Screen.HOME }

    fun start(t: nl.haltewekker.data.DoorTrip, to: String) {
        if (!Perms.location(context)) { trouble = "Allow location first: the ride follows GPS to wake you."; screen = Screen.SETTINGS; return }
        RideService.start(context, t, to)
        screen = Screen.RIDE
    }

    if (!profile.setupDone || screen == Screen.SETUP) {
        SetupScreen(onDone = { screen = Screen.HOME })
        return
    }
    val r = ride
    when (screen) {
        Screen.HOME, Screen.SETUP -> HomeScreen(r, onPlan = { planDir = it; screen = Screen.PLAN }, onRide = { screen = Screen.RIDE },
            onStart = ::start, onSettings = { screen = Screen.SETTINGS })
        Screen.PLAN -> PlanScreen(planDir, canStart = r == null, onBack = { screen = Screen.HOME }, onStart = ::start)
        Screen.RIDE -> if (r != null) RideScreen(r, onBack = { screen = Screen.HOME }) else screen = Screen.HOME
        Screen.SETTINGS -> SettingsScreen(onBack = { trouble = null; screen = Screen.HOME }, onSetup = { screen = Screen.SETUP })
    }
}
