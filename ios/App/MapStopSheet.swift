import CoreLocation
import SwiftUI

/// A stop or station tapped on the home map (0.20.1): its live departures (its board, on the Polite lanes, every 30 s and
/// only while this sheet is open and in front), each with its details and its line to watch; and Wake me at this stop,
/// Plan from here and Plan to here.
struct MapStopSheet: View {
    let stop: Transit.NearStop
    /// Plan with this stop as where you start (true) or where you go (false).
    let plan: (Bool) -> Void
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var near: NearMe
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var board: [BoardDeparture] = []
    @State private var loaded = false
    @State private var lastAsk: Date?
    @State private var note: String?
    @State private var tapped: DepartureTap?
    @State private var wake: WakeTarget?

    /// The stop as a place to plan to or wake you at.
    static func place(_ s: Transit.NearStop) -> Place { Destination(id: s.id, name: s.name, lat: s.lat, lon: s.lon).place }

    private var name: String { stop.rail ? Fmt.place(stop.name) : Fmt.stop(stop.name) }
    private var metres: Double? { near.position.map { $0.distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon)) } }
    private var groupStop: DepartureGroups.Stop {
        DepartureGroups.Stop(id: stop.id, name: stop.name, rail: stop.rail, metres: metres, lat: stop.lat, lon: stop.lon)
    }
    /// Asking only while you can see it: the sheet in front, nothing over it, the app active.
    private var polling: Bool { scene == .active && tapped == nil && wake == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    header
                    if stop.rail { OVFietsLine(code: NSStore.code(stopId: stop.id, name: stop.name)) }      // (0.37)
                    departures
                    actions
                }
                .padding(.horizontal, DS.s20).padding(.bottom, DS.s24)
            }
            .background(DS.surface.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .task(id: polling) {
            guard polling else { return }
            while !Task.isCancelled {
                if lastAsk.map({ Date().timeIntervalSince($0) >= 30 }) ?? true { await load() }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .sheet(item: $tapped) { DepartureDetailSheet(tap: $0).presentationDetents([.medium, .large]) }
        .sheet(item: $wake) { WakeAtStopNew(preset: $0) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: stop.rail ? "tram.fill" : "bus.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(DS.onAccent)
                .frame(width: 44, height: 44)
                .background(stop.rail ? DS.train : DS.bus, in: RoundedRectangle(cornerRadius: stop.rail ? 12 : 22, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(DS.title).foregroundStyle(DS.text).lineLimit(2).accessibilityAddTraits(.isHeader)
                Text([stop.rail ? "Station" : "Bus stop", MapTap.awayText(metres: metres)].compactMap { $0 }.joined(separator: " · "))
                    .font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, DS.s4)
    }

    @ViewBuilder private var departures: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            let deps = board.map { DepartureGroups.Departure(board: $0, rail: stop.rail) }
            let shown = DepartureGroups.cards(stops: [groupStop], departures: deps, now: tl.date, perCard: 10, maxCards: 1).first?.departures ?? []
            VStack(alignment: .leading, spacing: 0) {
                DSHeader(title: "Leaving from here", sub: loaded ? nil : "Loading…")
                    .padding(.bottom, DS.s8)
                if !loaded {
                    DSSkeletonRow(); DSSkeletonRow(); DSSkeletonRow()
                } else if shown.isEmpty {
                    Text(note ?? "Nothing leaving here in the next while.").font(DS.sub).foregroundStyle(DS.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                }
                ForEach(shown) { d in DepartureRow(d: d, stop: groupStop) { tapped = $0 } }
                if loaded && !shown.isEmpty {
                    Text("Tap one for its details; hold it to watch its line.").font(DS.footnote).foregroundStyle(DS.secondary)
                        .padding(.top, DS.s8)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: DS.s8) {
            if trip.phase == .idle {
                DSPrimaryButton(title: "Wake me at \(name)", icon: "bell.and.waves.left.and.right", lines: 2) {
                    wake = WakeTarget(place: Self.place(stop), rail: stop.rail)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.s8) { planButtons }
                VStack(spacing: DS.s8) { planButtons }
            }
        }
        .padding(.top, DS.s8)
    }

    @ViewBuilder private var planButtons: some View {
        DSQuietButton(title: "Plan from here", icon: "arrow.up.right", full: true) { plan(true) }
            .accessibilityHint("Plan a trip starting at \(name)")
        DSQuietButton(title: "Plan to here", icon: "arrow.down.right", full: true) { plan(false) }
            .accessibilityHint("Plan a trip to \(name)")
    }

    /// Its board: the first answer on the urgent lane (you're waiting for it), the refreshes on the background lane.
    private func load() async {
        lastAsk = Date()
        let from = Date().addingTimeInterval(-60)
        let ids = [stop.id]
        let b: [BoardDeparture]
        if loaded {
            b = await Transit.board(stopIds: ids, from: from, n: 12)
        } else {
            b = await Transit.$urgent.withValue(true) { () async -> [BoardDeparture] in await Transit.board(stopIds: ids, from: from, n: 12) }
        }
        guard !Task.isCancelled else { return }
        if !b.isEmpty || board.isEmpty { board = b }
        note = b.isEmpty && board.isEmpty ? Transit.trouble.recent() : nil
        loaded = true
    }
}
