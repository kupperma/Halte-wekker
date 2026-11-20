import AVFoundation
import SwiftUI

@main
struct HaltewekkerApp: App {
    @StateObject private var trip = TripManager()
    @StateObject private var live = LiveStore()
    @StateObject private var planner = Planner()
    @StateObject private var near = NearMe()
    @Environment(\.scenePhase) private var scenePhase
    init() {
        // The profile first (before anything saves a key, so a new install is told from an earlier version's user),
        // then your places and stops: the roles (`Place.home`, `.school`) are yours from the first thing that plans,
        // a background wake-up for the school alarm too.
        // A "Test the setup as a new user" that the app stopped in the middle of goes back first (0.23).
        MainActor.assumeIsolated {
            let recovered = SetupStore.recoverAtLaunch()
            _ = ProfileStore.shared
            _ = PlacesStore.shared
            _ = StopsStore.shared
            if recovered {
                SnapshotStore.shared.prune(olderThan: 0)
                Task { await SchoolAlarm.shared.refresh(force: true, now: true) }
            }
        }
        Watchdog.shared.start()
        Net.startWatchingConnection()
        // the map on the wall and the station, read and decoded off the main thread while the rest starts
        StillCache.shared.warm()
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(AppActionsHandler())          // (0.37) Siri and Shortcuts: Fastest trip, Start my trip
                .environmentObject(trip).environmentObject(live).environmentObject(trip.music)
                .environmentObject(planner).environmentObject(near)
                .environmentObject(NSStore.shared).environmentObject(WatchStore.shared)
                .environmentObject(ScoreBook.shared).environmentObject(StopsStore.shared).environmentObject(LineWatchStore.shared)
                .environmentObject(GoStore.shared)
                .onOpenURL { url in
                    // a friend's code (haltewekker://friend?…, 0.25), else back from the Spotify sign-in page
                    if FriendStore.shared.handle(url) { return }
                    // (0.37) the widget's tap: haltewekker://stop?… opens that stop's sheet
                    if let a = IntentActions.action(url) { AppActions.shared.post(a); return }
                    Task { await trip.music.finish(url) }
                }
                // Friends (0.25): requests are fetched when the app comes to the front (only with an account; no push)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await FriendStore.shared.sync(.auto) }
                    // (0.28.1: shared ride logs, only when you turned it on; at most once an hour)
                    LogShareStore.shared.tick()
                    // (0.36) works on your routes (at most every 4 h), the last way home (hourly, evenings away)
                    Task { await TravelNotes.shared.tick() }
                }
                .onAppear {
                    Watchdog.shared.mark("drawing the first screen")
                    let t = trip
                    // The station video is silent and must never stop your music: after the first frame (a call to the
                    // audio daemon that can take a while), and not over a trip's own sound that started meanwhile.
                    DispatchQueue.main.async {
                        Watchdog.shared.mark("setting up sound")
                        if t.phase == .idle { t.sound.idleCategory() }
                        Watchdog.shared.mark("drawing the first screen")
                    }
                    near.onPosition = { t.guessFromPlace($0); t.maybeAutoHome($0) }
                    // Friends (0.26): your trip to the friends you show it to, watched from the trip (it changes nothing)
                    FriendTravelShare.shared.attach(t)
                    // (0.29) the Friends extras: region events (at school, leaving home) and the trip's start, read only
                    FriendExtrasStore.shared.attach(t)
                    // (0.30) the live link for people without the app: ends with the trip, read only
                    LiveLinkStore.shared.attach(t)
                    // (0.36) the travel help: where you are, for the last way home
                    TravelNotes.shared.trip = t
                    // (0.28.1) shared ride logs: a trip that ended is a moment to send (only when turned on)
                    LogShareStore.shared.attach(t)
                    Task { await NoticeLog.shared.collectDelivered() }
                    Morning.shared.checkAfterAlarm()
                    // (Recomp is parked since 0.19: its data stays on the phone, untouched, and nothing in the app
                    // opens it or posts its calorie notice)
                }
        }
        .backgroundTask(.appRefresh(SchoolAlarm.backgroundId)) {
            await SchoolAlarm.backgroundRefresh()
        }
    }
}
