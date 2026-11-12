import AuthenticationServices
import SwiftUI

struct RootView: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var watch: WatchStore
    var body: some View {
        Group {
            switch trip.phase {
            case .idle: HomeView()
            case .alarm: AlarmView()
            case .transfer, .finished: ArrivalView()
            default: RideView()
            }
        }
        .overlay {
            if let a = watch.alert {
                PlatformAlertView(alert: a, pal: .of(home: trip.direction == .home)) { watch.dismiss() }.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: watch.alert)
        .preferredColorScheme(.dark)
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
    @Environment(\.scenePhase) private var scene
    @State private var settings = false
    @State private var planning = false
    @State private var liveSettings = false
    @State private var startReq: StartRequest?
    @State private var stopEdit: StopEditRequest?
    @State private var open: Set<String> = []
    var home: Bool { trip.direction == .home }
    var pal: HWPalette { .of(home: home) }

    var body: some View {
        ZStack(alignment: .top) {
            StationBackdrop(home: home, moving: trip.movingStation && scene == .active)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    directionButton
                    if planner.trip != nil {
                        PlannedPass(edit: { planning = true }, wake: { r in
                            if let t = planner.trip { trip.pick(t.out ? .toSchool : .home) }
                            startReq = StartRequest(route: r)
                        })
                    } else {
                        nextPass
                        planButton
                    }

                    sectionTitle("Wake me up")
                    VStack(spacing: 0) {
                        ForEach(RoutePlan.all) { r in
                            Button { startReq = StartRequest(route: r) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(r.name).font(HWFont.display(17)).foregroundStyle(HWPalette.ink)
                                        Text(r.legs(trip.direction).map { "\($0.mode.title) to \($0.to.short)" }.joined(separator: " — ")).font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "bell.and.waves.left.and.right").foregroundStyle(pal.brass)
                                }
                                .padding(.vertical, 12).padding(.horizontal, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if r.id != RoutePlan.all.last?.id { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
                        }
                    }
                    .brass(pal, pad: 14)

                    HStack(alignment: .firstTextBaseline) {
                        sectionTitle("Live times")
                        Spacer()
                        Button { near.on.toggle() } label: {
                            Label("Near me", systemImage: near.on ? "location.fill" : "location")
                                .font(HWFont.body(12, bold: true)).foregroundStyle(near.on ? Color(hex: 0x0B0D14) : pal.accent)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(near.on ? pal.band : Color.black.opacity(0.5), in: Capsule())
                                .overlay(Capsule().stroke(pal.brass, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(near.on ? .isSelected : [])
                    }
                    nearNote
                    HStack(spacing: 6) {
                        ForEach(["S", "A", "B", "C"], id: \.self) { Coin(grade: $0, size: 22) }
                        Text("How fast each bus or train gets you there, compared with the fastest on that route. Delays count.")
                            .font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
                    }
                    ForEach(panelOrder.filter(shown), id: \.self) { p in panel(p) }
                    if trip.locationDenied {
                        Text("Location is off for Haltewekker. Turn it on in Settings → Privacy → Location Services, or it can’t wake you.")
                            .font(HWFont.body(12, bold: true)).foregroundStyle(HWPalette.warn)
                    }
                    Text("Live times from Transitous, map data © OpenStreetMap contributors.").font(HWFont.body(10)).foregroundStyle(HWPalette.muted)

                    sectionTitle("More")
                    fold("scores", "Leaderboard", icon: "trophy.fill",
                         next: scores.bestThisWeek(home: true).map { "Home \(Int($0.mins.rounded())) min" } ?? "") {
                        LeaderboardView(pal: pal).padding(.top, 10)
                    }
                    fold("stops", "Wake me at a single stop", icon: "mappin.and.ellipse", next: "") {
                        StopsList(pal: pal, start: { startReq = StartRequest(stop: $0) }, edit: { stopEdit = StopEditRequest(stop: $0) })
                    }
                    fold("tips", "Before you nap", icon: "moon.zzz.fill", next: "") { TipsList() }
                    Text("The alarm works with your phone’s GPS, so delays and detours don’t throw it off.").font(HWFont.body(11)).foregroundStyle(HWPalette.muted)
                    Link("Questions or problems? github.com/kupperma/Halte-wekker", destination: URL(string: "https://github.com/kupperma/Halte-wekker")!)
                        .font(HWFont.body(11, bold: true)).foregroundStyle(pal.accent)
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 40)
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
        .animation(.easeInOut(duration: 0.3), value: trip.toast)
        .sheet(isPresented: $settings) { SettingsView().presentationDetents([.large]) }
        .sheet(isPresented: $planning) { PlanSheet() }
        .sheet(isPresented: $liveSettings, onDismiss: { Task { await live.refresh(trip.direction, force: true) } }) { LiveSettingsSheet() }
        .sheet(item: $startReq) { r in StartSheet(req: r).presentationDetents([.medium, .large]) }
        .sheet(item: $stopEdit) { r in StopSheet(req: r) }
        .task(id: trip.direction) {
            while !Task.isCancelled {
                if scene == .active {
                    await live.refresh(trip.direction)
                    await planner.refresh()
                    await watch.check()
                    if near.on || (trip.autoHome && trip.direction == .toSchool) { near.locate() }
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .onChange(of: scene) { _, s in
            if s == .active {
                trip.appBecameActive()
                Task { await live.refresh(trip.direction); await planner.refresh(); await watch.check(force: true) }
            }
        }
    }

    // MARK: pieces

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Haltewekker").font(HWFont.display(32)).foregroundStyle(HWPalette.ink)
                Text("Fall asleep on the bus or train. It wakes you before your stop.").font(HWFont.body(13)).foregroundStyle(HWPalette.muted)
            }
            Spacer()
            Button { settings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .semibold)).foregroundStyle(pal.brass)
                    .frame(width: 46, height: 46).background(Color.black.opacity(0.6), in: Circle()).overlay(Circle().stroke(pal.brass, lineWidth: 1.5))
            }
            .accessibilityLabel("Settings")
        }
    }

    private func toggleDirection() {
        withAnimation(.easeInOut(duration: 0.6)) { trip.pick(home ? .toSchool : .home) }
        Task { await live.refresh(trip.direction, force: true) }
    }

    private var directionButton: some View {
        Button(action: toggleDirection) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(trip.direction.kicker.uppercased()).font(HWFont.body(11)).tracking(2.2).foregroundStyle(HWPalette.ink.opacity(0.8))
                    FlipTiles(word: trip.direction.word, pal: pal)
                    Text(home ? "Breda → Veghel · tap to switch" : "Veghel → Breda · tap to switch").font(HWFont.body(13)).foregroundStyle(HWPalette.ink.opacity(0.8))
                }
                Spacer()
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 18, weight: .bold)).foregroundStyle(pal.brass)
                    .frame(width: 46, height: 46).background(Color.black.opacity(0.6), in: Circle()).overlay(Circle().stroke(pal.brass, lineWidth: 1.5))
                    .rotationEffect(.degrees(home ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(home ? "Going home. Tap to switch to going to Breda." : "Going to Breda. Tap to switch to going home.")
    }

    @ViewBuilder private var nextPass: some View {
        if let t = live.next[safe: live.pick] {
            BoardingPass(trip: t, home: home, options: live.next, pick: $live.pick)
            if let via = t.via, let r = RoutePlan.all.first(where: { $0.station.short == via }) {
                BandButton(title: "Wake me up · via \(via)", pal: pal) { trip.start(r) }
            }
        } else {
            Text(live.nextError ?? "Finding your next connections…").font(HWFont.body(13)).foregroundStyle(HWPalette.muted)
                .frame(maxWidth: .infinity, alignment: .leading).brass(pal, pad: 18)
        }
    }

    private var planButton: some View {
        Button { planning = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "tram.fill").font(.system(size: 14)).foregroundStyle(pal.brass).frame(width: 32, height: 32).overlay(Circle().stroke(pal.brass, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plan by train time").font(HWFont.display(17)).foregroundStyle(HWPalette.ink)
                    Text("Pick the train you take with your friend. The buses before and after it are added for you.").font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(pal.brass)
            }
            .contentShape(Rectangle())
            .brass(pal, pad: 14)
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(HWFont.display(24)).foregroundStyle(HWPalette.ink).padding(.top, 8)
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
                        Button("Switch direction", action: toggleDirection).font(HWFont.body(12, bold: true)).foregroundStyle(pal.accent)
                    } else {
                        Text("Showing what leaves near \(names(Array(n.filter { k in visible.contains { panelFrom($0).contains(k) } }))).")
                    }
                } else {
                    Text("You’re not near Veghel, Den Bosch, Eindhoven or Breda, so everything is shown.")
                }
            }
            .font(HWFont.body(12)).foregroundStyle(HWPalette.ink.opacity(0.85))
        }
    }

    // MARK: the lists

    private func foldHeader(_ key: String, _ title: String, icon: String, next: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { if open.contains(key) { open.remove(key) } else { open.insert(key) } } } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(pal.brass).frame(width: 32, height: 32).overlay(Circle().stroke(pal.brass, lineWidth: 1.5))
                Text(title).font(HWFont.display(17)).foregroundStyle(HWPalette.ink)
                Spacer()
                Text(next).font(HWFont.body(12)).foregroundStyle(pal.accent)
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(pal.brass).rotationEffect(.degrees(open.contains(key) ? 180 : 0))
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fold<C: View>(_ key: String, _ title: String, icon: String, next: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            foldHeader(key, title, icon: icon, next: next)
            if open.contains(key) {
                DottedLine(vertical: false).stroke(pal.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(height: 1.5).padding(.top, 8)
                content()
            }
        }
        .brass(pal, pad: 14)
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }

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
        return "Tap a train to get an alarm if its platform changes." + (crowd ? " People icons: how busy NS expects the train, from 1 (quiet) to 3 (very busy)." : "")
    }

    private func tripsFold(_ key: String, _ title: String, icon: String, _ all: [PanelTrip]) -> some View {
        let list = Array(all.filter { $0.trip.first.departure > Date().addingTimeInterval(-60) && nearOK($0) }.prefix(6))
        let mine = planner.chosen?.tripIds ?? []
        return fold(key, title, icon: icon, next: list.first.map { "\($0.trip.first.line) · \(Fmt.hhmm($0.trip.first.departure))" } ?? "") {
            if list.isEmpty {
                Text(live.panelsUpdated == nil ? "Loading…" : "Nothing coming up right now.").font(HWFont.body(12)).foregroundStyle(HWPalette.muted).padding(.vertical, 12)
            }
            ForEach(list) { p in
                let t = p.trip, rail = t.first.isTrain
                Button { if rail { watch.toggle(t, from: p.from, to: p.to) } } label: {
                    TripRow(trip: t, pal: pal, head: head(key, p), extra: extra(key, p), info: rail ? ns.rail(t.first) : nil,
                            watched: rail && watch.isWatched(t.first, from: p.from), mine: mine.contains(t.first.tripId))
                }
                .buttonStyle(.plain)
                divider
            }
            if key == "train" { Text(trainHint(list)).font(HWFont.body(11)).foregroundStyle(HWPalette.muted).padding(.top, 8) }
            if let u = live.panelsUpdated { Text("Updated at \(Fmt.hhmm(u)).").font(HWFont.body(10)).foregroundStyle(HWPalette.muted).padding(.top, 4) }
        }
    }

    private func chip(_ label: String, _ on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label).font(HWFont.body(12, bold: true))
                .foregroundStyle(on ? Color(hex: 0x14121A) : HWPalette.ink)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? HWPalette.ink : .clear)
                .overlay(Rectangle().stroke(pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func boardStatus(_ d: BoardDeparture, showStop: Bool) -> String {
        var st: String
        if d.cancelled { st = "cancelled" }
        else if !d.live { st = "timetable time" }
        else if d.delay >= 1 { st = "\(d.delay) min late, planned \(Fmt.hhmm(d.scheduled))" }
        else if d.delay <= -1 { st = "\(-d.delay) min early, planned \(Fmt.hhmm(d.scheduled))" }
        else { st = "on time" }
        if let p = d.platform, !p.isEmpty { st += ", platform \(p)" }
        let s = st.prefix(1).uppercased() + st.dropFirst()
        return showStop ? "\(StopsStore.shared.boardStops.first { $0.id == d.stopId }?.short ?? Fmt.place(d.stopName)) · \(s)" : s
    }

    private func boardFold() -> some View {
        let list = live.boardShown
        let many = stops.boardStops.count > 1
        return fold("board", "Bus in Veghel", icon: "bus.fill", next: list.first.map { "\($0.line) · \(Fmt.hhmm($0.time))" } ?? "") {
            HStack {
                Text(stops.boardTitle).font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
                Spacer()
                Button("Change") { liveSettings = true }.font(HWFont.body(12, bold: true)).foregroundStyle(pal.accent)
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
                    if !stops.lines.isEmpty {
                        HStack(spacing: 6) {
                            chip("My lines", live.lineFilter == "mine") { live.lineFilter = "mine" }
                            ForEach(stops.lines, id: \.self) { l in chip(l, live.lineFilter == l) { live.lineFilter = l } }
                            chip("All buses", live.lineFilter == "all") { live.lineFilter = "all" }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            if list.isEmpty {
                Text(live.panelsUpdated == nil ? "Loading…" : "No buses coming up for this choice right now.").font(HWFont.body(12)).foregroundStyle(HWPalette.muted).padding(.vertical, 12)
            }
            ForEach(list) { d in
                let ride = live.boardRides["\(d.stopId)|\(d.tripId)"]
                HStack(alignment: .top, spacing: 10) {
                    Text(d.line).font(HWFont.display(13)).foregroundStyle(HWPalette.ink).frame(width: 44).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(HWPalette.ink, lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let g = ride?.grade, !d.cancelled { Coin(grade: g, size: 22) }
                            Text(d.headsign).font(HWFont.display(16)).foregroundStyle(HWPalette.ink)
                        }
                        Text(boardStatus(d, showStop: many && live.stopFilter == "all"))
                            .font(HWFont.body(12, bold: d.live)).foregroundStyle(d.delay != 0 || d.cancelled ? HWPalette.warn : d.live ? HWPalette.ok : HWPalette.muted)
                        if let r = ride, !d.cancelled {
                            Text("\(Fmt.rideText(r.minutes)) ride to \(r.station) station, arrives \(Fmt.hhmm(r.arrival))").font(HWFont.body(12)).foregroundStyle(HWPalette.ink.opacity(0.8))
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.hhmm(d.time)).font(HWFont.display(23)).foregroundStyle(pal.accent).strikethrough(d.cancelled)
                        Text(Fmt.mins(d.time.timeIntervalSinceNow) == 0 ? "now" : "in \(Fmt.mins(d.time.timeIntervalSinceNow)) min").font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
                    }
                }
                .padding(.vertical, 10)
                divider
            }
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
                Text(r.line).font(HWFont.display(13)).foregroundStyle(HWPalette.ink).frame(width: 44).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(HWPalette.ink, lineWidth: 1.5))
                if let c = info?.crowd, c > 0 { CrowdIcons(level: c) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Coin(grade: trip.rides.count == 1 ? r.grade : last.grade, size: 22)
                    Text(head ?? (r.isTrain ? "\(r.name) to \(Fmt.place(last.toStop))" : "From \(Fmt.place(r.fromStop))")).font(HWFont.display(15)).foregroundStyle(HWPalette.ink)
                }
                if mine || watched {
                    HStack(spacing: 6) {
                        if mine { SmallTag(text: "YOUR PLAN", pal: pal) }
                        if watched { SmallTag(text: "WATCHING", icon: "bell.fill", pal: pal) }
                    }
                }
                Text(st.text).font(HWFont.body(12, bold: r.live)).foregroundStyle(st.warn ? HWPalette.warn : st.ok ? HWPalette.ok : HWPalette.muted)
                Text(extra ?? "\(trip.rideLabel) · arrives \(Fmt.hhmm(showWalk ? trip.end : last.arrival))")
                    .font(HWFont.body(12)).foregroundStyle(HWPalette.ink.opacity(0.8))
                if r.isTrain { TrainExtras(info: info, pal: pal) }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.hhmm(r.departure)).font(HWFont.display(23)).foregroundStyle(pal.accent).strikethrough(gone)
                Text(Fmt.mins(r.departure.timeIntervalSinceNow) == 0 ? "now" : "in \(Fmt.mins(r.departure.timeIntervalSinceNow)) min").font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: riding

struct RideView: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var music: NowPlaying
    @Environment(\.scenePhase) private var scene
    @State private var confirmEnd = false
    var pal: HWPalette { .of(home: trip.direction == .home) }
    var body: some View {
        ZStack {
            StationBackdrop(home: trip.direction == .home, moving: trip.movingStation && scene == .active, dim: 0.62)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(trip.accuracy.map { "GPS ±\(Int($0)) m" } ?? "Finding GPS…", systemImage: "location.fill")
                        .font(HWFont.body(12)).foregroundStyle(HWPalette.ink.opacity(0.8)).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.white.opacity(0.07), in: Capsule())
                    Spacer()
                    if trip.autoStarted { Text("STARTED BY ITSELF").font(HWFont.body(10)).tracking(1.2).foregroundStyle(pal.accent) }
                }
                Spacer()
                if trip.legs.count > 1 { Text("LEG \(trip.index + 1) OF \(trip.legs.count)").font(HWFont.body(11)).tracking(1.6).foregroundStyle(HWPalette.muted) }
                Text("NOW RIDING").font(HWFont.body(11)).tracking(1.8).foregroundStyle(HWPalette.ink.opacity(0.75)).padding(.top, 8)
                Text(trip.vehicle.map { "\($0.title) to \(trip.leg?.to.short ?? "")" } ?? (trip.leg?.title ?? ""))
                    .font(HWFont.display(24)).foregroundStyle(HWPalette.ink)
                if trip.vehicle == nil { Text("Looking for the bus or train you’re on…").font(HWFont.body(12)).foregroundStyle(HWPalette.muted) }
                let parts = trip.distance.map { Fmt.distanceParts($0) } ?? ("–", "")
                VStack(spacing: 4) {
                    Text(parts.0).font(HWFont.display(music.song == nil ? 104 : 88)).foregroundStyle(HWPalette.ink).monospacedDigit()
                        .shadow(color: pal.accent.opacity(0.45), radius: 22).contentTransition(.numericText())
                    Text("\(parts.1.uppercased()) TO \((trip.leg?.to.short ?? "").uppercased())").font(HWFont.display(13)).tracking(3).foregroundStyle(pal.accent)
                }
                .frame(maxWidth: .infinity).padding(.top, 16)
                // the metro drives along as you get closer, like a song's progress bar
                TimelineView(.periodic(from: .now, by: 2)) { ctx in
                    MetroTrack(progress: trip.progress(at: ctx.date), home: trip.direction == .home).frame(height: 34)
                }
                .id(trip.index)
                .padding(.top, 12)
                HStack {
                    Text(trip.legFrom.map { Fmt.hhmm($0) } ?? (trip.leg?.from.short ?? ""))
                    Spacer()
                    Text(trip.legTo.map { "\(Fmt.hhmm($0)) \(trip.leg?.to.short ?? "")" } ?? (trip.leg?.to.short ?? ""))
                }
                .font(HWFont.body(11)).foregroundStyle(HWPalette.muted).padding(.top, 4)
                Text(trip.phase == .awake ? (trip.ringAtStop ? "You’re awake. It rings once more at the stop." : "You’re awake. Get your things ready.")
                                          : "It rings at \(Fmt.distance(trip.wakeKm * 1000)) from the stop.")
                    .font(HWFont.body(13)).foregroundStyle(HWPalette.muted).frame(maxWidth: .infinity).padding(.top, 10)
                if let a = trip.arrival {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(trip.finalName) around \(Fmt.hhmm(a))").font(HWFont.display(22)).foregroundStyle(HWPalette.ink)
                        if let n = trip.nextText { Text(n).font(HWFont.body(12)).foregroundStyle(HWPalette.muted) }
                        if let la = trip.legArrival { Text("This \(trip.leg?.mode == .train ? "train" : "bus") arrives at \(Fmt.hhmm(la))").font(HWFont.body(12)).foregroundStyle(pal.accent) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).brass(pal, pad: 16).padding(.top, 18)
                }
                if let song = music.song { SongCard(song: song, pal: pal).padding(.top, 12) }
                Spacer()
                if trip.phase == .awake {
                    Button { trip.legDone() } label: {
                        Text("I’M OFF, END THIS LEG").font(HWFont.display(15)).tracking(1.4).foregroundStyle(HWPalette.ink).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(pal.brass, lineWidth: 1.5))
                    }.buttonStyle(.plain).padding(.bottom, 8)
                }
                HoldButton(title: "Hold to end trip", pal: pal) { trip.endTrip() }
            }
            .padding(22)
        }
        .onAppear { music.setFast(scene == .active) }
        .onDisappear { music.setFast(false) }
        .onChange(of: scene) { _, s in music.setFast(s == .active) }
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
                } else { ZStack { pal.paper; Image(systemName: "music.note").foregroundStyle(pal.brass) } }
            }
            .frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(pal.brass.opacity(0.7), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(song.playing ? "NOW PLAYING" : "PAUSED") · \(song.app.uppercased())").font(HWFont.body(10)).tracking(1.4).foregroundStyle(pal.accent)
                Text(song.title).font(HWFont.display(16)).foregroundStyle(HWPalette.ink).lineLimit(1)
                if !song.artist.isEmpty { Text(song.artist).font(HWFont.body(12)).foregroundStyle(HWPalette.muted).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Image(systemName: song.playing ? "waveform" : "pause.fill").foregroundStyle(pal.accent)
                .symbolEffect(.variableColor.iterative, isActive: song.playing)
        }
        .brass(pal, pad: 12)
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
        Text(title.uppercased()).font(HWFont.display(16)).tracking(1.4).foregroundStyle(HWPalette.ink)
            .frame(maxWidth: .infinity).padding(.vertical, 20)
            .background(alignment: .leading) { GeometryReader { g in pal.band.opacity(0.35).frame(width: g.size.width * progress) } }
            .background(Color.black.opacity(0.55))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(pal.brass, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 3))
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
            RadialGradient(colors: [Color(hex: 0x5A2A10), Color(hex: 0x1A0C08)], center: .center, startRadius: 10, endRadius: glow ? 520 : 380).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Spacer()
                Text(approach ? "Wake up" : "Get off now").font(HWFont.display(64)).foregroundStyle(HWPalette.ink)
                Text(trip.leg?.to.name ?? "").font(HWFont.display(24)).foregroundStyle(HWPalette.ink)
                Text(approach ? "\(Fmt.distance(trip.distance ?? 0)) to go. Get ready to get off." : "You’re at \(trip.leg?.to.short ?? "your stop").")
                    .font(HWFont.body(15)).foregroundStyle(HWPalette.ink.opacity(0.85))
                if let n = trip.nextText { Text(n).font(HWFont.body(13)).foregroundStyle(HWPalette.muted) }
                Spacer()
                HoldButton(title: "Hold to stop alarm", pal: pal, seconds: 1.2) { trip.stopAlarm() }
            }
            .padding(24)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever()) { glow = true } }
    }
}

