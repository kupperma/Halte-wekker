import CoreLocation
import SwiftUI

// 0.37: OV-fiets at the station and rain on the walk — fetched and kept here, shown on the Go card, the home's next-trip
// card, the ride screen's last train and the station sheet. The rules are in `OVFiets` and `RainAdvice`.

// MARK: OV-fiets

/// How many OV-fiets are left at a station: the relay's `/ns/ovfiets`, kept 5 minutes per station, asked only while a
/// card that shows it is on screen.
@MainActor
final class OVFietsStore: ObservableObject {
    static let shared = OVFietsStore()
    /// Settings › Map & home › OV-fiets at the station.
    static let key = "ovfiets.show"

    @Published private(set) var answers: [String: OVFiets.Answer] = [:]
    private var at: [String: Date] = [:]
    private var asking: Set<String> = []

    /// The answer for a station, while it's no older than half an hour (a fresh one is asked for meanwhile).
    func answer(_ code: String) -> OVFiets.Answer? {
        guard let t = at[code], Date().timeIntervalSince(t) < 30 * 60 else { return nil }
        return answers[code]
    }

    func load(_ code: String) async {
        let now = Date()
        if let t = at[code], OVFiets.fresh(t, now: now) { return }
        guard UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true, !asking.contains(code) else { return }
        asking.insert(code)
        defer { asking.remove(code) }
        guard let data = await Self.relay(code), let a = OVFiets.parse(data, station: code) else { return }
        answers[code] = a
        at[code] = Date()
    }

    nonisolated private static func relay(_ code: String) async -> Data? {
        guard let url = URL(string: NSStore.relay + "/ns/ovfiets?station=\(code)") else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        r.setValue(Transit.userAgent, forHTTPHeaderField: "User-Agent")
        guard let a = try? await Net.response(r, lane: .background, label: "/ns/ovfiets"), a.status == 200 else { return nil }
        return a.data
    }

    /// The station of a trip whose bikes count (where its last train arrives, with more of the trip after it).
    nonisolated static func station(for t: DoorTrip) -> (code: String, name: String)? {
        let rides = t.rides.map { r in
            OVFiets.Ride(train: r.isTrain, toCode: r.isTrain ? NSStore.code(stopId: "", name: r.toStop) : nil)
        }
        guard let code = OVFiets.station(rides, walkAfter: t.walkAfter),
              let last = t.rides.last(where: \.isTrain) else { return nil }
        return (code, Fmt.place(last.toStop))
    }
}

/// "Breda · OV-fiets: 12 left" (warm when only a few are left). Nothing while it doesn't know, for a station without
/// OV-fiets, or with the setting off.
struct OVFietsLine: View {
    let code: String?
    var station: String? = nil
    @ObservedObject private var store = OVFietsStore.shared
    @AppStorage(OVFietsStore.key) private var on = true

