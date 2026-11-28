import CoreLocation
import MapKit
import SwiftUI

/// A stop picked on "Fastest trip, zoomed out" (its `Nearby.Group` id).
struct NearbyPick: Identifiable, Hashable { let id: String }

/// "Fastest trip, zoomed out" (0.42, concept N5): Fastest trip's overview. The map zooms out to the stops you could
/// walk to (one plan from where you are, walking up to 1.6 km, 3 km while fewer than 3 have a way, framed on the
/// useful ones; grey dots for stops to tap and check); 0.42.15: each stop with a way a mini card by its dot (its line,
/// leave and walk, arrive, how sure, FASTEST and SUREST), never on top of another, of you or of a dot
/// (`NearbyCards.layout`), the walk line from you solid gold or green to a tagged one. Leave now / in 10 / in 20 min.
/// Under it the stops, tagged Fastest and Surest. Tap one: its times, the whole trip, what's on the line now, and Go.
/// "Your trip and other times" (or the top right) shows Fastest trip's own cards as before.
struct NearbyOverview: View {
    @EnvironmentObject var go: GoStore
    @EnvironmentObject var trip: TripManager
    @StateObject private var store = NearbyStore()
    @StateObject private var line = NearbyLineModel()
    @State private var camera: MapCameraPosition = .automatic
    @State private var picked: NearbyPick?
    /// (0.42.15) Counts the map's moves: the cards follow their stops on the screen.
    @State private var moved: Int = 0
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
                mapView(width: g.size.width, height: mapH + 24)
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
        // (0.42.8) Fastest trip's fresher live times freshen the same trips here (by trip id, at any of their stops)
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

