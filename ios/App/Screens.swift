import AuthenticationServices
import SwiftUI

struct RootView: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var watch: WatchStore
    @EnvironmentObject var go: GoStore
    @ObservedObject private var notices = Notices.shared
    @State private var browsing = false         // at a change: looking at the map and the boards for a bit
    var body: some View {
        Group {
            switch trip.phase {
            case .idle where go.isOpen: GoView().transition(.opacity)
            case .idle: HomeView()
            case .alarm: AlarmView()
            case .transfer where browsing:
                HomeView().safeAreaInset(edge: .bottom) { ChangeBar { withAnimation(.easeInOut(duration: 0.3)) { browsing = false } } }
            case .transfer, .finished: ArrivalView(browse: { withAnimation(.easeInOut(duration: 0.3)) { browsing = true } })
            default: RideView()
            }
        }
        .onChange(of: trip.phase) { _, p in
            if p != .transfer { browsing = false }
            if p != .idle && go.isOpen { go.close() }        // a trip started: the ride screen takes over
        }
        .animation(.easeInOut(duration: 0.35), value: go.isOpen)
        .overlay {
            if let a = watch.alert {
                PlatformAlertView(alert: a, pal: .of(home: trip.direction == .home)) { watch.dismiss() }.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: watch.alert)
        // notifications pop up inside the app too, while it's open
        .overlay(alignment: .top) {
            if let n = notices.current {
                NoticeBanner(notice: n) { notices.dismiss() }
                    .padding(.horizontal, 10).padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(n.id)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// At a change, while you look at the map: where you're changing and the next one, and the way back to it.
struct ChangeBar: View {
    @EnvironmentObject var trip: TripManager
    let back: () -> Void
    var body: some View {
        Button(action: back) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.swap").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Change at \(trip.leg?.to.short ?? "your stop")").font(BoardInk.sans(14)).foregroundStyle(.white)
                    if let r = trip.next {
                        Text("\(r.isTrain ? r.name : "Bus \(r.line)") at \(Fmt.hhmm(r.departure))").font(BoardInk.sans(11.5, .regular)).foregroundStyle(Color.white.opacity(0.85))
                    }
                }
                Spacer(minLength: 6)
                Text("Back to your trip").font(BoardInk.sans(12)).foregroundStyle(BoardInk.navy)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(Color.white, in: Capsule())
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Paper.green, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            .padding(.horizontal, 12).padding(.bottom, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: home

struct HomeView: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var live: LiveStore
    @EnvironmentObject var planner: Planner
    @EnvironmentObject var ns: NSStore
    @EnvironmentObject var watch: WatchStore
    @EnvironmentObject var near: NearMe
    @EnvironmentObject var stops: StopsStore
    @EnvironmentObject var scores: ScoreBook
    @EnvironmentObject var lines: LineWatchStore
    @EnvironmentObject var goStore: GoStore
    @Environment(\.scenePhase) private var scene
    @State private var settings = false
    @State private var planning = false
    @State private var liveSettings = false
    @State private var startReq: StartRequest?
    @State private var stopEdit: StopEditRequest?
    @State private var open: Set<String> = []
    var home: Bool { trip.direction == .home }
    var pal: HWPalette { .of(home: home) }

    @State private var stage: StageMode = .map
    @State private var section: HomeSection = .fastest
    @State private var moveToken = 0
    @State private var loopToken = 0
    @State private var picked: BoardPick?            // the line you tapped on a board
    @State private var choosingDestination = false
    @State private var nearShift: [String: Int] = [:]     // how far back or forward you've gone at each stop near you
    @State private var walkTo: WalkTarget?                 // the walk to a stop, on a map
    @State private var liveTrack: LiveTrackTarget?         // a bus or train you tapped, live on a map
    @State private var showMoving = false                  // everything moving near you, on a map
    @State private var showDemo = false                    // try it at home
    @State private var showNotices = false                 // the notifications you had, and what's watched
    @State private var planByArrival = true                // the plan sheet opens on "be there by"

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            // at the boards: back to the map, the direction, settings (what you picked is on the boards themselves)
            if stage == .station {
                topBar.transition(.opacity)
            }
            if let t = trip.toast {
                ToastView(text: t, pal: pal)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { withAnimation { trip.toast = nil } }
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 7_000_000_000)
                        if trip.toast == t { withAnimation { trip.toast = nil } }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The station and the map on the wall fill the whole screen behind; the screen's own buttons stay clear of
        // the clock and the Dynamic Island. (Taps that miss them reach the map.)
        .background {
            HomeStage(home: home, stage: stage, moveToken: moveToken) {
                MetroMapMenu(home: home, fastest: fastestSub, lines: linesSub, planned: plannedSub, via: live.next.first?.via,
                             custom: live.custom?.short, trip: live.custom == nil ? nil : (live.next[safe: live.pick] ?? live.next.first),
                             others: Array(live.next.prefix(3)),
                             open: { go($0) }, toggle: { toggleDirection() }, settings: { settings = true })
            } boards: { led, plan in
                wallBoards(led, plan)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: trip.toast)
        .onChange(of: stage) { _, s in Handoff.fromBoards = s == .station }
        .onChange(of: near.position?.coordinate.latitude) { _, _ in Task { await live.refresh(trip.direction, at: near.position) } }
        .sheet(item: $walkTo) { WalkMapSheet(target: $0).presentationDetents([.large]) }
        .sheet(item: $liveTrack) { LiveBusSheet(target: $0).presentationDetents([.large]) }
        .sheet(isPresented: $showMoving) { LiveAllSheet(center: near.position?.coordinate ?? Place.breda.coordinate).presentationDetents([.large]) }
        .sheet(isPresented: $choosingDestination) {
            DestinationSheet { d in
                live.go(to: d)
                Task { await live.refresh(trip.direction, at: near.position, force: true) }
            }
        }
        .onAppear { Handoff.fromBoards = stage == .station }
        .sheet(isPresented: $settings) {
            SettingsView(tryDemo: {
                Task { @MainActor in try? await Task.sleep(nanoseconds: 500_000_000); showDemo = true }
            }).presentationDetents([.large])
        }
        .sheet(isPresented: $showDemo) { DemoSheet().presentationDetents([.large]) }
        .sheet(isPresented: $showNotices) { NotificationsSheet().presentationDetents([.medium, .large]) }
        // on the map: the bell, top left, clear of the map's own buttons
        .overlay(alignment: .topLeading) {
            if stage == .map { NoticeBell { showNotices = true }.padding(.leading, 18).padding(.top, 4).transition(.opacity) }
        }
        .sheet(isPresented: $planning) { PlanSheet(byArrival: planByArrival) }
        .sheet(isPresented: $liveSettings, onDismiss: { Task { await live.refresh(trip.direction, force: true) } }) { LiveSettingsSheet() }
        .sheet(item: $startReq) { r in StartSheet(req: r).presentationDetents([.medium, .large]) }
        .sheet(item: $stopEdit) { r in StopSheet(req: r) }
        .task(id: trip.direction) {
            while !Task.isCancelled {
                if scene == .active {
                    Watchdog.shared.mark("finding where you are")
                    near.locate(ask: true)                       // where you are decides where your trips start
                    Watchdog.shared.mark("loading the live times")
                    await live.refresh(trip.direction, at: near.position)
                    Watchdog.shared.mark("planning your planned trips")
                    await planner.refresh()
                    Watchdog.shared.mark("planning the school alarms")
                    await SchoolAlarm.shared.refresh()
                    Watchdog.shared.mark("checking watched trains")
                    await watch.check()
                    autoGo()
                    Watchdog.shared.mark("showing the home screen")
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .onChange(of: scene) { _, s in
            if s == .active {
                trip.appBecameActive()
                autoGo()
                Task { await live.refresh(trip.direction); await planner.refresh(); await watch.check(force: true) }
            }
        }
    }

    // MARK: map ⇄ station

    /// Pick a line on the map: step back from the wall and walk over to the boards.
    private func go(_ s: HomeSection) {
        guard stage == .map else { return }
        // Fastest trip: straight to the screen that gets you there (not the boards)
        if s == .fastest && trip.phase == .idle { openGo(); return }
        section = s
        picked = nil
        if s == .more { open.insert("scores") }
        moveToken += 1; loopToken += 1
        withAnimation(.easeOut(duration: 0.15)) { stage = .leaving }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)          // the map comes down, the sheets go up
            guard stage == .leaving else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { stage = .station }
        }
    }

    /// Around the time to leave for a trip you planned (your first class, or a Be there by time): the hands-free screen
    /// for it opens by itself, and starts the ride once you're on the bus. Once per trip: closing it means not again.
    private func autoGo() {
        guard trip.phase == .idle, !goStore.isOpen else { return }
        let now = Date()
        let school = SchoolAlarm.shared
        // from when the alarm rings (or 45 minutes before you leave) until just after the first bus has left
        if school.on, let n = school.next, let l = n.leave, let t = n.trip,
           now > min(l.addingTimeInterval(-45 * 60), n.alarm ?? l), now < t.first.departure.addingTimeInterval(5 * 60) {
            if trip.direction != .toSchool { trip.pick(.toSchool) }
            withAnimation(.easeInOut(duration: 0.35)) {
                goStore.openForPlan(to: .buas, from: near.position, deadline: n.beThere, label: "your \(Fmt.hhmm(n.classStart)) class",
                                    key: "school-\(Fmt.ymd.string(from: n.classStart))")
            }
            return
        }
        if let a = planner.arrive, let T = a.when, let t = planner.arriveChosen,
           now > t.start.addingTimeInterval(-45 * 60), now < t.first.departure.addingTimeInterval(5 * 60) {
            if trip.direction != (a.out ? .toSchool : .home) { trip.pick(a.out ? .toSchool : .home) }
            withAnimation(.easeInOut(duration: 0.35)) {
                goStore.openForPlan(to: a.out ? .buas : .veghel, from: near.position, deadline: T, label: "\(a.out ? "BUas" : "home") by \(a.time)",
                                    key: "arrive-\(a.date)-\(a.time)")
            }
        }
    }

    /// Hands-free now, for the school alarm's trip or the Be there by plan.
    private func openPlanGo(school: Bool) {
        if school, let n = SchoolAlarm.shared.next {
            if trip.direction != .toSchool { trip.pick(.toSchool) }
            withAnimation(.easeInOut(duration: 0.35)) { goStore.open(to: .buas, from: near.position, deadline: n.beThere, label: "your \(Fmt.hhmm(n.classStart)) class") }
        } else if let a = planner.arrive, let T = a.when {
            if trip.direction != (a.out ? .toSchool : .home) { trip.pick(a.out ? .toSchool : .home) }
            withAnimation(.easeInOut(duration: 0.35)) { goStore.open(to: a.out ? .buas : .veghel, from: near.position, deadline: T, label: "\(a.out ? "BUas" : "home") by \(a.time)") }
        }
    }

    /// The hands-free Fastest trip screen, to where you're going now.
    private func openGo() {
        withAnimation(.easeInOut(duration: 0.35)) { goStore.open(to: live.destination(trip.direction), from: near.position) }
    }

    /// Back to the map: walk back over to the wall.
    private func backToMap() {
        guard stage == .station else { return }
        moveToken += 1
        withAnimation(.easeIn(duration: 0.2)) { stage = .returning }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard stage == .returning else { return }
            withAnimation(.easeOut(duration: 0.3)) { stage = .map }
        }
    }

    /// Your next trip's rides for the board over the platform.
    private var boardLines: [BoardLine] {
        guard let t = live.next[safe: live.pick] ?? live.next.first else { return [] }
        return t.rides.prefix(3).map { r in
            let to = Fmt.place(r.toStop)
            return BoardLine(line: r.line, to: to == "BUas" ? "BUas" : to, time: Fmt.hhmm(r.departure),
                             note: r.cancelled ? "X" : r.live && r.delay >= 1 ? "+\(r.delay)" : nil)
        }
    }

    private var fastestSub: String {
        guard let t = live.next.first else { return live.nextError == nil ? "Finding your next connection…" : "No trips found right now" }
        let m = Fmt.mins(t.first.departure.timeIntervalSinceNow)
        return "Leaves \(Fmt.hhmm(t.first.departure))\(m <= 90 ? " (in \(m) min)" : "") · \(live.custom?.short ?? (home ? "home" : "BUas")) \(Fmt.hhmm(t.end))"
    }
    private var linesSub: String {
        if let w = lines.watches.first { return "Watching \(w.line): \(w.status)" }
        let now = Date()
        if home, let t = live.trains.first(where: { $0.trip.first.departure > now }) {
            return "\(t.trip.first.line) to \(t.to.short) \(Fmt.hhmm(t.trip.first.departure)) · every bus and train"
        }
        if !home, let d = live.boardShown.first(where: { $0.time > now && !$0.cancelled }) {
            return "Bus \(d.line) to \(d.headsign) \(Fmt.hhmm(d.time)) · every bus and train"
        }
        return "Every bus and train, live"
    }
    private var plannedSub: String {
        if let n = SchoolAlarm.shared.next, SchoolAlarm.shared.on, let a = n.alarm, a > Date() {
            return "Alarm \(SchoolAlarm.dayWord(a)) \(Fmt.hhmm(a)) · first class \(Fmt.hhmm(n.classStart))"
        }
        if let a = planner.arrive {
            return "\(a.dayLabel) · \(a.out ? "BUas" : "home") by \(a.time)" + (planner.arriveChosen.map { " · leave \(Fmt.hhmm($0.start))" } ?? "")
        }
        guard let t = planner.trip else { return "Be there by a time, or travel with your friend’s train" }
        return "\(t.dayLabel) · \(t.out ? "arrive Breda" : "leave Breda") \(t.time)"
    }

    // MARK: at the boards

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: backToMap) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                    Text("MAP").font(HWFont.display(13)).tracking(1.4)
                }
                .foregroundStyle(Paper.ink).padding(.horizontal, 12).padding(.vertical, 8)
                .background(Paper.paper, in: Capsule()).shadow(color: .black.opacity(0.35), radius: 5, y: 3)
            }
            .buttonStyle(.plain).accessibilityLabel("Back to the map")
            Spacer(minLength: 4)
            // where you're going: school, home, or somewhere you pick
            Menu {
                Button { goTo(.toSchool) } label: { Label("To school (BUas)", systemImage: "graduationcap.fill") }
                Button { goTo(.home) } label: { Label("Home (Veghel)", systemImage: "house.fill") }
                if !live.recents.isEmpty {
                    Section("Recent") {
                        ForEach(live.recents) { d in
                            Button { live.go(to: d); Task { await live.refresh(trip.direction, at: near.position, force: true) } } label: { Label(d.name, systemImage: "mappin") }
                        }
                    }
                }
                Button { choosingDestination = true } label: { Label("Somewhere else…", systemImage: "magnifyingglass") }
            } label: {
                HStack(spacing: 5) {
                    Text(live.custom.map { $0.short.uppercased() } ?? trip.direction.word).font(HWFont.display(13)).tracking(1.2)
                        .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: 150)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Paper.ink).padding(.horizontal, 10).padding(.vertical, 8)
                .background(Paper.paper, in: Capsule()).shadow(color: .black.opacity(0.35), radius: 5, y: 3)
            }
            .accessibilityLabel("Where you’re going: \(live.custom?.short ?? (home ? "home" : "school")). Tap to change.")
            NoticeBell { showNotices = true }
            Button { showMoving = true } label: {
                Image(systemName: "map.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Paper.ink)
                    .frame(width: 34, height: 34).background(Paper.paper, in: Circle()).shadow(color: .black.opacity(0.35), radius: 5, y: 3)
            }
            .buttonStyle(.plain).accessibilityLabel("Everything moving near you, on a map")
            Button { settings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .semibold)).foregroundStyle(Paper.ink)
                    .frame(width: 34, height: 34).background(Paper.paper, in: Circle()).shadow(color: .black.opacity(0.35), radius: 5, y: 3)
            }
            .buttonStyle(.plain).accessibilityLabel("Settings")
        }
        .padding(.horizontal, 18).padding(.top, 4)
    }

    /// What the app writes on the two screens on the wall: the trains on the LED strip, the rest on the planner.
    private func wallBoards(_ led: CGRect, _ plan: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            PaperTrainSheet(title: ledTitle, sub: live.anywhere ? "Departures near you · tap one for its page" : "Departures · tap one for its page", home: home,
                            rows: live.anywhere ? nearLedRows : ledRows, tap: live.anywhere ? tapNearTrain : tapTrain)
                .frame(width: led.width, height: led.height, alignment: .top)
                .position(x: led.midX, y: led.midY)
            PlannerScreen(section: section, pick: pickSection) { plannerContent }
                .frame(width: plan.width, height: plan.height)
                .position(x: plan.midX, y: plan.midY)
        }
    }

    /// The trains for the LED strip: the last few that left (dimmed) and the next ones.
    private var ledRows: [LEDTrain] {
        let now = Date(), since = now.addingTimeInterval(-20 * 60)
        let all = live.trains.filter { $0.trip.first.departure > since || $0.trip.first.scheduledDeparture > since }
        let firstNext = all.firstIndex { $0.trip.first.departure > now.addingTimeInterval(-60) } ?? all.count
        let list = all.dropFirst(max(0, firstNext - 2)).prefix(12)         // at most two that have left
        return list.map { p in
            let f = p.trip.first, info = ns.rail(f)
            let cancelled = f.cancelled || info?.cancelled == true
            let gone = !cancelled && f.departure < now.addingTimeInterval(-60)
            let status = cancelled ? "Cancelled" : gone ? "Departed" : (f.live && f.delay >= 1) ? Fmt.hhmm(f.departure) : f.live ? "On time" : "Planned"
            let to = f.headsign.isEmpty ? p.to.short : Fmt.place(f.headsign)
            let via = "from \(p.from.short)" + (p.trip.changes.isEmpty ? "" : ", change \(p.trip.changes.joined(separator: ", "))")
            let track = (info?.track ?? f.platform ?? "") + (info?.trackChanged == true ? "!" : "")
            var isPicked = false
            if case .train(let t) = picked, t.id == p.id { isPicked = true }
            return LEDTrain(id: p.id, time: Fmt.hhmm(f.scheduledDeparture), to: "\(to) \(f.line)", via: via, platform: track,
                            status: status, gone: gone, picked: isPicked)
        }
    }

    private var ledTitle: String {
        guard live.anywhere else { return home ? "Trains home" : "Trains to Breda" }
        return live.nearStops.first(where: \.rail).map { "Trains from \(Fmt.place($0.name))" } ?? "No station near you"
    }

    /// From anywhere: the trains from the station near you.
    private var nearLedRows: [LEDTrain] {
        let rail = Set(live.nearStops.filter(\.rail).map(\.id))
        let station = live.nearStops.first(where: \.rail).map { Fmt.place($0.name) } ?? ""
        let now = Date()
        let list = live.nearBoard.filter { rail.contains($0.stopId) && $0.time > now.addingTimeInterval(-30 * 60) }
        let firstNext = list.firstIndex { ($0.cancelled ? $0.scheduled : $0.time) > now.addingTimeInterval(-60) } ?? list.count
        return list.dropFirst(max(0, firstNext - 2)).prefix(12).map { d in
            let gone = !d.cancelled && d.time < now.addingTimeInterval(-60)
            let status = d.cancelled ? "Cancelled" : gone ? "Departed" : (d.live && d.delay >= 1) ? Fmt.hhmm(d.time) : d.live ? "On time" : "Planned"
            var isPicked = false
            if case .bus(let b) = picked, b.id == d.id { isPicked = true }
            return LEDTrain(id: d.id, time: Fmt.hhmm(d.scheduled), to: "\(Fmt.place(d.headsign)) \(Transit.trainLabel(d.line))",
                            via: d.heading.map { h in "\(h.compass)\(h.via.map { " via " + $0 } ?? " from \(station)")" } ?? "from \(station)",
                            platform: d.platform ?? "", status: status, gone: gone, picked: isPicked)
        }
    }

    private func tapNearTrain(_ id: String) {
        if let d = live.nearBoard.first(where: { $0.id == id }) { tapBus(d) }
    }

    /// Back to school or home (from the menu at the top).
    private func goTo(_ d: Direction) {
        live.go(to: nil)
        if trip.direction != d { toggleDirection() } else { Task { await live.refresh(d, at: near.position, force: true) } }
    }

    private func pickSection(_ s: HomeSection) {
        picked = nil
        if s == .more { open.insert("scores") }
        withAnimation(.easeInOut(duration: 0.2)) { section = s }
    }

    // Tapping a line opens its page on the planner and starts tracking it.
    private func tapTrain(_ id: String) {
        guard let p = live.trains.first(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { picked = .train(p) }
        if !watch.isWatched(p.trip.first, from: p.from) { _ = watch.toggle(p.trip, from: p.from, to: p.to) }
    }
    private func tapBus(_ d: BoardDeparture) {
        withAnimation(.easeInOut(duration: 0.2)) { picked = .bus(d) }
        if !lines.isWatched(stopId: d.stopId, line: d.line, headsign: d.headsign) {
            lines.toggle(stopId: d.stopId, stopName: d.stopName, line: d.line, headsign: d.headsign, tripId: d.tripId, delay: d.live ? d.delay : nil)
        }
    }
    private func tapBusTrip(_ p: PanelTrip) {
        withAnimation(.easeInOut(duration: 0.2)) { picked = .busTrip(p) }
        let f = p.trip.first
        if !lines.isWatched(stopId: f.fromId, line: f.line, headsign: f.headsign) {
            lines.toggle(stopId: f.fromId, stopName: f.fromStop, line: f.line, headsign: f.headsign, tripId: f.tripId, delay: f.live ? f.delay : nil)
        }
    }

    @ViewBuilder private var plannerContent: some View {
        if let p = picked {
            pickedPage(p)
        } else {
            switch section {
            case .fastest: boardFastestContent
            case .lines: boardLinesContent
            case .planned: plannedContent
            case .more: moreContent
            }
        }
    }

    @ViewBuilder private func pickedPage(_ p: BoardPick) -> some View {
        switch p {
        case .train(let t):
            let f = t.trip.first
            TrainPage(p: t, info: ns.rail(f), tracked: watch.isWatched(f, from: t.from), nsMissing: ns.available == false, pal: pal,
                      walk: walkAction(f), liveMap: liveAction(f), back: { withAnimation(.easeInOut(duration: 0.2)) { picked = nil } },
                      track: { _ = watch.toggle(t.trip, from: t.from, to: t.to) })
        case .bus(let d):
            let ride = live.boardRides["\(d.stopId)|\(d.tripId)"]
            let isTrain = live.nearStops.contains { $0.rail && $0.id == d.stopId }
            BusPage(line: isTrain ? Transit.trainLabel(d.line) : d.line, to: d.headsign, stop: d.stopName, time: d.cancelled ? d.scheduled : d.time, scheduled: d.scheduled,
                    live: d.live, cancelled: d.cancelled, status: BoardRow.status(d),
                    ride: ride.map { "\(Fmt.rideText($0.minutes)) ride to \($0.station) station, arrives \(Fmt.hhmm($0.arrival))" },
                    rank: ride.map { RankInfo(grade: d.cancelled ? nil : $0.grade, minutes: $0.minutes, best: $0.best, stretch: "\(Fmt.place(d.stopName)) → \($0.station)") },
                    train: isTrain,
                    walk: live.nearStops.first(where: { $0.id == d.stopId }).map { s in { walkTo = WalkTarget(name: Fmt.place(d.stopName), lat: s.lat, lon: s.lon, rail: isTrain,
                        catchText: "the \(isTrain ? Transit.trainLabel(d.line) : d.line) to \(Fmt.place(d.headsign)) at \(Fmt.hhmm(d.time))", leaves: d.time) } },
                    liveMap: { liveTrack = LiveTrackTarget(tripId: d.tripId, line: isTrain ? Transit.trainLabel(d.line) : d.line, headsign: d.headsign,
                                                           stopName: d.stopName, time: d.cancelled ? d.scheduled : d.time, rail: isTrain) },
                    tracked: lines.isWatched(stopId: d.stopId, line: d.line, headsign: d.headsign),
                    back: { withAnimation(.easeInOut(duration: 0.2)) { picked = nil } },
                    track: { lines.toggle(stopId: d.stopId, stopName: d.stopName, line: d.line, headsign: d.headsign, tripId: d.tripId, delay: d.live ? d.delay : nil) })
        case .busTrip(let t):
            let f = t.trip.first
            BusPage(line: f.line, to: f.headsign.isEmpty ? Fmt.place(t.trip.last.toStop) : f.headsign, stop: Fmt.place(f.fromStop),
                    time: f.departure, scheduled: f.scheduledDeparture, live: f.live, cancelled: f.cancelled, status: RideText.status(f, nil).text,
                    ride: "\(t.trip.rideLabel) · arrives \(Fmt.place(t.trip.last.toStop)) \(Fmt.hhmm(t.trip.last.arrival))",
                    rank: RankInfo.of(t.trip),
                    walk: walkAction(f), liveMap: liveAction(f),
                    tracked: lines.isWatched(stopId: f.fromId, line: f.line, headsign: f.headsign),
                    back: { withAnimation(.easeInOut(duration: 0.2)) { picked = nil } },
                    track: { lines.toggle(stopId: f.fromId, stopName: f.fromStop, line: f.line, headsign: f.headsign, tripId: f.tripId, delay: f.live ? f.delay : nil) })
        case .ride(let r):
            if r.isTrain, let pt = trainTrip(r) {
                TrainPage(p: pt, info: ns.rail(r), tracked: watch.isWatched(r, from: pt.from), nsMissing: ns.available == false, pal: pal,
                          walk: walkAction(r), liveMap: liveAction(r), back: { withAnimation(.easeInOut(duration: 0.2)) { picked = nil } },
                          track: { _ = watch.toggle(pt.trip, from: pt.from, to: pt.to) })
            } else {
                BusPage(line: r.line, to: r.headsign.isEmpty ? Fmt.place(r.toStop) : r.headsign, stop: Fmt.place(r.fromStop),
                        time: r.departure, scheduled: r.scheduledDeparture, live: r.live, cancelled: r.cancelled, status: RideText.status(r, ns.rail(r)).text,
                        ride: "\(r.rideMinutes) min ride · arrives \(Fmt.place(r.toStop)) \(Fmt.hhmm(r.arrival))",
                        rank: RankInfo.of(r),
                        walk: walkAction(r), liveMap: liveAction(r),
                        tracked: lines.isWatched(stopId: r.fromId, line: r.line, headsign: r.headsign),
                        back: { withAnimation(.easeInOut(duration: 0.2)) { picked = nil } },
                        track: { lines.toggle(stopId: r.fromId, stopName: r.fromStop, line: r.line, headsign: r.headsign, tripId: r.tripId, delay: r.live ? r.delay : nil) })
            }
        }
    }

    /// A train from your trip as a one-ride trip between two of your stations (so it can be watched like the others).
    private func trainTrip(_ r: Ride) -> PanelTrip? {
        guard let from = Place.all.first(where: { $0.short == Fmt.place(r.fromStop) }),
              let to = Place.all.first(where: { $0.short == Fmt.place(r.toStop) }) else { return nil }
        return PanelTrip(trip: DoorTrip(rides: [r], start: r.departure, end: r.arrival), from: from, to: to)
    }

    private func tapRide(_ r: Ride) {
        withAnimation(.easeInOut(duration: 0.2)) { picked = .ride(r) }
        if r.isTrain {
            if let pt = trainTrip(r), !watch.isWatched(r, from: pt.from) { _ = watch.toggle(pt.trip, from: pt.from, to: pt.to) }
        } else if !lines.isWatched(stopId: r.fromId, line: r.line, headsign: r.headsign) {
            lines.toggle(stopId: r.fromId, stopName: r.fromStop, line: r.line, headsign: r.headsign, tripId: r.tripId, delay: r.live ? r.delay : nil)
        }
    }

    /// "Fastest" on the planner, in the same style as All lines: pick one of the next connections, see it ride by ride
    /// (tap a ride for its page), wake up for it, or start one of your routes.
    @ViewBuilder private var boardFastestContent: some View {
        if trip.phase == .idle {
            Button(action: openGo) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("FASTEST TRIP · HANDS-FREE").font(BoardInk.sans(12)).tracking(0.6)
                        Text("Shows what to take, watches it, starts by itself").font(BoardInk.sans(10, .regular)).opacity(0.85)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 8)
                .background(Paper.green, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        if live.next.isEmpty {
            Text(live.nextError ?? "Finding your next connections…").font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.85))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(live.next.enumerated()), id: \.offset) { i, o in
                        Button { withAnimation(.easeInOut(duration: 0.2)) { live.pick = i } } label: {
                            Text(Fmt.hhmm(o.first.departure)).font(BoardInk.sans(13))
                                .foregroundStyle(i == live.pick ? Color.white : Paper.ink)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(i == live.pick ? Paper.navy : Paper.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(i == live.pick ? .isSelected : [])
                    }
                }
            }
            if let t = live.next[safe: live.pick] ?? live.next.first {
                let r = live.anywhere ? RoutePlan.from(t) : t.via.flatMap { via in RoutePlan.all.first(where: { $0.station.short == via }) }
                let dest = live.destination(trip.direction).short
                PlannerBar(title: live.onBoard != nil ? "Your trip · on board" : live.here != nil ? "Your trip · from here" : t.via.map { "Your trip · via \($0)" } ?? "Your trip",
                           sub: live.anywhere ? "at \(dest) \(Fmt.hhmm(t.end))" : "\(home ? "home" : "at BUas") \(Fmt.hhmm(t.end))")
                ForEach(Array(t.rides.enumerated()), id: \.offset) { i, ride in
                    if i > 0 {
                        let prev = t.rides[i - 1]
                        let ch = Fmt.mins(ride.departure.timeIntervalSince(prev.arrival))
                        Label("\(ch) min to change at \(Fmt.place(prev.toStop))\(ride.walkBefore > 0 ? ", \(ride.walkBefore) min walk" : "")", systemImage: "arrow.triangle.swap")
                            .font(BoardInk.sans(10.5, .semibold)).foregroundStyle(ch - ride.walkBefore < 2 ? Paper.late : Paper.ink.opacity(0.8))
                    }
                    PlannerRideRow(ride: ride, info: ns.rail(ride), picked: picked == .ride(ride)) { tapRide(ride) }
                }
                if let r {
                    Button { if live.anywhere { wake(t) } else { trip.start(r) } } label: {
                        Text(live.anywhere ? "WAKE ME UP · TO \(r.station.short.uppercased())" : "WAKE ME UP · VIA \(r.station.short.uppercased())").font(BoardInk.sans(12)).tracking(0.6).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 9).background(Paper.green, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        RankLegend()
        WatchingCard(pal: pal, board: true)
        PlannerBar(title: "Wake me up", sub: "pick a route")
        ForEach(RoutePlan.all) { r in
            Button { startReq = StartRequest(route: r) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(BoardInk.sans(14)).foregroundStyle(Paper.ink)
                        Text(r.legs(trip.direction).map { "\($0.mode.title) to \($0.to.short)" }.joined(separator: " — "))
                            .font(BoardInk.sans(10.5, .regular)).foregroundStyle(Paper.ink.opacity(0.75))
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "bell.and.waves.left.and.right").foregroundStyle(Paper.navy)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) { Rectangle().fill(Paper.ink.opacity(0.12)).frame(height: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var boardLinesContent: some View {
        if live.anywhere { anywhereLinesContent } else { usualLinesContent }
    }

    /// From anywhere: your fastest trip from where you are, and what leaves from the stops around you.
    @ViewBuilder private var anywhereLinesContent: some View {
        let dest = live.destination(trip.direction).short
        if let t = live.next[safe: live.pick] ?? live.next.first {
            let r = RoutePlan.from(t)
            PlannerTripCard(trip: t, home: home, wakeTitle: r.map { _ in "Wake me up · to \(dest)" }, arrive: "at \(dest) \(Fmt.hhmm(t.end))",
                            title: live.onBoard.map { "On the \($0.vehicle.title) now" } ?? (live.here == nil ? "Your trip · fastest" : "Your trip · from here")) {
                wake(t)
            }
            if let ob = live.onBoard, t.first.tripId == ob.vehicle.tripId {
                Label("You’re on the \(ob.vehicle.title) to \(ob.to): stay on until \(Fmt.place(t.first.toStop))", systemImage: ob.vehicle.isTrain ? "tram.fill" : "bus.fill")
                    .font(BoardInk.sans(11.5, .semibold)).foregroundStyle(Paper.ink.opacity(0.9))
            } else if let ob = live.onBoard {
                Label("You’re on the \(ob.vehicle.title): get off at \(ob.next) and change there", systemImage: ob.vehicle.isTrain ? "tram.fill" : "bus.fill")
                    .font(BoardInk.sans(11.5, .semibold)).foregroundStyle(Paper.ink.opacity(0.9))
            } else if t.first.walkBefore > 0 || walkTarget(t.first) != nil {
                HStack(spacing: 8) {
                    Label(t.first.walkBefore > 0 ? "First a \(t.first.walkBefore) min walk to \(Fmt.place(t.first.fromStop))" : "Your stop: \(Fmt.place(t.first.fromStop))",
                          systemImage: "figure.walk")
                        .font(BoardInk.sans(11.5, .semibold)).foregroundStyle(Paper.ink.opacity(0.85))
                    Spacer(minLength: 4)
                    if let w = walkTarget(t.first) { WalkButton { walkTo = w } }
                }
            }
        } else {
            Text(live.nextError ?? "Finding the fastest way to \(dest)…").font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.85))
        }
        nearYou
        RankLegend()
        WatchingCard(pal: pal, board: true)
        Text("The trips and stops follow where you are. Pick where you’re going with the button at the top. Tap any line for more: it’s tracked for you from then on.")
            .font(BoardInk.sans(9.5, .regular)).foregroundStyle(Paper.ink.opacity(0.65))
    }

    /// The stops around you: the nearest bus stops (both sides) and the nearest station, with what leaves next.
    /// The ones that are part of your trip are marked.
    @ViewBuilder private var nearYou: some View {
        let rail = Set(live.nearStops.filter(\.rail).map(\.id))
        let mine = Set(live.next.flatMap(\.rides).map(\.tripId))
        // when you'd be there if you took this bus first, to compare with the fastest
        let ends = live.next.reduce(into: [String: Date]()) { m, t in if (m[t.first.tripId] ?? .distantFuture) > t.end { m[t.first.tripId] = t.end } }
        let fastest = live.next.map(\.end).min()
        let names = live.nearStops.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let dest = live.destination(trip.direction).short
        PlannerBar(title: "Near you", sub: live.here == nil ? nil : "from where you are")
        if live.nearStops.isEmpty {
            Text(live.here == nil ? "Turn location on for Haltewekker to see the stops around you." : "Looking for the stops around you…")
                .font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.85))
        }
        ForEach(names, id: \.self) { name in
            let here = live.nearStops.filter { $0.name == name }
            let ids = Set(here.map(\.id))
            let isRail = !ids.isDisjoint(with: rail)
            // from the next one that hasn't left; Earlier goes back to the ones that have, Later further on
            let all = live.nearBoard.filter { ids.contains($0.stopId) }
            let firstNext = all.firstIndex { ($0.cancelled ? $0.scheduled : $0.time) > Date().addingTimeInterval(-60) } ?? all.count
            let start = max(0, min(firstNext + (nearShift[name] ?? 0), all.count - 1))
            let rows = Array(all.dropFirst(start).prefix(6))
            HStack(spacing: 6) {
                PlannerStop(name: "\(Fmt.place(name)) · \(Fmt.distance(here.map(\.meters).min() ?? 0))", rail: isRail)
                Spacer(minLength: 4)
                if let s = here.min(by: { $0.meters < $1.meters }) {
                    // to catch the one that's part of your trip, or else the next one
                    let soon = all.filter { !$0.cancelled && $0.time > Date() }
                    let c = soon.first(where: { mine.contains($0.tripId) }) ?? soon.first
                    WalkButton {
                        walkTo = WalkTarget(name: Fmt.place(name), lat: s.lat, lon: s.lon, rail: isRail,
                                            catchText: c.map { "the \(isRail ? Transit.trainLabel($0.line) : $0.line) to \(Fmt.place($0.headsign)) at \(Fmt.hhmm($0.time))" },
                                            leaves: c?.time)
                    }
                }
            }
            if rows.isEmpty {
                Text("Nothing leaving here soon.").font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.75))
            } else {
                HStack(spacing: 6) {
                    shiftButton("‹ Earlier", enabled: start > 0) { nearShift[name] = (nearShift[name] ?? 0) - 3 }
                    if (nearShift[name] ?? 0) != 0 { shiftButton("Now", enabled: true) { nearShift[name] = nil } }
                    Spacer()
                    shiftButton("Later ›", enabled: start + 6 < all.count) { nearShift[name] = (nearShift[name] ?? 0) + 4 }
                }
                PlannerColumns()
                ForEach(rows) { d in
                    PlannerBusRow(line: isRail ? Transit.trainLabel(d.line) : d.line, to: Fmt.place(d.headsign), time: d.cancelled ? d.scheduled : d.time,
                                  scheduled: d.scheduled, live: d.live, cancelled: d.cancelled, train: isRail,
                                  note: compareNote(ends[d.tripId], fastest, dest) ?? (mine.contains(d.tripId) ? "Part of your trip to \(dest)" : d.platform.map { "platform \($0)" }),
                                  heading: d.heading,
                                  watched: lines.isWatched(stopId: d.stopId, line: d.line, headsign: d.headsign), picked: picked == .bus(d)) { tapBus(d) }
                }
            }
        }
    }

    /// "BUas 19:04 · 14 min later than the fastest", "BUas 18:50 · the fastest"
    private func compareNote(_ end: Date?, _ fastest: Date?, _ dest: String) -> String? {
        guard let end, let fastest else { return nil }
        let d = Fmt.mins(end.timeIntervalSince(fastest))
        return "\(dest) \(Fmt.hhmm(end)) · " + (d == 0 ? "the fastest" : "\(d) min later than the fastest")
    }

    /// Wake me up for a trip from anywhere; on a bus or train, the alarm starts with the one you're on.
    private func wake(_ t: DoorTrip) {
        guard let r = RoutePlan.from(t) else { return }
        if let ob = live.onBoard, t.first.tripId == ob.vehicle.tripId { trip.start(r, vehicle: ob.vehicle) } else { trip.start(r) }
    }

    /// The walk to where a ride leaves from (to catch that ride), if we know where its stop is.
    private func walkTarget(_ r: Ride) -> WalkTarget? {
        guard let a = r.fromLat, let o = r.fromLon else { return nil }
        return WalkTarget(name: Fmt.place(r.fromStop), lat: a, lon: o, rail: r.isTrain,
                          catchText: "the \(r.line) to \(Fmt.place(r.headsign.isEmpty ? r.toStop : r.headsign)) at \(Fmt.hhmm(r.departure))", leaves: r.departure)
    }
    private func walkAction(_ r: Ride) -> (() -> Void)? { walkTarget(r).map { w in { walkTo = w } } }
    /// Where a ride's bus or train is now, on a live map (from the stop where you get on).
    private func liveAction(_ r: Ride) -> () -> Void {
        { liveTrack = LiveTrackTarget(tripId: r.tripId, line: r.line, headsign: r.headsign.isEmpty ? Fmt.place(r.toStop) : r.headsign,
                                      stopName: r.fromStop, time: r.departure, rail: r.isTrain) }
    }

    private func shiftButton(_ t: String, enabled: Bool, _ go: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { go() } } label: {
            Text(t).font(BoardInk.sans(11)).foregroundStyle(Paper.ink)
                .padding(.horizontal, 10).padding(.vertical, 4).background(Paper.ink.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }

    /// "All lines" on the planner: your trip, then the buses (the trains are on the LED strip above).
    @ViewBuilder private var usualLinesContent: some View {
        if let t = live.next[safe: live.pick] ?? live.next.first {
            let r = t.via.flatMap { via in RoutePlan.all.first(where: { $0.station.short == via }) }
            PlannerTripCard(trip: t, home: home, wakeTitle: r.map { "Wake me up · via \($0.station.short)" }) {
                if let r { trip.start(r) }
            }
        } else {
            Text(live.nextError ?? "Finding your next connection…").font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.85))
        }
        ForEach(panelOrder.filter(shown).filter { $0 != "train" }, id: \.self) { p in busPanel(p) }
        Button(live.showEarlier ? "Hide earlier ones" : "Show more earlier ones") { withAnimation { live.showEarlier.toggle() } }
            .font(BoardInk.sans(12, .semibold)).foregroundStyle(Paper.ink)
        RankLegend()
        WatchingCard(pal: pal, board: true)
        nearToggle
        nearNote
        if trip.locationDenied {
            Text("Location is off for Haltewekker. Turn it on in Settings → Privacy → Location Services, or it can’t wake you.")
                .font(HWFont.body(12, bold: true)).foregroundStyle(Paper.late)
        }
        Text("Tap any bus or train for more: it’s tracked for you from then on. Live times from Transitous, map data © OpenStreetMap contributors.")
            .font(BoardInk.sans(9.5, .regular)).foregroundStyle(Paper.ink.opacity(0.65))
    }

    @ViewBuilder private func busPanel(_ p: String) -> some View {
        switch p {
        case "board": veghelBuses
        case "buas": tripBuses(home ? "Bus to Breda station" : "Breda station → BUas", live.buas, fallback: nextBuses(first: home))
        default: tripBuses("Bus to Veghel", live.toVeghel, fallback: nextBuses(first: false))
        }
    }

    /// The buses from the Veghel stops, stop by stop.
    @ViewBuilder private var veghelBuses: some View {
        let list = live.boardShown
        let names = list.map(\.stopName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        PlannerBar(title: "Local bus services", sub: "Change stops") { liveSettings = true }
        if list.isEmpty {
            Text(live.panelsUpdated == nil ? "Loading…" : "No buses coming up right now.").font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.85))
        }
        ForEach(names, id: \.self) { name in
            PlannerStop(name: name)
            PlannerColumns()
            ForEach(list.filter { $0.stopName == name }) { d in
                let ride = live.boardRides["\(d.stopId)|\(d.tripId)"]
                PlannerBusRow(line: d.line, to: d.headsign, time: d.cancelled ? d.scheduled : d.time, scheduled: d.scheduled, live: d.live, cancelled: d.cancelled,
                              grade: d.cancelled ? nil : ride?.grade, note: ride.map { "\(Fmt.rideText($0.minutes)) to \($0.station) station, arrives \(Fmt.hhmm($0.arrival))" },
                              heading: d.heading, watched: lines.isWatched(stopId: d.stopId, line: d.line, headsign: d.headsign), picked: picked == .bus(d)) { tapBus(d) }
            }
        }
    }

    /// Buses from one of the other lists (Breda station to BUas, or to Veghel), with the last few that left.
    /// The buses of your next trips: the first ride of each (from BUas going home) or the last (to BUas, or to Veghel).
    private func nextBuses(first: Bool) -> [Ride] {
        var seen = Set<String>()
        return live.next.compactMap { first ? $0.rides.first : $0.rides.last }
            .filter { !$0.isTrain && $0.departure > Date().addingTimeInterval(-10 * 60) && seen.insert($0.tripId).inserted }
    }

    @ViewBuilder private func tripBuses(_ title: String, _ all: [PanelTrip], fallback: [Ride] = []) -> some View {
        let since = Date().addingTimeInterval(live.showEarlier ? -30 * 60 : -60)
        let list = Array(all.filter { $0.trip.first.departure > since && nearOK($0) }.prefix(8))
        PlannerBar(title: title, sub: (list.first?.trip.first ?? fallback.first).map { "from \(Fmt.place($0.fromStop))" })
        if list.isEmpty && !fallback.isEmpty {
            // its own list hasn't come in (yet): the buses from your next trips
            PlannerColumns()
            ForEach(fallback) { r in
                PlannerBusRow(line: r.line, to: r.headsign.isEmpty ? Fmt.place(r.toStop) : r.headsign, time: r.departure, scheduled: r.scheduledDeparture,
                              live: r.live, cancelled: r.cancelled, grade: r.grade, note: "\(r.rideMinutes) min ride · arrives \(Fmt.hhmm(r.arrival))",
                              heading: Heading.of(r), watched: lines.isWatched(stopId: r.fromId, line: r.line, headsign: r.headsign), picked: picked == .ride(r)) { tapRide(r) }
            }
            Text("From your next trips; the full list comes in on the next refresh.").font(BoardInk.sans(9.5, .regular)).foregroundStyle(Paper.ink.opacity(0.65))
        } else if list.isEmpty {
            Text(live.panelsUpdated == nil ? "Loading…" : "Nothing coming up right now.").font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.85))
        } else {
            PlannerColumns()
            ForEach(list) { p in
                let f = p.trip.first
                PlannerBusRow(line: f.line, to: f.headsign.isEmpty ? Fmt.place(p.trip.last.toStop) : f.headsign, time: f.departure, scheduled: f.scheduledDeparture,
                              live: f.live, cancelled: f.cancelled, grade: p.trip.rides.count == 1 ? f.grade : p.trip.last.grade, note: "\(p.trip.rideLabel) · arrives \(Fmt.hhmm(p.trip.last.arrival))",
                              heading: Heading.of(f), watched: lines.isWatched(stopId: f.fromId, line: f.line, headsign: f.headsign), picked: picked == .busTrip(p)) { tapBusTrip(p) }
            }
        }
    }

    private var nearToggle: some View {
        Button { near.on.toggle() } label: {
            Label("Near me", systemImage: near.on ? "location.fill" : "location")
                .font(BoardInk.sans(12)).foregroundStyle(near.on ? BoardInk.navy : Color.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(near.on ? Color.white : Paper.ink.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(near.on ? .isSelected : [])
    }

    @ViewBuilder private var fastestContent: some View {
        nextPass
        WatchingCard(pal: pal, board: true)
        sectionTitle("Wake me up")
        routesList
    }

    @ViewBuilder private var linesContent: some View {
        WatchingCard(pal: pal, board: true)
        HStack(alignment: .firstTextBaseline) {
            sectionTitle("Live times")
            Spacer()
            Button { near.on.toggle() } label: {
                Label("Near me", systemImage: near.on ? "location.fill" : "location")
                    .font(HWFont.body(12, bold: true)).foregroundStyle(near.on ? Color(hex: 0x0B0D14) : pal.deep)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(near.on ? pal.band : Color.black.opacity(0.5), in: Capsule())
                    .overlay(Capsule().stroke(pal.deep, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(near.on ? .isSelected : [])
        }
        nearNote
        HStack(spacing: 6) {
            ForEach(["S", "A", "B", "C"], id: \.self) { Coin(grade: $0, size: 22) }
            Text("How fast each bus or train gets you there, compared with the fastest on that route. Delays count.")
                .font(HWFont.body(12)).foregroundStyle(Paper.muted)
        }
        ForEach(panelOrder.filter(shown), id: \.self) { p in panel(p) }
        if trip.locationDenied {
            Text("Location is off for Haltewekker. Turn it on in Settings → Privacy → Location Services, or it can’t wake you.")
                .font(HWFont.body(12, bold: true)).foregroundStyle(Paper.late)
        }
        Text("Live times from Transitous, map data © OpenStreetMap contributors.").font(HWFont.body(10)).foregroundStyle(Paper.muted)
    }

    @ViewBuilder private var plannedContent: some View {
        // the school alarm: from your timetable, the trip to your first class and the alarm before it
        SchoolAlarmCard(setUp: { settings = true }, go: { openPlanGo(school: true) }, wake: { t in
            if trip.direction != .toSchool { trip.pick(.toSchool) }
            if let r = RoutePlan.from(t) { trip.start(r) }
        })
        // be there by a time: the trip that leaves the latest and still gets you there
        if planner.arrive != nil {
            ArrivePass(edit: { planByArrival = true; planning = true }, go: { openPlanGo(school: false) }, wake: { t in
                if let a = planner.arrive { trip.pick(a.out ? .toSchool : .home) }
                if let via = t.via, let r = RoutePlan.all.first(where: { $0.station.short == via }) { startReq = StartRequest(route: r) }
                else if let r = RoutePlan.from(t) { trip.start(r) }
            })
        } else {
            arriveButton
        }
        if planner.trip != nil {
            PlannedPass(edit: { planByArrival = false; planning = true }, wake: { r in
                if let t = planner.trip { trip.pick(t.out ? .toSchool : .home) }
                startReq = StartRequest(route: r)
            })
        } else {
            planButton
            Text("Pick the time of your friend’s train, today or tomorrow. You get a boarding pass with the bus before it and the bus after it, and an alarm if the train changes platform or runs late.")
                .font(HWFont.body(12)).foregroundStyle(Paper.ink.opacity(0.85))
        }
        WatchingCard(pal: pal, board: true)
    }

    @ViewBuilder private var moreContent: some View {
        Button { showDemo = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(BoardInk.navy)
                    .frame(width: 32, height: 32).background(BoardInk.yellow, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Try it at home").font(HWFont.display(17)).foregroundStyle(Paper.ink)
                    Text("A pretend trip: Fastest trip, the ride, the alarm.").font(HWFont.body(12)).foregroundStyle(Paper.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Paper.ink.opacity(0.8))
            }
            .contentShape(Rectangle())
            .brass(pal, pad: 14)
        }
        .buttonStyle(.plain)
        Button { showMoving = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "map.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(BoardInk.band, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything moving near you").font(HWFont.display(17)).foregroundStyle(Paper.ink)
                    Text("Every bus and train around you, live on a map.").font(HWFont.body(12)).foregroundStyle(Paper.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Paper.ink.opacity(0.8))
            }
            .contentShape(Rectangle())
            .brass(pal, pad: 14)
        }
        .buttonStyle(.plain)
        fold("scores", "Leaderboard", icon: "trophy.fill",
             next: scores.bestThisWeek(home: true).map { "Home \(Int($0.mins.rounded())) min" } ?? "") {
            LeaderboardView(pal: pal).padding(.top, 10)
        }
        fold("stops", "Wake me at a single stop", icon: "mappin.and.ellipse", next: "") {
            StopsList(pal: pal, start: { startReq = StartRequest(stop: $0) }, edit: { stopEdit = StopEditRequest(stop: $0) })
        }
        fold("tips", "Before you nap", icon: "moon.zzz.fill", next: "") { TipsList() }
        Text("The alarm works with your phone’s GPS, so delays and detours don’t throw it off.").font(HWFont.body(11)).foregroundStyle(Paper.muted)
        Link("Questions or problems? github.com/kupperma/Halte-wekker", destination: URL(string: "https://github.com/kupperma/Halte-wekker")!)
            .font(HWFont.body(11, bold: true)).foregroundStyle(pal.deep)
    }

    private var routesList: some View {
        VStack(spacing: 0) {
            ForEach(RoutePlan.all) { r in
                Button { startReq = StartRequest(route: r) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(r.name).font(HWFont.display(17)).foregroundStyle(Paper.ink)
                            Text(r.legs(trip.direction).map { "\($0.mode.title) to \($0.to.short)" }.joined(separator: " — ")).font(HWFont.body(12)).foregroundStyle(Paper.muted)
                        }
                        Spacer()
                        Image(systemName: "bell.and.waves.left.and.right").foregroundStyle(pal.deep)
                    }
                    .padding(.vertical, 12).padding(.horizontal, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if r.id != RoutePlan.all.last?.id { Rectangle().fill(Paper.rule).frame(height: 1) }
            }
        }
        .brass(pal, pad: 14)
    }

    // MARK: pieces

    private func toggleDirection() {
        live.go(to: nil)                                    // school or home again, not somewhere you picked
        withAnimation(.easeInOut(duration: 0.6)) { trip.pick(home ? .toSchool : .home) }
        Task { await live.refresh(trip.direction, force: true) }
    }

    @ViewBuilder private var nextPass: some View {
        if let t = live.next[safe: live.pick] {
            BoardingPass(trip: t, home: home, options: live.next, pick: $live.pick)
            if let via = t.via, let r = RoutePlan.all.first(where: { $0.station.short == via }) {
                BandButton(title: "Wake me up · via \(via)", pal: pal) { trip.start(r) }
            }
        } else {
            Text(live.nextError ?? "Finding your next connections…").font(HWFont.body(13)).foregroundStyle(Paper.muted)
                .frame(maxWidth: .infinity, alignment: .leading).brass(pal, pad: 18)
        }
    }

    private var arriveButton: some View {
        Button { planByArrival = true; planning = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "flag.checkered").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(width: 32, height: 32).background(Paper.green, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Be there by…").font(HWFont.display(17)).foregroundStyle(Paper.ink)
                    Text("Say when you want to be at school (or home). You get the trip that leaves the latest and still gets you there.").font(HWFont.body(12)).foregroundStyle(Paper.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Paper.ink.opacity(0.8))
            }
            .contentShape(Rectangle())
            .brass(pal, pad: 14)
        }
        .buttonStyle(.plain)
    }

    private var planButton: some View {
        Button { planByArrival = false; planning = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "tram.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(width: 32, height: 32).background(BoardInk.band, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plan by train time").font(HWFont.display(17)).foregroundStyle(Paper.ink)
                    Text("Pick the train you take with your friend. The buses before and after it are added for you.").font(HWFont.body(12)).foregroundStyle(Paper.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Paper.ink.opacity(0.8))
            }
            .contentShape(Rectangle())
            .brass(pal, pad: 14)
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(HWFont.display(24)).foregroundStyle(Paper.ink).padding(.top, 8)
    }

    // MARK: near me

    private var panelOrder: [String] { home ? ["buas", "train", "vhome"] : ["board", "train", "buas"] }
    private func panelFrom(_ p: String) -> [String] {
        switch p {
        case "board": return ["veghel"]
        case "vhome": return ["ht", "ehv"]
        case "train": return home ? ["bd"] : ["ehv", "ht"]
        case "buas": return home ? ["buas"] : ["bd"]
        default: return []
        }
    }
    private func shown(_ p: String) -> Bool {
        guard let n = near.nearSet else { return true }
        return panelFrom(p).contains { n.contains($0) }
    }
    private func nearOK(_ t: PanelTrip) -> Bool {
        guard let n = near.nearSet else { return true }
        return n.contains(t.from.key)
    }
    private func names(_ keys: [String]) -> String {
        let n = keys.compactMap { NearMe.places[$0]?.1 }.sorted()
        guard n.count > 1 else { return n.first ?? "" }
        return n.dropLast().joined(separator: ", ") + " and " + n.last!
    }

    @ViewBuilder private var nearNote: some View {
        if near.on {
            let visible = panelOrder.filter(shown)
            VStack(alignment: .leading, spacing: 6) {
                if near.position == nil {
                    Text(near.error ?? "Finding where you are…")
                } else if let n = near.nearSet {
                    if visible.isEmpty {
                        Text("Near \(names(Array(n))). Nothing \(home ? "home" : "to Breda") leaves from here.")
                        Button("Switch direction", action: toggleDirection).font(HWFont.body(12, bold: true)).foregroundStyle(pal.deep)
                    } else {
                        Text("Showing what leaves near \(names(Array(n.filter { k in visible.contains { panelFrom($0).contains(k) } }))).")
                    }
                } else {
                    Text("You’re not near Veghel, Den Bosch, Eindhoven or Breda, so everything is shown.")
                }
            }
            .font(HWFont.body(12)).foregroundStyle(Paper.ink.opacity(0.85))
        }
    }

    // MARK: the lists

    private func foldHeader(_ key: String, _ title: String, icon: String, next: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { if open.contains(key) { open.remove(key) } else { open.insert(key) } } } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(width: 32, height: 32).background(BoardInk.band, in: RoundedRectangle(cornerRadius: 6))
                Text(title).font(HWFont.display(17)).foregroundStyle(Paper.ink)
                Spacer()
                Text(next).font(HWFont.body(12)).foregroundStyle(pal.deep)
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Paper.ink.opacity(0.8)).rotationEffect(.degrees(open.contains(key) ? 180 : 0))
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fold<C: View>(_ key: String, _ title: String, icon: String, next: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            foldHeader(key, title, icon: icon, next: next)
            if open.contains(key) {
                Rectangle().fill(Paper.ink.opacity(0.14)).frame(height: 1).padding(.top, 8)
                content()
            }
        }
        .brass(pal, pad: 14)
    }

    private var divider: some View { Rectangle().fill(Paper.rule).frame(height: 1) }

    @ViewBuilder private func panel(_ p: String) -> some View {
        switch p {
        case "board": boardFold()
        case "train": tripsFold("train", home ? "Train home" : "Train to Breda", icon: "tram.fill", live.trains)
        case "buas": tripsFold("buas", home ? "Bus to Breda station" : "Bus to BUas", icon: "bus.fill", live.buas)
        default: tripsFold("vhome", "Bus to Veghel", icon: "bus.fill", live.toVeghel)
        }
    }

    private func head(_ key: String, _ p: PanelTrip) -> String {
        let t = p.trip
        switch key {
        case "train": return home ? "To \(p.to.short)" : "From \(p.from.short)"
        case "buas": return home ? "From \(Fmt.place(t.first.fromStop))" : "Get off at \(Fmt.place(t.last.toStop))"
        default: return "From \(p.from.short)"
        }
    }

    private func extra(_ key: String, _ p: PanelTrip) -> String {
        let t = p.trip
        switch key {
        case "train":
            let name = t.first.name.isEmpty ? "" : "\(t.first.name) · "
            let how = t.changes.isEmpty ? (t.first.name.lowercased().contains("direct") ? "no changes" : "direct") : "change at \(t.changes.joined(separator: ", "))"
            return "\(t.rideLabel) · \(name)\(how) · arrives \(Fmt.hhmm(t.last.arrival))"
        case "buas":
            if home {
                let walk = t.first.walkBefore > 0 ? "Leave BUas \(Fmt.hhmm(t.start)), \(t.first.walkBefore) min walk · " : ""
                return "\(t.rideLabel) · \(walk)at the station \(Fmt.hhmm(t.last.arrival))"
            }
            return "\(t.rideLabel) · At BUas \(Fmt.hhmm(t.end))\(t.walkAfter > 0 ? " after a \(t.walkAfter) min walk" : "")"
        default:
            return "\(t.rideLabel) · Arrives \(Fmt.place(t.last.toStop)) \(Fmt.hhmm(t.last.arrival))"
        }
    }

    private func trainHint(_ list: [PanelTrip]) -> String {
        if ns.available == false { return "Platform changes need the NS key in your relay (see the GitHub page)." }
        let crowd = list.contains { (ns.rail($0.trip.first)?.crowd ?? 0) > 0 }
        return "Tap a train to get an alarm if its platform changes or it runs late." + (crowd ? " People icons: how busy NS expects the train, from 1 (quiet) to 3 (very busy)." : "")
    }

    private func tripsFold(_ key: String, _ title: String, icon: String, _ all: [PanelTrip]) -> some View {
        let since = Date().addingTimeInterval(live.showEarlier ? -30 * 60 : -60)
        let list = Array(all.filter { $0.trip.first.departure > since && nearOK($0) }.prefix(live.showEarlier ? 12 : 6))
        let mine = planner.chosen?.tripIds ?? []
        return fold(key, title, icon: icon, next: list.first.map { "\($0.trip.first.line) · \(Fmt.hhmm($0.trip.first.departure))" } ?? "") {
            if list.isEmpty {
                Text(live.panelsUpdated == nil ? "Loading…" : "Nothing coming up right now.").font(HWFont.body(12)).foregroundStyle(Paper.muted).padding(.vertical, 12)
            }
            ForEach(list) { p in
                let t = p.trip, f = t.first, rail = f.isTrain
                let lineOn = !rail && lines.isWatched(stopId: f.fromId, line: f.line, headsign: f.headsign)
                Button {
                    if rail { watch.toggle(t, from: p.from, to: p.to) }
                    else { lines.toggle(stopId: f.fromId, stopName: f.fromStop, line: f.line, headsign: f.headsign, tripId: f.tripId, delay: f.live ? f.delay : nil) }
                } label: {
                    TripRow(trip: t, pal: pal, head: head(key, p), extra: extra(key, p), info: rail ? ns.rail(f) : nil,
                            watched: rail ? watch.isWatched(f, from: p.from) : lineOn, mine: mine.contains(f.tripId))
                }
                .buttonStyle(.plain)
                divider
            }
            Button(live.showEarlier ? "Hide earlier ones" : "Show earlier ones") { withAnimation { live.showEarlier.toggle() } }
                .font(HWFont.body(12, bold: true)).foregroundStyle(pal.deep).padding(.top, 8)
            Text(key == "train" ? trainHint(list) : "Tap a bus to watch its line: you get told when it runs late, leaves early or is cancelled.")
                .font(HWFont.body(11)).foregroundStyle(Paper.muted).padding(.top, 4)
            if let u = live.panelsUpdated { Text("Updated at \(Fmt.hhmm(u)).").font(HWFont.body(10)).foregroundStyle(Paper.muted).padding(.top, 4) }
        }
    }

    private func chip(_ label: String, _ on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label).font(HWFont.body(12, bold: true))
                .foregroundStyle(on ? Color(hex: 0x14121A) : Paper.ink)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? Paper.ink : .clear)
                .overlay(Rectangle().stroke(pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func boardFold() -> some View {
        let list = live.boardShown
        let many = stops.boardStops.count > 1
        return fold("board", "Bus in Veghel", icon: "bus.fill", next: list.first.map { "\($0.line) · \(Fmt.hhmm($0.time))" } ?? "") {
            HStack {
                Text(stops.boardTitle).font(HWFont.body(12)).foregroundStyle(Paper.muted)
                Spacer()
                Button("Change") { liveSettings = true }.font(HWFont.body(12, bold: true)).foregroundStyle(pal.deep)
            }
            .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    if many {
                        HStack(spacing: 6) {
                            chip(stops.boardStops.count == 2 ? "Both stops" : "All stops", live.stopFilter == "all") { live.stopFilter = "all" }
                            ForEach(stops.boardStops) { s in chip(s.short, live.stopFilter == s.id) { live.stopFilter = s.id } }
                        }
                    }
                    HStack(spacing: 6) {
                        if !stops.lines.isEmpty {
                            chip("My lines", live.lineFilter == "mine") { live.lineFilter = "mine" }
                            ForEach(stops.lines, id: \.self) { l in chip(l, live.lineFilter == l) { live.lineFilter = l } }
                        }
                        chip("All buses", live.lineFilter == "all") { live.lineFilter = "all" }
                        chip("Earlier", live.showEarlier) { withAnimation { live.showEarlier.toggle() } }
                    }
                }
                .padding(.vertical, 8)
            }
            if list.isEmpty {
                Text(live.panelsUpdated == nil ? "Loading…" : "No buses coming up for this choice right now.").font(HWFont.body(12)).foregroundStyle(Paper.muted).padding(.vertical, 12)
            }
            ForEach(list) { d in
                let mine = stops.boardStops.first(where: { $0.id == d.stopId })
                let stopName = mine?.name ?? d.stopName
                let label: String? = many && live.stopFilter == "all" ? (mine?.short ?? Fmt.place(d.stopName)) : nil
                BoardRow(d: d, ride: live.boardRides["\(d.stopId)|\(d.tripId)"], stopLabel: label,
                         watched: lines.isWatched(stopId: d.stopId, line: d.line, headsign: d.headsign), pal: pal) {
                    lines.toggle(stopId: d.stopId, stopName: stopName, line: d.line, headsign: d.headsign, tripId: d.tripId, delay: d.live ? d.delay : nil)
                }
                divider
            }
            Text("Tap the bell to watch a line: you get told when the next one runs late, leaves early or is cancelled, until you’re on it.")
                .font(HWFont.body(11)).foregroundStyle(Paper.muted).padding(.top, 8)
        }
    }
}

