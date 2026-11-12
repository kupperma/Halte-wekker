import MapKit
import SwiftUI

/// A bus or train on its way, from its live times: where it is now along the road, and how far it is from your stop.
/// (Transitous gives live times per stop, not a GPS position: the position is worked out from those times.)
struct LiveTrip {
    struct Stop {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let arrival: Date?
        let departure: Date?
        let scheduled: Date?
    }
    let line: String
    let headsign: String
    let live: Bool
    let stops: [Stop]
    let path: [CLLocationCoordinate2D]
    private let cum: [Double]           // metres along the path at each of its points
    private let at: [Int]               // the point on the path each stop is at

    init(line: String, headsign: String, live: Bool, stops: [Stop], path: [CLLocationCoordinate2D]) {
        self.line = line; self.headsign = headsign; self.live = live; self.stops = stops
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
struct LiveBusSheet: View {
    let target: LiveTrackTarget
    @Environment(\.dismiss) private var dismiss
    @State private var trip: LiveTrip?
    @State private var mine: Int?
    @State private var failed = false
    @State private var updated: Date?
    @State private var camera: MapCameraPosition = .automatic
    @State private var follow = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                VStack(spacing: 0) {
                    map(tl.date).frame(minHeight: 300)
                    info(tl.date)
                }
            }
            .background(LinearGradient(colors: [BoardInk.blueTop, BoardInk.blueBottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .navigationTitle("\(target.rail ? "" : "Bus ")\(target.line) live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await run() }
        }
        .preferredColorScheme(.dark)
    }

    @MapContentBuilder private func content(_ now: Date) -> some MapContent {
        UserAnnotation()
        if let trip {
            MapPolyline(coordinates: trip.path).stroke(BoardInk.route.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            ForEach(Array(trip.stops.enumerated()), id: \.offset) { i, s in
                Annotation(i == mine ? "Your stop" : "", coordinate: s.coordinate, anchor: .center) {
                    Circle().fill(i == mine ? BoardInk.yellow : Color.white)
                        .frame(width: i == mine ? 16 : 7, height: i == mine ? 16 : 7)
                        .overlay(Circle().stroke(BoardInk.navy, lineWidth: 1.5))
                }
            }
            Annotation(target.line, coordinate: trip.coordinate(atMetres: trip.position(now).metres), anchor: .center) {
                HStack(spacing: 4) {
                    Image(systemName: target.rail ? "tram.fill" : "bus.fill").font(.system(size: 12, weight: .bold))
                    Text(target.line).font(BoardInk.sans(13))
                }
                .foregroundStyle(target.rail ? Color(hex: 0x1A1A1A) : BoardInk.navy)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(target.rail ? BoardInk.yellow : BoardInk.route, in: RoundedRectangle(cornerRadius: 6))
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
                Text(target.line).font(BoardInk.sans(14)).foregroundStyle(target.rail ? Color(hex: 0x1A1A1A) : BoardInk.navy)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(target.rail ? BoardInk.yellow : BoardInk.route, in: RoundedRectangle(cornerRadius: 3))
                Text("to \(Fmt.place(target.headsign))").font(BoardInk.sans(17)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            }
            if let trip {
                let w = trip.position(now)
                Text(status(trip, w, now)).font(BoardInk.sans(15)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                if let m = mine, let a = trip.arrival(m), w.metres <= trip.metres(ofStop: m) + 20, !w.done {
                    let mins = Int((a.timeIntervalSince(now) / 60).rounded())
                    let late = trip.stops[m].scheduled.map { Int((a.timeIntervalSince($0) / 60).rounded()) } ?? 0
                    Text("At \(Fmt.place(trip.stops[m].name)) \(Fmt.hhmm(a))\(mins > 0 ? " · in \(mins) min" : "")\(late >= 1 ? " · \(late) min late" : late <= -1 ? " · \(-late) min early" : " · on time")")
                        .font(BoardInk.sans(13)).foregroundStyle(late >= 1 ? BoardInk.late : BoardInk.green)
                }
                if w.started, !w.done, !w.atStop {
                    Text("Next stop: \(Fmt.place(trip.stops[w.next].name))\(trip.arrival(w.next).map { " · \(Fmt.hhmm($0))" } ?? "")")
                        .font(BoardInk.sans(12, .regular)).foregroundStyle(Color.white.opacity(0.85))
                }
                Text(trip.live ? "Live times\(updated.map { ", updated \(Fmt.hhmm($0))" } ?? ""). Its position is worked out from them." : "No live times for this one: its position follows the timetable.")
                    .font(BoardInk.sans(10, .regular)).foregroundStyle(Color.white.opacity(0.65))
                HStack(spacing: 8) {
                    Button { follow.toggle(); if !follow { fit(trip, now) } } label: {
                        Label(follow ? "Following it" : "Follow it", systemImage: follow ? "location.fill" : "location")
                            .font(BoardInk.sans(13)).foregroundStyle(follow ? BoardInk.navy : Color.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(follow ? Color.white : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    Button { follow = false; fit(trip, now) } label: {
                        Label("It and your stop", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(BoardInk.sans(13)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            } else if failed {
                Text("Couldn’t find where this one is right now.").font(BoardInk.sans(13, .regular)).foregroundStyle(Color.white.opacity(0.85))
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Finding it…").font(BoardInk.sans(13, .regular)).foregroundStyle(Color.white.opacity(0.85)) }
            }
        }
        .padding(14)
    }

    /// "3 stops away · 1.4 km", "At your stop now", "It has passed your stop"
    private func status(_ t: LiveTrip, _ w: (metres: Double, next: Int, atStop: Bool, started: Bool, done: Bool), _ now: Date) -> String {
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
        let want = Fmt.place(target.stopName)
        let c = t.stops.indices.filter { t.stops[$0].name == target.stopName || Fmt.place(t.stops[$0].name) == want }
        return c.min { abs((t.departure($0) ?? .distantPast).timeIntervalSince(target.time)) < abs((t.departure($1) ?? .distantPast).timeIntervalSince(target.time)) }
    }

    /// Show it and your stop together.
    private func fit(_ t: LiveTrip, _ now: Date) {
        var pts = [MKMapPoint(t.coordinate(atMetres: t.position(now).metres))]
        if let m = mine { pts.append(MKMapPoint(t.stops[m].coordinate)) }
        var r = MKMapRect(origin: pts[0], size: MKMapSize(width: 0, height: 0))
        for p in pts.dropFirst() { r = r.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))) }
        let pad = max(r.width, r.height) * 0.4 + 1500
        withAnimation { camera = .rect(r.insetBy(dx: -pad, dy: -pad)) }
    }

    private func run() async {
        var last = Date.distantPast
        while !Task.isCancelled {
            if Date().timeIntervalSince(last) >= 30 {
                last = Date()
                if let t = await Transit.liveTrip(target.tripId) {
                    let first = trip == nil
                    trip = t; updated = Date(); failed = false
                    if mine == nil { mine = findMine(t) }
                    if first { fit(t, Date()) }
                } else if trip == nil { failed = true }
            }
            if follow, let t = trip {
                withAnimation(.linear(duration: 1)) {
                    camera = .camera(MapCamera(centerCoordinate: t.coordinate(atMetres: t.position(Date()).metres), distance: 1800))
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