    /// A stop's dot on the map: tagged (gold, green), with a way (grey), or not planned from yet (`NearbyStopMark`).
    private struct Mark: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let state: NearbyStopMark.Look
        let edge: NearbyCards.Edge
        let spoken: String
    }

    /// (0.42.15) Every stop as a small dot; the ones with a way get a mini card by it (`NearbyCards.layout`, over the map).
    private func marks() -> [Mark] {
        var out: [Mark] = []
        for w in store.ways {
            let g: Nearby.Group = w.group
            let c = CLLocationCoordinate2D(latitude: g.lat, longitude: g.lon)
            let name: String = Fmt.stop(g.name)
            if let o = store.option(w.id) {
                let e: NearbyCards.Edge = NearbyCards.edge(store.badges[w.id])
                out.append(Mark(id: w.id, name: name, coordinate: c, state: .ready, edge: e, spoken: spoken(o, name: name)))
                continue
            }
            let st: NearbyStopMark.Look
            let said: String
            switch w.check {
            case .asking: st = .pending; said = "\(name): asking"
            case .done: st = .none; said = "\(name): no way from here in this time"
            case .unasked: st = .unasked; said = "\(name): not checked. Tap to check it"
            case .failed: st = .unasked; said = "\(name): couldn’t check it. Tap to try again"
            }
            out.append(Mark(id: w.id, name: name, coordinate: c, state: st, edge: .plain, spoken: said))
        }
        return out
    }

    private func spoken(_ o: Nearby.Option, name: String) -> String {
        let tags: [Nearby.Tag] = store.badges[o.id]?.tags ?? []
        let tagWords: String = tags.map { ", " + $0.rawValue }.joined()
        let sure: String = o.sure.map { ", on time \($0.percent)%" + (NearbyCards.estimateWord($0).map { " (\($0))" } ?? "") } ?? ""
        return "\(name)\(tagWords): leave \(Fmt.hhmm(o.departure)), \(o.walk) minutes walk, there at \(Fmt.hhmm(o.arrival))\(sure)"
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

    private func mapView(width: CGFloat, height: CGFloat) -> some View {
        let ms: [Mark] = marks()
        let following: Bool = picked != nil
        return MapReader { proxy in
            Map(position: $camera) {
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
                            NearbyStopMark(state: m.state, fill: Color(hex: NearbyCards.color(m.edge)), selected: picked?.id == m.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(m.state == .pending)
                        .accessibilityLabel(m.spoken)
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
            .onMapCameraChange(frequency: .continuous) { _ in moved &+= 1 }
            .overlay {
                if !following {
                    cards(proxy, marks: ms, width: width, height: height)
                }
            }
        }
    }

    /// The map's part the cards may use: under the top bar, above the list's round corners, off the edges.
    private func cardBounds(width: CGFloat, height: CGFloat) -> NearbyCards.Rect {
        let top: Double = 4 + Double(DS.hit) + 6
        let bottom: Double = Double(height) - 24 - 6
        return NearbyCards.Rect(x: 8, y: top, w: max(0, Double(width) - 16), h: max(0, bottom - top))
    }

    private func screen(_ proxy: MapProxy, _ c: CLLocationCoordinate2D) -> NearbyCards.Point? {
        guard let p = proxy.convert(c, to: .local) else { return nil }
        return NearbyCards.Point(x: Double(p.x), y: Double(p.y))
    }

    /// The mini cards (and pills), the walk lines from you to each stop with a way (solid gold or green when tagged,
    /// dashed grey else) and the leader lines, all at their screen places (`NearbyCards.layout`: never on top of each
    /// other, of you, of a dot, of the top bar or of the list).
    private func cards(_ proxy: MapProxy, marks ms: [Mark], width: CGFloat, height: CGFloat) -> some View {
        let _ = moved                                                  // (redrawn as the map moves)
        let opts: [Nearby.Option] = Nearby.ordered(store.options)
        var items: [NearbyCards.Item] = []
        var spotOf: [String: NearbyCards.Point] = [:]
        for o in opts {
            guard let w = store.way(o.id) else { continue }
            let c = CLLocationCoordinate2D(latitude: w.group.lat, longitude: w.group.lon)
            guard let p = screen(proxy, c) else { continue }
            spotOf[o.id] = p
            items.append(NearbyCards.Item(id: o.id, at: p, tagged: store.badges[o.id]?.tagged ?? false))
        }
        let others: [NearbyCards.Point] = ms.filter { spotOf[$0.id] == nil }.compactMap { screen(proxy, $0.coordinate) }
        let you: NearbyCards.Point? = here.flatMap { screen(proxy, $0.coordinate) }
        let bounds: NearbyCards.Rect = cardBounds(width: width, height: height)
        let placed: [NearbyCards.Placed] = NearbyCards.layout(items, bounds: bounds, you: you, dots: others)
        return ZStack(alignment: .topLeading) {
            NearbyCardLines(you: you, items: items, placed: placed, edges: edges(items))
                .allowsHitTesting(false)
            ForEach(placed.filter { $0.kind != .hidden }, id: \.id) { p in
                if let o = store.option(p.id) {
                    cardButton(p, o)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func edges(_ items: [NearbyCards.Item]) -> [String: NearbyCards.Edge] {
        var out: [String: NearbyCards.Edge] = [:]
        for i in items { out[i.id] = NearbyCards.edge(store.badges[i.id]) }
        return out
    }

    private func cardButton(_ p: NearbyCards.Placed, _ o: Nearby.Option) -> some View {
        let name: String = store.way(o.id).map { Fmt.stop($0.group.name) } ?? ""
        let badge: NearbyCards.Badge = store.badges[o.id] ?? NearbyCards.Badge()
        var seen = Set<String>()
        let rides: [Ride] = store.departures(o.id).map(\.first).filter { seen.insert($0.line).inserted }
        let lines: [(String, Bool)] = rides.prefix(2).map { r -> (String, Bool) in
            let label: String = r.isTrain ? Transit.trainLabel(r.line) : r.line
            return (label, r.isTrain)
        }
        let day: String? = Nearby.dayWord(o.arrival, now: Date(), calendar: Calendar.current)
        let arrive: String = (day.map { $0 + " " } ?? "") + Fmt.hhmm(o.arrival)
        let w: CGFloat = CGFloat(p.rect.w), h: CGFloat = CGFloat(p.rect.h)
        let cx: CGFloat = CGFloat(p.rect.x) + w / 2, cy: CGFloat = CGFloat(p.rect.y) + h / 2
        return Button { picked = NearbyPick(id: o.id) } label: {
            if p.kind == .card {
                NearbyMiniCard(lines: lines, leave: NearbyCards.leaveWords(Fmt.hhmm(o.departure), walk: o.walk), arrive: arrive,
                               sure: o.sure, badge: badge, ranked: o.ranked)
                    .frame(width: w, height: h)
            } else {
                NearbyMiniPill(text: Fmt.hhmm(o.arrival), edge: NearbyCards.edge(badge))
                    .frame(width: w, height: h)
            }
        }
        .buttonStyle(DSPressStyle())
        .contentShape(Rectangle().inset(by: p.kind == .pill ? -8 : 0))
        .position(x: cx, y: cy)
        .accessibilityLabel(spoken(o, name: name))
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
                }
                leaveSwitch
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
        let tg: [Nearby.Tag] = store.badges[o.id]?.tags ?? []
        let deps: [DoorTrip] = store.departures(o.id)
        var seen = Set<String>()
        let lines: [Ride] = deps.map(\.first).filter { seen.insert($0.line).inserted }
        let sureText: String = o.sure.map(NearbyCards.onTimeWords) ?? ""
        let estimate: String? = o.sure.flatMap(NearbyCards.estimateWord)
        // (0.42.2) a way overnight or much later: with its day, no tags
        let day: String? = Nearby.dayWord(o.arrival, now: Date(), calendar: Calendar.current)
        let arriveText: String = (day.map { $0 + " " } ?? "") + Fmt.hhmm(o.arrival)
        let tagWords: String = tg.map { $0.rawValue + ", " }.joined()
        let spoken: String = "\(name), \(tagWords)\(o.walk) minutes walk, leaves \(Fmt.hhmm(o.departure)), there \(arriveText), \(sureText)\(estimate.map { ", " + $0 } ?? "")"
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
                    Text(NearbyCards.walkWords(o.walk) + " ·").font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(1).fixedSize()
                    ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, r in
                        DSLinePill(line: r.isTrain ? Transit.trainLabel(r.line) : r.line, train: r.isTrain)
                    }
                    Text("· leaves \(Fmt.hhmm(o.departure))").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    // (0.42.8) how late it leaves, by live times
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
                    Text(sureText).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).lineLimit(1).fixedSize()
                }
                if let e = estimate {
                    Text(e).font(DS.caption).foregroundStyle(DS.secondary).lineLimit(1).fixedSize()
                }
            }
            .layoutPriority(1)
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

/// A stop on the map (0.42.15): a small dot, gold or green when it's tagged and grey else (its card is by it, over the
/// map); a small grey ring while it's asked, a grey dot for a stop not planned from yet (tap it to check), a smaller
/// one when there's no way from it.
struct NearbyStopMark: View {
    enum Look: Equatable { case ready, pending, unasked, none }
    let state: Look
    let fill: Color
    var selected = false

    var body: some View {
        ZStack {
            switch state {
            case .ready:
                Circle().fill(fill).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(hex: 0x0B0C0E), lineWidth: 2))
            case .pending:
                Circle().fill(DS.surface3).frame(width: 14, height: 14)
                Circle().stroke(DS.legQuiet, lineWidth: 2).frame(width: 14, height: 14)
            case .unasked:
                Circle().fill(DS.legQuiet.opacity(0.7)).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(DS.surface, lineWidth: 1.5))
            case .none:
                Circle().fill(DS.legQuiet.opacity(0.7)).frame(width: 9, height: 9)
            }
        }
        .frame(width: 14, height: 14)
        .scaleEffect(selected ? 1.3 : 1)
        .contentShape(Circle().inset(by: -6))
    }
}

