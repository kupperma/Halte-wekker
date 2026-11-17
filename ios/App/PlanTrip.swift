import CoreLocation
import MapKit
import SwiftUI

// MARK: the trip you're planning

/// Plan a trip (artboard C2): from your location (or anywhere) to anywhere, leaving now, at a time, or to be there by
/// one. The results come from one plain `Transit.plan` (urgent lane: you're waiting for it on screen); Go hands over
/// to the hands-free Fastest trip, which makes its own pick.
@MainActor
final class PlanTripModel: ObservableObject {
    enum End: Equatable {
        case here
        case place(Place, name: String? = nil)          // `name`: as your places call it ("Home")
        var label: String {
            switch self {
            case .here: return "My location"
            case .place(let p, let n): return n ?? p.short
            }
        }
    }

    @Published var from: End = .here
    @Published var to: End?
    @Published var when: PlanCompare.When = .now
    @Published var modes: String?                // nil every mode, "RAIL", "BUS"
    @Published private(set) var options: [DoorTrip] = []
    @Published private(set) var labels: [String: PlanCompare.Label] = [:]
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var focused: String?
    private var round = 0

    var fromHere: Bool { from == .here }

    func place(_ e: End, here: CLLocation?) -> Place? {
        switch e {
        case .here: return here.map { Place.here($0.coordinate) }
        case .place(let p, _): return p
        }
    }

    func swap() {
        guard let t = to else { return }
        let f = from
        from = t; to = f
    }

    func clear() { round += 1; options = []; labels = [:]; error = nil; loading = false; focused = nil }

    /// Ask for the ways there (a newer question makes an older answer go unused).
    func run(here: CLLocation?) async {
        guard let t = to else { clear(); return }
        round += 1
        let mine = round
        // a new question: the old answer goes at once (its cards and the Go title belonged to it)
        options = []; labels = [:]; focused = nil
        guard let a = place(from, here: here), let b = place(t, here: here) else {
            options = []; labels = [:]; loading = false
            error = "Haltewekker doesn’t know where you are yet. Turn on location, or pick where you start."
            return
        }
        if a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude {
            options = []; labels = [:]; error = "From and to are the same place."; return
        }
        loading = true; error = nil
        let now = Date()
        let (at, arriveBy): (Date, Bool) = {
            switch when {
            case .now: return (now.addingTimeInterval(-60), false)
            case .leave(let d): return (d.addingTimeInterval(-60), false)
            case .arrive(let d): return (d, true)
            }
        }()
        let m = modes
        let all = await Transit.$urgent.withValue(true) { () async -> [DoorTrip] in
            await Transit.plan(from: a, to: b, modes: m, at: at, count: 6, maxTransfers: 4, arriveBy: arriveBy)
        }
        guard mine == round else { return }
        let kept = all.filter { t in
            switch when {
            case .now: return t.first.departure >= now.addingTimeInterval(-60)
            case .leave(let d): return t.first.departure >= d.addingTimeInterval(-60)
            case .arrive: return t.first.departure >= now.addingTimeInterval(-60)
            }
        }
        let opts = kept.map(Self.option)
        let useful = PlanCompare.useful(opts).prefix(6).map(\.id)
        let byId = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        options = useful.compactMap { byId[$0] }
        var deadline: Date?
        if case .arrive(let d) = when { deadline = d }
        labels = PlanCompare.labels(options.map(Self.option), deadline: deadline)
        focused = labels.first(where: { $0.value == .fastest })?.key ?? options.first?.id
        loading = false
        error = options.isEmpty ? (Transit.trouble.recent() ?? "No trips found. Try another time, or check the places.") : nil
    }

    nonisolated static func option(_ t: DoorTrip) -> PlanCompare.Option {
        var room: Int?
        for k in t.rides.indices.dropFirst() {
            let r = Fmt.mins(t.rides[k].departure.timeIntervalSince(t.rides[k - 1].arrival)) - t.rides[k].walkBefore
            room = min(room ?? r, r)
        }
        return PlanCompare.Option(id: t.id, depart: t.first.departure, arrive: t.end, changes: t.rides.count - 1, minRoom: room)
    }

    /// The stops it draws on the map for the option you look at: where each ride gets on and off.
    func route(_ id: String?) -> [CLLocationCoordinate2D] {
        guard let t = options.first(where: { $0.id == id }) ?? options.first else { return [] }
        var c: [CLLocationCoordinate2D] = []
        for r in t.rides {
            if let a = r.fromLat, let o = r.fromLon { c.append(.init(latitude: a, longitude: o)) }
            if let a = r.toLat, let o = r.toLon { c.append(.init(latitude: a, longitude: o)) }
        }
        return c
    }

