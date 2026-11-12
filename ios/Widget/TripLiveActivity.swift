import ActivityKit
import AppIntents
import SwiftUI
import UIKit
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
private func riding(_ s: TripAttributes.ContentState) -> Bool { !["CHANGE HERE", "YOU’RE THERE"].contains(s.kicker) }

/// The empty platform behind the lock screen trip (the metro drives in along the bottom).
private let platforms: [Bool: UIImage] = {
    var out: [Bool: UIImage] = [:]
    for (home, name) in [(false, "ls-out"), (true, "ls-home")] {
        if let p = Bundle.main.path(forResource: name, ofType: "jpg"), let img = UIImage(contentsOfFile: p) { out[home] = img }
    }
    return out
}()

struct Countdown: View {
    let to: Date?
    var body: some View {
        if let a = to, a > Date() {
            Text(timerInterval: Date()...a, countsDown: true, showsHours: true).monospacedDigit().multilineTextAlignment(.trailing)
        } else { Text("–") }
    }
}

struct SongLine: View {
    let s: TripAttributes.ContentState
    var size: CGFloat = 11
    var body: some View {
        if let song = s.song {
            HStack(spacing: 6) {
                Image(systemName: s.songPlaying ? "music.note" : "pause.fill").font(.system(size: size - 1, weight: .bold)).foregroundStyle(pal(s).accent)
                Text(song).font(HWFont.body(size, bold: true)).foregroundStyle(HWPalette.ink).lineLimit(1).layoutPriority(1)
                if let a = s.artist, !a.isEmpty { Text("· \(a)").font(HWFont.body(size)).foregroundStyle(HWPalette.muted).lineLimit(1) }
                Spacer(minLength: 4)
                if let app = s.musicApp { Text(app.uppercased()).font(HWFont.body(size - 3)).tracking(1).foregroundStyle(HWPalette.muted).lineLimit(1) }
            }
        }
    }
}

/// Stops the alarm without opening the app.
struct StopButton: View {
    var size: CGFloat = 15
    var body: some View {
        Button(intent: StopAlarmIntent()) {
            Label("Stop alarm", systemImage: "bell.slash.fill")
                .font(HWFont.display(size)).foregroundStyle(Color(hex: 0x1A0C08))
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(HWPalette.warn, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

/// The lock screen: a small version of the ride screen, with the song you're listening to.
struct LockScreenTrip: View {
    let s: TripAttributes.ContentState
    var body: some View {
        let p = pal(s)
        let parts = s.distanceText.split(separator: " ").map(String.init)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: s.isTrain ? "tram.fill" : "bus.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent(s))
                Text(s.kicker).font(HWFont.body(10, bold: true)).tracking(1.3).foregroundStyle(accent(s)).lineLimit(1).layoutPriority(1)
                if riding(s) { Text("· \(s.legTitle.uppercased())").font(HWFont.body(10)).tracking(1).foregroundStyle(HWPalette.ink.opacity(0.85)).lineLimit(1) }
                Spacer(minLength: 4)
                if let a = s.arrival {
                    Text("\(s.finalName.uppercased()) \(hhmm.string(from: a))").font(HWFont.display(13)).foregroundStyle(HWPalette.ink).lineLimit(1)
                        .fixedSize().layoutPriority(2)
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                if riding(s) {
                    Text(parts.first ?? "–").font(HWFont.display(40)).foregroundStyle(HWPalette.ink).monospacedDigit()
                        .shadow(color: p.accent.opacity(0.5), radius: 10).contentTransition(.numericText())
                    VStack(alignment: .leading, spacing: 0) {
                        Text((parts.count > 1 ? parts[1] : "").uppercased()).font(HWFont.display(12))
                        Text("TO \(s.stopName.uppercased())").font(HWFont.display(11)).tracking(1.4).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(p.accent)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.legTitle).font(HWFont.display(24)).foregroundStyle(HWPalette.ink).lineLimit(1).minimumScaleFactor(0.7)
                        if let n = s.nextText { Text(n).font(HWFont.body(11)).foregroundStyle(HWPalette.ink.opacity(0.8)).lineLimit(1) }
                    }
                }
                Spacer(minLength: 4)
                if riding(s) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Countdown(to: s.legTo ?? s.arrival).font(HWFont.body(15, bold: true)).foregroundStyle(accent(s)).frame(maxWidth: 74, alignment: .trailing)
                        Text("TO GO").font(HWFont.body(9)).tracking(1).foregroundStyle(HWPalette.muted)
                    }
                }
            }
            MetroTrack(progress: s.progress, home: s.goingHome)
                .frame(height: 24)
                .id(s.stopName)                              // a new leg: a new metro rolls in
            if s.ringing { StopButton(size: 15) }
            else if s.song != nil { SongLine(s: s) }
            else if riding(s), let n = s.nextText { Text(n).font(HWFont.body(11)).foregroundStyle(HWPalette.muted).lineLimit(1) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background {
            ZStack {
                LinearGradient(colors: [p.paper, p.paper2], startPoint: .top, endPoint: .bottom)
                if let img = platforms[s.goingHome] { Image(uiImage: img).resizable().scaledToFill() }
                LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.5), .black.opacity(0.25)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 2).inset(by: 5).stroke(p.brass.opacity(0.9), lineWidth: 1))
    }
}

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripAttributes.self) { ctx in
            LockScreenTrip(s: ctx.state)
                .activityBackgroundTint(pal(ctx.state).paper2)
                .activitySystemActionForegroundColor(HWPalette.ink)
        } dynamicIsland: { ctx in
            let s = ctx.state, p = pal(s)
            return DynamicIsland {
                // The regions beside the camera are narrow: short, and allowed to shrink a little.
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Image(systemName: s.isTrain ? "tram.fill" : "bus.fill").font(.system(size: 15, weight: .semibold))
                        Text(s.distanceText).font(HWFont.display(16)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(accent(s)).padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(s.arrival.map { hhmm.string(from: $0) } ?? "–").font(HWFont.display(16)).foregroundStyle(HWPalette.ink)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(s.finalName.uppercased()).font(HWFont.body(8)).tracking(1).foregroundStyle(HWPalette.muted).lineLimit(1)
                    }
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(s.legTitle).font(HWFont.display(17)).foregroundStyle(HWPalette.ink).lineLimit(1).minimumScaleFactor(0.75)
                            Spacer(minLength: 4)
                            Countdown(to: s.legTo ?? s.arrival).font(HWFont.body(12, bold: true)).foregroundStyle(p.accent).frame(maxWidth: 70, alignment: .trailing)
                        }
                        MetroTrack(progress: s.progress, home: s.goingHome).frame(height: 18).id(s.stopName)
                        if s.ringing { StopButton(size: 14) }
                        else if s.song != nil { SongLine(s: s, size: 10) }
                        else if let n = s.nextText { Text(n).font(HWFont.body(11)).foregroundStyle(HWPalette.muted).lineLimit(1) }
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
