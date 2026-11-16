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
        Watchdog.shared.start()
        Net.startWatchingConnection()
        Watchdog.shared.mark("setting up sound")
        // The station video is silent and must never stop your music.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        WorkoutStore.shared.bodyWeight = { WorkoutBody.kg(on: $0) }        // pull-ups and dips count with Recomp's weight
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
                .onChange(of: scenePhase) { _, phase in
                    // workouts read before the first unlock after a restart: read the files again now they can be
                    if phase == .active { WorkoutStore.shared.refresh() }
                }
                .onAppear {
                    Watchdog.shared.mark("drawing the first screen")
                    let t = trip
                    near.onPosition = { t.guessFromPlace($0); t.maybeAutoHome($0) }
                    Task { await NoticeLog.shared.collectDelivered() }
                    Morning.shared.checkAfterAlarm()
                    RecompStore.shared.limitReached = { total, limit, day in
                        RecompKcalNotice.post(total: total, limit: limit, day: day)
                    }
                }
        }
        .backgroundTask(.appRefresh(SchoolAlarm.backgroundId)) {
            await SchoolAlarm.backgroundRefresh()
        }
    }
}
