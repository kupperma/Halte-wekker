import AVFoundation
import SwiftUI
import UIKit

// MARK: brass ticket frame

/// Engraved paper, a brass double rule, corner diamonds and punched notches along the top.
struct BrassFrame: ViewModifier {
    let pal: HWPalette
    var pad: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .padding(pad)
            .background(
                ZStack {
                    LinearGradient(colors: [pal.paper, pal.paper2], startPoint: .top, endPoint: .bottom)
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width / 2, y: size.height * 1.2)
                        var r: CGFloat = 7
                        while r < size.height * 1.4 {
                            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.03)), lineWidth: 1)
                            r += 7
                        }
                    }
                }
            )
            .overlay(FrameLines(pal: pal).allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.6), radius: 14, y: 10)
    }
}

struct FrameLines: View {
    let pal: HWPalette
    var body: some View {
        Canvas { ctx, size in
            let r1 = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            let r2 = CGRect(origin: .zero, size: size).insetBy(dx: 7, dy: 7)
            ctx.stroke(Path(roundedRect: r1, cornerRadius: 1), with: .color(pal.line), lineWidth: 1)
            ctx.stroke(Path(roundedRect: r2, cornerRadius: 1), with: .color(pal.brass), lineWidth: 1.5)
            for p in [CGPoint(x: r2.minX, y: r2.minY), CGPoint(x: r2.maxX, y: r2.minY), CGPoint(x: r2.minX, y: r2.maxY), CGPoint(x: r2.maxX, y: r2.maxY)] {
                var d = Path(); d.move(to: CGPoint(x: p.x, y: p.y - 5)); d.addLine(to: CGPoint(x: p.x + 5, y: p.y)); d.addLine(to: CGPoint(x: p.x, y: p.y + 5)); d.addLine(to: CGPoint(x: p.x - 5, y: p.y)); d.closeSubpath()
                ctx.fill(d, with: .color(pal.paper)); ctx.stroke(d, with: .color(pal.brass), lineWidth: 1.3)
            }
            var x: CGFloat = 16
            while x < size.width - 10 {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: -3, width: 6, height: 6)), with: .color(HWPalette.bg))
                x += 13
            }
        }
    }
}

extension View {
    func brass(_ pal: HWPalette, pad: CGFloat = 10) -> some View { modifier(BrassFrame(pal: pal, pad: pad)) }
}

// MARK: flip tiles

