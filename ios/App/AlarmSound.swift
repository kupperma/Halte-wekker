import AVFoundation
import AudioToolbox

/// Alarm sounds, the station jingle and the announcer. Everything plays over your music.
final class AlarmSound: NSObject, AVSpeechSynthesizerDelegate {
    enum Kind: String, CaseIterable, Identifiable {
        case steam, chime, marimba, sunrise, beeps, siren
        var id: String { rawValue }
        var title: String {
            switch self { case .steam: "Steam train"; case .chime: "Chime"; case .marimba: "Marimba"; case .sunrise: "Sunrise"; case .beeps: "Beeps"; case .siren: "Siren" }
        }
        var detail: String {
            switch self {
            case .steam: "A whistle, then an old engine pulling away"
            case .chime: "Soft bells, like a doorbell"
            case .marimba: "Warm wooden notes, a bit livelier"
            case .sunrise: "A slow, rising melody. The gentlest"
            case .beeps: "Sharp and loud"
            case .siren: "The loudest, for deep sleepers"
            }
        }
    }

    var kind: Kind = Kind(rawValue: UserDefaults.standard.string(forKey: "sound") ?? "") ?? .steam {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: "sound"); alarm = nil }
    }

    private var alarm: AVAudioPlayer?
    private var jingle: AVAudioPlayer?
    private var silent: AVAudioPlayer?
    private var preview: AVAudioPlayer?
    private var buzz: Timer?
    private var fallback: DispatchWorkItem?
    private let speech = AVSpeechSynthesizer()
    private var afterSpeech: (() -> Void)?

    override init() { super.init(); speech.delegate = self }

    /// Keeps the audio session awake with a silent loop, so the alarm can start while the phone is locked.
    func startTrip() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
        if silent == nil, let p = try? AVAudioPlayer(data: Synth.wav(Synth.silence(2))) { p.numberOfLoops = -1; p.volume = 0; p.play(); silent = p }
    }

    func endTrip() {
        stop()
        silent?.stop(); silent = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// The jingle, the announcement (if any), then the alarm on repeat.
    func ring(announcement: String?) {
        stop()
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
        try? s.setActive(true)
        vibrate()
        guard let text = announcement, !text.isEmpty else { startLoop(); return }
        jingle = try? AVAudioPlayer(data: Synth.wav(Synth.jingle()))
        jingle?.play()
        let fb = DispatchWorkItem { [weak self] in self?.speech.stopSpeaking(at: .immediate); self?.startLoop() }
        fallback = fb
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: fb)          // never hold the alarm back longer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.fallback === fb, !fb.isCancelled else { return }
            let u = AVSpeechUtterance(string: text)
            u.voice = Self.voice
            u.rate = 0.48; u.pitchMultiplier = 1.05; u.volume = 1
            self.afterSpeech = { [weak self] in fb.cancel(); self?.startLoop() }
            self.speech.speak(u)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in let f = self?.afterSpeech; self?.afterSpeech = nil; f?() }
    }

    private func startLoop() {
        if alarm == nil { alarm = try? AVAudioPlayer(data: Synth.wav(Synth.samples(kind))) }
        alarm?.numberOfLoops = -1; alarm?.volume = 1; alarm?.currentTime = 0; alarm?.play()
    }

    private func vibrate() {
        buzz?.invalidate()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        buzz = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
    }

    func stop() {
        fallback?.cancel(); fallback = nil; afterSpeech = nil
        speech.stopSpeaking(at: .immediate)
        jingle?.stop(); alarm?.stop()
        buzz?.invalidate(); buzz = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    func play(preview k: Kind) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers]); try? s.setActive(true)
        preview = try? AVAudioPlayer(data: Synth.wav(Synth.samples(k)))
        preview?.play()
    }

    /// A British woman's voice if the phone has one, the best quality first.
    static var voice: AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        func pick(_ lang: String) -> AVSpeechSynthesisVoice? {
            all.filter { $0.language == lang && $0.gender == .female }
               .sorted { $0.quality.rawValue > $1.quality.rawValue }.first
        }
        return pick("en-GB") ?? pick("en-IE") ?? pick("en-AU") ?? pick("en-US") ?? AVSpeechSynthesisVoice(language: "en-GB")
    }
}

/// The sounds are made here, not recorded: the same recipes as the website.
enum Synth {
    static let rate = 22050

