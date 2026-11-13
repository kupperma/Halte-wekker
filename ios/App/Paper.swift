import SwiftUI

/// The pinned-paper look: every screen is paper pinned to the station's blue wall, like the metro map. Cream paper with
/// the map's wear (stains, smudges, a coffee ring), navy header bands, tape, stickers, and the lines in the map's colours.
enum Paper {
    static let paper = Color(hex: 0xF7F5EF)
    static let card = Color(hex: 0xEEE9DC)         // a box on the paper: the paper a shade deeper (white stood out)
    static let ink = Color(hex: 0x1D1D1B)
    static let muted = Color(hex: 0x6B6B6B)
    static let soft = Color(hex: 0x8A877F)
    static let rule = Color(hex: 0xDDD9CE)
    static let edge = Color(hex: 0xCFC9BA)
    static let navy = Color(hex: 0x1D2C5A)
    static let oxblood = Color(hex: 0x7A2A1E)
    static let ok = Color(hex: 0x3F7F2A)
    static let late = Color(hex: 0xB5481F)
    static let green = Color(hex: 0x5E9A36)        // buttons (white text on it)
    static let yellow = Color(hex: 0xF0D722)
    static let tape = Color(red: 236 / 255, green: 226 / 255, blue: 196 / 255)
    static let wallTop = Color(hex: 0x1F4A86), wallMid = Color(hex: 0x122C58), wallBottom = Color(hex: 0x0D2147)
    static let ic = Color(hex: 0x224F86), spr = Color(hex: 0x528DBA)

    /// The header band: navy going to Breda, oxblood going home (like the map).
    static func band(home: Bool) -> Color { home ? oxblood : navy }

    /// A line in the map's colours: the 306 red, the 305 orange, the 158 teal, Intercitys dark blue, Sprinters light blue,
    /// the buses to BUas purple, any other line its own colour that stays the same.
    static func line(_ l: String, train: Bool) -> Color {
        if train { return l.uppercased().hasPrefix("SPR") || l.lowercased().contains("sprinter") ? spr : ic }
        switch l {
        case "306": return Color(hex: 0xDA421E)
        case "305": return Color(hex: 0xF3791D)
        case "158": return Color(hex: 0x2E9C8F)
        case "1", "5": return Color(hex: 0x8C6DAB)
        default:
            let palette: [UInt32] = [0x8C6DAB, 0x2E9C8F, 0xC8578F, 0x7E5330, 0x5B8C3A, 0xB08A1E, 0x3E7CB1, 0xA0522D, 0x6A7F2A, 0xD35F8D]
            let h = l.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return Color(hex: palette[h % palette.count])
        }
    }

    /// The map's wear and tear, laid over the paper.
    static let grime: UIImage? = Bundle.main.path(forResource: "map-grime", ofType: "png").flatMap(UIImage.init(contentsOfFile:))
    static let smile: UIImage? = Bundle.main.path(forResource: "sticker-smile", ofType: "png").flatMap(UIImage.init(contentsOfFile:))
}

/// The blue station wall behind the paper.
struct WallBackground: View {
    var body: some View {
        ZStack {
            RadialGradient(colors: [Paper.wallTop, Paper.wallMid, Paper.wallBottom], center: .init(x: 0.5, y: 0.3), startRadius: 20, endRadius: 700)
            if let g = Paper.grime { Image(uiImage: g).resizable().blendMode(.screen).opacity(0.16) }
        }
        .ignoresSafeArea()
    }
}

/// Paper, with the map's wear on it.
struct PaperFill: View {
    var body: some View {
        ZStack {
            Paper.paper
            if let g = Paper.grime { Image(uiImage: g).resizable().blendMode(.multiply).opacity(0.85) }
        }
    }
}

/// A strip of tape holding the paper to the wall.
struct Tape: View {
    var angle: Double = -5
    var width: CGFloat = 84
    var body: some View {
        Rectangle().fill(Paper.tape.opacity(0.85)).frame(width: width, height: 22)
            .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
            .rotationEffect(.degrees(angle))
            .allowsHitTesting(false)
    }
}