// MARK: arriving: the counter spins and sparkles

struct ArrivalView: View {
    @EnvironmentObject var trip: TripManager
    @StateObject private var transfers = TransferStore()
    @State private var spin = 0.0
    @State private var burst = false
    @State private var backup = 0
    var pal: HWPalette { .of(home: trip.direction == .home) }
    private var nextLeg: Leg? { trip.phase == .transfer ? trip.legs[safe: trip.index + 1] : nil }
    var body: some View {
        ZStack {
            RadialGradient(colors: [pal.paper, HWPalette.bg], center: .top, startRadius: 20, endRadius: 600).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack(alignment: .leading) {
                        Text("0").font(HWFont.display(92)).foregroundStyle(HWPalette.ink).shadow(color: pal.accent.opacity(0.5), radius: 24)
                            .rotation3DEffect(.degrees(spin), axis: (x: 0, y: 1, z: 0))
                        ForEach(0..<16, id: \.self) { i in
                            let a = Double(i) / 16 * 2 * .pi, r = 70.0 + Double((i * 37) % 40)
                            Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(Color(hex: 0xF4C542))
                                .offset(x: 30 + (burst ? cos(a) * r : 0), y: burst ? sin(a) * r * 0.8 : 0)
                                .opacity(burst ? 0 : 1).scaleEffect(burst ? 1.4 : 0.4)
                        }
                    }
                    .padding(.top, 40)
                    Text("YOU’RE AT \((trip.arrivedAt ?? "").uppercased())").font(HWFont.display(13)).tracking(3).foregroundStyle(pal.accent)
                    if let n = nextLeg {
                        Text("Change at \(trip.leg?.to.short ?? "")").font(HWFont.display(34)).foregroundStyle(HWPalette.ink)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NEXT").font(HWFont.body(11)).tracking(1.8).foregroundStyle(pal.brass)
                            Text(trip.next.map { "\($0.isTrain ? $0.name : "Bus \($0.line)") at \(Fmt.hhmm($0.departure))" } ?? "\(n.mode.title) to \(n.to.short)")
                                .font(HWFont.display(22)).foregroundStyle(HWPalette.ink)
                            if let r = trip.next { Text("To \(n.to.short)\(r.platform.map { " · platform \($0)" } ?? "") · \(r.rideMinutes) min").font(HWFont.body(12)).foregroundStyle(HWPalette.muted) }
                            Text("It rings at \(Fmt.km(trip.km(for: n))) from the stop.").font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
                            if let a = trip.arrival { Text("\(trip.finalName) around \(Fmt.hhmm(a))").font(HWFont.body(12, bold: true)).foregroundStyle(pal.accent) }
                            if trip.autoStart { Text("It starts the next leg by itself when you’re on board.").font(HWFont.body(11)).foregroundStyle(HWPalette.muted) }
                            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.vertical, 4)
                            Picker("Backup alarm", selection: $backup) {
                                Text("Backup alarm: off").tag(0)
                                ForEach([10, 15, 20, 25, 30, 40, 50, 60, 75, 90], id: \.self) { m in Text("Backup alarm after \(m) min").tag(m) }
                            }
                            .pickerStyle(.menu).tint(pal.accent).font(HWFont.body(13))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).brass(pal, pad: 16)
                        TransferList(store: transfers, mode: n.mode, dest: n.mode == .train ? n.to.short : "Veghel", pal: pal).brass(pal, pad: 14)
                    } else {
                        Text(trip.route?.single != nil ? "You’re at \(trip.arrivedAt ?? "your stop")" : trip.direction == .home ? "You’re home" : "You’re in Breda")
                            .font(HWFont.display(34)).foregroundStyle(HWPalette.ink)
                        Text("Trip finished.").font(HWFont.body(14)).foregroundStyle(HWPalette.muted)
                        if let s = trip.lastScore { ScoreCard(result: s, pal: pal).frame(maxWidth: .infinity, alignment: .leading).brass(pal, pad: 18) }
                    }
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if nextLeg != nil {
                        BandButton(title: "Start next leg", pal: pal) { trip.nextLeg(backup: backup) }
                        Button("End trip here") { trip.endTrip() }.font(HWFont.display(15)).foregroundStyle(HWPalette.muted).frame(maxWidth: .infinity)
                    } else {
                        BandButton(title: "Done", pal: pal) { trip.endTrip() }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 8)
                .background(LinearGradient(colors: [HWPalette.bg.opacity(0), HWPalette.bg], startPoint: .top, endPoint: .center))
            }
        }
        .onAppear {
            withAnimation(.timingCurve(0.45, 0.05, 0.2, 1, duration: 1.15)) { spin = 360 }
            withAnimation(.easeOut(duration: 1.1)) { burst = true }
        }
        .task(id: trip.index) {
            while !Task.isCancelled {
                if let n = nextLeg, let here = trip.leg?.to { await transfers.load(from: here, to: n.to, mode: n.mode) }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
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
    var pal: HWPalette { .of(home: trip.direction == .home) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $trip.autoStart) { label("Start trips by itself", "Notices when you leave your stop or station on a bus or train, and starts the alarm. Needs location set to Always.") }
                    if trip.autoStart && !trip.always {
                        Button("Allow location Always") { trip.askForAlways() }.foregroundStyle(pal.accent)
                    }
                    Toggle(isOn: $trip.announce) { label("Station announcement", "A jingle and a voice that names your stop, before the alarm.") }
                    Toggle(isOn: $trip.ringAtStop) { label("Ring again at the stop", "A second alarm when you arrive, in case you dozed off again.") }
                    Toggle(isOn: $trip.autoHome) { label("Switch to Home at school", "When you reach BUas, the app switches to going home once that day. Switch back whenever you like.") }
                    Toggle(isOn: $trip.movingStation) { label("Moving station", "The station and train behind the home and ride screens. It pauses when the screen is off. Off shows a still picture.") }
                } header: { Text("Trips") }
                Section {
                    Picker("Sound", selection: $trip.soundKind) {
                        ForEach(AlarmSound.Kind.allCases) { k in Text(k.title).tag(k) }
                    }
                    .onChange(of: trip.soundKind) { _, k in trip.sound.play(preview: k) }
                    Text(trip.soundKind.detail).font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
                    Button("Test alarm") { trip.testAlarm() }.foregroundStyle(pal.accent)
                    Picker("If music is playing", selection: $trip.pauseMusic) {
                        Text("Keep it playing").tag(false)
                        Text("Pause it").tag(true)
                    }
                    Text(trip.pauseMusic ? "The loudest option: your music stops while it rings. To start it again, press play on your earbuds."
                                         : "The alarm plays over your music, a little louder than it.").font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
                } header: { Text("Alarm") } footer: { Text("The alarm also rings in silent mode. Keep the volume up or wear earbuds.") }
                Section {
                    Picker("Show music from", selection: $music.source) {
                        ForEach(MusicSource.allCases) { m in Text(m.title).tag(m) }
                    }
                    if music.source == .spotify { spotifyRows }
                    if music.source == .appleMusic && !music.appleMusicAllowed {
                        Text("Let Haltewekker see Apple Music: iPhone Settings → Apps → Haltewekker → Media & Apple Music.").font(HWFont.body(12)).foregroundStyle(HWPalette.warn)
                    }
                    if let s = music.song {
                        Label("\(s.title)\(s.artist.isEmpty ? "" : " · \(s.artist)")", systemImage: s.playing ? "music.note" : "pause.fill").font(HWFont.body(13))
                    }
                    Button("Preview on the lock screen") { music.checkOnce(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { trip.previewActivity() } }
                        .foregroundStyle(pal.accent).disabled(trip.isRiding)
                } header: { Text("Lock screen") } footer: {
                    Text("During a trip your lock screen shows a little train screen: how far to go, a metro that drives along as you get closer, your arrival time and the song you’re playing. The preview runs for about a minute: lock your phone to see it.")
                }
                Section {
                    Stepper("Bus: \(String(format: "%.1f", trip.busKm)) km", value: $trip.busKm, in: 0.5...10, step: 0.5)
                    Stepper("Train: \(String(format: "%.1f", trip.trainKm)) km", value: $trip.trainKm, in: 0.5...15, step: 0.5)
                } header: { Text("Usual wake distance") } footer: { Text("Used until you pick a distance for a stop when you start. After that, it remembers your choice.") }
                Section("Your stops") {
                    Button("Live bus times stops and lines") { liveStops = true }.foregroundStyle(pal.accent)
                }
                Section {
                    Button("Reset everything", role: .destructive) { confirmReset = true }
                } footer: { Text("Haltewekker \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")") }
            }
            .scrollContentBackground(.hidden)
            .background(LinearGradient(colors: [pal.paper, HWPalette.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
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
            Label("Spotify is connected", systemImage: "checkmark.circle.fill").foregroundStyle(HWPalette.ok)
            Button("Check what’s playing") { music.checkOnce() }.foregroundStyle(pal.accent)
            Button("Disconnect Spotify", role: .destructive) { music.disconnectSpotify() }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spotify only tells apps what’s playing if you make a (free) Spotify app for it. Once, on developer.spotify.com with your Premium account:")
                Text("1. Dashboard → Create app. Tick “Web API”.\n2. Redirect URI: the link below.\n3. Settings → User Management: add your own name and Spotify email.\n4. Copy the Client ID and paste it here.")
            }
            .font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
            Button { UIPasteboard.general.string = NowPlaying.redirect } label: { Label("Copy the redirect link", systemImage: "doc.on.doc") }
                .foregroundStyle(pal.accent)
            Text(NowPlaying.redirect).font(HWFont.body(11)).foregroundStyle(HWPalette.muted).textSelection(.enabled)
            HStack {
                TextField("Client ID", text: $music.clientId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(HWFont.body(13))
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in music.clientId = (strings.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.iconOnly).buttonBorderShape(.capsule)
            }
            Button(music.busy ? "Connecting…" : "Connect Spotify") { Task { await connectSpotify() } }
                .foregroundStyle(pal.accent)
                .disabled(music.clientId.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 || music.busy)
        }
        if let e = music.spotifyError { Text(e).font(HWFont.body(12)).foregroundStyle(HWPalette.warn) }
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
            Text(d).font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
        }
    }
}
