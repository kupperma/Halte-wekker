import SwiftUI

// "From <stop>" (0.40): the next departures from the stop you get on at, in Fastest trip and in the home's next-trip
// card (`FromStop` has the rules). The departures are Transitous's stop times, the same boards the home's cards use.

/// The departures from one stop, every 30 s while they're on screen. A failed answer keeps the last good list.
@MainActor
final class FromStopModel: ObservableObject {
    @Published private(set) var deps: [BoardDeparture] = []
    @Published private(set) var loaded = false
    private var stopId = ""
    private var at: Date?

    func load(stopId id: String) async {
        guard !id.isEmpty else { return }
        if id != stopId { stopId = id; deps = []; loaded = false; at = nil }
        if let a = at, Date().timeIntervalSince(a) < 25 { return }
        let from: Date = Date().addingTimeInterval(-60)
        let b: [BoardDeparture] = await Transit.$urgent.withValue(true) { () async -> [BoardDeparture] in
            await Transit.board(stopIds: [id], from: from, n: 20)
        }
        guard id == stopId else { return }
        at = Date()
        if !b.isEmpty || deps.isEmpty { deps = b }
        loaded = true
    }

    /// The rows to show (`FromStop.board`), with the lines seen live today and the vehicles seen (their GPS).
    func board(usefulLines: Set<String>, current: String?, atStop: Date, now: Date) -> FromStop.Board {
        let alsoLive: Set<String> = Set(LiveDelays.shared.seen.values.map(\.line))
        let positions = RealPositionsStore.shared
        let list: [FromStop.Dep] = deps.map { d in
            let seen: Bool = positions.fix(for: d.tripId, now: now) != nil
            let stop: String = d.stopName.isEmpty ? d.stopId : d.stopName
            return FromStop.Dep(id: d.id, tripId: d.tripId, line: d.line, headsign: d.headsign, time: d.time, scheduled: d.scheduled,
                                live: d.live, cancelled: d.cancelled, platform: d.platform, train: d.train, stop: stop, vehicle: seen)
        }
        return FromStop.board(list, usefulLines: usefulLines, current: current, atStop: atStop, now: now, alsoLive: alsoLive)
    }
}

extension WalkPlan {
    /// Your walk to a ride's stop (`shown`), at your speed once learned (read from `HabitStore`; the planner's speed is
    /// yours there once it's learned, else its own).
    @MainActor static func mine(_ r: Ride, metres: Double? = nil) -> Shown {
        let b: HabitBook = HabitStore.shared.book
        let used: Double = HabitStore.pedestrianSpeed() ?? Habits.plannerWalk
        return shown(planned: r.walkBefore, metres: metres, speed: Habits.walkSpeed(b), walks: b.walks.count, plannerSpeed: used)
    }
}

