import SwiftUI

// Friends (0.31): the seat picker. On top the whole train, its first and last coach shaped like the noses, numbered
// from the front, "Driving to Breda →"; tap a coach and it opens below, seen from the side as from the platform:
// doors, windows, wheels and the line's colour stripe. A double-deck coach has two rows of windows (the top row the
// upper deck, the bottom row the lower), a single-deck one a row. Tap your window: that's your seat. A friend's face
// sits in their window. The sums are in SeatMap.swift.
//
// The same picker on your ride screen (yours to set) and on a friend's page (theirs to see; yours too when you take
// that train).
//
// (0.31.1) 1st class, as NS's drawings show it (`SeatClass`): its windows gold-framed with a "1" at the start of each
// run, a gold mark in the train strip where it is; a coach that's 1st class all through gold in the strip and cream in
// the side view, "1st class" on it. Derived from the train, never sent.

/// (0.31.1) 1st class's colours: NS's yellow.
enum FirstClassLook {
    static let gold = DS.dynamic(0xD9A300, 0xFFC917)
    /// A coach that's all 1st class, in the strip (shut; open).
    static let body = DS.dynamic(0xF2D46A, 0xB8962A)
    static let bodyOpen = DS.dynamic(0xE3AE12, 0xD9A90F)
    static let bodyInk = DS.dynamic(0x5A4600, 0x2E2400)
    /// Its side, from the platform.
    static let shell = DS.dynamic(0xF7E9B8, 0xCDBB7E)
    /// A 1st-class window's glass.
    static let glass = DS.dynamic(0x4E4217, 0x463A12)
    /// Text on gold.
    static let ink = DS.dynamic(0x3A2E00, 0x2A2100)
}

/// (0.31.1) The "1" badge: in the legend, and on the first window of each 1st-class run.
struct FirstClassBadge: View {
    var size: CGFloat = 14

