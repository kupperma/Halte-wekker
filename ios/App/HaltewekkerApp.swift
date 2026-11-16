import AVFoundation
import SwiftUI

@main
struct HaltewekkerApp: App {
    @StateObject private var trip = TripManager()
    @StateObject private var live = LiveStore()
    @StateObject private var planner = Planner()
    @StateObject private var near = NearMe()
    init() {
        Watchdog.shared.start()
        Net.startWatchingConnection()
        // the map on the wall and the station, read and decoded off the main thread while the rest starts
        StillCache.shared.warm()
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(trip).environmentObject(live).environmentObject(trip.music)
                .environmentObject(planner).environmentObject(near)
                .environmentObject(NSStore.shared).environmentObject(WatchStore.shared)
                .environmentObject(ScoreBook.shared).environmentObject(StopsStore.shared).environmentObject(LineWatchStore.shared)
                .environmentObject(GoStore.shared)
                .onOpenURL { url in Task { await trip.music.finish(url) } }      // back from the Spotify sign-in page
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
