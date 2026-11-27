import AppIntents
import CoreLocation
import SwiftUI

// 0.37: Siri and Shortcuts (App Intents, no entitlement needed). "When's my bus?" answers by itself; the others open the
// app, which does them through its own start path (`AppActions`): nothing here starts a ride or an alarm by itself.

/// The next departures from your home stop (near home, or when it doesn't know where you are), else from the stop
/// nearest you: said, and shown as a small card.
struct WhensMyBusIntent: AppIntent {
    static var title: LocalizedStringResource = "When’s my bus?"
    static var description = IntentDescription("The next bus or train from your home stop, or from the stop nearest you.")
    static var openAppWhenRun: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let now = Date()
        let (name, ids) = await Self.where_()
        guard !ids.isEmpty else {
            return .result(dialog: "I don’t know your stop yet. Open Haltewekker once to set up your home.", view: BusSnippet(stop: "", rows: []))
        }
        let board = await Transit.$urgent.withValue(true) { () async -> [BoardDeparture] in
            await Transit.board(stopIds: ids, from: now.addingTimeInterval(-60), n: 8)
        }
        let deps: [StopBoardCore.Departure] = board.map { b in
            StopBoardCore.Departure(line: b.train ? StopBoardCore.trainLabel(b.line) : b.line, headsign: Fmt.place(b.headsign), time: b.time,
                                    scheduled: b.scheduled, live: b.live, cancelled: b.cancelled, train: b.train, platform: b.platform)
        }
        let text = StopBoardCore.spoken(deps, stop: name, now: now, hhmm: Fmt.hhmm)
        let rows = StopBoardCore.upcoming(deps, at: now, count: 4)
        return .result(dialog: "\(text)", view: BusSnippet(stop: name, rows: rows))
    }

    /// Your home stop or the nearest one: its name and stop ids.
    @MainActor
    private static func where_() async -> (String, [String]) {
        let home = Place.homeBoard
        let homeIds = home.ids.filter { !$0.contains(",") }
        let fix = CLLocationManager().location.flatMap { f -> CLLocation? in
            f.horizontalAccuracy >= 0 && f.horizontalAccuracy < 1000 && -f.timestamp.timeIntervalSinceNow < 3600 ? f : nil
        }
        let metres = fix.map { $0.distance(from: CLLocation(latitude: Place.home.coordinate.latitude, longitude: Place.home.coordinate.longitude)) }
        switch IntentActions.busFrom(metresFromHome: metres, haveHomeStop: !homeIds.isEmpty) {
        case .home:
            return (home.short, homeIds)
        case .nearest:
            guard let c = fix?.coordinate, let s = await Transit.nearStops(c).first else { return (home.short, homeIds) }
            return (s.rail ? Fmt.place(s.name) : Fmt.stop(s.name), [s.id])
        }
    }
}

/// Siri's card: the stop and its next departures, as the widget shows them.
struct BusSnippet: View {
    let stop: String
    let rows: [StopBoardCore.Departure]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !stop.isEmpty {
                Text(stop).font(.headline).lineLimit(1)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, d in
                HStack(spacing: 8) {
                    DSLinePill(line: d.line, train: d.train)
                    Text(d.headsign).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(StopBoardCore.timeText(d, hhmm: Fmt.hhmm)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(d.cancelled || d.delay >= 3 ? DS.warning : DS.text)
                }
            }
        }
        .padding()
    }
}

/// Wake me at a stop or station you name: the app opens on Wake me at a stop with it, for you to confirm.
struct WakeAtStopIntent: AppIntent {
    static var title: LocalizedStringResource = "Wake me at a stop"
    static var description = IntentDescription("Opens Haltewekker’s Wake me at a stop with the stop or station you name, to confirm.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Stop", requestValueDialog: IntentDialog("Which stop or station?"))
    var stop: StopEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        AppActions.shared.post(.wake(stop.stop))
        return .result()
    }
}

enum TripGoal: String, AppEnum {
    case school, home
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Where to"
    static var caseDisplayRepresentations: [TripGoal: DisplayRepresentation] = [.school: "School", .home: "Home"]
}

