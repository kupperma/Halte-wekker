import SwiftUI

// The boards on the station wall, a few steps from the map: a slim amber LED strip with the trains, and under it the
// blue journey planner (your trip, the buses, and the other parts). The app writes on them exactly where they are in
// the last frame of the walk from the map.

/// Where the two screens sit at the end of the walk (share of the 540 × 1170 picture). The LED rectangle includes its
/// blue title strip.
enum WallBoards {
    static let led = CGRect(x: 0.02407, y: 0.11713, width: 0.95186, height: 0.12829)
    static let planner = CGRect(x: 0.04912, y: 0.29152, width: 0.90176, height: 0.67154)
    static func rect(_ f: CGRect, in size: CGSize) -> CGRect {
        let v = MapSpot.picture(in: size)
        return CGRect(x: v.minX + f.minX * v.width, y: v.minY + f.minY * v.height, width: f.width * v.width, height: f.height * v.height)
    }
}

enum BoardInk {
    static let amber = Color(hex: 0xFFB43A)
    static let amberDim = Color(hex: 0x8A5A1A)
    static let amberSoft = Color(hex: 0xD08A2A)
    static let led = Color(hex: 0x07070A)
    static let strip = Color(hex: 0x100C07)          // the LED board's header: warm black
    static let blueTop = Color(hex: 0x1D55C8)
    static let blueBottom = Color(hex: 0x0F3EA8)
    static let band = Color(hex: 0x0B2F86)
    static let bar = Color(hex: 0xE9EEF7)
    static let navy = Color(hex: 0x10275E)
    static let route = Color(hex: 0x5CC6F2)
    static let yellow = Color(hex: 0xF5C400)
    static let green = Color(hex: 0x2FD27A)
    static let late = Color(hex: 0xFFD34D)
    static func mono(_ s: CGFloat) -> Font { .system(size: s, weight: .bold, design: .monospaced) }
    static func sans(_ s: CGFloat, _ w: Font.Weight = .bold) -> Font { .system(size: s, weight: w) }
}

extension HomeSection {
    /// The tabs along the top of the planner.
    static let board: [HomeSection] = [.fastest, .lines, .planned, .more]
    var tab: String {
        switch self {
        case .fastest: return "TRIPS"
        case .lines: return "ALL LINES"
        case .planned: return "PLANNED"
        case .more: return "MORE"
        }
    }
}

/// Whether the trip was started at the boards, so the ride screen turns from the boards to the platform first.
enum Handoff { static var fromBoards = false }

/// What you tapped on a board: its page shows on the planner.
enum BoardPick: Hashable {
    case train(PanelTrip)
    case bus(BoardDeparture)
    case busTrip(PanelTrip)
    case ride(Ride)                 // one ride of your trip, from the Fastest tab
}

// MARK: speed ranks

/// The speed rank of a ride: how it compares with the fastest ride seen on the same stretch (delays count).
struct RankInfo {
    let grade: String?
    let minutes: Double
    let best: Double?
    let stretch: String
    static func of(_ r: Ride) -> RankInfo {
        let g = r.grade                 // (grading also remembers a new fastest time, so ask for it first)
        return RankInfo(grade: g, minutes: r.arrival.timeIntervalSince(r.departure) / 60, best: Ratings.shared.best("\(r.fromId)>\(r.toStop)"),
                        stretch: "\(Fmt.place(r.fromStop)) → \(Fmt.place(r.toStop))")
    }
    /// A trip is ranked on the ride that gets you there: the only one, or the last.
    static func of(_ t: DoorTrip) -> RankInfo { of(t.rides.count == 1 ? t.first : t.last) }
}

