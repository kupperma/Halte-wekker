import CoreLocation
import MapKit
import SwiftUI

/// What leaves from the stops around you, for the home's cards. Away from your usual start the live store already has
/// it (the boards near you); at home your Veghel board; anywhere else (at school, say) it asks itself: the stops near
/// you once per 150 m or 10 minutes, their next departures at most every minute, on the background lane, only while
/// the home is on screen.
@MainActor
final class NearDeparturesModel: ObservableObject {
    static let shared = NearDeparturesModel()
    @Published private(set) var stops: [Transit.NearStop] = []
    @Published private(set) var board: [BoardDeparture] = []
    @Published private(set) var loaded = false
    private var stopsAt: (CLLocation, Date)?
    private var boardAt: Date?
    private var busy = false

    func refresh(at loc: CLLocation?) async {
        guard let loc, !busy else { return }
        busy = true
        defer { busy = false }
        if stopsAt.map({ loc.distance(from: $0.0) > 150 || Date().timeIntervalSince($0.1) > 600 }) ?? true {
            if let s = await Transit.nearStopsAnswer(loc.coordinate) {
                stops = LiveStore.onePerName(s)
                stopsAt = (loc, Date())
                boardAt = nil
            }
        }
        guard !stops.isEmpty else { loaded = true; return }
        guard boardAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        let b = await Transit.board(stopIds: stops.map(\.id), from: Date().addingTimeInterval(-60), n: 8)
        if !b.isEmpty || board.isEmpty { board = b }
        boardAt = Date()
        loaded = true
    }
}

extension DepartureGroups.Departure {
    /// A board's departure for the cards (a station's: its trains with their train labels).
    init(board d: BoardDeparture, rail: Bool) {
        let train = rail || d.train
        self.init(tripId: d.tripId, stopId: d.stopId, line: train ? Transit.trainLabel(d.line) : d.line, headsign: d.headsign,
                  time: d.time, scheduled: d.scheduled, live: d.live, cancelled: d.cancelled, platform: d.platform,
                  train: train, stopName: d.stopName)
    }
}

/// A departure you tapped, and its stop.
struct DepartureTap: Identifiable {
    let dep: DepartureGroups.Departure
    let stop: DepartureGroups.Stop
    var id: String { dep.id }
}

/// The swipeable cards: one stop each, its next three departures; the next-trip nudge first when a planned trip is due.
struct DepartureCardsView: View {
    let cards: [DepartureGroups.Card]
    let loading: Bool
    let asOf: Date?
    let note: String?                         // nothing to show, and why
    let nudge: AnyView?
    @Binding var focused: String?
    let tap: (DepartureTap) -> Void
    let openDay: () -> Void
    @EnvironmentObject var lines: LineWatchStore

