import AVFoundation
import SwiftUI

@main
struct HaltewekkerApp: App {
    @StateObject private var trip = TripManager()
    @StateObject private var live = LiveStore()
    @StateObject private var planner = Planner()
    @StateObject private var near = NearMe()
    init() {
        // The station video is silent and must never stop your music.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
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
                    let t = trip
                    near.onPosition = { t.guessFromPlace($0); t.maybeAutoHome($0) }
                }
        }
    }
}
