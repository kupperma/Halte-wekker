import SwiftUI

/// The boarding-pass look, shared by the app and the Live Activity.
enum HWFont {
    static func display(_ size: CGFloat) -> Font { .custom("OldStandardTT-Bold", size: size) }
    static func displayRegular(_ size: CGFloat) -> Font { .custom("OldStandardTT-Regular", size: size) }
    static func body(_ size: CGFloat, bold: Bool = false) -> Font { .custom(bold ? "CourierPrime-Bold" : "CourierPrime-Regular", size: size) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

/// Ink blue going to Breda, oxblood going home.
struct HWPalette {
    let paper: Color, paper2: Color, brass: Color, line: Color, accent: Color, band: Color
    static let ink = Color(hex: 0xEDE3CC)
    static let muted = Color(hex: 0xA79F8C)
    static let bg = Color(hex: 0x07080D)
    static let stamp = Color(hex: 0xC8432F)
    static let warn = Color(hex: 0xFFB37A)
    static let ok = Color(hex: 0x7FDCA4)
    static let toBreda = HWPalette(paper: Color(hex: 0x0F1428), paper2: Color(hex: 0x090C18), brass: Color(hex: 0xB9A066),
                                   line: Color(hex: 0x5E5A44), accent: Color(hex: 0x9BE7FF), band: Color(hex: 0x9BE7FF))
    static let home = HWPalette(paper: Color(hex: 0x1E1012), paper2: Color(hex: 0x120809), brass: Color(hex: 0xC9965A),
                                line: Color(hex: 0x76523A), accent: Color(hex: 0xFFC27A), band: Color(hex: 0xFFB45E))
    static func of(home: Bool) -> HWPalette { home ? .home : .toBreda }
}

/// S to C speed rating colours.
enum RatingStyle {
    static func fill(_ g: String?) -> AnyShapeStyle {
        switch g {
        case "S": return AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x9C6D15), Color(hex: 0xF4C542), Color(hex: 0xFFF3C4), Color(hex: 0xE2B23D), Color(hex: 0xA87A1E)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
        case "A": return AnyShapeStyle(Color(hex: 0x4CC38A))
        case "B": return AnyShapeStyle(Color(hex: 0x7AA7FF))
        case "C": return AnyShapeStyle(Color(hex: 0xE0814E))
        case "D": return AnyShapeStyle(Color(hex: 0xD9685E))
        case "F": return AnyShapeStyle(Color(hex: 0xB44A4A))
        default: return AnyShapeStyle(Color.clear)
        }
    }
    static func ink(_ g: String?) -> Color {
        switch g {
        case "S": return Color(hex: 0x3B2A00)
        case "A": return Color(hex: 0x08321D)
        case "B": return Color(hex: 0x12224D)
        case "C": return Color(hex: 0x4A1A05)
        default: return Color(hex: 0x2A0404)
        }
    }
}

/// A rating coin. The serif sits a little high in its line, so the letter is nudged down to the true centre.
struct Coin: View {
    let grade: String?
    var size: CGFloat = 26
    var pal: HWPalette = .toBreda
    var body: some View {
        ZStack {
            if let g = grade {
                Circle().fill(RatingStyle.fill(g))
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
                Text(g).font(HWFont.display(size * 0.52)).foregroundStyle(RatingStyle.ink(g))
                    .offset(y: size * 0.045)
            } else {
                Circle().stroke(pal.line, lineWidth: 1.5)
                Text("–").font(HWFont.display(size * 0.5)).foregroundStyle(pal.line)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(grade.map { "Speed rating \($0)" } ?? "No rating")
    }
}
