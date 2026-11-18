import SwiftUI

// The "Next trip first" home (0.19.1, concept B, artboards B1–B3): the same home as "Live around you" (`NewHome`: its
// map, stores, refreshes, Plan and Your day), laid out around one big card with your next trip, and a bar at the
// bottom with Search, Your week and Settings (0.20.1: the card picks where you go). These are its parts; `NewHome` puts them together.

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
                        .fill(l.kind == .ride ? DS.mode(train: l.train, line: l.line) : DS.legQuiet)
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
    /// On the bus or train the home found you on (0.20.5): where you get off it, when you're there, and Wake me.
    struct Aboard {
        let vehicle: Vehicle
        let trip: DoorTrip          // starts with the ride you're on ("On board")
        let destName: String
        let startsSoon: Bool        // seen on it once: one more look and the trip starts by itself
    }
    enum Content {
        case loading
        case empty(note: String?)
        case trip(Shown)
        case onBoard(Aboard)
    }

    let content: Content
    /// The countdown's clock (the same date the trip was picked with).
    let now: Date
    /// Where the card is going, as a chip to pick another (0.20.1: the card owns the destination).
    var chip: AnyView? = nil
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
            case .onBoard(let a): aboard(a)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let chip { chip }
            Text("Finding your next trip…").font(DS.headline).foregroundStyle(DS.text)
            DSSkeletonRow(); DSSkeletonRow()
        }
        .accessibilityElement(children: .combine)
    }

    private func empty(_ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let chip { chip }
            Text("No trip planned").font(DS.title).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
            Text(note ?? (chip == nil ? "Plan one, or tap a place below to see the way there." : "Plan one, or pick another place above."))
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: plan) {
                Label("Plan a trip", systemImage: "magnifyingglass").font(DS.bodyStrong).foregroundStyle(DS.accentSoftText)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(DS.accentSoft, in: Capsule())
            }
            .buttonStyle(DSPressStyle())
        }
    }

    /// "You're on the 158": no countdown to leave (you've left), but when you're there and where to get off.
    private func aboard(_ a: Aboard) -> some View {
        let ride = a.trip.first
        let more = a.trip.rides.count - 1
        let getOff = Fmt.place(ride.toStop)
        let last = Fmt.place(a.trip.last.toStop)
        let then: String = more <= 0 ? "" : more == 1 ? ", then one more ride" : ", then \(more) more rides"
        let stay: String = "Stay on until \(getOff) · \(Fmt.hhmm(ride.arrival))" + then
        let title: String = a.vehicle.isTrain ? "You’re on the \(a.vehicle.title)" : "You’re on bus \(a.vehicle.line)"
        return VStack(alignment: .leading, spacing: 12) {
            if let chip { chip }
            HStack(alignment: .center, spacing: 8) {
                DSLinePill(line: a.vehicle.line, train: a.vehicle.isTrain)
                Text(title)
                    .font(DS.headline).foregroundStyle(DS.text).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            .accessibilityElement(children: .combine)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.hhmm(a.trip.end)).font(DS.hero(min(big, 72))).monospacedDigit().foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("at \(a.destName)").font(DS.body).foregroundStyle(DS.secondary).lineLimit(2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("At \(a.destName) at \(Fmt.hhmm(a.trip.end))")
            Text(stay)
                .font(DS.calloutStrong).foregroundStyle(DS.text).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            DSLegBar(legs: NextTrip.legs(of: a.trip))
            DSPrimaryButton(title: "Wake me before \(last)", icon: "bell.fill", lines: 2, action: start)
                .accessibilityHint("Starts your trip on this \(a.vehicle.isTrain ? "train" : "bus")")
            if a.startsSoon {
                Text("Stay on and it starts by itself in about a minute.").font(DS.footnote).foregroundStyle(DS.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shown(_ s: Shown) -> some View {
        let first = s.trip.first
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                if let chip {
                    chip
                } else {
                    Text(s.title).font(DS.subStrong).foregroundStyle(DS.secondary).lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 8)
                Button(action: otherTimes) {
                    Text("Other times").font(DS.subStrong).foregroundStyle(DS.accentText)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Plan a trip to \(s.destName), with the other ways there")
            }
            if chip != nil && !s.title.isEmpty {
                Text(s.title).font(DS.subStrong).foregroundStyle(DS.secondary).lineLimit(2)
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

/// The bar at the bottom (0.20.1): Friends (0.25: in place of Search, which the field at the top already is), Your
/// week, and Settings. Where you go is the card's.
struct NextTripBar: View {
    let weekOpen: Bool
    /// Friend requests waiting (a badge on Friends).
    var friendsWaiting = 0
    let friends: () -> Void
    let week: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            item("Friends", icon: friendsWaiting > 0 ? "person.2.fill" : "person.2",
                 label: friendsWaiting > 0 ? "Friends, \(friendsWaiting) waiting" : "Friends", badge: friendsWaiting, action: friends)
            item("Week", icon: "calendar", label: "Your week", selected: weekOpen, action: week)
            item("Settings", icon: "gearshape", label: "Settings", action: settings)
        }
        .padding(.horizontal, DS.s8).padding(.top, 4)
        .background(DS.page.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
    }

    private func item(_ title: String, icon: String, label: String, selected: Bool = false, badge: Int = 0,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3.weight(.semibold))
                    .overlay(alignment: .topTrailing) { if badge > 0 { FriendsBadge(count: badge).offset(x: 10, y: -6) } }
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

/// The card's destination: "To BUas ▾", a 44 pt chip; tap it for By your schedule, Home, School, your other places
/// and the last places you searched (0.20.2).
struct DestinationChip: View {
    let title: String
    /// By your schedule: where that goes now ("BUas", "Home"), and whether the card goes there by it.
    var schedule: (name: String, current: Bool)? = nil
    let places: [SavedPlace]
    var recents: [Destination] = []
    let isCurrent: (SavedPlace) -> Bool
    var isCurrentRecent: (Destination) -> Bool = { _ in false }
    let choose: (SavedPlace) -> Void
    var chooseSchedule: () -> Void = {}
    var chooseRecent: (Destination) -> Void = { _ in }
    var body: some View {
        Menu {
            if let s = schedule {
                Button { chooseSchedule() } label: { Label("By your schedule · \(s.name)", systemImage: s.current ? "checkmark" : "calendar") }
            }
            Section {
                ForEach(places) { p in
                    Button { choose(p) } label: { Label(p.name, systemImage: isCurrent(p) ? "checkmark" : p.symbol) }
                }
            }
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents) { d in
                        Button { chooseRecent(d) } label: { Label(d.short, systemImage: isCurrentRecent(d) ? "checkmark" : "clock.arrow.circlepath") }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(DS.calloutStrong).foregroundStyle(DS.accentSoftText).lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(DS.accentSoftText)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: DS.hit)
            .background(DS.accentSoft, in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel("\(title). Where the card goes")
        .accessibilityHint("Pick another place")
    }
}