/// "Fastest" (gold), "Surest" (green).
struct NearbyTagChip: View {
    let tag: Nearby.Tag
    static let gold = Color(hex: NearbyCards.color(.fastest))
    static let green = Color(hex: NearbyCards.color(.surest))
    var body: some View {
        let fill: Color = tag == .fastest ? Self.gold : tag == .surest ? Self.green : DS.surface3
        let ink: Color = tag == .slower ? DS.secondary : Color(hex: 0x10140F)
        Text(tag.rawValue)
            .font(DS.caption)
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize()                     // (0.42.8) never "Fastes / t": the row's other text gives way first
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .layoutPriority(2)
    }
}

/// (0.42.15) A stop's mini card on the map (design M4b): its lines and "leave 10:41 · 9 min walk", "arrive 12:07"
/// with how sure beside it ("92% on time", "estimate" when it isn't from your own rides), and the tags row (FASTEST,
/// SUREST; both when one way is both). Fixed sizes (`NearbyCards.cardWidth` and heights), so the layout's boxes hold:
/// the walk words give way first (cut off), the time and the % never.
struct NearbyMiniCard: View {
    let lines: [(String, Bool)]
    let leave: String
    let arrive: String
    let sure: Nearby.Sure?
    let badge: NearbyCards.Badge
    let ranked: Bool

