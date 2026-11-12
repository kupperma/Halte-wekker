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

// MARK: the stage behind it all

struct HomeStage: View {
    let home: Bool
    let stage: StageMode
    let moving: Bool
    let moveToken: Int
    let loopToken: Int

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

// MARK: the map

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
                ctx.fill(d, with: .color(pal.paper)); ctx.stroke(d, with: .color(pal.brass), lineWidth: 1.5)
            }
            // faint map grid
            var g = Path(), x: CGFloat = 0
            while x < size.width { g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: size.height)); x += 11 }
            var y: CGFloat = 0
            while y < size.height { g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y)); y += 11 }
            ctx.stroke(g, with: .color(.white.opacity(0.035)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Your commute as a metro map. The route of your fastest trip is drawn bright, the other one paler.
struct NetworkMap: View {
    let via: String?
    var body: some View {
        Canvas { ctx, _ in
            let pt: [String: CGPoint] = ["bd": .init(x: 40, y: 60), "buas": .init(x: 22, y: 122), "til": .init(x: 122, y: 80),
                                         "ht": .init(x: 204, y: 30), "ehv": .init(x: 214, y: 124), "vg": .init(x: 300, y: 62)]
            let gold = Color(hex: 0xF4C542), green = Color(hex: 0x4CC38A), copper = Color(hex: 0xE0814E)
            let viaEhv = via == "Eindhoven"
            func line(_ a: String, _ b: String, _ c: Color, _ on: Bool = true) {
                var p = Path(); p.move(to: pt[a]!); p.addLine(to: pt[b]!)
                ctx.stroke(p, with: .color(c.opacity(on ? 1 : 0.5)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
            line("bd", "til", gold)
            line("til", "ht", gold, !viaEhv); line("til", "ehv", gold, viaEhv)
            line("vg", "ht", green, !viaEhv); line("vg", "ehv", green, viaEhv)
            line("bd", "buas", copper)
            for (k, big) in [("til", false), ("bd", true), ("ht", true), ("ehv", true), ("vg", true), ("buas", true)] {
                let r: CGFloat = big ? 7 : 4.5, c = pt[k]!
                let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(dot, with: .color(.white)); ctx.stroke(dot, with: .color(Color(hex: 0x14121A)), lineWidth: 2.5)
            }
            func label(_ t: String, _ k: String, dx: CGFloat, dy: CGFloat, _ anchor: UnitPoint) {
                ctx.draw(Text(t).font(HWFont.body(10, bold: true)).foregroundColor(HWPalette.ink), at: CGPoint(x: pt[k]!.x + dx, y: pt[k]!.y + dy), anchor: anchor)
            }
            label("BREDA", "bd", dx: 0, dy: -11, .bottom); label("BUAS", "buas", dx: 14, dy: 0, .leading)
            label("Tilburg", "til", dx: 0, dy: 10, .top); label("DEN BOSCH", "ht", dx: 0, dy: -11, .bottom)
            label("EINDHOVEN", "ehv", dx: 0, dy: 11, .top); label("VEGHEL", "vg", dx: 0, dy: -11, .bottom)
        }
        .frame(width: 318, height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map: Veghel by bus to Den Bosch or Eindhoven, the train to Breda, the bus to BUas.")
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

    var body: some View {
        let pal = HWPalette.of(home: home)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [pal.paper, pal.paper2], startPoint: .top, endPoint: .bottom)
            MapFrame(pal: pal)
            Text("Haltewekker").font(HWFont.display(27)).foregroundStyle(HWPalette.ink).offset(x: 20, y: 19)
            Text("METRO MAP OF YOUR COMMUTE").font(HWFont.body(9)).tracking(0.6).foregroundStyle(HWPalette.muted).offset(x: 20, y: 53)
            Button(action: settings) {
                Image(systemName: "gearshape").font(.system(size: 15, weight: .semibold)).foregroundStyle(pal.brass)
                    .frame(width: 32, height: 32).overlay(Circle().stroke(pal.brass, lineWidth: 1.5))
            }
            .buttonStyle(.plain).offset(x: 300, y: 24).accessibilityLabel("Settings")
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(home ? "GOING" : "GOING TO").font(HWFont.body(9)).foregroundStyle(HWPalette.ink.opacity(0.8))
                    FlipTiles(word: home ? "HOME" : "BREDA", pal: pal, size: 0.74)
                    Text(home ? "Breda → Veghel · tap to switch" : "Veghel → Breda · tap to switch").font(HWFont.body(10)).foregroundStyle(HWPalette.ink.opacity(0.8))
                }
                .frame(width: 300, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).offset(x: 20, y: 83)
            .accessibilityLabel(home ? "Going home. Tap to switch to going to Breda." : "Going to Breda. Tap to switch to going home.")
            NetworkMap(via: via).offset(x: 14, y: 166)
            row(.fastest, letter: "F", fill: AnyShapeStyle(RatingStyle.fill("S")), sub: fastest, y: 330)
            row(.lines, letter: "A", fill: AnyShapeStyle(Color(hex: 0x4CC38A)), sub: lines, y: 392)
            row(.planned, letter: "P", fill: AnyShapeStyle(Color(hex: 0x7AA7FF)), sub: planned, y: 454)
            Button { open(.more) } label: {
                HStack(spacing: 8) {
                    Text("M").font(HWFont.display(12)).foregroundStyle(Color(hex: 0x14121A)).frame(width: 20, height: 20).background(HWPalette.muted, in: Circle())
                    Text("More · leaderboard, single stop, tips").font(HWFont.body(10.5)).foregroundStyle(HWPalette.ink.opacity(0.85))
                }
                .padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain).offset(x: 20, y: 512)
        }
        .frame(width: MapSpot.design.width, height: MapSpot.design.height)
    }

    private func row(_ s: HomeSection, letter: String, fill: AnyShapeStyle, sub: String, y: CGFloat) -> some View {
        Button { open(s) } label: {
            HStack(spacing: 12) {
                Text(letter).font(HWFont.display(22)).foregroundStyle(Color(hex: 0x14121A)).offset(y: 1)
                    .frame(width: 40, height: 40).background(fill, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title).font(HWFont.display(17)).foregroundStyle(HWPalette.ink)
                    Text(sub).font(HWFont.body(10.5)).foregroundStyle(HWPalette.muted).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(HWPalette.of(home: home).brass)
            }
            .padding(.horizontal, 14).frame(width: 318, height: 54)
            .background(Color.black.opacity(0.28))
            .overlay(Rectangle().stroke(HWPalette.of(home: home).line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: 14, y: y)
        .accessibilityLabel("\(s.title). \(sub)")
    }
}
