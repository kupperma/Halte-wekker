import CoreLocation
import SwiftUI

/// A stop to wake you at, and (from the map) whether it's a station.
struct WakeTarget: Identifiable, Hashable {
    let place: Place
    var rail: Bool? = nil
    var id: String { place.key }
}

/// Wake me at a stop, in the new look (0.20.1): search, your saved stops and the usual ones; then the stop with how far
/// it is and what leaves there next, the bus or train you're riding, how far before it to ring, and one big button. It
/// starts the same single-stop alarm as today's `StartSheet` (`TripManager.start(.stop(…))`). The old look keeps
/// `StartSheet`, `StopSheet` and `StopsList`.
struct WakeAtStopNew: View {
    @EnvironmentObject var stops: StopsStore
    @EnvironmentObject var near: NearMe
    @Environment(\.dismiss) private var dismiss
    @State private var path: [WakeTarget]
    @State private var query = ""
    @State private var hits: [Transit.StopHit] = []
    @State private var searching = false

    /// `preset`: straight to that stop (from the map); back goes to the search and your stops.
    init(preset: WakeTarget? = nil) {
        _path = State(initialValue: preset.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    Section {
                        if stops.saved.isEmpty {
                            Text("Search for a stop and tap its bookmark to keep it here.").font(DS.sub).foregroundStyle(DS.secondary)
                        }
                        ForEach(stops.saved) { s in
                            row(name: s.name, icon: "bookmark.fill", lat: s.lat, lon: s.lon) { path.append(WakeTarget(place: s.place)) }
                                .swipeActions {
                                    Button(role: .destructive) { stops.delete(s.id) } label: { Label("Delete", systemImage: "trash") }
                                }
                                .accessibilityAction(named: "Delete") { stops.delete(s.id) }
                        }
                    } header: { Text("Your stops") }
                    Section("Usual stops") {
                        ForEach(Place.all, id: \.key) { p in
                            row(name: p.name, icon: "mappin.and.ellipse", lat: p.coordinate.latitude, lon: p.coordinate.longitude) {
                                path.append(WakeTarget(place: p))
                            }
                        }
                    }
                } else {
                    if searching && hits.isEmpty { HStack { ProgressView(); Text("Searching…").foregroundStyle(DS.secondary) } }
                    else if hits.isEmpty { Text("No stops or stations found for “\(query)”").foregroundStyle(DS.secondary) }
                    ForEach(hits) { h in
                        let saved = stops.saved.first { $0.stopId == h.id }
                        HStack(spacing: 4) {
                            row(name: h.name, sub: h.town, icon: "mappin.and.ellipse", lat: h.lat, lon: h.lon) {
                                path.append(WakeTarget(place: Destination(id: h.id, name: h.name, lat: h.lat, lon: h.lon).place))
                            }
                            Button {
                                if let s = saved { stops.delete(s.id) }
                                else { stops.add(name: h.name, at: .init(latitude: h.lat, longitude: h.lon), stopId: h.id) }
                            } label: {
                                Image(systemName: saved == nil ? "bookmark" : "bookmark.fill").font(.body.weight(.semibold))
                                    .foregroundStyle(DS.accentText).frame(width: DS.hit, height: DS.hit).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(saved == nil ? "Save \(h.name)" : "Remove \(h.name) from your stops")
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search a stop or station")
            .navigationTitle("Wake me at a stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(for: WakeTarget.self) { t in WakeStopDetail(target: t) { dismiss() } }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { hits = []; return }
                try? await Task.sleep(nanoseconds: 350_000_000)         // (one search when you pause typing)
                guard !Task.isCancelled else { return }
                searching = true
                let found = await Transit.findStops(q)
                searching = false
                guard !Task.isCancelled else { return }
                hits = found
            }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func row(name: String, sub: String = "", icon: String, lat: Double, lon: Double, tap: @escaping () -> Void) -> some View {
        let away = MapTap.awayText(metres: near.position.map { $0.distance(from: CLLocation(latitude: lat, longitude: lon)) })
        let line = [sub.isEmpty ? nil : sub, away].compactMap { $0 }.joined(separator: " · ")
        return Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(DS.accentText).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(DS.bodyStrong).foregroundStyle(DS.text)
                    if !line.isEmpty { Text(line).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary).accessibilityHidden(true)
            }
            .frame(minHeight: DS.hit).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One stop to wake you at: how far it is, what leaves there next, the bus or train you're on, how far before the stop
/// to ring, and Wake me at <stop>.
struct WakeStopDetail: View {
    let target: WakeTarget
    let done: () -> Void
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var near: NearMe
    @Environment(\.scenePhase) private var scene
    @State private var mode: Mode = .train
    @State private var km: Double = 1
    @State private var ready = false
    @State private var board: [BoardDeparture] = []
    @State private var loaded = false

    private var p: Place { target.place }
    /// The leg the alarm follows: from where you are to the stop (as `StartSheet`).
    private var leg: Leg { Leg(mode: mode, from: .here(trip.here ?? p.coordinate), to: p) }
    private var boardIds: [String] { MapTap.boardIds(p.ids) }
    private var metres: Double? {
        near.position.map { $0.distance(from: CLLocation(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.short).font(DS.largeTitle).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
                    Text(MapTap.awayText(metres: metres) ?? (near.position == nil ? "Finding where you are…" : ""))
                        .font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary)
                }
                nextHere.dsPanel()
                VStack(alignment: .leading, spacing: DS.s12) {
                    DSHeader(title: "You’re riding a")
                    Picker("Riding", selection: $mode) {
                        Text("Bus").tag(Mode.bus)
                        Text("Train").tag(Mode.train)
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: DS.hit)
                }
                .dsPanel()
                wakeDistance.dsPanel()
                if trip.phase == .idle {
                    DSPrimaryButton(title: "Wake me at \(p.short)", icon: "bell.and.waves.left.and.right", lines: 2) { go() }
                } else {
                    DSNote(icon: "info.circle", tint: DS.accentText, text: "A trip is on. End it first to be woken at a stop.")
                }
            }
            .padding(DS.s16)
        }
        .background(DS.surface2.ignoresSafeArea())
        .navigationTitle(p.short)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !ready else { return }
            let s = StopsStore.shared
            mode = s.lastMode[p.key].flatMap(Mode.init(rawValue:)) ?? target.rail.map { $0 ? Mode.train : Mode.bus } ?? s.mode(for: p)
            km = trip.km(for: leg)
            ready = true
        }
        .onChange(of: mode) { _, _ in if ready { km = trip.km(for: leg) } }
        // what leaves there: every minute, only while this is on screen and the app in front
        .task(id: scene == .active) {
            guard scene == .active, !boardIds.isEmpty else { loaded = true; return }
            var first = !loaded
            while !Task.isCancelled {
                let ids = boardIds, from = Date().addingTimeInterval(-60)
                let b: [BoardDeparture] = first
                    ? await Transit.$urgent.withValue(true) { () async -> [BoardDeparture] in await Transit.board(stopIds: ids, from: from, n: 6) }
                    : await Transit.board(stopIds: ids, from: from, n: 6)
                guard !Task.isCancelled else { return }
                if !b.isEmpty || board.isEmpty { board = b }
                loaded = true; first = false
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    @ViewBuilder private var nextHere: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Next at this stop")
            if boardIds.isEmpty {
                Text("No live times known for this stop.").font(DS.sub).foregroundStyle(DS.secondary)
            } else if !loaded {
                DSSkeletonRow(); DSSkeletonRow()
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { tl in
                    let stop = DepartureGroups.Stop(id: "here", name: p.name, rail: false, metres: nil)
                    // (a stop with more than one id, as Veghel's: one list)
                    let deps = board.map { DepartureGroups.Departure(board: $0.at("here"), rail: false) }
                    let shown = DepartureGroups.cards(stops: [stop], departures: deps, now: tl.date, perCard: 4, maxCards: 1).first?.departures ?? []
                    VStack(alignment: .leading, spacing: 6) {
                        if shown.isEmpty {
                            Text("Nothing in the next while.").font(DS.sub).foregroundStyle(DS.secondary)
                        }
                        ForEach(shown) { d in
                            HStack(spacing: 8) {
                                DSLinePill(line: d.line, train: d.train).frame(width: 46, alignment: .leading)
                                Text(Fmt.place(d.headsign)).font(DS.callout).foregroundStyle(DS.text).lineLimit(1).strikethrough(d.cancelled)
                                Spacer(minLength: 4)
                                Text(d.cancelled ? "Cancelled" : DepartureGroups.countdown(d, now: tl.date, clock: Fmt.hhmm))
                                    .font(DS.calloutStrong).monospacedDigit().foregroundStyle(d.cancelled ? DS.warning : DS.text)
                                if let late = DepartureGroups.lateText(d) {
                                    Text(late).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.warning)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    private var wakeDistance: some View {
        let bus = mode == .bus
        return VStack(alignment: .leading, spacing: DS.s12) {
            DSHeader(title: "Wake me")
            HStack(spacing: DS.s12) {
                step("minus", enabled: km > 0.5) { km = MapTap.wakeKm(km, by: -0.5, bus: bus) }
                VStack(spacing: 2) {
                    Text(Fmt.km(km)).font(DS.bigNumber).monospacedDigit().foregroundStyle(DS.text)
                    Text("before the stop").font(DS.footnote).foregroundStyle(DS.secondary)
                }
                .frame(maxWidth: .infinity)
                step("plus", enabled: km < (bus ? 10 : 15)) { km = MapTap.wakeKm(km, by: 0.5, bus: bus) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Wake distance")
            .accessibilityValue("\(Fmt.km(km)) before the stop, roughly \(RideText.roughly(km: km, mode: mode))")
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: km = MapTap.wakeKm(km, by: 0.5, bus: bus)
                case .decrement: km = MapTap.wakeKm(km, by: -0.5, bus: bus)
                @unknown default: break
                }
            }
            Text("That’s roughly \(RideText.roughly(km: km, mode: mode)) before you arrive.")
                .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ icon: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.body.weight(.bold)).foregroundStyle(enabled ? DS.accentText : DS.secondary)
                .frame(width: DS.hit, height: DS.hit)
                .background(DS.surface3, in: Circle())
        }
        .buttonStyle(DSPressStyle())
        .disabled(!enabled)
    }

    /// As `StartSheet.go()` for a single stop: remember the mode, start the alarm.
    private func go() {
        guard trip.phase == .idle else { return }
        StopsStore.shared.setMode(mode, for: p)
        trip.start(.stop(p, mode: mode, from: .here(trip.here ?? p.coordinate)), kms: [km])
        done()
    }
}
