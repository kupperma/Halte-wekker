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

private func pal(_ s: TripAttributes.ContentState) -> HWPalette { .of(home: s.goingHome) }
private func accent(_ s: TripAttributes.ContentState) -> Color { s.awake ? HWPalette.warn : pal(s).accent }

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
            let s = ctx.state, p = pal(s)
            HStack(spacing: 12) {
                Image(systemName: s.isTrain ? "tram.fill" : "bus.fill")
                    .font(.system(size: 18)).frame(width: 44, height: 44)
                    .overlay(Circle().stroke(p.brass, lineWidth: 1.5)).foregroundStyle(p.brass)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.legTitle).font(HWFont.display(17)).foregroundStyle(HWPalette.ink).lineLimit(1)
                    Text("\(s.distanceText) to go").font(HWFont.body(12)).foregroundStyle(HWPalette.ink.opacity(0.8))
                    if let n = s.nextText { Text(n).font(HWFont.body(11)).foregroundStyle(HWPalette.muted).lineLimit(1) }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(s.arrival.map { hhmm.string(from: $0) } ?? "–").font(HWFont.display(20)).foregroundStyle(HWPalette.ink)
                    Text(s.finalName.uppercased()).font(HWFont.body(10)).tracking(1.2).foregroundStyle(HWPalette.muted)
                    Countdown(arrival: s.arrival).font(HWFont.body(12, bold: true)).foregroundStyle(accent(s)).frame(maxWidth: 90, alignment: .trailing)
                }
            }
            .padding(14)
            .background(LinearGradient(colors: [p.paper, p.paper2], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 2).inset(by: 6).stroke(p.brass, lineWidth: 1.2))
            .activityBackgroundTint(p.paper2)
            .activitySystemActionForegroundColor(HWPalette.ink)
        } dynamicIsland: { ctx in
            let s = ctx.state, p = pal(s)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(s.distanceText, systemImage: s.isTrain ? "tram.fill" : "bus.fill")
                        .font(HWFont.display(16)).foregroundStyle(accent(s))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(s.finalName) \(s.arrival.map { hhmm.string(from: $0) } ?? "")").font(HWFont.display(16)).foregroundStyle(HWPalette.ink)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.legTitle).font(HWFont.display(18)).foregroundStyle(HWPalette.ink).lineLimit(1)
                        HStack {
                            if let n = s.nextText { Text(n).font(HWFont.body(11)).foregroundStyle(HWPalette.muted).lineLimit(1) }
                            Spacer()
                            Countdown(arrival: s.arrival).font(HWFont.body(12, bold: true)).foregroundStyle(p.accent)
                        }
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: s.isTrain ? "tram.fill" : "bus.fill").foregroundStyle(accent(s))
                    Text(s.distanceText).font(HWFont.body(11, bold: true)).foregroundStyle(HWPalette.ink)
                }
            } compactTrailing: {
                Text(s.arrival.map { hhmm.string(from: $0) } ?? "–").font(HWFont.display(13)).foregroundStyle(accent(s))
            } minimal: {
                Image(systemName: s.isTrain ? "tram.fill" : "bus.fill").foregroundStyle(accent(s))
            }
            .keylineTint(p.brass)
        }
    }
}
