import SwiftUI

// The vehicle that drives along the track on the lock screen and in the Dynamic Island: a bus, an intercity, a
// sprinter, a tram or a metro, seen from the side, facing right (the way it drives). Drawn with plain shapes so it
// renders on the lock screen and stays crisp small (some 18–26 pt tall). Shapes after Dutch double-deck intercities,
// sprinters and city buses, in the app's own line colours (the whole body in the line colour, light glass): no
// operator's livery or logo.

// MARK: - The tram and the metro (simple shapes, by car)

/// One car of a tram or metro: `front` has its cab on the right, `back` on the left (a unit that can drive both ways),
/// `coach` none.
enum CarEnd { case front, back, coach }

/// A car's shapes, in a box of the car's width and height (0…1 each way, the floor of the body at 0.84, the wheels
/// below it).
private typealias Box = (CGFloat, CGFloat, CGFloat, CGFloat)

private struct CarPath: Shape {
    enum Part { case body, skirt, band, stripe, doors, glass, wheels, bogies, lights, roof }
    let kind: VehicleKind
    let end: CarEnd
    let part: Part

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let back = end == .back
        /// A box from 0…1 coordinates, mirrored for a cab on the left.
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
            let a = back ? 1 - x1 : x0, b = back ? 1 - x0 : x1
            return CGRect(x: r.minX + a * w, y: r.minY + y0 * h, width: (b - a) * w, height: (y1 - y0) * h)
        }
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + (back ? 1 - x : x) * w, y: r.minY + y * h) }
        func rects(_ list: [Box], corner: CGFloat = 0.03) -> Path {
            var p = Path()
            for (a, b, c, d) in list { p.addRoundedRect(in: box(a, b, c, d), cornerSize: CGSize(width: h * corner, height: h * corner)) }
            return p
        }
        /// Panes across a stretch, with thin pillars between them.
        func panes(_ x0: CGFloat, _ x1: CGFloat, _ n: Int, _ y0: CGFloat, _ y1: CGFloat, gap: CGFloat = 0.018) -> [Box] {
            let pw = (x1 - x0 - gap * CGFloat(n - 1)) / CGFloat(n)
            return (0..<n).map { i in let a = x0 + CGFloat(i) * (pw + gap); return (a, y0, a + pw, y1) }
        }
        /// A door's two leaves, as windows.
        func leaves(_ d0: CGFloat, _ d1: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> [Box] {
            let m = (d0 + d1) / 2, inset = (d1 - d0) * 0.14, split: CGFloat = 0.006
            return [(d0 + inset, y0, m - split, y1), (m + split, y0, d1 - inset, y1)]
        }
        func circles(_ xs: [CGFloat], y: CGFloat, radius: CGFloat) -> Path {
            var p = Path()
            for x in xs { let c = pt(x, y); p.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)) }
            return p
        }
        /// A body with the corners of its cab end (`front`: top, bottom) and of its other end (`rear`).
        func uneven(_ rect: CGRect, front ft: CGFloat, _ fb: CGFloat, rear rt: CGFloat, _ rb: CGFloat) -> Path {
            back ? UnevenRoundedRectangle(topLeadingRadius: ft, bottomLeadingRadius: fb, bottomTrailingRadius: rb, topTrailingRadius: rt).path(in: rect)
                 : UnevenRoundedRectangle(topLeadingRadius: rt, bottomLeadingRadius: rb, bottomTrailingRadius: fb, topTrailingRadius: ft).path(in: rect)
        }
        // a rail car's bogies: two wheels each
        let bogieAt: [CGFloat] = [0.13, 0.87]
        let wheelGap = 0.17 * h / w

        switch (kind, part) {
        case (.metro, .bogies):
            var p = Path()
            for b in bogieAt { p.addRoundedRect(in: box(b - wheelGap - 0.03, 0.82, b + wheelGap + 0.03, 0.89), cornerSize: CGSize(width: 1, height: 1)) }
            return p
        case (.metro, .wheels):
            return circles(bogieAt.flatMap { [$0 - wheelGap, $0 + wheelGap] }, y: 0.905, radius: h * 0.075)

        // MARK: the tram: two short sections with round ends, a pantograph
        case (.tram, .body):
            return uneven(box(0, 0.10, 1, 0.84), front: h * 0.3, h * 0.1, rear: h * 0.06, h * 0.04)
        case (.tram, .skirt): return Path(box(0, 0.70, 1, 0.84))
        case (.tram, .band): return Path(box(0, 0.62, 1, 0.665))
        case (.tram, .doors): return rects([(0.40, 0.16, 0.53, 0.82)], corner: 0.015)
        case (.tram, .glass):
            let list: [Box] = [(0.06, 0.20, 0.37, 0.56), (0.56, 0.20, 0.84, 0.56)]
            var p = rects(list + leaves(0.40, 0.53, 0.20, 0.64))
            p.addRoundedRect(in: box(0.875, 0.18, 1.02, 0.60), cornerSize: CGSize(width: h * 0.05, height: h * 0.05))
            return p
        case (.tram, .wheels): return circles([0.24, 0.76], y: 0.90, radius: h * 0.08)
        case (.tram, .lights): return end == .front ? circles([0.962], y: 0.66, radius: h * 0.04) : Path()
        case (.tram, .roof):
            guard end == .front else { return Path() }
            var p = Path()
            p.move(to: pt(0.38, 0.10)); p.addLine(to: pt(0.48, 0.01)); p.addLine(to: pt(0.58, 0.10))
            p.move(to: pt(0.42, 0.01)); p.addLine(to: pt(0.54, 0.01))
            return p

        // MARK: the metro: a silver car with a coloured stripe
        case (.metro, .body):
            return uneven(box(0, 0.04, 1, 0.84), front: h * 0.26, h * 0.06, rear: h * 0.08, h * 0.04)
        case (.metro, .stripe): return Path(box(0, 0.60, 1, 0.68))
        case (.metro, .doors): return rects([(0.25, 0.10, 0.37, 0.82), (0.61, 0.10, 0.73, 0.82)], corner: 0.01)
        case (.metro, .glass):
            let list: [Box] = [(0.06, 0.18, 0.22, 0.48), (0.40, 0.18, 0.58, 0.48), (0.76, 0.18, 0.88, 0.48)]
            var p = rects(list + leaves(0.25, 0.37, 0.16, 0.50) + leaves(0.61, 0.73, 0.16, 0.50))
            p.addRoundedRect(in: box(0.905, 0.16, 1.02, 0.50), cornerSize: CGSize(width: h * 0.04, height: h * 0.04))
            return p
        case (.metro, .lights): return end == .front ? circles([0.968], y: 0.72, radius: h * 0.04) : Path()

        default: return Path()
        }
    }
}

