import Darwin
import SwiftUI
import UIKit

// Room for the main thread's call stack. The signal handler below fills it in, so it allocates nothing itself.
private let sampleFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 48)
private var sampleCount: Int32 = 0

/// Runs on the main thread when the watchdog pokes it (SIGUSR2): notes where the main thread is right now.
private func sampleMainStack(_: Int32) {
    sampleCount = backtrace(sampleFrames, 48)
}

/// Notices when the app stops responding: a background thread checks the main one every second, and if it hasn't
/// answered for more than 3 seconds, writes down how long, what the app was doing (the last `mark`) and exactly where
/// in the code the main thread was stuck. Settings shows it.
///
/// Time the app spends paused by iOS (the phone locked, another app in front) is not a freeze: the check thread is
/// paused then too, so when its own one-second nap took much longer, or the app is in the background, it starts over.
final class Watchdog: @unchecked Sendable {
    static let shared = Watchdog()
    private let lock = NSLock()
    private var beat = Date()
    private var label = "starting up"
    private var started = false
    private var paused = false
    private var main: pthread_t?
    private var current: (at: Date, label: String, samples: Int)?

    /// What the app is about to do (before something that could take long).
    func mark(_ s: String) { lock.lock(); label = s; lock.unlock() }

    /// From the app's start, on the main thread.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        // the freezes noted before this version were mostly the phone being locked: start the list again
        if UserDefaults.standard.integer(forKey: "freezes.v") < 2 {
            UserDefaults.standard.removeObject(forKey: "freezes")
            UserDefaults.standard.set(2, forKey: "freezes.v")
        }
        if Thread.isMainThread {
            main = pthread_self()
            sampleCount = 0
            _ = sampleFrames
            signal(SIGUSR2, sampleMainStack)
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [self] _ in setPaused(true) }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [self] _ in setPaused(false) }
        Thread.detachNewThread { [self] in
            var tick = Date()
            while true {
                DispatchQueue.main.async { self.lock.lock(); self.beat = Date(); self.lock.unlock() }
                Thread.sleep(forTimeInterval: 1)
                let now = Date()
                let late = now.timeIntervalSince(tick) - 1        // this thread was paused too: so was the whole app
                tick = now
                self.lock.lock()
                if late > 1.5 || self.paused {
                    self.beat = now
                    self.current = nil
                    self.lock.unlock()
                    continue
                }
                let gap = now.timeIntervalSince(self.beat)
                guard gap > 3 else {
                    self.current = nil
                    self.lock.unlock()
                    continue
                }
                if self.current == nil { self.current = (now.addingTimeInterval(-gap), self.label, 0) }
                var c = self.current!
                // where it's stuck: once soon after it froze, and once more if it's still stuck after 15 seconds
                let sample = (c.samples == 0 && gap > 3.5) || (c.samples == 1 && gap > 15)
                if sample { c.samples += 1; self.current = c }
                let thread = self.main
                self.lock.unlock()
                var stack: [String]? = nil
                if sample, let thread { stack = Self.sampleStack(of: thread) }
                Self.record(at: c.at, seconds: gap, label: c.label, stack: stack, second: c.samples == 2)
            }
        }
    }

    private func setPaused(_ p: Bool) {
        lock.lock(); paused = p; beat = Date(); current = nil; lock.unlock()
    }

    /// Pokes the main thread and reads back where it is: the image and offset of each frame (so it can be looked up
    /// in exactly this build), with the function's name when the phone knows it.
    private static func sampleStack(of thread: pthread_t) -> [String] {
        sampleCount = 0
        guard pthread_kill(thread, SIGUSR2) == 0 else { return [] }
        for _ in 0..<20 where sampleCount == 0 { usleep(10_000) }
        let n = Int(sampleCount)
        guard n > 2 else { return [] }
        var lines: [String] = []
        for i in 2..<min(n, 40) {                               // 0 and 1: the signal handler itself
            guard let a = sampleFrames[i] else { continue }
            var info = Dl_info()
            if dladdr(UnsafeRawPointer(a), &info) != 0, let base = info.dli_fbase {
                let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
                let off = Int(bitPattern: a) - Int(bitPattern: base)
                let name = info.dli_sname.map { String(cString: $0) } ?? ""
                lines.append("\(image) +0x\(String(off, radix: 16)) \(name)")
            } else {
                lines.append("? 0x\(String(Int(bitPattern: a), radix: 16))")
            }
        }
        return lines
    }

    struct Freeze: Codable, Identifiable {
        var id: Double { at.timeIntervalSince1970 }
        let at: Date
        var seconds: Double
        let label: String
        var stack: [String]?
        var later: [String]?          // the second look, if it was still stuck after 15 seconds
        var version: String?

        /// The first of the app's own functions on the stack, readable: "HomeView.wallBoards". Else the system part
        /// it was in ("in MapKit").
        var spot: String? {
            for l in stack ?? [] {
                let parts = l.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.first == "Haltewekker", parts.count == 3, let r = Watchdog.readable(parts[2]) else { continue }
                return r
            }
            return stack?.first.flatMap { $0.split(separator: " ").first.map(String.init) }
        }

        var details: String {
            var s = "Haltewekker \(version ?? "?") · \(Fmt.when(at)) · stuck \(Int(seconds)) s · while \(label)\n"
            s += (stack ?? ["(no stack)"]).joined(separator: "\n")
            if let later { s += "\n— 15 s later —\n" + later.joined(separator: "\n") }
            return s
        }
    }

    /// The last few times it froze (the same freeze is updated while it lasts).
    static var freezes: [Freeze] {
        UserDefaults.standard.data(forKey: "freezes").flatMap { try? JSONDecoder().decode([Freeze].self, from: $0) } ?? []
    }

    private static func record(at: Date, seconds: Double, label: String, stack: [String]?, second: Bool) {
        var list = freezes
        if let i = list.firstIndex(where: { abs($0.at.timeIntervalSince(at)) < 2 }) {
            list[i].seconds = seconds
            if let stack, !stack.isEmpty { if second { list[i].later = stack } else { list[i].stack = stack } }
        } else {
            let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
            list.insert(Freeze(at: at, seconds: seconds, label: label, stack: stack, later: nil, version: v), at: 0)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(list.prefix(5))), forKey: "freezes")
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: "freezes") }

    /// A rough reading of a Swift function name, enough to see where it is: "$s11Haltewekker8HomeViewV10wallBoards…"
    /// becomes "HomeView.wallBoards".
    static func readable(_ mangled: String) -> String? {
        var s = Substring(mangled)
        for p in ["_$s", "$s"] where s.hasPrefix(p) { s = s.dropFirst(p.count); break }
        guard s.first?.isNumber == true else { return nil }
        var names: [String] = []
        while let c = s.first {
            if c.isNumber {
                var n = 0
                while let d = s.first, let v = d.wholeNumberValue { n = n * 10 + v; s = s.dropFirst() }
                guard n > 0, s.count >= n else { break }
                let id = String(s.prefix(n))
                s = s.dropFirst(n)
                if !id.hasPrefix("_") { names.append(id) }
            } else if s.dropFirst().first?.isNumber == true {
                s = s.dropFirst()                                  // a one-letter kind: struct, class, enum…
            } else { break }
        }
        guard names.count >= 2 else { return nil }
        var r = names.dropFirst().joined(separator: ".")
        if mangled.contains("fU_") || mangled.contains("fU0_") || mangled.contains("XEfU") { r += " (closure)" }
        return r
    }
}

