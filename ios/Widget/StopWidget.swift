import AppIntents
import SwiftUI
import WidgetKit

// 0.37: the home-screen and lock-screen widget — the next departures from a stop you pick in the widget's own settings
// (Transitous's stop search), with live delays. It asks Transitous itself on its timeline (every 12 minutes or so, as
// WidgetKit allows), so it needs nothing from the app: no App Group. A tap opens the app on that stop.

struct PickStopIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Pick a stop"
    static var description = IntentDescription("The next buses and trains from a stop or station you pick.")

    @Parameter(title: "Stop")
    var stop: StopEntity?

    init() {}
}

struct StopBoardEntry: TimelineEntry {
    let date: Date
    let stop: StopBoardCore.Stop?
    let departures: [StopBoardCore.Departure]
    /// "Not refreshed" (an older answer), or nil.
    var note: String? = nil
}

/// The last answer per stop, in the widget's own defaults (not shared with the app): shown when Transitous doesn't
/// answer, for as long as it still has departures to come.
private enum BoardCache {
    static func load(_ id: String) -> [StopBoardCore.Departure]? {
        guard let d = UserDefaults.standard.data(forKey: "board." + id) else { return nil }
        return try? JSONDecoder().decode([StopBoardCore.Departure].self, from: d)
    }
    static func save(_ id: String, _ deps: [StopBoardCore.Departure]) {
        if let d = try? JSONEncoder().encode(deps) { UserDefaults.standard.set(d, forKey: "board." + id) }
    }
}

struct StopBoardProvider: AppIntentTimelineProvider {
    private static func count(_ f: WidgetFamily) -> Int {
        switch f {
        case .systemSmall: return 3
        case .systemMedium: return 4
        case .accessoryInline: return 1
        default: return 2
        }
    }

    static let sample: StopBoardEntry = {
        let now = Date()
        func d(_ line: String, _ to: String, _ m: Double, _ late: Double) -> StopBoardCore.Departure {
            .init(line: line, headsign: to, time: now.addingTimeInterval((m + late) * 60), scheduled: now.addingTimeInterval(m * 60),
                  live: true, cancelled: false, train: false)
        }
        return StopBoardEntry(date: now, stop: .init(id: "sample", name: "Veghel, Busstation", lat: 51.6, lon: 5.5),
                              departures: [d("305", "Den Bosch", 4, 2), d("306", "Uden", 15, 0), d("158", "Eindhoven", 22, 0), d("305", "Den Bosch", 34, 0)])
    }()

    func placeholder(in context: Context) -> StopBoardEntry { Self.sample }

    func snapshot(for configuration: PickStopIntent, in context: Context) async -> StopBoardEntry {
        guard let s = configuration.stop?.stop else { return context.isPreview ? Self.sample : StopBoardEntry(date: Date(), stop: nil, departures: []) }
        let now = Date()
        let deps = await StopBoardFetch.departures(s.id, from: now.addingTimeInterval(-60)) ?? BoardCache.load(s.id) ?? []
        return StopBoardEntry(date: now, stop: s, departures: StopBoardCore.upcoming(deps, at: now, count: Self.count(context.family)))
    }

    func timeline(for configuration: PickStopIntent, in context: Context) async -> Timeline<StopBoardEntry> {
        let now = Date()
        guard let s = configuration.stop?.stop else {
            return Timeline(entries: [StopBoardEntry(date: now, stop: nil, departures: [])], policy: .never)
        }
        let n = Self.count(context.family)
        let fresh = await StopBoardFetch.departures(s.id, from: now.addingTimeInterval(-60))
        if let fresh { BoardCache.save(s.id, fresh) }
        let deps = fresh ?? BoardCache.load(s.id) ?? []
        let t = StopBoardCore.timeline(deps, now: now, count: n)
        let note: String? = fresh == nil ? "Not refreshed" : nil
        let entries = t.entries.map { StopBoardEntry(date: $0.date, stop: s, departures: $0.departures, note: note) }
        // no answer: try again in 10 minutes, not at the end of what it had
        let reload = fresh == nil ? min(t.reloadAt, now.addingTimeInterval(10 * 60)) : t.reloadAt
        return Timeline(entries: entries, policy: .after(reload))
    }
}

