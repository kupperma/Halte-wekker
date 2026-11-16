import AppIntents
import PhotosUI
import SwiftUI

/// One of the drawn backgrounds for the morning screen (in the app's Media folder as morning-<id>.jpg, with a small
/// morning-<id>-t.jpg for the picker). `light`: a pale picture, so the time is written in ink instead of white.
struct MorningPreset: Hashable, Identifiable {
    let id: String
    let title: String
    let light: Bool

    static let all: [MorningPreset] = [
        .init(id: "sunrise", title: "Sunrise", light: false),
        .init(id: "brabant", title: "Brabant", light: false),
        .init(id: "splitflap", title: "Departures", light: false),
        .init(id: "riso", title: "Riso", light: true),
        .init(id: "delft", title: "Delft blue", light: true),
        .init(id: "constellation", title: "Stars", light: false),
        .init(id: "breda", title: "Breda", light: false),
        .init(id: "papermap", title: "Map & coffee", light: false),
        .init(id: "rails", title: "Rails", light: false),
        .init(id: "bauhaus", title: "Bauhaus", light: true),
    ]
    static func named(_ id: String) -> MorningPreset? { all.first { $0.id == id } }

    var thumbnail: UIImage? { Bundle.main.path(forResource: "morning-\(id)-t", ofType: "jpg").flatMap(UIImage.init(contentsOfFile:)) }
}

/// What the morning screen shows behind the time: the moving metro station, one of the drawn designs, or a photo of yours.
enum MorningLook: Hashable {
    case station
    case preset(MorningPreset)
    case photo(String)

    /// How it's remembered: "station", "p:<id>" or "u:<file name>".
    var key: String {
        switch self {
        case .station: return "station"
        case .preset(let p): return "p:" + p.id
        case .photo(let n): return "u:" + n
        }
    }
    init?(key: String) {
        if key == "station" { self = .station }
        else if key.hasPrefix("p:"), let p = MorningPreset.named(String(key.dropFirst(2))) { self = .preset(p) }
        else if key.hasPrefix("u:") { self = .photo(String(key.dropFirst(2))) }
        else { return nil }
    }
    var light: Bool { if case .preset(let p) = self { return p.light }; return false }
}

/// The morning screen after the school alarm: the time, and the day on a sheet of paper (when to leave, the bus, when
/// you're at BUas, your first class), over the metro station, a drawn design or one of your photos. Pick several and
/// they take turns, one each morning. It shows when you tap Open on the alarm, or the first time you open the app after
/// it rang that morning.
@MainActor
final class Morning: ObservableObject {
    static let shared = Morning()
    @Published var showing = false { didSet { if !showing { preview = nil } } }
    @Published var on: Bool { didSet { UserDefaults.standard.set(on, forKey: "morning.on") } }
    @Published private(set) var photos: [String]            // file names, in the app's own folder
    @Published private(set) var chosen: [String]            // MorningLook keys, taking turns
    /// Shown instead of today's look, until the morning screen closes (to try one from Settings).
    @Published var preview: String?

    private var cached: (key: String, image: UIImage)?