/// One departure in a list: rating, line, where to, time, ride length, and for trains what NS knows.
struct TripRow: View {
    let trip: DoorTrip
    let pal: HWPalette
    var showWalk = false
    var head: String? = nil
    var extra: String? = nil
    var info: RailInfo? = nil
    var watched = false
    var mine = false
    var body: some View {
        let r = trip.first, last = trip.last
        let st = RideText.status(r, info)
        let gone = r.cancelled || info?.cancelled == true
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 5) {
                Text(r.line).font(HWFont.display(13)).foregroundStyle(Paper.ink).frame(width: 44).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Paper.ink, lineWidth: 1.5))
                if let c = info?.crowd, c > 0 { CrowdIcons(level: c) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Coin(grade: trip.rides.count == 1 ? r.grade : last.grade, size: 22)
                    Text(head ?? (r.isTrain ? "\(r.name) to \(Fmt.place(last.toStop))" : "From \(Fmt.place(r.fromStop))")).font(HWFont.display(15)).foregroundStyle(Paper.ink)
                }
                if mine || watched {
                    HStack(spacing: 6) {
                        if mine { SmallTag(text: "YOUR PLAN", pal: pal) }
                        if watched { SmallTag(text: "WATCHING", icon: "bell.fill", pal: pal) }
                    }
                }
                Text(st.text).font(HWFont.body(12, bold: r.live)).foregroundStyle(st.warn ? Paper.late : st.ok ? Paper.ok : Paper.muted)
                Text(extra ?? "\(trip.rideLabel) · arrives \(Fmt.hhmm(showWalk ? trip.end : last.arrival))")
                    .font(HWFont.body(12)).foregroundStyle(Paper.ink.opacity(0.8))
                if r.isTrain { TrainExtras(info: info, pal: pal) }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.hhmm(r.departure)).font(HWFont.display(23)).foregroundStyle(pal.deep).strikethrough(gone)
                Text(whenText(r)).font(HWFont.body(12)).foregroundStyle(Paper.muted)
            }
        }
        .padding(.vertical, 10)
        .opacity(!gone && r.departure < Date().addingTimeInterval(-60) ? 0.55 : 1)
        .contentShape(Rectangle())
    }
    private func whenText(_ r: Ride) -> String {
        let m = Int((r.departure.timeIntervalSinceNow / 60).rounded())
        if m <= -1 { return "left \(-m) min ago" }
        return m == 0 ? "now" : "in \(m) min"
    }
}

