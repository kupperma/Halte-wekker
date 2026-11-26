import SwiftUI

/// A stop tapped on "Fastest trip, zoomed out" (0.42): its name, your walk and its tag; how sure it gets you there
/// (only what the app can back: your own rides, else "by live times"); its next departures towards where you're going
/// (line, time, live / +delay / timetable, when you're there) or the whole trip of each on one time axis (walk, wait,
/// rides, changes: from concept N4); the vehicles on the line now with their GPS; and Go, which makes the chosen one
/// your trip (`GoStore.chooseDeparture`, as From <stop> does).
struct NearbyDetailSheet: View {
    @EnvironmentObject var go: GoStore
    @ObservedObject var store: NearbyStore
    @ObservedObject var line: NearbyLineModel
    let stopId: String
    let destWord: String
    /// The departure was made your trip: show Fastest trip's own cards.
    let onChosen: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var wholeTrip = false
    @State private var pick: String?            // the chosen departure's trip id (nil: the one there first)
    @State private var going = false
    @State private var failed = false

    private var deps: [DoorTrip] { Array(store.departures(stopId).prefix(8)) }

    /// (0.42.2) The ways overnight or much later (a six-hour wait at a change, there tomorrow morning) apart from the
    /// others: their own group and axis, with their day, never Fastest or Surest.
    private var soon: [DoorTrip] { deps.filter { !store.isLate($0, at: stopId) } }
    private var later: [DoorTrip] { deps.filter { store.isLate($0, at: stopId) } }

    private var chosen: DoorTrip? {
        let d: [DoorTrip] = deps
        if let p = pick, let t = d.first(where: { $0.first.tripId == p }) { return t }
        let s: [DoorTrip] = soon
        return (s.isEmpty ? d : s).min { $0.end < $1.end }
    }

    /// Of the departures that aren't late: the one there first, and the surest (`Nearby.surestOf`: 70% at least, and
    /// surer than that one).
    private var marks: (fastest: String?, surest: String?) {
        let d: [DoorTrip] = soon
        guard let fi = d.indices.min(by: { d[$0].end < d[$1].end }) else { return (nil, nil) }
        let pcts: [Int] = d.map { store.sure($0).percent }
        let si: Int? = Nearby.surestOf(pcts, fastest: fi)
        return (d[fi].first.tripId, si.map { d[$0].first.tripId })
    }

