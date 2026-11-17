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
    /// Line pills and drawings, by mode.
    static let bus: UInt32 = 0xC4461F
    static let train: UInt32 = 0x2B3A55
    static let trainDark: UInt32 = 0x4A68A8
    /// The sprinter's lighter blue (only the drawings and glyphs; its pill is a train's).
    static let sprinter: UInt32 = 0x4F6FB0
    static let sprinterDark: UInt32 = 0x6A88C6
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
    /// A thin edge round the drawings, so a navy train still shows on a dark surface.
    var outline: Color { dark ? Color.white.opacity(0.22) : Color.black.opacity(0.22) }

    static let light = LiveLook(dark: false)
    static let darkLook = LiveLook(dark: true)
    static let islandLook = LiveLook(dark: true, island: true)
    static func of(_ scheme: ColorScheme) -> LiveLook { scheme == .dark ? .darkLook : .light }

    /// A line pill's fill: orange for a bus, navy for every train, purple for a tram or metro.
    func pill(_ k: VehicleKind) -> Color {
        switch k {
        case .bus: return Color(hex: DSCore.bus)
        case .tram, .metro: return Color(hex: dark ? DSCore.tramDark : DSCore.tram)
        case .ic, .sprinter, .train: return Color(hex: dark ? DSCore.trainDark : DSCore.train)
        }
    }

    /// A vehicle glyph's colour (the sprinter in its lighter blue).
    func glyph(_ k: VehicleKind) -> Color {
        k == .sprinter ? Color(hex: dark ? DSCore.sprinterDark : DSCore.sprinter) : pill(k)
    }
}
