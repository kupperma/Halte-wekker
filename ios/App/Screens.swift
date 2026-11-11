import SwiftUI

struct RootView: View {
    @EnvironmentObject var trip: TripManager
    var body: some View {
        Group {
            switch trip.phase {
            case .idle: HomeView()
            case .alarm: AlarmView()
            case .transfer, .finished: ArrivalView()
            default: RideView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: home

struct HomeView: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var live: LiveStore
    @Environment(\.scenePhase) private var scene
    @State private var settings = false
    @State private var open: Set<String> = []
    var home: Bool { trip.direction == .home }
    var pal: HWPalette { .of(home: home) }

    var body: some View {
        ZStack {
            StationBackdrop(home: home, moving: trip.movingStation && scene == .active)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                    Button { withAnimation(.easeInOut(duration: 0.6)) { trip.direction = home ? .toSchool : .home }; Task { await live.refresh(trip.direction, force: true) } } label: {
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

                    if let t = live.next[safe: live.pick] {
                        BoardingPass(trip: t, home: home, options: live.next, pick: $live.pick)
                        if let via = t.via, let r = RoutePlan.all.first(where: { $0.station.short == via }) {
                            BandButton(title: "Wake me up · via \(via)", pal: pal) { trip.start(r) }
                        }
                    } else {
                        Text(live.nextError ?? "Finding your next connections…").font(HWFont.body(13)).foregroundStyle(HWPalette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).brass(pal, pad: 18)
                    }

                    sectionTitle("Wake me up")
                    VStack(spacing: 0) {
                        ForEach(RoutePlan.all) { r in
                            Button { trip.start(r) } label: {
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

                    sectionTitle("Live times")
                    HStack(spacing: 6) {
                        ForEach(["S", "A", "B", "C"], id: \.self) { Coin(grade: $0, size: 22) }
                        Text("How fast each bus or train gets you there, compared with the fastest on that route. Delays count.")
                            .font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
                    }
                    if home {
                        fold("buas", "Bus to Breda station", icon: "bus.fill", trips: live.buas, showWalk: true)
                        fold("train", "Train home", icon: "tram.fill", trips: live.trains)
                        fold("vhome", "Bus to Veghel", icon: "bus.fill", trips: live.toVeghel)
                    } else {
                        boardFold()
                        fold("train", "Train to Breda", icon: "tram.fill", trips: live.trains)
                        fold("buas", "Bus to BUas", icon: "bus.fill", trips: live.buas, showWalk: true)
                    }
                    if trip.locationDenied {
                        Text("Location is off for Haltewekker. Turn it on in Settings → Privacy → Location Services, or it can’t wake you.")
                            .font(HWFont.body(12, bold: true)).foregroundStyle(HWPalette.warn)
                    }
                    Link("Leaderboard, planning by train time and more on the website", destination: URL(string: "https://kupperma.github.io/Halte-wekker/")!)
                        .font(HWFont.body(12, bold: true)).foregroundStyle(pal.accent)
                    Text("Live times from Transitous, map data © OpenStreetMap contributors.").font(HWFont.body(10)).foregroundStyle(HWPalette.muted)
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $settings) { SettingsView().presentationDetents([.large]) }
        .task(id: trip.direction) {
            while !Task.isCancelled {
                if scene == .active { await live.refresh(trip.direction) }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .onChange(of: scene) { _, s in if s == .active { trip.appBecameActive(); Task { await live.refresh(trip.direction) } } }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(HWFont.display(24)).foregroundStyle(HWPalette.ink).padding(.top, 8)
    }

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

    private func fold(_ key: String, _ title: String, icon: String, trips: [DoorTrip], showWalk: Bool = false) -> some View {
        let list = trips.filter { $0.first.departure > Date().addingTimeInterval(-60) }.prefix(6)
        return VStack(alignment: .leading, spacing: 0) {
            foldHeader(key, title, icon: icon, next: list.first.map { "\($0.first.line) · \(Fmt.hhmm($0.first.departure))" } ?? "")
            if open.contains(key) {
                DottedLine(vertical: false).stroke(pal.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(height: 1.5).padding(.top, 8)
                if list.isEmpty { Text("Loading…").font(HWFont.body(12)).foregroundStyle(HWPalette.muted).padding(.vertical, 12) }
                ForEach(Array(list)) { t in
                    TripRow(trip: t, pal: pal, showWalk: showWalk)
                    Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                }
            }
        }
        .brass(pal, pad: 14)
    }

    private func boardFold() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            foldHeader("board", "Bus in Veghel", icon: "bus.fill", next: live.board.first.map { "\($0.line) · \(Fmt.hhmm($0.time))" } ?? "")
            if open.contains("board") {
                DottedLine(vertical: false).stroke(pal.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(height: 1.5).padding(.top, 8)
                if live.board.isEmpty { Text("Loading…").font(HWFont.body(12)).foregroundStyle(HWPalette.muted).padding(.vertical, 12) }
                ForEach(live.board.prefix(8)) { d in
                    HStack(alignment: .top, spacing: 10) {
                        Text(d.line).font(HWFont.display(13)).foregroundStyle(HWPalette.ink).frame(width: 44).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(HWPalette.ink, lineWidth: 1.5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.headsign).font(HWFont.display(16)).foregroundStyle(HWPalette.ink)
                            Text("\(Fmt.place(d.stopName)) · \(d.cancelled ? "cancelled" : d.live ? (abs(d.delay) >= 1 ? "\(abs(d.delay)) min \(d.delay > 0 ? "late" : "early")" : "on time") : "timetable time")\(d.platform.map { ", platform \($0)" } ?? "")")
                                .font(HWFont.body(12, bold: d.live)).foregroundStyle(d.delay >= 1 || d.cancelled ? HWPalette.warn : d.live ? HWPalette.ok : HWPalette.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.hhmm(d.time)).font(HWFont.display(23)).foregroundStyle(pal.accent).strikethrough(d.cancelled)
                            Text(Fmt.mins(d.time.timeIntervalSinceNow) == 0 ? "now" : "in \(Fmt.mins(d.time.timeIntervalSinceNow)) min").font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
                        }
                    }
                    .padding(.vertical, 10)
                    Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                }
            }
        }
        .brass(pal, pad: 14)
    }
}

/// One departure in a board: rating, line, where to, time, ride length.
struct TripRow: View {
    let trip: DoorTrip
    let pal: HWPalette
    var showWalk = false
    var body: some View {
        let r = trip.first, last = trip.rides.last!
        HStack(alignment: .top, spacing: 10) {
            Text(r.line).font(HWFont.display(13)).foregroundStyle(HWPalette.ink).frame(width: 44).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(HWPalette.ink, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Coin(grade: trip.rides.count == 1 ? r.grade : last.grade, size: 22)
                    Text(r.isTrain ? "\(r.name) to \(Fmt.place(last.toStop))" : "From \(Fmt.place(r.fromStop))").font(HWFont.display(15)).foregroundStyle(HWPalette.ink)
                }
                Text(status(r)).font(HWFont.body(12, bold: r.live)).foregroundStyle(r.delay >= 1 || r.cancelled ? HWPalette.warn : r.live ? HWPalette.ok : HWPalette.muted)
                Text("\(Fmt.mins(last.arrival.timeIntervalSince(r.departure))) min \(trip.rides.count > 1 ? "incl. change" : "ride") · arrives \(Fmt.hhmm(showWalk ? trip.end : last.arrival))")
                    .font(HWFont.body(12)).foregroundStyle(HWPalette.ink.opacity(0.8))
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.hhmm(r.departure)).font(HWFont.display(23)).foregroundStyle(pal.accent).strikethrough(r.cancelled)
                Text(Fmt.mins(r.departure.timeIntervalSinceNow) == 0 ? "now" : "in \(Fmt.mins(r.departure.timeIntervalSinceNow)) min").font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
            }
        }
        .padding(.vertical, 10)
    }
    private func status(_ r: Ride) -> String {
        let plat = r.platform.map { ", platform \($0)" } ?? ""
        if r.cancelled { return "Cancelled" }
        if r.live && abs(r.delay) >= 1 { return "\(abs(r.delay)) min \(r.delay > 0 ? "late" : "early")\(plat)" }
        return "\(r.live ? "On time" : "Timetable time")\(plat)"
    }
}

// MARK: riding

struct RideView: View {
    @EnvironmentObject var trip: TripManager
    @State private var confirmEnd = false
    var pal: HWPalette { .of(home: trip.direction == .home) }
    var body: some View {
        ZStack {
            StationBackdrop(home: trip.direction == .home, moving: false, dim: 0.72)
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
                    Text(parts.0).font(HWFont.display(104)).foregroundStyle(HWPalette.ink).monospacedDigit()
                        .shadow(color: pal.accent.opacity(0.45), radius: 22).contentTransition(.numericText())
                    Text("\(parts.1.uppercased()) TO \((trip.leg?.to.short ?? "").uppercased())").font(HWFont.display(13)).tracking(3).foregroundStyle(pal.accent)
                }
                .frame(maxWidth: .infinity).padding(.top, 16)
                Text(trip.phase == .awake ? (trip.ringAtStop ? "You’re awake. It rings once more at the stop." : "You’re awake. Get your things ready.")
                                          : "It rings at \(Fmt.distance(trip.wakeKm * 1000)) from the stop.")
                    .font(HWFont.body(13)).foregroundStyle(HWPalette.muted).frame(maxWidth: .infinity).padding(.top, 10)
                if let a = trip.arrival {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(trip.finalName) around \(Fmt.hhmm(a))").font(HWFont.display(22)).foregroundStyle(HWPalette.ink)
                        if let n = trip.nextText { Text(n).font(HWFont.body(12)).foregroundStyle(HWPalette.muted) }
                        if let la = trip.legArrival { Text("This \(trip.leg?.mode == .train ? "train" : "bus") arrives at \(Fmt.hhmm(la))").font(HWFont.body(12)).foregroundStyle(pal.accent) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).brass(pal, pad: 16).padding(.top, 22)
                }
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
    @State private var spin = 0.0
    @State private var burst = false
    var pal: HWPalette { .of(home: trip.direction == .home) }
    var body: some View {
        ZStack {
            RadialGradient(colors: [pal.paper, HWPalette.bg], center: .top, startRadius: 20, endRadius: 600).ignoresSafeArea()
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
                if trip.phase == .transfer, let n = trip.legs[safe: trip.index + 1] {
                    Text("Change at \(trip.leg?.to.short ?? "")").font(HWFont.display(34)).foregroundStyle(HWPalette.ink)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NEXT").font(HWFont.body(11)).tracking(1.8).foregroundStyle(pal.brass)
                        Text(trip.next.map { "\($0.isTrain ? $0.name : "Bus \($0.line)") at \(Fmt.hhmm($0.departure))" } ?? "\(n.mode.title) to \(n.to.short)")
                            .font(HWFont.display(22)).foregroundStyle(HWPalette.ink)
                        if let r = trip.next { Text("To \(n.to.short)\(r.platform.map { " · platform \($0)" } ?? "") · \(r.rideMinutes) min").font(HWFont.body(12)).foregroundStyle(HWPalette.muted) }
                        if let a = trip.arrival { Text("\(trip.finalName) around \(Fmt.hhmm(a))").font(HWFont.body(12, bold: true)).foregroundStyle(pal.accent) }
                        if trip.autoStart { Text("It starts the next leg by itself when you’re on board.").font(HWFont.body(11)).foregroundStyle(HWPalette.muted) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).brass(pal, pad: 16)
                    Spacer()
                    BandButton(title: "Start next leg", pal: pal) { trip.nextLeg() }
                    Button("End trip here") { trip.endTrip() }.font(HWFont.display(15)).foregroundStyle(HWPalette.muted).frame(maxWidth: .infinity)
                } else {
                    Text(trip.direction == .home ? "You’re home" : "You’re in Breda").font(HWFont.display(34)).foregroundStyle(HWPalette.ink)
                    Text("Trip finished.").font(HWFont.body(14)).foregroundStyle(HWPalette.muted)
                    Spacer()
                    BandButton(title: "Done", pal: pal) { trip.endTrip() }
                }
            }
            .padding(24)
        }
        .onAppear {
            withAnimation(.timingCurve(0.45, 0.05, 0.2, 1, duration: 1.15)) { spin = 360 }
            withAnimation(.easeOut(duration: 1.1)) { burst = true }
        }
    }
}

// MARK: settings

struct SettingsView: View {
    @EnvironmentObject var trip: TripManager
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
                    Toggle(isOn: $trip.movingStation) { label("Moving station", "The station and train behind the home screen. Off shows a still picture.") }
                } header: { Text("Trips") }
                Section {
                    Picker("Sound", selection: $trip.soundKind) {
                        ForEach(AlarmSound.Kind.allCases) { k in Text(k.title).tag(k) }
                    }
                    .onChange(of: trip.soundKind) { _, k in trip.sound.play(preview: k) }
                    Text(trip.soundKind.detail).font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
                    Button("Test alarm") { trip.testAlarm() }.foregroundStyle(pal.accent)
                } header: { Text("Alarm") } footer: { Text("The alarm plays over your music and also rings in silent mode. Keep the volume up or wear earbuds.") }
                Section("Wake me this far from my stop") {
                    Stepper("Bus: \(String(format: "%.1f", trip.busKm)) km", value: $trip.busKm, in: 0.5...10, step: 0.5)
                    Stepper("Train: \(String(format: "%.1f", trip.trainKm)) km", value: $trip.trainKm, in: 0.5...15, step: 0.5)
                }
            }
            .scrollContentBackground(.hidden)
            .background(LinearGradient(colors: [pal.paper, HWPalette.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .font(HWFont.body(15))
            .tint(pal.band)
            .navigationTitle("Settings")
        }
    }
    private func label(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(HWFont.display(16))
            Text(d).font(HWFont.body(12)).foregroundStyle(HWPalette.muted)
        }
    }
}
