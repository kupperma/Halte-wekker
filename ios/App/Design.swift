import SwiftUI
import UIKit

/// The new look's design tokens (0.19): colours, type, shapes and spacing. Every new screen uses only these.
/// Light values from the design; dark ones derived to keep the same contrast (text ≥ WCAG AA on its surface).
enum DS {
    // MARK: colours

    /// A colour that follows the phone's light or dark setting.
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }

    static let text = dynamic(0x14171A, 0xECEEF0)
    static let secondary = dynamic(0x5B636B, 0xA3ABB3)
    /// Cards and sheets.
    static let surface = dynamic(0xFFFFFF, 0x1C1F23)
    /// Grouped rows inside a card, the page behind lists.
    static let surface2 = dynamic(0xF6F7F9, 0x24282D)
    /// Quiet buttons and chips.
    static let surface3 = dynamic(0xF1F3F5, 0x2C3137)
    static let divider = dynamic(0xECEEF0, 0x33383E)
    /// The one accent: fills (white text on it, 5.0:1).
    static let accent = Color(hex: DSCore.accent)
    /// The accent as text or an icon on a surface.
    static let accentText = dynamic(DSCore.accent, DSCore.accentTextDark)
    static let accentSoft = dynamic(0xE3F3EC, 0x163A2C)
    static let accentSoftText = dynamic(0x0A5C40, 0x8FE0BB)
    /// Late, cancelled, a tight change.
    static let warning = dynamic(DSCore.warning, DSCore.warningDark)
    static let onAccent = Color.white

    // line pills, by mode (white text on them)
    // (white text on each ≥ 4.5:1 in both modes; the values the Live Activity shares are in Shared/DesignShared.swift)
    static let train = dynamic(DSCore.train, DSCore.trainDark)
    static let bus = Color(hex: DSCore.bus)
    static let tram = dynamic(DSCore.tram, DSCore.tramDark)
    static let ferry = dynamic(0x1C6E8C, 0x2A7898)

    // "Next trip first" (0.19.1, concept B): dark-first, the same tokens plus these two
    /// The page behind its cards: the week view and the bottom bar (the map's dark ground).
    /// (secondary on it 5.5:1 light, 8.0:1 dark; the accent text 4.8:1 / 8.7:1)
    static let page = dynamic(0xF1F3F5, 0x111417)
    /// The walk and wait parts of a leg bar (a shape, ≥ 3:1 on the card: 3.2:1 light, 3.5:1 dark).
    static let legQuiet = dynamic(0x8A929A, 0x6B747E)

    /// The pill colour for a line: a train, a bus, or (by the live data's mode name) tram, metro or ferry.
    static func mode(train: Bool, mode: String = "") -> Color {
        let m = mode.uppercased()
        if m.contains("TRAM") || m.contains("SUBWAY") || m.contains("METRO") { return tram }
        if m.contains("FERRY") { return ferry }
        return train ? DS.train : bus
    }

    // MARK: type (system font; text styles so Dynamic Type works)

    static let largeTitle = Font.system(.title, design: .default, weight: .bold)
    static let title = Font.system(.title2, design: .default, weight: .bold)
    static let headline = Font.system(.headline, design: .default, weight: .bold)
    static let body = Font.system(.body, design: .default, weight: .regular)
    static let bodyStrong = Font.system(.body, design: .default, weight: .semibold)
    static let callout = Font.system(.callout, design: .default, weight: .regular)
    static let calloutStrong = Font.system(.callout, design: .default, weight: .semibold)
    static let sub = Font.system(.subheadline, design: .default, weight: .regular)
    static let subStrong = Font.system(.subheadline, design: .default, weight: .semibold)
    static let footnote = Font.system(.footnote, design: .default, weight: .regular)
    static let footnoteStrong = Font.system(.footnote, design: .default, weight: .semibold)
    static let caption = Font.system(.caption, design: .default, weight: .bold)
    /// Big numbers (times, countdowns): rounded; always with `.monospacedDigit()`.
    static let bigNumber = Font.system(.title2, design: .rounded, weight: .bold)
    /// The one big number of a screen (the next trip's countdown): rounded, at a size the view scales with
    /// `@ScaledMetric`; always with `.monospacedDigit()`.
    static func hero(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }

    // MARK: shapes and spacing

    static let cardRadius: CGFloat = 24
    static let cardRadiusSmall: CGFloat = 22
    static let chipRadius: CGFloat = 20
    static let fieldRadius: CGFloat = 16
    static let pillRadius: CGFloat = 6
    /// Inner radius = outer radius − padding.
    static func inner(_ outer: CGFloat, padding: CGFloat) -> CGFloat { max(4, outer - padding) }

    static let s4: CGFloat = 4, s8: CGFloat = 8, s12: CGFloat = 12, s16: CGFloat = 16, s20: CGFloat = 20, s24: CGFloat = 24
    /// The side margin over the map.
    static let edge: CGFloat = 12
    static let hit: CGFloat = 44
    static let cta: CGFloat = 56

    // MARK: motion: short, eased, for feedback only
    static let quick = Animation.easeOut(duration: 0.2)
    static let move = Animation.spring(response: 0.38, dampingFraction: 0.86)
}