/// Fastest trip to school or home.
struct PlanTripIntent: AppIntent {
    static var title: LocalizedStringResource = "Plan to school or home"
    static var description = IntentDescription("Opens Fastest trip to school or home: when to leave, and it watches your bus or train.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "To", default: .school)
    var to: TripGoal

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        AppActions.shared.post(.fastest(toSchool: to == .school))
        return .result()
    }
}

/// I'm on it, for your next planned ride (or Fastest trip for it, which starts by itself once you're on board).
struct StartTripIntent: AppIntent {
    static var title: LocalizedStringResource = "Start my trip"
    static var description = IntentDescription("I’m on it, for your next planned trip: it wakes you before your stop.")
    static var openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        AppActions.shared.post(.startTrip)
        return .result()
    }
}

/// (0.42.6) "Be at school at 9": the next school day's "Be there at …"; its trip and wake-up alarm are planned again.
struct BeAtSchoolIntent: AppIntent {
    static var title: LocalizedStringResource = "Be at school at a time"
    static var description = IntentDescription("Changes when you want to be at school on your next school day: the trip there and your wake-up alarm follow.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Time", requestValueDialog: IntentDialog("When do you want to be at school?"))
    var time: Date

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let school = SchoolAlarm.shared
        let now = Date()
        let days: [SchoolAlarm.Planned] = school.week.filter { $0.classStart > now && !$0.rang }
        guard school.on, let p = days.min(by: { $0.classStart < $1.classStart }) else {
            return .result(dialog: "There’s no school day planned to change. Turn on the school alarm in Haltewekker first.")
        }
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: time)
        guard let at = cal.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0, second: 0, of: p.classStart) else {
            return .result(dialog: "I couldn’t read that time.")
        }
        if school.applyArrival(p.day, at) { await school.refresh(now: true, staleOnly: true) }
        let when: String = SchoolAlarm.dayWord(p.classStart)
        let alarm: String = school.week.first(where: { $0.day == p.day })?.alarm.map { " Your alarm: \(Fmt.hhmm($0))." } ?? ""
        let text: String = "Be at school \(when) at \(Fmt.hhmm(at)), class \(Fmt.hhmm(p.classStart)).\(alarm)"
        return .result(dialog: "\(text)")
    }
}

struct HaltewekkerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhensMyBusIntent(), phrases: [
            "When’s my bus in \(.applicationName)",
            "When does my bus leave in \(.applicationName)",
            "Next bus in \(.applicationName)",
            "\(.applicationName) when’s my bus",
        ], shortTitle: "When’s my bus?", systemImageName: "bus")
        AppShortcut(intent: WakeAtStopIntent(), phrases: [
            "Wake me at a stop with \(.applicationName)",
            "\(.applicationName) wake me at a stop",
            "Wake me at my stop with \(.applicationName)",
        ], shortTitle: "Wake me at a stop", systemImageName: "bell.and.waves.left.and.right")
        AppShortcut(intent: PlanTripIntent(), phrases: [
            "Plan to \(\.$to) with \(.applicationName)",
            "Plan my trip \(\.$to) with \(.applicationName)",
            "Fastest way \(\.$to) in \(.applicationName)",
            "Plan my trip with \(.applicationName)",
        ], shortTitle: "Plan to school or home", systemImageName: "point.topleft.down.to.point.bottomright.curvepath")
        AppShortcut(intent: StartTripIntent(), phrases: [
            "Start my trip with \(.applicationName)",
            "\(.applicationName) start my trip",
            "I’m on it in \(.applicationName)",
        ], shortTitle: "Start my trip", systemImageName: "play.fill")
        AppShortcut(intent: BeAtSchoolIntent(), phrases: [
            "Be at school at a time with \(.applicationName)",
            "Change when I’m at school with \(.applicationName)",
            "\(.applicationName) be at school earlier",
        ], shortTitle: "Be at school at", systemImageName: "clock.arrow.circlepath")
    }
}
