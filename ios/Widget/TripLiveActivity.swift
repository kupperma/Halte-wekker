import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HaltewekkerWidgets: WidgetBundle {
    var body: some Widget { TripLiveActivity() }
}

private let hhmm: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = TimeZone(identifier: "Europe/Amsterdam"); return f
}()

private func accent(_ s: TripAttributes.ContentState) -> Color {
    s.awake ? .orange : (s.goingHome ? Color(red: 1, green: 0.62, blue: 0.72) : Color(red: 0.6, green: 0.65, blue: 1))
}

struct Countdown: View {
    let arrival: Date?
    var body: some View {
        if let a = arrival, a > Date() {
            Text(timerInterval: Date()...a, countsDown: true, showsHours: true).monospacedDigit()
        } else { Text("–") }
    }
}

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripAttributes.self) { ctx in
            let s = ctx.state
            HStack(spacing: 14) {
                Image(systemName: s.isTrain ? "tram.fill" : "bus.fill")
                    .font(.title2).frame(width: 46, height: 46)
                    .background(accent(s).opacity(0.25), in: Circle()).foregroundStyle(accent(s))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.legTitle).font(.headline).lineLimit(1)
                    Text("\(s.distanceText) to go").font(.subheadline).foregroundStyle(.secondary)
                    if let n = s.nextText { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(s.arrival.map { "\(s.finalName) \(hhmm.string(from: $0))" } ?? s.finalName).font(.headline)
                    Countdown(arrival: s.arrival).font(.subheadline).foregroundStyle(accent(s)).frame(maxWidth: 90, alignment: .trailing)
                }
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(s.distanceText, systemImage: s.isTrain ? "tram.fill" : "bus.fill")
                        .font(.headline).foregroundStyle(accent(s))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(s.arrival.map { "\(s.finalName) \(hhmm.string(from: $0))" } ?? s.finalName).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.legTitle).font(.title3.weight(.semibold)).lineLimit(1)
                        HStack {
                            if let n = s.nextText { Text(n).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Countdown(arrival: s.arrival).foregroundStyle(accent(s))
                        }.font(.subheadline)
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: s.isTrain ? "tram.fill" : "bus.fill").foregroundStyle(accent(s))
                    Text(s.distanceText).font(.caption2.weight(.semibold))
                }
            } compactTrailing: {
                Text(s.arrival.map { hhmm.string(from: $0) } ?? "–").font(.caption2.weight(.semibold)).foregroundStyle(accent(s))
            } minimal: {
                Image(systemName: s.isTrain ? "tram.fill" : "bus.fill").foregroundStyle(accent(s))
            }
        }
    }
}
