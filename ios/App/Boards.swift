import SwiftUI

// The boards on the station wall, a few steps from the map: a slim amber LED strip with the trains, and under it the
// blue journey planner (your trip, the buses, and the other parts). The app writes on them exactly where they are in
// the last frame of the walk from the map.

/// Where the two screens sit at the end of the walk (share of the 540 × 1170 picture). The LED rectangle includes its
/// blue title strip.
enum WallBoards {
    static let led = CGRect(x: 0.0246, y: 0.1175, width: 0.9508, height: 0.1372)
    static let planner = CGRect(x: 0.0496, y: 0.2797, width: 0.9008, height: 0.6828)
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
    static let strip = Color(hex: 0x1F4FA0)
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
        case .fastest: return "FASTEST"
        case .lines: return "ALL LINES"
        case .planned: return "PLANNED"
        case .more: return "MORE"
        }
    }
}

/// What you tapped on a board: its page shows on the planner.
enum BoardPick: Hashable {
    case train(PanelTrip)
    case bus(BoardDeparture)
    case busTrip(PanelTrip)
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
            let stripH = g.size.height * 0.16
            VStack(spacing: 0) {
                HStack {
                    Text("Departures")
                    Spacer(minLength: 4)
                    Text(title)
                }
                .font(BoardInk.sans(10.5 * k)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 8 * k)
                .frame(height: stripH)
                .frame(maxWidth: .infinity)
                .background(BoardInk.strip)
                .overlay(alignment: .top) { Color(hex: 0x5F8FD8).frame(height: max(1, stripH * 0.08)) }
                TimelineView(.periodic(from: .now, by: 8)) { tl in
                    let pages = max(1, (rows.count + perPage - 1) / perPage)
                    let page = Int(tl.date.timeIntervalSinceReferenceDate / 8) % pages
                    let shown = Array(rows.dropFirst(page * perPage).prefix(perPage))
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
                    .overlay(Rectangle().stroke(Color.white.opacity(r.picked ? 0.9 : 0), lineWidth: 1))
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
            HStack(spacing: 4) {
                ForEach(HomeSection.board) { s in
                    Button { pick(s) } label: {
                        Text(s.tab).font(BoardInk.sans(11)).lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(s == section ? BoardInk.blueBottom : Color.white.opacity(0.85))
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .background(s == section ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(s == section ? .isSelected : [])
                }
                Spacer(minLength: 2)
                TimelineView(.everyMinute) { tl in
                    Text(Fmt.hhmm(tl.date)).font(BoardInk.sans(12)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 34)
            .background(BoardInk.band)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .background(LinearGradient(colors: [BoardInk.blueTop, BoardInk.blueBottom], startPoint: .top, endPoint: .bottom))
        .clipped()
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
        .foregroundStyle(BoardInk.navy)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(BoardInk.bar)
    }
}

/// A stop's name, with the yellow bus dot.
struct PlannerStop: View {
    let name: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bus.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(BoardInk.navy)
                .frame(width: 15, height: 15).background(BoardInk.yellow, in: Circle())
            Text(name).font(BoardInk.sans(13)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
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
        .font(BoardInk.sans(9.5, .semibold)).foregroundStyle(Color.white.opacity(0.72))
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
    var note: String? = nil
    let watched: Bool
    let picked: Bool
    let tap: () -> Void

    var body: some View {
        let gone = !cancelled && time < Date().addingTimeInterval(-60)
        let late = live && !cancelled && abs(time.timeIntervalSince(scheduled)) >= 60
        Button(action: tap) {
            HStack(spacing: 0) {
                Text(line).font(BoardInk.sans(13)).foregroundStyle(BoardInk.navy).lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: 38, height: 20).background(BoardInk.route, in: RoundedRectangle(cornerRadius: 2))
                    .padding(.trailing, 8)
                if cancelled {
                    Text("Cancelled · \(to)").font(BoardInk.sans(12)).foregroundStyle(BoardInk.navy).lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 20, alignment: .leading).background(Color.white)
                    Text("×\(Fmt.hhmm(scheduled))").font(BoardInk.sans(13)).foregroundStyle(.white).frame(width: 76, alignment: .trailing)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(to).font(BoardInk.sans(14)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                        if let note { Text(note).font(BoardInk.sans(9.5, .regular)).foregroundStyle(Color.white.opacity(0.75)).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    if watched { Image(systemName: "bell.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(BoardInk.yellow).padding(.trailing, 4) }
                    Text(due(gone)).font(BoardInk.sans(14)).foregroundStyle(.white).frame(width: 40, alignment: .trailing)
                    if late {
                        HStack(spacing: 4) {
                            Text(Fmt.hhmm(scheduled)).font(BoardInk.sans(10, .regular)).foregroundStyle(Color.white.opacity(0.7))
                            Text(Fmt.hhmm(time)).font(BoardInk.sans(12)).foregroundStyle(BoardInk.navy)
                                .padding(.horizontal, 4).padding(.vertical, 1).background(Color.white, in: RoundedRectangle(cornerRadius: 2))
                        }
                        .frame(width: 76, alignment: .trailing)
                    } else {
                        Text(Fmt.hhmm(time)).font(BoardInk.sans(13)).foregroundStyle(.white).frame(width: 76, alignment: .trailing)
                    }
                }
            }
            .padding(.vertical, 5)
            .opacity(gone ? 0.45 : 1)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1) }
            .background(picked ? Color.white.opacity(0.12) : Color.clear)
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
    let wake: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your trip · fastest").font(BoardInk.sans(13))
                Spacer(minLength: 4)
                Text("\(home ? "home" : "at BUas") \(Fmt.hhmm(trip.end))").font(BoardInk.sans(13))
            }
            .foregroundStyle(BoardInk.navy)
            HStack(spacing: 5) {
                ForEach(Array(trip.rides.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Rectangle().fill(Color(hex: 0x9FB1D6)).frame(width: 8, height: 2) }
                    HStack(spacing: 4) {
                        Text(r.line).font(BoardInk.sans(11)).foregroundStyle(BoardInk.navy).lineLimit(1).minimumScaleFactor(0.6)
                            .frame(width: 30, height: 17).background(r.isTrain ? BoardInk.yellow : BoardInk.route, in: RoundedRectangle(cornerRadius: 2))
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
                        .frame(maxWidth: .infinity).padding(.vertical, 7).background(Color(hex: 0x2F9E5B), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
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
                Label("Board", systemImage: "chevron.left").font(BoardInk.sans(12)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Color.white.opacity(0.14), in: Capsule())
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
                .background(tracked ? BoardInk.green : Color.white.opacity(0.14), in: Capsule())
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
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background((tracked ? BoardInk.green : Color.white).opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// One train: when and where, how long it is and where 1st class is, how busy NS expects it, your ride, and the tracking.
struct TrainPage: View {
    let p: PanelTrip
    let info: RailInfo?
    let tracked: Bool
    let nsMissing: Bool
    let pal: HWPalette
    let back: () -> Void
    let track: () -> Void

    var body: some View {
        let f = p.trip.first
        let st = RideText.status(f, info)
        let gone = f.cancelled || info?.cancelled == true
        VStack(alignment: .leading, spacing: 10) {
            PageTop(tracked: tracked, back: back, track: track)
            HStack(spacing: 8) {
                Text(f.line).font(BoardInk.sans(14)).foregroundStyle(BoardInk.navy).lineLimit(1)
                    .frame(minWidth: 38).padding(.vertical, 3).padding(.horizontal, 4).background(Color.white, in: RoundedRectangle(cornerRadius: 2))
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.headsign.isEmpty ? p.to.short : Fmt.place(f.headsign)).font(BoardInk.sans(22)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    Text("\(f.num.isEmpty ? f.name : "\(f.name) \(f.num)") · from \(p.from.short)").font(BoardInk.sans(11, .regular))
                        .foregroundStyle(Color.white.opacity(0.8)).lineLimit(1)
                }
            }
            HStack(alignment: .center, spacing: 10) {
                Text(Fmt.hhmm(f.departure)).font(BoardInk.sans(32)).foregroundStyle(.white).strikethrough(gone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(st.text).font(BoardInk.sans(12)).foregroundStyle(st.warn ? BoardInk.late : st.ok ? BoardInk.green : Color.white.opacity(0.85))
                        .lineLimit(2).minimumScaleFactor(0.8)
                    Text(leaves(f.departure)).font(BoardInk.sans(11, .regular)).foregroundStyle(Color.white.opacity(0.8))
                }
                Spacer(minLength: 4)
                VStack(spacing: 0) {
                    Text(info?.track ?? f.platform ?? "–").font(BoardInk.sans(26)).foregroundStyle(.white)
                    Text("PLATFORM").font(BoardInk.sans(8, .regular)).foregroundStyle(Color.white.opacity(0.75))
                }
            }
            PlannerBar(title: "The train", sub: info?.size.map { "\($0.cars) coaches" })
            if let s = info?.size {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.text).font(BoardInk.sans(11, .regular)).foregroundStyle(s.warn ? BoardInk.late : Color.white.opacity(0.85))
                    if let l = s.layout { ConsistView(layout: l, pal: pal) }
                }
            } else {
                Text(nsMissing ? "Train details need the NS key in your relay (see the GitHub page)." : "NS hasn’t said how this train is made up yet.")
                    .font(BoardInk.sans(11, .regular)).foregroundStyle(Color.white.opacity(0.8))
            }
            PlannerBar(title: "How busy", sub: "NS forecast")
            if let c = info?.crowd, c > 0 {
                HStack(spacing: 8) {
                    Text(["", "Quiet", "Busy", "Very busy"][min(3, c)]).font(BoardInk.sans(15)).foregroundStyle(.white)
                    CrowdIcons(level: c).scaleEffect(1.4, anchor: .leading)
                }
            } else {
                Text("No forecast for this train.").font(BoardInk.sans(11, .regular)).foregroundStyle(Color.white.opacity(0.8))
            }
            PlannerBar(title: "Your ride", sub: p.trip.rideLabel)
            Text("Arrives \(p.to.short) \(Fmt.hhmm(p.trip.last.arrival))" + (p.trip.changes.isEmpty ? "" : " · change at \(p.trip.changes.joined(separator: ", "))"))
                .font(BoardInk.sans(12, .regular)).foregroundStyle(.white)
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
    let tracked: Bool
    let back: () -> Void
    let track: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageTop(tracked: tracked, back: back, track: track)
            HStack(spacing: 8) {
                Text(line).font(BoardInk.sans(15)).foregroundStyle(BoardInk.navy).lineLimit(1)
                    .frame(width: 44, height: 26).background(BoardInk.route, in: RoundedRectangle(cornerRadius: 2))
                VStack(alignment: .leading, spacing: 1) {
                    Text(to).font(BoardInk.sans(22)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    Text("Bus \(line) · from \(stop)").font(BoardInk.sans(11, .regular)).foregroundStyle(Color.white.opacity(0.8)).lineLimit(1)
                }
            }
            HStack(alignment: .center, spacing: 10) {
                Text(Fmt.hhmm(cancelled ? scheduled : time)).font(BoardInk.sans(32)).foregroundStyle(.white).strikethrough(cancelled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status).font(BoardInk.sans(12)).foregroundStyle(cancelled || (live && abs(time.timeIntervalSince(scheduled)) >= 60) ? BoardInk.late : live ? BoardInk.green : Color.white.opacity(0.85))
                        .lineLimit(2).minimumScaleFactor(0.8)
                    Text(leaves(time)).font(BoardInk.sans(11, .regular)).foregroundStyle(Color.white.opacity(0.8))
                }
            }
            if let ride {
                PlannerBar(title: "Your ride")
                Text(ride).font(BoardInk.sans(12, .regular)).foregroundStyle(.white)
            }
            PlannerBar(title: "How busy")
            Text("There’s no busyness forecast for buses.").font(BoardInk.sans(11, .regular)).foregroundStyle(Color.white.opacity(0.8))
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
