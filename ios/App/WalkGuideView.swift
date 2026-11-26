import AVFoundation
import CoreLocation
import MapKit
import SwiftUI
import UIKit

// Walk with arrows (0.41): turn by turn on foot to the stop or platform, like a navigation app. The rules are in
// `WalkGuide` (tested); here the map's walking route, the GPS (best accuracy only while this is on screen, nothing in
// the background), the buzzes, the voice (with headphones only) and the screen.

extension WalkTarget {
    /// "Platform 4", "Stop U": where at the stop a ride leaves from, when it's known.
    static func spotOf(_ r: Ride, _ info: RailInfo?) -> String? {
        let kind: StopLabel.Kind = StopLabel.kind(isTrain: r.isTrain, line: r.line)
        let track: String? = StopLabel.clean(info?.track) ?? r.platform
        let planned: String? = StopLabel.clean(info?.plannedTrack) ?? r.plannedPlatform
        let w: StopLabel.Where = StopLabel.make(kind: kind, stop: r.fromStop, track: track, planned: planned)
        guard let c = w.code else { return nil }
        return "\(w.word) \(c)"
    }
}

/// The walk, followed: the route, where you are on it, the buzzes and the words.
@MainActor
final class WalkGuideModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    let target: WalkTarget
    @Published private(set) var route: WalkGuide.Route?
    @Published private(set) var pos: WalkGuide.Position?
    @Published private(set) var walked: [CLLocationCoordinate2D] = []
    @Published private(set) var ahead: [CLLocationCoordinate2D] = []
    @Published private(set) var arrived = false
    @Published private(set) var failed = false
    @Published private(set) var finding = false
    /// Spoken directions (only ever with headphones in).
    var speak = true
    /// The lock screen's line for the next turn (nil: none).
    var onTurn: (String?) -> Void = { _ in }
    /// Not while the alarm rings.
    var quiet: () -> Bool = { false }

    private let manager = CLLocationManager()
    private let voice = AVSpeechSynthesizer()
    private var running = false
    private var step = 0
    private var lastAlong: Double?
    private var warnedStep = -1
    private var off = WalkGuide.OffRoute()
    private var lastFix: CLLocation?

    init(target: WalkTarget) {
        self.target = target
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        manager.activityType = .fitness
        voice.usesApplicationAudioSession = false          // (never touches the trip's sound)
    }

    /// The turn to show: the next one, how far, and the one after it.
    var shown: (next: WalkGuide.Step, metres: Double, then: WalkGuide.Step?)? {
        guard let r = route, !r.steps.isEmpty else { return nil }
        let k: Int = pos?.step ?? 0
        guard let n = WalkGuide.next(r, step: k) else { return nil }
        let m: Double = pos?.toTurn ?? r.steps[0].end
        return (n, m, WalkGuide.then(r, step: k))
    }

    /// Metres left: along the route, else straight to the stop.
    var left: Double? {
        if let p = pos { return p.left }
        if let r = route { return r.length }
        return nil
    }

    // MARK: on and off

    /// On screen: the GPS at its best, and the route.
    func start() {
        guard !running, !arrived else { return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        running = true
        manager.startUpdatingLocation()
        BatteryLog.shared.gps("walk", mode: .best, reason: .walk)
        if route == nil { findRoute(from: manager.location) }
    }

    /// Off screen (behind, or the phone locked): the GPS off. The lock screen keeps the next turn.
    func pause() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        BatteryLog.shared.gps("walk", mode: nil, reason: nil)
    }

    /// Closed.
    func stop() {
        pause()
        voice.stopSpeaking(at: .immediate)
        onTurn(nil)
    }

    // MARK: the route

    private func findRoute(from l: CLLocation?) {
        guard !finding else { return }
        finding = true
        let from: CLLocationCoordinate2D? = l.flatMap { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 100 ? $0.coordinate : nil }
        Task { [weak self] in
            guard let self else { return }
            let found: MKRoute? = await Self.directions(from: from, to: self.target)
            self.finding = false
            guard let found else {
                if self.route == nil { self.failed = true }
                return
            }
            self.use(found)
        }
    }

    private func use(_ found: MKRoute) {
        var raw: [WalkGuide.RawStep] = found.steps.map { s in
            WalkGuide.RawStep(text: s.instructions, distance: s.distance, path: Self.points(s.polyline))
        }
        if raw.reduce(0, { $0 + $1.path.count }) < 2 {
            raw = [WalkGuide.RawStep(text: "", distance: found.distance, path: Self.points(found.polyline))]
        }
        let r: WalkGuide.Route = WalkGuide.route(raw)
        route = r
        failed = false
        step = 0; lastAlong = nil; warnedStep = -1; pos = nil
        off.since = nil
        draw()
        if let l = lastFix { take(l) }
        if let s = shown { onTurn(WalkGuide.lockLine(metres: s.metres, step: s.next, stop: target.spot ?? target.name)) }
    }

    private static func directions(from: CLLocationCoordinate2D?, to t: WalkTarget) async -> MKRoute? {
        let req = MKDirections.Request()
        if let f = from {
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: f))
        } else {
            req.source = MKMapItem.forCurrentLocation()
        }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: t.coordinate))
        item.name = t.name
        req.destination = item
        req.transportType = .walking
        BatteryLog.shared.request(.directions, body: 0)             // (MapKit's own: its bytes aren't known)
        return try? await MKDirections(request: req).calculate().routes.first
    }

    private static func points(_ line: MKPolyline) -> [GeoPoint] {
        let n: Int = line.pointCount
        guard n > 0 else { return [] }
        let p: UnsafeMutablePointer<MKMapPoint> = line.points()
        var out: [GeoPoint] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let c: CLLocationCoordinate2D = p[i].coordinate
            out.append(GeoPoint(lat: c.latitude, lon: c.longitude))
        }
        return out
    }

    /// The route on the map: the part walked dimmed.
    private func draw() {
        guard let r = route else { walked = []; ahead = []; return }
        let parts = WalkGuide.split(r.path, at: lastAlong ?? 0)
        walked = parts.walked.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        ahead = parts.ahead.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    // MARK: each fix

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in self.take(l) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.running else { return }
            self.manager.startUpdatingLocation()
            if self.route == nil && !self.finding { self.findRoute(from: self.manager.location) }
        }
    }

    private func take(_ l: CLLocation) {
        guard running, !arrived else { return }
        let acc: Double = l.horizontalAccuracy
        guard acc >= 0, acc <= WalkGuide.worstFix else { return }
        lastFix = l
        let here = GeoPoint(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        let stopAt = GeoPoint(lat: target.lat, lon: target.lon)
        if WalkGuide.arrived(metres: Geo.metres(here, stopAt), accuracy: acc) { arrive(); return }
        guard let r = route else {
            if failed && !finding { findRoute(from: l) }
            return
        }
        guard let p = WalkGuide.locate(here, on: r, step: step, lastAlong: lastAlong) else { return }
        let o = WalkGuide.offRoute(off, off: p.off, accuracy: acc, now: Date())
        off = o.state
        if p.off <= WalkGuide.offRouteMetres { lastAlong = p.along }
        step = p.step
        pos = p
        draw()
        if p.advanced {
            atTurn(r, p)
        } else if WalkGuide.warn(p, on: r, warned: warnedStep == p.step) {
            warnedStep = p.step
            turnSoon(r, p)
        }
        if o.reroute { findRoute(from: l) }
    }

    /// At ~30 m: a buzz, the turn said, the lock screen.
    private func turnSoon(_ r: WalkGuide.Route, _ p: WalkGuide.Position) {
        guard let n = WalkGuide.next(r, step: p.step) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        say(WalkGuide.spoken(metres: p.toTurn, step: n))
        onTurn(WalkGuide.lockLine(metres: p.toTurn, step: n, stop: target.spot ?? target.name))
    }

    /// At the turn: two strong buzzes, what to do now, and the next turn on the lock screen.
    private func atTurn(_ r: WalkGuide.Route, _ p: WalkGuide.Position) {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        g.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { g.impactOccurred() }
        let now: WalkGuide.Step = r.steps[p.step]
        let words: String = now.text.isEmpty ? now.turn.words : now.text
        if now.turn != .arrive { say(words) }
        if let n = WalkGuide.next(r, step: p.step) {
            onTurn(WalkGuide.lockLine(metres: p.toTurn, step: n, stop: target.spot ?? target.name))
        }
    }

    private func arrive() {
        arrived = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        say("You’re here. \(target.spot ?? target.name).")
        pause()
        onTurn(nil)
    }

    /// Spoken, only with headphones in (the app's rule for its voice), and never over the alarm.
    private func say(_ text: String) {
        guard speak, !quiet(), AlarmSound.privateOutput() else { return }
        if voice.isSpeaking { voice.stopSpeaking(at: .word) }
        let u = AVSpeechUtterance(string: text)
        u.voice = AlarmSound.voice
        u.rate = 0.5
        voice.speak(u)
    }
}