/// The rank on a line's page: the coin, what it means, and the numbers behind it.
struct RankBlock: View {
    let rank: RankInfo
    var cancelled = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlannerBar(title: "Speed rank", sub: rank.stretch)
            HStack(alignment: .top, spacing: 10) {
                Coin(grade: rank.grade, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(BoardInk.sans(15)).foregroundStyle(Paper.ink)
                    Text(meaning).font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
                    if let n = numbers { Text(n).font(BoardInk.sans(11)).foregroundStyle(Paper.ink).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
    }
    private var title: String {
        guard let g = rank.grade else { return cancelled ? "No rank: it’s cancelled" : "No rank yet" }
        return "\(g)-rank"
    }
    private var meaning: String {
        switch rank.grade {
        case "S": return "As fast as it gets on this stretch."
        case "A": return "A little slower than the fastest seen here: up to 3 min, or 18% longer."
        case "B": return "Slower than the fastest seen here: up to 30% longer."
        case "C": return "Much slower than the fastest seen here."
        default: return "A rank compares a ride with the fastest one seen on the same stretch."
        }
    }
    private var numbers: String? {
        guard rank.grade != nil, rank.minutes > 0 else { return nil }
        var t = "This ride: \(Fmt.rideText(rank.minutes))"
        if let b = rank.best, b > 0 {
            let e = Int((rank.minutes - b).rounded())
            t += " · the fastest: \(Fmt.rideText(b))" + (e >= 1 ? " (\(e) min slower)" : "")
        }
        return t + ". Delays count, so a late one drops a rank."
    }
}

/// What the route colours on the planner mean.
struct RankLegend: View {
    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            ForEach(["S", "A", "B", "C"], id: \.self) { g in
                Text(g).font(BoardInk.sans(10)).foregroundStyle(RatingStyle.ink(g))
                    .frame(width: 20, height: 15).background(RatingStyle.fill(g), in: RoundedRectangle(cornerRadius: 2))
            }
            Text("Route colours are speed ranks: how fast a bus gets you there compared with the fastest on that route. Tap any line for its rank.")
                .font(BoardInk.sans(9.5, .regular)).foregroundStyle(Paper.ink.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: the LED strip

/// One train on the LED strip.
struct LEDTrain: Identifiable, Hashable {
    let id: String
    let time: String
    let to: String              // "Breda IC"
    let via: String             // "from Den Bosch"
    let platform: String
    let status: String          // "On time", "09:16", "Cancelled", "Departed"
    let gone: Bool
    let picked: Bool
}

/// The slim amber LED strip: one line per train, the ones that have gone dimmed, a new page every 8 seconds.
struct LEDStrip: View {
    let title: String
    let rows: [LEDTrain]
    let tap: (String) -> Void
    private let perPage = 6

    var body: some View {
        GeometryReader { g in
            let k = g.size.width / 346
            let stripH = g.size.height * 0.156
            VStack(spacing: 0) {
                // the header: warm black with amber letters and a thin amber rule, part of the same LED board
                HStack {
                    Text("Departures")
                    Spacer(minLength: 4)
                    Text(title)
                }
                .font(BoardInk.sans(10.5 * k)).foregroundStyle(BoardInk.amber).lineLimit(1)
                .shadow(color: BoardInk.amber.opacity(0.7), radius: 2 * k)
                .padding(.horizontal, 8 * k)
                .frame(height: stripH)
                .frame(maxWidth: .infinity)
                .background(BoardInk.strip)
                .overlay(alignment: .bottom) { BoardInk.amber.opacity(0.55).frame(height: max(1, stripH * 0.06)) }
                TimelineView(.periodic(from: .now, by: 8)) { tl in
                    let pages = max(1, (rows.count + perPage - 1) / perPage)
                    let page = Int(tl.date.timeIntervalSinceReferenceDate / 8) % pages
                    // the last page is filled up with the trains before it, so the board is never half empty
                    let start = min(page * perPage, max(0, rows.count - perPage))
                    let shown = Array(rows.dropFirst(start).prefix(perPage))
                    led(shown, k: k, rowH: max(8, (g.size.height - stripH - 12 * k) / CGFloat(perPage)), page: page, pages: pages)
                }
            }
        }
    }

    private func led(_ shown: [LEDTrain], k: CGFloat, rowH: CGFloat, page: Int, pages: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Time").frame(width: 34 * k, alignment: .leading)
                Text("Destination").frame(width: 82 * k, alignment: .leading)
                Text("Via").frame(width: 150 * k, alignment: .leading)
                Text("Plat").frame(width: 30 * k, alignment: .leading)
                Text(pages > 1 ? "\(page + 1)/\(pages)" : "Exp").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(BoardInk.mono(7.5 * k)).foregroundStyle(BoardInk.amberDim).lineLimit(1)
            .frame(height: 12 * k)
            if shown.isEmpty {
                Text("No trains right now").font(BoardInk.mono(10 * k)).foregroundStyle(BoardInk.amber).frame(height: rowH)
            }
            ForEach(shown) { r in
                Button { tap(r.id) } label: {
                    HStack(spacing: 0) {
                        Text(r.time).frame(width: 34 * k, alignment: .leading)
                        Text(r.to).frame(width: 82 * k, alignment: .leading)
                        Text(r.via).font(BoardInk.mono(8 * k)).foregroundStyle(r.gone ? BoardInk.amberDim : BoardInk.amberSoft)
                            .frame(width: 150 * k, alignment: .leading)
                        Text(r.platform).frame(width: 30 * k, alignment: .leading)
                        Text(r.status).font(BoardInk.mono(8.5 * k)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(BoardInk.mono(10 * k)).lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(r.gone ? BoardInk.amberDim : BoardInk.amber)
                    .frame(height: rowH)
                    .overlay(Rectangle().stroke(Paper.ink.opacity(r.picked ? 0.9 : 0), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(r.time) \(r.to), \(r.via), platform \(r.platform), \(r.status). Tap for more and to track it.")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4 * k)
        .shadow(color: BoardInk.amber.opacity(0.55), radius: 2.5 * k)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BoardInk.led)
        .overlay(LEDGrid().allowsHitTesting(false))
        .clipped()
    }
}

/// The dark gaps between the LEDs, over the text, so it reads like a dot-matrix board.
struct LEDGrid: View {
    var body: some View {
        Canvas { c, size in
            let p: CGFloat = 2.2
            var path = Path()
            var x: CGFloat = 0
            while x < size.width { path.addRect(CGRect(x: x, y: 0, width: 0.75, height: size.height)); x += p }
            var y: CGFloat = 0
            while y < size.height { path.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.75)); y += p }
            c.fill(path, with: .color(.black.opacity(0.5)))
        }
    }
}

// MARK: the planner

/// The blue journey planner: tabs for the four parts along the top, and what you picked under them.
struct PlannerScreen<Content: View>: View {
    let section: HomeSection
    let pick: (HomeSection) -> Void
    let content: Content

    init(section: HomeSection, pick: @escaping (HomeSection) -> Void, @ViewBuilder content: () -> Content) {
        self.section = section; self.pick = pick; self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                PaperTabs(section: section, pick: pick)
                TimelineView(.everyMinute) { tl in
                    Text(Fmt.hhmm(tl.date)).font(BoardInk.sans(12)).foregroundStyle(Paper.muted)
                }
            }
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .paperSheet()
    }
}

/// So the planner reads as a screen in the station rather than a flat menu: faint scan lines, a little shading
/// towards the edges, and the sheen of the glass.
struct ScreenGlass: View {
    var body: some View {
        ZStack {
            Canvas { c, size in
                var path = Path()
                var y: CGFloat = 0
                while y < size.height { path.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.6)); y += 3 }
                c.fill(path, with: .color(.black.opacity(0.12)))
            }
            RadialGradient(colors: [.clear, .black.opacity(0.28)], center: .center, startRadius: 160, endRadius: 560)
            LinearGradient(stops: [.init(color: .white.opacity(0.08), location: 0), .init(color: .clear, location: 0.38)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().stroke(Paper.ink.opacity(0.10), lineWidth: 1)
        }
    }
}

/// A white header bar on the planner ("Local bus services").
struct PlannerBar: View {
    let title: String
    var sub: String? = nil
    var action: (() -> Void)? = nil         // makes the text on the right a button ("Change")
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(BoardInk.sans(13)).lineLimit(1)
            Spacer(minLength: 4)
            if let sub {
                if let action {
                    Button(action: action) { Text(sub).font(BoardInk.sans(11, .semibold)).underline() }.buttonStyle(.plain)
                } else {
                    Text(sub).font(BoardInk.sans(11, .regular)).lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Paper.navy)
    }
}

/// A stop's name, with the yellow bus dot.
struct PlannerStop: View {
    let name: String
    var rail = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: rail ? "tram.fill" : "bus.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(BoardInk.navy)
                .frame(width: 15, height: 15).background(BoardInk.yellow, in: Circle())
            Text(name).font(BoardInk.sans(13)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.top, 2)
    }
}

struct PlannerColumns: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Route").frame(width: 46, alignment: .leading)
            Text("Destination")
            Spacer(minLength: 4)
            Text("Due").frame(width: 40, alignment: .trailing)
            Text("Time").frame(width: 76, alignment: .trailing)
        }
        .font(BoardInk.sans(9.5, .semibold)).foregroundStyle(Paper.ink.opacity(0.72))
    }
}

/// A bus on the planner: the route in a light blue box, where it goes, minutes to go and the time. When it runs late the
/// new time is in a white box; when it's cancelled a white band says so; once it has gone it's dimmed.
struct PlannerBusRow: View {
    let line: String
    let to: String
    let time: Date              // when it really leaves
    let scheduled: Date
    let live: Bool
    let cancelled: Bool
    var grade: String? = nil        // the route box takes the colour of its speed rank
    var train = false               // a train from the station near you: a yellow box
    var note: String? = nil
    var heading: Heading? = nil     // which way it goes: an arrow, the compass direction and where it goes next
    let watched: Bool
    let picked: Bool
    let tap: () -> Void

    var body: some View {
        let gone = !cancelled && time < Date().addingTimeInterval(-60)
        let late = live && !cancelled && abs(time.timeIntervalSince(scheduled)) >= 60
        Button(action: tap) {
            HStack(spacing: 0) {
                LineBullet(line: line, train: train, grade: grade, height: 22, minWidth: 38, font: 13)
                    .padding(.trailing, heading == nil ? 9 : 7)
                if let h = heading {
                    // the way it drives, on a map with north up
                    Image(systemName: "location.north.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Paper.ink)
                        .rotationEffect(.degrees(h.degrees))
                        .frame(width: 21, height: 21).background(Paper.card, in: Circle())
                        .overlay(Circle().stroke(Paper.ink, lineWidth: 1.4))
                        .padding(.trailing, 7)
                        .accessibilityLabel("Going \(h.spoken)")
                }
                if cancelled {
                    Text("Cancelled · \(to)").font(BoardInk.sans(12)).foregroundStyle(Paper.late).lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 20, alignment: .leading).background(Paper.late.opacity(0.1))
                    Text("×\(Fmt.hhmm(scheduled))").font(BoardInk.sans(13)).foregroundStyle(Paper.ink).frame(width: 76, alignment: .trailing)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(to).font(BoardInk.sans(14)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.7)
                        if let h = heading {
                            Text("\(h.compass)\(h.via.map { " · via \($0)" } ?? "")").font(BoardInk.sans(9.5, .semibold))
                                .foregroundStyle(Paper.navy).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        if let note { Text(note).font(BoardInk.sans(9.5, .regular)).foregroundStyle(Paper.ink.opacity(0.75)).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    if watched { Image(systemName: "bell.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Paper.navy).padding(.trailing, 4) }
                    Text(due(gone)).font(BoardInk.sans(14)).foregroundStyle(Paper.ink).frame(width: 40, alignment: .trailing)
                    if late {
                        HStack(spacing: 4) {
                            Text(Fmt.hhmm(scheduled)).font(BoardInk.sans(10, .regular)).foregroundStyle(Paper.ink.opacity(0.7))
                            Text(Fmt.hhmm(time)).font(BoardInk.sans(12)).foregroundStyle(Paper.late)
                                .padding(.horizontal, 4).padding(.vertical, 1).background(Paper.late.opacity(0.12), in: RoundedRectangle(cornerRadius: 2))
                        }
                        .frame(width: 76, alignment: .trailing)
                    } else {
                        Text(Fmt.hhmm(time)).font(BoardInk.sans(13)).foregroundStyle(Paper.ink).frame(width: 76, alignment: .trailing)
                    }
                }
            }
            .padding(.vertical, 5)
            .opacity(gone ? 0.45 : 1)
            .overlay(alignment: .bottom) { Rectangle().fill(Paper.ink.opacity(0.12)).frame(height: 1) }
            .background(picked ? Paper.ink.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cancelled ? "Bus \(line) to \(to), \(Fmt.hhmm(scheduled)), cancelled" : "Bus \(line) to \(to), \(Fmt.hhmm(time))\(gone ? ", has left" : ""). Tap for more and to track it.")
    }

    private func due(_ gone: Bool) -> String {
        if gone { return "left" }
        let m = Int((time.timeIntervalSinceNow / 60).rounded())
        return m <= 0 ? "now" : "\(m)"
    }
}

/// Your fastest trip at the top of the planner: the rides one after the other, when you're there, and the wake-up button.
struct PlannerTripCard: View {
    let trip: DoorTrip
    let home: Bool
    let wakeTitle: String?
    var arrive: String? = nil       // "at Tilburg 10:12" for a trip from where you are
    var title = "Your trip · fastest"
    let wake: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(BoardInk.sans(13))
                Spacer(minLength: 4)
                Text(arrive ?? "\(home ? "home" : "at BUas") \(Fmt.hhmm(trip.end))").font(BoardInk.sans(13)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(BoardInk.navy)
            HStack(spacing: 5) {
                ForEach(Array(trip.rides.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Rectangle().fill(Color(hex: 0x9FB1D6)).frame(width: 8, height: 2) }
                    HStack(spacing: 4) {
                        let g = r.isTrain ? nil : r.grade          // buses in the colour of their speed rank, trains in yellow
                        LineBullet(line: r.line, train: r.isTrain, grade: g, height: 18, minWidth: 30, font: 11)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Fmt.hhmm(r.departure)).font(BoardInk.sans(13)).foregroundStyle(r.cancelled ? HWPalette.stamp : BoardInk.navy).strikethrough(r.cancelled)
                            Text("to \(Fmt.place(r.toStop))").font(BoardInk.sans(9.5, .regular)).foregroundStyle(Color(hex: 0x45608F)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if let wakeTitle {
                Button(action: wake) {
                    Text(wakeTitle.uppercased()).font(BoardInk.sans(11)).tracking(0.6).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 7).background(Paper.green, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.edge, lineWidth: 1))
    }
}

/// One ride of your trip on the Fastest tab: the line (buses in their rank colour, trains in yellow), where it goes,
/// how it's doing, and when it leaves and gets there.
struct PlannerRideRow: View {
    let ride: Ride
    let info: RailInfo?
    let picked: Bool
    let tap: () -> Void
    var body: some View {
        let st = RideText.status(ride, info)
        let gone = ride.cancelled || info?.cancelled == true
        let late = ride.live && !gone && abs(ride.delay) >= 1
        let g = ride.isTrain ? nil : ride.grade
        Button(action: tap) {
            HStack(alignment: .top, spacing: 8) {
                LineBullet(line: ride.line, train: ride.isTrain, grade: g, height: 22, minWidth: 38, font: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text("to \(Fmt.place(ride.toStop))").font(BoardInk.sans(14)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.7)
                    Text("from \(Fmt.place(ride.fromStop)) · \(ride.rideMinutes) min ride").font(BoardInk.sans(10, .regular)).foregroundStyle(Paper.ink.opacity(0.75)).lineLimit(1)
                    Text(st.text).font(BoardInk.sans(10.5)).foregroundStyle(st.warn ? Paper.late : st.ok ? Paper.ok : Paper.ink.opacity(0.8)).lineLimit(2)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    if late {
                        HStack(spacing: 4) {
                            Text(Fmt.hhmm(ride.scheduledDeparture)).font(BoardInk.sans(10, .regular)).foregroundStyle(Paper.ink.opacity(0.7))
                            Text(Fmt.hhmm(ride.departure)).font(BoardInk.sans(13)).foregroundStyle(Paper.late)
                                .padding(.horizontal, 4).padding(.vertical, 1).background(Paper.late.opacity(0.12), in: RoundedRectangle(cornerRadius: 2))
                        }
                    } else {
                        Text(Fmt.hhmm(gone ? ride.scheduledDeparture : ride.departure)).font(BoardInk.sans(15)).foregroundStyle(Paper.ink).strikethrough(gone)
                    }
                    Text("→ \(Fmt.hhmm(ride.arrival))").font(BoardInk.sans(10.5, .regular)).foregroundStyle(Paper.ink.opacity(0.8))
                }
            }
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Paper.ink.opacity(0.12)).frame(height: 1) }
            .background(picked ? Paper.ink.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: the page for a line you tapped

/// Back to the board, and whether it's being tracked (tap to start or stop).
struct PageTop: View {
    let tracked: Bool
    let back: () -> Void
    let track: () -> Void
    var body: some View {
        HStack {
            Button(action: back) {
                Label("Board", systemImage: "chevron.left").font(BoardInk.sans(12)).foregroundStyle(Paper.ink)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Paper.ink.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: track) {
                HStack(spacing: 5) {
                    Circle().fill(tracked ? Color(hex: 0x062A16) : Color.white).frame(width: 7, height: 7)
                    Text(tracked ? "TRACKING" : "TRACK").font(BoardInk.sans(11)).tracking(0.8)
                }
                .foregroundStyle(tracked ? Color(hex: 0x062A16) : Color.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(tracked ? Paper.ok : Paper.ink.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tracked ? "Tracking. Tap to stop." : "Track it")
        }
    }
}

struct TrackingNote: View {
    let tracked: Bool
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tracked ? "Tracking this for you" : "Not tracked").font(BoardInk.sans(12))
            Text(tracked ? text : "Tap TRACK to get told when something changes.").font(BoardInk.sans(11, .regular)).opacity(0.85)
        }
        .foregroundStyle(Paper.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background((tracked ? Paper.ok : Color.white).opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// One train: when and where, how long it is and where 1st class is, how busy NS expects it, your ride, and the tracking.
struct TrainPage: View {
    let p: PanelTrip
    let info: RailInfo?
    let tracked: Bool
    let nsMissing: Bool
    let pal: HWPalette
    var walk: (() -> Void)? = nil       // the way to the station on foot
    var liveMap: (() -> Void)? = nil    // where the train is now, on a map
    let back: () -> Void
    let track: () -> Void

    var body: some View {
        let f = p.trip.first
        let st = RideText.status(f, info)
        let gone = f.cancelled || info?.cancelled == true
        VStack(alignment: .leading, spacing: 10) {
            PageTop(tracked: tracked, back: back, track: track)
            HStack(spacing: 8) {
                LineBullet(line: f.line, train: true, height: 26, minWidth: 42, font: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.headsign.isEmpty ? p.to.short : Fmt.place(f.headsign)).font(BoardInk.sans(22)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.6)
                    Text("\(f.num.isEmpty ? f.name : "\(f.name) \(f.num)") · from \(p.from.short)").font(BoardInk.sans(11, .regular))
                        .foregroundStyle(Paper.ink.opacity(0.8)).lineLimit(1)
                }
            }
            HStack(alignment: .center, spacing: 10) {
                Text(Fmt.hhmm(f.departure)).font(BoardInk.sans(32)).foregroundStyle(Paper.ink).strikethrough(gone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(st.text).font(BoardInk.sans(12)).foregroundStyle(st.warn ? Paper.late : st.ok ? Paper.ok : Paper.ink.opacity(0.85))
                        .lineLimit(2).minimumScaleFactor(0.8)
                    Text(leaves(f.departure)).font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.8))
                }
                Spacer(minLength: 4)
                VStack(spacing: 0) {
                    Text(info?.track ?? f.platform ?? "–").font(BoardInk.sans(26)).foregroundStyle(Paper.ink)
                    Text("PLATFORM").font(BoardInk.sans(8, .regular)).foregroundStyle(Paper.ink.opacity(0.75))
                }
            }
            HStack(spacing: 8) {
                if let liveMap { WalkButton(title: "See it live", icon: "location.viewfinder", go: liveMap) }
                if let walk { WalkButton(title: "Show the way to the station", go: walk) }
            }
            RankBlock(rank: RankInfo.of(p.trip), cancelled: gone)
            PlannerBar(title: "The train", sub: info?.size.map { "\($0.cars) coaches" })
            if let s = info?.size {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.text).font(BoardInk.sans(11, .regular)).foregroundStyle(s.warn ? Paper.late : Paper.ink.opacity(0.85))
                    if let l = s.layout { ConsistView(layout: l, pal: pal) }
                }
            } else {
                Text(nsMissing ? "Train details need the NS key in your relay (see the GitHub page)." : "NS hasn’t said how this train is made up yet.")
                    .font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.8))
            }
            PlannerBar(title: "How busy", sub: "NS forecast")
            if let c = info?.crowd, c > 0 {
                HStack(spacing: 8) {
                    Text(["", "Quiet", "Busy", "Very busy"][min(3, c)]).font(BoardInk.sans(15)).foregroundStyle(Paper.ink)
                    CrowdIcons(level: c).scaleEffect(1.4, anchor: .leading)
                }
            } else {
                Text("No forecast for this train.").font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.8))
            }
            PlannerBar(title: "Your ride", sub: p.trip.rideLabel)
            Text("Arrives \(p.to.short) \(Fmt.hhmm(p.trip.last.arrival))" + (p.trip.changes.isEmpty ? "" : " · change at \(p.trip.changes.joined(separator: ", "))"))
                .font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink)
            TrackingNote(tracked: tracked, text: "You get a note if the platform changes or it runs late. It stops by itself once you’re on board.")
        }
    }
}

/// One bus: when and from where, how it's doing, the ride, and the tracking of its line.
struct BusPage: View {
    let line: String
    let to: String
    let stop: String
    let time: Date
    let scheduled: Date
    let live: Bool
    let cancelled: Bool
    let status: String
    let ride: String?
    var rank: RankInfo? = nil
    var train = false
    var walk: (() -> Void)? = nil       // the way to the stop on foot
    var liveMap: (() -> Void)? = nil    // where it is now, on a map
    let tracked: Bool
    let back: () -> Void
    let track: () -> Void

    var body: some View {
        let g = rank?.grade
        VStack(alignment: .leading, spacing: 10) {
            PageTop(tracked: tracked, back: back, track: track)
            HStack(spacing: 8) {
                LineBullet(line: line, train: train, grade: g, height: 28, minWidth: 46, font: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(to).font(BoardInk.sans(22)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.6)
                    Text("\(train ? "Train" : "Bus") \(line) · from \(stop)").font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.8)).lineLimit(1)
                }
            }
            HStack(alignment: .center, spacing: 10) {
                Text(Fmt.hhmm(cancelled ? scheduled : time)).font(BoardInk.sans(32)).foregroundStyle(Paper.ink).strikethrough(cancelled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status).font(BoardInk.sans(12)).foregroundStyle(cancelled || (live && abs(time.timeIntervalSince(scheduled)) >= 60) ? Paper.late : live ? Paper.ok : Paper.ink.opacity(0.85))
                        .lineLimit(2).minimumScaleFactor(0.8)
                    Text(leaves(time)).font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.8))
                }
            }
            HStack(spacing: 8) {
                if let liveMap { WalkButton(title: "See it live", icon: "location.viewfinder", go: liveMap) }
                if let walk { WalkButton(title: "Show the way to the stop", go: walk) }
            }
            if let rank { RankBlock(rank: rank, cancelled: cancelled) }
            if let ride {
                PlannerBar(title: "Your ride")
                Text(ride).font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink)
            }
            PlannerBar(title: "How busy")
            Text(train ? "There’s no busyness forecast for this train here." : "There’s no busyness forecast for buses.").font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.8))
            TrackingNote(tracked: tracked, text: "Watching the \(line): you’re told when the next one runs late, leaves early or is cancelled, until you’re on it.")
        }
    }
}

