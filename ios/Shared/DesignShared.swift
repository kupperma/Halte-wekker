import SwiftUI

/// The few colours of the new look (0.19) that the app and the Live Activity both need. The app's `DS` takes these
/// values; the widget can't see App files, so it reads them from here.
enum DSCore {
    /// The one accent: fills (white text on it).
    static let accent: UInt32 = 0x0E7A55
    /// The accent as text or an icon on a dark surface.
    static let accentTextDark: UInt32 = 0x4CC792
    /// Late, cancelled, a tight change, "Wake up".
    static let warning: UInt32 = 0xA84219
    static let warningDark: UInt32 = 0xFF8A5C
    /// Line pills, glyphs and drawings, by kind (set C1, 0.20.4): the bus orange, the intercity indigo, the sprinter
    /// cyan; each with a slightly darker shade (the drawings' doors) and a slightly lighter one (their stripe and nose).
    /// A train it can't tell more about takes the intercity's. White bold text on each: bus 3.5:1, intercity 8.0:1,
    /// sprinter 3.6:1 (fine at pill size: bold, and AA for large text).
    static let bus: UInt32 = 0xE0632E
    static let busLight: UInt32 = 0xE4794B
    static let busDoor: UInt32 = 0xC55728
    static let intercity: UInt32 = 0x3B44B0
    static let intercityLight: UInt32 = 0x565EBB
    static let intercityDoor: UInt32 = 0x343C9B
    static let sprinter: UInt32 = 0x0A93B5
    static let sprinterLight: UInt32 = 0x2CA2BF
    static let sprinterDoor: UInt32 = 0x09819F
    static let tram: UInt32 = 0x6B3FA0
    static let tramDark: UInt32 = 0x7A55B0
}

/// The Live Activity's colours, for the phone's light or dark (the Dynamic Island is always dark).
struct LiveLook {
    let dark: Bool
    /// The Dynamic Island: dark, on its black.
    var island = false
    var surface: Color { island ? .black : Color(hex: dark ? 0x1E2126 : 0xFFFFFF) }
    var text: Color { Color(hex: dark ? 0xECEEF0 : 0x14171A) }
    var secondary: Color { Color(hex: dark ? 0xA3ABB3 : 0x5B636B) }
    /// The track's line and the stops still to come.
    var track: Color { Color(hex: dark ? 0x3A4047 : 0xDDE1E5) }
    var trackStrong: Color { Color(hex: dark ? 0x6B747E : 0x8A929A) }
    /// The accent as text, an icon or a dot.
    var accent: Color { Color(hex: dark ? DSCore.accentTextDark : DSCore.accent) }
    var warning: Color { Color(hex: dark ? DSCore.warningDark : DSCore.warning) }
    /// A thin edge round the tram and metro drawings, so they still show on the surface.
    var outline: Color { dark ? Color.white.opacity(0.22) : Color.black.opacity(0.22) }

    static let light = LiveLook(dark: false)
    static let darkLook = LiveLook(dark: true)
    static let islandLook = LiveLook(dark: true, island: true)
    static func of(_ scheme: ColorScheme) -> LiveLook { scheme == .dark ? .darkLook : .light }

    /// A line pill's fill, and the vehicle glyph's colour: orange for a bus, indigo for an intercity (and a train it
    /// can't tell more about), cyan for a sprinter, purple for a tram or metro.
    func pill(_ k: VehicleKind) -> Color {
        switch k {
        case .bus: return Color(hex: DSCore.bus)
        case .tram, .metro: return Color(hex: dark ? DSCore.tramDark : DSCore.tram)
        case .ic, .train: return Color(hex: DSCore.intercity)
        case .sprinter: return Color(hex: DSCore.sprinter)
        }
    }
    func glyph(_ k: VehicleKind) -> Color { pill(k) }
}