// MARK: riding

struct RideView: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var music: NowPlaying
    @EnvironmentObject var ns: NSStore
    @EnvironmentObject var planner: Planner
    @EnvironmentObject var lines: LineWatchStore
    @Environment(\.scenePhase) private var scene
    @State private var earlier = false
    @State private var panning = Handoff.fromBoards       // started at the boards: turn round to the platform first
    @State private var walkTo: WalkTarget?
    @State private var loopRestart = 0
    @State private var screenH: CGFloat = 800
    var pal: HWPalette { .of(home: trip.direction == .home) }
    /// The ring as big as the screen allows.
    private var ringSize: CGFloat { min(250, max(170, screenH * 0.31 - (trip.phase == .awake ? 60 : 0) - (music.song == nil ? 0 : 20))) }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // the blue wall, and the trip on a sheet of paper pinned to it
            WallBackground()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    if trip.waitingToBoard { boarding } else { riding }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .paperSheet()
                if trip.phase == .awake {
                    Button { trip.legDone() } label: {
                        Text("I’M OFF, END THIS LEG").font(HWFont.display(15)).tracking(1.4).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Paper.band(home: trip.direction == .home), in: RoundedRectangle(cornerRadius: 6))
                            .shadow(color: .black.opacity(0.4), radius: 8, y: 5)
                    }.buttonStyle(.plain)
                }
                HoldButton(title: "Hold to end trip", pal: pal) { trip.endTrip() }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            WallSticker(text: "I ♥ BRABANT", fill: Paper.yellow, angle: 9).padding(.top, 4).padding(.trailing, 10)
        }
        .environment(\.seeThrough, true)
        .background { GeometryReader { g in Color.clear.onAppear { screenH = g.size.height }.onChange(of: g.size.height) { _, h in screenH = h } } }
        .sheet(item: $walkTo) { WalkMapSheet(target: $0).presentationDetents([.large]) }
        .animation(.easeInOut(duration: 0.4), value: trip.waitingToBoard)
        .onAppear {
            music.setFast(scene == .active)
            // the turn from the boards to the platform takes 1.6 s; then the station loop carries on from its first frame
            if panning {
                Handoff.fromBoards = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    loopRestart += 1
                    withAnimation(.easeOut(duration: 0.25)) { panning = false }
                }
            }
        }
        .onDisappear { music.setFast(false) }
        .onChange(of: scene) { _, s in music.setFast(s == .active) }
        .task(id: trip.index) {
            while !Task.isCancelled {
                if trip.waitingToBoard { await trip.loadUpcoming() }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private var legKicker: some View {
        Group {
            if trip.legs.count > 1 { Text("LEG \(trip.index + 1) OF \(trip.legs.count)").font(HWFont.body(11)).tracking(1.6).foregroundStyle(Paper.muted) }
        }
    }

    // MARK: still at the stop: what you can take

    private var boardingTitle: String {
        guard let l = trip.leg else { return "" }
        if trip.index == 0 && trip.route?.isFixed == true { return trip.direction == .toSchool ? "Next buses towards BUas" : "Next trains home" }
        return "Next \(l.mode == .train ? "trains" : "buses") to \(l.to.short)"
    }

    @ViewBuilder private var boarding: some View {
        let rail = trip.leg?.mode == .train
        let now = Date()
        let list = Array(trip.upcoming.filter { $0.trip.first.departure > now.addingTimeInterval(earlier ? -30 * 60 : -90) }.prefix(earlier ? 12 : 8))
        // Buses: the stop's own board, so cancelled ones and the ones that just left show too.
        let board = Array(trip.upcomingBoard.filter { d in
            earlier ? d.scheduled > now.addingTimeInterval(-30 * 60) || d.time > now.addingTimeInterval(-30 * 60)
                    : d.time > now.addingTimeInterval(-90) || (d.cancelled && d.scheduled > now.addingTimeInterval(-15 * 60))
        }.prefix(earlier ? 14 : 9))
        let mine = planner.chosen?.tripIds ?? []
        // the same band as the ride: what you're waiting for, then how it works
        PaperBand(home: trip.direction == .home) {
            VStack(alignment: .leading, spacing: 1) {
                Text(trip.legs.count > 1 ? "LEG \(trip.index + 1) OF \(trip.legs.count) · WAITING TO BOARD" : "WAITING TO BOARD")
                    .font(HWFont.body(10, bold: true)).tracking(1.6).opacity(0.85)
                Text(boardingTitle).font(HWFont.display(21)).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        sheetInfo
        Text("It notices which one you get on by itself: your GPS against the live position of every \(rail ? "train" : "bus") nearby. Or tap the one you’re on.")
            .font(HWFont.body(12)).foregroundStyle(Paper.muted).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.top, 6)
        if let l = trip.leg {
            WalkButton(title: "Show the way to \(l.from.short)") {
                walkTo = WalkTarget(name: l.from.short, lat: l.from.coordinate.latitude, lon: l.from.coordinate.longitude, rail: rail,
                                    catchText: list.first.map { "the \($0.trip.first.line) at \(Fmt.hhmm($0.trip.first.departure))" }, leaves: list.first?.trip.first.departure)
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Button(earlier ? "Hide earlier ones" : "Show earlier ones") { withAnimation { earlier.toggle() } }
                        .font(HWFont.body(12, bold: true)).foregroundStyle(pal.deep)
                }
                if list.isEmpty && board.isEmpty {
                    Text(trip.upcomingError ?? "Looking up the next \(rail ? "trains" : "buses")…").font(HWFont.body(12)).foregroundStyle(Paper.muted).padding(.vertical, 12)
                }
                if !rail && !board.isEmpty {
                    ForEach(board) { d in
                        let p = trip.upcoming.first(where: { $0.trip.first.tripId == d.tripId })
                        let ride: BoardRide? = p.map { BoardRide(minutes: $0.trip.rideMinutes, station: $0.to.short, arrival: $0.trip.last.arrival, grade: $0.trip.first.grade) }
                        BoardRow(d: d, ride: ride, stopLabel: Fmt.place(d.stopName),
                                 watched: lines.isWatched(stopId: d.stopId, line: d.line, headsign: d.headsign), pal: pal) {
                            lines.toggle(stopId: d.stopId, stopName: d.stopName, line: d.line, headsign: d.headsign, tripId: d.tripId, delay: d.live ? d.delay : nil)
                        }
                        .onTapGesture { if !d.cancelled { trip.choose(board: d) } }
                        .accessibilityAction(named: "I’m on this one") { if !d.cancelled { trip.choose(board: d) } }
                        Rectangle().fill(Paper.rule).frame(height: 1)
                    }
                } else {
                ForEach(list) { p in
                    let t = p.trip
                    Button { trip.choose(p) } label: {
                        TripRow(trip: t, pal: pal,
                                head: t.first.isTrain ? "\(t.first.name.isEmpty ? "Train" : t.first.name) to \(p.to.short)" : "To \(Fmt.place(t.last.toStop))",
                                extra: "\(t.rideLabel) · arrives \(Fmt.hhmm(t.last.arrival))",
                                info: t.first.isTrain ? ns.rail(t.first) : nil, mine: mine.contains(t.first.tripId))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Tap if you’re on this one")
                    Rectangle().fill(Paper.rule).frame(height: 1)
                }
                }
                if !rail { Text("Tap the bell to get told when a bus runs late, leaves early or is cancelled.").font(HWFont.body(11)).foregroundStyle(Paper.muted).padding(.top, 6) }
                if let u = trip.upcomingAt { Text("Updated at \(Fmt.hhmm(u)).").font(HWFont.body(10)).foregroundStyle(Paper.muted).padding(.top, 6) }
            }
        }
        .brass(pal, pad: 14)
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 12)
    }

    // MARK: on board

    /// "LEG 1 OF 3 · YOU'RE ON"
    private var rideKicker: String {
        let k = trip.vehicle == nil ? "NOW RIDING" : trip.pickedByHand ? "YOU PICKED" : "YOU’RE ON"
        return trip.legs.count > 1 ? "LEG \(trip.index + 1) OF \(trip.legs.count) · \(k)" : k
    }

    /// GPS, and how the trip started.
    private var sheetInfo: some View {
        HStack(spacing: 8) {
            Label(trip.accuracy.map { "GPS ±\(Int($0)) m" } ?? "Finding GPS…", systemImage: "location.fill")
            Spacer()
            if trip.demo { Text("DEMO").font(HWFont.body(11, bold: true)).tracking(1.4).foregroundStyle(Paper.late) }
            else if trip.autoStarted { Text("STARTED BY ITSELF").tracking(1.2).foregroundStyle(Paper.navy) }
        }
        .font(HWFont.body(11, bold: true)).foregroundStyle(Paper.muted)
        .padding(.horizontal, 16).padding(.top, 8)
    }

    @ViewBuilder private var riding: some View {
        let v = trip.vehicle
        let to = trip.leg?.to.short ?? ""
        let eta = trip.legArrival ?? trip.legTo
        PaperBand(home: trip.direction == .home) {
            HStack(spacing: 10) {
                if let v { LineBullet(line: v.line, train: v.isTrain, height: 30, minWidth: 48, font: 16) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(rideKicker).font(HWFont.body(10, bold: true)).tracking(1.6).opacity(0.85)
                    Text(v.map { "\($0.title) to \(to)" } ?? (trip.leg?.title ?? "")).font(HWFont.display(21)).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
        }
        sheetInfo
        if v == nil { Text("Looking for the bus or train you’re on…").font(HWFont.body(12)).foregroundStyle(Paper.muted).padding(.horizontal, 16).padding(.top, 2) }
        Spacer(minLength: 6)
        // the countdown: a ring that fills up as you go, with your bus or train riding round it
        TimelineView(.periodic(from: .now, by: 2)) { ctx in
            RideRing(progress: trip.progress(at: ctx.date), stops: trip.stopMarks.map(\.fraction), train: v?.isTrain ?? (trip.leg?.mode == .train),
                     accent: v.map { Paper.line($0.line, train: $0.isTrain) } ?? Paper.navy, size: ringSize) {
                ringCenter(eta: eta, to: to, now: ctx.date)
            }
        }
        .id(trip.index)
        .frame(maxWidth: .infinity)
        Spacer(minLength: 6)
        rideStats(eta: eta).padding(.horizontal, 14)
        if !trip.stopMarks.isEmpty || trip.legTo != nil { stopChips.padding(.horizontal, 14).padding(.top, 10) }
        if trip.phase == .awake {
            Text(trip.ringAtStop ? "You’re awake. It rings once more at the stop." : "You’re awake. Get your things ready.")
                .font(HWFont.body(13, bold: true)).foregroundStyle(Paper.late).frame(maxWidth: .infinity).padding(.top, 8)
        }
        if let line = afterLine { Text(line).font(HWFont.body(12)).foregroundStyle(Paper.muted).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.horizontal, 14).padding(.top, 8) }
        if let song = music.song { SongPill(song: song, pal: pal).padding(.horizontal, 14).padding(.top, 10) }
        Spacer(minLength: 10)
    }

    /// In the ring: the minutes to your stop (or the distance, before the times are known).
    @ViewBuilder private func ringCenter(eta: Date?, to: String, now: Date) -> some View {
        VStack(spacing: 2) {
            if let eta, eta > now.addingTimeInterval(-120) {
                let m = Fmt.mins(eta.timeIntervalSince(now))
                Text("\(m)").font(HWFont.display(ringSize * (m >= 100 ? 0.26 : 0.33))).foregroundStyle(Paper.ink).monospacedDigit()
                    .contentTransition(.numericText())
                Text("MIN TO \(to.uppercased())").font(HWFont.display(12)).tracking(2).foregroundStyle(pal.deep).lineLimit(1).minimumScaleFactor(0.6)
                Text("there at \(Fmt.hhmm(eta))").font(HWFont.body(14)).foregroundStyle(Paper.ink.opacity(0.9)).padding(.top, 2)
            } else {
                let parts = trip.distance.map { Fmt.distanceParts($0) } ?? ("–", "")
                Text(parts.0).font(HWFont.display(ringSize * 0.28)).foregroundStyle(Paper.ink).monospacedDigit()
                    .contentTransition(.numericText())
                Text("\(parts.1.uppercased()) TO \(to.uppercased())").font(HWFont.display(12)).tracking(2).foregroundStyle(pal.deep).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .frame(width: ringSize * 0.72)
    }

    /// Three tiles under the ring: how far, how fast, the next stop.
    private func rideStats(eta: Date?) -> some View {
        let speed = trip.speed.flatMap { $0 > 1 ? "\(Int(($0 * 3.6).rounded())) km/h" : nil }
        let next = trip.nextStop
        let minutesInRing = eta.map { $0 > Date().addingTimeInterval(-120) } ?? false
        return HStack(spacing: 8) {
            // the ring shows the minutes: the distance goes here (or the other way round)
            if minutesInRing, let d = trip.distance {
                statTile(Fmt.distance(d), "to go")
            } else if !minutesInRing, let a = trip.arrival {
                statTile(Fmt.hhmm(a), "there around")
            }
            statTile(speed ?? "–", speed == nil ? "standing still" : "speed")
            if let n = next, let t = n.arrival {
                statTile(Fmt.hhmm(t), "next: \(Fmt.place(n.name))")
            } else if let m = trip.matchMeters {
                statTile("\(m) m", "recognised")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statTile(_ big: String, _ small: String) -> some View {
        VStack(spacing: 1) {
            Text(big).font(HWFont.display(19)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
            Text(small).font(HWFont.body(11)).foregroundStyle(Paper.muted).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 9).padding(.horizontal, 6)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Paper.edge, lineWidth: 1.2))
    }

    /// The stops along the way as chips you can scroll: the next one lit, the ones you passed faded, yours in yellow.
    private var stopChips: some View {
        let now = Date()
        let marks = trip.stopMarks
        let next = marks.firstIndex { ($0.time ?? .distantFuture) > now }
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(marks.enumerated()), id: \.offset) { i, m in
                        let passed = (m.time ?? .distantFuture) <= now
                        Text("\(m.name)\(m.time.map { " " + Fmt.hhmm($0) } ?? "")").font(HWFont.body(12, bold: i == next))
                            .foregroundStyle(i == next ? Color.white : Paper.ink.opacity(passed ? 0.45 : 0.9))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(i == next ? AnyShapeStyle(Paper.line(trip.vehicle?.line ?? "", train: trip.vehicle?.isTrain ?? false)) : AnyShapeStyle(Paper.card), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(i == next ? Color.clear : Paper.edge, lineWidth: 1.2))
                            .id(i)
                    }
                    Text("\(trip.leg?.to.short ?? "")\(trip.legTo.map { " " + Fmt.hhmm($0) } ?? "")").font(HWFont.body(12, bold: true))
                        .foregroundStyle(Paper.ink).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Paper.yellow, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .onAppear { if let next { proxy.scrollTo(max(0, next - 1), anchor: .leading) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stops along the way: " + marks.map { "\($0.name)\($0.time.map { " at " + Fmt.hhmm($0) } ?? "")" }.joined(separator: ", "))
    }

    /// After the ring: where the whole trip ends and when, the next leg, and how it knows the bus.
    private var afterLine: String? {
        var parts: [String] = []
        if trip.legs.count > 1, let a = trip.arrival { parts.append("\(trip.finalName) around \(Fmt.hhmm(a))") }
        if let n = trip.nextText { parts.append(n) }
        if trip.pickedByHand { parts.append("You picked it in the list") }
        else if trip.byTimetable { parts.append("Going by its timetable") }
        else if trip.nextStop != nil, let m = trip.matchMeters { parts.append("Recognised: \(m) m from you") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The stops along the way under the track: name and time, the next one highlighted, the ones you passed faded.
/// Two rows when names would overlap.
struct StopLabels: View {
    let marks: [StopMark]
    let pal: HWPalette
    /// A shorter name where it helps ("Tilburg Univ.").
    private static func short(_ n: String) -> String {
        n.replacingOccurrences(of: "Universiteit", with: "Univ.").replacingOccurrences(of: " Centraal", with: " C.")
    }
    private static func width(_ m: StopMark) -> CGFloat { CGFloat(max(short(m.name).count, 5)) * 6.2 + 8 }
    private static func x(_ m: StopMark, _ w: CGFloat) -> CGFloat { min(w - width(m) / 2, max(width(m) / 2, MetroTrack.x(m.fraction) * w)) }
    /// Up to three rows, so names close together don't run into each other.
    private static func rows(_ marks: [StopMark], _ w: CGFloat) -> [Int] {
        var last: [CGFloat] = [-.infinity, -.infinity, -.infinity], out: [Int] = []
        for m in marks {
            let px = Self.x(m, w), half = width(m) / 2
            let row = (0..<3).first { px - half >= last[$0] + 6 } ?? (0..<3).min { last[$0] < last[$1] } ?? 0
            last[row] = px + half
            out.append(row)
        }
        return out
    }
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, rows = Self.rows(marks, w), now = Date()
            let next = marks.firstIndex { ($0.time ?? .distantFuture) > now }
            ZStack(alignment: .topLeading) {
                ForEach(Array(marks.enumerated()), id: \.offset) { i, m in
                    let passed = (m.time ?? .distantFuture) <= now
                    VStack(spacing: 0) {
                        Text(Self.short(m.name)).font(HWFont.body(10, bold: true)).lineLimit(1).fixedSize()
                        if let t = m.time { Text(Fmt.hhmm(t)).font(HWFont.body(9)) }
                    }
                    .foregroundStyle(i == next ? pal.deep : Paper.ink.opacity(passed ? 0.4 : 0.85))
                    .position(x: Self.x(m, w), y: 13 + CGFloat(rows[i]) * 26)
                }
            }
        }
        .frame(height: 26 + 26 * CGFloat(Self.rows(marks, 340).max() ?? 0))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stops along the way: " + marks.map { "\($0.name)\($0.time.map { " at " + Fmt.hhmm($0) } ?? "")" }.joined(separator: ", "))
    }
}

/// What you're listening to, under the trip.
struct SongCard: View {
    let song: Song
    let pal: HWPalette
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = song.image { Image(uiImage: img).resizable().scaledToFill() }
                else if let u = song.artURL {
                    AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { pal.paper }
                } else { ZStack { pal.paper; Image(systemName: "music.note").foregroundStyle(pal.deep) } }
            }
            .frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Paper.ink.opacity(0.3), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(song.playing ? "NOW PLAYING" : "PAUSED") · \(song.app.uppercased())").font(HWFont.body(10)).tracking(1.4).foregroundStyle(pal.deep)
                Text(song.title).font(HWFont.display(16)).foregroundStyle(Paper.ink).lineLimit(1)
                if !song.artist.isEmpty { Text(song.artist).font(HWFont.body(12)).foregroundStyle(Paper.muted).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Image(systemName: song.playing ? "waveform" : "pause.fill").foregroundStyle(pal.deep)
                .symbolEffect(.variableColor.iterative, isActive: song.playing)
        }
        .brass(pal, pad: 12)
    }
}

/// What you're listening to, small, under the ring.
struct SongPill: View {
    let song: Song
    let pal: HWPalette
    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let img = song.image { Image(uiImage: img).resizable().scaledToFill() }
                else if let u = song.artURL {
                    AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.15) }
                } else { ZStack { Color.white.opacity(0.15); Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(Paper.yellow) } }
            }
            .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Paper.ink.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(song.playing ? "NOW PLAYING" : "PAUSED") · \(song.app.uppercased())").font(HWFont.body(10, bold: true)).tracking(1.4).foregroundStyle(Paper.yellow)
                Text(song.title).font(HWFont.display(19)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                if !song.artist.isEmpty { Text(song.artist).font(HWFont.body(14)).foregroundStyle(Color.white.opacity(0.8)).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Image(systemName: song.playing ? "waveform" : "pause.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(Paper.yellow)
                .symbolEffect(.variableColor.iterative, isActive: song.playing)
                .padding(.trailing, 6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.navy, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(song.playing ? "Now playing" : "Paused"): \(song.title)\(song.artist.isEmpty ? "" : " by \(song.artist)")")
    }
}

/// The countdown ring on the ride screen: it fills up as you go, with a little bus (or train) riding round it to where
/// you are now, and a dot for each stop along the way.
struct RideRing<Center: View>: View {
    let progress: Double
    let stops: [Double]
    let train: Bool
    let accent: Color
    var size: CGFloat = 250
    @ViewBuilder let center: () -> Center
    var body: some View {
        let p = min(1, max(0, progress))
        let line: CGFloat = 14
        let r = (size - line) / 2
        ZStack {
            // a circle line on the paper: the part you've ridden in the line's colour, the stops as white stations
            Circle().stroke(Color(hex: 0xE4DFD3), lineWidth: line)
            Circle().trim(from: 0, to: p).stroke(accent, style: StrokeStyle(lineWidth: line, lineCap: .round)).rotationEffect(.degrees(-90))
            ForEach(Array(stops.enumerated()), id: \.offset) { _, f in
                Circle().fill(Color.white).frame(width: 12, height: 12).overlay(Circle().stroke(Paper.ink, lineWidth: 3))
                    .offset(y: -r).rotationEffect(.degrees(f * 360))
            }
            // the bus or train, upright, at the end of the filled part
            Image(systemName: train ? "tram.fill" : "bus.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Paper.ink)
                .frame(width: 36, height: 36).background(Color.white, in: Circle())
                .overlay(Circle().stroke(accent, lineWidth: 3.5))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                .rotationEffect(.degrees(-p * 360))
                .offset(y: -r)
                .rotationEffect(.degrees(p * 360))
            center()
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 2), value: p)
        .accessibilityElement(children: .combine)
        .accessibilityValue("Trip \(Int(p * 100)) percent done")
    }
}

/// Hold for a second to confirm, so a sleepy tap doesn't end things.
struct HoldButton: View {
    let title: String
    let pal: HWPalette
    var seconds: Double = 1.0
    let action: () -> Void
    @State private var progress: CGFloat = 0
    var body: some View {
        // a paper button pinned under the sheet; it fills up green while you hold it
        Text(title.uppercased()).font(HWFont.display(15)).tracking(1.2).foregroundStyle(Paper.navy)
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .background(alignment: .leading) { GeometryReader { g in Paper.green.opacity(0.85).frame(width: g.size.width * progress) } }
            .background(PaperFill())
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.edge, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 5)
            .onLongPressGesture(minimumDuration: seconds, perform: { progress = 0; action() }, onPressingChanged: { p in
                withAnimation(p ? .linear(duration: seconds) : .easeOut(duration: 0.2)) { progress = p ? 1 : 0 }
            })
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: the alarm

struct AlarmView: View {
    @EnvironmentObject var trip: TripManager
    @State private var glow = false
    var approach: Bool { if case .alarm(let a) = trip.phase { return a }; return true }
    var pal: HWPalette { .of(home: trip.direction == .home) }
    var body: some View {
        ZStack {
            WallBackground()
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(approach ? "Wake up" : "Get off now").font(HWFont.display(58)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 22)
                        .background(Color(hex: 0xDA421E).opacity(glow ? 1 : 0.82))
                        .padding(.horizontal, 6).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(trip.leg?.to.name ?? "").font(HWFont.display(26)).foregroundStyle(Paper.ink)
                        Text(approach ? "\(Fmt.distance(trip.distance ?? 0)) to go. Get ready to get off." : "You’re at \(trip.leg?.to.short ?? "your stop").")
                            .font(HWFont.body(16)).foregroundStyle(Paper.ink.opacity(0.85))
                        if let n = trip.nextText { Text(n).font(HWFont.body(13)).foregroundStyle(Paper.muted) }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 22)
                }
                .paperSheet()
                Spacer()
                HoldButton(title: "Hold to stop alarm", pal: pal, seconds: 1.2) { trip.stopAlarm() }
            }
            .padding(.horizontal, 14).padding(.top, 40).padding(.bottom, 8)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever()) { glow = true } }
    }
}

// MARK: arriving: the counter spins and sparkles

struct ArrivalView: View {
    @EnvironmentObject var trip: TripManager
    var browse: (() -> Void)? = nil             // to the map and the boards, while the change stays open
    @State private var spin = 0.0
    @State private var burst = false
    var pal: HWPalette { .of(home: trip.direction == .home) }
    private var nextLeg: Leg? { trip.phase == .transfer ? trip.legs[safe: trip.index + 1] : nil }
    var body: some View {
        ZStack {
            WallBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let n = nextLeg { change(n) } else { arrived }
                }
                .padding(18)
                .paperSheet()
                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if nextLeg != nil {
                        BandButton(title: "Start next leg", pal: pal) { trip.nextLeg() }
                        Button("End trip here") { trip.endTrip() }.font(HWFont.display(15)).foregroundStyle(Paper.muted).frame(maxWidth: .infinity)
                    } else {
                        BandButton(title: "Done", pal: pal) { trip.endTrip() }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                .background(LinearGradient(colors: [Paper.wallBottom.opacity(0), Paper.wallBottom], startPoint: .top, endPoint: .center))
            }
        }
        .onAppear {
            withAnimation(.timingCurve(0.45, 0.05, 0.2, 1, duration: 1.15)) { spin = 360 }
            withAnimation(.easeOut(duration: 1.1)) { burst = true }
        }
        .task(id: trip.index) {
            while !Task.isCancelled {
                if nextLeg != nil { await trip.loadUpcoming() }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    /// You're there: the zero, a little burst, and how the trip went.
    @ViewBuilder private var arrived: some View {
        ZStack(alignment: .leading) {
            Text("0").font(HWFont.display(92)).foregroundStyle(Paper.ink)
                .rotation3DEffect(.degrees(spin), axis: (x: 0, y: 1, z: 0))
            ForEach(0..<16, id: \.self) { i in
                let a = Double(i) / 16 * 2 * .pi, r = 70.0 + Double((i * 37) % 40)
                Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(Color(hex: 0xF4C542))
                    .offset(x: 30 + (burst ? cos(a) * r : 0), y: burst ? sin(a) * r * 0.8 : 0)
                    .opacity(burst ? 0 : 1).scaleEffect(burst ? 1.4 : 0.4)
            }
        }
        .padding(.top, 40)
        Text(trip.route?.isFixed == false ? "You’re at \(trip.arrivedAt ?? trip.route?.station.short ?? "your stop")" : trip.direction == .home ? "You’re home" : "You’re in Breda")
            .font(HWFont.display(34)).foregroundStyle(Paper.ink)
        Text("Trip finished.").font(HWFont.body(14)).foregroundStyle(Paper.muted)
        if let s = trip.lastScore { ScoreCard(result: s, pal: pal).frame(maxWidth: .infinity, alignment: .leading).brass(pal, pad: 18) }
    }

    /// A change: where you are, the next bus or train in one card, and what else leaves.
    @ViewBuilder private func change(_ n: Leg) -> some View {
        if let browse {
            Button(action: browse) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                    Text("MAP").font(HWFont.display(13)).tracking(1.4)
                }
                .foregroundStyle(Paper.ink).padding(.horizontal, 12).padding(.vertical, 8)
                .background(Paper.paper, in: Capsule()).shadow(color: .black.opacity(0.35), radius: 5, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the map. Your change stays open.")
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("YOU’RE AT \((trip.arrivedAt ?? trip.leg?.to.short ?? "").uppercased())").font(BoardInk.sans(12)).tracking(1.6).foregroundStyle(pal.deep)
            Text("Change at \(trip.leg?.to.short ?? "")").font(BoardInk.sans(30)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.top, 12)
        VStack(alignment: .leading, spacing: 10) {
            PlannerBar(title: "Next", sub: trip.arrival.map { "\(trip.finalName) around \(Fmt.hhmm($0))" })
            if let r = trip.next {
                let g = r.isTrain ? nil : r.grade
                HStack(spacing: 10) {
                    LineBullet(line: r.line, train: r.isTrain, grade: g, height: 28, minWidth: 46, font: 15)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.isTrain ? r.name : "Bus \(r.line)") to \(n.to.short)").font(BoardInk.sans(17)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.7)
                        Text([r.platform.map { "platform \($0)" }, "\(r.rideMinutes) min ride"].compactMap { $0 }.joined(separator: " · "))
                            .font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.8))
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Fmt.hhmm(r.departure)).font(BoardInk.sans(24)).foregroundStyle(Paper.ink)
                        Text(inMinutes(r.departure)).font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.8))
                    }
                }
            } else {
                Text("\(n.mode.title) to \(n.to.short)").font(BoardInk.sans(17)).foregroundStyle(Paper.ink)
            }
            Text("It starts by itself once you’re on board.").font(BoardInk.sans(10.5, .regular)).foregroundStyle(Paper.ink.opacity(0.65))
        }
        .padding(12)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Paper.edge, lineWidth: 1.2))
        TransferList(all: trip.upcoming, updated: trip.upcomingAt, error: trip.upcomingError, mode: n.mode, dest: n.mode == .train ? n.to.short : "Veghel", pal: pal)
            .padding(12)
            .background(Paper.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Paper.edge, lineWidth: 1.2))
    }

    private func inMinutes(_ d: Date) -> String {
        let m = Int((d.timeIntervalSinceNow / 60).rounded())
        return m <= -1 ? "left \(-m) min ago" : m == 0 ? "now" : "in \(m) min"
    }
}

