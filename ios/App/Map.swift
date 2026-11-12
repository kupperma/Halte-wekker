import CoreLocation
import SwiftUI

// The home screen starts face to face with a metro map hanging on the station wall. Pick a line on it and
// you step back from the wall and turn to the platform, where that part of the app opens.

enum HomeSection: String, Identifiable {
    case fastest, lines, planned, more
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fastest: return "Fastest trip"
        case .lines: return "All lines"
        case .planned: return "Planned trip"
        case .more: return "More"
        }
    }
}

enum StageMode: Equatable { case map, leaving, station, returning }

/// Where the map hangs in the first frame of the camera move (share of the 540 × 1170 picture).
enum MapSpot {
    static let x0 = 0.0353, x1 = 0.9647, y0 = 0.1516, y1 = 0.8484
    static let design = CGSize(width: 346, height: 562)
    static let video = CGSize(width: 540, height: 1170)
    /// Where the 540 × 1170 picture sits on a screen of this size: it fills the screen and is cropped evenly.
    /// The videos, the stills and the app's own map and board are all placed from this one rectangle, so they line up.
    static func picture(in size: CGSize) -> CGRect {
        let s = max(size.width / video.width, size.height / video.height)
        let vw = video.width * s, vh = video.height * s
        return CGRect(x: (size.width - vw) / 2, y: (size.height - vh) / 2, width: vw, height: vh)
    }
    /// The map's rectangle on a screen of this size.
    static func rect(in size: CGSize) -> CGRect {
        let v = picture(in: size)
        return CGRect(x: v.minX + x0 * v.width, y: v.minY + y0 * v.height, width: (x1 - x0) * v.width, height: (y1 - y0) * v.height)
    }
}

/// The hanging board over the platform in the station video: the app writes your next transfers on it.
enum BoardSpot {
    static let x0 = 0.3512, x1 = 0.7119, y0 = 0.3102, y1 = 0.3679
    static let design = CGSize(width: 298, height: 100)
    static func rect(in size: CGSize) -> CGRect {
        let v = MapSpot.picture(in: size)
        return CGRect(x: v.minX + x0 * v.width, y: v.minY + y0 * v.height, width: (x1 - x0) * v.width, height: (y1 - y0) * v.height)
    }
}

struct BoardLine: Hashable {
    let line: String
    let to: String
    let time: String
    let note: String?
}

/// Amber and white on dark blue, like a station display.
struct TransferBoard: View {
    let rows: [BoardLine]
    var body: some View {
        let amber = Color(hex: 0xFFB43A)
        VStack(alignment: .leading, spacing: 3) {
            Text("NEXT TRANSFERS").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(amber)
            Rectangle().fill(amber.opacity(0.35)).frame(height: 1.2)
            ForEach(Array(rows.prefix(3).enumerated()), id: \.offset) { _, r in
                HStack(spacing: 6) {
                    Text(r.line).frame(width: 40, alignment: .leading)
                    Text(r.to).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 2)
                    Text(r.time)
                    if let n = r.note { Text(n).foregroundStyle(amber).frame(width: 30, alignment: .trailing) }
                }
                .font(.system(size: 13.5, weight: .bold, design: .monospaced)).foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: BoardSpot.design.width, height: BoardSpot.design.height, alignment: .topLeading)
        .background(Color(hex: 0x06122B))
        .shadow(color: Color(hex: 0x6FA0FF).opacity(0.35), radius: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next transfers: " + rows.map { "\($0.line) to \($0.to) at \($0.time)" }.joined(separator: ", "))
    }
}

// MARK: the stage behind it all

struct HomeStage<Menu: View, Boards: View>: View {
    let home: Bool
    let stage: StageMode
    let moveToken: Int
    let menu: Menu
    let boards: (CGRect, CGRect) -> Boards

    /// `boards` gets where the LED strip and the planner are on screen, and draws on them.
    init(home: Bool, stage: StageMode, moveToken: Int, @ViewBuilder menu: () -> Menu, @ViewBuilder boards: @escaping (CGRect, CGRect) -> Boards) {
        self.home = home; self.stage = stage; self.moveToken = moveToken; self.menu = menu(); self.boards = boards
    }

