import CoreLocation
import MapKit
import SwiftUI
import UserNotifications

/// "Fastest trip", hands-free: one tap and it plans from where you are, shows what to take next and the walk there,
/// keeps watching the fastest way (late, early, cancelled, or something faster now: it tells you and switches to that
/// one by itself), and starts the trip by itself once you're on board. It stops on its own when you're on board, when
/// you're there, after three hours, or when you leave the screen.
@MainActor
final class GoStore: ObservableObject {
    static let shared = GoStore()
    static let maxHours = 3.0
    weak var trip: TripManager?

    @Published private(set) var isOpen = false
    @Published private(set) var watching = false
    @Published private(set) var dest: Place = .veghel
    @Published private(set) var best: DoorTrip?             // the one it's watching: the fastest you can still catch
    @Published private(set) var others: [DoorTrip] = []
    @Published private(set) var error: String?
    @Published private(set) var updated: Date?
    @Published private(set) var notes: [Note] = []           // what it told you, newest first
    @Published private(set) var arrived = false
    @Published private(set) var seen: Vehicle?               // looks like you're on this one (checking)
    @Published private(set) var here: CLLocation?
    @Published private(set) var demo = false                 // pretend buses, to try it at home
    private var demoTask: Task<Void, Never>?
    struct Note: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let text: String
    }

    private var fallback: CLLocation?
    private var loop: Task<Void, Never>?
    private var detect: Task<Void, Never>?
    private var since = Date()
    private var told: [String: Int] = [:]          // a ride's trip id → the delay you were last told about
    private var toldEnd: Date?                       // the arrival you were last told about
    private var toldGo: Set<String> = []             // "time to go" sent, per ride
    private var missed: (trip: DoorTrip, at: Date)?  // the one you were catching left: tell, unless you turn out to be on it
    private var posted: [String] = []                // its notifications, so only the newest stays

    // MARK: open and close

    /// Open the screen and start watching the way to `d`.
    func open(to d: Place, from loc: CLLocation?) {
        fallback = loc
        isOpen = true
        begin(d)
    }

    /// Somewhere else to go (from the menu at the top).
    func retarget(_ d: Place) {
        guard isOpen, d != dest || !watching else { return }
        begin(d)
    }

    /// Out of the screen: everything stops, and its notifications go.
    func close() {
        stopWatching()
        isOpen = false
        clearPosted()
        demoTask?.cancel(); demoTask = nil
        if demo { demo = false; Demo.buses = [:] }
    }

    /// Watch again (after it stopped by itself).
    func again() { begin(dest) }

    private func begin(_ d: Place) {
        loop?.cancel(); detect?.cancel()
        dest = d
        best = nil; others = []; error = nil; updated = nil; notes = []; arrived = false; seen = nil
        told = [:]; toldEnd = nil; toldGo = []; missed = nil
        since = Date()
        watching = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        trip?.setGo(true)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.watching else { return }
                await self.refresh()
                // quicker when the one you're catching is close
                let soon = (self.best?.first.departure.timeIntervalSinceNow ?? .infinity) < 12 * 60
                let wait: UInt64 = self.best == nil ? 6 : soon ? 20 : 40          // nothing yet: look again soon
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
        detect = Task { [weak self] in
            var last: String?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, self.watching, !Task.isCancelled else { return }
                last = await self.checkBoarding(last)
            }
        }
    }

    private func stopWatching() {
        watching = false
        loop?.cancel(); loop = nil
        detect?.cancel(); detect = nil
        seen = nil
        trip?.setGo(false)
    }

    // MARK: the fastest way, again and again

    private func refresh() async {
        guard watching else { return }
        // the newest fix; an old one only when no new one comes (indoors)
        let fix = [trip?.lastFix, fallback].compactMap { $0 }.max { $0.timestamp < $1.timestamp }
        guard let loc = fix, loc.timestamp.timeIntervalSinceNow > -300 || Date().timeIntervalSince(since) > 20 else {
            if trip?.locationDenied == true { error = "Location is off for Haltewekker. Turn it on in Settings to plan from where you are." }
            return
        }
        here = loc
        let now = Date()
        if now.timeIntervalSince(since) > Self.maxHours * 3600 {
            stopWatching()
            tell("Stopped watching", "After \(Int(Self.maxHours)) hours it stops by itself. Open Fastest trip again when you need it.", sound: false)
            return
        }
        let target = CLLocation(latitude: dest.coordinate.latitude, longitude: dest.coordinate.longitude)
        if loc.distance(from: target) < 400 && loc.horizontalAccuracy < 200 {
            arrived = true
            stopWatching()
            return
        }
        let d = dest
        let found = await Transit.tripsFrom(loc.coordinate, to: d)
        guard watching, dest == d else { return }
        // One empty answer keeps what you had (that hasn't left).
        let list = found.isEmpty ? ([best].compactMap { $0 } + others).filter { $0.first.departure > now } : found
        // The ones you can still make: not cancelled, and you'd have had to set off at most a minute and a half ago.
        let ok = list.filter { !$0.first.cancelled && $0.start >= now.addingTimeInterval(-90) }
        var pick = ok.min { ($0.end, $0.first.departure) < ($1.end, $1.first.departure) }
        // Stay with the one you're catching unless another gets you there at least a minute sooner.
        if let cur = best, let p = pick, p.first.tripId != cur.first.tripId,
           let same = ok.filter({ $0.first.tripId == cur.first.tripId }).min(by: { $0.end < $1.end }),
           p.end > same.end.addingTimeInterval(-60) {
            pick = same
        }
        guard let p = pick else {
            if !found.isEmpty || best == nil {
                best = nil; others = []
                error = "No way to \(d.short) found from here right now. It tries again in a minute."
            }
            return
        }
        let prev = best
        best = p
        others = Array(ok.filter { $0.first.tripId != p.first.tripId }.sorted { $0.first.departure < $1.first.departure }.prefix(3))
        error = nil
        updated = now
        if let prev, prev.first.tripId != p.first.tripId {
            await switched(from: prev, to: p, found: found)
        } else if prev != nil {
            changed(p)
        }
        if prev == nil || prev!.first.tripId != p.first.tripId {
            told[p.first.tripId] = p.first.live ? p.first.delay : 0
            toldEnd = p.end
            if p.start <= now.addingTimeInterval(60) { toldGo.insert(p.first.tripId) }     // the screen (or the switch) says go now
        }
        timeToGo(p)
        if let m = missed, now.timeIntervalSince(m.at) >= 120, trip?.phase == .idle {
            missed = nil
            tell("The \(Self.what(m.trip.first)) has left", "Next: the \(Self.what(p.first)) at \(Fmt.hhmm(p.first.departure)) from \(Fmt.place(p.first.fromStop)). \(d.short) at \(Fmt.hhmm(p.end)).")
        }
    }

    /// The fastest way changed: say why, and that it's watching the new one now.
    private func switched(from old: DoorTrip, to new: DoorTrip, found: [DoorTrip]) async {
        let now = Date(), f = new.first
        let take = "the \(Self.what(f)) at \(Fmt.hhmm(f.departure)) from \(Fmt.place(f.fromStop))"
        if old.first.departure < now.addingTimeInterval(-20) {
            if missed == nil { missed = (old, now) }         // wait a little: you may be on it
            return
        }
        let o = old.first
        let cancelled = await Self.isCancelled(o)
        guard watching else { return }
        if cancelled {
            tell("\(Self.title(o)) at \(Fmt.hhmm(o.scheduledDeparture)) is cancelled", "Take \(take) instead. \(dest.short) at \(Fmt.hhmm(new.end)).")
        } else if old.start < now.addingTimeInterval(-90) {
            tell("Too late for the \(Self.what(o))", "Take \(take) instead. \(dest.short) at \(Fmt.hhmm(new.end)).")
        } else {
            let oldNow = found.filter { $0.first.tripId == o.tripId }.min(by: { $0.end < $1.end }) ?? old
            let gain = Fmt.mins(oldNow.end.timeIntervalSince(new.end))
            tell("Faster now: \(Self.title(f))", "Take \(take): \(dest.short) at \(Fmt.hhmm(new.end))\(gain >= 1 ? ", \(gain) min sooner" : ""). It watches that one for you now.")
        }
    }

    /// The same one, but later or earlier than you were told (or the rest of the trip moved).
    private func changed(_ p: DoorTrip) {
        let f = p.first
        if f.live {
            let dl = f.delay, last = told[f.tripId] ?? 0
            if abs(dl - last) >= 2 || (dl <= -1 && last > -1) || (dl == 0 && abs(last) >= 2) {
                told[f.tripId] = dl
                toldEnd = p.end
                if dl >= 1 {
                    tell("\(Self.title(f)) is \(dl) min late", "It leaves \(Fmt.hhmm(f.departure)) instead of \(Fmt.hhmm(f.scheduledDeparture)). Still your fastest: \(dest.short) at \(Fmt.hhmm(p.end)).")
                } else if dl <= -1 {
                    tell("\(Self.title(f)) leaves \(-dl) min early", "It leaves \(Fmt.hhmm(f.departure)), not \(Fmt.hhmm(f.scheduledDeparture)). Be at \(Fmt.place(f.fromStop)) in time.")
                } else {
                    tell("\(Self.title(f)) is on time again", "It leaves \(Fmt.hhmm(f.departure)) as planned. \(dest.short) at \(Fmt.hhmm(p.end)).", sound: false)
                }
                return
            }
        }
        if let e = toldEnd, abs(p.end.timeIntervalSince(e)) >= 180 {
            toldEnd = p.end
            tell("\(dest.short) at \(Fmt.hhmm(p.end)) now", "Instead of \(Fmt.hhmm(e)). Still the fastest way: the \(Self.what(f)) at \(Fmt.hhmm(f.departure)).", sound: false)
        }
    }

    /// When it's time to walk to the stop.
    private func timeToGo(_ p: DoorTrip) {
        let f = p.first, now = Date()
        guard f.walkBefore >= 2, !toldGo.contains(f.tripId), p.start <= now.addingTimeInterval(60) else { return }
        toldGo.insert(f.tripId)
        tell("Time to go", "\(f.walkBefore) min walk to \(Fmt.place(f.fromStop)) for the \(Self.what(f)) at \(Fmt.hhmm(f.departure)).")
    }

    private static func isCancelled(_ r: Ride) async -> Bool {
        let b = await Transit.board(stopIds: [r.fromId], from: r.scheduledDeparture.addingTimeInterval(-5 * 60), n: 20)
        return b.first(where: { $0.tripId == r.tripId })?.cancelled ?? false
    }

    // MARK: on board?

    /// Every few seconds: is your GPS moving with a bus or train? One look is enough for the one it's watching (or one of the
    /// others it found); any other one has to be the same twice and take you there.
    private func checkBoarding(_ last: String?) async -> String? {
        guard let trip, trip.phase == .idle, watching else { return nil }
        guard let m = await trip.matchVehicle(mode: nil) else { seen = nil; return nil }
        guard watching, trip.phase == .idle else { return nil }
        // at bus speed, not running for it while it passes you
        guard (trip.speed ?? 0) >= 3.5 else { return last }
        let twice = last == m.vehicle.tripId
        let all = [best].compactMap { $0 } + others
        if let t = all.first(where: { $0.first.tripId == m.vehicle.tripId }), m.meters < 250 || twice {
            board(t, m.vehicle)
            return nil
        }
        if twice, let loc = trip.lastFix, let ob = await LiveStore.onBoardTrips(loc, to: dest), ob.0.vehicle.tripId == m.vehicle.tripId, let t = ob.1.first {
            // a long way round is probably not a bus you're on (a car or bike next to one)
            if let b = best, t.end > b.end.addingTimeInterval(30 * 60) { seen = nil; return m.vehicle.tripId }
            guard watching, trip.phase == .idle else { return nil }
            board(t, ob.0.vehicle)
            return nil
        }
        seen = m.vehicle
        return m.vehicle.tripId
    }

    /// On board: the trip starts by itself (the ride screen takes over) and the watching stops.
    private func board(_ t: DoorTrip, _ v: Vehicle) {
        guard let r = RoutePlan.from(t), let trip else { return }
        trip.start(r, vehicle: v, auto: true)
        close()
        let c = UNMutableNotificationContent()
        c.title = "You’re on the \(v.title)"
        c.body = "Your trip to \(r.station.short) started by itself. It rings before \(r.legs(trip.direction).first?.to.short ?? "your stop")."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "goboard-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil)) { _ in }
    }

    /// "I'm on it": start the trip by hand (it still looks for which one you're on).
    func startByHand() {
        if demo, let f = best?.first, let a = f.fromLat, let o = f.fromLon {
            trip?.startDemo(from: .init(latitude: a, longitude: o), line: f.line)
            close()
            return
        }
        guard let t = best, let r = RoutePlan.from(t), let trip else { return }
        trip.start(r)
        close()
    }

    // MARK: the demo

    /// The screen with pretend buses from the stop nearest to you: what to take, the walk, the bus coming on the map, the
    /// notifications (time to go, late, something faster), then it "sees" you get on and the pretend ride starts.
    func startDemo(near loc: CLLocation?) {
        close()
        demo = true
        isOpen = true
        dest = .breda
        best = nil; others = []; error = nil; updated = nil; notes = []; arrived = false; seen = nil
        here = loc ?? trip?.lastFix
        watching = true
        demoTask = Task { [weak self] in await self?.runDemo() }
    }

    private func runDemo() async {
        let c = here?.coordinate ?? trip?.here ?? Place.veghel.coordinate
        var name = "Your nearest stop"
        var s = CLLocationCoordinate2D(latitude: c.latitude + 0.0016, longitude: c.longitude + 0.0022)
        if let n = await Transit.nearStops(c).first(where: { !$0.rail }) { name = n.name; s = .init(latitude: n.lat, longitude: n.lon) }
        guard demo, isOpen else { return }
        let metres = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: CLLocation(latitude: s.latitude, longitude: s.longitude))
        let walk = max(1, Int((metres / 80).rounded()))
        let t0 = Date()
        let ht = Place.denBosch.coordinate, bd = Place.breda.coordinate
        func bus(_ id: String, _ line: String, _ dep: TimeInterval, planned: TimeInterval? = nil, ride: TimeInterval = 20 * 60) -> Ride {
            let d = t0.addingTimeInterval(dep), p = t0.addingTimeInterval(planned ?? dep)
            return Ride(tripId: id, line: line, name: line, isTrain: false, departure: d, scheduledDeparture: p,
                        arrival: d.addingTimeInterval(ride), scheduledArrival: p.addingTimeInterval(ride), fromStop: name, fromId: "demo-stop",
                        toStop: "’s-Hertogenbosch, Centraal Station", platform: nil, live: true, cancelled: false, walkBefore: walk,
                        headsign: "Den Bosch", fromLat: s.latitude, fromLon: s.longitude, toLat: ht.latitude, toLon: ht.longitude)
        }
        func intercity(_ dep: TimeInterval) -> Ride {
            let d = t0.addingTimeInterval(dep)
            return Ride(tripId: "demo-ic-\(Int(dep))", line: "IC", name: "Intercity", isTrain: true, departure: d, scheduledDeparture: d,
                        arrival: d.addingTimeInterval(30 * 60), scheduledArrival: d.addingTimeInterval(30 * 60), fromStop: "’s-Hertogenbosch",
                        fromId: "demo-ht", toStop: "Breda", platform: "3", live: true, cancelled: false, walkBefore: 0,
                        headsign: "Roosendaal", fromLat: ht.latitude, fromLon: ht.longitude, toLat: bd.latitude, toLon: bd.longitude)
        }
        func door(_ b: Ride, _ t: Ride) -> DoorTrip { DoorTrip(rides: [b, t], start: b.departure.addingTimeInterval(Double(-walk * 60)), end: t.arrival) }
        func show(_ b: Ride) { Demo.buses[b.tripId] = Demo.Bus(line: b.line, stopName: name, stop: s, departure: b.departure, planned: b.scheduledDeparture) }
        func at(_ t: TimeInterval) async -> Bool {
            let left = t0.addingTimeInterval(t).timeIntervalSinceNow
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
            return !Task.isCancelled && demo && isOpen
        }
        let stop = Fmt.place(name)
        // the 306 in two and a half minutes, then the Intercity from Den Bosch
        let b306 = bus("demo-306", "306", 150), ic2 = intercity(150 + 28 * 60)
        let later = [door(bus("demo-306-later", "306", 150 + 15 * 60), intercity(150 + 43 * 60)),
                     door(bus("demo-305", "305", 150 + 26 * 60, ride: 24 * 60), intercity(150 + 58 * 60))]
        show(b306)
        best = door(b306, ic2); others = later; updated = Date()
        guard await at(10) else { return }
        tell("Time to go", "\(walk) min walk to \(stop) for the bus 306 at \(Fmt.hhmm(b306.departure)).")
        // it runs late (still your fastest)
        guard await at(25) else { return }
        let late = bus("demo-306", "306", 150 + 180, planned: 150)
        show(late)
        best = door(late, ic2); updated = Date()
        tell("Bus 306 is 3 min late", "It leaves \(Fmt.hhmm(late.departure)) instead of \(Fmt.hhmm(late.scheduledDeparture)). Still your fastest: Breda at \(Fmt.hhmm(ic2.arrival)).")
        // then something faster: it switches by itself
        guard await at(42) else { return }
        let b300 = bus("demo-300", "300", 105, ride: 16 * 60), ic1 = intercity(105 + 22 * 60)
        show(b300)
        let fast = door(b300, ic1)
        best = fast; others = [door(late, ic2)] + later; updated = Date()
        tell("Faster now: Bus 300", "Take the bus 300 at \(Fmt.hhmm(b300.departure)) from \(stop): Breda at \(Fmt.hhmm(fast.end)), \(Fmt.mins(ic2.arrival.timeIntervalSince(fast.end))) min sooner. It watches that one for you now.")
        // the bus is at your stop: it sees you get on, and the ride starts
        guard await at(106) else { return }
        seen = Vehicle(tripId: "demo-300", line: "300", isTrain: false)
        guard await at(113) else { return }
        trip?.startDemo(from: s, line: "300")
        close()
        let n = UNMutableNotificationContent()
        n.title = "You’re on the bus 300"
        n.body = "Your trip started by itself (demo)."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "goboard-demo", content: n, trigger: nil)) { _ in }
    }

    // MARK: telling you

    private func tell(_ title: String, _ body: String, sound: Bool = true) {
        notes.insert(Note(at: Date(), text: "\(title). \(body)"), at: 0)
        if notes.count > 5 { notes.removeLast(notes.count - 5) }
        clearPosted()                                     // only the newest stays on your lock screen
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        c.threadIdentifier = "go"
        if sound { c.sound = .default; c.interruptionLevel = .timeSensitive }
        let id = "go-\(Int(Date().timeIntervalSince1970))-\(notes.count)"
        posted.append(id)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { _ in }
    }

    private func clearPosted() {
        guard !posted.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: posted)
        posted = []
    }

    /// "bus 306", "Sprinter"
    static func what(_ r: Ride) -> String { r.isTrain ? (r.name.isEmpty ? "train" : r.name) : "bus \(r.line)" }
    /// "Bus 306", "Sprinter"
    static func title(_ r: Ride) -> String { r.isTrain ? (r.name.isEmpty ? "Train" : r.name) : "Bus \(r.line)" }
}

