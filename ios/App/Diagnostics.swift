import SwiftUI
import Foundation

/// Notices when the app stops responding: a background thread checks the main one every second, and if it hasn't
/// answered for more than 3 seconds, writes down how long and what the app was doing (the last `mark`). Settings shows it.
final class Watchdog: @unchecked Sendable {
    static let shared = Watchdog()
    private let lock = NSLock()
    private var beat = Date()
    private var label = "starting up"
    private var started = false
    private var current: (at: Date, label: String)?

    /// What the app is about to do (before something that could take long).
    func mark(_ s: String) { lock.lock(); label = s; lock.unlock() }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        Thread.detachNewThread { [self] in
            while true {
                DispatchQueue.main.async { self.lock.lock(); self.beat = Date(); self.lock.unlock() }
                Thread.sleep(forTimeInterval: 1)
                self.lock.lock()
                let gap = Date().timeIntervalSince(self.beat), l = self.label
                if gap > 3 {
                    if self.current == nil { self.current = (Date().addingTimeInterval(-gap), l) }
                    let c = self.current!
                    self.lock.unlock()
                    Self.record(at: c.at, seconds: gap, label: c.label)
                } else {
                    self.current = nil
                    self.lock.unlock()
                }
            }
        }
    }

    struct Freeze: Codable, Identifiable { var id: Double { at.timeIntervalSince1970 }; let at: Date; var seconds: Double; let label: String }

    /// The last few times it froze (the same freeze is updated while it lasts).
    static var freezes: [Freeze] {
        UserDefaults.standard.data(forKey: "freezes").flatMap { try? JSONDecoder().decode([Freeze].self, from: $0) } ?? []
    }

    private static func record(at: Date, seconds: Double, label: String) {
        var list = freezes
        if let i = list.firstIndex(where: { abs($0.at.timeIntervalSince(at)) < 2 }) { list[i].seconds = seconds }
        else { list.insert(Freeze(at: at, seconds: seconds, label: label), at: 0) }
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(list.prefix(5))), forKey: "freezes")
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: "freezes") }
}

/// In Settings, only when it froze: when, how long, and what it was doing.
struct FreezeSection: View {
    @State private var list = Watchdog.freezes
    var body: some View {
        if !list.isEmpty {
            Section {
                ForEach(list) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Fmt.when(f.at)) · stuck for \(f.seconds >= 90 ? "\(Int((f.seconds / 60).rounded())) min" : "\(Int(f.seconds)) s")")
                            .font(HWFont.body(13, bold: true))
                        Text("While \(f.label)").font(HWFont.body(12)).foregroundStyle(Paper.muted)
                    }
                }
                Button("Clear") { Watchdog.clear(); list = [] }.foregroundStyle(Paper.navy)
            } header: { Text("When the app froze") } footer: {
                Text("If the app stops responding for more than a few seconds, it notes what it was doing. Send a screenshot of this to get it fixed.")
            }
        }
    }
}
