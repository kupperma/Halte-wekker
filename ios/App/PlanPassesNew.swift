import SwiftUI

// Plan › More ways › Be there by and Friend's train, when one is planned (0.21): the planned trips in the new look. The
// same as `PlannedTripsSheet`, `ArrivePass` and `PlannedPass` (the old look keeps those, as boarding passes), over the
// same `Planner`, in the phone's light or dark. Changing a plan opens `PlanSheet`, starting the alarm `StartSheet`,
// both in the new look.

/// Your Be there by plan and your friend's train: view, change, remove, start.
struct PlannedTripsSheetNew: View {
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
                VStack(alignment: .leading, spacing: DS.s16) {
                    if planner.arrive != nil {
                        ArrivePassNew(edit: { editing = true }, go: {
                            dismiss()
                            HomeActions.openPlanGo(school: false, trip: trip, planner: planner, goStore: goStore, near: near)
                        }, wake: { t in
                            if let a = planner.arrive { trip.pick(a.out ? .toSchool : .home) }
                            if let via = t.via, let r = RoutePlan.all.first(where: { $0.station.short == via }) { startReq = StartRequest(route: r) }
                            else if let r = RoutePlan.from(t) { trip.start(r); dismiss() }
                        })
                    } else {
                        DSQuietButton(title: "Be there by, or leave at…", icon: "flag.checkered", full: true) { editing = true }
                    }
                    if planner.trip != nil {
                        PlannedPassNew(edit: { editing = false }, wake: { r in
                            if let t = planner.trip { trip.pick(t.out ? .toSchool : .home) }
                            startReq = StartRequest(route: r)
                        })
                    } else {
                        DSQuietButton(title: "Plan by your friend’s train", icon: "tram.fill", full: true) { editing = false }
                    }
                }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Planned trips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sheet(item: $startReq) { StartSheet(req: $0, newLook: true).presentationDetents([.medium, .large]) }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) { PlanSheet(byArrival: editing ?? true, newLook: true) }
    }
}