    var body: some View {
        VStack(spacing: 0) {
            // the handle: a full-width strip to tap or drag up (the cards themselves only swipe sideways)
            Button(action: openDay) {
                Capsule().fill(DS.secondary.opacity(0.5)).frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(DragGesture(minimumDistance: 10).onEnded { v in
                if v.translation.height < -30 && abs(v.translation.height) > abs(v.translation.width) { openDay() }
            })
            .accessibilityLabel("Your day")
            .accessibilityHint("Shows your day: alarm, trip and classes")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .bottom, spacing: 12) {
                    if let nudge {
                        nudge.containerRelativeFrame(.horizontal) { w, _ in w - 60 }.id("nudge")
                    }
                    if cards.isEmpty {
                        placeholder.containerRelativeFrame(.horizontal) { w, _ in w - 60 }.id("empty")
                    }
                    ForEach(cards) { c in
                        card(c).containerRelativeFrame(.horizontal) { w, _ in w - 60 }.id(c.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, DS.edge, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $focused)
            dots
        }
    }

    private var ids: [String] { (nudge == nil ? [] : ["nudge"]) + (cards.isEmpty ? ["empty"] : cards.map(\.id)) }

    @ViewBuilder private var dots: some View {
        if ids.count > 1 {
            HStack(spacing: 6) {
                ForEach(ids, id: \.self) { id in
                    let on = id == (focused ?? ids.first)
                    Capsule().fill(on ? DS.text : DS.text.opacity(0.3)).frame(width: on ? 18 : 6, height: 6)
                }
            }
            .animation(DS.quick, value: focused)
            .padding(.top, 8)
            .accessibilityHidden(true)
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10).fill(DS.surface3).frame(width: 34, height: 34)
                    RoundedRectangle(cornerRadius: 4).fill(DS.surface3).frame(width: 140, height: 16)
                }
                DSSkeletonRow(); DSSkeletonRow(); DSSkeletonRow()
            } else {
                Text("Around you").font(DS.headline).foregroundStyle(DS.text)
                Text(note ?? "Nothing leaving near you right now.").font(DS.sub).foregroundStyle(DS.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(loading ? "Loading the departures near you" : (note ?? "Nothing leaving near you right now."))
    }

    private func card(_ c: DepartureGroups.Card) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: c.stop.rail ? "tram.fill" : "bus.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.onAccent)
                    .frame(width: 34, height: 34)
                    .background(c.stop.rail ? DS.train : DS.bus, in: RoundedRectangle(cornerRadius: c.stop.rail ? 10 : 17, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.stop.rail ? Fmt.place(c.stop.name) : Fmt.stop(c.stop.name)).font(DS.headline).foregroundStyle(DS.text).lineLimit(1)
                    Text(subtitle(c.stop))
                        .font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if c.departures.isEmpty && loading {
                DSSkeletonRow(); DSSkeletonRow(); DSSkeletonRow()
            } else if c.departures.isEmpty {
                Text("Nothing leaving here soon.").font(DS.sub).foregroundStyle(DS.secondary).padding(.vertical, 6)
            }
            ForEach(c.departures) { d in row(d, c.stop) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    /// "Station · 4 min walk", "Bus · as of 08:12".
    private func subtitle(_ s: DepartureGroups.Stop) -> String {
        var parts: [String] = [s.rail ? "Station" : "Bus"]
        if let w = DepartureGroups.walkText(metres: s.metres) { parts.append(w) }
        if let a = asOf { parts.append(Snapshots.asOf(a)) }
        return parts.joined(separator: " · ")
    }

    private func row(_ d: DepartureGroups.Departure, _ s: DepartureGroups.Stop) -> some View {
        DepartureRow(d: d, stop: s, tap: tap)
    }
}

/// A departure's row (a card on the home, a stop's sheet): its line, where to, the platform, when, how late; tap for its
/// details, hold to watch its line.
struct DepartureRow: View {
    let d: DepartureGroups.Departure
    let stop: DepartureGroups.Stop
    let tap: (DepartureTap) -> Void
    @EnvironmentObject var lines: LineWatchStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            Button { tap(DepartureTap(dep: d, stop: stop)) } label: {
                HStack(spacing: 8) {
                    DSLinePill(line: d.line, train: d.train).frame(width: 46, alignment: .leading)
                    Text(Fmt.place(d.headsign)).font(DS.calloutStrong).foregroundStyle(DS.text).lineLimit(2)
                        .strikethrough(d.cancelled)
                    Spacer(minLength: 4)
                    if let p = d.platform, d.train { Text("Pl. \(p)").font(DS.footnote).foregroundStyle(DS.secondary).monospacedDigit() }
                    if lines.isWatched(stopId: d.stopId, stopName: d.stopName, line: d.line, headsign: d.headsign) {
                        Image(systemName: "bell.fill").font(.caption2).foregroundStyle(DS.accentText).accessibilityLabel("Watched")
                    }
                    if d.cancelled {
                        Text("Cancelled").font(DS.footnoteStrong).foregroundStyle(DS.warning)
                    } else {
                        HStack(spacing: 3) {
                            Text(DepartureGroups.countdown(d, now: tl.date, clock: Fmt.hhmm)).font(DS.calloutStrong).monospacedDigit()
                                .foregroundStyle(d.live && DepartureGroups.lateText(d) == nil ? DS.accentText : DS.text)
                            if let late = DepartureGroups.lateText(d) {
                                Text(late).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.warning)
                            }
                        }
                        .frame(minWidth: 58, alignment: .trailing)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spoken(d, now: tl.date))
            .contextMenu {
                let on = lines.isWatched(stopId: d.stopId, stopName: d.stopName, line: d.line, headsign: d.headsign)
                Button {
                    lines.toggle(stopId: d.stopId, stopName: d.stopName, line: d.line, headsign: d.headsign, tripId: d.tripId, delay: d.live ? d.delay : nil)
                } label: { Label(on ? "Stop watching this line" : "Watch this line", systemImage: on ? "bell.slash" : "bell") }
            }
        }
    }

    private func spoken(_ d: DepartureGroups.Departure, now: Date) -> String {
        let what = "\(d.train ? "Train" : "Line") \(d.line) to \(Fmt.place(d.headsign))"
        if d.cancelled { return "\(what), cancelled" }
        let late = DepartureGroups.lateText(d).map { ", \($0.dropFirst()) minutes late" } ?? ""
        let platform = d.train ? d.platform.map { ", platform \($0)" } ?? "" : ""
        return "\(what), \(DepartureGroups.countdown(d, now: now, clock: Fmt.hhmm))\(late)\(platform)"
    }
}

/// The departure you tapped: when it goes, how it's running, and what you can do with it (see it live, walk there,
/// watch the line).
struct DepartureDetailSheet: View {
    let tap: DepartureTap
    @EnvironmentObject var lines: LineWatchStore
    @EnvironmentObject var trains: WatchStore
    @EnvironmentObject var live: LiveStore
    @EnvironmentObject var ns: NSStore
    @Environment(\.dismiss) private var dismiss
    @State private var liveTrack: LiveTrackTarget?
    @State private var walkTo: WalkTarget?

    private var d: DepartureGroups.Departure { tap.dep }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    HStack(spacing: 10) {
                        DSLinePill(line: d.line, train: d.train)
                        Text("to \(Fmt.place(d.headsign))").font(DS.title).foregroundStyle(DS.text).lineLimit(2)
                    }
                    Text(fromText)
                        .font(DS.sub).foregroundStyle(DS.secondary)
                    TimelineView(.periodic(from: .now, by: 30)) { tl in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Fmt.hhmm(d.leaves)).font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                                .foregroundStyle(DS.text).strikethrough(d.cancelled)
                            Text(DepartureGroups.countdown(d, now: tl.date, clock: Fmt.hhmm)).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.secondary)
                        }
                    }
                    Label(status, systemImage: d.cancelled || d.delay >= 1 ? "exclamationmark.triangle.fill" : d.live ? "dot.radiowaves.left.and.right" : "clock")
                        .font(DS.calloutStrong).foregroundStyle(d.cancelled || d.delay >= 1 ? DS.warning : d.live ? DS.accentText : DS.secondary)
                    VStack(spacing: 0) {
                        action(icon: "location.viewfinder", title: "Where is it now") {
                            liveTrack = LiveTrackTarget(tripId: d.tripId, line: d.line, headsign: d.headsign, stopName: d.stopName, time: d.leaves, rail: d.train)
                        }
                        if let la = tap.stop.lat, let lo = tap.stop.lon {
                            Divider()
                            action(icon: "figure.walk", title: "Walk to the stop") {
                                walkTo = WalkTarget(name: tap.stop.rail ? Fmt.place(tap.stop.name) : Fmt.stop(tap.stop.name), lat: la, lon: lo, rail: tap.stop.rail,
                                                    catchText: d.cancelled ? nil : "the \(d.line) to \(Fmt.place(d.headsign)) at \(Fmt.hhmm(d.time))",
                                                    leaves: d.cancelled ? nil : d.time)
                            }
                        }
                        Divider()
                        if let pt = trainTrip {
                            // a train from one of your stations: NS tells you about a platform change or a delay
                            let on = trains.isWatched(pt.trip.first, from: pt.from)
                            action(icon: on ? "bell.slash" : "bell", title: on ? "Stop telling me about this train" : "Tell me about platform changes") {
                                _ = trains.toggle(pt.trip, from: pt.from, to: pt.to)
                            }
                        } else {
                            let on = lines.isWatched(stopId: d.stopId, stopName: d.stopName, line: d.line, headsign: d.headsign)
                            action(icon: on ? "bell.slash" : "bell", title: on ? "Stop watching this line" : "Watch this line") {
                                lines.toggle(stopId: d.stopId, stopName: d.stopName, line: d.line, headsign: d.headsign, tripId: d.tripId, delay: d.live ? d.delay : nil)
                            }
                        }
                    }
                    .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                    Text("Watching a line tells you when the next one runs late, leaves early or is cancelled, until you’re on it.")
                        .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    details
                }
                .padding(DS.s20)
            }
            .background(DS.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(DS.accentText)
        .sheet(item: $liveTrack) { LiveBusSheet(target: $0, newLook: true).presentationDetents([.large]) }
        .sheet(item: $walkTo) { WalkMapSheet(target: $0).presentationDetents([.large]) }
    }

    /// The rest of the old train and bus pages (0.20): your ride, how steady the line is, its speed rank, and for a
    /// train how it's made up and how busy.
    @ViewBuilder private var details: some View {
        let ride = live.boardRides["\(d.stopId)|\(d.tripId)"]
        let known = trainTrip?.trip.first
        VStack(alignment: .leading, spacing: DS.s20) {
            if let r = ride, !d.cancelled {
                VStack(alignment: .leading, spacing: DS.s8) {
                    DSHeader(title: "Your ride")
                    Text("\(Fmt.rideText(r.minutes)) ride to \(r.station) station, arrives \(Fmt.hhmm(r.arrival))").font(DS.sub).monospacedDigit().foregroundStyle(DS.text)
                }
            } else if let pt = trainTrip {
                VStack(alignment: .leading, spacing: DS.s8) {
                    DSHeader(title: "Your ride", sub: pt.trip.rideLabel)
                    Text("Arrives \(pt.to.short) \(Fmt.hhmm(pt.trip.last.arrival))").font(DS.sub).monospacedDigit().foregroundStyle(DS.text)
                }
            }
            DSSteadyInfo(line: d.line, train: d.train, stop: d.train ? known?.toStop : nil, at: d.leaves)
            if let r = ride {
                DSRankInfo(rank: RankInfo(grade: d.cancelled ? nil : r.grade, minutes: r.minutes, best: r.best,
                                          stretch: "\(Fmt.place(d.stopName)) → \(r.station)"), cancelled: d.cancelled)
            } else if let k = known {
                DSRankInfo(rank: RankInfo.of(k), cancelled: d.cancelled)
            }
            if d.train {
                DSTrainInfo(info: known.flatMap { ns.rail($0) }, nsMissing: ns.available == false)
            } else {
                VStack(alignment: .leading, spacing: DS.s8) {
                    DSHeader(title: "How busy")
                    Text("There’s no busyness forecast for buses.").font(DS.sub).foregroundStyle(DS.secondary)
                }
            }
        }
        .padding(.top, DS.s8)
    }

    /// This train as a one-ride trip between two of your stations, as the old train page watches it (`HomeView.trainTrip`):
    /// only a train your trips or lists know (they have its number for NS), between stations NS covers.
    private var trainTrip: PanelTrip? {
        guard d.train else { return nil }
        let known = (live.trains.map(\.trip) + live.next).flatMap(\.rides).first { $0.tripId == d.tripId && $0.isTrain }
        guard let r = known, !r.num.isEmpty,
              let from = Place.all.first(where: { $0.short == Fmt.place(r.fromStop) }), NSStore.code(from) != nil,
              let to = Place.all.first(where: { $0.short == Fmt.place(r.toStop) }) else { return nil }
        return PanelTrip(trip: DoorTrip(rides: [r], start: r.departure, end: r.arrival), from: from, to: to)
    }

    private var fromText: String {
        let name = tap.stop.rail ? Fmt.place(tap.stop.name) : Fmt.stop(tap.stop.name)
        if d.train, let p = d.platform { return "From \(name) · platform \(p)" }
        return "From \(name)"
    }

    private var status: String {
        if d.cancelled { return "Cancelled" }
        if !d.live { return "Planned time (no live times)" }
        if d.delay >= 1 { return "\(d.delay) min late (planned \(Fmt.hhmm(d.scheduled)))" }
        if d.delay <= -1 { return "\(-d.delay) min early" }
        return "On time"
    }

    private func action(icon: String, title: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(DS.accentText).frame(width: 24)
                Text(title).font(DS.bodyStrong).foregroundStyle(DS.text)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
            }
            .padding(.horizontal, DS.s16).frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
