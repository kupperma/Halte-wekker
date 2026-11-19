package nl.haltewekker.ui

import android.content.Intent
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
import kotlinx.coroutines.flow.MutableStateFlow
import nl.haltewekker.App
import nl.haltewekker.auto.ResumeStore
import nl.haltewekker.profile.TestSetup
import nl.haltewekker.ride.Notifications
import nl.haltewekker.ride.Phase
import nl.haltewekker.ride.RideService
import nl.haltewekker.ride.RideStore
import nl.haltewekker.school.SchoolAlarm
import nl.haltewekker.school.WakeService
import nl.haltewekker.ui.screens.CalendarsScreen
import nl.haltewekker.ui.screens.DayScreen
import nl.haltewekker.ui.screens.HomeScreen
import nl.haltewekker.ui.screens.PlanScreen
import nl.haltewekker.ui.screens.Perms
import nl.haltewekker.ui.screens.RideScreen
import nl.haltewekker.ui.screens.SettingsScreen
import nl.haltewekker.ui.screens.SetupScreen
import nl.haltewekker.ui.screens.WeekScreen
import nl.haltewekker.ui.theme.HaltewekkerTheme

class MainActivity : ComponentActivity() {
    companion object {
        const val EXTRA_SCREEN = "screen"
        const val SCREEN_DAY = "day"
        const val EXTRA_STOP_WAKE = "stopWake"
        /** A screen asked for from outside (the alarm's Open, a notification). */
        val asked = MutableStateFlow<String?>(null)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handle(intent)
        setContent { HaltewekkerTheme { Root() } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(i: Intent?) {
        if (i == null) return
        // the alarm's Open stops it (iOS 0.24.6 had an Open that left it ringing)
        if (i.getBooleanExtra(EXTRA_STOP_WAKE, false)) WakeService.stop(this)
        i.getStringExtra(EXTRA_SCREEN)?.let { asked.value = it }
    }

    override fun onResume() {
        super.onResume()
        // opening the app: you're up, so a school alarm still ringing stops; old notifications go
        WakeService.stop(this)
        Notifications.sweep(this)
        (application as App).launch { SchoolAlarm.refresh(this) }
    }
}

private enum class Screen { HOME, PLAN, RIDE, SETTINGS, SETUP, TEST_SETUP, DAY, CALENDARS, WEEK }

@Composable
private fun Root() {
    val context = LocalContext.current
    val app = context.applicationContext as App
    val profile by app.store.profile.collectAsState()
    val ride by RideStore.state.collectAsState()
    val asked by MainActivity.asked.collectAsState()
    var screen by rememberSaveable { mutableStateOf(Screen.HOME) }
    var planDir by rememberSaveable { mutableStateOf<Direction?>(null) }

    LaunchedEffect(ride == null) { if (ride == null && screen == Screen.RIDE) screen = Screen.HOME }
    // made smaller holds while it doesn't ring: the alarm opens the ride full again (iOS RideBar.keepsSmall)
    LaunchedEffect(ride?.phase) { if (ride?.phase == Phase.ALARM && screen != Screen.SETUP && screen != Screen.TEST_SETUP) screen = Screen.RIDE }
    LaunchedEffect(asked) {
        if (asked == MainActivity.SCREEN_DAY && profile.setupDone) screen = Screen.DAY
        MainActivity.asked.value = null
    }

    fun start(t: nl.haltewekker.data.DoorTrip, to: String, index: Int = 0) {
        if (!Perms.location(context)) { screen = Screen.SETTINGS; return }
        RideService.start(context, t, to, index)
        screen = Screen.RIDE
    }

    if (screen == Screen.TEST_SETUP) {
        SetupScreen(test = true, onDone = { screen = Screen.HOME }, onCancel = { TestSetup.cancel(context); screen = Screen.SETTINGS })
        return
    }
    if (!profile.setupDone || screen == Screen.SETUP) {
        SetupScreen(onDone = { screen = Screen.HOME }, onCancel = if (profile.setupDone) ({ screen = Screen.SETTINGS }) else null)
        return
    }
    val r = ride
    when (screen) {
        Screen.HOME, Screen.SETUP, Screen.TEST_SETUP -> HomeScreen(r, onPlan = { planDir = it; screen = Screen.PLAN }, onRide = { screen = Screen.RIDE },
            onStart = { t, to -> start(t, to) }, onSettings = { screen = Screen.SETTINGS }, onDay = { screen = Screen.DAY },
            onResume = { o -> ResumeStore.set(context, null); start(o.trip, o.destination, o.leg) })
        Screen.PLAN -> PlanScreen(planDir, canStart = r == null, onBack = { screen = Screen.HOME }, onStart = { t, to -> start(t, to) })
        Screen.RIDE -> if (r != null) RideScreen(r, onBack = { screen = Screen.HOME }) else screen = Screen.HOME
        Screen.SETTINGS -> SettingsScreen(onBack = { screen = Screen.HOME }, onSetup = { screen = Screen.SETUP },
            onTestSetup = { if (TestSetup.start(context)) screen = Screen.TEST_SETUP }, onDay = { screen = Screen.DAY },
            onCalendars = { screen = Screen.CALENDARS }, onWeek = { screen = Screen.WEEK })
        Screen.DAY -> DayScreen(onBack = { screen = Screen.HOME }, onSettings = { screen = Screen.SETTINGS }, canStart = r == null,
            onStart = { t, to -> start(t, to) })
        Screen.CALENDARS -> CalendarsScreen(onBack = { screen = Screen.SETTINGS })
        Screen.WEEK -> WeekScreen(onBack = { screen = Screen.SETTINGS })
    }
}