    // recent destinations of Plan (on the phone)
    static let recentsKey = "plan.recents"
    static func recents() -> [Destination] {
        UserDefaults.standard.data(forKey: recentsKey).flatMap { try? JSONDecoder().decode([Destination].self, from: $0) } ?? []
    }
    static func remember(_ d: Destination) {
        let l = Array(([d] + recents().filter { $0.id != d.id }).prefix(8))
        UserDefaults.standard.set(try? JSONEncoder().encode(l), forKey: recentsKey)
    }
}

// MARK: the directions sheet over the map

/// What can be opened from Plan.
enum PlanSheetKind: Identifiable, Equatable {
    case pickFrom, pickTo, when, wakeAtStop, route(String), planned, newPlan(byArrival: Bool)
    var id: String {
        switch self {
        case .pickFrom: return "from"
        case .pickTo: return "to"
        case .when: return "when"
        case .wakeAtStop: return "stop"
        case .route(let r): return "route-\(r)"
        case .planned: return "planned"
        case .newPlan(let b): return "new-\(b)"
        }
    }
}

struct PlanTripOverlay: View {
    @ObservedObject var model: PlanTripModel
    var pickOnOpen = false                              // opened from Search: straight to Where to?
    var legBars = false                                 // Next trip first: each option with its leg bar (B2)
    let close: () -> Void
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var near: NearMe
    @EnvironmentObject var goStore: GoStore
    @EnvironmentObject var planner: Planner
    @State private var sheet: PlanSheetKind?
    @State private var after: PlanSheetKind?           // to open once the picker has gone
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            fields.padding(.horizontal, DS.edge).padding(.top, 6)
            Spacer(minLength: 0)
            bottom
        }
        .sheet(item: $sheet, onDismiss: {
            if let a = after { after = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { sheet = a } }
        }) { s in sheetView(s) }
        .task(id: runKey) { await model.run(here: near.position) }
        .onAppear { if pickOnOpen && model.to == nil { sheet = .pickTo } }
    }

    /// A new question when what's asked changes.
    private var runKey: String {
        "\(near.position == nil)|\(placeKey(model.from))>\(model.to.map(placeKey) ?? "")|\(whenKey)|\(model.modes ?? "")"
    }
    private func placeKey(_ e: PlanTripModel.End) -> String {
        if case .place(let p, _) = e { return p.key + p.ids.joined(separator: ",") }
        return "here"
    }
    private var whenKey: String {
        switch model.when {
        case .now: return "now"
        case .leave(let d): return "l\(Int(d.timeIntervalSince1970 / 60))"
        case .arrive(let d): return "a\(Int(d.timeIntervalSince1970 / 60))"
        }
    }

    // MARK: from, to, when

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: close) {
                    Image(systemName: "chevron.left").font(.body.weight(.bold)).foregroundStyle(DS.text).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("Back to the map")
                VStack(spacing: 0) {
                    field(dot: AnyView(Circle().fill(Color.blue).frame(width: 9, height: 9)), text: model.from.label, placeholder: "From", a11y: "From") { sheet = .pickFrom }
                    Divider()
                    field(dot: AnyView(RoundedRectangle(cornerRadius: 2).fill(DS.text).frame(width: 9, height: 9)), text: model.to?.label, placeholder: "Where to?", a11y: "To") { sheet = .pickTo }
                }
                Button { withAnimation(DS.quick) { model.swap() } } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.body.weight(.semibold)).foregroundStyle(DS.text)
                        .frame(width: 44, height: 44).background(DS.surface3, in: Circle())
                }
                .buttonStyle(DSPressStyle()).disabled(model.to == nil)
                .accessibilityLabel("Swap from and to")
            }
            HStack(spacing: 8) {
                Button { sheet = .when } label: {
                    HStack(spacing: 4) {
                        Text(whenText).font(DS.subStrong).monospacedDigit()
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(DS.accentSoftText).padding(.horizontal, 12).frame(minHeight: 36)
                    .background(DS.accentSoft, in: Capsule())
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(DSPressStyle())
                .accessibilityHint("Pick when, and the options")
                Button { sheet = .when } label: {
                    Text(model.modes == nil ? "Options" : model.modes == "RAIL" ? "Trains only" : "Buses only").font(DS.sub).foregroundStyle(DS.text)
                        .padding(.horizontal, 12).frame(minHeight: 36).background(DS.surface3, in: Capsule())
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(DSPressStyle())
            }
            .padding(.leading, 52)
            .frame(minHeight: 44)
        }
        .padding(.leading, 4).padding(.trailing, 6).padding(.vertical, 6)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .dsFloat()
    }

    private func field(dot: AnyView, text: String?, placeholder: String, a11y: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                dot
                Text(text ?? placeholder).font(DS.body).foregroundStyle(text == nil ? DS.secondary : DS.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(a11y): \(text ?? "not set")")
    }

    private var whenText: String {
        switch model.when {
        case .now: return "Leave now"
        case .leave(let d): return "Leave \(dayWord(d))\(Fmt.hhmm(d))"
        case .arrive(let d): return "There by \(dayWord(d))\(Fmt.hhmm(d))"
        }
    }
    private func dayWord(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return "" }
        if c.isDateInTomorrow(d) { return "tomorrow " }
        return DayTimeline.label(d, cal: c) + " "
    }

    // MARK: the results and the action

    @ViewBuilder private var bottom: some View {
        VStack(spacing: 10) {
            if model.to == nil {
                MoreWaysList { sheet = $0 }.padding(.horizontal, DS.edge)
            } else if model.loading && model.options.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Finding the ways there…").font(DS.headline).foregroundStyle(DS.text)
                    DSSkeletonRow(); DSSkeletonRow()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsCard(radius: DS.cardRadiusSmall, padding: 14)
                .padding(.horizontal, DS.edge)
            } else if let e = model.error, model.options.isEmpty {
                Text(e).font(DS.sub).foregroundStyle(DS.text).frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard(radius: DS.cardRadiusSmall, padding: 14).padding(.horizontal, DS.edge)
            } else {
                optionCards
            }
            if let note { Text(note).font(DS.footnote).foregroundStyle(DS.secondary).padding(.horizontal, DS.edge) }
            action.padding(.horizontal, DS.edge)
        }
        .padding(.bottom, 8)
    }

    private var optionCards: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(model.options) { t in
                        OptionCard(trip: t, label: model.labels[t.id], selected: t.id == model.focused, legBar: legBars)
                            .containerRelativeFrame(.horizontal) { w, _ in min(300, w - 120) }
                            .id(t.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, DS.edge, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $model.focused)
            if model.options.count > 1 {
                HStack(spacing: 6) {
                    ForEach(model.options) { t in
                        let on = t.id == (model.focused ?? model.options.first?.id)
                        Capsule().fill(on ? DS.text : DS.text.opacity(0.3)).frame(width: on ? 18 : 6, height: 6)
                    }
                }
                .animation(DS.quick, value: model.focused)
                .accessibilityHidden(true)
            }
        }
    }

    private var focusedTrip: DoorTrip? { model.options.first { $0.id == model.focused } ?? model.options.first }

    private var dayOffset: Int {
        let c = Calendar.current
        let d: Date
        switch model.when {
        case .now: return 0
        case .leave(let x), .arrive(let x): d = x
        }
        return c.dateComponents([.day], from: c.startOfDay(for: Date()), to: c.startOfDay(for: d)).day ?? 9
    }

    /// Home and School, today's places (`.veghel` and `.buas` keys), one each way. Your location counts as one of
    /// them within about 800 m of it.
    private var homeSchoolOut: Bool? {
        guard case .place(let b, _)? = model.to else { return nil }
        let a: Place
        switch model.from {
        case .place(let p, _): a = p
        case .here:
            guard let h = near.position, let p = nearHomeOrSchool(h) else { return nil }
            a = p
        }
        if a.key == Place.veghel.key && b.key == Place.buas.key { return true }
        if a.key == Place.buas.key && b.key == Place.veghel.key { return false }
        return nil
    }

    private func nearHomeOrSchool(_ l: CLLocation) -> Place? {
        let places = PlacesStore.shared
        for sp in [places.home, places.school].compactMap({ $0 }) {
            let p = places.place(sp)
            guard p.key == Place.veghel.key || p.key == Place.buas.key else { continue }
            if l.distance(from: CLLocation(latitude: sp.lat, longitude: sp.lon)) < 800 { return p }
        }
        return nil
    }

    @ViewBuilder private var action: some View {
        if case .place(let dest, _)? = model.to, trip.phase == .idle {
            if PlanCompare.offersGo(fromHere: model.fromHere, when: model.when, now: Date()) {
                let stop = focusedTrip.map { Fmt.place($0.last.toStop) } ?? dest.short
                DSPrimaryButton(title: "Go · wake me before \(stop)", icon: "bell.and.waves.left.and.right") { go(dest) }
            } else if let out = homeSchoolOut, PlanCompare.offersRemind(homeSchool: true, fromHere: false, when: model.when, day: dayOffset) {
                DSPrimaryButton(title: "Remind me", icon: "bell") { remind(out: out) }
            }
        }
    }

    private func go(_ dest: Place) {
        guard trip.phase == .idle else { return }
        if dest.key == Place.buas.key, trip.direction != .toSchool { trip.pick(.toSchool) }
        if dest.key == Place.veghel.key, trip.direction != .home { trip.pick(.home) }
        withAnimation(.easeInOut(duration: 0.35)) {
            if case .arrive(let t) = model.when {
                goStore.open(to: dest, from: near.position, deadline: t, label: "\(dest.short) by \(Fmt.hhmm(t))")
            } else {
                goStore.open(to: dest, from: near.position)
            }
        }
        close()
    }

    private func remind(out: Bool) {
        let t: Date, leave: Bool
        switch model.when {
        case .now: return
        case .leave(let d): t = d; leave = true
        case .arrive(let d): t = d; leave = false
        }
        if let e = planner.setArrive(out: out, time: t, tomorrow: dayOffset == 1, leave: leave) {
            note = e
        } else {
            note = "Planned. You get a reminder ten minutes before you have to leave; it’s under More ways › Be there by."
        }
    }

    // MARK: sheets

    @ViewBuilder private func sheetView(_ s: PlanSheetKind) -> some View {
        switch s {
        case .pickFrom:
            EndPickerSheet(title: "From", allowHere: true, more: nil) { model.from = $0 }
        case .pickTo:
            EndPickerSheet(title: "Where to?", allowHere: model.from != .here, more: { after = $0 }) { model.to = $0 }
        case .when:
            PlanWhenSheet(when: model.when, modes: model.modes) { w, m in model.when = w; model.modes = m }
                .presentationDetents([.medium, .large])
        case .wakeAtStop:
            WakeAtStopNew()
        case .route(let id):
            if let r = RoutePlan.all.first(where: { $0.id == id }) { StartSheet(req: StartRequest(route: r)).presentationDetents([.medium, .large]) }
        case .planned:
            PlannedTripsSheet()
        case .newPlan(let byArrival):
            PlanSheet(byArrival: byArrival)
        }
    }
}