struct FlipTiles: View {
    let word: String
    let pal: HWPalette
    var size: CGFloat = 1
    var body: some View {
        HStack(spacing: 4 * size) {
            ForEach(Array(word.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(HWFont.display(36 * size)).foregroundStyle(pal.accent)
                    .offset(y: 3 * size)
                    .frame(width: 38 * size, height: 54 * size)
                    .background(LinearGradient(stops: [.init(color: Color(hex: 0x1C1A22), location: 0), .init(color: Color(hex: 0x1C1A22), location: 0.49),
                                                       .init(color: Color(hex: 0x100F15), location: 0.51), .init(color: Color(hex: 0x100F15), location: 1)],
                                               startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(.black.opacity(0.65)).frame(height: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .shadow(color: .black, radius: 0, y: 2)
            }
        }
    }
}

// MARK: shiny gold (S)

struct ShinyGold: View {
    @State private var phase: CGFloat = -1
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [Color(hex: 0x9C6D15), Color(hex: 0xF4C542), Color(hex: 0xFFF6CF), Color(hex: 0xE2B23D), Color(hex: 0xA87A1E), Color(hex: 0xF4C542)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 2.6)
                .offset(x: phase * g.size.width)
        }
        .clipped()
        .onAppear { withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) { phase = -1.6 } }
    }
}

struct RatingBar: View {
    let grade: String?
    let pal: HWPalette
    var body: some View {
        if grade == "S" { ShinyGold().shadow(color: Color(hex: 0xF4C542).opacity(0.5), radius: 5) }
        else if grade == nil { pal.line }
        else { Rectangle().fill(RatingStyle.fill(grade)) }
    }
}

// MARK: boarding pass

/// The route line across the pass: one segment per ride in its rating colour, a dot per stop.
struct RouteStrip: View {
    let stops: [(name: String, time: String)]
    let grades: [String?]
    let pal: HWPalette
    var body: some View {
        GeometryReader { g in
            let n = max(1, stops.count - 1), w = g.size.width, step = w / CGFloat(n)
            ZStack(alignment: .topLeading) {
                ForEach(0..<grades.count, id: \.self) { i in
                    RatingBar(grade: grades[i], pal: pal).frame(width: step, height: 6).clipShape(Capsule())
                        .offset(x: CGFloat(i) * step, y: 6)
                }
                ForEach(0..<stops.count, id: \.self) { i in
                    let first = i == 0, last = i == stops.count - 1
                    VStack(alignment: first ? .leading : last ? .trailing : .center, spacing: 3) {
                        Circle().fill(pal.paper).overlay(Circle().stroke(HWPalette.ink, lineWidth: 3)).frame(width: 18, height: 18)
                        Text(stops[i].name.uppercased()).font(HWFont.display(11)).foregroundStyle(HWPalette.ink)
                            .multilineTextAlignment(first ? .leading : last ? .trailing : .center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(stops[i].time).font(HWFont.body(11)).foregroundStyle(pal.accent)
                    }
                    .frame(width: first || last ? 90 : 70, alignment: first ? .leading : last ? .trailing : .center)
                    .offset(x: first ? -9 : last ? w - 90 + 9 : CGFloat(i) * step - 35)
                }
            }
        }
        .frame(height: 70)
        .padding(.horizontal, 22)
    }
}

struct PassLine: Identifiable { let id = UUID(); let text: String; var warn = false }

/// One tear-off section: time, line badge, destination, a few lines and the rating stub.
struct PassSection: View {
    let time: String
    let badge: String
    let to: String
    let grade: String?
    let lines: [PassLine]
    var tag: String? = nil
    var gone = false
    let pal: HWPalette
    var extra: AnyView? = nil           // e.g. the train's class diagram
    var body: some View {
        HStack(spacing: 0) {
            RatingBar(grade: grade, pal: pal).frame(width: 4).clipShape(Capsule()).padding(.vertical, 8)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(time).font(HWFont.display(25)).foregroundStyle(pal.accent).strikethrough(gone).monospacedDigit()
                    if let tag { Text(tag).font(HWFont.display(10)).tracking(1.2).foregroundStyle(Color(hex: 0x14121A)).padding(.horizontal, 5).padding(.vertical, 3).background(pal.band) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(badge).font(HWFont.display(12)).foregroundStyle(HWPalette.ink).padding(.horizontal, 5).padding(.vertical, 3)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(HWPalette.ink, lineWidth: 1.5)).fixedSize()
                        Text(to).font(HWFont.display(15)).foregroundStyle(HWPalette.ink).lineLimit(2)
                    }
                    ForEach(lines) { l in
                        Text(l.text).font(HWFont.body(11, bold: l.warn)).foregroundStyle(l.warn ? HWPalette.warn : HWPalette.ink.opacity(0.75))
                    }
                    if let extra { extra.padding(.top, 2) }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10).padding(.vertical, 9)
            VStack(spacing: 3) {
                Coin(grade: grade, size: 30, pal: pal)
                Text("SPEED").font(HWFont.body(9)).tracking(1.4).foregroundStyle(HWPalette.ink.opacity(0.65))
            }
            .frame(width: 56)
            .padding(.vertical, 8)
            .overlay(alignment: .leading) { DottedLine(vertical: true).stroke(pal.line, style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 3])).frame(width: 1.5) }
        }
        .overlay(alignment: .top) { DottedLine(vertical: false).stroke(pal.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(height: 1.5) }
    }
}

struct DottedLine: Shape {
    let vertical: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if vertical { p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)) }
        else { p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)) }
        return p
    }
}

