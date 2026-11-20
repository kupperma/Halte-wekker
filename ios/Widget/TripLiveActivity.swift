import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct HaltewekkerWidgets: WidgetBundle {
    var body: some Widget {
        TripLiveActivity()
        StopBoardWidget()               // (0.37) the next departures from a stop you pick
    }
}

private let hhmm: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = TimeZone(identifier: "Europe/Amsterdam"); return f
}()

private typealias TripState = TripAttributes.ContentState

private func riding(_ s: TripState) -> Bool { !["CHANGE HERE", "YOU’RE THERE"].contains(s.kicker) }
/// The countdown, the part of the track done and your stop's dot: the accent, warm while it's waking you.
private func stateTint(_ s: TripState, _ look: LiveLook) -> Color { s.awake ? look.warning : look.accent }

/// What the state says over the main line, when it isn't just riding: its words, an icon, and whether it's warm.
private func status(_ s: TripState) -> (text: String, icon: String, warm: Bool)? {
    switch s.kicker {
    case "NOW RIDING": return nil
    case "WAITING TO BOARD": return ("Waiting to board", "clock", false)
    case "GET READY": return ("Get ready", "bell.fill", true)
    case "WAKE UP": return ("Wake up", "alarm.fill", true)
    case "GET OFF NOW": return ("Get off now", "bell.fill", true)
    case "CHANGE HERE": return ("Change here", "arrow.triangle.swap", false)
    case "YOU’RE THERE": return ("You’re there", "checkmark.circle.fill", false)
    default:
        if s.kicker.isEmpty { return nil }
        return (text: s.kicker.capitalized, icon: "info.circle.fill", warm: s.awake)
    }
}

/// The big line: "Get off at Breda · 16:22" while riding; "Change at Breda" at a change; where you are at the end.
private func mainLine(_ s: TripState) -> String {
    switch s.kicker {
    case "CHANGE HERE": return s.legTitle
    case "YOU’RE THERE": return s.stopName.isEmpty ? s.finalName : s.stopName
    default:
        guard !s.stopName.isEmpty else { return s.legTitle }
        return "Get off at \(s.stopName)" + (s.legTo.map { " · \(hhmm.string(from: $0))" } ?? "")
    }
}

/// Under the track, on the left: the song while riding (as before), else the next ride ("Then bus 5 at 16:27").
/// At a change the next ride comes first: it's what you need there.
private enum Footnote { case song, next(String), change(String, warm: Bool) }
private func footnote(_ s: TripState) -> Footnote? {
    // (0.39) a change ahead comes first: the platforms, the walk, the minutes, or that you'll miss it and what instead
    if let c = s.changeLine, s.kicker != "YOU’RE THERE" { return .change(c, warm: s.changeMiss != nil) }
    if riding(s) {
        if s.song != nil { return .song }
        return s.nextText.map { .next($0) }
    }
    if let n = s.nextText { return .next(n) }
    return s.song != nil ? .song : nil
}

/// A small icon for the vehicle in the Dynamic Island's compact and minimal views.
private func glyph(_ k: VehicleKind) -> String {
    switch k {
    case .bus: return "bus.fill"
    case .ic, .train: return "train.side.front.car"
    case .sprinter, .metro: return "tram.fill"
    case .tram: return "lightrail.fill"
    }
}

struct Countdown: View {
    let to: Date?
    var body: some View {
        if let a = to, a > Date() {
            Text(timerInterval: Date()...a, countsDown: true, showsHours: true).monospacedDigit().multilineTextAlignment(.trailing)
        } else { Text("–") }
    }
}