    var body: some View {
        let a: OVFiets.Answer? = on ? code.flatMap { store.answer($0) } : nil
        let text: String? = a.flatMap { OVFiets.text($0) }
        ZStack(alignment: .leading) {
            Color.clear.frame(width: 0, height: 0)
            if let a, let text {
                let warn = OVFiets.low(a)
                Label((station.map { "\($0) · " } ?? "") + text, systemImage: "bicycle")
                    .font(DS.footnoteStrong)
                    .foregroundStyle(warn ? DS.warning : DS.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel((station.map { "At \($0): " } ?? "") + text.replacingOccurrences(of: "·", with: ","))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(code ?? "")|\(on)") {
            guard on, let code else { return }
            await store.load(code)
        }
    }
}

// MARK: rain on the walk

/// Rain on your next trip's walks: Open-Meteo's hourly rain (the forecast the outfit uses, kept half an hour) at the
/// start and the end, looked at again at most every 10 minutes per trip. A bus instead of the walk to the station from
/// the other ways, else one Transitous plan by bus to the station.
@MainActor
final class RainStore: ObservableObject {
    static let shared = RainStore()
    /// Settings › Map & home › Rain advice for the walk.
    static let key = "rain.advice"

    /// The line per trip (`key(_:)`), nil: no rain on its walks.
    @Published private(set) var lines: [String: String] = [:]
    private var asked: [String: Date] = [:]

    /// A trip by its rides (its times move with the live ones; the advice doesn't need to).
    static func key(_ t: DoorTrip) -> String { t.rides.map(\.tripId).joined(separator: "+") }

    func line(_ t: DoorTrip) -> String? { lines[Self.key(t)] }

    func check(_ t: DoorTrip, others: [DoorTrip], origin: CLLocationCoordinate2D?) async {
        let now = Date()
        let k = Self.key(t)
        guard UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true, RainAdvice.due(start: t.start, now: now) else {
            lines[k] = nil
            return
        }
        if let a = asked[k], now.timeIntervalSince(a) < 10 * 60 { return }
        asked[k] = now
        let f = t.first, l = t.last
        var firstStop: CLLocationCoordinate2D? = nil
        if let la = f.fromLat, let lo = f.fromLon { firstStop = CLLocationCoordinate2D(latitude: la, longitude: lo) }
        var lastStop: CLLocationCoordinate2D? = nil
        if let la = l.toLat, let lo = l.toLon { lastStop = CLLocationCoordinate2D(latitude: la, longitude: lo) }
        let fix: CLLocationCoordinate2D? = origin ?? Self.recentFix()
        guard let here = fix ?? firstStop else { return }
        let there: CLLocationCoordinate2D = lastStop ?? here
        async let a = Weather.hourly(here)
        async let b = Weather.hourly(there)
        let (wHere, wThere) = await (a, b)
        let hours: ([WeatherHour]) -> [RainAdvice.Hour] = { list in list.map { RainAdvice.Hour(time: $0.time, mm: $0.rain) } }
        let stretches = RainAdvice.stretches(start: t.start, walkBefore: f.walkBefore, lastArrival: l.arrival, end: t.end)
        guard let hit = RainAdvice.hit(stretches, here: hours(wHere), there: hours(wThere)) else {
            lines[k] = nil
            return
        }
        var bus: RainAdvice.Bus? = nil
        if hit.atStart, f.isTrain, f.walkBefore >= 6 {
            bus = await Self.busInstead(t, others: others, from: origin ?? Self.recentFix(), now: now)
        }
        let advice = RainAdvice.advice(hit, firstIsTrain: f.isTrain, walkBefore: f.walkBefore, bus: bus)
        lines[k] = RainAdvice.text(hit, advice, hhmm: Fmt.hhmm)
    }

    /// The phone's own position, when it's recent and good enough to plan a bus from.
    private static func recentFix() -> CLLocationCoordinate2D? {
        guard let f = CLLocationManager().location, f.horizontalAccuracy >= 0, f.horizontalAccuracy < 300,
              -f.timestamp.timeIntervalSinceNow < 1800 else { return nil }
        return f.coordinate
    }

    /// A bus instead of the walk to the first train: one of the other ways that starts with a bus and is there at much
    /// the same time, else a bus to the station by Transitous (in time for the train).
    private static func busInstead(_ t: DoorTrip, others: [DoorTrip], from: CLLocationCoordinate2D?, now: Date) async -> RainAdvice.Bus? {
        let f = t.first
        let alts: [RainAdvice.Bus] = others.compactMap { o in
            guard !o.first.isTrain, o.first.fromId != "onboard" else { return nil }
            return RainAdvice.Bus(line: o.first.line, departure: o.first.departure, walkBefore: o.first.walkBefore,
                                  arrives: o.end, deadline: t.end.addingTimeInterval(10 * 60))
        }
        if let b = RainAdvice.bus(instead: f.walkBefore, now: now, from: alts) { return b }
        guard let from, let la = f.fromLat, let lo = f.fromLon else { return nil }
        let station = Place(key: "rain-station", name: f.fromStop, short: Fmt.place(f.fromStop), ids: [f.fromId.isEmpty ? "\(la),\(lo)" : f.fromId],
                            coordinate: CLLocationCoordinate2D(latitude: la, longitude: lo), spoken: Fmt.place(f.fromStop))
        let by = f.departure.addingTimeInterval(-2 * 60)
        let plans = await Transit.plan(from: Place.here(from), to: station, modes: "BUS", at: by, count: 3, maxTransfers: 0, arriveBy: true)
        let buses: [RainAdvice.Bus] = plans.compactMap { p in
            guard !p.first.isTrain else { return nil }
            return RainAdvice.Bus(line: p.first.line, departure: p.first.departure, walkBefore: p.first.walkBefore, arrives: p.end, deadline: by)
        }
        return RainAdvice.bus(instead: f.walkBefore, now: now, from: buses)
    }
}

/// "Rain at 08:00 — take bus 305 at 07:41 to the station instead of walking" / "… — bring an umbrella", before a trip.
struct RainAdviceLine: View {
    let trip: DoorTrip
    var others: [DoorTrip] = []
    var origin: CLLocationCoordinate2D? = nil
    @ObservedObject private var store = RainStore.shared
    @AppStorage(RainStore.key) private var on = true

    static let rainBlue = DS.dynamic(0x2F6DB5, 0x82B4F0)

    var body: some View {
        let text: String? = on ? store.line(trip) : nil
        ZStack(alignment: .leading) {
            Color.clear.frame(width: 0, height: 0)
            if let text {
                DSNote(icon: "cloud.rain.fill", tint: Self.rainBlue, text: text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(RainStore.key(trip))|\(on)|\(Int(trip.start.timeIntervalSince1970 / 300))") {
            guard on else { return }
            await store.check(trip, others: others, origin: origin)
        }
    }
}

/// Settings › Map & home: rain advice, OV-fiets, and how to add the widget and talk to Siri.
struct TripExtrasSettingsRows: View {
    @AppStorage(RainStore.key) private var rain = true
    @AppStorage(OVFietsStore.key) private var ovfiets = true

    var body: some View {
        Section {
            SettingsSwitch(title: "Rain advice for the walk", isOn: $rain)
                .settingsAnchor("map.rainAdvice")
            SettingsSwitch(title: "OV-fiets at the station", isOn: $ovfiets)
                .settingsAnchor("map.ovfiets")
        } header: { Text("On your trips") } footer: {
            Text("Before a trip, when rain (0.5 mm an hour or more, from Open-Meteo) is expected while you walk to the first stop or from the last one, the next-trip card and the Go card say so — with a bus to the station instead of the walk when there is one. On the Go card, the ride to your last station and a station’s sheet: how many OV-fiets NS has left there.")
        }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Widget and Siri").font(DS.body).foregroundStyle(DS.text)
                Text("Home screen or lock screen: touch and hold, tap Edit or +, find Haltewekker and add Next departures. Then touch and hold it, Edit Widget, and pick your stop.")
                    .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Say “Hey Siri, when’s my bus in Haltewekker”, “Wake me at a stop with Haltewekker”, “Plan to school with Haltewekker” or “Start my trip with Haltewekker” — or find them in the Shortcuts app.")
                    .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .settingsAnchor("map.widget")
        }
    }
}
