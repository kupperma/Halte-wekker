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
    /// The map's rectangle on a screen of this size (the video fills the screen, so it's cropped like it).
    static func rect(in size: CGSize) -> CGRect {
        let s = max(size.width / video.width, size.height / video.height)
        let vw = video.width * s, vh = video.height * s
        let ox = (size.width - vw) / 2, oy = (size.height - vh) / 2
        return CGRect(x: ox + x0 * vw, y: oy + y0 * vh, width: (x1 - x0) * vw, height: (y1 - y0) * vh)
    }
}

/// The hanging board over the platform in the station video: the app writes your next transfers on it.
enum BoardSpot {
    static let x0 = 0.3512, x1 = 0.7119, y0 = 0.3102, y1 = 0.3679
    static let design = CGSize(width: 298, height: 100)
    static func rect(in size: CGSize) -> CGRect {
        let s = max(size.width / MapSpot.video.width, size.height / MapSpot.video.height)
        let vw = MapSpot.video.width * s, vh = MapSpot.video.height * s
        let ox = (size.width - vw) / 2, oy = (size.height - vh) / 2
        return CGRect(x: ox + x0 * vw, y: oy + y0 * vh, width: (x1 - x0) * vw, height: (y1 - y0) * vh)
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

struct HomeStage: View {
    let home: Bool
    let stage: StageMode
    let moving: Bool
    let moveToken: Int
    let loopToken: Int
    var board: [BoardLine] = []

    var body: some View {
        ZStack {
            HWPalette.bg
            // the platform
            ForEach([false, true], id: \.self) { h in
                Group {
                    if moving { StationVideo(name: h ? "station-home" : "station-out", playing: h == home && stage != .map, restart: loopToken) }
                    else { still(h ? "still-home" : "still-out") }
                }
                .opacity(h == home ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.8), value: home)
            // stepping back from the wall (or towards it)
            OneShotVideo(name: "move-\(home ? "home" : "out")\(stage == .returning ? "-back" : "")", token: moveToken)
                .opacity(stage == .leaving || stage == .returning ? 1 : 0)
                .animation(.easeOut(duration: stage == .station ? 0.35 : 0.12), value: stage)
            // face to face with the map
            ForEach([false, true], id: \.self) { h in
                still(h ? "map-home" : "map-out").opacity(stage == .map && h == home ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.45), value: stage)
            .animation(.easeInOut(duration: 0.6), value: home)
            // the station's mood, once you've stepped back
            ZStack {
                Color.black.opacity(0.38)
                RadialGradient(colors: [.clear, .black.opacity(0.6)], center: .init(x: 0.5, y: 0.3), startRadius: 120, endRadius: 520)
            }
            .opacity(stage == .station || stage == .leaving ? 1 : 0)
            .animation(.easeInOut(duration: 1.5), value: stage)
            // your next transfers on the board over the platform
            if !board.isEmpty {
                GeometryReader { g in
                    let r = BoardSpot.rect(in: g.size)
                    TransferBoard(rows: board)
                        .scaleEffect(r.width / BoardSpot.design.width, anchor: .topLeading)
                        .frame(width: r.width, height: r.height, alignment: .topLeading)
                        .position(x: r.midX, y: r.midY)
                        .brightness(-0.12)                 // under the station's dimmer light
                }
                .opacity(stage == .station ? 1 : 0)
                .animation(.easeInOut(duration: 0.5), value: stage)
            }
            FilmGrain()
        }
        .ignoresSafeArea()
    }

    private func still(_ name: String) -> some View {
        Group {
            if let img = UIImage(named: name) ?? Bundle.main.path(forResource: name, ofType: "jpg").flatMap(UIImage.init(contentsOfFile:)) {
                Image(uiImage: img).resizable().scaledToFill()
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

/// The double brass rule with corner diamonds, like on the boarding pass.
private struct MapFrame: View {
    let pal: HWPalette
    var body: some View {
        Canvas { ctx, size in
            let r1 = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            let r2 = CGRect(origin: .zero, size: size).insetBy(dx: 7, dy: 7)
            ctx.stroke(Path(r1), with: .color(pal.line), lineWidth: 1)
            ctx.stroke(Path(r2), with: .color(pal.brass), lineWidth: 1.5)
            for p in [CGPoint(x: r2.minX, y: r2.minY), CGPoint(x: r2.maxX, y: r2.minY), CGPoint(x: r2.minX, y: r2.maxY), CGPoint(x: r2.maxX, y: r2.maxY)] {
                var d = Path(); d.move(to: CGPoint(x: p.x, y: p.y - 5)); d.addLine(to: CGPoint(x: p.x + 5, y: p.y)); d.addLine(to: CGPoint(x: p.x, y: p.y + 5)); d.addLine(to: CGPoint(x: p.x - 5, y: p.y)); d.closeSubpath()
                ctx.fill(d, with: .color(MapInk.paper)); ctx.stroke(d, with: .color(pal.brass), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Your commute as a network map. The route of your fastest trip is highlighted in yellow.
struct NetworkMap: View {
    let via: String?
    var body: some View {
        Canvas { ctx, _ in
            func stroke(_ pts: [CGPoint], _ c: Color, _ w: CGFloat) {
                var p = Path(); p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
            let glow = Color(red: 1, green: 0.84, blue: 0.25).opacity(0.55)
            if via == "Eindhoven" { stroke([P(46, 110), P(128, 110), P(188, 174), P(228, 174), P(292, 110)], glow, 14) }
            else { stroke([P(46, 110), P(128, 110), P(188, 46), P(228, 46), P(292, 110)], glow, 14) }
            stroke([P(46, 110), P(46, 178)], glow, 14)
            stroke([P(46, 106.5), P(128, 106.5), P(188, 46.5), P(214, 46.5)], Color(hex: 0x224F86), 5)
            stroke([P(46, 113.5), P(128, 113.5), P(188, 173.5), P(214, 173.5)], Color(hex: 0x528DBA), 5)
            stroke([P(214, 46), P(228, 46), P(292, 110)], Color(hex: 0xDA421E), 5)
            stroke([P(214, 174), P(228, 174), P(292, 110)], Color(hex: 0xF3791D), 5)
            stroke([P(46, 110), P(46, 178)], Color(hex: 0x8C6DAB), 5)
            func ring(_ c: CGPoint, _ r: CGFloat) {
                let o = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(o, with: .color(.white)); ctx.stroke(o, with: .color(MapInk.text), lineWidth: 2)
            }
            func pill(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) {
                let o = Path(roundedRect: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), cornerRadius: w / 2)
                ctx.fill(o, with: .color(.white)); ctx.stroke(o, with: .color(MapInk.text), lineWidth: 2)
            }
            pill(P(46, 110), 13, 22); pill(P(128, 110), 13, 22)
            ring(P(214, 46), 6); ring(P(214, 174), 6); ring(P(292, 110), 7); ring(P(46, 178), 6)
            func label(_ t: String, _ at: CGPoint, _ anchor: UnitPoint) {
                ctx.draw(Text(t).font(MapInk.sans(11, .bold)).foregroundColor(MapInk.text), at: at, anchor: anchor)
            }
            label("Breda", P(46, 97), .bottom); label("BUas", P(58, 178), .leading); label("Tilburg", P(128, 125), .top)
            label("Den Bosch", P(214, 37), .bottom); label("Eindhoven", P(214, 184), .top); label("Veghel", P(292, 97), .bottom)
            func badge(_ t: String, _ c: CGPoint, _ col: Color) {
                let w = CGFloat(t.count) * 7 + 10
                ctx.fill(Path(roundedRect: CGRect(x: c.x - w / 2, y: c.y - 7.5, width: w, height: 15), cornerRadius: 3), with: .color(col))
                ctx.draw(Text(t).font(MapInk.sans(9.5, .bold)).foregroundColor(.white), at: P(c.x, c.y + 0.5), anchor: .center)
            }
            badge("306", P(274, 66), Color(hex: 0xDA421E)); badge("305", P(274, 154), Color(hex: 0xF3791D))
            badge("IC", P(146, 62), Color(hex: 0x224F86)); badge("IC", P(146, 158), Color(hex: 0x528DBA)); badge("BUS", P(72, 144), Color(hex: 0x8C6DAB))
        }
        .frame(width: 318, height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network map: bus 306 from Veghel to Den Bosch or bus 305 to Eindhoven, the Intercity via Tilburg to Breda, the bus to BUas.")
    }
}

/// The map on the wall: the direction, your network and the lines you can pick (the app's menu).
struct MetroMapMenu: View {
    let home: Bool
    let fastest: String
    let lines: String
    let planned: String
    let via: String?
    let open: (HomeSection) -> Void
    let toggle: () -> Void
    let settings: () -> Void

    private var accent: Color { home ? Color(hex: 0x7A2A1E) : Color(hex: 0x1D2C5A) }

    var body: some View {
        let pal = HWPalette.of(home: home)
        ZStack(alignment: .topLeading) {
            MapInk.paper
            MapFrame(pal: pal)
            Text("Haltewekker").font(MapInk.sans(24, .bold)).foregroundStyle(MapInk.text).offset(x: 20, y: 18)
            Text("Network map · Veghel ⇄ Breda").font(MapInk.sans(10.5)).foregroundStyle(MapInk.grey).offset(x: 20, y: 49)
            Button(action: settings) {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .semibold)).foregroundStyle(MapInk.text)
                    .frame(width: 30, height: 30).overlay(Circle().stroke(MapInk.text, lineWidth: 1.5))
            }
            .buttonStyle(.plain).offset(x: 299, y: 23).accessibilityLabel("Settings")
            Button(action: toggle) {
                HStack(spacing: 6) {
                    directionBadge("TO BREDA", on: !home)
                    directionBadge("HOME", on: home)
                    Text("tap to switch").font(MapInk.sans(9.5)).foregroundStyle(MapInk.soft).padding(.leading, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).offset(x: 20, y: 72)
            .accessibilityLabel(home ? "Going home. Tap to switch to going to Breda." : "Going to Breda. Tap to switch to going home.")
            NetworkMap(via: via).offset(x: 14, y: 108)
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
        }
        .frame(width: MapSpot.design.width, height: MapSpot.design.height)
    }

    private func directionBadge(_ t: String, on: Bool) -> some View {
        Text(t).font(MapInk.sans(12.5, .bold)).foregroundStyle(on ? .white : MapInk.soft)
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