/// A line's pill, like the app's: an orange bus pill with its number, indigo for an intercity ("IC"), cyan for a sprinter ("SPR").
struct LivePill: View {
    let s: TripAttributes.ContentState
    let look: LiveLook
    var size: CGFloat = 14
    var body: some View {
        Text(VehicleKind.pillText(line: s.line, kind: s.kind))
            .font(.system(size: size, weight: .bold)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.45).padding(.vertical, size * 0.15)
            .frame(minWidth: size * 2.4)
            .background(look.pill(s.kind), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
            .accessibilityLabel(s.kind == .bus ? "Bus \(s.line)" : VehicleKind.pillText(line: s.line, kind: s.kind))
    }
}

/// The state's words with their icon ("Wake up", "Change here"…), warm or in the accent.
private struct StatusLabel: View {
    let text: String, icon: String, color: Color
    var size: CGFloat = 15
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: size - 1, weight: .bold))
            Text(text).font(.system(size: size, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

/// The top of the trip: the line's pill and "to Breda", or the state's words. `detail` (the lock screen, 0.39): the next
/// stop, the delay and the platform instead of "to Breda" (the big line says where already).
private struct TripHeading: View {
    let s: TripAttributes.ContentState
    let look: LiveLook
    var size: CGFloat = 15
    var detail = false
    var body: some View {
        HStack(spacing: 8) {
            if riding(s) { LivePill(s: s, look: look, size: size - 1) }
            if let st = status(s) {
                StatusLabel(text: st.text, icon: st.icon, color: st.warm ? look.warning : look.accent, size: size)
            } else if detail, let r = s.rideLine {
                Text(r).font(.system(size: size - 1, weight: .semibold)).monospacedDigit()
                    .foregroundStyle((s.delay ?? 0) >= 3 ? look.warning : look.secondary).lineLimit(1)
            } else if !s.stopName.isEmpty {
                Text("to \(s.stopName)").font(.system(size: size, weight: .semibold)).foregroundStyle(look.secondary).lineLimit(1)
            }
        }
        .minimumScaleFactor(0.75)
    }
}

struct SongLine: View {
    let s: TripAttributes.ContentState
    let look: LiveLook
    var size: CGFloat = 13
    var body: some View {
        if let song = s.song {
            HStack(spacing: 5) {
                Image(systemName: s.songPlaying ? "music.note" : "pause.fill").font(.system(size: size - 2, weight: .bold)).foregroundStyle(look.accent)
                Text(song).font(.system(size: size, weight: .semibold)).foregroundStyle(look.text).lineLimit(1).layoutPriority(1)
                if let a = s.artist, !a.isEmpty { Text("· \(a)").font(.system(size: size)).foregroundStyle(look.secondary).lineLimit(1) }
            }
        }
    }
}

/// Under the track: the song or the next ride on the left, your last stop and when you're there on the right.
private struct TripFooter: View {
    let s: TripAttributes.ContentState
    let look: LiveLook
    var size: CGFloat = 13
    var showArrival = true
    var body: some View {
        HStack(spacing: 8) {
            if let f = footnote(s) {
                switch f {
                case .song: SongLine(s: s, look: look, size: size)
                case .next(let n): Text(n).font(.system(size: size, weight: .medium)).foregroundStyle(look.secondary).lineLimit(1)
                case .change(let c, let warm):
                    ChangeLine(text: c, leaves: s.kicker == "CHANGE HERE" ? s.changeLeaves : nil, warm: warm, look: look, size: size)
                }
            }
            Spacer(minLength: 6)
            if showArrival, let a = s.arrival {
                Text("\(s.finalName) \(hhmm.string(from: a))").font(.system(size: size, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(look.text).lineLimit(1).fixedSize().layoutPriority(2)
            }
        }
    }
}

/// (0.39) The change ahead: "Platform 5 → 7 · 3 min walk · 4 min to change", or that you'll miss it; at the change
/// itself the time to when the next one leaves, running.
private struct ChangeLine: View {
    let text: String
    let leaves: Date?
    let warm: Bool
    let look: LiveLook
    var size: CGFloat = 13
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: warm ? "exclamationmark.triangle.fill" : "arrow.triangle.swap")
                .font(.system(size: size - 1, weight: .bold)).foregroundStyle(warm ? look.warning : look.accent)
            Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(warm ? look.warning : look.text)
                .lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
            if let l = leaves, l > Date() {
                Text(timerInterval: Date()...l, countsDown: true, showsHours: false).monospacedDigit()
                    .font(.system(size: size, weight: .bold)).foregroundStyle(look.accent).fixedSize()
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
                .font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, size * 0.5)
                .background(Color(hex: DSCore.warning), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The lock screen: the line and where it goes, the countdown to your stop, the stop, the track with the vehicle on
/// it, and the song or the next ride. Light or dark with the phone.
struct LockScreenTrip: View {
    let s: TripAttributes.ContentState
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let look = LiveLook.of(scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    TripHeading(s: s, look: look, detail: true)
                    Text(mainLine(s)).font(.system(size: 20, weight: .bold)).monospacedDigit().foregroundStyle(look.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)
                if riding(s) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Countdown(to: s.legTo ?? s.arrival).font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(stateTint(s, look)).frame(maxWidth: 104, alignment: .trailing)
                        Text(s.distanceText.isEmpty || s.distanceText == "–" ? "to go" : "\(s.distanceText) to go")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(look.secondary).lineLimit(1)
                    }
                }
            }
            RideTrack(progress: s.progress, kind: s.kind, stops: s.stops, look: look, tint: stateTint(s, look))
                .frame(height: 28)
                .id(s.stopName)                              // a new leg: a new vehicle rolls in
            if s.ringing { StopButton(size: 15) }
            else { TripFooter(s: s, look: look) }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(look.surface)
        .activityBackgroundTint(look.surface)
        .activitySystemActionForegroundColor(look.text)
    }
}

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripAttributes.self) { ctx in
            LockScreenTrip(s: ctx.state)
        } dynamicIsland: { ctx in
            let s = ctx.state, look = LiveLook.islandLook
            return DynamicIsland {
                // The regions beside the camera are narrow: short, and allowed to shrink a little.
                DynamicIslandExpandedRegion(.leading) {
                    TripHeading(s: s, look: look, size: 14).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if riding(s) {
                            Countdown(to: s.legTo ?? s.arrival).font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(stateTint(s, look)).frame(maxWidth: 88, alignment: .trailing)
                        } else {
                            Text(s.arrival.map { hhmm.string(from: $0) } ?? "–").font(.system(size: 20, weight: .bold, design: .rounded))
                                .monospacedDigit().foregroundStyle(look.text).lineLimit(1)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mainLine(s)).font(.system(size: 16, weight: .bold)).monospacedDigit().foregroundStyle(look.text)
                            .lineLimit(1).minimumScaleFactor(0.75)
                        RideTrack(progress: s.progress, kind: s.kind, stops: s.stops, look: look, tint: stateTint(s, look))
                            .frame(height: 24).id(s.stopName)
                        if s.ringing { StopButton(size: 14) }
                        else { TripFooter(s: s, look: look, size: 12, showArrival: riding(s)) }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: glyph(s.kind)).font(.system(size: 13, weight: .semibold)).foregroundStyle(look.glyph(s.kind))
                    Text(VehicleKind.pillText(line: s.line, kind: s.kind)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                        .foregroundStyle(look.text).lineLimit(1)
                }
            } compactTrailing: {
                if riding(s) {
                    Countdown(to: s.legTo ?? s.arrival).font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(stateTint(s, look)).frame(maxWidth: 46, alignment: .trailing)
                } else if let st = status(s) {
                    Image(systemName: st.icon).font(.system(size: 13, weight: .bold)).foregroundStyle(look.accent)
                }
            } minimal: {
                if s.ringing {
                    Image(systemName: "bell.fill").foregroundStyle(look.warning)
                } else {
                    Image(systemName: glyph(s.kind)).foregroundStyle(look.glyph(s.kind))
                }
            }
            .keylineTint(look.accent)
        }
    }
}
