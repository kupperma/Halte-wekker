import SwiftUI

@main
struct HaltewekkerApp: App {
    @StateObject private var trip = TripManager()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(trip)
        }
    }
}