    var body: some View {
        let edge: NearbyCards.Edge = NearbyCards.edge(badge)
        let stroke: Color = Color(hex: NearbyCards.color(edge))
        let radius: CGFloat = 10
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l.0).font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .foregroundStyle(DS.onAccent).lineLimit(1).fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(DS.mode(train: l.1, line: l.0), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(leave).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(DS.secondary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            }
            HStack(alignment: .center, spacing: 6) {
                Text("arrive " + arrive).font(.system(size: 15, weight: .bold)).monospacedDigit()
                    .foregroundStyle(ranked ? DS.text : DS.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 6)
                if let s = sure {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(NearbyCards.onTimeWords(s)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                            .foregroundStyle(DS.secondary).lineLimit(1)
                        if let e = NearbyCards.estimateWord(s) {
                            Text(e).font(.system(size: 9)).foregroundStyle(DS.secondary).lineLimit(1)
                        }
                    }
                    .fixedSize()
                }
            }
            if badge.tagged {
                HStack(spacing: 4) {
                    if badge.fastest { NearbyMiniTag(text: "FASTEST", fill: NearbyTagChip.gold) }
                    if badge.surest { NearbyMiniTag(text: "SUREST", fill: NearbyTagChip.green) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(stroke, lineWidth: CGFloat(NearbyCards.edgeWidth(edge))))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .dynamicTypeSize(.large)            // (fixed sizes: the boxes the layout made hold)
    }
}

/// FASTEST / SUREST on a mini card: one line, never cut.
struct NearbyMiniTag: View {
    let text: String
    let fill: Color
    var body: some View {
        Text(text).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color(hex: 0x10140F))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A stop's card folded to its arrival ("12:31") where there's no room for the card.
struct NearbyMiniPill: View {
    let text: String
    let edge: NearbyCards.Edge
    var body: some View {
        Text(text).font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(DS.text)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.surface, in: Capsule())
            .overlay(Capsule().stroke(Color(hex: NearbyCards.color(edge)), lineWidth: CGFloat(NearbyCards.edgeWidth(edge))))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            .dynamicTypeSize(.large)
    }
}

/// The lines under the cards: from you to each stop with a way (solid in its colour when tagged, dashed grey else),
/// stopping short of your dot and of the stop's; and each card's leader line to its dot.
struct NearbyCardLines: View {
    let you: NearbyCards.Point?
    let items: [NearbyCards.Item]
    let placed: [NearbyCards.Placed]
    let edges: [String: NearbyCards.Edge]

    var body: some View {
        Canvas { ctx, _ in
            if let y = you {
                for i in items { walk(ctx, from: y, to: i) }
            }
            for p in placed {
                guard let l = p.leader, let i = items.first(where: { $0.id == p.id }) else { continue }
                var path = Path()
                path.move(to: CGPoint(x: l.x, y: l.y))
                path.addLine(to: CGPoint(x: i.at.x, y: i.at.y))
                let e: NearbyCards.Edge = edges[p.id] ?? .plain
                ctx.stroke(path, with: .color(Color(hex: NearbyCards.color(e))), lineWidth: 1.5)
            }
        }
    }

    private func walk(_ ctx: GraphicsContext, from y: NearbyCards.Point, to i: NearbyCards.Item) {
        let dx: Double = i.at.x - y.x, dy: Double = i.at.y - y.y
        let d: Double = (dx * dx + dy * dy).squareRoot()
        let start: Double = NearbyCards.youRadius * 0.45, end: Double = NearbyCards.dotRadius
        guard d > start + end + 2 else { return }
        let ux: Double = dx / d, uy: Double = dy / d
        var path = Path()
        path.move(to: CGPoint(x: y.x + ux * start, y: y.y + uy * start))
        path.addLine(to: CGPoint(x: i.at.x - ux * end, y: i.at.y - uy * end))
        let e: NearbyCards.Edge = edges[i.id] ?? .plain
        let c: Color = Color(hex: NearbyCards.color(e))
        if NearbyCards.walkDashed(e) {
            ctx.stroke(path, with: .color(c.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
        } else {
            ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
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