// MARK: the screen

/// One look: a big live map of you, the walk to your stop and the bus or train coming, with see-through cards over it:
/// what to take next, how to get there, and what happens after. It watches everything for you.
struct GoView: View {
    @EnvironmentObject var go: GoStore
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var live: LiveStore
    @EnvironmentObject var ns: NSStore
    @State private var walkTo: WalkTarget?
    @State private var liveTrack: LiveTrackTarget?
    @State private var choosing = false
    var home: Bool { trip.direction == .home }
    var pal: HWPalette { .of(home: home) }

    var body: some View {
        GeometryReader { g in
            let bar: CGFloat = 50                                   // the buttons along the top
            let window = max(220, (g.size.height - bar) * 0.47)     // the map you see above the cards
            ZStack(alignment: .top) {
                GoMap(ride: go.arrived ? nil : go.best?.first, here: go.here,
                      top: g.safeAreaInsets.top + bar, bottom: g.safeAreaInsets.top + bar + window)
                    .ignoresSafeArea()
                // a little shade under the buttons, so they read on any map
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: g.safeAreaInsets.top + bar + 30).ignoresSafeArea(edges: .top).allowsHitTesting(false)
                VStack(spacing: 0) {
                    topBar.frame(height: bar)
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            Color.clear.frame(height: window - 6)        // the map shows through here
                            content
                        }
                        .padding(.horizontal, 12).padding(.bottom, 16)
                    }
                    bottom
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .sheet(item: $walkTo) { WalkMapSheet(target: $0).presentationDetents([.large]) }
        .sheet(item: $liveTrack) { LiveBusSheet(target: $0).presentationDetents([.large]) }
        .sheet(isPresented: $choosing) {
            DestinationSheet { d in live.go(to: d); go.retarget(d.place) }
        }
    }

