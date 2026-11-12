import AppIntents
import PhotosUI
import SwiftUI

/// The morning screen after the school alarm: one of your own photos full screen, the time, and the day on a sheet of
/// paper: when to leave, the bus, when you're at BUas, your first class. It shows when you tap Open on the alarm, or the
/// first time you open the app after it rang that morning.
@MainActor
final class Morning: ObservableObject {
    static let shared = Morning()
    @Published var showing = false
    @Published var on: Bool { didSet { UserDefaults.standard.set(on, forKey: "morning.on") } }
    @Published private(set) var photos: [String]            // file names, in the app's own folder

    private init() {
        on = UserDefaults.standard.object(forKey: "morning.on") as? Bool ?? true
        photos = UserDefaults.standard.stringArray(forKey: "morning.photos") ?? []
        photos = photos.filter { FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent($0).path) }
    }

    static var dir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Morning", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func persist() { UserDefaults.standard.set(photos, forKey: "morning.photos") }

    /// Today's photo: a different one of yours each day.
    func photo(for day: Date = Date()) -> UIImage? {
        guard !photos.isEmpty else { return nil }
        let n = Calendar.current.ordinality(of: .day, in: .era, for: day) ?? 0
        return UIImage(contentsOfFile: Self.dir.appendingPathComponent(photos[n % photos.count]).path)
    }

    func thumbnail(_ name: String) -> UIImage? { UIImage(contentsOfFile: Self.dir.appendingPathComponent(name).path) }

    /// Photos you picked: made smaller (no need for 48 megapixels on a phone screen) and kept in the app.
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
            if let name { photos.append(name) }
        }
        persist()
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(name))
        photos.removeAll { $0 == name }
        persist()
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
    @ObservedObject private var morning = Morning.shared
    @ObservedObject private var school = SchoolAlarm.shared
    let go: (SchoolAlarm.Planned) -> Void
    @State private var picking: [PhotosPickerItem] = []

    /// Today's (or the next) school day.
    private var day: SchoolAlarm.Planned? {
        school.week.filter { $0.classStart > Date().addingTimeInterval(-3 * 3600) }.min { $0.classStart < $1.classStart }
    }

    var body: some View {
        ZStack {
            // your photo (or the station)
            Group {
                if let img = morning.photo() {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    StationBackdrop(home: false, moving: false, dim: 0.1)
                }
            }
            .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.5), .clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                TimelineView(.everyMinute) { tl in
                    Text(Fmt.hhmm(tl.date)).font(.system(size: 88, weight: .heavy)).monospacedDigit().foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                }
                .padding(.top, 30)
                Text("Good morning").font(HWFont.display(24)).foregroundStyle(.white).shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                Spacer()
                card
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
        .onChange(of: picking) { _, items in
            guard !items.isEmpty else { return }
            Task { await morning.add(items); picking = [] }
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

/// Settings: the morning screen and your photos for it.
struct MorningSection: View {
    @ObservedObject private var morning = Morning.shared
    @State private var picking: [PhotosPickerItem] = []
    let preview: () -> Void
    var body: some View {
        Section {
            Toggle(isOn: $morning.on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Morning screen")
                    Text("After the school alarm: your photo, the time, when to leave and your first class. Tap Open on the alarm, or just open the app.")
                        .font(HWFont.body(12)).foregroundStyle(Paper.muted)
                }
            }
            if morning.on {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(morning.photos, id: \.self) { name in
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let t = morning.thumbnail(name) { Image(uiImage: t).resizable().scaledToFill() } else { Paper.card }
                                }
                                .frame(width: 64, height: 86).clipShape(RoundedRectangle(cornerRadius: 6))
                                Button { morning.remove(name) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Color.black.opacity(0.55))
                                }
                                .buttonStyle(.plain).padding(3)
                            }
                        }
                        PhotosPicker(selection: $picking, maxSelectionCount: 10, matching: .images) {
                            VStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 18, weight: .bold))
                                Text("Photos").font(HWFont.body(11))
                            }
                            .foregroundStyle(Paper.navy).frame(width: 64, height: 86)
                            .background(Paper.navy.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 4)
                }
                Text(morning.photos.isEmpty ? "Pick a few photos: each morning shows another one." : "\(morning.photos.count) photo\(morning.photos.count == 1 ? "" : "s"): each morning shows another one.")
                    .font(HWFont.body(11.5)).foregroundStyle(Paper.muted)
                Button("Show the morning screen now", action: preview).foregroundStyle(Paper.navy)
            }
        } header: { Text("Morning") }
        .onChange(of: picking) { _, items in
            guard !items.isEmpty else { return }
            Task { await morning.add(items); picking = [] }
        }
    }
}