/// The card: "From Bolkenplein", the next buses that get you there (tap one to take it), then the other lines.
struct FromStopCard: View {
    let ride: Ride                      // your trip's first ride (where you get on)
    let usefulLines: Set<String>        // the lines that get you there from here
    /// In the home's card: no card of its own, and only the lines that get you there.
    var inline = false
    /// From the saved answer: shown, but not to switch to yet.
    var saved = false
    let pick: (FromStop.Row) -> Void
    @StateObject private var model = FromStopModel()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { tl in
            content(tl.date)
        }
        .task(id: ride.fromId) {
            while !Task.isCancelled {
                await model.load(stopId: ride.fromId)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private var stopName: String { ride.isTrain ? Fmt.place(ride.fromStop) : Fmt.stop(ride.fromStop) }
    private var kinds: String { ride.isTrain ? "trains" : "buses" }

    /// When you can be at the stop: now plus the walk there.
    private func atStop(_ now: Date) -> Date { now.addingTimeInterval(Double(max(0, ride.walkBefore)) * 60) }

    @ViewBuilder private func content(_ now: Date) -> some View {
        let b: FromStop.Board = model.board(usefulLines: usefulLines, current: ride.tripId, atStop: atStop(now), now: now)
        let inner: AnyView = AnyView(list(b, now: now))
        if inline {
            inner
        } else {
            inner.frame(maxWidth: .infinity, alignment: .leading).dsCard()
        }
    }

    private func list(_ b: FromStop.Board, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.loaded && b.isEmpty {
                VStack(spacing: DS.s8) { DSSkeletonRow(); DSSkeletonRow() }.padding(.top, DS.s8)
            } else if b.useful.isEmpty {
                Text("No other \(kinds) that get you there leave here soon.").font(DS.sub).foregroundStyle(DS.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.s8)
            }
            ForEach(b.useful) { r in usefulRow(r, now: now) }
            if !inline && !b.other.isEmpty {
                Text("Other lines").font(DS.footnoteStrong).foregroundStyle(DS.secondary)
                    .padding(.top, DS.s12).padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(b.other) { r in otherRow(r, now: now) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("From \(stopName)").font(DS.headline).foregroundStyle(DS.text).lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Text(saved ? "The next \(kinds) that get you there" : "The next \(kinds) that get you there · tap one to take it")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, DS.s4)
    }

    private func label(_ d: FromStop.Dep) -> String { d.train ? Transit.trainLabel(d.line) : d.line }

    /// How it runs: "+3" (late), "live", "timetable", or "may not run".
    private func status(_ r: FromStop.Row) -> (text: String, color: Color) {
        if r.status == .unsure { return (GhostDepartures.unsureShort, DS.warning) }
        if let l = r.late {
            let warn: Bool = l.hasPrefix("+")
            return (l, warn ? DS.warning : DS.accentText)
        }
        return ("timetable", DS.secondary)
    }

    private func usefulRow(_ r: FromStop.Row, now: Date) -> some View {
        let tappable: Bool = r.switchable && !saved
        return Button { if tappable { pick(r) } } label: {
            rowBody(r, now: now, big: true)
        }
        .buttonStyle(.plain)
        .disabled(!tappable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(r, now: now))
        .accessibilityHint(tappable ? "Takes this one: the rest of the trip is planned from it" : "")
    }

    private func otherRow(_ r: FromStop.Row, now: Date) -> some View {
        rowBody(r, now: now, big: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(r, now: now))
    }

    private func rowBody(_ r: FromStop.Row, now: Date, big: Bool) -> some View {
        let d: FromStop.Dep = r.dep
        let st = status(r)
        let place: String? = FromStop.place(d)
        let when: String? = FromStop.countdown(d, now: now)
        return HStack(alignment: .center, spacing: DS.s8) {
            DSLinePill(line: label(d), train: d.train).frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.place(d.headsign)).font(big ? DS.calloutStrong : DS.footnote).foregroundStyle(DS.text).lineLimit(1)
                if r.current || place != nil {
                    HStack(spacing: 6) {
                        if r.current {
                            Text("Your trip").font(DS.footnoteStrong).foregroundStyle(DS.accentSoftText)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(DS.accentSoft, in: Capsule())
                        }
                        if let place { Text(place).font(DS.footnote).foregroundStyle(DS.secondary) }
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.hhmm(d.time)).font(big ? DS.calloutStrong : DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.text)
                HStack(spacing: 4) {
                    if big, let when { Text(when).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary) }
                    Text(st.text).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(st.color)
                }
            }
            if big && r.switchable && !saved {
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(DS.secondary)
            }
        }
        .frame(minHeight: big ? 48 : 36)
        .contentShape(Rectangle())
        .opacity(r.dimmed ? 0.45 : 1)
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
    }

    private func spoken(_ r: FromStop.Row, now: Date) -> String {
        let d: FromStop.Dep = r.dep
        var parts: [String] = ["\(d.train ? "Train" : "Line") \(label(d)) to \(Fmt.place(d.headsign)) at \(Fmt.hhmm(d.time))"]
        if let p = FromStop.place(d) { parts.append(p) }
        parts.append(status(r).text)
        if r.current { parts.append("your trip") }
        if r.dimmed { parts.append("you can’t be there in time") }
        return parts.joined(separator: ", ")
    }
}

/// In the home's next-trip card: "Buses from Bolkenplein" folded away; open, the next ones that get you there.
struct FromStopDisclosure: View {
    let ride: Ride
    let usefulLines: Set<String>
    let pick: (FromStop.Row) -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Button { withAnimation(DS.quick) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: ride.isTrain ? "tram.fill" : "bus.fill").font(.footnote.weight(.semibold))
                    Text("\(ride.isTrain ? "Trains" : "Buses") from \(ride.isTrain ? Fmt.place(ride.fromStop) : Fmt.stop(ride.fromStop))")
                        .font(DS.subStrong).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption.weight(.bold))
                }
                .foregroundStyle(DS.accentText)
                .frame(minHeight: DS.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the next departures" : "Shows the next departures from this stop")
            if open {
                FromStopCard(ride: ride, usefulLines: usefulLines, inline: true, pick: pick)
                    .transition(.opacity)
            }
        }
    }
}