/// One way there: its comparison label, the times, the rides as pills, and the change (red when it's tight).
struct OptionCard: View {
    let trip: DoorTrip
    let label: PlanCompare.Label?
    let selected: Bool
    var legBar = false
    var body: some View {
        let changes = Array(trip.rides.indices.dropFirst())
        let tight = changes.first { k in
            let ch = Fmt.mins(trip.rides[k].departure.timeIntervalSince(trip.rides[k - 1].arrival))
            return Risk.changeNote(after: trip.rides[k - 1], minutes: ch, walk: trip.rides[k].walkBefore).red
        }
        VStack(alignment: .leading, spacing: 8) {
            Text(label?.rawValue ?? "Option").font(DS.footnoteStrong).foregroundStyle(label == .fastest ? DS.accentText : DS.secondary)
            Text("\(Fmt.hhmm(trip.first.departure)) → \(Fmt.hhmm(trip.end))").font(DS.bigNumber).monospacedDigit().foregroundStyle(DS.text)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 5) {
                ForEach(Array(trip.rides.enumerated()), id: \.offset) { k, r in
                    if k > 0 { Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(DS.secondary) }
                    DSLinePill(line: r.isTrain ? Transit.trainLabel(r.line) : r.line, train: r.isTrain)
                }
                Text("· \(Fmt.rideText(trip.end.timeIntervalSince(trip.start) / 60))").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                    .lineLimit(1)
            }
            if legBar { DSLegBar(legs: NextTrip.legs(of: trip)) }
            Group {
                if let k = tight {
                    let ch = Fmt.mins(trip.rides[k].departure.timeIntervalSince(trip.rides[k - 1].arrival))
                    Label("\(ch) min to change at \(Fmt.place(trip.rides[k - 1].toStop))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DS.warning)
                } else {
                    Text(note(changes.first)).foregroundStyle(DS.secondary)
                }
            }
            .font(DS.sub).monospacedDigit().lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous).stroke(selected ? DS.accent : .clear, lineWidth: 2))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }

    /// "Platform 4 · 7 min to change", "Direct · 3 min walk first".
    private func note(_ change: Int?) -> String {
        var parts: [String] = []
        if trip.first.isTrain, let p = trip.first.platform { parts.append("Platform \(p)") }
        if let k = change {
            parts.append("\(Fmt.mins(trip.rides[k].departure.timeIntervalSince(trip.rides[k - 1].arrival))) min to change")
        } else {
            parts.append("Direct")
            if trip.first.walkBefore > 0 { parts.append("\(trip.first.walkBefore) min walk first") }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: picking where from and where to

/// A place to plan from or to: your location, your places, recent ones, or a stop or station by name. Picking a
/// destination with nothing typed also offers today's other ways to set an alarm (More ways).
struct EndPickerSheet: View {
    let title: String
    let allowHere: Bool
    let more: ((PlanSheetKind) -> Void)?
    let pick: (PlanTripModel.End) -> Void
    @ObservedObject private var places = PlacesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [Transit.StopHit] = []
    @State private var searching = false
    @State private var recents = PlanTripModel.recents()

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    if allowHere {
                        row(icon: "location.fill", title: "My location", sub: nil) { choose(.here) }
                    }
                    Section("Your places") {
                        ForEach(places.list) { p in row(icon: p.symbol, title: p.name, sub: nil) { choose(.place(places.place(p), name: p.name)) } }
                    }
                    if !recents.isEmpty {
                        Section("Recent") {
                            ForEach(recents) { d in row(icon: "clock.arrow.circlepath", title: d.short, sub: d.name == d.short ? nil : d.name) { choose(.place(d.place)) } }
                        }
                    }
                    if let more {
                        Section("More ways") { MoreWaysRows { k in more(k); dismiss() } }
                    }
                } else {
                    if searching && hits.isEmpty { HStack { ProgressView(); Text("Searching…").foregroundStyle(DS.secondary) } }
                    else if hits.isEmpty { Text("No stops or stations found for “\(query)”").foregroundStyle(DS.secondary) }
                    ForEach(hits) { h in
                        row(icon: "mappin.and.ellipse", title: h.name, sub: h.town.isEmpty ? nil : h.town) {
                            let d = Destination(id: h.id, name: h.name, lat: h.lat, lon: h.lon)
                            PlanTripModel.remember(d)
                            choose(.place(d.place))
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search anywhere")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { hits = []; return }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                searching = true
                let found = await Transit.findStops(q)
                searching = false
                guard !Task.isCancelled else { return }
                hits = found
            }
        }
        .tint(DS.accentText)
    }

    private func choose(_ e: PlanTripModel.End) { pick(e); dismiss() }

    private func row(icon: String, title: String, sub: String?, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(DS.accentText).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.bodyStrong).foregroundStyle(DS.text)
                    if let sub { Text(sub).font(DS.footnote).foregroundStyle(DS.secondary) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Today's other ways to set off, kept within reach: an alarm at a single stop, one of your routes by hand, your
/// friend's train, and Be there by.
struct MoreWaysRows: View {
    @EnvironmentObject var planner: Planner
    let open: (PlanSheetKind) -> Void
    var body: some View {
        Group {
            item("mappin.and.ellipse", "Wake me at a stop", "A single stop, or one you saved") { open(.wakeAtStop) }
            ForEach(RoutePlan.all) { r in
                item("bell.and.waves.left.and.right", "My route \(r.name.lowercased())", "Start the alarm by hand") { open(.route(r.id)) }
            }
            item("tram.fill", "Friend’s train", planner.trip.map { "\($0.dayLabel) · \($0.out ? "arrive Breda" : "leave Breda") \($0.time)" } ?? "Plan by the time of a train") {
                open(planner.trip == nil ? .newPlan(byArrival: false) : .planned)
            }
            item("flag.checkered", "Be there by", planner.arrive.map { "\($0.dayLabel) · \($0.out ? "school" : "home") \($0.leaving ? "leave" : "by") \($0.time)" } ?? "Or leave at a time, to school or home") {
                open(planner.arrive == nil ? .newPlan(byArrival: true) : .planned)
            }
        }
    }
    private func item(_ icon: String, _ title: String, _ sub: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(DS.accentText).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.bodyStrong).foregroundStyle(DS.text)
                    Text(sub).font(DS.footnote).foregroundStyle(DS.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
            }
            .frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// More ways, as a card over the map (Plan with nowhere picked yet).
struct MoreWaysList: View {
    let open: (PlanSheetKind) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("More ways").font(DS.headline).foregroundStyle(DS.text).padding(.bottom, 4)
            MoreWaysRows(open: open)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(radius: DS.cardRadiusSmall, padding: 14)
    }
}

// MARK: when, and the options

/// "Leave now ▾": leave now, at a time, or be there by a time; and the options the planner has (trains or buses only).
struct PlanWhenSheet: View {
    let done: (PlanCompare.When, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Int
    @State private var time: Date
    @State private var modes: String

    init(when: PlanCompare.When, modes: String?, done: @escaping (PlanCompare.When, String?) -> Void) {
        self.done = done
        switch when {
        case .now: _kind = State(initialValue: 0); _time = State(initialValue: Date().addingTimeInterval(30 * 60))
        case .leave(let d): _kind = State(initialValue: 1); _time = State(initialValue: d)
        case .arrive(let d): _kind = State(initialValue: 2); _time = State(initialValue: d)
        }
        _modes = State(initialValue: modes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("When", selection: $kind) { Text("Leave now").tag(0); Text("Leave at").tag(1); Text("Be there by").tag(2) }
                        .pickerStyle(.segmented)
                    if kind != 0 {
                        DatePicker(kind == 1 ? "Leave at" : "Be there by", selection: $time, in: Date().addingTimeInterval(-10 * 60)...Date().addingTimeInterval(30 * 86400))
                    }
                }
                Section("Options") {
                    Picker("Travel by", selection: $modes) { Text("Bus and train").tag(""); Text("Train only").tag("RAIL"); Text("Bus only").tag("BUS") }
                }
            }
            .navigationTitle("When")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        done(kind == 0 ? .now : kind == 1 ? .leave(time) : .arrive(time), modes.isEmpty ? nil : modes)
                        dismiss()
                    }
                }
            }
        }
        .tint(DS.accentText)
    }
}