    private var destWord: String { go.dest.short }
    /// Home is Veghel, unless you picked somewhere yourself.
    private var goingHome: Bool { go.dest == .veghel && live.custom == nil }

    // MARK: top

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.35)) { go.close() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                    Text("MAP").font(HWFont.display(13)).tracking(1.4)
                }
                .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
            }
            .buttonStyle(.plain).accessibilityLabel("Back to the map. This stops the watching.")
            Spacer(minLength: 4)
            Menu {
                Button { to(.toSchool) } label: { Label("To school (BUas)", systemImage: "graduationcap.fill") }
                Button { to(.home) } label: { Label("Home (Veghel)", systemImage: "house.fill") }
                if !live.recents.isEmpty {
                    Section("Recent") {
                        ForEach(live.recents) { d in
                            Button { live.go(to: d); go.retarget(d.place) } label: { Label(d.name, systemImage: "mappin") }
                        }
                    }
                }
                Button { choosing = true } label: { Label("Somewhere else…", systemImage: "magnifyingglass") }
            } label: {
                HStack(spacing: 5) {
                    Text(goingHome ? "HOME" : "TO \(destWord.uppercased())").font(HWFont.display(13)).tracking(1.2).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: 170)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
            }
            .accessibilityLabel("Where you’re going: \(destWord). Tap to change.")
            HStack(spacing: 5) {
                Circle().fill(go.demo ? BoardInk.yellow : go.watching ? BoardInk.green : Color.white.opacity(0.4)).frame(width: 7, height: 7)
                Text(go.demo ? "DEMO" : go.watching ? "WATCHING" : "STOPPED").font(BoardInk.sans(10)).tracking(1)
            }
            .foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 12)
    }

    private func to(_ d: Direction) {
        live.go(to: nil)
        if trip.direction != d { withAnimation(.easeInOut(duration: 0.6)) { trip.pick(d) } }
        go.retarget(d == .toSchool ? .buas : .veghel)
    }

    // MARK: what's on it

    @ViewBuilder private var content: some View {
        if go.arrived {
            message(icon: "checkmark.circle.fill", title: "You’re at \(destWord)", text: "Nothing to catch: you’re there. It stopped watching.")
        } else if let t = go.best {
            nextCard(t)
            howToGetThere(t)
            if t.rides.count > 1 { thenCard(t) }
            watchingCard(t)
            if !go.others.isEmpty { othersCard }
        } else {
            message(icon: go.error == nil ? "location.magnifyingglass" : "exclamationmark.triangle.fill",
                    title: go.error == nil ? "Finding your fastest way" : "Nothing found yet",
                    text: go.error ?? "From where you are to \(destWord): every bus and train, live.", spinner: go.error == nil)
        }
        if !go.watching && !go.arrived {
            Button { go.again() } label: {
                Label("Watch again", systemImage: "bell.badge").font(BoardInk.sans(14)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 11).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private func message(icon: String, title: String, text: String, spinner: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if spinner { ProgressView().tint(.white) } else { Image(systemName: icon).font(.system(size: 20, weight: .bold)).foregroundStyle(BoardInk.yellow) }
                Text(title).font(BoardInk.sans(18)).foregroundStyle(.white)
            }
            Text(text).font(BoardInk.sans(13, .regular)).foregroundStyle(Color.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glass()
    }

    /// A small heading inside a card.
    private func kicker(_ t: String, _ sub: String? = nil) -> some View {
        HStack {
            Text(t.uppercased()).font(BoardInk.sans(10.5)).tracking(1.6).foregroundStyle(Color.white.opacity(0.7))
            Spacer(minLength: 4)
            if let sub { Text(sub).font(BoardInk.sans(11, .semibold)).foregroundStyle(Color.white.opacity(0.85)) }
        }
    }

    // MARK: take next

    private func nextCard(_ t: DoorTrip) -> some View {
        let f = t.first
        let info = f.isTrain ? ns.rail(f) : nil
        let st = RideText.status(f, info)
        let g = f.isTrain ? nil : f.grade
        let track = info?.track ?? f.platform ?? ""
        let fromLine = "from \(Fmt.place(f.fromStop))" + (track.isEmpty ? "" : " · platform \(track)")
        let toName = Fmt.place(f.headsign.isEmpty ? f.toStop : f.headsign)
        let mins = Fmt.mins(t.end.timeIntervalSinceNow)
        let changes = t.rides.count > 1 ? " · \(t.rides.count - 1) change\(t.rides.count > 2 ? "s" : "")" : ""
        return VStack(alignment: .leading, spacing: 10) {
            // where it gets you, and when
            VStack(alignment: .leading, spacing: 1) {
                Text(goingHome ? "Fastest way home" : "Fastest way to \(destWord)").font(BoardInk.sans(10.5)).tracking(1.6).textCase(.uppercase).foregroundStyle(Color.white.opacity(0.7))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(destWord) at \(Fmt.hhmm(t.end))").font(HWFont.display(28)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 4)
                    Text("\(Fmt.rideText(Double(mins)))\(changes)").font(BoardInk.sans(12, .semibold)).foregroundStyle(Color.white.opacity(0.85)).lineLimit(1)
                }
            }
            Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1)
            kicker("Take next")
            HStack(alignment: .center, spacing: 12) {
                Text(f.line).font(BoardInk.sans(22)).lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(f.isTrain ? Color(hex: 0x1A1A1A) : (g.map { RatingStyle.ink($0) } ?? BoardInk.navy))
                    .frame(width: 62, height: 44)
                    .background(f.isTrain ? AnyShapeStyle(BoardInk.yellow) : (g.map { RatingStyle.fill($0) } ?? AnyShapeStyle(BoardInk.route)), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(GoStore.title(f)).font(BoardInk.sans(17)).foregroundStyle(.white).lineLimit(1)
                    Text("to \(toName)").font(BoardInk.sans(13, .regular)).foregroundStyle(Color.white.opacity(0.9)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(fromLine).font(BoardInk.sans(11.5, .regular)).foregroundStyle(Color.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.hhmm(f.cancelled ? f.scheduledDeparture : f.departure)).font(HWFont.display(28)).foregroundStyle(.white).monospacedDigit()
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        let m = Int((f.departure.timeIntervalSinceNow / 60).rounded(.down))
                        Text(m <= 0 ? "now" : "in \(m) min").font(BoardInk.sans(12)).foregroundStyle(m <= 2 ? BoardInk.late : Color.white.opacity(0.85))
                    }
                }
            }
            HStack(spacing: 6) {
                Circle().fill(st.warn ? BoardInk.late : st.ok ? BoardInk.green : Color.white.opacity(0.6)).frame(width: 7, height: 7)
                Text(st.text).font(BoardInk.sans(12)).foregroundStyle(st.warn ? BoardInk.late : st.ok ? BoardInk.green : Color.white.opacity(0.85)).lineLimit(2)
                Spacer(minLength: 4)
                Button { liveTrack = LiveTrackTarget(tripId: f.tripId, line: f.line, headsign: f.headsign.isEmpty ? Fmt.place(f.toStop) : f.headsign,
                                                     stopName: f.fromStop, time: f.departure, rail: f.isTrain) } label: {
                    Label("Its whole route", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(BoardInk.sans(11)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Color.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glass()
    }

    // MARK: how to get there

    @ViewBuilder private func howToGetThere(_ t: DoorTrip) -> some View {
        let f = t.first
        if let a = f.fromLat, let o = f.fromLon {
            let target = WalkTarget(name: Fmt.place(f.fromStop), lat: a, lon: o, rail: f.isTrain,
                                    catchText: "the \(GoStore.what(f)) at \(Fmt.hhmm(f.departure))", leaves: f.departure)
            let away = go.here.map { $0.distance(from: CLLocation(latitude: a, longitude: o)) } ?? 9999
            if f.walkBefore == 0 && away < 120 {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 18, weight: .bold)).foregroundStyle(BoardInk.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You’re at the stop").font(BoardInk.sans(15)).foregroundStyle(.white)
                        Text("Wait here for the \(GoStore.what(f)): you can see it coming on the map. It notices by itself when you get on.")
                            .font(BoardInk.sans(12, .regular)).foregroundStyle(Color.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14).glass()
            } else {
                HStack(alignment: .center, spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 10)) { _ in leaveRing(t) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.walkBefore > 0 ? "\(f.walkBefore) min walk to \(Fmt.place(f.fromStop))" : "Get to \(Fmt.place(f.fromStop))")
                            .font(BoardInk.sans(15)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.8)
                        Text(leaveText(t)).font(BoardInk.sans(12)).foregroundStyle(t.start <= Date().addingTimeInterval(60) ? BoardInk.late : BoardInk.green)
                        Text("Follow the dotted line on the map.").font(BoardInk.sans(11, .regular)).foregroundStyle(Color.white.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                    Button { walkTo = target } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill").font(.system(size: 18, weight: .semibold))
                            Text("Turns").font(BoardInk.sans(10))
                        }
                        .foregroundStyle(.white).frame(width: 54, height: 54).background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain).accessibilityLabel("The walk, turn by turn")
                }
                .padding(14).glass()
            }
        }
    }

    private func leaveText(_ t: DoorTrip) -> String {
        let m = Int((t.start.timeIntervalSinceNow / 60).rounded(.down))
        return m <= 0 ? "Leave now" : "Leave by \(Fmt.hhmm(t.start)), in \(m) min"
    }

    /// The minutes until you have to set off, round a ring that closes as it gets nearer (the last 15 minutes).
    private func leaveRing(_ t: DoorTrip) -> some View {
        let s = t.start.timeIntervalSinceNow
        let m = max(0, Int((s / 60).rounded(.down)))
        let fill = 1 - min(1, max(0, s / (15 * 60)))
        return ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 6)
            Circle().trim(from: 0, to: fill).stroke(s <= 60 ? BoardInk.late : BoardInk.green, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                if s <= 60 {
                    Image(systemName: "figure.walk").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    Text("GO").font(BoardInk.sans(10)).foregroundStyle(.white)
                } else {
                    Text("\(m)").font(HWFont.display(24)).foregroundStyle(.white).monospacedDigit()
                    Text("MIN").font(BoardInk.sans(9)).foregroundStyle(Color.white.opacity(0.8))
                }
            }
        }
        .frame(width: 62, height: 62)
        .animation(.easeInOut(duration: 0.6), value: fill)
        .accessibilityLabel(s <= 60 ? "Leave now" : "Leave in \(m) minutes")
    }

    // MARK: then

    private func thenCard(_ t: DoorTrip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            kicker("Then", "\(destWord) \(Fmt.hhmm(t.end))")
            ForEach(Array(t.rides.enumerated()).dropFirst(), id: \.offset) { i, ride in
                let prev = t.rides[i - 1]
                let ch = Fmt.mins(ride.departure.timeIntervalSince(prev.arrival))
                Label("\(ch) min to change at \(Fmt.place(prev.toStop))\(ride.walkBefore > 0 ? ", \(ride.walkBefore) min walk" : "")", systemImage: "arrow.triangle.swap")
                    .font(BoardInk.sans(10.5, .semibold)).foregroundStyle(ch - ride.walkBefore < 2 ? BoardInk.late : Color.white.opacity(0.8))
                    .padding(.top, 4)
                PlannerRideRow(ride: ride, info: ns.rail(ride), picked: false) {
                    liveTrack = LiveTrackTarget(tripId: ride.tripId, line: ride.line, headsign: ride.headsign.isEmpty ? Fmt.place(ride.toStop) : ride.headsign,
                                                stopName: ride.fromStop, time: ride.departure, rail: ride.isTrain)
                }
            }
            if t.walkAfter > 0 {
                Label("\(t.walkAfter) min walk to \(destWord)", systemImage: "figure.walk").font(BoardInk.sans(11, .semibold)).foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .padding(14)
        .glass()
    }

    // MARK: it watches for you

    private func watchingCard(_ t: DoorTrip) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: go.watching ? "bell.and.waves.left.and.right.fill" : "bell.slash.fill").foregroundStyle(go.watching ? BoardInk.yellow : Color.white.opacity(0.6))
                    .symbolEffect(.pulse, isActive: go.watching)
                Text(go.watching ? "Watching the \(GoStore.what(t.first)) for you" : "Not watching any more").font(BoardInk.sans(14)).foregroundStyle(.white)
            }
            if let v = go.seen {
                Label("Looks like you’re on the \(v.title)… checking.", systemImage: v.isTrain ? "tram.fill" : "bus.fill")
                    .font(BoardInk.sans(12)).foregroundStyle(BoardInk.green)
            }
            if go.watching {
                Text("You get a notification if it runs late or leaves early, or if something faster comes up: then it watches that one instead. Once you’re on board, your trip starts by itself.")
                    .font(BoardInk.sans(11.5, .regular)).foregroundStyle(Color.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(go.notes) { n in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.hhmm(n.at)).font(BoardInk.sans(11)).foregroundStyle(BoardInk.yellow).monospacedDigit()
                    Text(n.text).font(BoardInk.sans(11.5, .regular)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let u = go.updated {
                Text("Checked at \(Fmt.hhmm(u)). It stops when you leave this screen.").font(BoardInk.sans(10, .regular)).foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glass()
    }

    private var othersCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            kicker("Other ways", "if you miss it").padding(.bottom, 4)
            ForEach(go.others) { o in
                HStack(spacing: 8) {
                    Text(Fmt.hhmm(o.first.departure)).font(BoardInk.sans(14)).foregroundStyle(.white).monospacedDigit().frame(width: 46, alignment: .leading)
                    HStack(spacing: 3) {
                        ForEach(Array(o.rides.enumerated()), id: \.offset) { _, r in
                            Text(r.line).font(BoardInk.sans(10.5)).lineLimit(1).foregroundStyle(r.isTrain ? Color(hex: 0x1A1A1A) : BoardInk.navy)
                                .padding(.horizontal, 5).frame(height: 17)
                                .background(r.isTrain ? BoardInk.yellow : BoardInk.route, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text("from \(Fmt.place(o.first.fromStop))").font(BoardInk.sans(11, .regular)).foregroundStyle(Color.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text("→ \(Fmt.hhmm(o.end))").font(BoardInk.sans(12)).foregroundStyle(.white)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1) }
            }
        }
        .padding(14)
        .glass()
    }

    // MARK: bottom

    @ViewBuilder private var bottom: some View {
        if go.arrived || go.best == nil {
            BandButton(title: "Back to the map", pal: pal) { withAnimation(.easeInOut(duration: 0.35)) { go.close() } }
                .padding(.horizontal, 12).padding(.bottom, 6)
        } else if let t = go.best, RoutePlan.from(t) != nil {
            Button { go.startByHand() } label: {
                HStack(spacing: 8) {
                    Image(systemName: t.first.isTrain ? "tram.fill" : "bus.fill")
                    Text("I’M ON IT · START NOW").font(HWFont.display(14)).tracking(0.8)
                }
                .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Color(hex: 0x2F9E5B).opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.bottom, 6)
            .accessibilityHint("Only if it hasn’t noticed by itself that you’re on board.")
        }
    }
}

extension View {
    /// The see-through card of the Go screen: frosted glass over the map.
    func glass(_ radius: CGFloat = 18) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.white.opacity(0.16), lineWidth: 1))
    }
}

