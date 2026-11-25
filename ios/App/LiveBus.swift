import MapKit
import SwiftUI

/// A bus or train on its way, from its live times: where it is now along the road, and how far it is from your stop.
/// (Transitous gives live times per stop, not a GPS position: the position is worked out from those times, unless
/// OVapi's open data has a fresh GPS fix for it: `TripPlacement`.)
struct LiveTrip {
    struct Stop {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let arrival: Date?
        let departure: Date?
        let scheduled: Date?
        var scheduledArrival: Date? = nil       // the timetable's own two times (`scheduled`: either)
        var scheduledDeparture: Date? = nil
        var track: String? = nil                // (0.39) its platform there (live, else the timetable's)
    }
    let line: String
    let headsign: String
    let live: Bool
    let stops: [Stop]
    let path: [CLLocationCoordinate2D]
    let mode: String                    // as the live data names it ("BUS", "TRAM", "REGIONAL_RAIL"…), "" not known
    var num = ""                        // a train's number as its trip names it ("2416"), for NS's positions; "" not known
    private let cum: [Double]           // metres along the path at each of its points
    private let at: [Int]               // the point on the path each stop is at

    init(line: String, headsign: String, live: Bool, stops: [Stop], path: [CLLocationCoordinate2D], mode: String = "") {
        self.line = line; self.headsign = headsign; self.live = live; self.stops = stops; self.mode = mode
        let p = path.count >= 2 ? path : stops.map(\.coordinate)         // no road shape: straight lines between the stops
        self.path = p
        var c: [Double] = [0]
        for i in 1..<max(1, p.count) {
            c.append(c[i - 1] + CLLocation(latitude: p[i - 1].latitude, longitude: p[i - 1].longitude)
                .distance(from: CLLocation(latitude: p[i].latitude, longitude: p[i].longitude)))
        }
        cum = c
        // each stop on the path: the nearest point from where the previous stop was, going forward
        var idx: [Int] = [], from = 0
        for s in stops {
            let k = cos(s.coordinate.latitude * .pi / 180)
            var best = from, bestD = Double.greatestFiniteMagnitude
            for j in from..<p.count {
                let dy = p[j].latitude - s.coordinate.latitude, dx = (p[j].longitude - s.coordinate.longitude) * k
                let d = dx * dx + dy * dy
                if d < bestD { bestD = d; best = j }
            }
            idx.append(best); from = best
        }
        at = idx
    }

    func arrival(_ i: Int) -> Date? { stops[i].arrival ?? stops[i].departure }
    func departure(_ i: Int) -> Date? { stops[i].departure ?? stops[i].arrival }
    func metres(ofStop i: Int) -> Double { cum[min(at[i], cum.count - 1)] }

    /// Where it is at `t`: metres along the road, the next stop it reaches (or stands at), and how it's doing.
    func position(_ t: Date) -> (metres: Double, next: Int, atStop: Bool, started: Bool, done: Bool) {
        let n = stops.count
        if let d0 = departure(0), t < d0 { return (metres(ofStop: 0), 0, true, false, false) }
        for i in 0..<n {
            if let a = arrival(i), let d = departure(i), t >= a, t <= d { return (metres(ofStop: i), i, true, true, false) }
            if i + 1 < n, let d = departure(i), let a2 = arrival(i + 1), t > d, t < a2 {
                let f = t.timeIntervalSince(d) / max(1, a2.timeIntervalSince(d))
                return (metres(ofStop: i) + f * (metres(ofStop: i + 1) - metres(ofStop: i)), i + 1, false, true, false)
            }
        }
        return (metres(ofStop: n - 1), n - 1, true, true, true)
    }

    /// The road between two points, `a` to `b` metres along.
    func road(from a: Double, to b: Double) -> [CLLocationCoordinate2D] {
        guard b > a else { return [] }
        var out = [coordinate(atMetres: a)]
        for i in cum.indices where cum[i] > a && cum[i] < b && i < path.count { out.append(path[i]) }
        out.append(coordinate(atMetres: b))
        return out
    }