/// Builds the pass for a door-to-door trip.
struct BoardingPass: View {
    let trip: DoorTrip
    let home: Bool
    var options: [DoorTrip] = []
    var pick: Binding<Int>? = nil
    var nowRide: String? = nil          // ride id that's happening now
    var body: some View {
        let pal = HWPalette.of(home: home), r = trip.rides, stops = stopList()
        VStack(spacing: 0) {
            HStack {
                Text("BOARDING PASS").font(HWFont.display(13)).tracking(2).foregroundStyle(pal.brass)
                Spacer()
                Text("Nº \(String(format: "%06d", Int(trip.first.departure.timeIntervalSince1970 / 60) % 1_000_000))").font(HWFont.body(11)).foregroundStyle(HWPalette.stamp)
            }
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 7)
            Rectangle().fill(pal.line).frame(height: 1)
            HStack {
                Text((trip.via.map { "Via \($0)" } ?? "Your next trip").uppercased())
                Spacer()
                Text((home ? "Home around \(Fmt.hhmm(trip.end))" : "At BUas \(Fmt.hhmm(trip.end))").uppercased())
            }
            .font(HWFont.body(11)).tracking(0.8).foregroundStyle(HWPalette.ink.opacity(0.8)).padding(.horizontal, 12).padding(.top, 6)
            if options.count > 1, let pick {
                HStack(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                        Button { pick.wrappedValue = i } label: {
                            Text(Fmt.hhmm(o.first.departure)).font(HWFont.body(12, bold: true))
                                .foregroundStyle(i == pick.wrappedValue ? Color(hex: 0x14121A) : HWPalette.ink)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(i == pick.wrappedValue ? HWPalette.ink : .clear)
                                .overlay(Rectangle().stroke(pal.line, lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            RouteStrip(stops: stops, grades: r.map(\.grade), pal: pal).padding(.top, 12)
            ForEach(Array(r.enumerated()), id: \.element.id) { i, ride in
                PassSection(time: Fmt.hhmm(ride.departure), badge: ride.badge,
                            to: "to \(Fmt.place(ride.toStop) == "BUas" ? ride.toStop.components(separatedBy: ", ").last ?? "" : Fmt.place(ride.toStop))",
                            grade: ride.grade, lines: lines(ride, i), tag: ride.id == nowRide ? "NOW" : nil, gone: ride.cancelled, pal: pal)
            }
            HStack {
                Text("LEAVES IN \(Fmt.mins(trip.first.departure.timeIntervalSinceNow)) MIN")
                Spacer()
                Text("VALID TODAY ONLY")
            }
            .font(HWFont.body(11)).tracking(0.8).foregroundStyle(HWPalette.ink.opacity(0.85))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .overlay(alignment: .top) { DottedLine(vertical: false).stroke(pal.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(height: 1.5) }
        }
        .brass(pal, pad: 8)
    }

    private func stopList() -> [(name: String, time: String)] {
        let r = trip.rides
        var out: [(name: String, time: String)] = [(name: home ? "BUas" : "Veghel", time: Fmt.hhmm(r[0].walkBefore > 0 ? trip.start : r[0].departure))]
        for i in 0..<(r.count - 1) { out.append((name: Fmt.place(r[i].toStop), time: Fmt.hhmm(r[i + 1].departure))) }
        out.append((name: home ? "Veghel" : "BUas", time: Fmt.hhmm(trip.end)))
        return out
    }

    private func lines(_ ride: Ride, _ i: Int) -> [PassLine] {
        var out: [PassLine] = []
        let plat = ride.platform.map { " · platform \($0)" } ?? ""
        if ride.cancelled { out.append(PassLine(text: "Cancelled", warn: true)) }
        else if ride.live && abs(ride.delay) >= 1 { out.append(PassLine(text: "\(abs(ride.delay)) min \(ride.delay > 0 ? "late" : "early")\(plat)", warn: true)) }
        else { out.append(PassLine(text: "\(ride.live ? "On time" : "Timetable time")\(plat)")) }
        out.append(PassLine(text: "\(ride.rideMinutes) min ride\(i == 0 && ride.walkBefore > 0 ? " · walk \(ride.walkBefore) min first" : "")"))
        if let n = trip.rides[safe: i + 1] {
            let ch = Fmt.mins(n.departure.timeIntervalSince(ride.arrival))
            out.append(PassLine(text: "\(ch) min to change\(n.walkBefore > 0 ? ", \(n.walkBefore) min walk" : "")", warn: ch - n.walkBefore < 2))
        }
        return out
    }
}

// MARK: buttons

struct BandButton: View {
    let title: String
    let pal: HWPalette
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title.uppercased()).font(HWFont.display(16)).tracking(1.6).foregroundStyle(Color(hex: 0x0B0D14))
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(pal.band)
                .overlay(RoundedRectangle(cornerRadius: 2).inset(by: 3).stroke(.white.opacity(0.3), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}

// MARK: the station behind the home screen

/// A short looping video of the 3D station: the phone's video chip plays it for almost nothing.
final class LoopingVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var current = ""
    private var restartToken = 0
    func show(_ name: String, playing: Bool, restart: Int = 0) {
        if restart != restartToken { restartToken = restart; player.seek(to: .zero) }
        if current != name, let url = Bundle.main.url(forResource: name, withExtension: "mp4") {
            current = name
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
        }
        if playing { player.play() } else { player.pause() }
    }
}

struct StationVideo: UIViewRepresentable {
    let name: String
    let playing: Bool
    var restart = 0                 // change it to start the loop from the beginning
    func makeUIView(context: Context) -> LoopingVideoView { LoopingVideoView() }
    func updateUIView(_ v: LoopingVideoView, context: Context) { v.show(name, playing: playing, restart: restart) }
}

/// A short video that plays once each time `token` changes (the camera stepping back from the map, or towards it).
final class OneShotVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private let player = AVPlayer()
    private var current = ""
    private var token = 0
    func show(_ name: String, token t: Int) {
        if current != name, let url = Bundle.main.url(forResource: name, withExtension: "mp4") {
            current = name
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.actionAtItemEnd = .pause
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
        }
        if t != token {
            token = t
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in self?.player.play() }
        }
    }
}

struct OneShotVideo: UIViewRepresentable {
    let name: String
    let token: Int
    func makeUIView(context: Context) -> OneShotVideoView { OneShotVideoView() }
    func updateUIView(_ v: OneShotVideoView, context: Context) { v.show(name, token: token) }
}

struct StationBackdrop: View {
    let home: Bool
    let moving: Bool
    var dim: Double = 0.38
    var body: some View {
        ZStack {
            HWPalette.bg
            ForEach([false, true], id: \.self) { h in
                Group {
                    if moving { StationVideo(name: h ? "station-home" : "station-out", playing: h == home) }
                    else if let img = UIImage(named: h ? "still-home" : "still-out") ?? Bundle.main.path(forResource: h ? "still-home" : "still-out", ofType: "jpg").flatMap(UIImage.init(contentsOfFile:)) {
                        Image(uiImage: img).resizable().scaledToFill()
                    }
                }
                .opacity(h == home ? 1 : 0)
                .animation(.easeInOut(duration: 0.8), value: home)
            }
            Color.black.opacity(dim)
            RadialGradient(colors: [.clear, .black.opacity(0.6)], center: .init(x: 0.5, y: 0.3), startRadius: 120, endRadius: 520)
            FilmGrain()
        }
        .ignoresSafeArea()
    }
}

/// Old-film grain: one noise picture, shifted a few times a second.
struct FilmGrain: View {
    static let noise: UIImage = {
        let w = 160
        var px = [UInt8](repeating: 255, count: w * w * 4)
        for i in 0..<(w * w) { let v = UInt8.random(in: 0...255); px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255 }
        let img: CGImage = px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: w, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
        return UIImage(cgImage: img)
    }()
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.14)) { tl in
            let s = Int(tl.date.timeIntervalSinceReferenceDate * 7) % 7
            Image(uiImage: Self.noise).resizable(resizingMode: .tile)
                .offset(x: CGFloat((s * 37) % 70) - 35, y: CGFloat((s * 53) % 70) - 35)
                .padding(-60)
                .opacity(0.12).blendMode(.overlay)
        }
        .allowsHitTesting(false)
    }
}