/// A tram's or metro's colours.
private struct CarColors {
    let body: Color, skirt: Color, band: Color, stripe: Color, door: Color
    let glass = Color(hex: 0x1B2431)
    let wheel = Color(hex: 0x15181C)
    let hub = Color(hex: 0x8A9099)
    let light = Color(hex: 0xFFF3C4)

    init(_ k: VehicleKind, _ look: LiveLook) {
        let d = look.dark
        if k == .tram {
            body = Color(hex: d ? DSCore.tramDark : DSCore.tram); skirt = Color(hex: d ? 0x5E3E8E : 0x4E2C78)
            band = Color(hex: 0xE7DDF3); stripe = .clear; door = Color(hex: d ? 0x6A479F : 0x5A3489)
        } else {
            body = Color(hex: d ? 0xAEB5BF : 0xC3C9D2); skirt = .clear; band = .clear
            stripe = Color(hex: d ? DSCore.tramDark : DSCore.tram); door = Color(hex: d ? 0x949BA6 : 0x9FA6B1)
        }
    }
}

/// One tram or metro car, drawn.
private struct VehicleCar: View {
    let kind: VehicleKind
    let end: CarEnd
    let look: LiveLook
    var body: some View {
        let c = CarColors(kind, look)
        let shape = CarPath(kind: kind, end: end, part: .body)
        ZStack {
            CarPath(kind: kind, end: end, part: .roof).stroke(look.dark ? c.hub : c.wheel, lineWidth: 1)
            CarPath(kind: kind, end: end, part: .bogies).fill(c.wheel)
            CarPath(kind: kind, end: end, part: .wheels).fill(c.wheel)
            ZStack {
                shape.fill(c.body)
                CarPath(kind: kind, end: end, part: .skirt).fill(c.skirt)
                CarPath(kind: kind, end: end, part: .band).fill(c.band)
                CarPath(kind: kind, end: end, part: .stripe).fill(c.stripe)
                CarPath(kind: kind, end: end, part: .doors).fill(c.door)
                CarPath(kind: kind, end: end, part: .glass).fill(c.glass)
                CarPath(kind: kind, end: end, part: .lights).fill(c.light)
            }
            .clipShape(shape)
            shape.stroke(look.outline, lineWidth: 0.6)
        }
    }
}