// MARK: the map behind it

/// The big map behind the Go screen: you, the walk to your stop (dotted), the stop, and the bus or train on its way to it,
/// moving every second. It keeps all of that in view by itself, in the part of the screen above the cards, so you can just
/// follow it.
struct GoMap: View {
    let ride: Ride?
    let here: CLLocation?
    let top: CGFloat            // the screen's top part that the buttons cover
    let bottom: CGFloat         // where the cards start
    @State private var trip: LiveTrip?
    @State private var mine: Int?
    @State private var walk: MKRoute?
    @State private var walkFrom: CLLocation?
    @State private var hereNow: CLLocation?
    @State private var camera: MapCameraPosition = .automatic
    @State private var size: CGSize = .zero
    @State private var tick = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            Map(position: $camera, interactionModes: []) { content(tl.date) }
                .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        }
        .background { GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s } } }
        .onAppear { hereNow = here }
        .onChange(of: here?.timestamp) { _, _ in hereNow = here }
        .onChange(of: tick) { _, t in if t <= 2 || t % 4 == 0 { fit(Date(), animated: t > 2) } }
        .onChange(of: size) { _, _ in fit(Date(), animated: false) }
        .task(id: ride?.tripId ?? "") { await run() }
    }

    private var stop: CLLocationCoordinate2D? {
        guard let r = ride, let a = r.fromLat, let o = r.fromLon else { return nil }
        return .init(latitude: a, longitude: o)
    }

    @MapContentBuilder private func content(_ now: Date) -> some MapContent {
        UserAnnotation()
        if let walk {
            MapPolyline(walk.polyline).stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round, dash: [0.5, 11]))
        }
        if let t = trip, let m = mine, let r = ride {
            let w = t.position(now)
            let me = t.metres(ofStop: m)
            // the road it still has to take to you, and on from there (fainter)
            let rest = t.road(from: me, to: t.metres(ofStop: t.stops.count - 1))
            if rest.count > 1 {
                MapPolyline(coordinates: rest)
                    .stroke((r.isTrain ? BoardInk.yellow : BoardInk.route).opacity(0.35), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if w.metres < me - 5 {
                MapPolyline(coordinates: t.road(from: w.metres, to: me))
                    .stroke(r.isTrain ? BoardInk.yellow : BoardInk.route, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if !w.done && w.metres <= me + 30 {
                Annotation("", coordinate: t.coordinate(atMetres: w.metres), anchor: .center) {
                    HStack(spacing: 4) {
                        Image(systemName: r.isTrain ? "tram.fill" : "bus.fill").font(.system(size: 12, weight: .bold))
                        Text(r.line).font(BoardInk.sans(13))
                    }
                    .foregroundStyle(r.isTrain ? Color(hex: 0x1A1A1A) : BoardInk.navy)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(r.isTrain ? BoardInk.yellow : BoardInk.route, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                }
            }
        }
        if let s = stop, let r = ride {
            Annotation("", coordinate: s, anchor: .bottom) {
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: r.isTrain ? "tram.fill" : "bus.fill").font(.system(size: 11, weight: .bold))
                        Text("\(r.line) · \(Fmt.hhmm(r.departure))").font(BoardInk.sans(12))
                    }
                    .foregroundStyle(BoardInk.navy).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                    Image(systemName: "triangle.fill").font(.system(size: 9)).foregroundStyle(.white).rotationEffect(.degrees(180)).offset(y: -2)
                    Circle().fill(BoardInk.yellow).frame(width: 12, height: 12).overlay(Circle().stroke(BoardInk.navy, lineWidth: 2))
                }
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            }
        }
    }

    /// Its live times every 30 seconds; the walk again every minute (or when you've moved).
    private func run() async {
        trip = nil; mine = nil; walk = nil; walkFrom = nil
        var lastTrip = Date.distantPast
        while !Task.isCancelled {
            let now = Date()
            if let r = ride, now.timeIntervalSince(lastTrip) >= 30 {
                lastTrip = now
                if let t = await Transit.liveTrip(r.tripId), !Task.isCancelled {
                    trip = t
                    if mine == nil { mine = Self.findMine(t, r) }
                }
            }
            if let s = stop, let h = hereNow, walkFrom.map({ h.distance(from: $0) > 40 || now.timeIntervalSince($0.timestamp) > 60 }) ?? true {
                walkFrom = h
                let d = h.distance(from: CLLocation(latitude: s.latitude, longitude: s.longitude))
                if d > 60 { walk = await Self.walkRoute(to: s) } else { walk = nil }
            }
            tick += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func walkRoute(to s: CLLocationCoordinate2D) async -> MKRoute? {
        let req = MKDirections.Request()
        req.source = MKMapItem.forCurrentLocation()
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: s))
        req.transportType = .walking
        return try? await MKDirections(request: req).calculate().routes.first
    }

    /// Your stop on its route: the one nearest where you get on, at about the time you catch it.
    private static func findMine(_ t: LiveTrip, _ r: Ride) -> Int? {
        let c = CLLocation(latitude: r.fromLat ?? 0, longitude: r.fromLon ?? 0)
        let near = t.stops.indices.filter { CLLocation(latitude: t.stops[$0].coordinate.latitude, longitude: t.stops[$0].coordinate.longitude).distance(from: c) < 250 }
        let pool = near.isEmpty ? t.stops.indices.filter { Fmt.place(t.stops[$0].name) == Fmt.place(r.fromStop) } : near
        return pool.min { abs((t.departure($0) ?? .distantPast).timeIntervalSince(r.departure)) < abs((t.departure($1) ?? .distantPast).timeIntervalSince(r.departure)) }
    }

    /// Keep you, your stop and the bus (when it's on its way, not too far) in the window above the cards.
    private func fit(_ now: Date, animated: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        var pts: [CLLocationCoordinate2D] = []
        if let h = hereNow { pts.append(h.coordinate) }
        if let s = stop {
            pts.append(s)
            if let t = trip, let m = mine {
                let w = t.position(now), bus = t.coordinate(atMetres: w.metres)
                let far = CLLocation(latitude: bus.latitude, longitude: bus.longitude).distance(from: CLLocation(latitude: s.latitude, longitude: s.longitude))
                if !w.done && w.metres <= t.metres(ofStop: m) + 30 && far < 6000 { pts.append(bus) }
            }
        }
        guard let p0 = pts.first else { return }
        var box = MKMapRect(origin: MKMapPoint(p0), size: MKMapSize(width: 1, height: 1))
        for p in pts.dropFirst() { box = box.union(MKMapRect(origin: MKMapPoint(p), size: MKMapSize(width: 1, height: 1))) }
        let ppm = MKMapPointsPerMeterAtLatitude(p0.latitude)
        var w = max(box.size.width * 1.35, ppm * 420), h = max(box.size.height * 1.35, ppm * 420)
        let winH = max(120, bottom - top)
        let aspect = size.width / winH
        if w / h > aspect { h = w / aspect } else { w = h * aspect }
        let scale = h / winH                                       // map points per screen point
        let rect = MKMapRect(x: box.midX - w / 2, y: box.midY - h / 2 - top * scale, width: w, height: size.height * scale)
        if animated { withAnimation(.easeInOut(duration: 1.2)) { camera = .rect(rect) } } else { camera = .rect(rect) }
    }
}