    private init() {
        on = UserDefaults.standard.object(forKey: "morning.on") as? Bool ?? true
        let stored = (UserDefaults.standard.stringArray(forKey: "morning.photos") ?? [])
            .filter { FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent($0).path) }
        photos = stored
        if let c = UserDefaults.standard.stringArray(forKey: "morning.chosen") {
            chosen = c
        } else {
            // before there were designs your photos took turns: keep that, else the station
            chosen = stored.isEmpty ? ["station"] : stored.map { "u:" + $0 }
        }
        chosen = chosen.filter(valid)
        if chosen.isEmpty { chosen = ["station"] }
    }

    nonisolated static var dir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Morning", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func valid(_ key: String) -> Bool {
        guard let l = MorningLook(key: key) else { return false }
        if case .photo(let n) = l { return photos.contains(n) }
        return true
    }

    private func persist() {
        UserDefaults.standard.set(photos, forKey: "morning.photos")
        UserDefaults.standard.set(chosen, forKey: "morning.chosen")
    }

    /// Everything you can pick, in the order of the picker.
    var all: [MorningLook] { [.station] + MorningPreset.all.map { .preset($0) } + photos.map { .photo($0) } }

    func isChosen(_ l: MorningLook) -> Bool { chosen.contains(l.key) }

    /// Tap in the picker: in or out of the turns. One always stays.
    func toggle(_ l: MorningLook) {
        if let i = chosen.firstIndex(of: l.key) {
            guard chosen.count > 1 else { return }
            chosen.remove(at: i)
        } else {
            chosen.append(l.key)
        }
        persist()
    }

    /// Today's look: the next one of your picks each day (or the one you're trying from Settings).
    func look(for day: Date = Date()) -> MorningLook {
        if let p = preview, let l = MorningLook(key: p), valid(p) { return l }
        let picks = chosen.compactMap(MorningLook.init(key:))
        guard !picks.isEmpty else { return .station }
        let n = Calendar.current.ordinality(of: .day, in: .era, for: day) ?? 0
        return picks[n % picks.count]
    }

    /// The full picture for a drawn design or a photo (the station is a video, so nil). The last one is kept, so the
    /// screen doesn't read the file again each time it redraws.
    func image(_ l: MorningLook) -> UIImage? {
        if let c = cached, c.key == l.key { return c.image }
        let img: UIImage?
        switch l {
        case .station: return nil
        case .preset(let p): img = Bundle.main.path(forResource: "morning-\(p.id)", ofType: "jpg").flatMap(UIImage.init(contentsOfFile:))
        case .photo(let n): img = UIImage(contentsOfFile: Self.dir.appendingPathComponent(n).path)
        }
        if let img { cached = (l.key, img) }
        return img
    }

    func thumbnail(_ l: MorningLook) -> UIImage? {
        switch l {
        case .station: return Bundle.main.path(forResource: "morning-station-t", ofType: "jpg").flatMap(UIImage.init(contentsOfFile:))
        case .preset(let p): return p.thumbnail
        case .photo(let n): return UIImage(contentsOfFile: Self.dir.appendingPathComponent(n).path)
        }
    }

    /// Photos you picked: made smaller (no need for 48 megapixels on a phone screen), kept in the app, and added to
    /// the turns.
    func add(_ items: [PhotosPickerItem]) async {
        for item in items.prefix(12) {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let name = await Task.detached { () -> String? in
                guard let img = UIImage(data: data) else { return nil }
                let maxSide: CGFloat = 1800
                let s = min(1, maxSide / max(img.size.width, img.size.height))
                let size = CGSize(width: img.size.width * s, height: img.size.height * s)
                let small = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
                guard let jpg = small.jpegData(compressionQuality: 0.85) else { return nil }
                let name = UUID().uuidString + ".jpg"
                try? jpg.write(to: Morning.dir.appendingPathComponent(name))
                return name
            }.value
            if let name {
                photos.append(name)
                chosen.append("u:" + name)
            }
        }
        persist()
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(name))
        photos.removeAll { $0 == name }
        chosen.removeAll { $0 == "u:" + name }
        if chosen.isEmpty { chosen = ["station"] }
        if cached?.key == "u:" + name { cached = nil }
        persist()
    }

    /// Settings: see one look on the morning screen now.
    func tryOut(_ l: MorningLook) {
        preview = l.key
        withAnimation(.easeInOut(duration: 0.4)) { showing = true }
    }

    /// The app came to the screen: if the school alarm rang this morning (in the last 90 minutes), show the morning
    /// screen, once that day.
    func checkAfterAlarm() {
        guard on, !showing else { return }
        let now = Date()
        guard let p = SchoolAlarm.shared.week.first(where: { p in
            guard let a = p.alarm, p.alarmId != nil else { return false }
            return a <= now && now.timeIntervalSince(a) < 90 * 60
        }), UserDefaults.standard.string(forKey: "morning.shown") != p.day else { return }
        UserDefaults.standard.set(p.day, forKey: "morning.shown")
        withAnimation(.easeInOut(duration: 0.4)) { showing = true }
    }
}

/// "Open" on the morning alarm: opens the app on the morning screen.
struct OpenMorningIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Open the morning screen"
    static var openAppWhenRun: Bool = true
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { Morning.shared.showing = true }
        return .result()
    }
}

/// The morning screen itself.
struct MorningView: View {
    @EnvironmentObject private var trip: TripManager
    @ObservedObject private var morning = Morning.shared
    @ObservedObject private var school = SchoolAlarm.shared
    let go: (SchoolAlarm.Planned) -> Void
    @State private var picking: [PhotosPickerItem] = []
    @State private var showOutfit = false