    /// The point on the road `m` metres along.
    func coordinate(atMetres m: Double) -> CLLocationCoordinate2D {
        guard path.count >= 2 else { return path.first ?? stops[0].coordinate }
        var lo = 0, hi = cum.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if cum[mid] <= m { lo = mid } else { hi = mid } }
        let span = max(0.001, cum[hi] - cum[lo]), f = min(1, max(0, (m - cum[lo]) / span))
        return .init(latitude: path[lo].latitude + (path[hi].latitude - path[lo].latitude) * f,
                     longitude: path[lo].longitude + (path[hi].longitude - path[lo].longitude) * f)
    }
}

/// The bus or train you tapped, and the stop where you're catching it.
struct LiveTrackTarget: Identifiable, Hashable {
    let tripId: String
    let line: String
    let headsign: String
    let stopName: String
    let time: Date
    var rail = false
    var id: String { "\(tripId)|\(stopName)" }
}

/// A live map of one bus or train: where it is now, moving along its route every second, how many stops and how far
/// it is from your stop, and when it's there. Its live times are fetched again every 30 seconds.
/// A bus with a fresh GPS fix in the open data is drawn where that puts it (0.20.2, `TripPlacement`); else a late
/// bus is drawn by its times without catching up (`LiveTimes.noCatchUp`). Either way not past your stop until two
/// minutes after it should have left there; the times it prints are the answer's own (as on the board).
struct LiveBusSheet: View {
    let target: LiveTrackTarget
    var newLook = false         // the new look (0.20): its tokens, in the phone's light or dark
    /// A bus or train tapped on the home map that you could be on (0.20.1): "I'm on this one" starts your trip by hand.
    var onIt: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var trip: LiveTrip?          // drawn by: without catching up
    @State private var given: LiveTrip?         // as the answer gives it: the times it prints
    @State private var mine: Int?
    @State private var failed = false
    @State private var updated: Date?
    @State private var refreshFailed = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var follow = false
    @State private var hold = GPSHold()
    @State private var later = Approach.Steady()    // its GPS's soonest time at your stop, when clearly later (0.24.5)

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                VStack(spacing: 0) {
                    map(tl.date).frame(minHeight: 300)
                    if newLook {
                        // (scrolls at large text, under the map)
                        ScrollView { infoNew(tl.date) }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(maxHeight: 380)
                            .background(DS.surface)
                    } else { info(tl.date) }
                }
            }
            .background { if newLook { DS.page.ignoresSafeArea() } else { PaperFill().ignoresSafeArea() } }
            .navigationTitle("\(target.rail ? "" : "Bus ")\(target.line) live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .realPositions(RealPositions.key(target.tripId) != nil, trains: target.rail)
            .task { await run() }
        }
        .tint(newLook ? DS.accentText : nil)
        .preferredColorScheme(newLook ? nil : .light)
    }

    /// Its colour on the map: its line's (the old look), or its mode's (the new look).
    private var lineColor: Color { newLook ? DS.mode(train: target.rail, mode: trip?.mode ?? "", line: target.line) : Paper.line(target.line, train: target.rail) }

    @MapContentBuilder private func content(_ now: Date) -> some MapContent {
        UserAnnotation()
        if let trip {
            MapPolyline(coordinates: trip.path).stroke(lineColor.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            ForEach(Array(trip.stops.enumerated()), id: \.offset) { i, s in
                Annotation(i == mine ? "Your stop" : "", coordinate: s.coordinate, anchor: .center) {
                    Circle().fill(i == mine ? (newLook ? DS.accent : BoardInk.yellow) : Color.white)
                        .frame(width: i == mine ? 16 : 7, height: i == mine ? 16 : 7)
                        .overlay(Circle().stroke(newLook ? (i == mine ? Color.white : lineColor) : BoardInk.navy, lineWidth: i == mine && newLook ? 3 : 1.5))
                }
            }
            Annotation(target.line, coordinate: trip.coordinate(atMetres: shownMetres(trip, now)), anchor: .center) {
                HStack(spacing: 4) {
                    Image(systemName: target.rail ? "tram.fill" : "bus.fill").font(.system(size: 12, weight: .bold))
                    Text(target.line).font(newLook ? DS.footnoteStrong : BoardInk.sans(13))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(lineColor, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            }
        }
    }

    private func map(_ now: Date) -> some View {
        Map(position: $camera) { content(now) }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls { MapUserLocationButton(); MapCompass() }
    }

    @ViewBuilder private func info(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                LineBullet(line: target.line, train: target.rail, height: 24, minWidth: 38, font: 14)
                Text("to \(Fmt.place(target.headsign))").font(BoardInk.sans(17)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.7)
            }
            if let trip {
                let placed = placement(trip, now), w = placed.w, printed = given ?? trip
                Text(status(trip, w, now)).font(BoardInk.sans(15)).foregroundStyle(Paper.ink).fixedSize(horizontal: false, vertical: true)
                if let m = mine, m < printed.stops.count, let a = atMine(printed.arrival(m)), shownMetres(trip, now) <= trip.metres(ofStop: m) + 20,
                   !w.done || !LiveTimes.hasLeft(trip.stops[m].times, now: now) {
                    let mins = Int((a.timeIntervalSince(now) / 60).rounded())
                    let late = printed.stops[m].scheduled.map { Int((a.timeIntervalSince($0) / 60).rounded()) } ?? 0
                    Text("At \(Fmt.place(trip.stops[m].name)) \(Fmt.hhmm(a))\(mins > 0 ? " · in \(mins) min" : "")\(late >= 1 ? " · \(late) min late" : late <= -1 ? " · \(-late) min early" : " · on time")")
                        .font(BoardInk.sans(13)).foregroundStyle(late >= 1 ? Paper.late : Paper.ok)
                }
                if w.started, !w.done, !w.atStop {
                    Text("Next stop: \(Fmt.place(trip.stops[w.next].name))\((w.next < printed.stops.count ? printed.arrival(w.next) : nil).map { " · \(Fmt.hhmm($0))" } ?? "")")
                        .font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.85))
                }
                Text(footnote(trip, placed, now))
                    .font(BoardInk.sans(10, .regular)).foregroundStyle(Paper.ink.opacity(0.65))
                if refreshFailed {
                    Text("Couldn’t update just now.").font(BoardInk.sans(10, .regular)).foregroundStyle(Paper.ink.opacity(0.85))
                }
                HStack(spacing: 8) {
                    Button { follow.toggle(); if !follow { fit(trip, now) } } label: {
                        Label(follow ? "Following it" : "Follow it", systemImage: follow ? "location.fill" : "location")
                            .font(BoardInk.sans(13)).foregroundStyle(follow ? BoardInk.navy : Color.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(follow ? Color.white : Paper.ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    Button { follow = false; fit(trip, now) } label: {
                        Label("It and your stop", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(BoardInk.sans(13)).foregroundStyle(Paper.ink)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Paper.ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            } else if failed {
                Text("Couldn’t find where this one is right now.").font(BoardInk.sans(13, .regular)).foregroundStyle(Paper.ink.opacity(0.85))
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Finding it…").font(BoardInk.sans(13, .regular)).foregroundStyle(Paper.ink.opacity(0.85)) }
            }
        }
        .padding(14)
    }

    /// The new look's part under the map: the same words, big where it matters (how far from your stop), with Follow
    /// and "It and your stop" as 44 pt buttons.
    @ViewBuilder private func infoNew(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            HStack(spacing: 10) {
                DSLinePill(line: target.line, train: target.rail, mode: trip?.mode ?? "")
                if !headsign.isEmpty {
                    Text("to \(Fmt.place(headsign))").font(DS.headline).foregroundStyle(DS.text).lineLimit(2)
                }
            }
            if let trip {
                let placed = placement(trip, now), w = placed.w, printed = given ?? trip
                Text(status(trip, w, now)).font(DS.title).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                if let m = mine, m < printed.stops.count, let a = atMine(printed.arrival(m)), shownMetres(trip, now) <= trip.metres(ofStop: m) + 20,
                   !w.done || !LiveTimes.hasLeft(trip.stops[m].times, now: now) {
                    let mins = Int((a.timeIntervalSince(now) / 60).rounded())
                    let late = printed.stops[m].scheduled.map { Int((a.timeIntervalSince($0) / 60).rounded()) } ?? 0
                    Text("At \(Fmt.place(trip.stops[m].name)) \(Fmt.hhmm(a))\(mins > 0 ? " · in \(mins) min" : "")\(late >= 1 ? " · \(late) min late" : late <= -1 ? " · \(-late) min early" : " · on time")")
                        .font(DS.calloutStrong).monospacedDigit().foregroundStyle(late >= 1 ? DS.warning : DS.accentText)
                }
                if w.started, !w.done, !w.atStop {
                    Text("Next stop: \(Fmt.place(trip.stops[w.next].name))\((w.next < printed.stops.count ? printed.arrival(w.next) : nil).map { " · \(Fmt.hhmm($0))" } ?? "")")
                        .font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary)
                }
                if mine == nil { nextStops(trip, printed, w) }
                if let onIt {
                    DSPrimaryButton(title: "I’m on this one", icon: target.rail ? "tram.fill" : "bus.fill") { onIt(); dismiss() }
                        .accessibilityHint("Starts your trip with this \(target.rail ? "train" : "bus"), and its alarm")
                        .padding(.vertical, DS.s4)
                }
                Text(footnote(trip, placed, now))
                    .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                if refreshFailed {
                    Text("Couldn’t update just now.").font(DS.footnote).foregroundStyle(DS.warning)
                }
                HStack(spacing: DS.s8) {
                    Button { follow.toggle(); if !follow { fit(trip, now) } } label: {
                        Label(follow ? "Following it" : "Follow it", systemImage: follow ? "location.fill" : "location")
                            .font(DS.subStrong).foregroundStyle(follow ? DS.onAccent : DS.accentText)
                            .frame(maxWidth: .infinity, minHeight: DS.hit)
                            .background(follow ? AnyShapeStyle(DS.accent) : AnyShapeStyle(DS.surface3), in: Capsule())
                    }
                    .buttonStyle(DSPressStyle())
                    .accessibilityAddTraits(follow ? .isSelected : [])
                    Button { follow = false; fit(trip, now) } label: {
                        Label("It and your stop", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(DS.subStrong).foregroundStyle(DS.accentText)
                            .frame(maxWidth: .infinity, minHeight: DS.hit)
                            .background(DS.surface3, in: Capsule())
                    }
                    .buttonStyle(DSPressStyle())
                }
            } else if failed {
                Text("Couldn’t find where this one is right now.").font(DS.body).foregroundStyle(DS.secondary)
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Finding it…").font(DS.body).foregroundStyle(DS.secondary) }
            }
        }
        .padding(DS.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// Where it goes: the target's, or (tapped on the map) its live times'.
    private var headsign: String { target.headsign.isEmpty ? (trip?.headsign ?? "") : target.headsign }

    /// Tapped on the map (no stop of yours): the stops after its next one, with their times and how late.
    @ViewBuilder private func nextStops(_ t: LiveTrip, _ printed: LiveTrip, _ w: (metres: Double, next: Int, atStop: Bool, started: Bool, done: Bool)) -> some View {
        let r = MapTap.ahead(next: w.next, count: min(t.stops.count, printed.stops.count), done: w.done)
        if !r.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Then").font(DS.footnoteStrong).foregroundStyle(DS.secondary).padding(.bottom, 2)
                ForEach(Array(r), id: \.self) { i in
                    let at = printed.arrival(i)
                    let late = MapTap.delayText(at: at, scheduled: printed.stops[i].scheduledArrival ?? printed.stops[i].scheduled)
                    HStack(spacing: DS.s8) {
                        Circle().fill(lineColor).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(Fmt.place(t.stops[i].name)).font(DS.sub).foregroundStyle(DS.text).lineLimit(1)
                        Spacer(minLength: 4)
                        if let at { Text(Fmt.hhmm(at)).font(DS.subStrong).monospacedDigit().foregroundStyle(DS.text) }
                        if let late, printed.live {
                            Text(late).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(late.hasPrefix("+") ? DS.warning : DS.accentText)
                        }
                    }
                    .frame(minHeight: 30)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Where it is at `now`: by its GPS when there's a fresh fix on its road, else by its times (at your stop only
    /// once its GPS is: 0.24.5).
    private func placement(_ t: LiveTrip, _ now: Date) -> TripPlacement {
        TripPlacement(t, tripId: target.tripId, now: now, hold: hold, mine: mine)
    }

    /// The time it's at your stop: the answer's, or the later one its GPS allows (0.24.5, `Approach.Steady`).
    private func atMine(_ given: Date?) -> Date? {
        guard let g = given else { return nil }
        return later.shown.map { max($0, g) } ?? g
    }

    /// Its GPS against the answer's time at your stop (0.24.5), once a second.
    private func noteLater(_ now: Date) {
        guard let t = trip, let p = given ?? trip, let m = mine, m < t.stops.count, m < p.stops.count, let g = p.arrival(m) else {
            if later.shown != nil { later = Approach.Steady() }
            return
        }
        var estimate: Date?, age: TimeInterval?
        if !target.rail, let f = RealPositionsStore.shared.fix(for: target.tripId, now: now) {
            estimate = t.gpsArrival(f, atStop: m, now: now)
            age = now.timeIntervalSince(f.at)
        }
        _ = later.update(given: g, estimate: estimate, fixAge: age)
    }

    /// Where to draw it at `now` (metres along): by its GPS or its times, but not past your stop before it has left there.
    /// (0.40) And not at your stop while its time there is more than two minutes off (`WaitMarker`).
    private func shownMetres(_ t: LiveTrip, _ now: Date) -> Double {
        let p = placement(t, now)
        let w = p.w
        guard let m = mine, m < t.stops.count else { return w.metres }
        let me: Double = t.metres(ofStop: m)
        let left: Bool = LiveTimes.hasLeft(t.stops[m].times, now: now)
        let drawn: Double = LiveTimes.shown(w.metres, mine: me, left: left)
        let g: LiveTrip = given ?? t
        guard !left, m < g.stops.count, let eta = atMine(g.departure(m) ?? g.arrival(m)) else { return drawn }
        let byTime = t.position(now)
        let waiting: Bool = byTime.atStop && byTime.started && byTime.next == m
        let s: WaitMarker.Shown = WaitMarker.place(drawn: drawn, byTime: min(byTime.metres, me), mine: me, mineIsFirst: m == 0,
                                                    started: byTime.started, gpsRaw: p.raw, waitingByTimes: waiting, eta: eta, now: now)
        return s.metres ?? min(byTime.metres, me)
    }

    /// Where its position comes from: "Live times, updated 12:30. Position from the bus’s GPS, 40 s ago."
    private func footnote(_ t: LiveTrip, _ p: TripPlacement, _ now: Date) -> String {
        if let f = p.fix {
            let what = target.rail ? "train" : t.mode.uppercased().contains("TRAM") ? "tram" : "bus"
            let ago = "Position from the \(what)’s GPS, \(Int(max(0, now.timeIntervalSince(f.at)).rounded())) s ago."
            return t.live ? "Live times\(updated.map { ", updated \(Fmt.hhmm($0))" } ?? ""). \(ago)" : ago
        }
        return t.live ? "Live times\(updated.map { ", updated \(Fmt.hhmm($0))" } ?? ""). Its position is worked out from them." : "No live times for this one: its position follows the timetable."
    }

    /// "3 stops away · 1.4 km", "At your stop now", "Due at your stop now", "It has passed your stop"
    private func status(_ t: LiveTrip, _ w: (metres: Double, next: Int, atStop: Bool, started: Bool, done: Bool), _ now: Date) -> String {
        // past your stop by its times, but it left there less than two minutes ago: it may well still be coming
        if let m = mine, m < t.stops.count, w.done || t.metres(ofStop: m) - w.metres < -20, !LiveTimes.hasLeft(t.stops[m].times, now: now) {
            return "Due at your stop now."
        }
        if w.done { return "This trip has ended." }
        if !w.started { return "Hasn’t left \(Fmt.place(t.stops[0].name)) yet\(t.departure(0).map { ": it leaves at \(Fmt.hhmm($0))" } ?? "")." }
        guard let m = mine else { return w.atStop ? "At \(Fmt.place(t.stops[w.next].name)) now." : "On its way to \(Fmt.place(t.stops[w.next].name))." }
        let left = t.metres(ofStop: m) - w.metres
        if left < -20 { return "It has passed your stop." }
        let ahead = m - w.next
        if ahead == 0 { return w.atStop ? "It’s at your stop now!" : "Almost at your stop · \(Fmt.distance(max(0, left)))" }
        return "\(ahead + (w.atStop ? 0 : 1)) stop\(ahead + (w.atStop ? 0 : 1) == 1 ? "" : "s") away · \(Fmt.distance(max(0, left)))"
    }

    /// Your stop on its route: the one with your stop's name nearest to the time you're catching it.
    private func findMine(_ t: LiveTrip) -> Int? {
        guard !target.stopName.isEmpty else { return nil }          // (tapped on the map: no stop of yours)
        let want = Fmt.place(target.stopName)
        let c = t.stops.indices.filter { t.stops[$0].name == target.stopName || Fmt.place(t.stops[$0].name) == want }
        return c.min { abs((t.departure($0) ?? .distantPast).timeIntervalSince(target.time)) < abs((t.departure($1) ?? .distantPast).timeIntervalSince(target.time)) }
    }

    /// Show it and your stop together.
    private func fit(_ t: LiveTrip, _ now: Date) {
        var pts = [MKMapPoint(t.coordinate(atMetres: shownMetres(t, now)))]
        if let m = mine { pts.append(MKMapPoint(t.stops[m].coordinate)) }
        var r = MKMapRect(origin: pts[0], size: MKMapSize(width: 0, height: 0))
        for p in pts.dropFirst() { r = r.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))) }
        let pad = max(r.width, r.height) * 0.4 + 1500
        withAnimation { camera = .rect(r.insetBy(dx: -pad, dy: -pad)) }
    }

    private func run() async {
        var last = Date.distantPast
        if trip == nil, let c = await Transit.cachedLiveTrip(target.tripId) {
            given = c.trip; trip = c.trip.noCatchUp(asOf: c.at, isTrain: target.rail)
            updated = c.at; mine = findMine(c.trip); fit(c.trip, Date())
        }
        while !Task.isCancelled {
            if Date().timeIntervalSince(last) >= 30 {
                last = Date()
                if let t = await Transit.liveTrip(target.tripId) {
                    let first = trip == nil
                    given = t; trip = t.noCatchUp(asOf: Date(), isTrain: target.rail)
                    updated = Date(); failed = false; refreshFailed = false
                    if mine == nil { mine = findMine(t) }
                    if first { fit(t, Date()) }
                } else if trip == nil { failed = true } else { refreshFailed = true }
            }
            noteLater(Date())
            if follow, let t = trip {
                withAnimation(.linear(duration: 1)) {
                    camera = .camera(MapCamera(centerCoordinate: t.coordinate(atMetres: shownMetres(t, Date())), distance: 1800))
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