    /// The stop's other departures of the same lines and directions (`/v6/stoptimes`), after the ones listed.
    private var boardRows: [BoardDeparture] {
        let all: [BoardDeparture] = store.boards[stopId] ?? []
        let last: Date = deps.map(\.first.departure).max() ?? .distantPast
        return Array(all.filter { $0.time > last }.prefix(5))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.s12) {
                header
                sureLine
                Picker("Show", selection: $wholeTrip) {
                    Text("Times").tag(false)
                    Text("Whole trip").tag(true)
                }
                .pickerStyle(.segmented)
                if deps.isEmpty {
                    emptyLine
                } else if wholeTrip {
                    timelines
                } else {
                    times
                }
                onTheLine
            }
            .padding(.horizontal, DS.s16).padding(.top, DS.s20).padding(.bottom, DS.s16)
        }
        .safeAreaInset(edge: .bottom) { goButton }
        .background(DS.surface.ignoresSafeArea())
        .task(id: stopId) { await store.more(stopId) }
        .onAppear { follow() }
        .onChange(of: deps.map(\.first.tripId)) { _, _ in follow() }
        .realPositions(true, trains: line.anyTrain)
    }

    private func follow() {
        guard let w = store.way(stopId) else { return }
        line.follow(stopId: stopId, at: w.group.point, rides: deps.map(\.first))
    }

    // MARK: the top

    private var header: some View {
        let w: NearbyStore.Way? = store.way(stopId)
        let walk: Int = w.map { store.walk($0.group).shown.walk } ?? 0
        let tags: [Nearby.Tag] = store.tags[stopId] ?? []
        return HStack(alignment: .firstTextBaseline, spacing: DS.s8) {
            Text(w.map { Fmt.stop($0.group.name) } ?? "").font(DS.title).foregroundStyle(DS.text)
                .lineLimit(2).minimumScaleFactor(0.7).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Image(systemName: "figure.walk").font(.caption.weight(.semibold))
                Text("\(walk) min").font(DS.footnoteStrong)
            }
            .foregroundStyle(DS.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(walk) minutes walk")
            ForEach(tags, id: \.self) { NearbyTagChip(tag: $0) }
        }
    }

    @ViewBuilder private var sureLine: some View {
        if let t = chosen {
            let s: Nearby.Sure = store.sure(t)
            Text("Arrive \(destWord): \(Nearby.sureWords(s))")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// No departure from here (yet): it's being checked, it couldn't be (try again), or there's none in this time.
    @ViewBuilder private var emptyLine: some View {
        let check: NearbyStore.Check = store.way(stopId)?.check ?? .unasked
        HStack(spacing: DS.s8) {
            switch check {
            case .asking, .unasked:
                ProgressView().controlSize(.small)
                Text("Checking this stop…").font(DS.footnote).foregroundStyle(DS.secondary)
            case .failed:
                Text("Couldn’t check this stop just now (the planner is busy or didn’t answer).")
                    .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Try again") { Task { await store.more(stopId) } }
                    .font(DS.footnoteStrong)
            case .done:
                Text("Nothing from here in this time.").font(DS.footnote).foregroundStyle(DS.secondary)
            }
        }
    }

    // MARK: its times

    private var times: some View {
        let m = marks
        let late: [DoorTrip] = later
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(soon) { t in
                Button { pick = t.first.tripId } label: { timeRow(t, fastest: m.fastest == t.first.tripId, surest: m.surest == t.first.tripId) }
                    .buttonStyle(.plain)
            }
            if let first = late.first {
                groupTitle(first)
                ForEach(late) { t in
                    Button { pick = t.first.tripId } label: { timeRow(t, fastest: false, surest: false) }
                        .buttonStyle(.plain)
                }
            }
            let more: [BoardDeparture] = boardRows
            if !more.isEmpty {
                Text("ALSO FROM HERE").font(DS.caption).tracking(0.8).foregroundStyle(DS.secondary)
                    .padding(.top, DS.s12).padding(.bottom, 4).padding(.horizontal, 8)
                    .accessibilityAddTraits(.isHeader)
                ForEach(more) { b in boardRow(b) }
            }
        }
    }

    /// "Tomorrow morning", "Later · Sat": over the ways shown apart.
    private func groupTitle(_ first: DoorTrip) -> some View {
        let t: String = Nearby.laterTitle(firstArrival: first.end, now: Date(), calendar: Calendar.current)
        return Text(t.uppercased()).font(DS.caption).tracking(0.8).foregroundStyle(DS.secondary)
            .padding(.top, DS.s12).padding(.bottom, 4).padding(.horizontal, 8)
            .accessibilityAddTraits(.isHeader)
    }

    /// One of the stop's other departures of the same line: its time and how it's running (when it gets you there is
    /// the planner's to say: tap the stop again later).
    private func boardRow(_ b: BoardDeparture) -> some View {
        let live: String = b.live ? (b.delay > 0 ? "+\(b.delay)" : "live") : "timetable"
        return HStack(spacing: DS.s8) {
            DSLinePill(line: b.train ? Transit.trainLabel(b.line) : b.line, train: b.train)
            Text(Fmt.hhmm(b.time)).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
            Text(live).font(DS.footnoteStrong).foregroundStyle(b.live && b.delay > 0 ? DS.warning : DS.secondary)
            Text(b.headsign).font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(b.train ? "Train" : "Bus") \(b.line) at \(Fmt.hhmm(b.time)) to \(b.headsign), \(live)")
    }

    private func status(_ r: Ride) -> (text: String, color: Color) {
        if r.cancelled { return ("cancelled", DS.warning) }
        if !r.live { return ("timetable", DS.secondary) }
        let d: Int = r.delay
        if d > 0 { return ("+\(d)", DS.warning) }
        if d < 0 { return ("\(d)", DS.warning) }
        return ("live", DS.accentText)
    }

    private func timeRow(_ t: DoorTrip, fastest: Bool, surest: Bool) -> some View {
        let f: Ride = t.first
        let st = status(f)
        let on: Bool = chosen?.id == t.id
        let changes: Int = t.rides.count - 1
        return HStack(spacing: DS.s8) {
            DSLinePill(line: f.isTrain ? Transit.trainLabel(f.line) : f.line, train: f.isTrain)
            Text(Fmt.hhmm(f.departure)).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
            Text(st.text).font(DS.footnoteStrong).foregroundStyle(st.color)
            if changes > 0 {
                Text("· \(changes) change\(changes > 1 ? "s" : "")").font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if fastest { NearbyTagChip(tag: .fastest) } else if surest { NearbyTagChip(tag: .surest) }
            Text("arrive").font(DS.footnote).foregroundStyle(DS.secondary)
            if let d = Nearby.dayWord(t.end, now: Date(), calendar: Calendar.current) {
                Text(d).font(DS.footnote).foregroundStyle(DS.secondary)
            }
            Text(Fmt.hhmm(t.end)).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
        }
        .padding(.vertical, 9).padding(.horizontal, 8)
        .background(on ? AnyShapeStyle(DS.surface2) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1).padding(.horizontal, 8) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(GoStore.what(f)) at \(Fmt.hhmm(f.departure)), \(st.text), there \(Fmt.hhmm(t.end))\(fastest ? ", fastest" : surest ? ", surest" : "")")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: the whole trip (concept N4's timelines)

    private struct Line: Identifiable {
        let trip: DoorTrip
        let legs: [TripTimeline.Leg]
        let parts: [TripTimeline.Part]
        var id: String { trip.id }
    }

    private func lines(_ ts: [DoorTrip]) -> [Line] {
        ts.map { t in
            let legs: [TripTimeline.Leg] = t.rides.map { r in
                TripTimeline.Leg(line: r.isTrain ? Transit.trainLabel(r.line) : r.line, train: r.isTrain, live: r.live,
                                 departure: r.departure, arrival: r.arrival, from: Fmt.stop(r.fromStop), walkBefore: r.walkBefore)
            }
            let parts: [TripTimeline.Part] = TripTimeline.parts(leave: t.start, legs: legs, end: t.end)
            return Line(trip: t, legs: legs, parts: parts)
        }
    }

    /// The ways on a shared axis, the late ones (overnight) on their own so they don't stretch it.
    @ViewBuilder private var timelines: some View {
        let m = marks
        let late: [DoorTrip] = later
        VStack(alignment: .leading, spacing: DS.s8) {
            timelineGroup(lines(soon), marks: m)
            if let first = late.first {
                groupTitle(first)
                timelineGroup(lines(late), marks: (nil, nil))
            }
            Text("Walk, wait, ride, change: leaves → arrives \(destWord), with the minutes of each. Bright = live, faint = timetable. Gold = fastest, green = surest.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func timelineGroup(_ ls: [Line], marks m: (fastest: String?, surest: String?)) -> some View {
        if let axis = TripTimeline.axis(ls.map(\.parts)) {
            let need: Double? = Habits.changeMinutes(HabitStore.shared.book)
            VStack(alignment: .leading, spacing: DS.s8) {
                ticks(axis)
                ForEach(ls) { l in
                    let id: String = l.trip.first.tripId
                    Button { pick = id } label: {
                        NearbyTimelineRow(legs: l.legs, placed: TripTimeline.place(l.parts, on: axis), axis: axis,
                                          leave: l.trip.start, arrive: l.trip.end, changeNeeds: need,
                                          fastest: m.fastest == id, surest: m.surest == id, selected: chosen?.id == l.trip.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func ticks(_ a: TripTimeline.Axis) -> some View {
        GeometryReader { g in
            let w: CGFloat = g.size.width
            let ts: [Date] = a.ticks(width: Double(w))
            ZStack(alignment: .topLeading) {
                ForEach(ts, id: \.self) { d in
                    let x: Double = a.at(d)
                    NearbyAxisText(text: Fmt.hhmm(d), x: x, anchor: TripTimeline.anchor(x), width: w)
                }
            }
        }
        .frame(height: 14)
        .padding(.horizontal, 8)
        .accessibilityHidden(true)
    }

    // MARK: on the line now

    @ViewBuilder private var onTheLine: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Text("ON THE LINE NOW").font(DS.caption).tracking(0.8).foregroundStyle(DS.secondary)
                .accessibilityAddTraits(.isHeader)
            if line.coming.isEmpty {
                Text(deps.isEmpty ? "—" : "Looking for them…").font(DS.footnote).foregroundStyle(DS.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { tl in
                    HStack(alignment: .top, spacing: DS.s8) {
                        ForEach(line.coming) { c in comingCard(c, now: tl.date) }
                    }
                }
            }
        }
        .padding(.top, DS.s4)
    }

    private func comingCard(_ c: NearbyLineModel.Coming, now: Date) -> some View {
        let mins: Int = Int((c.due.timeIntervalSince(now) / 60).rounded(.down))
        let gps: String = c.gpsAge.map { Nearby.gpsAge($0) } ?? (c.live ? "live times" : "timetable")
        let words: String = Nearby.comingWords(minutes: mins, stops: c.stops)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                DSLinePill(line: c.train ? Transit.trainLabel(c.line) : c.line, train: c.train)
                Text(gps).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(words).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.train ? "Train" : "Bus") \(c.line), \(words), \(gps)")
    }

    // MARK: go

    @ViewBuilder private var goButton: some View {
        if let t = chosen, let w = store.way(stopId) {
            let walk: NearbyStore.Walk = store.walk(w.group)
            let leaveAt: Date = t.start.addingTimeInterval(Double(walk.shown.later) * 60)
            VStack(spacing: 6) {
                if failed {
                    Text("Couldn’t make that one your trip just now. Try again in a moment.")
                        .font(DS.footnote).foregroundStyle(DS.warning).fixedSize(horizontal: false, vertical: true)
                }
                TimelineView(.periodic(from: .now, by: 15)) { tl in
                    let m: Int = Int((leaveAt.timeIntervalSince(tl.date) / 60).rounded(.down))
                    let title: String = going ? "Making it your trip…" : m <= 0 ? "Go · leave now" : "Go · leave in \(m) min"
                    DSPrimaryButton(title: title, icon: t.first.isTrain ? "tram.fill" : "bus.fill") { take(t, walk: walk.planned) }
                        .disabled(going)
                        .accessibilityHint("Makes the \(GoStore.what(t.first)) at \(Fmt.hhmm(t.first.departure)) your trip; it watches that one")
                }
            }
            .padding(.horizontal, DS.s16).padding(.top, 8).padding(.bottom, 6)
            .background(DS.surface)
        }
    }

    private func take(_ t: DoorTrip, walk: Int) {
        going = true
        failed = false
        if !go.watching { go.again() }
        let f: Ride = t.first
        Task { @MainActor in
            let ok: Bool = await go.chooseDeparture(tripId: f.tripId, departure: f.departure, stopId: f.fromId, walk: walk)
            going = false
            if ok {
                dismiss()
                onChosen()
            } else {
                failed = true
            }
        }
    }
}

/// A time or a name on the axis: hanging right of its point near the start, left of it near the end, else centred.
struct NearbyAxisText: View {
    let text: String
    let x: Double
    let anchor: TripTimeline.Anchor
    let width: CGFloat
    var font: Font = DS.footnote
    var color: Color = DS.secondary

    var body: some View {
        let px: CGFloat = CGFloat(x) * width
        let align: Alignment = anchor == .leading ? .leading : anchor == .trailing ? .trailing : .center
        let shift: CGFloat = anchor == .leading ? px : anchor == .trailing ? px - width : px - width / 2
        Text(text).font(font).monospacedDigit().foregroundStyle(color).lineLimit(1).fixedSize()
            .frame(width: width, alignment: align)
            .offset(x: shift)
    }
}

/// One departure's whole trip on the shared axis: the times at its ends (both always: `TripTimeline.ends`), the parts
/// (walks and waits thin and quiet, rides in their line's colour, bright when live, each with its minutes when they
/// fit), the minutes of each walk and wait (on the gap, or under the bar with a tick when it's narrow; a tight change
/// yellow, a risky one red: `TripTimeline.gapLabels`), the change stations under it.
struct NearbyTimelineRow: View {
    let legs: [TripTimeline.Leg]
    let placed: [TripTimeline.Placed]
    let axis: TripTimeline.Axis
    let leave: Date
    let arrive: Date
    var changeNeeds: Double? = nil
    let fastest: Bool
    let surest: Bool
    let selected: Bool

    static let tight = Color(hex: 0xE8A33D)
    static let risky = Color(hex: 0xE5484D)

    var body: some View {
        let startX: Double = placed.first?.x ?? 0
        let endX: Double = placed.last.map { $0.x + $0.width } ?? 1
        let changes: [TripTimeline.Label] = TripTimeline.changeLabels(legs, parts: placed, ends: nil)
        let edge: Color = fastest ? NearbyTagChip.gold : surest ? DS.accent : selected ? DS.legQuiet : Color.clear
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ForEach(Array(legs.enumerated()), id: \.offset) { _, l in DSLinePill(line: l.line, train: l.train) }
                Spacer(minLength: 4)
                if fastest { NearbyTagChip(tag: .fastest) } else if surest { NearbyTagChip(tag: .surest) }
            }
            GeometryReader { g in
                let w: CGFloat = g.size.width
                let e: TripTimeline.Ends = TripTimeline.ends(start: startX, end: endX, width: Double(w))
                ZStack(alignment: .topLeading) {
                    NearbyAxisText(text: Fmt.hhmm(leave), x: e.leave, anchor: .leading, width: w, font: DS.footnoteStrong, color: DS.text)
                    NearbyAxisText(text: Fmt.hhmm(arrive), x: e.arrive, anchor: .leading, width: w, font: DS.footnoteStrong, color: DS.text)
                }
            }
            .frame(height: 16)
            GeometryReader { g in
                let w: CGFloat = g.size.width
                let gaps: [TripTimeline.GapLabel] = TripTimeline.gapLabels(placed, width: Double(w), changeNeeds: changeNeeds)
                let rides: [TripTimeline.RideLabel] = TripTimeline.rideLabels(placed, width: Double(w))
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.surface3.opacity(0.6)).frame(height: 18)
                    ForEach(Array(placed.enumerated()), id: \.offset) { _, p in
                        piece(p, width: w).frame(height: 18)
                    }
                    ForEach(Array(rides.enumerated()), id: \.offset) { _, r in
                        rideText(r, width: w)
                    }
                    ForEach(Array(gaps.enumerated()), id: \.offset) { _, l in
                        gapText(l, width: w)
                    }
                }
            }
            .frame(height: barHeight)
            if !changes.isEmpty {
                GeometryReader { g in
                    let w: CGFloat = g.size.width
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, l in
                            NearbyAxisText(text: l.text, x: l.x, anchor: l.anchor, width: w, font: DS.caption)
                        }
                    }
                }
                .frame(height: 14)
            }
        }
        .padding(8)
        .background(selected ? AnyShapeStyle(DS.surface2) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(edge, lineWidth: 2))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The bar, and room under it for the minutes that don't fit on their gap (two rows at most).
    private var barHeight: CGFloat { 18 + 2 * Self.underRow + 2 }
    private static let underRow: CGFloat = 13

    private var spoken: String {
        let rides: String = legs.map { "\($0.train ? "train" : "bus") \($0.line) at \(Fmt.hhmm($0.departure))" }.joined(separator: ", then ")
        let tag: String = fastest ? ", fastest" : surest ? ", surest" : ""
        return "Leave \(Fmt.hhmm(leave)), \(rides), there \(Fmt.hhmm(arrive))\(tag)"
    }

    private func tone(_ t: TripTimeline.Tone) -> Color {
        switch t {
        case .plain: return DS.secondary
        case .tight: return Self.tight
        case .risky: return Self.risky
        }
    }

    /// A gap's minutes: on the gap, or under the bar with a tick up to it.
    @ViewBuilder private func gapText(_ l: TripTimeline.GapLabel, width w: CGFloat) -> some View {
        let c: Color = tone(l.tone)
        let font: Font = .system(size: 10, weight: l.tone == .plain ? .semibold : .bold, design: .rounded)
        if l.below {
            let y: CGFloat = 20 + CGFloat(l.lane) * Self.underRow
            Rectangle().fill(c.opacity(0.7)).frame(width: 1, height: y - 15)
                .offset(x: CGFloat(l.x) * w, y: 16)
            NearbyAxisText(text: l.text, x: l.x, anchor: .center, width: w, font: font, color: c)
                .offset(y: y)
        } else {
            NearbyAxisText(text: l.text, x: l.x, anchor: .center, width: w, font: font, color: c)
                .offset(y: 3)
        }
    }

    /// A ride's minutes inside its bar.
    private func rideText(_ r: TripTimeline.RideLabel, width w: CGFloat) -> some View {
        let p: TripTimeline.Placed = placed[r.index]
        let centre: Double = p.x + p.width / 2
        return NearbyAxisText(text: r.text, x: centre, anchor: .center, width: w,
                              font: .system(size: 10, weight: .bold, design: .rounded), color: Color.white.opacity(p.part.live ? 0.95 : 0.85))
            .offset(y: 3)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func piece(_ p: TripTimeline.Placed, width w: CGFloat) -> some View {
        let x: CGFloat = CGFloat(p.x) * w
        let pw: CGFloat = max(2, CGFloat(p.width) * w)
        switch p.part.kind {
        case .ride:
            let c: Color = DS.mode(train: p.part.train, line: p.part.line)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(c.opacity(p.part.live ? 1 : 0.45))
                .frame(width: pw, height: 14)
                .offset(x: x)
        case .walk:
            Capsule()
                .stroke(DS.legQuiet, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 4]))
                .frame(width: pw, height: 2)
                .offset(x: x)
        case .wait:
            Capsule()
                .fill(DS.legQuiet.opacity(0.5))
                .frame(width: pw, height: 3)
                .offset(x: x)
        }
    }
}
