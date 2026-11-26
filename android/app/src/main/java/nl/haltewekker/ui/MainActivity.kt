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
import androidx.compose.runtime.remember
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
        const val SCREEN_FRIENDS = "friends"
        const val EXTRA_STOP_WAKE = "stopWake"
        /** A screen asked for from outside (the alarm's Open, a notification). */
        val asked = MutableStateFlow<String?>(null)
        /** (A6) a shortcut (long-press the icon), and the widget's stop. */
        val shortcut = MutableStateFlow<String?>(null)
        val stop = MutableStateFlow<nl.haltewekker.widget.StopBoardCore.Stop?>(null)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handle(intent)
        nl.haltewekker.ui.Shortcuts.install(this)
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
        // A3: a friend link (haltewekker://friend?…, the https /add page) or a Friends notification
        val link = i.dataString
        if (link != null && nl.haltewekker.friends.FriendStore.handle(link)) asked.value = SCREEN_FRIENDS
        // (A6) the widget's tap (haltewekker://stop?…) and the app shortcuts
        if (link != null) (nl.haltewekker.widget.IntentActions.action(link) as? nl.haltewekker.widget.IntentActions.Action.ShowStop)?.let { stop.value = it.stop }
        if (i.action == nl.haltewekker.ui.Shortcuts.ACTION) shortcut.value = i.getStringExtra(nl.haltewekker.ui.Shortcuts.EXTRA)
        if (i.getBooleanExtra(nl.haltewekker.friends.FriendChats.EXTRA_FRIENDS, false)) {
            i.getStringExtra(nl.haltewekker.friends.FriendChats.EXTRA_CHAT)?.let { nl.haltewekker.friends.FriendChats.toOpen.value = it }
            asked.value = SCREEN_FRIENDS
        }
    }

    override fun onStart() {
        super.onStart()
        nl.haltewekker.friends.FriendChats.foreground = true
        nl.haltewekker.logs.LogShareStore.tick()          // (A4) shared ride logs: at most once an hour
    }

    override fun onStop() {
        super.onStop()
        nl.haltewekker.friends.FriendChats.foreground = false
    }

    override fun onResume() {
        super.onResume()
        // opening the app: you're up, so a school alarm still ringing stops; old notifications go
        WakeService.stop(this)
        Notifications.sweep(this)
        (application as App).launch { SchoolAlarm.refresh(this) }
        // A3: the app to the front checks the relay (at most every 20 s)
        nl.haltewekker.friends.FriendStore.sync(nl.haltewekker.friends.FriendStore.Why.AUTO)
    }
}

