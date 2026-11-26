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

    private var deps: [DoorTrip] { Array(store.departures(stopId).prefix(6)) }

    private var chosen: DoorTrip? {
        let d: [DoorTrip] = deps
        if let p = pick, let t = d.first(where: { $0.first.tripId == p }) { return t }
        return d.min { $0.end < $1.end }
    }

    /// Of these departures: the one there first, and the surest (when it's surer than that one).
    private var marks: (fastest: String?, surest: String?) {
        let d: [DoorTrip] = deps
        guard let f = d.min(by: { $0.end < $1.end }) else { return (nil, nil) }
        let fp: Int = store.sure(f).percent
        let top: DoorTrip? = d.max { a, b in
            let pa: Int = store.sure(a).percent, pb: Int = store.sure(b).percent
            return pa != pb ? pa < pb : a.end > b.end
        }
        let s: String? = top.flatMap { store.sure($0).percent > fp ? $0.first.tripId : nil }
        return (f.first.tripId, s)
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
                    HStack(spacing: DS.s8) {
                        if store.busy { ProgressView().controlSize(.small) }
                        Text(store.busy ? "Getting its times…" : "Nothing from here in this time.")
                            .font(DS.footnote).foregroundStyle(DS.secondary)
                    }
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

    // MARK: its times

    private var times: some View {
        let m = marks
        return VStack(spacing: 0) {
            ForEach(deps) { t in
                Button { pick = t.first.tripId } label: { timeRow(t, fastest: m.fastest == t.first.tripId, surest: m.surest == t.first.tripId) }
                    .buttonStyle(.plain)
            }
        }
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

    private func lines() -> [Line] {
        deps.map { t in
            let legs: [TripTimeline.Leg] = t.rides.map { r in
                TripTimeline.Leg(line: r.isTrain ? Transit.trainLabel(r.line) : r.line, train: r.isTrain, live: r.live,
                                 departure: r.departure, arrival: r.arrival, from: Fmt.stop(r.fromStop), walkBefore: r.walkBefore)
            }
            let parts: [TripTimeline.Part] = TripTimeline.parts(leave: t.start, legs: legs, end: t.end)
            return Line(trip: t, legs: legs, parts: parts)
        }
    }

    @ViewBuilder private var timelines: some View {
        let ls: [Line] = lines()
        if let axis = TripTimeline.axis(ls.map(\.parts)) {
            let m = marks
            VStack(alignment: .leading, spacing: DS.s8) {
                ticks(axis)
                ForEach(ls) { l in
                    let id: String = l.trip.first.tripId
                    Button { pick = id } label: {
                        NearbyTimelineRow(legs: l.legs, placed: TripTimeline.place(l.parts, on: axis), axis: axis,
                                          leave: l.trip.start, arrive: l.trip.end,
                                          fastest: m.fastest == id, surest: m.surest == id, selected: chosen?.id == l.trip.id)
                    }
                    .buttonStyle(.plain)
                }
                Text("Walk, wait, ride, change: leaves → arrives \(destWord). Bright = live, faint = timetable. Gold = fastest, green = surest.")
                    .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ticks(_ a: TripTimeline.Axis) -> some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(a.ticks, id: \.self) { d in
                    let x: Double = a.at(d)
                    NearbyAxisText(text: Fmt.hhmm(d), x: x, anchor: TripTimeline.anchor(x), width: g.size.width)
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

/// One departure's whole trip on the shared axis: the times at its ends, the parts (walks and waits thin and quiet,
/// rides in their line's colour, bright when live), the change stations under it.
struct NearbyTimelineRow: View {
    let legs: [TripTimeline.Leg]
    let placed: [TripTimeline.Placed]
    let axis: TripTimeline.Axis
    let leave: Date
    let arrive: Date
    let fastest: Bool
    let surest: Bool
    let selected: Bool

    var body: some View {
        let startX: Double = placed.first?.x ?? 0
        let endX: Double = placed.last.map { $0.x + $0.width } ?? 1
        let ends = TripTimeline.endLabels(start: startX, end: endX)
        let changes: [TripTimeline.Label] = TripTimeline.changeLabels(legs, parts: placed, ends: (startX, endX))
        let edge: Color = fastest ? NearbyTagChip.gold : surest ? DS.accent : selected ? DS.legQuiet : Color.clear
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ForEach(Array(legs.enumerated()), id: \.offset) { _, l in DSLinePill(line: l.line, train: l.train) }
                Spacer(minLength: 4)
                if fastest { NearbyTagChip(tag: .fastest) } else if surest { NearbyTagChip(tag: .surest) }
            }
            GeometryReader { g in
                let w: CGFloat = g.size.width
                ZStack(alignment: .topLeading) {
                    if ends.leave {
                        NearbyAxisText(text: Fmt.hhmm(leave), x: startX, anchor: .leading, width: w, font: DS.footnoteStrong, color: DS.text)
                    }
                    if ends.arrive {
                        NearbyAxisText(text: Fmt.hhmm(arrive), x: endX, anchor: .trailing, width: w, font: DS.footnoteStrong, color: DS.text)
                    }
                }
            }
            .frame(height: 16)
            GeometryReader { g in
                let w: CGFloat = g.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.surface3.opacity(0.6))
                    ForEach(Array(placed.enumerated()), id: \.offset) { _, p in
                        piece(p, width: w)
                    }
                }
            }
            .frame(height: 18)
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

    private var spoken: String {
        let rides: String = legs.map { "\($0.train ? "train" : "bus") \($0.line) at \(Fmt.hhmm($0.departure))" }.joined(separator: ", then ")
        let tag: String = fastest ? ", fastest" : surest ? ", surest" : ""
        return "Leave \(Fmt.hhmm(leave)), \(rides), there \(Fmt.hhmm(arrive))\(tag)"
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