    var body: some View {
        // Everything is laid out in one frame: the whole screen, with the picture placed by MapSpot.picture.
        // (Each layer gets that exact rectangle, so what the app draws can't drift off the boards and the map in the video.)
        GeometryReader { g in
            let v = MapSpot.picture(in: g.size)
            // the two sheets on the wall: the trains at the top, the boards under it, both clear of the clock and the buttons
            let ins = ScreenInsets.now
            let top = ins.top + 60
            let led = CGRect(x: 12, y: top, width: g.size.width - 24, height: 236)
            let plan = CGRect(x: 12, y: led.maxY + 20, width: g.size.width - 24, height: max(200, g.size.height - led.maxY - 20 - ins.bottom - 2))
            let away = stage != .map
            ZStack(alignment: .topLeading) {
                HWPalette.bg
                // the blue wall, with the sheets pinned on it
                WallBackground().frame(width: g.size.width, height: g.size.height)
                WallSticker(text: "306 ♥", angle: -7).position(x: g.size.width / 2 + 6, y: led.maxY + 10)
                    .opacity(stage == .station ? 1 : 0)
                // face to face with the map
                ForEach([false, true], id: \.self) { h in
                    still(h ? "map-home" : "map-out")
                        .frame(width: v.width, height: v.height).position(x: v.midX, y: v.midY)
                        .opacity(stage == .map && h == home ? 1 : 0)
                    .scaleEffect(away ? 0.94 : 1)
                }
                .animation(.easeOut(duration: 0.3), value: stage)
                .animation(.easeInOut(duration: 0.6), value: home)
                // the live trains and your trip, on paper: they drop onto the wall as the map comes down
                boards(led, plan)
                    .frame(width: g.size.width, height: g.size.height)
                    .opacity(stage == .station ? 1 : 0)
                    .offset(y: stage == .station ? 0 : -28)
                    .rotationEffect(.degrees(stage == .station ? 0 : -1.2))
                    .allowsHitTesting(stage == .station)
                    .animation(.spring(response: 0.45, dampingFraction: 0.82), value: stage)
                // the app's own map, exactly over the one on the wall
                let r = MapSpot.rect(in: g.size)
                menu
                    .scaleEffect(r.width / MapSpot.design.width, anchor: .topLeading)
                    .frame(width: r.width, height: r.height, alignment: .topLeading)
                    .position(x: r.midX, y: r.midY)
                    .opacity(stage == .map ? 1 : 0)
                    .allowsHitTesting(stage == .map)
                    .animation(stage == .map ? .easeOut(duration: 0.3) : nil, value: stage)
                // a light grain over everything, the app's boards and map too, so they sit in the same picture
                FilmGrain(strength: 0.07).frame(width: g.size.width, height: g.size.height).clipped()
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
    }

    private func still(_ name: String) -> some View {
        Group {
            if let img = UIImage(named: name) ?? Bundle.main.path(forResource: name, ofType: "jpg").flatMap(UIImage.init(contentsOfFile:)) {
                Image(uiImage: img).resizable()
            }
        }
    }
}

// MARK: the map (Berlin style: white paper, bold colour lines at 45°, white interchange markers, line badges)

private enum MapInk {
    static let paper = Color(hex: 0xF7F5EF)
    static let text = Color(hex: 0x1D1D1B)
    static let grey = Color(hex: 0x6B6B6B)
    static let soft = Color(hex: 0x8A877F)
    static let rule = Color(hex: 0xDDD9CE)
    static func sans(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w) }
}

/// Wear and tear: the same stains, smudges, scratches, coffee ring and tape as the map on the wall.
private let mapGrime: UIImage? = Bundle.main.path(forResource: "map-grime", ofType: "png").flatMap(UIImage.init(contentsOfFile:))
private let mapSticker: UIImage? = Bundle.main.path(forResource: "sticker-smile", ofType: "png").flatMap(UIImage.init(contentsOfFile:))

/// Your commute as a metro map: the rail corridor Breda–Tilburg–Boxtel with both Intercitys side by side, splitting
/// at Boxtel to Den Bosch and to Eindhoven, the 306 and 305 to Veghel and the bus to BUas. Your fastest route glows yellow.
struct NetworkMap: View {
    let via: String?
    var body: some View {
        Canvas { ctx, _ in
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
            func stroke(_ pts: [CGPoint], _ c: Color, _ w: CGFloat) {
                var p = Path(); p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
            let TR: CGFloat = 118, D: CGFloat = 3.5
            let dark = Color(hex: 0x224F86), light = Color(hex: 0x528DBA)
            let glow = Color(red: 1, green: 0.84, blue: 0.25).opacity(0.55)
            if via == "Eindhoven" { stroke([P(34, TR), P(196, TR), P(258, 180), P(300, 138)], glow, 14) }
            else { stroke([P(34, TR), P(196, TR), P(244, 70), P(252, 70), P(300, 118), P(300, 138)], glow, 14) }
            stroke([P(34, TR), P(34, 176)], glow, 14)
            stroke([P(244, 70), P(244, 44)], dark, 5); stroke([P(258, 180), P(288, 180)], light, 5)       // to Utrecht, to Venlo
            stroke([P(34, TR - D), P(196, TR - D), P(244, 70)], dark, 5)
            stroke([P(34, TR + D), P(196, TR + D), P(258, 180)], light, 5)
            stroke([P(244, 70), P(252, 70), P(300, 118), P(300, 138)], Color(hex: 0xDA421E), 5)
            stroke([P(258, 180), P(300, 138)], Color(hex: 0xF3791D), 5)
            stroke([P(34, TR), P(34, 176)], Color(hex: 0x8C6DAB), 5)
            // ticks for the small stations
            func tick(_ a: CGFloat, _ b: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
                var p = Path(); p.move(to: P(a, b)); p.addLine(to: P(a + dx, b + dy))
                ctx.stroke(p, with: .color(MapInk.text), lineWidth: 2)
            }
            for a in [62, 88, 142, 168] as [CGFloat] { tick(a, TR - D - 2.5, 0, -5) }
            tick(220, 94, -3.5, -3.5); tick(218, 140, 3.5, -3.5); tick(238, 160, 3.5, -3.5)
            func pill(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) {
                let o = Path(roundedRect: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), cornerRadius: min(w, h) / 2)
                ctx.fill(o, with: .color(.white)); ctx.stroke(o, with: .color(MapInk.text), lineWidth: 2)
            }
            func ring(_ c: CGPoint, _ r: CGFloat) {
                let o = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(o, with: .color(.white)); ctx.stroke(o, with: .color(MapInk.text), lineWidth: 2)
            }
            pill(P(34, TR), 12, 20); pill(P(116, TR), 12, 20); pill(P(196, TR), 12, 20)
            ring(P(244, 70), 6); ring(P(258, 180), 6); ring(P(300, 138), 6.5); ring(P(34, 176), 5.5)
            func name(_ t: String, _ at: CGPoint, _ anchor: UnitPoint, _ size: CGFloat = 10.5, _ w: Font.Weight = .bold) {
                ctx.draw(Text(t).font(MapInk.sans(size, w)).foregroundColor(MapInk.text), at: at, anchor: anchor)
            }
            func angled(_ t: String, _ at: CGPoint) {
                var c = ctx; c.translateBy(x: at.x, y: at.y); c.rotate(by: .degrees(-45))
                c.draw(Text(t).font(MapInk.sans(8.6, .medium)).foregroundColor(MapInk.text), at: .zero, anchor: .leading)
            }
            name("Breda", P(34, 104), .bottom, 11); name("BUas", P(43, 176), .leading)
            angled("Gilze-Rijen", P(64, TR - 11)); angled("Tilburg Reeshof", P(90, TR - 11)); angled("Tilburg Univ.", P(144, TR - 11)); angled("Oisterwijk", P(170, TR - 11))
            name("Tilburg", P(116, 131), .top); name("Boxtel", P(190, 131), .topTrailing, 10)
            name("Vught", P(227, 96), .leading, 9); name("Den Bosch", P(236, 63), .trailing); name("Utrecht", P(244, 40), .bottom, 8.6, .medium)
            name("Best", P(224, 139), .leading, 9); name("Beukenlaan", P(232, 164), .trailing, 9); name("Eindhoven", P(258, 192), .top)
            name("Venlo", P(292, 180), .leading, 8.6, .medium); name("Veghel", P(292, 138), .trailing)
            func badge(_ t: String, _ c: CGPoint, _ col: Color) {
                let w = CGFloat(t.count) * 6.6 + 9
                ctx.fill(Path(CGRect(x: c.x - w / 2, y: c.y - 7, width: w, height: 14)), with: .color(col))
                ctx.draw(Text(t).font(MapInk.sans(9, .bold)).foregroundColor(.white), at: P(c.x, c.y + 0.5), anchor: .center)
            }
            badge("IC", P(262, 48), dark); badge("IC", P(246, 128), light); badge("306", P(286, 84), Color(hex: 0xDA421E))
            badge("305", P(290, 166), Color(hex: 0xF3791D)); badge("BUS", P(52, 152), Color(hex: 0x8C6DAB))
        }
        .frame(width: 318, height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Metro map: the train from Breda via Tilburg to Boxtel, then to Den Bosch or Eindhoven; bus 306 from Den Bosch and bus 305 from Eindhoven to Veghel; the bus from Breda to BUas.")
    }
}

/// The map on the wall: the direction, your network and the lines you can pick (the app's menu).
struct MetroMapMenu: View {
    let home: Bool
    let fastest: String
    let lines: String
    let planned: String
    let via: String?
    var custom: String? = nil           // somewhere you picked yourself: the map is drawn for that trip
    var trip: DoorTrip? = nil
    var others: [DoorTrip] = []
    let open: (HomeSection) -> Void
    let toggle: () -> Void
    let settings: () -> Void

