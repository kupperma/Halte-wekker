import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HaltewekkerWidgets: WidgetBundle {
    var body: some Widget { TripLiveActivity() }
}

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripAttributes.self) { ctx in
            Text(ctx.state.legTitle).padding()
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) { Text(ctx.state.legTitle) }
            } compactLeading: {
                Image(systemName: "tram.fill")
            } compactTrailing: {
                Text(ctx.state.distanceText)
            } minimal: {
                Image(systemName: "tram.fill")
            }
        }
    }
}
