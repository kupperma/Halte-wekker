import SwiftUI

// A New York-style metro seen from the side, drawn with plain shapes so it also works on the lock screen.
// It drives along a track as your trip goes on and has pulled into the platform when you arrive.

private struct CarShell: Shape {
    var front: Bool
    func path(in r: CGRect) -> Path {
        let b = r.height * 0.84
        return UnevenRoundedRectangle(topLeadingRadius: b * 0.14, bottomLeadingRadius: b * 0.06,
                                      bottomTrailingRadius: b * 0.06, topTrailingRadius: front ? b * 0.42 : b * 0.14)
            .path(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: b))
    }
}

private let doorsAt: [CGFloat] = [0.29, 0.64]

private struct CarWindows: Shape {
    var front: Bool
    func path(in r: CGRect) -> Path {
        let b = r.height * 0.84, w = r.width
        var p = Path()
        let wins: [CGFloat] = front ? [0.05, 0.14, 0.40, 0.49, 0.74, 0.82] : [0.05, 0.14, 0.40, 0.49, 0.75, 0.84]
        for x in wins {
            p.addRoundedRect(in: CGRect(x: r.minX + w * x, y: r.minY + b * 0.2, width: w * 0.07, height: b * 0.32), cornerSize: CGSize(width: 1.2, height: 1.2))
        }
        for d in doorsAt {                                        // the little windows in each door pair
            for s in [-1.0, 1.0] as [CGFloat] {
                p.addRect(CGRect(x: r.minX + w * (d + s * 0.02) - w * 0.008, y: r.minY + b * 0.2, width: w * 0.016, height: b * 0.3))
            }
        }
        if front { p.addRoundedRect(in: CGRect(x: r.minX + w * 0.915, y: r.minY + b * 0.18, width: w * 0.06, height: b * 0.32), cornerSize: CGSize(width: 2, height: 2)) }
        return p
    }
}

private struct CarDoors: Shape {
    func path(in r: CGRect) -> Path {
        let b = r.height * 0.84, w = r.width
        var p = Path()
        for d in doorsAt {
            p.addRect(CGRect(x: r.minX + w * (d - 0.04), y: r.minY + b * 0.1, width: w * 0.08, height: b * 0.86))
            p.move(to: CGPoint(x: r.minX + w * d, y: r.minY + b * 0.1)); p.addLine(to: CGPoint(x: r.minX + w * d, y: r.minY + b * 0.96))
        }
        return p
    }
}

private struct CarStripe: Shape {
    func path(in r: CGRect) -> Path {
        let b = r.height * 0.84
        return Path(CGRect(x: r.minX, y: r.minY + b * 0.64, width: r.width, height: max(1, b * 0.07)))
    }
}

private struct CarWheels: Shape {
    func path(in r: CGRect) -> Path {
        let rad = r.height * 0.1, w = r.width
        var p = Path()
        for x in [0.11, 0.2, 0.8, 0.89] as [CGFloat] {
            p.addEllipse(in: CGRect(x: r.minX + w * x - rad, y: r.maxY - rad * 2, width: rad * 2, height: rad * 2))
        }
        p.addRect(CGRect(x: r.minX + w * 0.08, y: r.minY + r.height * 0.82, width: w * 0.15, height: r.height * 0.06))
        p.addRect(CGRect(x: r.minX + w * 0.77, y: r.minY + r.height * 0.82, width: w * 0.15, height: r.height * 0.06))
        return p
    }
}

private struct Headlight: Shape {
    func path(in r: CGRect) -> Path {
        let b = r.height * 0.84, s = b * 0.13
        return Path(ellipseIn: CGRect(x: r.maxX - s * 1.9, y: r.minY + b * 0.7, width: s, height: s))
    }
}

struct MetroCar: View {
    var front = false
    let home: Bool
    var body: some View {
        let pal = HWPalette.of(home: home)
        ZStack {
            CarWheels().fill(Color(hex: 0x14161B))
            CarShell(front: front).fill(LinearGradient(colors: [Color(hex: 0xE6EAF0), Color(hex: 0xB3BAC6), Color(hex: 0x7C8494)], startPoint: .top, endPoint: .bottom))
            CarShell(front: front).stroke(Color.black.opacity(0.4), lineWidth: 0.6)
            CarStripe().fill(pal.accent.opacity(0.9))
            CarDoors().stroke(Color.black.opacity(0.38), lineWidth: 0.6)
            CarWindows(front: front).fill(home ? Color(hex: 0xFFE2B0) : Color(hex: 0xCDEEFF))
            if front { Headlight().fill(Color(hex: 0xFFF6CF)).shadow(color: Color(hex: 0xFFE9A0), radius: 3) }
        }
    }
}

/// Three cars, the front one on the right (it drives left to right).
struct MetroTrain: View {
    let home: Bool
    var cars = 3
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<cars, id: \.self) { i in MetroCar(front: i == cars - 1, home: home) }
        }
    }
}

/// The track along the bottom of the ride screen and the lock screen. `progress` 0…1 moves the train's nose.
/// A stop along the way: its name, when you're there, and where it is on the track (0…1).
struct StopMark: Identifiable, Hashable {
    var id: String { "\(name)|\(fraction)" }
    let name: String
    let time: Date?
    let fraction: Double
}

struct MetroTrack: View {
    let progress: Double
    let home: Bool
    var cars = 3
    var stops: [Double] = []            // ticks for the stops along the way
    /// Where a point of the trip (0…1) sits along the track, as a share of its width.
    static func x(_ f: Double) -> Double { 0.04 + 0.96 * min(1, max(0, f)) }
    var body: some View {
        let pal = HWPalette.of(home: home)
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let carH = h - 3
            let carW = carH * 4.3
            let trainW = carW * CGFloat(cars) + CGFloat(cars - 1) * 2
            let nose = (0.04 + 0.96 * min(1, max(0, progress))) * w
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(pal.brass.opacity(0.45)).frame(width: w, height: 1)
                Rectangle().fill(pal.accent).frame(width: nose, height: 1.5)
                ForEach(Array(stops.enumerated()), id: \.offset) { _, f in
                    Circle().fill(f <= progress ? pal.accent : HWPalette.ink.opacity(0.85)).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                        .offset(x: Self.x(f) * w - 3, y: 0)
                }
                MetroTrain(home: home, cars: cars)
                    .frame(width: trainW, height: carH)
                    .offset(x: nose - trainW, y: -2)
            }
            .frame(width: w, height: h, alignment: .bottomLeading)
            .animation(.easeInOut(duration: 2), value: progress)
        }
        .clipped()
        .accessibilityLabel("Trip \(Int(min(1, max(0, progress)) * 100)) percent done")
    }
}