/// Walk with arrows: the map following you, a big arrow and "In 40 m · turn right onto Hoogstraat" on top, the turn
/// after it small, and how far and how long against when it leaves. At the stop: "You’re here · Platform 4", then it
/// closes (`done(true)`), back to the Go to card that says you're here.
struct WalkGuideView: View {
    let target: WalkTarget
    let done: (Bool) -> Void
    @EnvironmentObject var trip: TripManager
    @StateObject private var model: WalkGuideModel
    @Environment(\.scenePhase) private var scene
    @AppStorage("walkSpeak") private var speak = true
    @State private var headingUp = true
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)

    init(target: WalkTarget, done: @escaping (Bool) -> Void) {
        self.target = target
        self.done = done
        _model = StateObject(wrappedValue: WalkGuideModel(target: target))
    }

    private var kindColor: Color { target.rail ? DS.train : DS.bus }
    private var place: String { target.spot ?? target.name }

    var body: some View {
        ZStack {
            map.ignoresSafeArea()
            VStack(spacing: DS.s12) {
                top
                Spacer(minLength: 0)
                bottom
            }
            .padding(.horizontal, DS.s12)
            .padding(.vertical, DS.s8)
            if model.arrived { arrivedCard }
        }
        .background(DS.page.ignoresSafeArea())
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onAppear {
            let t: TripManager = trip
            model.speak = speak
            model.onTurn = { [weak t] line in t?.walkTurn = line }
            model.quiet = { [weak t] in
                guard let t else { return false }
                if case .alarm = t.phase { return true }
                return false
            }
            model.start()
        }
        .onDisappear { model.stop(); trip.walkTurn = nil }
        .onChange(of: scene) { _, s in
            if s == .active { model.start() } else { model.pause() }
        }
        .onChange(of: speak) { _, v in model.speak = v }
        .task(id: model.arrived) {
            guard model.arrived else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            done(true)
        }
    }

    // MARK: the map

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            Marker(place, systemImage: target.rail ? "tram.fill" : "bus.fill", coordinate: target.coordinate)
                .tint(kindColor)
            if model.walked.count >= 2 {
                MapPolyline(coordinates: model.walked)
                    .stroke(Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if model.ahead.count >= 2 {
                MapPolyline(coordinates: model.ahead)
                    .stroke(DS.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .including([.publicTransport])))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }

    // MARK: the arrow

    @ViewBuilder private var top: some View {
        if let s = model.shown {
            arrowCard(s.next, metres: s.metres, then: s.then)
        } else if model.failed {
            note("Couldn’t work out the walk from here. Apple Maps can show you the way.", icon: "exclamationmark.triangle.fill")
        } else {
            HStack(spacing: DS.s8) {
                ProgressView()
                Text("Finding the way…").font(DS.bodyStrong).foregroundStyle(DS.text)
                Spacer(minLength: 0)
            }
            .padding(DS.s16)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous))
        }
    }

    private func arrowCard(_ next: WalkGuide.Step, metres: Double, then: WalkGuide.Step?) -> some View {
        let words: String = next.text.isEmpty ? next.turn.words : next.text
        return VStack(alignment: .leading, spacing: DS.s12) {
            HStack(alignment: .center, spacing: DS.s12) {
                Image(systemName: next.turn.symbol)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(DS.onAccent)
                    .frame(width: 68, height: 68)
                    .background(DS.accent, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("In \(WalkGuide.metres(metres))").font(DS.hero(30)).monospacedDigit().foregroundStyle(DS.text)
                    Text(words).font(DS.headline).foregroundStyle(DS.text)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WalkGuide.phrase(metres: metres, step: next))
            if let then {
                let thenWords: String = then.text.isEmpty ? then.turn.words : then.text
                HStack(spacing: DS.s8) {
                    Image(systemName: then.turn.symbol).font(.subheadline.weight(.bold)).foregroundStyle(DS.secondary)
                        .frame(width: 24).accessibilityHidden(true)
                    Text("Then \(WalkGuide.lowerFirst(thenWords))").font(DS.sub).foregroundStyle(DS.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(DS.s16)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private func note(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: DS.s8) {
            Image(systemName: icon).foregroundStyle(DS.warning).accessibilityHidden(true)
            Text(text).font(DS.sub).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DS.s16)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous))
    }

    // MARK: how far, will you make it

    private var bottom: some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            HStack(spacing: DS.s8) {
                Image(systemName: target.rail ? "tram.fill" : "bus.fill").font(.footnote.weight(.bold)).foregroundStyle(DS.onAccent)
                    .frame(width: 26, height: 26).background(kindColor, in: Circle())
                    .accessibilityHidden(true)
                Text(target.spot.map { "\($0) · \(target.name)" } ?? target.name)
                    .font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(2)
                Spacer(minLength: 0)
            }
            if let m = model.left {
                TimelineView(.periodic(from: .now, by: 15)) { tl in
                    hurryLines(metres: m, now: tl.date)
                }
            }
            HStack(spacing: DS.s8) {
                DSQuietButton(title: "Stop", icon: "xmark", full: true) { done(false) }
                DSQuietButton(title: "Apple Maps", icon: "map", full: true, action: openInMaps)
                roundButton(headingUp ? "location.north.line.fill" : "location.north.line",
                            label: headingUp ? "Map turns with you" : "North up") {
                    headingUp.toggle()
                    camera = .userLocation(followsHeading: headingUp, fallback: .automatic)
                }
                roundButton(speak ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            label: speak ? "Spoken turns on, with headphones" : "Spoken turns off") { speak.toggle() }
            }
        }
        .padding(DS.s16)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: -2)
    }

    @ViewBuilder private func hurryLines(metres m: Double, now: Date) -> some View {
        let what: String = target.rail ? "your train" : "your bus"
        let h: WalkGuide.Hurry = WalkGuide.hurry(left: m, speed: trustedSpeed, leaves: target.leaves, now: now, what: what)
        VStack(alignment: .leading, spacing: 4) {
            Label(WalkGuide.left(metres: m, minutes: h.walkMinutes), systemImage: "figure.walk")
                .font(DS.calloutStrong).monospacedDigit().foregroundStyle(DS.text)
            if let t = h.text {
                let fine: Bool = h.pace == .fine
                Label(t, systemImage: fine ? "checkmark.circle.fill" : "hare.fill")
                    .font(DS.subStrong).monospacedDigit()
                    .foregroundStyle(fine ? DS.accentText : DS.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Your own walking speed, once learned (`Habits`); else the planner's.
    private var trustedSpeed: Double? { Habits.walkSpeed(HabitStore.shared.book) }

    private func roundButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(DS.accentText)
                .frame(width: DS.hit, height: DS.hit)
                .background(DS.surface3, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: there

    private var arrivedCard: some View {
        VStack(spacing: DS.s8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44, weight: .bold)).foregroundStyle(DS.accentText)
                .accessibilityHidden(true)
            Text("You’re here · \(place)").font(DS.title).foregroundStyle(DS.text).multilineTextAlignment(.center)
            if let c = target.catchText {
                Text("Wait here for \(c).").font(DS.sub).foregroundStyle(DS.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(DS.s24)
        .frame(maxWidth: .infinity)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 4)
        .padding(DS.s24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .transition(.opacity)
    }

    private func openInMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: target.coordinate))
        item.name = target.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}