    /// Today's (or the next) school day.
    private var day: SchoolAlarm.Planned? {
        school.week.filter { $0.classStart > Date().addingTimeInterval(-3 * 3600) }.min { $0.classStart < $1.classStart }
    }

    var body: some View {
        let look = morning.look()
        let light = look.light
        let text: Color = light ? Paper.ink : .white
        let shade: Color = light ? .clear : .black.opacity(0.45)
        ZStack {
            backdrop(look)
            // a little darker behind the time and under the card, so they read on any picture
            Group {
                if light {
                    LinearGradient(colors: [Paper.paper.opacity(0.45), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.3))
                } else if case .photo = look {
                    LinearGradient(colors: [.black.opacity(0.5), .clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                } else {
                    LinearGradient(colors: [.black.opacity(0.3), .clear, .clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                TimelineView(.everyMinute) { tl in
                    Text(Fmt.hhmm(tl.date)).font(.system(size: 88, weight: .heavy)).monospacedDigit().foregroundStyle(text)
                        .shadow(color: shade, radius: 10, y: 4)
                }
                .padding(.top, 30)
                Text("Good morning").font(HWFont.display(24)).foregroundStyle(text).shadow(color: shade, radius: 6, y: 2)
                Spacer()
                card
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
        .onChange(of: picking) { _, items in
            guard !items.isEmpty else { return }
            Task { await morning.add(items); picking = [] }
        }
        .sheet(isPresented: $showOutfit) { OutfitSheet().presentationDetents([.large]) }
        .task { await OutfitStore.shared.refresh() }
    }

    /// The picture fills the screen and is cut to it (a wide photo mustn't push the time and the card off the sides).
    @ViewBuilder private func backdrop(_ look: MorningLook) -> some View {
        if case .station = look {
            StationBackdrop(home: false, moving: trip.movingStation, dim: 0.1)
        } else if let img = morning.image(look) {
            GeometryReader { g in
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: g.size.width, height: g.size.height).clipped()
            }
            .ignoresSafeArea()
        } else {
            StationBackdrop(home: false, moving: false, dim: 0.1)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = day {
                PaperBand {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(SchoolAlarm.dayWord(p.classStart).uppercased()) · FIRST CLASS \(Fmt.hhmm(p.classStart))").font(BoardInk.sans(10)).tracking(1.6).opacity(0.85)
                        Text(p.title).font(HWFont.display(21)).lineLimit(1).minimumScaleFactor(0.6)
                        if let r = p.room, !r.isEmpty { Text(r).font(BoardInk.sans(11, .medium)).opacity(0.85).lineLimit(1) }
                    }
                }
                HStack(alignment: .lastTextBaseline) {
                    if let l = p.leave {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("LEAVE").font(BoardInk.sans(10)).tracking(1.4).foregroundStyle(Paper.muted)
                            Text(Fmt.hhmm(l)).font(HWFont.display(34)).foregroundStyle(Paper.navy).monospacedDigit()
                            TimelineView(.everyMinute) { _ in
                                let m = Fmt.mins(l.timeIntervalSinceNow)
                                Text(l < Date() ? "now" : m >= 60 ? "in \(m / 60) h \(String(format: "%02d", m % 60))" : "in \(m) min")
                                    .font(BoardInk.sans(12)).foregroundStyle(m < 10 ? Paper.late : Paper.ok)
                            }
                        }
                    }
                    Spacer()
                    if let a = p.arrive {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("AT BUAS").font(BoardInk.sans(10)).tracking(1.4).foregroundStyle(Paper.muted)
                            Text(Fmt.hhmm(a)).font(HWFont.display(24)).foregroundStyle(Paper.ink).monospacedDigit()
                            if let lines = p.lines { Text(lines).font(BoardInk.sans(11.5)).foregroundStyle(Paper.muted) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                Button { showOutfit = true } label: { OutfitLine() }.buttonStyle(.plain).padding(.horizontal, 14)
                Button { go(p) } label: {
                    Label("GO HANDS-FREE", systemImage: "bolt.fill").font(HWFont.display(14)).tracking(0.8).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12).background(Paper.green, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).padding(.horizontal, 14)
            } else {
                Text("No class planned today.").font(BoardInk.sans(15)).foregroundStyle(Paper.ink).padding(14)
            }
            HStack {
                Button { withAnimation(.easeInOut(duration: 0.35)) { morning.showing = false } } label: {
                    Text("I’m up").font(BoardInk.sans(14)).foregroundStyle(Paper.navy)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Paper.navy.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.navy.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
                PhotosPicker(selection: $picking, maxSelectionCount: 10, matching: .images) {
                    Label(morning.photos.isEmpty ? "Add your photos" : "Add photos", systemImage: "photo.on.rectangle").font(BoardInk.sans(12)).foregroundStyle(Paper.navy)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .paperSheet()
    }
}

/// Settings: the morning screen, and what it shows. Tap to pick (as many as you like: they take turns, one each
/// morning), hold one to try it now.
struct MorningSection: View {
    @ObservedObject private var morning = Morning.shared
    @State private var picking: [PhotosPickerItem] = []
    let preview: (MorningLook?) -> Void

    private let cols = [GridItem(.adaptive(minimum: 66, maximum: 90), spacing: 8)]

    var body: some View {
        Section {
            Toggle(isOn: $morning.on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Morning screen")
                    Text("After the school alarm: the time, when to leave and your first class. Tap Open on the alarm, or just open the app.")
                        .font(HWFont.body(12)).foregroundStyle(Paper.muted)
                }
            }
            if morning.on {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(morning.all, id: \.self) { l in tile(l) }
                    PhotosPicker(selection: $picking, maxSelectionCount: 10, matching: .images) {
                        VStack(spacing: 3) {
                            Color.clear
                                .aspectRatio(0.462, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .background(Paper.navy.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Paper.navy.opacity(0.3), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                                .overlay {
                                    VStack(spacing: 6) {
                                        Image(systemName: "photo.badge.plus").font(.system(size: 22, weight: .semibold))
                                        Text("Add").font(HWFont.body(11, bold: true))
                                    }
                                    .foregroundStyle(Paper.navy)
                                }
                            Text("Your photos").font(HWFont.body(10.5)).foregroundStyle(Paper.navy).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)
                Text(caption).font(HWFont.body(11.5)).foregroundStyle(Paper.muted)
                Button("Show the morning screen now") { preview(nil) }.foregroundStyle(Paper.navy)
            }
        } header: { Text("Morning") }
        .onChange(of: picking) { _, items in
            guard !items.isEmpty else { return }
            Task { await morning.add(items); picking = [] }
        }
    }

    private var caption: String {
        let n = morning.chosen.count
        return n == 1 ? "Tap more to take turns, one each morning. Hold one to try it." : "\(n) picked: a different one each morning. Hold one to try it."
    }

    private func name(_ l: MorningLook) -> String {
        switch l {
        case .station: return "Metro"
        case .preset(let p): return p.title
        case .photo: return "Your photo"
        }
    }

    private func tile(_ l: MorningLook) -> some View {
        let on = morning.isChosen(l)
        return VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let t = morning.thumbnail(l) { Image(uiImage: t).resizable().scaledToFill() } else { Paper.card }
                }
                .frame(maxWidth: .infinity).aspectRatio(0.462, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Paper.navy : Paper.ink.opacity(0.15), lineWidth: on ? 3 : 1))
                .overlay(alignment: .bottomLeading) {
                    if case .station = l {
                        Text("LIVE").font(BoardInk.sans(8.5)).tracking(1).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1.5).background(Paper.oxblood, in: RoundedRectangle(cornerRadius: 3)).padding(5)
                    }
                }
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.9), on ? Paper.navy : Color.black.opacity(0.35))
                    .padding(4)
            }
            Text(name(l)).font(HWFont.body(10.5)).foregroundStyle(on ? Paper.navy : Paper.muted).lineLimit(1).minimumScaleFactor(0.8)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { morning.toggle(l) } }
        .contextMenu {
            Button { preview(l) } label: { Label("Try it now", systemImage: "eye") }
            Button { morning.toggle(l) } label: { Label(on ? "Don’t use" : "Use it", systemImage: on ? "minus.circle" : "checkmark.circle") }
            if case .photo(let n) = l {
                Button(role: .destructive) { morning.remove(n) } label: { Label("Remove photo", systemImage: "trash") }
            }
        }
    }
}