// MARK: settings

struct SettingsView: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var planner: Planner
    @EnvironmentObject var live: LiveStore
    @EnvironmentObject var music: NowPlaying
    @State private var liveStops = false
    @State private var confirmReset = false
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.dismiss) private var dismissSettings
    var tryDemo: (() -> Void)? = nil
    var pal: HWPalette { .of(home: trip.direction == .home) }
    var body: some View {
        NavigationStack {
            Form {
                if let tryDemo, trip.phase == .idle {
                    Section {
                        Button { dismissSettings(); tryDemo() } label: {
                            Label("Try it at home: a pretend trip", systemImage: "play.circle.fill").foregroundStyle(pal.deep)
                        }
                    } footer: { Text("Fastest trip with the map and notifications, being recognised on the bus, the ride ring, the alarm and arriving, all pretend.") }
                }
                SchoolAlarmSection()
                FreezeSection()
                Section {
                    Toggle(isOn: $trip.autoStart) { label("Start trips by itself", "Notices when you leave your stop or station on a bus or train, and starts the alarm. Needs location set to Always.") }
                    if trip.autoStart && !trip.always {
                        Button("Allow location Always") { trip.askForAlways() }.foregroundStyle(pal.deep)
                    }
                    Toggle(isOn: $trip.announce) { label("Station announcement", "A jingle and a voice that names your stop, before the alarm.") }
                    Toggle(isOn: $trip.quietWhenInUse) { label("Just a notification when I’m on my phone", "If your phone is unlocked and in use when it would ring, you’re awake: you get one notification instead of the alarm. Locked, it rings as usual. (Only with a passcode on your phone.)") }
                    Toggle(isOn: $trip.ringAtStop) { label("Ring again at the stop", "A second alarm when you arrive, in case you dozed off again.") }
                    Toggle(isOn: $trip.autoHome) { label("Switch to Home at school", "When you reach BUas, the app switches to going home once that day. Switch back whenever you like.") }
                    Toggle(isOn: $trip.movingStation) { label("Moving station", "The station and train behind the home and ride screens. It pauses when the screen is off. Off shows a still picture.") }
                } header: { Text("Trips") }
                Section {
                    Picker("Sound", selection: $trip.soundKind) {
                        ForEach(AlarmSound.Kind.allCases) { k in Text(k.title).tag(k) }
                    }
                    .onChange(of: trip.soundKind) { _, k in trip.sound.play(preview: k) }
                    Text(trip.soundKind.detail).font(HWFont.body(12)).foregroundStyle(Paper.muted)
                    Button("Test alarm") { trip.testAlarm() }.foregroundStyle(pal.deep)
                    Picker("If music is playing", selection: $trip.pauseMusic) {
                        Text("Keep it playing").tag(false)
                        Text("Pause it").tag(true)
                    }
                    Text(trip.pauseMusic ? "The loudest option: your music stops while it rings. To start it again, press play on your earbuds."
                                         : "The alarm plays over your music, a little louder than it.").font(HWFont.body(12)).foregroundStyle(Paper.muted)
                } header: { Text("Alarm") } footer: { Text("The alarm also rings in silent mode. Keep the volume up or wear earbuds. You can stop it from the lock screen: tap Stop alarm on the trip, or on the notification.") }
                Section {
                    Picker("Backup alarm", selection: $trip.backupMinutes) {
                        Text("Off").tag(0)
                        ForEach([10, 15, 20, 25, 30, 40, 50, 60, 75, 90], id: \.self) { m in Text("After \(m) min").tag(m) }
                    }
                } header: { Text("Backup alarm") } footer: {
                    Text("On every leg it also rings after this time, even if GPS drops out. Pick a bit longer than your longest ride.")
                }
                Section {
                    Picker("Show music from", selection: $music.source) {
                        ForEach(MusicSource.allCases) { m in Text(m.title).tag(m) }
                    }
                    if music.source == .spotify { spotifyRows }
                    if music.source == .appleMusic && !music.appleMusicAllowed {
                        Text("Let Haltewekker see Apple Music: iPhone Settings → Apps → Haltewekker → Media & Apple Music.").font(HWFont.body(12)).foregroundStyle(Paper.late)
                    }
                    if let s = music.song {
                        Label("\(s.title)\(s.artist.isEmpty ? "" : " · \(s.artist)")", systemImage: s.playing ? "music.note" : "pause.fill").font(HWFont.body(13))
                    }
                    Button("Preview on the lock screen") { music.checkOnce(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { trip.previewActivity() } }
                        .foregroundStyle(pal.deep).disabled(trip.isRiding)
                } header: { Text("Lock screen") } footer: {
                    Text("During a trip your lock screen shows a little train screen: how far to go, a metro that drives along as you get closer, your arrival time and the song you’re playing. The preview runs for about a minute: lock your phone to see it.")
                }
                Section {
                    Stepper("Bus: \(String(format: "%.1f", trip.busKm)) km", value: $trip.busKm, in: 0.5...10, step: 0.5)
                    Stepper("Train: \(String(format: "%.1f", trip.trainKm)) km", value: $trip.trainKm, in: 0.5...15, step: 0.5)
                } header: { Text("Usual wake distance") } footer: { Text("Used until you pick a distance for a stop when you start. After that, it remembers your choice.") }
                Section("Your stops") {
                    Button("Live bus times stops and lines") { liveStops = true }.foregroundStyle(pal.deep)
                }
                Section {
                    Button("Reset everything", role: .destructive) { confirmReset = true }
                } footer: { Text("Haltewekker \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")") }
            }
            .scrollContentBackground(.hidden)
            .background(PaperFill().ignoresSafeArea()).preferredColorScheme(.light)
            .font(HWFont.body(15))
            .tint(pal.band)
            .navigationTitle("Settings")
            .sheet(isPresented: $liveStops, onDismiss: { Task { await live.refresh(trip.direction, force: true) } }) { LiveSettingsSheet() }
            .confirmationDialog("Reset everything?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset everything", role: .destructive) { trip.resetAll(); planner.clear() }
            } message: { Text("Your settings, learned speed ratings, leaderboard, watched trains, stops and Spotify sign-in are removed.") }
        }
    }
    @ViewBuilder private var spotifyRows: some View {
        if music.spotifyConnected {
            Label("Spotify is connected", systemImage: "checkmark.circle.fill").foregroundStyle(Paper.ok)
            Button("Check what’s playing") { music.checkOnce() }.foregroundStyle(pal.deep)
            Button("Disconnect Spotify", role: .destructive) { music.disconnectSpotify() }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spotify only tells apps what’s playing if you make a (free) Spotify app for it. Once, on developer.spotify.com with your Premium account:")
                Text("1. Dashboard → Create app. Tick “Web API”.\n2. Redirect URI: the link below.\n3. Settings → User Management: add your own name and Spotify email.\n4. Copy the Client ID and paste it here.")
            }
            .font(HWFont.body(12)).foregroundStyle(Paper.muted)
            Button { UIPasteboard.general.string = NowPlaying.redirect } label: { Label("Copy the redirect link", systemImage: "doc.on.doc") }
                .foregroundStyle(pal.deep)
            Text(NowPlaying.redirect).font(HWFont.body(11)).foregroundStyle(Paper.muted).textSelection(.enabled)
            HStack {
                TextField("Client ID", text: $music.clientId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(HWFont.body(13))
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in music.clientId = (strings.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.iconOnly).buttonBorderShape(.capsule)
            }
            Button(music.busy ? "Connecting…" : "Connect Spotify") { Task { await connectSpotify() } }
                .foregroundStyle(pal.deep)
                .disabled(music.clientId.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 || music.busy)
        }
        if let e = music.spotifyError { Text(e).font(HWFont.body(12)).foregroundStyle(Paper.late) }
    }

    private func connectSpotify() async {
        guard let url = music.spotifySignInURL() else { return }
        do {
            let back = try await webAuth.authenticate(using: url, callbackURLScheme: "haltewekker", preferredBrowserSession: .shared)
            await music.finish(back)
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { music.report("Couldn’t sign in: \(error.localizedDescription)") }
        }
    }

    private func label(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(HWFont.display(16))
            Text(d).font(HWFont.body(12)).foregroundStyle(Paper.muted)
        }
    }
}