    static func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(Double(rate) * seconds)) }

    static func samples(_ k: AlarmSound.Kind) -> [Float] {
        switch k {
        case .steam: return steam()
        case .chime: return bells(dur: 2.6, notes: [(0, 783.99), (0.45, 659.25), (0.9, 523.25)], parts: [(1, 1, 1.6), (2, 0.42, 0.9), (2.76, 0.22, 0.5), (5.4, 0.06, 0.25)], attack: 0.004)
        case .marimba: return bells(dur: 2.2, notes: [(0, 523.25), (0.17, 659.25), (0.34, 783.99), (0.51, 1046.5), (0.85, 783.99), (1.02, 659.25)], parts: [(1, 1, 0.45), (3.9, 0.18, 0.08), (10, 0.04, 0.02)], attack: 0.003)
        case .sunrise: return bells(dur: 3.2, notes: [(0, 261.63), (0.32, 329.63), (0.64, 392), (0.96, 523.25), (1.28, 659.25), (1.6, 783.99)], parts: [(1, 1, 1.1), (2, 0.3, 0.7), (3, 0.12, 0.45)], attack: 0.05, rising: true)
        case .beeps: return beeps()
        case .siren: return siren()
        }
    }

    static func jingle() -> [Float] {
        bells(dur: 1.9, notes: [(0, 659.25), (0.34, 783.99), (0.68, 1046.5)], parts: [(1, 1, 1.3), (2, 0.38, 0.7), (2.76, 0.18, 0.4), (5.4, 0.05, 0.2)], attack: 0.004, peak: 0.85)
    }

    static func bells(dur: Double, notes: [(Double, Double)], parts: [(Double, Double, Double)], attack: Double, rising: Bool = false, peak: Float = 0.92) -> [Float] {
        let n = Int(Double(rate) * dur)
        var out = [Float](repeating: 0, count: n)
        for (idx, (at, f)) in notes.enumerated() {
            let start = Int(at * Double(rate)), lift = rising ? 0.55 + 0.45 * Double(idx) / Double(max(1, notes.count - 1)) : 1
            for i in start..<n {
                let t = Double(i - start) / Double(rate)
                var v = 0.0
                for (m, a, d) in parts { v += a * exp(-t / d) * sin(2 * .pi * f * m * t) }
                out[i] += Float(min(1, t / attack) * v * lift)
            }
        }
        return normalise(out, peak: peak)
    }

    /// An old steam train leaving: a whistle chord, then chuffs that start slow and speed up.
    static func steam() -> [Float] {
        let dur = 4.6, n = Int(Double(rate) * dur)
        var out = [Float](repeating: 0, count: n)
        var seed: UInt32 = 12345
        func rnd() -> Double { seed = seed &* 1103515245 &+ 12345; return Double(seed & 0x7fffffff) / Double(0x7fffffff) * 2 - 1 }
        let pipes = [523.0, 659.0, 784.0]
        for i in 0..<Int(Double(rate) * 1.2) {
            let t = Double(i) / Double(rate)
            let env = min(1, t / 0.06) * min(1, max(0, (1.15 - t) / 0.18)), vib = 1 + 0.004 * sin(2 * .pi * 5.5 * t)
            var v = 0.0
            for (k, f) in pipes.enumerated() { v += sin(2 * .pi * f * vib * t + Double(k)) * (k == 1 ? 0.9 : 0.7) }
            out[i] += Float(env * (0.32 * v / 2.3 + 0.06 * rnd()))
        }
        var at = 1.05, gap = 0.46, k = 0
        while at < dur - 0.15 {
            let start = Int(at * Double(rate)), len = Int(0.22 * Double(rate)), strong = k % 4 == 0
            var lp = 0.0, lp2 = 0.0, prev = 0.0
            for i in 0..<len where start + i < n {
                let t = Double(i) / Double(rate)
                let env = min(1, t / 0.006) * exp(-t / (0.07 + (strong ? 0.03 : 0)))
                let w = rnd(); lp += 0.35 * (w - lp); lp2 += 0.35 * (lp - lp2); let hp = lp2 - prev; prev = lp2
                let thump = sin(2 * .pi * (70 + 40 * exp(-t * 30)) * t) * exp(-t / 0.05)
                out[start + i] += Float(env * ((strong ? 1 : 0.75) * 1.9 * hp * 3 + 0.45 * thump))
            }
            at += gap; gap = max(0.17, gap * 0.88); k += 1
        }
        return normalise(out, peak: 0.92)
    }

    static func beeps() -> [Float] {
        let n = Int(Double(rate) * 1.6)
        var out = [Float](repeating: 0, count: n), ph = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(rate), k = Int(t / 0.2), wk = t - Double(k) * 0.2
            if k < 4 && wk < 0.13 {
                let f = k % 2 == 1 ? 2350.0 : 1870.0; ph += 2 * .pi * f / Double(rate)
                let env = min(1, wk / 0.004, (0.13 - wk) / 0.004), s = sin(ph)
                out[i] = Float(env * (0.6 * tanh(3 * s) + 0.3 * s))
            }
        }
        return out
    }

    static func siren() -> [Float] {
        let dur = 2.4, n = Int(Double(rate) * dur)
        var out = [Float](repeating: 0, count: n), ph = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(rate), f = 850 + 750 * (0.5 - 0.5 * cos(2 * .pi * t / dur))
            ph += 2 * .pi * f / Double(rate); let s = sin(ph)
            out[i] = Float(0.55 * tanh(4 * s) + 0.3 * s)
        }
        return out
    }

    static func normalise(_ x: [Float], peak: Float) -> [Float] {
        var out = x
        let p = out.map { abs($0) }.max() ?? 1, g = peak / max(p, 0.0001), fade = Int(0.03 * Double(rate))
        for i in 0..<out.count { out[i] *= g; if i > out.count - fade { out[i] *= Float(out.count - i) / Float(fade) } }
        return out
    }

    static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32000))) }
        return d
    }
}
