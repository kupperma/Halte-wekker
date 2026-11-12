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
                try? await Task.sleep(nanoseconds: 12_000_000_000)
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
        guard (trip.speed ?? 0) >= 4.5 else { return last }
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
        guard let t = best, let r = RoutePlan.from(t), let trip else { return }
        trip.start(r)
        close()
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

/// One look: what to take next, how to get there, and what happens after. It watches everything for you.
struct GoView: View {
    @EnvironmentObject var go: GoStore
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var live: LiveStore
    @EnvironmentObject var ns: NSStore
    @EnvironmentObject var near: NearMe
    @Environment(\.scenePhase) private var scene
    @State private var walkTo: WalkTarget?
    @State private var liveTrack: LiveTrackTarget?
    @State private var choosing = false
    var home: Bool { trip.direction == .home }
    var pal: HWPalette { .of(home: home) }

    var body: some View {
        ZStack {
            StationBackdrop(home: home, moving: trip.movingStation && scene == .active, dim: 0.5)
            VStack(spacing: 0) {
                topBar
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) { content }
                        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 16)
                }
                bottom
            }
        }
        .environment(\.seeThrough, true)
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
        HStack(spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.35)) { go.close() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                    Text("MAP").font(HWFont.display(13)).tracking(1.4)
                }
                .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
                .background(BoardInk.band.opacity(0.92), in: Capsule()).overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
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
                .background(BoardInk.band.opacity(0.92), in: Capsule()).overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
            }
            .accessibilityLabel("Where you’re going: \(destWord). Tap to change.")
            HStack(spacing: 5) {
                Circle().fill(go.watching ? BoardInk.green : Color.white.opacity(0.4)).frame(width: 7, height: 7)
                Text(go.watching ? "WATCHING" : "STOPPED").font(BoardInk.sans(10)).tracking(1)
            }
            .foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 8)
            .background(Color.black.opacity(0.35), in: Capsule())
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 16).padding(.top, 4)
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
            header(t)
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
                    .frame(maxWidth: .infinity).padding(.vertical, 11).background(BoardInk.band, in: RoundedRectangle(cornerRadius: 6))
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
        .background(panel)
        .padding(.top, 30)
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [BoardInk.blueTop, BoardInk.blueBottom], startPoint: .top, endPoint: .bottom).opacity(0.9))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.16), lineWidth: 1))
    }

    /// "FASTEST WAY HOME" · "Veghel at 16:48" · "52 min, 1 change"
    private func header(_ t: DoorTrip) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(goingHome ? "FASTEST WAY HOME" : "FASTEST WAY TO \(destWord.uppercased())")
                .font(BoardInk.sans(11)).tracking(1.8).foregroundStyle(Color.white.opacity(0.75))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(destWord) at \(Fmt.hhmm(t.end))").font(HWFont.display(30)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                let mins = Fmt.mins(t.end.timeIntervalSinceNow)
                Text("\(Fmt.rideText(Double(mins)))\(t.rides.count > 1 ? " · \(t.rides.count - 1) change\(t.rides.count > 2 ? "s" : "")" : "")")
                    .font(BoardInk.sans(13, .semibold)).foregroundStyle(Color.white.opacity(0.85))
            }
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
        return VStack(alignment: .leading, spacing: 0) {
            PlannerBar(title: "Take next", sub: f.isTrain ? "train" : "bus")
            HStack(alignment: .center, spacing: 12) {
                Text(f.line).font(BoardInk.sans(22)).lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(f.isTrain ? Color(hex: 0x1A1A1A) : (g.map { RatingStyle.ink($0) } ?? BoardInk.navy))
                    .frame(width: 62, height: 44)
                    .background(f.isTrain ? AnyShapeStyle(BoardInk.yellow) : (g.map { RatingStyle.fill($0) } ?? AnyShapeStyle(BoardInk.route)), in: RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(GoStore.title(f)).font(BoardInk.sans(17)).foregroundStyle(.white).lineLimit(1)
                    Text("to \(toName)").font(BoardInk.sans(13, .regular)).foregroundStyle(Color.white.opacity(0.9)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(fromLine)
                        .font(BoardInk.sans(11.5, .regular)).foregroundStyle(Color.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
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
            .padding(.horizontal, 12).padding(.vertical, 12)
            HStack(spacing: 6) {
                Circle().fill(st.warn ? BoardInk.late : st.ok ? BoardInk.green : Color.white.opacity(0.6)).frame(width: 7, height: 7)
                Text(st.text).font(BoardInk.sans(12)).foregroundStyle(st.warn ? BoardInk.late : st.ok ? BoardInk.green : Color.white.opacity(0.85)).lineLimit(2)
                Spacer(minLength: 4)
                Button { liveTrack = LiveTrackTarget(tripId: f.tripId, line: f.line, headsign: f.headsign.isEmpty ? Fmt.place(f.toStop) : f.headsign,
                                                     stopName: f.fromStop, time: f.departure, rail: f.isTrain) } label: {
                    Label("Where is it?", systemImage: "dot.radiowaves.left.and.right").font(BoardInk.sans(11)).foregroundStyle(BoardInk.navy)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                        Text("Wait here for the \(GoStore.what(f)). It notices by itself when you get on.").font(BoardInk.sans(12, .regular)).foregroundStyle(Color.white.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(panel)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        TimelineView(.periodic(from: .now, by: 10)) { _ in leaveRing(t) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.walkBefore > 0 ? "\(f.walkBefore) min walk to \(Fmt.place(f.fromStop))" : "Get to \(Fmt.place(f.fromStop))")
                                .font(BoardInk.sans(15)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.8)
                            Text(leaveText(t)).font(BoardInk.sans(12)).foregroundStyle(t.start <= Date().addingTimeInterval(60) ? BoardInk.late : BoardInk.green)
                            WalkButton { walkTo = target }.padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                    }
                    WalkPreview(target: target) { walkTo = target }
                }
                .padding(12).background(panel)
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
        .frame(width: 66, height: 66)
        .animation(.easeInOut(duration: 0.6), value: fill)
        .accessibilityLabel(s <= 60 ? "Leave now" : "Leave in \(m) minutes")
    }

    // MARK: then

    private func thenCard(_ t: DoorTrip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PlannerBar(title: "Then", sub: "\(destWord) \(Fmt.hhmm(t.end))")
            ForEach(Array(t.rides.enumerated()).dropFirst(), id: \.offset) { i, ride in
                let prev = t.rides[i - 1]
                let ch = Fmt.mins(ride.departure.timeIntervalSince(prev.arrival))
                Label("\(ch) min to change at \(Fmt.place(prev.toStop))\(ride.walkBefore > 0 ? ", \(ride.walkBefore) min walk" : "")", systemImage: "arrow.triangle.swap")
                    .font(BoardInk.sans(10.5, .semibold)).foregroundStyle(ch - ride.walkBefore < 2 ? BoardInk.late : Color.white.opacity(0.8))
                    .padding(.horizontal, 10).padding(.top, 4)
                PlannerRideRow(ride: ride, info: ns.rail(ride), picked: false) {
                    liveTrack = LiveTrackTarget(tripId: ride.tripId, line: ride.line, headsign: ride.headsign.isEmpty ? Fmt.place(ride.toStop) : ride.headsign,
                                                stopName: ride.fromStop, time: ride.departure, rail: ride.isTrain)
                }
                .padding(.horizontal, 10)
            }
            if t.walkAfter > 0 {
                Label("\(t.walkAfter) min walk to \(destWord)", systemImage: "figure.walk").font(BoardInk.sans(11, .semibold)).foregroundStyle(Color.white.opacity(0.8))
                    .padding(.horizontal, 10)
            }
        }
        .padding(.bottom, 8)
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(BoardInk.strip.opacity(0.88)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BoardInk.amber.opacity(0.35), lineWidth: 1)))
    }

    private var othersCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlannerBar(title: "Other ways", sub: "if you miss it")
            ForEach(go.others) { o in
                HStack(spacing: 8) {
                    Text(Fmt.hhmm(o.first.departure)).font(BoardInk.sans(14)).foregroundStyle(.white).monospacedDigit().frame(width: 46, alignment: .leading)
                    HStack(spacing: 3) {
                        ForEach(Array(o.rides.enumerated()), id: \.offset) { _, r in
                            Text(r.line).font(BoardInk.sans(10.5)).lineLimit(1).foregroundStyle(r.isTrain ? Color(hex: 0x1A1A1A) : BoardInk.navy)
                                .padding(.horizontal, 5).frame(height: 17)
                                .background(r.isTrain ? BoardInk.yellow : BoardInk.route, in: RoundedRectangle(cornerRadius: 2))
                        }
                    }
                    Text("from \(Fmt.place(o.first.fromStop))").font(BoardInk.sans(11, .regular)).foregroundStyle(Color.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text("→ \(Fmt.hhmm(o.end))").font(BoardInk.sans(12)).foregroundStyle(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1) }
            }
        }
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: bottom

    @ViewBuilder private var bottom: some View {
        if go.arrived || go.best == nil {
            BandButton(title: "Back to the map", pal: pal) { withAnimation(.easeInOut(duration: 0.35)) { go.close() } }
                .padding(.horizontal, 16).padding(.bottom, 8)
        } else if let t = go.best, RoutePlan.from(t) != nil {
            Button { go.startByHand() } label: {
                HStack(spacing: 8) {
                    Image(systemName: t.first.isTrain ? "tram.fill" : "bus.fill")
                    Text("I’M ON IT · START NOW").font(HWFont.display(14)).tracking(0.8)
                }
                .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Color(hex: 0x2F9E5B), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .accessibilityHint("Only if it hasn’t noticed by itself that you’re on board.")
        }
    }
}