// MARK: today's other ways, in sheets

/// Wake me at a single stop: today's list of stops (yours and the usual ones), to start the alarm by hand.
struct WakeAtStopSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var startReq: StartRequest?
    @State private var stopEdit: StopEditRequest?
    var body: some View {
        NavigationStack {
            ScrollView {
                StopsList(pal: .toBreda, start: { startReq = StartRequest(stop: $0) }, edit: { stopEdit = StopEditRequest(stop: $0) })
                    .padding(16)
            }
            .background(PaperFill().ignoresSafeArea())
            .navigationTitle("Wake me at a stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.light)
        .sheet(item: $startReq) { StartSheet(req: $0).presentationDetents([.medium, .large]) }
        .sheet(item: $stopEdit) { StopSheet(req: $0) }
    }
}

/// Your Be there by plan and your friend's train, as today's passes: view, change, remove, start.
struct PlannedTripsSheet: View {
    @EnvironmentObject var planner: Planner
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var goStore: GoStore
    @EnvironmentObject var near: NearMe
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Bool?            // true: Be there by, false: friend's train
    @State private var startReq: StartRequest?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if planner.arrive != nil {
                        ArrivePass(edit: { editing = true }, go: {
                            dismiss()
                            HomeActions.openPlanGo(school: false, trip: trip, planner: planner, goStore: goStore, near: near)
                        }, wake: { t in
                            if let a = planner.arrive { trip.pick(a.out ? .toSchool : .home) }
                            if let via = t.via, let r = RoutePlan.all.first(where: { $0.station.short == via }) { startReq = StartRequest(route: r) }
                            else if let r = RoutePlan.from(t) { trip.start(r); dismiss() }
                        })
                    } else {
                        Button("Be there by, or leave at…") { editing = true }.font(HWFont.body(15, bold: true)).foregroundStyle(Paper.ink)
                    }
                    if planner.trip != nil {
                        PlannedPass(edit: { editing = false }, wake: { r in
                            if let t = planner.trip { trip.pick(t.out ? .toSchool : .home) }
                            startReq = StartRequest(route: r)
                        })
                    } else {
                        Button("Plan by your friend’s train") { editing = false }.font(HWFont.body(15, bold: true)).foregroundStyle(Paper.ink)
                    }
                }
                .padding(16)
            }
            .background(PaperFill().ignoresSafeArea())
            .navigationTitle("Planned trips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.light)
        .sheet(item: $startReq) { StartSheet(req: $0).presentationDetents([.medium, .large]) }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) { PlanSheet(byArrival: editing ?? true) }
    }
}