private enum class Screen { HOME, PLAN, RIDE, SETTINGS, SETUP, TEST_SETUP, DAY, CALENDARS, WEEK, FRIENDS, YEAR }

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
        if (asked == MainActivity.SCREEN_FRIENDS && profile.setupDone) screen = Screen.FRIENDS
        MainActivity.asked.value = null
    }

    fun start(t: nl.haltewekker.data.DoorTrip, to: String, index: Int = 0, resumed: nl.haltewekker.auto.ResumeOffer? = null) {
        if (!Perms.location(context)) { screen = Screen.SETTINGS; return }
        RideService.start(context, t, to, index, resumed)
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
            onResume = { o -> ResumeStore.set(context, null); start(o.trip, o.destination, o.leg, o) }, onFriends = { screen = Screen.FRIENDS },
            onYear = { screen = Screen.YEAR })
        Screen.PLAN -> PlanScreen(planDir, canStart = r == null, onBack = { screen = Screen.HOME }, onStart = { t, to -> start(t, to) })
        Screen.RIDE -> if (r != null) RideScreen(r, onBack = { screen = Screen.HOME }) else screen = Screen.HOME
        Screen.SETTINGS -> SettingsScreen(onBack = { screen = Screen.HOME }, onSetup = { screen = Screen.SETUP },
            onTestSetup = { if (TestSetup.start(context)) screen = Screen.TEST_SETUP }, onDay = { screen = Screen.DAY },
            onCalendars = { screen = Screen.CALENDARS }, onWeek = { screen = Screen.WEEK }, onFriends = { screen = Screen.FRIENDS },
            onYear = { screen = Screen.YEAR })
        Screen.YEAR -> nl.haltewekker.ui.screens.YearScreen(onBack = { screen = Screen.HOME })
        Screen.DAY -> DayScreen(onBack = { screen = Screen.HOME }, onSettings = { screen = Screen.SETTINGS }, canStart = r == null,
            onStart = { t, to -> start(t, to) })
        Screen.CALENDARS -> CalendarsScreen(onBack = { screen = Screen.SETTINGS })
        Screen.WEEK -> WeekScreen(onBack = { screen = Screen.SETTINGS })
        Screen.FRIENDS -> nl.haltewekker.ui.friends.FriendsScreen(onBack = { screen = Screen.HOME }, canStart = r == null, onStart = { t, to -> start(t, to) })
    }
    // (A6) the shortcuts and the widget's stop (nothing starts over a running trip: IntentActions)
    val sc by MainActivity.shortcut.collectAsState()
    val widgetStop by MainActivity.stop.collectAsState()
    var busNow by rememberSaveable { mutableStateOf(false) }
    var toast by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(sc, profile.setupDone) {
        val k = sc ?: return@LaunchedEffect
        if (!profile.setupDone) return@LaunchedEffect
        MainActivity.shortcut.value = null
        val idle = RideStore.state.value == null
        when (k) {
            nl.haltewekker.ui.Shortcuts.BUS -> busNow = true
            nl.haltewekker.ui.Shortcuts.SCHOOL, nl.haltewekker.ui.Shortcuts.HOME, nl.haltewekker.ui.Shortcuts.WAKE -> {
                val a = if (k == nl.haltewekker.ui.Shortcuts.WAKE) nl.haltewekker.widget.IntentActions.Action.StartTrip
                    else nl.haltewekker.widget.IntentActions.Action.Fastest(k == nl.haltewekker.ui.Shortcuts.SCHOOL)
                when (val o = nl.haltewekker.widget.IntentActions.outcome(a, idle)) {
                    is nl.haltewekker.widget.IntentActions.Outcome.Refuse -> { toast = o.why; screen = Screen.RIDE }
                    else -> {
                        planDir = when (k) { nl.haltewekker.ui.Shortcuts.HOME -> Direction.HOME; nl.haltewekker.ui.Shortcuts.SCHOOL -> Direction.TO_SCHOOL; else -> null }
                        screen = Screen.PLAN
                    }
                }
            }
            nl.haltewekker.ui.Shortcuts.START -> {
                val dir = if (java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY) < 12) Direction.TO_SCHOOL else Direction.HOME
                val dest = if (dir == Direction.TO_SCHOOL) profile.school else profile.home
                val here = Locator.last(context)
                val next = if (idle && dest != null && here != null) nl.haltewekker.data.Transit.tripsFrom(here, dest.planId, 3).firstOrNull() else null
                val s = nl.haltewekker.widget.IntentActions.start(idle, next?.first?.departure, nl.haltewekker.core.Iso.now())
                nl.haltewekker.widget.IntentActions.startText(s)?.let { toast = it }
                when (s) {
                    nl.haltewekker.widget.IntentActions.Start.ALREADY_RUNNING -> screen = Screen.RIDE
                    nl.haltewekker.widget.IntentActions.Start.START_NOW -> if (next != null && dest != null) start(next, if (dir == Direction.HOME) "Home" else dest.name)
                    else -> { planDir = dir; screen = Screen.PLAN }
                }
            }
        }
    }
    if (busNow) nl.haltewekker.ui.BusNowDialog { busNow = false }
    widgetStop?.let { s -> nl.haltewekker.ui.StopSheet(s) { MainActivity.stop.value = null } }
    toast?.let { t -> LaunchedEffect(t) { android.widget.Toast.makeText(context, t, android.widget.Toast.LENGTH_LONG).show(); toast = null } }
    nl.haltewekker.ui.friends.FriendBannerHost { chat -> chat?.let { nl.haltewekker.friends.FriendChats.toOpen.value = it }; screen = Screen.FRIENDS }
}