/// A sticker on the wall ("306 ♥", "I ♥ BRABANT").
struct WallSticker: View {
    let text: String
    var fill = Color(hex: 0x8FC1F0)
    var angle: Double = 8
    var body: some View {
        Text(text).font(.system(size: 13, weight: .black)).foregroundStyle(Color(hex: 0x112233))
            .padding(.horizontal, 8).padding(.vertical, 4).background(fill)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 2)
            .rotationEffect(.degrees(angle))
            .allowsHitTesting(false)
    }
}

extension View {
    /// A sheet of paper pinned to the wall: the paper, a thin edge, a shadow and two strips of tape at the top.
    func paperSheet(tape: Bool = true, opacity: Double = 1) -> some View {
        background(PaperFill().opacity(opacity))
            .overlay(Rectangle().stroke(Paper.edge, lineWidth: 1).allowsHitTesting(false))
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
            .overlay(alignment: .top) {
                if tape {
                    HStack { Tape(angle: -6); Spacer(); Tape(angle: 5) }.padding(.horizontal, 22).offset(y: -11)
                }
            }
    }

    /// A white box on the paper.
    func paperCard(_ radius: CGFloat = 6, pad: CGFloat = 12) -> some View {
        padding(pad)
            .background(Paper.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Paper.edge, lineWidth: 1.2))
    }
}

/// The navy (or oxblood) band at the top of a sheet, set in from the edge like on the map.
struct PaperBand<Content: View>: View {
    var home = false
    let content: Content
    init(home: Bool = false, @ViewBuilder content: () -> Content) { self.home = home; self.content = content() }
    var body: some View {
        content
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.band(home: home))
            .padding(.horizontal, 6).padding(.top, 6)
    }
}

/// A line's bullet in its map colour, with how steady it is (S to C, at that time of day) as a small coin on the corner.
struct LineBullet: View {
    let line: String
    var train = false
    var grade: String? = nil            // another rank to show instead
    var at: Date? = nil                 // when it runs (rush hour or not); now if not given
    var height: CGFloat = 22
    var minWidth: CGFloat = 34
    var font: CGFloat = 13
    var steady = true
    var body: some View {
        let grade = self.grade ?? (steady && !line.isEmpty && line != "?" ? Steady.rank(line: line, train: train, at: at ?? Date()) : nil)
        return Text(line).font(.system(size: font, weight: .heavy)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, 6).frame(minWidth: minWidth).frame(height: height)
            .background(Paper.line(line, train: train), in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .topTrailing) {
                if let grade { Coin(grade: grade, size: max(13, height * 0.62)).offset(x: 6, y: -6) }
            }
            .padding(.trailing, grade == nil ? 0 : 6).padding(.top, grade == nil ? 0 : 4)
            .accessibilityLabel("\(train ? "" : "Bus ")\(line)\(grade.map { ", rank \($0)" } ?? "")")
    }
}