/// The window's light or dark: the new home follows the phone, the screens still in the old look stay dark. (Set on
/// the window as well as by `preferredColorScheme`, which doesn't always let go of a forced dark when given nil.)
@MainActor
enum WindowStyle {
    static func apply(dark: Bool) {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows { w.overrideUserInterfaceStyle = dark ? .dark : .unspecified }
        }
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

extension View {
    /// A card: the surface, the radius and one soft shadow.
    func dsCard(radius: CGFloat = DS.cardRadius, padding: CGFloat = DS.s16) -> some View {
        self.padding(padding)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    }

    /// Something floating over the map (search field, chips, round buttons): a lighter shadow.
    func dsFloat() -> some View { shadow(color: .black.opacity(0.14), radius: 8, y: 2) }
}

/// A line's pill: "IC", "306", in its mode's colour.
struct DSLinePill: View {
    let line: String
    let train: Bool
    var mode: String = ""
    var body: some View {
        Text(line.isEmpty ? "?" : line)
            .font(DS.caption).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(DS.onAccent)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .frame(minWidth: 34)
            .background(DS.mode(train: train, mode: mode), in: RoundedRectangle(cornerRadius: DS.pillRadius, style: .continuous))
            .accessibilityLabel(train ? "Train \(line)" : "Line \(line)")
    }
}

/// The main button of a screen: 56 pt, accent filled.
struct DSPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var lines = 1
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.body.weight(.semibold)) }
                Text(title).font(DS.bodyStrong).lineLimit(lines).minimumScaleFactor(0.8).multilineTextAlignment(.center)
            }
            .padding(.horizontal, DS.s16).padding(.vertical, lines > 1 ? 6 : 0)
            .foregroundStyle(DS.onAccent)
            .frame(maxWidth: .infinity, minHeight: DS.cta)
            .background(DS.accent, in: Capsule())
            .shadow(color: DS.accent.opacity(0.35), radius: 9, y: 6)
        }
        .buttonStyle(DSPressStyle())
    }
}

/// A short squash on press: the feedback that a tap landed.
struct DSPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A grey placeholder row while something loads.
struct DSSkeletonRow: View {
    @State private var dim = false
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: DS.pillRadius).frame(width: 38, height: 18)
            RoundedRectangle(cornerRadius: 4).frame(height: 14)
            RoundedRectangle(cornerRadius: 4).frame(width: 46, height: 14)
        }
        .foregroundStyle(DS.surface3)
        .opacity(dim ? 0.55 : 1)
        .padding(.vertical, 6)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true } }
        .accessibilityHidden(true)
    }
}