private let hhmm: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
}()
private func hm(_ d: Date) -> String { hhmm.string(from: d) }

/// A short stop name: "Veghel, Busstation" stays; "Station Breda" is "Breda".
private func shortName(_ s: StopBoardCore.Stop) -> String {
    var n = s.name
    if n.hasPrefix("Station ") { n = String(n.dropFirst(8)) }
    return n
}

struct StopBoardView: View {
    let entry: StopBoardEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var look: LiveLook { LiveLook.of(scheme) }

    var body: some View {
        content
            .widgetURL(entry.stop.flatMap(StopBoardCore.link))
            .containerBackground(for: .widget) { look.surface }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        default: board
        }
    }

    // MARK: lock screen

    @ViewBuilder private var inline: some View {
        if let s = entry.stop, let d = entry.departures.first {
            Text("\(d.line) \(StopBoardCore.timeText(d, hhmm: hm)) · \(shortName(s))")
        } else if entry.stop != nil {
            Text("Nothing leaving soon")
        } else {
            Text("Pick a stop")
        }
    }

    @ViewBuilder private var rectangular: some View {
        if let s = entry.stop {
            VStack(alignment: .leading, spacing: 1) {
                Text(shortName(s)).font(.headline).lineLimit(1)
                if entry.departures.isEmpty {
                    Text("Nothing leaving soon").font(.caption)
                }
                ForEach(Array(entry.departures.prefix(2).enumerated()), id: \.offset) { _, d in
                    HStack(spacing: 4) {
                        Text(d.line).font(.caption.weight(.bold))
                        Text(d.headsign).font(.caption).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(StopBoardCore.timeText(d, hhmm: hm)).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Haltewekker").font(.headline)
                Text("Hold to edit and pick a stop").font(.caption)
            }
        }
    }

    // MARK: home screen

    @ViewBuilder private var board: some View {
        if let s = entry.stop {
            let rows = Array(entry.departures.prefix(family == .systemSmall ? 3 : 4))
            VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 6) {
                HStack(spacing: 5) {
                    Image(systemName: s.rail ? "tram.fill" : "bus.fill").font(.caption.weight(.bold)).foregroundStyle(look.accent)
                    Text(shortName(s)).font(.caption.weight(.bold)).foregroundStyle(look.text).lineLimit(1)
                    Spacer(minLength: 0)
                    if let n = entry.note {
                        Text(n).font(.caption2).foregroundStyle(look.secondary).lineLimit(1)
                    }
                }
                if rows.isEmpty {
                    Spacer(minLength: 0)
                    Text("Nothing leaving in the next while.").font(.footnote).foregroundStyle(look.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, d in row(d) }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "bus.fill").font(.title3.weight(.semibold)).foregroundStyle(look.accent)
                Text("Pick a stop").font(.headline).foregroundStyle(look.text)
                Text("Touch and hold the widget, then Edit Widget.").font(.caption).foregroundStyle(look.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func pill(_ d: StopBoardCore.Departure) -> some View {
        let kind: VehicleKind = d.train ? (d.line == "SPR" ? .sprinter : .ic) : .bus
        return Text(d.line).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 5).frame(minWidth: 32, minHeight: 18)
            .background(look.pill(kind), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func row(_ d: StopBoardCore.Departure) -> some View {
        let warn = d.cancelled || d.delay >= 3
        return HStack(spacing: 6) {
            pill(d)
            if family != .systemSmall {
                Text(d.headsign).font(.caption).foregroundStyle(look.text).lineLimit(1)
                Spacer(minLength: 4)
            } else {
                Spacer(minLength: 2)
            }
            Text(StopBoardCore.timeText(d, hhmm: hm)).font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(warn ? look.warning : look.text)
                .strikethrough(d.cancelled)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StopBoardWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "StopDepartures", intent: PickStopIntent.self, provider: StopBoardProvider()) { entry in
            StopBoardView(entry: entry)
        }
        .configurationDisplayName("Next departures")
        .description("The next buses and trains from a stop you pick, with live delays.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}
