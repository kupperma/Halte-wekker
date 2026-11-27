import CoreLocation
import MapKit
import SwiftUI

/// A stop picked on "Fastest trip, zoomed out" (its `Nearby.Group` id).
struct NearbyPick: Identifiable, Hashable { let id: String }

/// "Fastest trip, zoomed out" (0.42, concept N5): Fastest trip's overview. The map zooms out to the stops you could
/// walk to (one plan from where you are, walking up to 1.6 km, 3 km while fewer than 3 have a way, framed on the
/// useful ones; 0.42.2: circles that would overlap as one, grey dots for stops to tap and check); each stop a circle coloured by when
/// you'd be there (green the earliest … red the latest, its minutes inside), its ring how sure (solid: almost always
/// on time, dashed: often late, thin: no live times to go by). Leave now / in 10 / in 20 min. Under it the stops,
/// tagged Fastest, Surest and Slower. Tap one: its times, the whole trip, what's on the line now, and Go.
/// "Your trip and other times" (or the top right) shows Fastest trip's own cards as before.
struct NearbyOverview: View {
    @EnvironmentObject var go: GoStore
    @EnvironmentObject var trip: TripManager
    @StateObject private var store = NearbyStore()
    @StateObject private var line = NearbyLineModel()
    @State private var camera: MapCameraPosition = .automatic
    @State private var picked: NearbyPick?
    /// The map's metres per point (for circles that would overlap: `Nearby.merge`).
    @State private var metresPerPoint: Double = 3
    /// Show Fastest trip's own cards.
    let onClose: () -> Void

    private var here: CLLocation? { go.here ?? trip.lastFix }
    private var destWord: String { go.dest.short }

    /// Fastest trip opens on this (not on board, not there yet, not a planned trip, not the demo).
    @MainActor static func opensOn(_ go: GoStore) -> Bool {
        let riding: Bool = go.movingUnknown || go.atVehicleSpeed           // (0.42.4: at bus speed, not the stops around you)
        return go.isOpen && !go.arrived && !go.demo && go.onBoard == nil && !riding && go.deadline == nil
            && go.best?.first.fromId != "onboard"
    }

    /// It can be opened by hand (from Fastest trip's cards).
    @MainActor static func canOpen(_ go: GoStore) -> Bool {
        go.isOpen && !go.arrived && !go.demo && go.onBoard == nil && go.best?.first.fromId != "onboard"
    }

    var body: some View {
        GeometryReader { g in
            let mapH: CGFloat = max(240, g.size.height * 0.46)
            VStack(spacing: 0) {
                mapView(height: mapH + 24)
                    .frame(height: mapH + 24)               // (the last 24 under the list's round corners)
                panel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, -24)
            }
            .overlay(alignment: .top) { topBar.padding(.top, 4) }
        }
        .background(DS.page.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .task(id: startKey) { start() }
        .onChange(of: go.best?.id) { _, _ in store.absorb(seed) }
        // (0.42.7) Fastest trip's fresher live times freshen the same trips here (by trip id, at any of their stops)
        .onChange(of: go.updated) { _, u in store.freshen(from: seed, asOf: u ?? Date()) }
        .onChange(of: frameKey) { _, _ in refit() }
        .task {
            // once a minute: "Leave now" moves on with the clock, and it asks again after a few minutes
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { return }
                store.tick()
            }
        }
        .onDisappear { store.stop(); line.stopFollowing() }
        .sheet(item: $picked, onDismiss: { line.stopFollowing(); refit() }) { p in
            NearbyDetailSheet(store: store, line: line, stopId: p.id, destWord: destWord) { onClose() }
                .environmentObject(go)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
    }

    private var seed: [DoorTrip] { [go.best].compactMap { $0 } + go.others }

    /// Asked again for another destination, or when you've moved (about 200 m steps).
    private var startKey: String {
        guard let h = here else { return go.dest.key }
        let c = h.coordinate
        return "\(go.dest.key)|\(Int((c.latitude * 500).rounded())),\(Int((c.longitude * 300).rounded()))"
    }