    private var accent: Color { home ? Color(hex: 0x7A2A1E) : Color(hex: 0x1D2C5A) }

    var body: some View {
        let pal = HWPalette.of(home: home)
        ZStack(alignment: .topLeading) {
            MapInk.paper
            Rectangle().stroke(Color(hex: 0xC9C4B6), lineWidth: 1).padding(3)
            // the title band, in the colour of where you're going
            accent.frame(width: MapSpot.design.width, height: 64)
            Text("Haltewekker").font(MapInk.sans(24, .bold)).foregroundStyle(.white).offset(x: 20, y: 12)
            Text(custom.map { "Network map · \(trip.map { Fmt.place($0.first.fromStop) } ?? "here") ⇄ \($0)" } ?? "Network map · Veghel ⇄ Breda")
                .font(MapInk.sans(10.5)).foregroundStyle(.white.opacity(0.78)).lineLimit(1).frame(width: 270, alignment: .leading).offset(x: 20, y: 43)
            Button(action: settings) {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).overlay(Circle().stroke(.white, lineWidth: 1.5))
            }
            .buttonStyle(.plain).offset(x: 299, y: 17).accessibilityLabel("Settings")
            Button(action: toggle) {
                HStack(spacing: 6) {
                    if let c = custom {
                        directionBadge("TO \(c.uppercased())", on: true)
                        directionBadge(home ? "TO BREDA" : "HOME", on: false)
                        Text("made for where you’re going").font(MapInk.sans(9)).foregroundStyle(MapInk.soft).lineLimit(2).frame(width: 80, alignment: .leading)
                    } else {
                        directionBadge("TO BREDA", on: !home)
                        directionBadge("HOME", on: home)
                        Text("tap to switch").font(MapInk.sans(9.5)).foregroundStyle(MapInk.soft).padding(.leading, 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).offset(x: 20, y: 72)
            .accessibilityLabel(home ? "Going home. Tap to switch to going to Breda." : "Going to Breda. Tap to switch to going home.")
            Group {
                if custom != nil {
                    if let trip { TripNetworkMap(trip: trip, others: others) }
                    else {
                        Text("Drawing the map to \(custom ?? "")…").font(MapInk.sans(12)).foregroundStyle(MapInk.soft).frame(width: 318, height: 220)
                    }
                } else {
                    NetworkMap(via: via)
                }
            }
            .offset(x: 14, y: 108)
            Text("PICK A LINE").font(MapInk.sans(9, .bold)).tracking(0.4).foregroundStyle(MapInk.soft).offset(x: 20, y: 334)
            row(.fastest, letter: "F", fill: Color(hex: 0xF0D722), ink: MapInk.text, sub: fastest, y: 350)
            row(.lines, letter: "A", fill: Color(hex: 0x7DAD4C), ink: .white, sub: lines, y: 408)
            row(.planned, letter: "P", fill: Color(hex: 0x7E5330), ink: .white, sub: planned, y: 466)
            Button { open(.more) } label: {
                HStack(spacing: 8) {
                    Text("M").font(MapInk.sans(10, .bold)).foregroundStyle(.white).frame(width: 22, height: 16)
                        .background(Color(hex: 0x8E8E8E), in: RoundedRectangle(cornerRadius: 3))
                    Text("More · leaderboard, single stop, tips").font(MapInk.sans(10.5)).foregroundStyle(Color(hex: 0x3A3A38))
                }
                .padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain).offset(x: 20, y: 520)
            Text("Not to scale").font(MapInk.sans(8)).foregroundStyle(Color(hex: 0x9A968C))
                .frame(width: 306, alignment: .trailing).offset(x: 20, y: 543)
            if let g = mapGrime {
                Image(uiImage: g).resizable().frame(width: MapSpot.design.width, height: MapSpot.design.height).allowsHitTesting(false)
            }
            // A sticker someone slapped on the glass over the corner of the map: the same one, in the same spot, as in
            // the station video (centre 336, 8; 33 wide; turned 0.3 rad), so it sits on top of the menu and hangs over the frame.
            if let s = mapSticker {
                Image(uiImage: s).resizable().frame(width: 33.3, height: 33.3)
                    .rotationEffect(.radians(0.3))
                    .offset(x: 336 - 16.65, y: 8 - 16.65)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: MapSpot.design.width, height: MapSpot.design.height)
        .background(Rectangle().fill(home ? Color(hex: 0x2E1A12) : Color(hex: 0x162438)).padding(-3))
    }

    private func directionBadge(_ t: String, on: Bool) -> some View {
        Text(t).font(MapInk.sans(12.5, .bold)).foregroundStyle(on ? .white : MapInk.soft).lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 4)
            .frame(width: 100, height: 28)
            .background(on ? accent : .clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? .clear : Color(hex: 0xB9B5AA), lineWidth: 1.2))
    }

    private func row(_ s: HomeSection, letter: String, fill: Color, ink: Color, sub: String, y: CGFloat) -> some View {
        Button { open(s) } label: {
            HStack(spacing: 12) {
                Text(letter).font(MapInk.sans(16, .bold)).foregroundStyle(ink)
                    .frame(width: 40, height: 28).background(fill, in: RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(MapInk.sans(16, .bold)).foregroundStyle(MapInk.text)
                    Text(sub).font(MapInk.sans(10.5)).foregroundStyle(MapInk.grey).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(MapInk.soft)
            }
            .padding(.leading, 6).padding(.trailing, 8)
            .frame(width: 318, height: 50)
            .overlay(alignment: .bottom) { Rectangle().fill(MapInk.rule).frame(height: 1).padding(.leading, 6) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: 14, y: y + 2)
        .accessibilityLabel("\(s.title). \(sub)")
    }
}


// MARK: a network map drawn for any trip

/// The metro map for somewhere you picked yourself, drawn from the trip: the stations where you get on, change and
/// arrive, joined by each ride in its line's colour, at 45° like the map on the wall (lengths follow the real distance,
/// squeezed so long rides don't take over). The other ways go fainter beside it, sharing the stations they share.
struct TripNetworkMap: View {
    let trip: DoorTrip
    let others: [DoorTrip]

    private struct Station { let name: String; let c: CLLocationCoordinate2D }
    private struct Piece { let a: Int; let b: Int; let line: String; let train: Bool; let main: Bool }

    /// Stations (by name) and the rides between them.
    private var graph: (stations: [Station], pieces: [Piece], dest: Int) {
        var st: [Station] = [], pieces: [Piece] = []
        func idx(_ name: String, _ lat: Double?, _ lon: Double?) -> Int? {
            let n = Fmt.place(name)
            if let i = st.firstIndex(where: { $0.name == n }) { return i }
            guard let lat, let lon else { return nil }
            st.append(Station(name: n, c: .init(latitude: lat, longitude: lon))); return st.count - 1
        }
        func add(_ t: DoorTrip, main: Bool) {
            for r in t.rides {
                guard let a = idx(r.fromStop, r.fromLat, r.fromLon), let b = idx(r.toStop, r.toLat, r.toLon), a != b else { continue }
                if !pieces.contains(where: { $0.a == a && $0.b == b && $0.line == r.line }) { pieces.append(Piece(a: a, b: b, line: r.line, train: r.isTrain, main: main)) }
            }
        }
        add(trip, main: true)
        let dest = idx(trip.last.toStop, trip.last.toLat, trip.last.toLon) ?? max(0, st.count - 1)
        for o in others.prefix(2) where o.id != trip.id { add(o, main: false) }
        return (st, pieces, dest)
    }

    /// Where each station goes: along the main trip first, each step at the nearest 45° to its real direction.
    private func layout(_ g: (stations: [Station], pieces: [Piece], dest: Int)) -> [CGPoint?] {
        var pos = [CGPoint?](repeating: nil, count: g.stations.count)
        guard !g.stations.isEmpty else { return pos }
        pos[0] = .zero
        func step(_ a: Int, _ b: Int) -> CGPoint {
            let p = g.stations[a].c, q = g.stations[b].c
            let dx = (q.longitude - p.longitude) * 111_320 * cos(p.latitude * .pi / 180), dy = (q.latitude - p.latitude) * 110_540
            let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = sqrt(max(1, hypot(dx, dy)) / 1000)          // km, squeezed
            return CGPoint(x: cos(ang) * len, y: -sin(ang) * len)
        }
        // keep going until every station that can be reached has a place (main pieces first)
        for _ in 0..<3 {
            for piece in g.pieces.sorted(by: { $0.main && !$1.main }) {
                if let pa = pos[piece.a], pos[piece.b] == nil { let d = step(piece.a, piece.b); pos[piece.b] = CGPoint(x: pa.x + d.x, y: pa.y + d.y) }
                else if let pb = pos[piece.b], pos[piece.a] == nil { let d = step(piece.a, piece.b); pos[piece.a] = CGPoint(x: pb.x - d.x, y: pb.y - d.y) }
            }
        }
        return pos
    }

    var body: some View {
        let g = graph
        let raw = layout(g)
        let pts = raw.compactMap { $0 }
        let minX = pts.map(\.x).min() ?? 0, maxX = pts.map(\.x).max() ?? 1
        let minY = pts.map(\.y).min() ?? 0, maxY = pts.map(\.y).max() ?? 1
        let W: CGFloat = 318, H: CGFloat = 220, mx: CGFloat = 64, my: CGFloat = 26
        let sc = min((W - 2 * mx) / max(0.01, maxX - minX), (H - 2 * my) / max(0.01, maxY - minY))
        let ox = (W - (maxX - minX) * sc) / 2, oy = (H - (maxY - minY) * sc) / 2
        let at: (Int) -> CGPoint? = { i in raw[i].map { CGPoint(x: ox + ($0.x - minX) * sc, y: oy + ($0.y - minY) * sc) } }
        return Canvas { ctx, _ in
            // the other ways first, fainter; then your trip on top
            for piece in g.pieces.sorted(by: { !$0.main && $1.main }) {
                guard let a = at(piece.a), let b = at(piece.b) else { continue }
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(Paper.line(piece.line, train: piece.train).opacity(piece.main ? 1 : 0.45)),
                           style: StrokeStyle(lineWidth: piece.main ? 7 : 5, lineCap: .round))
            }
            // each line's bullet halfway along it
            for piece in g.pieces {
                guard let a = at(piece.a), let b = at(piece.b) else { continue }
                let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let w = CGFloat(max(2, piece.line.count)) * 7 + 10
                let r = CGRect(x: m.x - w / 2, y: m.y - 9, width: w, height: 18)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Paper.line(piece.line, train: piece.train).opacity(piece.main ? 1 : 0.7)))
                ctx.draw(Text(piece.line).font(.system(size: 10.5, weight: .heavy)).foregroundColor(.white), at: m)
            }
            // the stations, and their names on the open side
            for i in g.stations.indices {
                guard let c = at(i) else { continue }
                let main = g.pieces.contains { $0.main && ($0.a == i || $0.b == i) }
                let big = i == 0 || i == g.dest
                let r: CGFloat = big ? 9 : main ? 7 : 5
                let e = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                ctx.fill(Path(ellipseIn: e), with: .color(i == g.dest ? Paper.yellow : .white))
                ctx.stroke(Path(ellipseIn: e), with: .color(Paper.ink), lineWidth: big ? 3.5 : 2.5)
                let right = c.x < W / 2
                ctx.draw(Text(g.stations[i].name).font(.system(size: big ? 12.5 : main ? 11 : 9.5, weight: big ? .heavy : main ? .bold : .medium))
                            .foregroundColor(main ? Paper.ink : Paper.muted),
                         at: CGPoint(x: c.x + (right ? r + 6 : -(r + 6)), y: c.y), anchor: right ? .leading : .trailing)
            }
        }
        .frame(width: W, height: H)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Metro map of your trip: " + trip.rides.map { "\($0.line) from \(Fmt.place($0.fromStop)) to \(Fmt.place($0.toStop))" }.joined(separator: ", then "))
    }
}
