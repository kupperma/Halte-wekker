import SwiftUI

// The "Next trip first" home (0.19.1, concept B, artboards B1–B3): the same home as "Live around you" (`NewHome`: its
// map, stores, refreshes, Plan and Your day), laid out around one big card with your next trip, and a bar at the
// bottom with Home, School, Plan and Your week. These are its parts; `NewHome` puts them together.

extension NextTrip {
    /// A trip's parts for the leg bar.
    static func legs(of t: DoorTrip) -> [Leg] {
        legs(start: t.start, end: t.end, rides: t.rides.map {
            RideSpan(departure: $0.departure, arrival: $0.arrival, line: $0.isTrain ? Transit.trainLabel($0.line) : $0.line, train: $0.isTrain)
        })
    }
}

/// The trip as one bar: the walks and waits quiet, each ride in its line's colour, as long as it takes.
struct DSLegBar: View {
    let legs: [NextTrip.Leg]
    var body: some View {
        let f = NextTrip.fractions(legs)
        GeometryReader { g in
            let room = max(0, g.size.width - CGFloat(max(0, legs.count - 1)) * 3)
            HStack(spacing: 3) {
                ForEach(Array(legs.enumerated()), id: \.offset) { k, l in
                    Capsule()
                        .fill(l.kind == .ride ? DS.mode(train: l.train) : DS.legQuiet)
                        .frame(width: max(2, room * CGFloat(f[safe: k] ?? 0)))
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NextTrip.spoken(legs))
    }
}

/// The big card: how long until you leave, the first ride and when you're there, the leg bar and Start (the hands-free
/// Fastest trip, as Go). Or, with nothing to show, a calm "No trip planned" and Plan.
struct NextTripCard: View {
    struct Shown {
        let title: String           // "Home · next trip", "For your 09:00 class"
        let leave: Date
        let trip: DoorTrip
        let destName: String        // "Home", "BUas"
        let asOf: Date?             // a saved answer: "as of 08:12"
        var startTitle: String? = nil   // nil: "Start · wake me before <stop>"
    }
    enum Content {
        case loading
        case empty(note: String?)
        case trip(Shown)
    }

    let content: Content
    /// The countdown's clock (the same date the trip was picked with).
    let now: Date
    let start: () -> Void
    let otherTimes: () -> Void
    let plan: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var big: CGFloat = 52

    var body: some View {
        Group {
            switch content {
            case .loading: loading
            case .empty(let note): empty(note)
            case .trip(let s): shown(s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Finding your next trip…").font(DS.headline).foregroundStyle(DS.text)
            DSSkeletonRow(); DSSkeletonRow()
        }
        .accessibilityElement(children: .combine)
    }

    private func empty(_ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No trip planned").font(DS.title).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
            Text(note ?? "Plan one, or tap a place below to see the way there.")
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: plan) {
                Label("Plan a trip", systemImage: "magnifyingglass").font(DS.bodyStrong).foregroundStyle(DS.accentSoftText)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(DS.accentSoft, in: Capsule())
            }
            .buttonStyle(DSPressStyle())
        }
    }

    private func shown(_ s: Shown) -> some View {
        let first = s.trip.first
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(s.title).font(DS.subStrong).foregroundStyle(DS.secondary).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: otherTimes) {
                    Text("Other times").font(DS.subStrong).foregroundStyle(DS.accentText)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Plan a trip to \(s.destName), with the other ways there")
            }
            let c = NextTrip.countdown(leave: s.leave, now: now)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(c.value).font(DS.hero(min(big, 72))).monospacedDigit().foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(c.unit).font(DS.body).foregroundStyle(DS.secondary).lineLimit(2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(c.spoken)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DSLinePill(line: first.isTrain ? Transit.trainLabel(first.line) : first.line, train: first.isTrain)
                (Text("\(Fmt.hhmm(first.departure)) from \(Fmt.place(first.fromStop))").font(DS.calloutStrong).foregroundStyle(DS.text)
                 + Text("  · \(s.destName) \(Fmt.hhmm(s.trip.end))").font(DS.callout).foregroundStyle(DS.secondary))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(first.isTrain ? "Train" : "Bus") \(first.line) at \(Fmt.hhmm(first.departure)) from \(Fmt.place(first.fromStop)), at \(s.destName) at \(Fmt.hhmm(s.trip.end))")
            if let a = s.asOf {
                Text(Snapshots.asOf(a)).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
            }
            DSLegBar(legs: NextTrip.legs(of: s.trip))
            DSPrimaryButton(title: s.startTitle ?? "Start · wake me before \(Fmt.place(s.trip.last.toStop))", icon: "play.fill", lines: 2, action: start)
                .accessibilityHint("Opens the hands-free trip")
        }
    }
}

/// The bar at the bottom: Home and School (Plan to there), Plan, and Your week.
struct NextTripBar: View {
    let home: SavedPlace?
    let school: SavedPlace?
    let weekOpen: Bool
    let openPlace: (SavedPlace) -> Void
    let plan: () -> Void
    let week: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if let h = home {
                item(h.name, icon: h.symbol, label: "Plan a trip to \(h.name)") { openPlace(h) }
            }
            if let s = school {
                item(s.name, icon: s.symbol, label: "Plan a trip to \(s.name)") { openPlace(s) }
            }
            item("Plan", icon: "point.topleft.down.to.point.bottomright.curvepath", label: "Plan a trip", action: plan)
            item("Week", icon: "calendar", label: "Your week", selected: weekOpen, action: week)
        }
        .padding(.horizontal, DS.s8).padding(.top, 4)
        .background(DS.page.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
    }

    private func item(_ title: String, icon: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3.weight(.semibold))
                Text(title).font(DS.footnoteStrong).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(selected ? DS.accentText : DS.text)
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
