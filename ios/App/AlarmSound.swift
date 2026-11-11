import AVFoundation
import AudioToolbox

/// The alarm plays over your music (it lowers it for a moment instead of stopping it).
final class AlarmSound {
    private var player: AVAudioPlayer?
    private var silent: AVAudioPlayer?
    private var buzz: Timer?

    /// Keeps the audio session awake during a trip with a silent loop, so the alarm can start while the phone is locked.
    func startTrip() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
        if silent == nil, let p = try? AVAudioPlayer(data: Self.wav(Self.silence(seconds: 2))) {
            p.numberOfLoops = -1; p.volume = 0; p.play(); silent = p
        }
    }

    func endTrip() {
        stop()
        silent?.stop(); silent = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func ring() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
        try? s.setActive(true)
        if player == nil { player = try? AVAudioPlayer(data: Self.wav(Self.chime())) }
        player?.numberOfLoops = -1
        player?.volume = 1
        player?.currentTime = 0
        player?.play()
        buzz?.invalidate()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        buzz = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    func stop() {
        player?.stop()
        buzz?.invalidate(); buzz = nil
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    // MARK: sound

    static let rate = 22050

    static func silence(seconds: Double) -> [Float] { Array(repeating: 0, count: Int(Double(rate) * seconds)) }

    /// Soft bells: G5, E5, C5 with a natural fade, the same "Chime" as the website.
    static func chime() -> [Float] {
        let dur = 2.6, n = Int(Double(rate) * dur)
        var out = [Float](repeating: 0, count: n)
        let notes: [(Double, Double)] = [(0, 783.99), (0.45, 659.25), (0.9, 523.25)]
        let parts: [(Double, Double, Double)] = [(1, 1, 1.6), (2, 0.42, 0.9), (2.76, 0.22, 0.5), (5.4, 0.06, 0.25)]
        for (at, f) in notes {
            let start = Int(at * Double(rate))
            for i in start..<n {
                let t = Double(i - start) / Double(rate)
                var v = 0.0
                for (m, a, d) in parts { v += a * exp(-t / d) * sin(2 * .pi * f * m * t) }
                out[i] += Float(min(1, t / 0.004) * v)
            }
        }
        let peak = out.map { abs($0) }.max() ?? 1
        let fade = Int(0.03 * Double(rate))
        for i in 0..<n {
            out[i] *= 0.92 / peak
            if i > n - fade { out[i] *= Float(n - i) / Float(fade) }
        }
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