/// The tabs along the top of the boards: the map's letter tiles.
struct PaperTabs: View {
    let section: HomeSection
    let pick: (HomeSection) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(HomeSection.board) { s in
                Button { pick(s) } label: {
                    HStack(spacing: 5) {
                        Text(s.letter).font(.system(size: 11, weight: .heavy)).foregroundStyle(s.letterInk)
                            .frame(width: 19, height: 19).background(s.tile, in: RoundedRectangle(cornerRadius: 3))
                        Text(s.short).font(.system(size: 11.5, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(s == section ? .white : Paper.ink.opacity(0.85))
                    .padding(.leading, 4).padding(.trailing, 7).padding(.vertical, 4)
                    .background(s == section ? Paper.navy : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(s == section ? Paper.navy : Color(hex: 0xB9B5AA), lineWidth: 1.2))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(s == section ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}

extension HomeSection {
    var letter: String {
        switch self { case .fastest: return "F"; case .lines: return "A"; case .planned: return "P"; case .more: return "M" }
    }
    var short: String {
        switch self { case .fastest: return "Trips"; case .lines: return "All lines"; case .planned: return "Planned"; case .more: return "More" }
    }
    var tile: Color {
        switch self {
        case .fastest: return Color(hex: 0xF0D722)
        case .lines: return Color(hex: 0x7DAD4C)
        case .planned: return Color(hex: 0x7E5330)
        case .more: return Color(hex: 0x8E8E8E)
        }
    }
    var letterInk: Color { self == .fastest ? Paper.ink : .white }
}

/// The trains as a printed timetable on paper (instead of the LED board): time, the train's bullet, where it goes,
/// the platform and how it's doing. Tap one for its page.
struct PaperTrainSheet: View {
    let title: String
    let sub: String
    var home = false
    let rows: [LEDTrain]
    let tap: (String) -> Void
    @State private var page = 0
    private var pages: Int { max(1, (rows.count + 3) / 4) }
    var body: some View {
        VStack(spacing: 0) {
            PaperBand(home: home) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 20, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                        Text(sub).font(.system(size: 11)).opacity(0.8).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if pages > 1 {
                        HStack(spacing: 4) {
                            pageButton("chevron.left", enabled: page > 0) { page -= 1 }
                            Text("\(min(page, pages - 1) + 1)/\(pages)").font(.system(size: 11, weight: .semibold)).opacity(0.85).monospacedDigit()
                            pageButton("chevron.right", enabled: page + 1 < pages) { page += 1 }
                        }
                    } else {
                        TimelineView(.everyMinute) { tl in Text(Fmt.hhmm(tl.date)).font(.system(size: 12, weight: .semibold)).opacity(0.85) }
                    }
                }
            }
            let p = min(page, pages - 1)
            let shown = Array(rows.dropFirst(p * 4).prefix(4))
            VStack(spacing: 0) {
                if rows.isEmpty {
                    Text("Looking up the trains…").font(.system(size: 12)).foregroundStyle(Paper.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                }
                ForEach(shown) { r in
                    Button { tap(r.id) } label: { row(r) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 6)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .paperSheet()
    }

    private func pageButton(_ icon: String, enabled: Bool, _ go: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { go() } } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).frame(width: 26, height: 22)
                .background(Color.white.opacity(enabled ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain).disabled(!enabled)
    }

    private func row(_ r: LEDTrain) -> some View {
        let (dest, line) = Self.split(r.to)
        let ok = r.status == "On time"
        let bad = r.status == "Cancelled" || r.platform.hasSuffix("!")
        return HStack(spacing: 9) {
            Text(r.time).font(.system(size: 14, weight: .heavy)).monospacedDigit().lineLimit(1).fixedSize().frame(width: 46, alignment: .leading)
            LineBullet(line: line.isEmpty ? "IC" : line, train: true, height: 19, minWidth: 32, font: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(dest).font(.system(size: 13.5, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(r.via).font(.system(size: 10.5)).foregroundStyle(Paper.muted).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 4)
            if !r.platform.isEmpty {
                Text("pl \(r.platform.replacingOccurrences(of: "!", with: ""))").font(.system(size: 11, weight: r.platform.hasSuffix("!") ? .heavy : .regular))
                    .foregroundStyle(r.platform.hasSuffix("!") ? Paper.late : Paper.muted)
            }
            Text(r.status).font(.system(size: 11, weight: .bold)).foregroundStyle(bad ? Paper.late : ok ? Paper.ok : Paper.muted)
                .lineLimit(1).minimumScaleFactor(0.7).frame(width: 56, alignment: .trailing)
        }
        .foregroundStyle(Paper.ink)
        .opacity(r.gone ? 0.45 : 1)
        .padding(.vertical, 6)
        .background(r.picked ? Paper.yellow.opacity(0.25) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.rule).frame(height: 1) }
        .contentShape(Rectangle())
    }

    /// "Vlissingen IC" → ("Vlissingen", "IC")
    static func split(_ s: String) -> (String, String) {
        let parts = s.split(separator: " ")
        guard let last = parts.last, ["IC", "ICD", "SPR", "ICE", "EC", "IR"].contains(String(last)) else { return (s, "") }
        return (parts.dropLast().joined(separator: " "), String(last))
    }
}

extension HWPalette {
    /// The palette's colour on paper: navy going to Breda, oxblood going home (its light accent is for dark screens).
    var deep: Color { band == HWPalette.home.band ? Paper.oxblood : Paper.navy }
}

/// The phone's safe area (the clock and the Dynamic Island at the top, the home bar at the bottom), for screens drawn
/// edge to edge, where SwiftUI reports none.
enum ScreenInsets {
    static var now: UIEdgeInsets {
        let w = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        return w?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    }
}
