import SwiftUI

// The vehicle that drives along the track on the lock screen and in the Dynamic Island: a bus, an intercity, a
// sprinter, a tram or a metro, seen from the side, facing right (the way it drives). Drawn with plain shapes so it
// renders on the lock screen and stays crisp small (some 18–26 pt tall). Generic shapes and the app's own colours:
// no operator's livery or logo.

/// One car of a vehicle: `front` has its cab on the right, `back` on the left (a unit that can drive both ways),
/// `coach` none.
enum CarEnd { case front, back, coach }

/// A car's shapes, in a box of the car's width and height (0…1 each way, the floor of the body at 0.84, the wheels
/// below it).
private typealias Box = (CGFloat, CGFloat, CGFloat, CGFloat)

private struct CarPath: Shape {
    enum Part { case body, skirt, band, stripe, doors, glass, arches, wheels, hubs, bogies, lights, roof }
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
        let cab = end != .coach
        // a rail car's bogies: two wheels each
        let bogieAt: [CGFloat] = [0.13, 0.87]
        let wheelGap = 0.17 * h / w

        switch (kind, part) {
        // MARK: the bus: a long box, a big windscreen, a dark window band, two doors, two wheels
        case (.bus, .body):
            return uneven(box(0, 0.04, 1, 0.84), front: h * 0.2, h * 0.07, rear: h * 0.1, h * 0.05)
        case (.bus, .skirt): return Path(box(0, 0.68, 1, 0.84))
        case (.bus, .glass):
            var list: [Box] = panes(0.035, 0.415, 3, 0.13, 0.52) + panes(0.555, 0.785, 2, 0.13, 0.52)
            list += leaves(0.44, 0.53, 0.13, 0.80) + leaves(0.80, 0.89, 0.13, 0.80)
            var p = rects(list)
            p.addRoundedRect(in: box(0.905, 0.10, 1.02, 0.62), cornerSize: CGSize(width: h * 0.04, height: h * 0.04))   // the windscreen
            return p
        case (.bus, .doors): return rects([(0.44, 0.12, 0.53, 0.82), (0.80, 0.12, 0.89, 0.82)], corner: 0.01)
        case (.bus, .arches): return circles([0.22, 0.70], y: 0.84, radius: h * 0.175)
        case (.bus, .wheels): return circles([0.22, 0.70], y: 0.84, radius: h * 0.14)
        case (.bus, .hubs): return circles([0.22, 0.70], y: 0.84, radius: h * 0.055)
        case (.bus, .lights): return circles([0.975], y: 0.71, radius: h * 0.045)

        // MARK: the intercity: double-deck, a sloped pointed nose, a light window band, a thin accent stripe
        case (.ic, .body):
            guard cab else { return uneven(box(0, 0.02, 1, 0.84), front: h * 0.1, h * 0.04, rear: h * 0.1, h * 0.04) }
            var p = Path()
            p.move(to: pt(0, 0.80))
            p.addLine(to: pt(0, 0.10))
            p.addQuadCurve(to: pt(0.03, 0.02), control: pt(0, 0.02))
            p.addLine(to: pt(0.74, 0.02))
            p.addQuadCurve(to: pt(1.0, 0.64), control: pt(0.97, 0.04))            // the long sloped nose
            p.addLine(to: pt(0.995, 0.80))
            p.addQuadCurve(to: pt(0.97, 0.84), control: pt(0.995, 0.84))
            p.addLine(to: pt(0.01, 0.84))
            p.addQuadCurve(to: pt(0, 0.80), control: pt(0, 0.84))
            p.closeSubpath()
            return p
        case (.ic, .band): return Path(box(0, 0.08, cab ? 0.77 : 1, 0.64))
        case (.ic, .stripe): return Path(box(0, 0.70, 1, 0.735))
        case (.ic, .doors):
            let list: [Box] = cab ? [(0.03, 0.06, 0.09, 0.82)] : [(0.03, 0.06, 0.09, 0.82), (0.91, 0.06, 0.97, 0.82)]
            return rects(list, corner: 0.01)
        case (.ic, .glass):
            let x1: CGFloat = cab ? 0.73 : 0.87, n = cab ? 5 : 6
            var list: [Box] = panes(0.13, x1, n, 0.13, 0.31, gap: 0.02) + panes(0.13, x1, n, 0.40, 0.58, gap: 0.02)
            list.append((0.042, 0.14, 0.078, 0.40))
            if !cab { list.append((0.922, 0.14, 0.958, 0.40)) }
            var p = rects(list)
            if cab {                                                          // the windscreen, along the slope
                p.move(to: pt(0.785, 0.09)); p.addLine(to: pt(0.855, 0.12)); p.addLine(to: pt(0.915, 0.23))
                p.addLine(to: pt(0.95, 0.40)); p.addLine(to: pt(0.80, 0.40)); p.closeSubpath()
            }
            return p
        case (.ic, .lights): return cab ? circles([0.976], y: 0.72, radius: h * 0.04) : Path()

        // MARK: the sprinter (and a train it can't tell more about): low, single-deck, a round flat nose, wide doors
        case (.sprinter, .body), (.train, .body):
            let bh = 0.66 * h
            let rect = box(0, 0.18, 1, 0.84)
            switch end {
            case .coach: return uneven(rect, front: bh * 0.1, bh * 0.06, rear: bh * 0.1, bh * 0.06)
            default: return uneven(rect, front: bh * 0.5, bh * 0.2, rear: bh * 0.1, bh * 0.06)
            }
        case (.sprinter, .band), (.train, .band): return Path(box(0, 0.60, 1, 0.645))
        case (.sprinter, .doors), (.train, .doors): return rects([(0.22, 0.24, 0.35, 0.82), (0.58, 0.24, 0.71, 0.82)], corner: 0.015)
        case (.sprinter, .glass), (.train, .glass):
            var list: [Box] = [(0.05, 0.30, 0.20, 0.54), (0.37, 0.30, 0.56, 0.54), (0.73, 0.30, 0.875, 0.54)]
            list += leaves(0.22, 0.35, 0.30, 0.62) + leaves(0.58, 0.71, 0.30, 0.62)
            var p = rects(list)
            if cab { p.addRoundedRect(in: box(0.905, 0.28, 1.02, 0.55), cornerSize: CGSize(width: h * 0.05, height: h * 0.05)) }
            return p
        case (.sprinter, .bogies), (.train, .bogies), (.ic, .bogies), (.metro, .bogies):
            var p = Path()
            for b in bogieAt { p.addRoundedRect(in: box(b - wheelGap - 0.03, 0.82, b + wheelGap + 0.03, 0.89), cornerSize: CGSize(width: 1, height: 1)) }
            return p
        case (.sprinter, .wheels), (.train, .wheels), (.ic, .wheels), (.metro, .wheels):
            return circles(bogieAt.flatMap { [$0 - wheelGap, $0 + wheelGap] }, y: 0.905, radius: h * 0.075)
        case (.sprinter, .lights), (.train, .lights): return end == .front ? circles([0.968], y: 0.67, radius: h * 0.04) : Path()
        case (.sprinter, .roof), (.train, .roof):
            guard end == .front else { return Path() }
            var p = Path()                                                    // a small pantograph
            p.move(to: pt(0.46, 0.18)); p.addLine(to: pt(0.52, 0.07)); p.addLine(to: pt(0.58, 0.18))
            p.move(to: pt(0.48, 0.07)); p.addLine(to: pt(0.56, 0.07))
            return p

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

/// The colours of one kind, in the app's palette: the bus orange, the train navy, a lighter blue for the sprinter.
private struct VehicleColors {
    let body: Color, skirt: Color, band: Color, stripe: Color, door: Color
    let glass = Color(hex: 0x1B2431)
    let wheel = Color(hex: 0x15181C)
    let hub = Color(hex: 0x8A9099)
    let light = Color(hex: 0xFFF3C4)

    init(_ k: VehicleKind, _ look: LiveLook) {
        let d = look.dark
        switch k {
        case .bus:
            body = Color(hex: DSCore.bus); skirt = Color(hex: 0x9C3415); band = .clear; stripe = .clear; door = Color(hex: 0x9C3415)
        case .ic:
            body = Color(hex: d ? DSCore.trainDark : DSCore.train); skirt = .clear; band = Color(hex: 0xDCE3EE)
            stripe = look.accent; door = body
        case .sprinter:
            body = Color(hex: d ? DSCore.sprinterDark : DSCore.sprinter); skirt = .clear; band = Color(hex: 0xDCE4F2)
            stripe = .clear; door = Color(hex: d ? 0x5876B4 : 0x3F5B96)
        case .train:
            body = Color(hex: d ? DSCore.trainDark : DSCore.train); skirt = .clear; band = Color(hex: 0xDCE3EE)
            stripe = .clear; door = Color(hex: d ? 0x3D5A94 : 0x22304A)
        case .tram:
            body = Color(hex: d ? DSCore.tramDark : DSCore.tram); skirt = Color(hex: d ? 0x5E3E8E : 0x4E2C78)
            band = Color(hex: 0xE7DDF3); stripe = .clear; door = Color(hex: d ? 0x6A479F : 0x5A3489)
        case .metro:
            body = Color(hex: d ? 0xAEB5BF : 0xC3C9D2); skirt = .clear; band = .clear
            stripe = Color(hex: d ? DSCore.tramDark : DSCore.tram); door = Color(hex: d ? 0x949BA6 : 0x9FA6B1)
        }
    }
}

/// One car, drawn.
private struct VehicleCar: View {
    let kind: VehicleKind
    let end: CarEnd
    let look: LiveLook
    var body: some View {
        let c = VehicleColors(kind, look)
        let shape = CarPath(kind: kind, end: end, part: .body)
        ZStack {
            CarPath(kind: kind, end: end, part: .roof).stroke(look.dark ? c.hub : c.wheel, lineWidth: 1)
            if kind != .bus {
                CarPath(kind: kind, end: end, part: .bogies).fill(c.wheel)
                CarPath(kind: kind, end: end, part: .wheels).fill(c.wheel)
            }
            ZStack {
                shape.fill(c.body)
                CarPath(kind: kind, end: end, part: .skirt).fill(c.skirt)
                CarPath(kind: kind, end: end, part: .band).fill(c.band)
                CarPath(kind: kind, end: end, part: .stripe).fill(c.stripe)
                CarPath(kind: kind, end: end, part: .doors).fill(c.door)
                CarPath(kind: kind, end: end, part: .glass).fill(c.glass)
                CarPath(kind: kind, end: end, part: .lights).fill(c.light)
                CarPath(kind: kind, end: end, part: .arches).fill(c.glass)
            }
            .clipShape(shape)
            shape.stroke(look.outline, lineWidth: 0.6)
            if kind == .bus {
                CarPath(kind: kind, end: end, part: .wheels).fill(c.wheel)
                CarPath(kind: kind, end: end, part: .hubs).fill(c.hub)
            }
        }
    }
}

/// A whole vehicle, its front on the right. `height` sets its size; `VehicleDrawing.width` its width.
struct VehicleDrawing: View {
    let kind: VehicleKind
    let height: CGFloat
    var look: LiveLook = .darkLook

    static func cars(_ k: VehicleKind) -> [CarEnd] {
        switch k {
        case .bus: return [.front]
        case .ic: return [.coach, .front]                    // a cab car and one more coach
        case .sprinter, .train, .tram, .metro: return [.back, .front]
        }
    }
    /// A car's width for its height.
    static func carAspect(_ k: VehicleKind) -> CGFloat {
        switch k {
        case .bus: return 3.3
        case .ic: return 3.9
        case .sprinter, .train: return 3.4
        case .tram: return 2.7
        case .metro: return 3.2
        }
    }
    static func gap(_ height: CGFloat) -> CGFloat { max(1, height * 0.06) }
    static func width(_ k: VehicleKind, height: CGFloat) -> CGFloat {
        let n = CGFloat(cars(k).count)
        return n * carAspect(k) * height + (n - 1) * gap(height)
    }

    var body: some View {
        let cars = Self.cars(kind), cw = Self.carAspect(kind) * height
        HStack(spacing: Self.gap(height)) {
            ForEach(Array(cars.enumerated()), id: \.offset) { _, end in
                VehicleCar(kind: kind, end: end, look: look).frame(width: cw, height: height)
            }
        }
        .background(alignment: .bottom) {                        // the couplings between the cars
            if cars.count > 1 { Rectangle().fill(Color(hex: 0x1B2431)).frame(height: height * 0.14).padding(.bottom, height * 0.24).padding(.horizontal, cw * 0.4) }
        }
        .frame(width: Self.width(kind, height: height), height: height)
        .accessibilityHidden(true)
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