/// A whole vehicle, its front on the right. `height` sets its size; `VehicleDrawing.width` its width.
struct VehicleDrawing: View {
    let kind: VehicleKind
    let height: CGFloat
    var look: LiveLook = .darkLook

    /// Below this height the finest detail (door windows, window dividers, the pantograph) is left out.
    static let fineFrom: CGFloat = 20

    // the tram and the metro: two cars each
    private static let carAspect: [VehicleKind: CGFloat] = [.tram: 2.7, .metro: 3.2]
    private static func gap(_ height: CGFloat) -> CGFloat { max(1, height * 0.06) }

    static func width(_ k: VehicleKind, height: CGFloat) -> CGFloat {
        if let art = VehicleArt.of(k) { return height * art.box.width / art.box.height }
        return 2 * (carAspect[k] ?? 3) * height + gap(height)
    }

    var body: some View {
        Group {
            if let art = VehicleArt.of(kind) {
                ArtView(art: art, palette: ArtPalette.of(kind), height: height)
            } else {
                let cw = (Self.carAspect[kind] ?? 3) * height
                HStack(spacing: Self.gap(height)) {
                    VehicleCar(kind: kind, end: .back, look: look).frame(width: cw, height: height)
                    VehicleCar(kind: kind, end: .front, look: look).frame(width: cw, height: height)
                }
                .background(alignment: .bottom) {                // the coupling between the cars
                    Rectangle().fill(Color(hex: 0x1B2431)).frame(height: height * 0.14).padding(.bottom, height * 0.24).padding(.horizontal, cw * 0.4)
                }
            }
        }
        .frame(width: Self.width(kind, height: height), height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - The bus, the intercity and the sprinter (drawn in their own view box, scaled to the frame)

/// The N1 colours: the whole body in the line colour, a slightly darker shade for the doors, a slightly lighter one
/// for the stripe and the cab's nose, light glass, dark wheels and bogies.
struct ArtPalette {
    let body: Color, light: Color, door: Color
    static let glass = Color(hex: 0xD3DCE5)
    static let dark = Color(hex: 0x15181C)
    static let headlight = Color(hex: 0xFFF4D6)
    static let display = Color(hex: 0xFFB37A)
    static let hub = Color(hex: 0x6B737B)

    static func of(_ k: VehicleKind) -> ArtPalette {
        switch k {
        case .bus: return ArtPalette(body: Color(hex: DSCore.bus), light: Color(hex: DSCore.busLight), door: Color(hex: DSCore.busDoor))
        case .sprinter: return ArtPalette(body: Color(hex: DSCore.sprinter), light: Color(hex: DSCore.sprinterLight), door: Color(hex: DSCore.sprinterDoor))
        default: return ArtPalette(body: Color(hex: DSCore.intercity), light: Color(hex: DSCore.intercityLight), door: Color(hex: DSCore.intercityDoor))
        }
    }
}

/// One layer of a drawing: a path in the view box, filled (or stroked) in one of the palette's colours.
private struct ArtLayer {
    enum Role { case body, light, door, glass, dark, headlight, display, hub }
    let path: Path
    let role: Role
    var stroke: CGFloat? = nil
    var opacity: Double = 1
    /// Fine detail, left out when the drawing is small.
    var fine = false
}

/// A vehicle's drawing: its layers, bottom first, in a view box.
struct VehicleArt {
    fileprivate let box: CGSize
    fileprivate let layers: [ArtLayer]

    /// The bus, the intercity and the sprinter (a train it can't tell more about is drawn as a sprinter in the
    /// intercity's colour); nil for the tram and the metro.
    static func of(_ k: VehicleKind) -> VehicleArt? {
        switch k {
        case .bus: return bus
        case .ic: return intercity
        case .sprinter, .train: return sprinter
        case .tram, .metro: return nil
        }
    }

    // MARK: the city bus (200 × 56): a low floor, a big windscreen with a destination display, 4 + 1 side windows,
    // two double doors, wheel arches and a roof unit

    static let bus: VehicleArt = {
        var l: [ArtLayer] = []
        l.append(ArtLayer(path: rr(22, 3, 44, 5, 2), role: .dark, opacity: 0.6))                  // the roof unit
        var b = PathPen(); b.M(3, 12); b.corner(6, -6, 6); b.H(184); b.c(6, 0, 10, 3, 11, 9); b.l(2, 26); b.corner(-5, 5, 5); b.H(3); b.z()
        l.append(ArtLayer(path: b.path, role: .body))
        var n = PathPen(); n.M(184, 6); n.c(6, 0, 10, 3, 11, 9); n.l(2, 26); n.corner(-5, 5, 5); n.H(182); n.z()
        l.append(ArtLayer(path: n.path, role: .light))                                           // the front
        var w = PathPen(); w.M(183, 12); w.h(9); w.c(1, 0, 2, 1, 2, 2); w.l(1.5, 21); w.H(183); w.z()
        l.append(ArtLayer(path: w.path, role: .glass))                                           // the windscreen
        l.append(ArtLayer(path: rr(180, 7.5, 13, 3, 1), role: .dark))                            // the destination display
        l.append(ArtLayer(path: rr(182, 8.3, 8, 1.4, 0.7), role: .display, fine: true))
        var win = Path()
        for x in [10, 40, 116, 146] as [CGFloat] { win.addPath(rr(x, 12, 26, 17, 2.5)) }
        win.addPath(rr(70, 12, 15, 17, 2.5))
        l.append(ArtLayer(path: win, role: .glass))
        var doors = Path(), leaves = Path()
        for dx in [90, 165] as [CGFloat] {
            doors.addPath(rr(dx, 10, 15, 36, 2))
            leaves.addPath(rr(dx + 2, 12.5, 5, 26, 1)); leaves.addPath(rr(dx + 8, 12.5, 5, 26, 1))
        }
        l.append(ArtLayer(path: doors, role: .door))
        l.append(ArtLayer(path: doors, role: .dark, stroke: 0.8))
        l.append(ArtLayer(path: leaves, role: .glass))
        l.append(ArtLayer(path: Path(CGRect(x: 3, y: 35, width: 160, height: 3)), role: .light)) // the stripe
        var arches = Path(), wheels = Path(), hubs = Path()
        for cx in [38, 148] as [CGFloat] {
            arches.addPath(dot(cx, 46, 9)); wheels.addPath(dot(cx, 47, 7)); hubs.addPath(dot(cx, 47, 3))
        }
        l.append(ArtLayer(path: arches, role: .body))
        l.append(ArtLayer(path: wheels, role: .dark))
        l.append(ArtLayer(path: hubs, role: .hub))
        l.append(ArtLayer(path: rr(194, 38, 3, 3, 1), role: .headlight))
        return VehicleArt(box: CGSize(width: 200, height: 56), layers: l)
    }()

    // MARK: the intercity (300 × 56): double-deck, a coach and a cab car; two rows of windows between the doors, a low
    // single-deck end with one window, doors with a small window, a sloped nose with a windscreen and a headlight, a
    // pantograph on the cab car, two bogies a car

    static let intercity: VehicleArt = {
        var l: [ArtLayer] = []
        func car(_ x0: CGFloat, cab: Bool) {
            let len: CGFloat = 138
            let end = x0 + (cab ? 118 : len)
            if cab {
                var b = PathPen(); b.M(x0, 14); b.corner(7, -7, 7); b.H(x0 + 118); b.c(10, 0, 18, 4, 23, 12); b.l(7, 13)
                b.c(2, 4, 2, 8, 1, 12); b.l(-2, 4); b.H(x0); b.z()
                l.append(ArtLayer(path: b.path, role: .body))
                var n = PathPen(); n.M(x0 + 118, 7); n.c(10, 0, 18, 4, 23, 12); n.l(7, 13); n.c(2, 4, 2, 8, 1, 12); n.l(-2, 4); n.H(x0 + 118); n.z()
                l.append(ArtLayer(path: n.path, role: .light))                                   // the nose
                var w = PathPen(); w.M(x0 + 124, 10); w.c(7, 0, 12, 4, 15, 10); w.l(5, 9); w.H(x0 + 124); w.z()
                l.append(ArtLayer(path: w.path, role: .glass))                                   // the windscreen
                l.append(ArtLayer(path: dot(x0 + 145, 41, 1.8), role: .headlight))
                var pan = Path()                                                                 // the pantograph
                pan.move(to: CGPoint(x: x0 + 60, y: 7)); pan.addLine(to: CGPoint(x: x0 + 68, y: 2)); pan.addLine(to: CGPoint(x: x0 + 76, y: 7))
                pan.move(to: CGPoint(x: x0 + 64, y: 2)); pan.addLine(to: CGPoint(x: x0 + 72, y: 2))
                l.append(ArtLayer(path: pan, role: .dark, stroke: 1.5, fine: true))
            } else {
                l.append(ArtLayer(path: rr(x0, 7, len, 41, 7), role: .body))
            }
            var glass = rr(x0 + 5, 20, 12, 11, 2)                                                // the low ends' windows
            if !cab { glass.addPath(rr(end - 17, 20, 12, 11, 2)) }
            let de = cab ? x0 + 106 : end - 29
            var doors = Path(), doorGlass = Path()
            for dx in [x0 + 20, de] {
                doors.addPath(rr(dx, 17, 9, 31, 1.5)); doorGlass.addPath(rr(dx + 2, 20, 5, 10, 1))
            }
            l.append(ArtLayer(path: doors, role: .door, opacity: 0.95))
            l.append(ArtLayer(path: doors, role: .dark, stroke: 0.8))
            l.append(ArtLayer(path: doorGlass, role: .glass, fine: true))
            let xs = x0 + 33, xe = de - 4, n: CGFloat = 4, ww = (xe - xs - (n - 1) * 3) / n
            for i in 0..<4 {                                                                     // the two decks
                let xx = xs + CGFloat(i) * (ww + 3)
                glass.addPath(rr(xx, 11, ww, 10, 2)); glass.addPath(rr(xx, 27, ww, 10, 2))
            }
            l.append(ArtLayer(path: glass, role: .glass))
            l.append(ArtLayer(path: Path(CGRect(x: x0, y: 41, width: cab ? 118 : end - x0, height: 2.5)), role: .light))
            var bogies = Path(), wheels = Path()
            for bx in cab ? [x0 + 8, x0 + 110] : [x0 + 8, end - 30] {
                bogies.addPath(rr(bx, 48, 22, 4, 2)); wheels.addPath(dot(bx + 5, 52, 3)); wheels.addPath(dot(bx + 17, 52, 3))
            }
            bogies.addPath(wheels)
            l.append(ArtLayer(path: bogies, role: .dark))
        }
        car(2, cab: false)
        l.append(ArtLayer(path: Path(CGRect(x: 140, y: 20, width: 4, height: 22)), role: .dark)) // the gangway
        car(144, cab: true)
        return VehicleArt(box: CGSize(width: 300, height: 56), layers: l)
    }()

    // MARK: the sprinter (260 × 50): two low cars, a long window band with dividers, two wide double doors a car, a
    // rounded wrap-around front, small wheels

    static let sprinter: VehicleArt = {
        var l: [ArtLayer] = []
        func car(_ x0: CGFloat, cab: Bool) {
            let len: CGFloat = cab ? 96 : 122
            if cab {
                var b = PathPen(); b.M(x0, 15); b.corner(7, -7, 7); b.H(x0 + 96); b.c(14, 0, 24, 10, 25, 24); b.v(8); b.corner(-4, 4, 4); b.H(x0); b.z()
                l.append(ArtLayer(path: b.path, role: .body))
                var n = PathPen(); n.M(x0 + 96, 8); n.c(14, 0, 24, 10, 25, 24); n.v(8); n.corner(-4, 4, 4); n.H(x0 + 96); n.z()
                l.append(ArtLayer(path: n.path, role: .light))                                   // the front
                var w = PathPen(); w.M(x0 + 98, 12); w.c(10, 1, 17, 7, 19, 16); w.H(x0 + 98); w.z()
                l.append(ArtLayer(path: w.path, role: .glass))
                l.append(ArtLayer(path: dot(x0 + 117, 38, 1.8), role: .headlight))
            } else {
                l.append(ArtLayer(path: rr(x0, 8, 122, 36, 7), role: .body))
            }
            l.append(ArtLayer(path: rr(x0 + 6, 14, len - 12, 13, 3), role: .glass))             // the window band
            var dividers = Path()
            for k in 1...4 { dividers.addRect(CGRect(x: x0 + 6 + CGFloat(k) * (len - 12) / 5, y: 14, width: 1.5, height: 13)) }
            l.append(ArtLayer(path: dividers, role: .body, fine: true))
            var doors = Path(), leaves = Path()
            for dx in cab ? [x0 + 26, x0 + 70] : [x0 + 26, x0 + 78] {
                doors.addPath(rr(dx, 12, 14, 32, 2))
                leaves.addPath(rr(dx + 2, 15, 4.5, 14, 1)); leaves.addPath(rr(dx + 7.5, 15, 4.5, 14, 1))
            }
            l.append(ArtLayer(path: doors, role: .door))
            l.append(ArtLayer(path: doors, role: .dark, stroke: 0.8))
            l.append(ArtLayer(path: leaves, role: .glass, fine: true))
            l.append(ArtLayer(path: Path(CGRect(x: x0, y: 36, width: len, height: 3)), role: .light))
            var wheels = Path()
            for bx in cab ? [x0 + 6, x0 + 92] : [x0 + 6, x0 + 98] { wheels.addPath(dot(bx + 4, 45, 2.6)); wheels.addPath(dot(bx + 13, 45, 2.6)) }
            l.append(ArtLayer(path: wheels, role: .dark))
        }
        car(2, cab: false)
        l.append(ArtLayer(path: Path(CGRect(x: 124, y: 18, width: 4, height: 20)), role: .dark)) // the gangway
        car(128, cab: true)
        return VehicleArt(box: CGSize(width: 260, height: 50), layers: l)
    }()
}

/// A rounded rectangle in view-box units.
private func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
    Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
}
private func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
}

/// SVG-style path commands (absolute capitals, relative small letters), so the drawings keep the design's numbers.
private struct PathPen {
    var path = Path()
    var at = CGPoint.zero
    mutating func M(_ x: CGFloat, _ y: CGFloat) { at = CGPoint(x: x, y: y); path.move(to: at) }
    mutating func L(_ x: CGFloat, _ y: CGFloat) { at = CGPoint(x: x, y: y); path.addLine(to: at) }
    mutating func l(_ dx: CGFloat, _ dy: CGFloat) { L(at.x + dx, at.y + dy) }
    mutating func H(_ x: CGFloat) { L(x, at.y) }
    mutating func h(_ dx: CGFloat) { L(at.x + dx, at.y) }
    mutating func v(_ dy: CGFloat) { L(at.x, at.y + dy) }
    mutating func c(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
        let end = CGPoint(x: at.x + dx, y: at.y + dy)
        path.addCurve(to: end, control1: CGPoint(x: at.x + x1, y: at.y + y1), control2: CGPoint(x: at.x + x2, y: at.y + y2))
        at = end
    }
    /// A quarter-circle corner to (dx, dy) of radius `r`, turning from going up or down into going across (the
    /// design's `a r r 0 0 1 dx dy`).
    mutating func corner(_ dx: CGFloat, _ dy: CGFloat, _ r: CGFloat) {
        let end = CGPoint(x: at.x + dx, y: at.y + dy)
        path.addArc(tangent1End: CGPoint(x: at.x, y: end.y), tangent2End: end, radius: r)
        at = end
    }
    mutating func z() { path.closeSubpath() }
}

/// A path in a view box, scaled to the frame.
private struct BoxShape: Shape {
    let path: Path
    let box: CGSize
    func path(in r: CGRect) -> Path {
        path.applying(CGAffineTransform(a: r.width / box.width, b: 0, c: 0, d: r.height / box.height, tx: r.minX, ty: r.minY))
    }
}

private struct ArtView: View {
    let art: VehicleArt
    let palette: ArtPalette
    let height: CGFloat
    var body: some View {
        let scale = height / art.box.height
        let fine = height >= VehicleDrawing.fineFrom
        ZStack(alignment: .topLeading) {
            ForEach(Array(art.layers.enumerated()), id: \.offset) { _, layer in
                if fine || !layer.fine {
                    if let w = layer.stroke {
                        BoxShape(path: layer.path, box: art.box).stroke(color(layer.role), lineWidth: max(0.5, w * scale)).opacity(layer.opacity)
                    } else {
                        BoxShape(path: layer.path, box: art.box).fill(color(layer.role)).opacity(layer.opacity)
                    }
                }
            }
        }
    }
    private func color(_ r: ArtLayer.Role) -> Color {
        switch r {
        case .body: return palette.body
        case .light: return palette.light
        case .door: return palette.door
        case .glass: return ArtPalette.glass
        case .dark: return ArtPalette.dark
        case .headlight: return ArtPalette.headlight
        case .display: return ArtPalette.display
        case .hub: return ArtPalette.hub
        }
    }
}

/// A stop along the way: its name, when you're there, and where it is on the track (0…1).
struct StopMark: Identifiable, Hashable {
    var id: String { "\(name)|\(fraction)" }
    let name: String
    let time: Date?
    let fraction: Double
}

/// The track on the lock screen and in the Dynamic Island: a thin rounded line, a dot for each stop along the way,
/// your stop as a filled dot at the end, and the vehicle riding on it. `progress` 0…1 moves the vehicle's nose.
struct RideTrack: View {
    let progress: Double
    let kind: VehicleKind
    var stops: [Double] = []
    var look: LiveLook = .darkLook
    /// The part done and your stop's dot (the accent; warm when it's waking you).
    var tint: Color? = nil