/// In Settings, only when it froze: when, how long, what it was doing and where it was stuck.
struct FreezeSection: View {
    @State private var list = Watchdog.freezes
    @State private var copied = false
    var body: some View {
        if !list.isEmpty {
            Section {
                ForEach(list) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Fmt.when(f.at)) · stuck for \(f.seconds >= 90 ? "\(Int((f.seconds / 60).rounded())) min" : "\(Int(f.seconds)) s")")
                            .font(HWFont.body(13, bold: true))
                        Text("While \(f.label)").font(HWFont.body(12)).foregroundStyle(Paper.muted)
                        if let s = f.spot { Text("in \(s)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Paper.oxblood).lineLimit(2) }
                    }
                }
                Button(copied ? "Copied: paste it in the chat" : "Copy the details") {
                    UIPasteboard.general.string = list.map(\.details).joined(separator: "\n\n")
                    copied = true
                }
                .foregroundStyle(Paper.navy)
                Button("Clear") { Watchdog.clear(); list = [] }.foregroundStyle(Paper.navy)
            } header: { Text("When the app froze") } footer: {
                Text("If the app stops responding for more than a few seconds, it notes what it was doing and where. Time with your phone locked doesn’t count. Send a screenshot, or copy the details, to get it fixed.")
            }
        }
    }
}