    private func start() {
        guard let h = here else { return }
        store.open(here: h, dest: go.dest, seed: seed)
        store.freshen(from: seed, asOf: go.updated ?? Date())
    }

    // MARK: the map

    private struct Mark: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let state: NearbyStopMark.Look
        let fill: Color
        let minutes: String
        let ring: Nearby.Ring
        let spoken: String
        var more = 0                    // other stops drawn under this one (too close to tell apart)
    }

    /// The stops' circles: coloured by when you'd be there, the ones that would overlap at this zoom as one (the
    /// earliest there, `Nearby.merge`), and grey dots for the stops not planned from (tap one to check it), left out
    /// under a circle.
    private func marks() -> [Mark] {
        let span: (earliest: Date, latest: Date)? = store.arrivals
        var ready: [String: Mark] = [:]
        var pins: [Nearby.Pin] = []
        var dots: [Mark] = []
        for w in store.ways {
            let g: Nearby.Group = w.group
            let c = CLLocationCoordinate2D(latitude: g.lat, longitude: g.lon)
            let name: String = Fmt.stop(g.name)
            if let o = store.option(w.id), let s = span {
                let f: Double = Nearby.fraction(o.arrival, earliest: s.earliest, latest: s.latest)
                let fill: Color = o.ranked ? Color(hex: Nearby.color(f)) : DS.legQuiet
                let mins: String = String(Fmt.hhmm(o.arrival).suffix(2))
                let spoken: String = "\(name): there at \(Fmt.hhmm(o.arrival))" + (o.sure.map { ", on time \($0.percent)%" } ?? "")
                ready[w.id] = Mark(id: w.id, name: name, coordinate: c, state: .ready, fill: fill, minutes: mins,
                                   ring: o.ranked ? Nearby.ring(o.sure) : .neutral, spoken: spoken)
                pins.append(Nearby.Pin(id: w.id, lat: g.lat, lon: g.lon, arrival: o.arrival))
            } else {
                let st: NearbyStopMark.Look
                let spoken: String
                switch w.check {
                case .asking: st = .pending; spoken = "\(name): asking"
                case .done: st = .none; spoken = "\(name): no way from here in this time"
                case .unasked: st = .unasked; spoken = "\(name): not checked. Tap to check it"
                case .failed: st = .unasked; spoken = "\(name): couldn’t check it. Tap to try again"
                }
                dots.append(Mark(id: w.id, name: name, coordinate: c, state: st, fill: DS.legQuiet, minutes: "", ring: .neutral, spoken: spoken))
            }
        }
        let within: Double = Nearby.pinPoints * max(0.1, metresPerPoint)
        var out: [Mark] = []
        for cl in Nearby.merge(pins, within: within) {
            guard var m = ready[cl.id] else { continue }
            m.more = cl.members.count - 1
            out.append(m)
        }
        let circles: [GeoPoint] = out.map { GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        let free: [Mark] = dots.filter { d in
            let p = GeoPoint(lat: d.coordinate.latitude, lon: d.coordinate.longitude)
            return !circles.contains { Geo.metres($0, p) < within * 0.6 }
        }
        return free + out
    }

    private var lineColor: Color { DS.mode(train: line.routeTrain, line: line.routeLine) }

    private var vehicles: [NearbyLineModel.Coming] { line.coming.filter { $0.spot != nil } }

    private struct Spot: Identifiable {
        let coming: NearbyLineModel.Coming
        let coordinate: CLLocationCoordinate2D
        var id: String { coming.tripId }
    }

    /// The vehicles on the line with their own GPS, where it puts them.
    private var spots: [Spot] {
        line.coming.compactMap { c in c.spot.map { Spot(coming: c, coordinate: $0.coordinate) } }
    }

    private func mapView(height: CGFloat) -> some View {
        let ms: [Mark] = marks()
        let following: Bool = picked != nil
        return Map(position: $camera) {
            if following && line.route.count >= 2 {
                MapPolyline(coordinates: line.route).stroke(lineColor, lineWidth: 5)
            }
            if let h = here {
                Annotation("You", coordinate: h.coordinate, anchor: .center) { youDot }
                    .annotationTitles(.hidden)
            }
            ForEach(ms) { m in
                Annotation(m.name, coordinate: m.coordinate, anchor: .center) {
                    Button { picked = NearbyPick(id: m.id) } label: {
                        NearbyStopMark(state: m.state, fill: m.fill, text: m.minutes, ring: m.ring, selected: picked?.id == m.id, more: m.more)
                    }
                    .buttonStyle(.plain)
                    .disabled(m.state == .pending)
                    .accessibilityLabel(m.more > 0 ? m.spoken + ", and \(m.more) more stop\(m.more == 1 ? "" : "s") close by" : m.spoken)
                }
                .annotationTitles(.hidden)
            }
            if following {
                ForEach(spots) { p in
                    Annotation(p.coming.line, coordinate: p.coordinate, anchor: .center) { vehicleChip(p.coming) }
                        .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .onMapCameraChange(frequency: .onEnd) { ctx in
            let h: Double = max(1, Double(height))
            let m: Double = ctx.region.span.latitudeDelta * 111_320 / h
            if m.isFinite && m > 0 { metresPerPoint = m }
        }
    }

    private var youDot: some View {
        ZStack {
            Circle().fill(Color(hex: 0x2F8CFF).opacity(0.18)).frame(width: 40, height: 40)
            Circle().fill(Color(hex: 0x2F8CFF)).frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.white, lineWidth: 3))
        }
        .accessibilityLabel("You")
    }

    private func vehicleChip(_ v: NearbyLineModel.Coming) -> some View {
        Text(v.train ? Transit.trainLabel(v.line) : v.line)
            .font(DS.caption).monospacedDigit()
            .foregroundStyle(DS.onAccent)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(DS.mode(train: v.train, line: v.line), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white, lineWidth: 2))
            .accessibilityLabel("\(v.train ? "Train" : "Bus") \(v.line) on its way")
    }

    /// What the frame follows: the stops with a way (else every stop), and with a stop open, it and its vehicles.
    private var frameKey: String {
        let ids: String = store.options.map(\.id).sorted().joined(separator: ",")
        let v: String = picked == nil ? "" : vehicles.map(\.tripId).joined(separator: ",")
        return "\(ids)|\(store.ways.count)|\(picked?.id ?? "")|\(v)|\(Int(store.radius))"
    }

    private func refit() {
        guard let h = here else { return }
        let you = GeoPoint(lat: h.coordinate.latitude, lon: h.coordinate.longitude)
        var pts: [GeoPoint] = store.options.compactMap { store.way($0.id)?.group.point }
        if pts.isEmpty { pts = store.ways.map(\.group.point) }
        if let p = picked, let w = store.way(p.id) {
            pts = [w.group.point] + vehicles.compactMap(\.spot)
        }
        let least: Double = pts.isEmpty ? store.radius * 2 : 600
        let f: Nearby.Frame = Nearby.frame(you: you, stops: pts, minMetres: least)
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon),
                                        span: MKCoordinateSpan(latitudeDelta: f.latDelta, longitudeDelta: f.lonDelta))
        withAnimation(.easeInOut(duration: 0.5)) { camera = .region(region) }
    }

    // MARK: the top

    private var topBar: some View {
        HStack(spacing: DS.s8) {
            DSRoundButton(icon: "chevron.left", label: "Back to the map. This stops the watching.") {
                withAnimation(.easeInOut(duration: 0.35)) { go.close() }
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Text("Your trip").font(DS.subStrong)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
                .foregroundStyle(DS.text)
                .padding(.horizontal, 16).frame(minHeight: DS.hit)
                .background(DS.surface, in: Capsule())
                .dsFloat()
            }
            .buttonStyle(DSPressStyle())
            .accessibilityHint("Fastest trip's own cards, and its other times")
        }
        .padding(.horizontal, DS.edge)
    }

    // MARK: the list

    private var panel: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.s12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(go.dest == .home ? "Home" : "To \(destWord)").font(DS.title).foregroundStyle(DS.text)
                        .lineLimit(1).minimumScaleFactor(0.7).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    Text("colour = arrival").font(DS.footnote).foregroundStyle(DS.secondary)
                }
                leaveSwitch
                legend
                status
                ForEach(Nearby.ordered(store.options)) { o in
                    if let w = store.way(o.id) {
                        Button { picked = NearbyPick(id: o.id) } label: { row(o, w) }
                            .buttonStyle(.plain)
                    }
                }
                DSQuietButton(title: "Your trip and other times", icon: "list.bullet", full: true, action: onClose)
                    .padding(.top, DS.s4)
            }
            .padding(.horizontal, DS.s16).padding(.top, DS.s16).padding(.bottom, 32)
        }
        .background(DS.surface, in: UnevenRoundedRectangle(topLeadingRadius: DS.cardRadius, topTrailingRadius: DS.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: -2)
        .ignoresSafeArea(edges: .bottom)
    }

    private var leaveSwitch: some View {
        HStack(spacing: 0) {
            ForEach(Nearby.Leave.allCases) { l in
                let on: Bool = store.leave == l
                Button { store.choose(l) } label: {
                    Text(l.title).font(DS.subStrong)
                        .foregroundStyle(on ? DS.onAccent : DS.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(on ? AnyShapeStyle(DS.accent) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(DS.surface3, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    @ViewBuilder private var legend: some View {
        if let s = store.arrivals {
            VStack(alignment: .leading, spacing: 4) {
                LinearGradient(colors: Nearby.scale.map { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 10).clipShape(Capsule())
                    .accessibilityHidden(true)
                HStack {
                    Text("arrive \(Fmt.hhmm(s.earliest))")
                    Spacer()
                    Text(Fmt.hhmm(s.latest))
                }
                .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                Text("Solid ring = almost always on time · dashed = often late")
                    .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var rangeWord: String {
        let km: Double = store.radius / 1000
        return km == km.rounded() ? "\(Int(km)) km" : String(format: "%.1f km", km)
    }

    /// What the line over the list says (`Nearby.statusLine`): never "No bus or train" while the planner didn't
    /// answer, or while your trip has a way.
    private var statusText: (text: String, asking: Bool)? {
        var sit: Nearby.Situation = store.situation
        sit.located = here != nil
        return Nearby.statusLine(sit, range: rangeWord)
    }

    @ViewBuilder private var status: some View {
        if let line = statusText {
            statusLine(spinner: line.asking, line.text)
        }
    }

    private func statusLine(spinner: Bool, _ text: String) -> some View {
        HStack(spacing: DS.s8) {
            if spinner { ProgressView().controlSize(.small).tint(DS.accentText) }
            Text(text).font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ o: Nearby.Option, _ w: NearbyStore.Way) -> some View {
        let name: String = Fmt.stop(w.group.name)
        let tg: [Nearby.Tag] = store.tags[o.id] ?? []
        let deps: [DoorTrip] = store.departures(o.id)
        var seen = Set<String>()
        let lines: [Ride] = deps.map(\.first).filter { seen.insert($0.line).inserted }
        let sureText: String = o.sure.map { s in s.source == .estimate ? "about \(s.percent)%" : "on time \(s.percent)%" } ?? ""
        // (0.42.2) a way overnight or much later: with its day, no tags
        let day: String? = Nearby.dayWord(o.arrival, now: Date(), calendar: Calendar.current)
        let arriveText: String = (day.map { $0 + " " } ?? "") + Fmt.hhmm(o.arrival)
        let spoken: String = "\(name), \(tg.map(\.rawValue).joined(separator: ", ")), \(o.walk) minutes walk, leaves \(Fmt.hhmm(o.departure)), there \(arriveText), \(sureText)"
        return HStack(alignment: .center, spacing: DS.s12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(1).minimumScaleFactor(0.8)
                    ForEach(tg, id: \.self) { NearbyTagChip(tag: $0) }
                    if !o.ranked {
                        Text("later").font(DS.caption).foregroundStyle(DS.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(DS.surface3, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk").font(.caption.weight(.semibold)).foregroundStyle(DS.secondary)
                    Text("\(o.walk) min ·").font(DS.footnote).foregroundStyle(DS.secondary)
                    ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, r in
                        DSLinePill(line: r.isTrain ? Transit.trainLabel(r.line) : r.line, train: r.isTrain)
                    }
                    Text("· leaves \(Fmt.hhmm(o.departure))").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    // (0.42.7) how late it leaves, by live times
                    if let f = store.bestTrip(o.id)?.first {
                        let sh: NearbyLive.Shown = NearbyLive.shown(departure: f.departure, scheduled: f.scheduledDeparture, live: f.live, cancelled: f.cancelled)
                        if sh.late {
                            Text(sh.word).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.warning).lineLimit(1).fixedSize()
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let d = day {
                    Text(d).font(DS.footnoteStrong).foregroundStyle(DS.secondary)
                }
                Text(Fmt.hhmm(o.arrival)).font(DS.bigNumber).monospacedDigit().foregroundStyle(o.ranked ? DS.text : DS.secondary)
                if !sureText.isEmpty {
                    Text(sureText).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isButton)
    }
}

/// A stop on the map: its circle in its arrival colour with the minutes, and the ring for how sure (a small "+1" when
/// another stop close by is drawn under it); a small grey dot while it's asked, a grey dot for a stop not planned from
/// yet (tap it to check), a smaller one when there's no way from it.
struct NearbyStopMark: View {
    enum Look: Equatable { case ready, pending, unasked, none }
    let state: Look
    let fill: Color
    let text: String
    let ring: Nearby.Ring
    var selected = false
    var more = 0

    var body: some View {
        ZStack {
            switch state {
            case .ready:
                Circle().fill(fill).frame(width: 36, height: 36)
                Text(text).font(.system(size: 13, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color(hex: 0x0B0C0E))
                ringView
                if more > 0 {
                    Text("+\(more)").font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(DS.surface, in: Capsule())
                        .offset(x: 17, y: -17)
                }
            case .pending:
                Circle().fill(DS.surface3).frame(width: 18, height: 18)
                Circle().stroke(DS.legQuiet, lineWidth: 2).frame(width: 18, height: 18)
            case .unasked:
                Circle().fill(DS.legQuiet.opacity(0.7)).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(DS.surface, lineWidth: 1.5))
            case .none:
                Circle().fill(DS.legQuiet.opacity(0.7)).frame(width: 10, height: 10)
            }
        }
        .frame(width: 54, height: 54)
        .scaleEffect(selected ? 1.18 : 1)
        .contentShape(Circle())
    }

    @ViewBuilder private var ringView: some View {
        switch ring {
        case .solid:
            Circle().stroke(fill, lineWidth: 3).frame(width: 48, height: 48)
        case .dashed:
            Circle().stroke(fill, style: StrokeStyle(lineWidth: 3, dash: [5, 4])).frame(width: 48, height: 48)
        case .neutral:
            Circle().stroke(DS.legQuiet, lineWidth: 1.5).frame(width: 46, height: 46)
        }
    }
}

/// "Fastest" (gold), "Surest" (the accent), "Slower" (quiet).
struct NearbyTagChip: View {
    let tag: Nearby.Tag
    static let gold = Color(hex: 0xE8A33D)
    var body: some View {
        let fill: Color = tag == .fastest ? Self.gold : tag == .surest ? DS.accent : DS.surface3
        let ink: Color = tag == .fastest ? Color(hex: 0x1A1205) : tag == .surest ? DS.onAccent : DS.secondary
        Text(tag.rawValue)
            .font(DS.caption)
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize()                     // (0.42.7) never "Fastes / t": the row's other text gives way first
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .layoutPriority(2)
    }
}

/// On Fastest trip's cards: back to the stops around you.
struct NearbyOpenButton: View {
    let action: () -> Void
    var body: some View {
        DSQuietButton(title: "All stops around you", icon: "map.circle", full: true, action: action)
            .accessibilityHint("Every stop you could walk to, with when you’d be there from each")
    }
}
