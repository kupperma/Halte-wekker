import Foundation

// replay <export.json> [--tracks vehicles.json] [--fetch] [--save-tracks vehicles.json] [--every 10] [--looks] [--json]
//
// 0.33: under each leg, when the wake rules would have rung (the distance rule, and the time rule by your speed along
// the track you went: `WakeReplay`), and when the app's own ring line says it rang, and by which rule.
//
// Every leg with GPS points in an export (docs/logs-export.md) through the app's on-board matcher, scored against the
// vehicle you were on: the one you picked by hand in the ride, else the one the app ended the leg on (or a fixture's
// `truth`). The vehicles come from the fixture, from --tracks, or with --fetch from Transitous (then --save-tracks
// keeps them, so the next run needs no network).

struct Options {
    var input: String?
    var tracks: String?
    var fetch = false
    var save: String?
    var every: TimeInterval = 10
    var looks = false
    var json = false
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: replay <export.json> [--tracks vehicles.json] [--fetch] [--save-tracks vehicles.json] [--every 10] [--looks] [--json]

    """.utf8))
    exit(2)
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    func value() -> String { i += 1; guard i < args.count else { usage() }; return args[i] }
    while i < args.count {
        switch args[i] {
        case "--tracks": o.tracks = value()
        case "--fetch": o.fetch = true
        case "--save-tracks": o.save = value()
        case "--every": o.every = TimeInterval(value()) ?? 10
        case "--looks": o.looks = true
        case "--json": o.json = true
        case "-h", "--help": usage()
        default: if o.input == nil { o.input = args[i] } else { usage() }
        }
        i += 1
    }
    if o.input == nil { usage() }
    return o
}

func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func fmt(_ x: Double?) -> String { x.map { String(format: "%.0f s", $0) } ?? "-" }
func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }

let o = parse(Array(CommandLine.arguments.dropFirst()))
let export: Export
do { export = try Export.read(try Data(contentsOf: URL(fileURLWithPath: o.input!))) } catch {
    say("couldn't read \(o.input!): \(error)")
    exit(1)
}
var tracks = export.tracks.map(\.track)
if let t = o.tracks {
    do { tracks += try JSONDecoder().decode([SavedTrack].self, from: Data(contentsOf: URL(fileURLWithPath: t))).map(\.track) } catch {
        say("couldn't read \(t): \(error)")
        exit(1)
    }
}
let legs = Rides.legs(export)
say("\(export.uploads.count) uploads, \(legs.count) legs with GPS points, \(tracks.count) vehicles given")
if o.fetch {
    for (n, leg) in legs.enumerated() {
        say("leg \(n + 1)/\(legs.count): asking Transitous for the vehicles around it")
        let got = Fetch.tracks(for: leg, log: say)
        let known = Set(tracks.map(\.tripId))
        tracks += got.filter { !known.contains($0.tripId) }
    }
    if let s = o.save {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        do { try enc.encode(tracks.map(SavedTrack.init)).write(to: URL(fileURLWithPath: s)) } catch { say("couldn't save \(s): \(error)") }
        say("saved \(tracks.count) vehicles to \(s)")
    }
}

var results: [LegResult] = []
for leg in legs {
    let logged = Score.of(Replayer.logged(leg), truth: leg.truth, start: leg.start)
    var replayed: Score?
    if !tracks.isEmpty {
        let timeline = Replayer.replay(leg, tracks: tracks, every: o.every, looks: o.looks ? { l in
            let t = ISO8601DateFormatter().string(from: l.at)
            say("  \(leg.ride) \(leg.leg) \(t) judged \(l.judged) · passed \(l.passed.joined(separator: ", ")) → \(l.outcome)")
        } : nil)
        replayed = Score.of(timeline, truth: leg.truth, start: leg.start)
    }
    let ids = Set(leg.fixes.compactMap(\.veh))
    results.append(LegResult(install: String(leg.install.prefix(8)), ride: leg.ride, leg: leg.leg, truth: leg.truth, truthFrom: leg.truthFrom,
                             minutes: leg.end.timeIntervalSince(leg.start) / 60, points: leg.fixes.count, vehicles: ids.count,
                             logged: logged, replayed: replayed, wake: WakeReplay.of(leg)))
}

let truths = results.filter { $0.truth != nil }.count
let loggedSummary = Summary.of(results.map(\.logged), truths: truths)
let replaySummary = tracks.isEmpty ? nil : Summary.of(results.compactMap(\.replayed), truths: truths)

if o.json {
    struct Out: Codable { var legs: [LegResult]; var logged: Summary; var replayed: Summary? }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try! enc.encode(Out(legs: results, logged: loggedSummary, replayed: replaySummary)))
    print()
} else {
    print("install  ride      leg  min  truth (from)               | app: settle  flips  on it | replay: settle  flips  on it  ended on")
    for r in results {
        let truth = "\(r.truth ?? "?") (\(r.truthFrom))".padding(toLength: 26, withPad: " ", startingAt: 0)
        let app = "\(fmt(r.logged.settle).leftPad(6))  \(String(r.logged.flips).leftPad(5))  \(pct(r.logged.onTruth).leftPad(5))"
        let rep = r.replayed.map { "\(fmt($0.settle).leftPad(6))  \(String($0.flips).leftPad(5))  \(pct($0.onTruth).leftPad(5))  \($0.endedOn ?? "-")" } ?? "(no vehicles: --fetch or --tracks)"
        print("\(r.install) \(r.ride.padding(toLength: 9, withPad: " ", startingAt: 0)) \(r.leg.padding(toLength: 4, withPad: " ", startingAt: 0)) \(String(format: "%4.0f", r.minutes))  \(truth) | app: \(app) | replay: \(rep)")
        if let w = r.wake { print("         wake · \(WakeReplay.words(w))") }
    }
    func line(_ name: String, _ s: Summary) -> String {
        "\(name): settled on the one you were on in \(s.settled) of \(s.withTruth) legs · median \(fmt(s.medianSettle)) to settle · \(s.flips) flips · on it \(pct(s.onTruth)) of the time"
    }
    print("")
    print(line("app (as logged)", loggedSummary))
    if let r = replaySummary { print(line("replay (matcher now)", r)) }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
