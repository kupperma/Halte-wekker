import AVFoundation
import SwiftUI

@main
struct HaltewekkerApp: App {
    @StateObject private var trip = TripManager()
    @StateObject private var live = LiveStore()
    init() {
        // The station video is silent and must never stop your music.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(trip).environmentObject(live)
        }
    }
}