/// "leaves in 13 min", "left 4 min ago"
private func leaves(_ d: Date) -> String {
    let m = Int((d.timeIntervalSinceNow / 60).rounded())
    if m <= -1 { return "left \(-m) min ago" }
    return m == 0 ? "leaves now" : "leaves in \(m) min"
}

// MARK: going somewhere you pick

/// Pick where you're going yourself: search a stop, station or town, or take one of your recent ones.
struct DestinationSheet: View {
    @EnvironmentObject var live: LiveStore
    @Environment(\.dismiss) private var dismiss
    let picked: (Destination) -> Void
    @State private var q = ""
    @State private var hits: [Transit.StopHit] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("A stop, station or town", text: $q)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                }
                if !hits.isEmpty {
                    Section("Stops and stations") {
                        ForEach(hits) { h in
                            Button { pick(Destination(id: h.id, name: h.name, lat: h.lat, lon: h.lon)) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.name).font(BoardInk.sans(15)).foregroundStyle(Paper.ink)
                                    if !h.town.isEmpty { Text(h.town).font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.7)) }
                                }
                            }
                        }
                    }
                } else if searching {
                    Section { ProgressView() }
                }
                if !live.recents.isEmpty {
                    Section("Recent") {
                        ForEach(live.recents) { d in
                            Button { pick(d) } label: { Text(d.name).font(BoardInk.sans(15)).foregroundStyle(Paper.ink) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PaperFill().ignoresSafeArea()).preferredColorScheme(.light)
            .navigationTitle("Where to?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: q) {
                let t = q.trimmingCharacters(in: .whitespaces)
                guard t.count >= 2 else { hits = []; searching = false; return }
                searching = true
                try? await Task.sleep(nanoseconds: 350_000_000)             // wait until you stop typing
                guard !Task.isCancelled else { return }
                let r = await Transit.findStops(t)
                guard !Task.isCancelled else { return }
                hits = r; searching = false
            }
        }
    }

    private func pick(_ d: Destination) { picked(d); dismiss() }
}