    var body: some View {
        Text("1").font(.system(size: size * 0.72, weight: .heavy, design: .rounded)).foregroundStyle(FirstClassLook.ink)
            .frame(width: size, height: size)
            .background(FirstClassLook.gold, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension TrainSize {
    /// The seat picker's train from NS's answer (nil: the guess, `coaches` long, else 6), with its decks and 1st class.
    static func seatTrain(_ size: TrainSize?, line: String?, coaches: Int = 0) -> SeatMap.Train {
        let l: TrainLayout? = size?.layout
        let units: [CoachMap.Unit] = l?.coachUnits ?? []
        let kinds: [String] = l?.units.map(\.kind) ?? []
        let cars: Int = size?.cars ?? coaches
        let drawings: [String] = l?.units.map(\.drawing) ?? []
        let seats: [Int?] = l?.units.map(\.firstSeats) ?? []
        return SeatMap.train(units: units, kinds: kinds, totalCars: cars > 0 ? cars : coaches, dir: l?.dir, line: line,
                             drawings: drawings, firstSeats: seats)
    }
}

/// Someone shown in the picker: a friend (their face in their window), or you.
struct SeatMark: Equatable {
    let id: String
    let name: String
    let coach: TravelState.Coach
}

/// The train and its coaches, and the windows of the one you tapped.
struct TrainSeatPicker: View {
    /// The vehicle's trip id (the same id is the same train).
    let tripId: String
    /// The train's number when known (else asked from the live trip).
    var num: String? = nil
    /// The NS station whose drawing it uses (where you, or they, got on).
    let station: String?
    /// "IC", "SPR": the stripe's colour and, without NS, the decks.
    let line: String?
    /// Where it's going ("Driving to Breda →").
    let towards: String?
    /// Friends on this train, with their coach.
    var friends: [SeatMark] = []
    /// You may set your own seat here (you're on this train, or a leg of yours takes it).
    var editable = true
    /// Without NS's drawing: the coaches to draw (a friend's "of"), 0: NS's length or 6.
    var coaches = 0
    /// (0.31.1) Told whether your own pick (coach, or window) is in 1st class, for your seat's line.
    var onMineFirst: ((Bool) -> Void)? = nil
    @ObservedObject private var share = FriendTravelShare.shared
    @ObservedObject private var store = FriendStore.shared
    @State private var size: TrainSize?
    @State private var loaded = false
    @State private var open: Int?

    private var mine: TravelState.Coach? { share.coachTrip == tripId ? share.coach : nil }
    private var colour: Color { DS.mode(train: true, line: line ?? "") }

    private var train: SeatMap.Train { TrainSize.seatTrain(size, line: line, coaches: coaches) }

    /// (0.31.1) Your pick is in 1st class.
    private func mineIsFirst(_ t: SeatMap.Train) -> Bool {
        guard let m = mine, let d = drawn(m, in: t), let c = t.coaches.first(where: { $0.drawn == d }) else { return false }
        return SeatMap.isFirst(SeatMap.valid(m.seat), in: c, dir: t.dir)
    }

    var body: some View {
        let t: SeatMap.Train = train
        VStack(alignment: .leading, spacing: DS.s12) {
            header(t)
            if !loaded {
                HStack(spacing: DS.s8) {
                    ProgressView().controlSize(.small)
                    Text("Getting the train from NS…").font(DS.sub).foregroundStyle(DS.secondary)
                }
            }
            TrainStrip(train: t, colour: colour, open: open, marked: markedCoaches(t), tap: { tapCoach($0, in: t) })
            if let o = open, let c = t.coaches.first(where: { $0.drawn == o }) {
                CoachSideView(coach: c, train: t, colour: colour, people: people(in: c, train: t), mine: mySeat(in: c, train: t),
                              editable: editable, tap: { w, row in tapWindow(w, row: row, coach: c, train: t) })
                    .transition(.opacity)
            }
            footer(t)
        }
        .padding(DS.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.inner(DS.cardRadius, padding: DS.s8), style: .continuous))
        .task(id: "\(tripId)|\(station ?? "")") { await load() }
        .onChange(of: mineIsFirst(t), initial: true) { _, v in onMineFirst?(v) }
    }

    // MARK: parts

    private func header(_ t: SeatMap.Train) -> some View {
        let what: String = t.anyDouble ? "Double-deck \(line ?? "train")" : (line.map { $0 == "SPR" ? "Sprinter" : $0 } ?? "Train")
        let to: String = towards.map { (name: String) -> String in
            switch t.dir {
            case "left": return "← Driving to \(name)"
            case "right": return "Driving to \(name) →"
            default: return "Towards \(name)"
            }
        } ?? (t.dir == "left" ? "← Front" : t.dir == "right" ? "Front →" : "")
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: DS.s8) {
                Text("\(what) · from the platform").font(DS.footnoteStrong).foregroundStyle(DS.secondary)
                Spacer(minLength: DS.s8)
                Text(to).font(DS.footnoteStrong).foregroundStyle(DS.accentText)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(what) · from the platform").font(DS.footnoteStrong).foregroundStyle(DS.secondary)
                Text(to).font(DS.footnoteStrong).foregroundStyle(DS.accentText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(t.dir == nil ? "\(what). Which way it goes isn’t known." : "\(what), \(to.replacingOccurrences(of: "→", with: "").replacingOccurrences(of: "←", with: ""))")
    }

    private func note(_ t: SeatMap.Train) -> String {
        guard let o = open else { return editable ? "Tap a coach, then your window" : "Tap a coach to look inside" }
        if t.coaches.first(where: { $0.drawn == o })?.double == true {
            return editable ? "Top row: upper deck · bottom: lower · tap your window" : "Top row: upper deck · bottom: lower"
        }
        return editable ? "Tap your window" : "Seen from the platform"
    }

    @ViewBuilder private func footer(_ t: SeatMap.Train) -> some View {
        let words: String = note(t)
        HStack(alignment: .firstTextBaseline, spacing: DS.s8) {
            Text(words).font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.s8)
            if editable, mine != nil {
                Button("Take it away") { share.setCoach(nil, trip: tripId) }
                    .font(DS.footnoteStrong).foregroundStyle(DS.accentText)
                    .frame(minHeight: DS.hit)
                    .accessibilityHint("Friends no longer see your coach")
            }
        }
        if t.anyFirst { legend(t) }
        if !t.fromNS, loaded {
            Text("NS hasn’t said how this train is made up: this is a guess (\(t.count) coaches).")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        } else if t.fromNS, loaded, !t.anyFirst, t.firstUnknown {
            Text("Where 1st class is in this train isn’t known.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// (0.31.1) "1 = 1st class (about here)", and "gold coach: all 1st class" when one is.
    private func legend(_ t: SeatMap.Train) -> some View {
        let whole: Bool = t.coaches.contains { $0.kind == .first }
        let part: Bool = t.coaches.contains { $0.kind == .part }
        let text: String = SeatClass.legend(part: part, whole: whole)
        let spoken: String = SeatClass.spokenLegend(part: part, whole: whole)
        return HStack(alignment: .center, spacing: 6) {
            FirstClassBadge()
            Text(text).font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    // MARK: who's where

    /// The coach a mark is in, as drawn here (nil: it can't be told).
    private func drawn(_ c: TravelState.Coach, in t: SeatMap.Train) -> Int? {
        let dir: String? = t.dir
        if let d = CoachMap.drawn(c, total: t.count, dir: dir, station: station) { return d }
        // the picker's own guess (front on the right) for a coach counted from the front
        if !t.fromNS, c.front, c.n >= 1, c.n <= t.count { return t.count - c.n }
        return nil
    }

    private func markedCoaches(_ t: SeatMap.Train) -> [Int: [String]] {
        var out: [Int: [String]] = [:]
        for f in friends { if let d = drawn(f.coach, in: t) { out[d, default: []].append(f.id) } }
        if let m = mine, let d = drawn(m, in: t) { out[d, default: []].append("me") }
        return out
    }

    private func people(in c: SeatMap.Coach, train t: SeatMap.Train) -> [CoachSideView.Person] {
        var out: [CoachSideView.Person] = []
        for f in friends {
            guard drawn(f.coach, in: t) == c.drawn, let s = SeatMap.valid(f.coach.seat), let w = SeatMap.drawnWindow(s, dir: t.dir) else { continue }
            out.append(CoachSideView.Person(id: f.id, name: f.name, picture: store.pictures[f.id], window: w, row: SeatMap.row(s, double: c.double)))
        }
        return out
    }

    private func mySeat(in c: SeatMap.Coach, train t: SeatMap.Train) -> (window: Int, row: Int)? {
        guard let m = mine, drawn(m, in: t) == c.drawn, let s = SeatMap.valid(m.seat), let w = SeatMap.drawnWindow(s, dir: t.dir) else { return nil }
        return (w, SeatMap.row(s, double: c.double))
    }

    // MARK: taps

    private func coachValue(_ c: SeatMap.Coach, in t: SeatMap.Train, seat: TravelState.Seat?) -> TravelState.Coach {
        TravelState.Coach(n: c.n, of: t.count, front: c.front, at: station, seat: seat)
    }

    private func tapCoach(_ c: SeatMap.Coach, in t: SeatMap.Train) {
        withAnimation(DS.quick) { open = c.drawn }
        guard editable else { return }
        // your coach (keeping your window when it's the same one)
        if let m = mine, drawn(m, in: t) == c.drawn { return }
        share.setCoach(coachValue(c, in: t, seat: nil), trip: tripId)
    }

    private func tapWindow(_ w: Int, row: Int, coach c: SeatMap.Coach, train t: SeatMap.Train) {
        guard editable else { return }
        let seat: TravelState.Seat = SeatMap.seat(drawn: w, row: row, double: c.double, dir: t.dir)
        // the same window again: the window goes, the coach stays
        if let m = mine, drawn(m, in: t) == c.drawn, m.seat == seat {
            share.setCoach(coachValue(c, in: t, seat: nil), trip: tripId)
        } else {
            share.setCoach(coachValue(c, in: t, seat: seat), trip: tripId)
        }
    }

    private func load() async {
        loaded = false
        defer {
            loaded = true
            if open == nil { open = firstOpen() }
        }
        guard let station else { return }
        var known: String? = num
        if known == nil || known?.isEmpty == true { known = await share.number(tripId) }
        guard let n = known, !n.isEmpty else { return }
        size = await NSStore.shared.trainSize(num: n, code: station)
    }

    /// The coach opened at first: a friend's, else yours.
    private func firstOpen() -> Int? {
        let t: SeatMap.Train = train
        if let f = friends.first, let d = drawn(f.coach, in: t) { return d }
        if let m = mine { return drawn(m, in: t) }
        return nil
    }
}

// MARK: the whole train

/// The coaches in a row, the first and last shaped like noses, each a button with its number under it.
struct TrainStrip: View {
    let train: SeatMap.Train
    let colour: Color
    let open: Int?
    /// Who's in each coach (drawn index: ids; "me" for you).
    let marked: [Int: [String]]
    let tap: (SeatMap.Coach) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(train.coaches, id: \.drawn) { c in button(c) }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(train.dir == nil ? "The train’s coaches" : "The train’s coaches, numbered from the front")
    }

    private func button(_ c: SeatMap.Coach) -> some View {
        let isOpen: Bool = open == c.drawn
        let who: [String] = marked[c.drawn] ?? []
        let first: Bool = c.drawn == 0
        let last: Bool = c.drawn == train.count - 1
        let spoken: String = SeatMap.spokenCoach(c, of: train.count) + (who.contains("me") ? ", your coach" : "")
            + (who.contains(where: { $0 != "me" }) ? ", a friend is here" : "")
        let all1: Bool = c.kind == .first
        let plain: Color = isOpen ? colour : DS.legQuiet.opacity(0.45)
        let gold: Color = isOpen ? FirstClassLook.bodyOpen : FirstClassLook.body
        let fill: Color = all1 ? gold : plain
        let plainInk: Color = isOpen ? Color.white.opacity(0.85) : DS.secondary.opacity(0.7)
        let ink: Color = all1 ? FirstClassLook.bodyInk.opacity(0.75) : plainInk
        let mark: ClosedRange<Double>? = c.kind == .part ? c.first.flatMap(SeatClass.span) : nil
        return Button { tap(c) } label: {
            VStack(spacing: 3) {
                CoachTop(double: c.double, noseLeft: first, noseRight: last, fill: fill, ink: ink, mark: mark)
                    .frame(width: 50, height: c.double ? 30 : 24)
                    .overlay(alignment: .top) {
                        if !who.isEmpty {
                            Circle().fill(who.contains("me") ? DS.accent : DS.warning).frame(width: 8, height: 8).offset(y: -5)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(isOpen ? DS.accent : Color.clear, lineWidth: 2))
                HStack(spacing: 2) {
                    Text("\(c.n)").font(DS.footnoteStrong).monospacedDigit().foregroundStyle(isOpen ? DS.accentText : DS.secondary)
                    if all1 { FirstClassBadge(size: 12) }
                }
            }
            .frame(minHeight: DS.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityHint("Shows its windows")
    }
}

/// A coach from above in the strip: a body (its outer ends rounded like a nose) with a line of windows per deck.
struct CoachTop: View {
    let double: Bool
    let noseLeft: Bool
    let noseRight: Bool
    let fill: Color
    let ink: Color
    /// (0.31.1) Where along it (shares, from the left) a part is 1st class: a gold bar there.
    var mark: ClosedRange<Double>? = nil

    var body: some View {
        let nose: CGFloat = 13
        let shape = UnevenRoundedRectangle(topLeadingRadius: noseLeft ? nose : 5, bottomLeadingRadius: noseLeft ? 6 : 5,
                                           bottomTrailingRadius: noseRight ? 6 : 5, topTrailingRadius: noseRight ? nose : 5,
                                           style: .continuous)
        return ZStack {
            shape.fill(fill)
            VStack(spacing: 4) {
                Capsule().fill(ink).frame(height: 3)
                if double { Capsule().fill(ink).frame(height: 3) }
            }
            .padding(.horizontal, 7)
            if let mark { markBar(mark) }
        }
        .accessibilityHidden(true)
    }

    private func markBar(_ mark: ClosedRange<Double>) -> some View {
        GeometryReader { g in
            let w: CGFloat = g.size.width
            let x0: CGFloat = w * CGFloat(mark.lowerBound)
            let x1: CGFloat = w * CGFloat(mark.upperBound)
            Capsule().fill(FirstClassLook.gold)
                .frame(width: max(5, x1 - x0), height: 4)
                .position(x: (x0 + x1) / 2, y: g.size.height - 3)
        }
    }
}

// MARK: one coach from the side

/// The coach you tapped, as from the platform: doors at both ends, 11 windows a row (two rows on a double-deck coach),
/// the line's stripe, the wheels. Each window is a button.
struct CoachSideView: View {
    struct Person: Equatable {
        let id: String
        let name: String
        let picture: Data?
        let window: Int
        let row: Int
    }

    let coach: SeatMap.Coach
    let train: SeatMap.Train
    let colour: Color
    let people: [Person]
    let mine: (window: Int, row: Int)?
    let editable: Bool
    let tap: (Int, Int) -> Void

    private static let shell = DS.dynamic(0xE6E9EC, 0xD3D8DD)
    private static let glass = DS.dynamic(0x33404D, 0x2B3640)
    private static let door = DS.dynamic(0x9AA3AC, 0x8B949D)

    private var rows: Int { coach.double ? 2 : 1 }
    /// (0.31.1) All 1st class.
    private var all1: Bool { coach.kind == .first }
    private var sections: [SeatClass.Section] { coach.first ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(all1 ? FirstClassLook.shell : Self.shell)
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        doorView
                        VStack(spacing: 6) {
                            ForEach(0..<rows, id: \.self) { r in windowRow(r) }
                        }
                        doorView
                    }
                    .padding(.horizontal, 8).padding(.top, 8)
                    Rectangle().fill(colour).frame(height: 5).padding(.top, 6).padding(.horizontal, 2)
                    Spacer(minLength: 6)
                }
            }
            .frame(height: coach.double ? 104 : 72)
            .overlay(alignment: .bottomLeading) {
                if all1 {
                    Text("1st class").font(.caption2.weight(.bold)).foregroundStyle(FirstClassLook.ink)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(FirstClassLook.gold, in: Capsule())
                        .padding(.leading, 26).padding(.bottom, 1)
                        .accessibilityHidden(true)
                }
            }
            wheels
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SeatMap.spokenCoach(coach, of: train.count))
    }

    private var doorView: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Self.door)
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }

    private func windowRow(_ r: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<SeatMap.windows, id: \.self) { i in window(i, row: r) }
        }
    }

    private func window(_ i: Int, row r: Int) -> some View {
        let here: Person? = people.first { $0.window == i && $0.row == r }
        let isMine: Bool = mine?.window == i && mine?.row == r
        let w: Int = SeatMap.window(drawn: i, dir: train.dir)
        let deck: SeatMap.Deck = coach.double ? (r == 0 ? .upper : .lower) : .none
        let first: Bool = isFirst(i, row: r)
        // the "1": on the first window of each run (the left one), when nobody sits there
        let startsRun: Bool = first && (i == 0 || !isFirst(i - 1, row: r))
        var spoken: String = SeatMap.spoken(coach: coach.n, deck: deck, window: w, front: coach.front)
        if first { spoken += ", 1st class" }
        if let here { spoken += ", \(here.name) sits here" }
        if isMine { spoken += ", your seat" }
        return Button { tap(i, r) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(isMine ? DS.accent : (first ? FirstClassLook.glass : Self.glass))
                if first {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(FirstClassLook.gold, lineWidth: 2)
                }
                if startsRun, here == nil, !isMine {
                    FirstClassBadge(size: 13)
                }
                if let here {
                    FriendAvatar(name: here.name, id: here.id, picture: here.picture, size: 18)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!editable)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(isMine ? .isSelected : [])
        .accessibilityHint(editable ? (isMine ? "Takes your window away" : "Marks it as your seat") : "")
    }

    /// (0.31.1) Window `i` (drawn from the left) in row `r` is 1st class.
    private func isFirst(_ i: Int, row r: Int) -> Bool {
        all1 || SeatClass.isFirst(window: i, row: r, double: coach.double, sections: sections)
    }

    private var wheels: some View {
        HStack {
            pair
            Spacer()
            pair
        }
        .padding(.horizontal, 26)
        .offset(y: -6)
        .accessibilityHidden(true)
    }

    private var pair: some View {
        HStack(spacing: 4) {
            Circle().stroke(DS.legQuiet, lineWidth: 2).background(Circle().fill(DS.surface3)).frame(width: 14, height: 14)
            Circle().stroke(DS.legQuiet, lineWidth: 2).background(Circle().fill(DS.surface3)).frame(width: 14, height: 14)
        }
    }
}