/// A row of choices that scrolls sideways (the other trains, the earlier ways): only as tall as itself.
private struct PlanChoices<Item, Choice: View>: View {
    let items: [Item]
    let picked: Int
    let pick: (Int) -> Void
    @ViewBuilder let label: (Int, Item) -> Choice
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.s8) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, x in
                    Button { pick(i) } label: {
                        label(i, x)
                            .foregroundStyle(i == picked ? DS.onAccent : DS.text)
                            .padding(.horizontal, DS.s12).padding(.vertical, 6)
                            .frame(minHeight: DS.hit)
                            .background(i == picked ? DS.accent : DS.surface3, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                    }
                    .buttonStyle(DSPressStyle())
                    .accessibilityAddTraits(i == picked ? .isSelected : [])
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Be there by a time: when to leave, how much time you have to spare, the trip as a line, the other ways that also
/// get you there in time (leaving earlier), and hands-free or the alarm for it.
struct ArrivePassNew: View {
    @EnvironmentObject var planner: Planner
    let edit: () -> Void
    var go: () -> Void = {}
    let wake: (DoorTrip) -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var big: CGFloat = 34

    var body: some View {
        if let a = planner.arrive {
            let w = RoleWords.current, dest = a.out ? w.school : w.homeName
            VStack(alignment: .leading, spacing: DS.s12) {
                HStack(alignment: .top, spacing: DS.s8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(a.leaving ? "Leave at" : "Be there by") · \(a.dayLabel)").font(DS.footnoteStrong).foregroundStyle(DS.accentText)
                        Text(a.leaving ? "\(a.out ? "To \(w.school)" : "Home") · leave \(a.time)" : "\(dest) by \(a.time)")
                            .font(DS.title).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    changeButton(edit)
                }
                if let t = planner.arriveChosen, let T = a.when {
                    let spare = Fmt.mins(T.timeIntervalSince(t.end))
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.leaving ? "Leave at" : "Leave by").font(DS.footnote).foregroundStyle(DS.secondary)
                            Text(Fmt.hhmm(t.start)).font(DS.hero(min(big, 56))).monospacedDigit().foregroundStyle(DS.text)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("There at").font(DS.footnote).foregroundStyle(DS.secondary)
                            Text(Fmt.hhmm(t.end)).font(DS.bigNumber).monospacedDigit().foregroundStyle(DS.text)
                            if a.leaving {
                                Text(Fmt.rideText(t.end.timeIntervalSince(t.start) / 60)).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.secondary)
                            } else {
                                Text(spare == 0 ? "just in time" : "\(spare) min to spare").font(DS.footnoteStrong).monospacedDigit()
                                    .foregroundStyle(spare < 3 ? DS.warning : DS.accentText)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if planner.arriveOptions.count > 1 {
                        // the best one first; the others leave earlier (more time to spare)
                        PlanChoices(items: planner.arriveOptions, picked: planner.arrivePick,
                                    pick: { i in withAnimation(DS.quick) { planner.arrivePick = i } }) { i, o in
                            VStack(spacing: 0) {
                                Text(Fmt.hhmm(o.first.departure)).font(DS.subStrong).monospacedDigit()
                                Text(i == 0 ? "best" : a.leaving ? "there \(Fmt.hhmm(o.end))" : "\(Fmt.mins(T.timeIntervalSince(o.end))) spare")
                                    .font(DS.footnote).monospacedDigit().opacity(0.9)
                            }
                        }
                    }
                    Divider().overlay(DS.divider)
                    TripLine(trip: t, others: planner.arriveOptions.filter { $0.id != t.id }, dest: dest, newLook: true)
                    VStack(spacing: DS.s8) {
                        DSPrimaryButton(title: "Go hands-free", icon: "bolt.fill", action: go)
                        DSQuietButton(title: "Wake me on this trip now", icon: "bell.and.waves.left.and.right", full: true) { wake(t) }
                    }
                    Text("Hands-free shows the walk and the bus, tells you if it changes, and starts the ride by itself once you’re on. It also opens by itself when you open the app around the time to leave.")
                        .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(a.leaving ? "Gets you there the soonest when you head off at \(a.time), with changes you’ll make. A reminder comes ten minutes before you have to leave."
                                   : "Leaves the latest and still gets you there in time. A reminder comes ten minutes before you have to leave.")
                        .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let e = planner.arriveError {
                    DSNote(icon: "exclamationmark.triangle.fill", text: e)
                } else {
                    HStack(spacing: DS.s8) { ProgressView(); Text("Finding the best trip…").font(DS.sub).foregroundStyle(DS.secondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
        }
    }
}

/// "Change", on a planned trip's card.
private func changeButton(_ edit: @escaping () -> Void) -> some View {
    Button(action: edit) {
        Text("Change").font(DS.subStrong).foregroundStyle(DS.accentText)
            .padding(.horizontal, DS.s12).frame(minHeight: DS.hit)
            .background(DS.surface3, in: Capsule())
            .contentShape(Capsule())
    }
    .buttonStyle(DSPressStyle())
}

/// Your planned trip with your friend: the bus, the train, the bus, each with its time, its line and how it's running.
struct PlannedPassNew: View {
    @EnvironmentObject var planner: Planner
    @EnvironmentObject var ns: NSStore
    @EnvironmentObject var watch: WatchStore
    let edit: () -> Void
    let wake: (RoutePlan) -> Void

    var body: some View {
        if let t = planner.trip {
            VStack(alignment: .leading, spacing: DS.s12) {
                VStack(alignment: .leading, spacing: DS.s12) {
                    HStack(alignment: .top, spacing: DS.s8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Friend’s train · \(t.dayLabel)").font(DS.footnoteStrong).foregroundStyle(DS.accentText)
                            Text("\(t.out ? "Arrive Breda" : "Leave Breda") \(t.time)").font(DS.title).monospacedDigit().foregroundStyle(DS.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 4)
                        changeButton(edit)
                    }
                    if let op = planner.chosen {
                        content(op, t)
                    } else {
                        Text(planner.error ?? "Finding your train and buses…").font(DS.sub).foregroundStyle(DS.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsCard()
                if let op = planner.chosen, let r = RoutePlan.via(op.station) {
                    DSPrimaryButton(title: "Wake me on this trip", icon: "bell.and.waves.left.and.right") { wake(r) }
                }
                if let u = planner.updated {
                    let watched = planner.chosen.map { watch.isWatched($0.train.first, from: $0.from) } ?? false
                    Text("Updated at \(Fmt.hhmm(u)).\((t.when?.timeIntervalSinceNow ?? 0) > 4 * 3600 ? " Live delays show up a few hours before." : "")\(watched ? " You get an alarm if this train changes platform or is cancelled." : "")")
                        .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DS.s4)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ op: PlanOption, _ t: PlannedTrip) -> some View {
        let info = ns.rail(op.train.first)
        let built = PlannedPass.build(op, out: t.out, info: info, extra: AnyView(TrainSizeRow(info: info)))
        if !built.right.isEmpty {
            Text(built.right).font(DS.subStrong).monospacedDigit().foregroundStyle(DS.secondary)
        }
        if planner.options.count > 1 {
            PlanChoices(items: planner.options, picked: planner.pick, pick: { planner.pick = $0 }) { _, x in
                Text("\(x.train.first.name.isEmpty ? "Train" : x.train.first.name) \(t.out ? "from \(x.from.short)" : "to \(x.to.short)")")
                    .font(DS.subStrong).lineLimit(1)
            }
        }
        if planner.inexact {
            DSNote(icon: "exclamationmark.triangle.fill", text: "No train \(t.out ? "arrives in" : "leaves") Breda at exactly \(t.time). This is the closest one.")
        }
        // the stops along it, with their times
        Text(built.stops.filter { !$0.time.isEmpty }.map { "\($0.name) \($0.time)" }.joined(separator: " → "))
            .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(built.legs.enumerated()), id: \.element.id) { i, l in
                if i > 0 { Divider().overlay(DS.divider).padding(.vertical, DS.s8) }
                LegRow(leg: l)
            }
        }
        let notes = [op.busInAlt.map { "Earlier bus: \($0.first.line) at \(Fmt.hhmm($0.first.departure))" },
                     op.busOutAlt.map { "Next one: \($0.first.line) at \(Fmt.hhmm($0.first.departure))" }].compactMap { $0 }
        VStack(alignment: .leading, spacing: 4) {
            Text(notes.isEmpty ? "Valid for this trip only" : notes.joined(separator: " · "))
                .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            if watch.isWatched(op.train.first, from: op.from) {
                Label("Watching \(op.train.first.line)", systemImage: "bell.fill").font(DS.footnoteStrong).foregroundStyle(DS.accentText)
            }
        }
    }

    /// One ride: its time, its line, where it goes and how it's running, and its speed rank.
    private struct LegRow: View {
        let leg: PassLeg
        /// "BUS 306" → a bus pill "306"; "IC" → a train pill.
        private var pill: (line: String, train: Bool) {
            let b = leg.badge
            if b.uppercased().hasPrefix("BUS") {
                let l = b.dropFirst(3).trimmingCharacters(in: .whitespaces)
                return (l.isEmpty ? "Bus" : l, false)
            }
            return (b, true)
        }
        var body: some View {
            HStack(alignment: .top, spacing: DS.s12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: DS.s8) {
                        Text(leg.time).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                        DSLinePill(line: pill.line, train: pill.train)
                        if leg.tag != nil {
                            Text("Friend’s").font(DS.footnoteStrong).foregroundStyle(DS.accentSoftText)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(DS.accentSoft, in: Capsule())
                        }
                    }
                    Text(leg.to).font(DS.calloutStrong).foregroundStyle(DS.text).strikethrough(leg.gone)
                        .fixedSize(horizontal: false, vertical: true)
                    if leg.gone { Text("Cancelled").font(DS.footnoteStrong).foregroundStyle(DS.warning) }
                    ForEach(leg.lines.compactMap { $0 }) { p in
                        Text(p.text).font(DS.footnote).monospacedDigit().foregroundStyle(p.warn ? DS.warning : DS.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let x = leg.extra { x }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                DSGrade(grade: leg.grade, size: 30)
            }
        }
    }

    /// How long the train is and where 1st class stops, under the train's row.
    private struct TrainSizeRow: View {
        let info: RailInfo?
        var body: some View {
            if let s = info?.size {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.text).font(DS.footnote).monospacedDigit().foregroundStyle(s.warn ? DS.warning : DS.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let l = s.layout { ConsistView(layout: l, pal: .toBreda, newLook: true) }
                }
                .padding(.top, 2)
            }
        }
    }
}