    /// Where a point of the trip (0…1) sits along the track, as a share of its width.
    static func x(_ f: Double) -> Double { 0.04 + 0.96 * min(1, max(0, f)) }

    var body: some View {
        let done = tint ?? look.accent
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let pad: CGFloat = 6                                 // room for your stop's dot at the end
            let tw = max(1, w - pad * 2)
            let lineY = h - 5
            let vh = max(8, lineY - 2)
            let vw = VehicleDrawing.width(kind, height: vh)
            let nose = pad + CGFloat(Self.x(progress)) * tw
            ZStack(alignment: .topLeading) {
                Capsule().fill(look.track).frame(width: tw, height: 3).position(x: pad + tw / 2, y: lineY)
                Capsule().fill(done).frame(width: max(3, nose - pad), height: 3).position(x: pad + max(3, nose - pad) / 2, y: lineY)
                ForEach(Array(stops.enumerated()), id: \.offset) { _, f in
                    let passed = f <= progress
                    Circle().fill(passed ? done : look.surface)
                        .overlay(Circle().stroke(passed ? done : look.trackStrong, lineWidth: 1.5))
                        .frame(width: 7, height: 7)
                        .position(x: pad + CGFloat(Self.x(f)) * tw, y: lineY)
                }
                Circle().fill(done).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(look.surface, lineWidth: 2))
                    .position(x: pad + tw, y: lineY)
                VehicleDrawing(kind: kind, height: vh, look: look)
                    .position(x: nose - vw / 2, y: lineY - 1.5 - vh / 2)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .animation(.easeInOut(duration: 2), value: progress)
        }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Trip \(Int(min(1, max(0, progress)) * 100)) percent done")
    }
}
