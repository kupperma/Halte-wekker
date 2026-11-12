import CoreLocation
import SwiftUI

// MARK: words for a ride

enum RideText {
    /// "On time, platform 5" · "3 min late, planned 08:02, now platform 7 (was 5)" · "Cancelled"
    static func status(_ r: Ride, _ i: RailInfo?) -> (text: String, warn: Bool, ok: Bool) {
        if r.cancelled || i?.cancelled == true { return ("Cancelled", true, false) }
        var st: String, warn = false, ok = false
        if !r.live { st = "Timetable time" }
        else if r.delay >= 1 { st = "\(r.delay) min late"; warn = true }
        else if r.delay <= -1 { st = "\(-r.delay) min early"; warn = true }
        else { st = "On time"; ok = true }
        if r.live && abs(r.delay) >= 1 { st += ", planned \(Fmt.hhmm(r.scheduledDeparture))" }
        if let i, i.trackChanged, let t = i.track, let p = i.plannedTrack { st += ", now platform \(t) (was \(p))"; warn = true; ok = false }
        else if let t = i?.track ?? r.platform, !t.isEmpty { st += ", platform \(t)" }
        return (st, warn, ok)
    }

    /// The live line on a boarding pass section.
    static func passLine(_ r: Ride, _ i: RailInfo?) -> PassLine? {
        if r.cancelled || i?.cancelled == true { return PassLine(text: "Cancelled", warn: true) }
        let changed = i?.trackChanged == true
        let track = i?.track ?? r.platform
        let plat: String? = changed ? "now platform \(track ?? "") (was \(i?.plannedTrack ?? ""))" : track.flatMap { $0.isEmpty ? nil : "platform \($0)" }
        if r.live && r.departure.timeIntervalSinceNow < 4 * 3600 {
            let st = r.delay >= 1 ? "\(r.delay) min late" : r.delay <= -1 ? "\(-r.delay) min early" : "On time"
            return PassLine(text: [st, plat].compactMap { $0 }.joined(separator: " · "), warn: changed || abs(r.delay) >= 1)
        }
        guard let plat else { return nil }
        return PassLine(text: plat.prefix(1).uppercased() + plat.dropFirst(), warn: changed)
    }

    static func change(_ mins: Int, _ what: String) -> PassLine { PassLine(text: "\(mins) min to \(what)", warn: mins < 3) }

    /// "under a minute", "4 min"
    static func roughly(km: Double, mode: Mode) -> String {
        let s = km / (mode == .bus ? 40 : 90) * 3600
        return s < 60 ? "under a minute" : "\(Int((s / 60).rounded())) min"
    }
}

// MARK: how busy, how long, where 1st class is

struct CrowdIcons: View {
    let level: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...3, id: \.self) { i in
                Image(systemName: "person.fill").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(i <= level ? color : Paper.muted.opacity(0.3))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["", "Quiet", "Busy", "Very busy"][min(3, max(0, level))])
    }
    private var color: Color { level >= 3 ? HWPalette.stamp : level == 2 ? Paper.late : Paper.ok }
}

/// The train along the platform: each unit, its 1st class part (yellow), the platform letters and which way it leaves.
struct ConsistView: View {
    let layout: TrainLayout
    let pal: HWPalette
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                let w = max(40, g.size.width - 16)
                let x0: CGFloat = layout.dir == "left" ? 14 : 2
                ZStack(alignment: .topLeading) {
                    ForEach(Array(layout.units.enumerated()), id: \.offset) { _, u in
                        unit(u, w).offset(x: x0 + u.x * w)
                    }
                    if let d = layout.dir {
                        Text(d == "right" ? "▶" : "◀").font(.system(size: 9)).foregroundStyle(pal.deep)
                            .offset(x: d == "right" ? x0 + w + 3 : 0, y: 3)
                    }
                    ForEach(layout.letters, id: \.self) { l in
                        Text(l.letter).font(HWFont.body(9, bold: true)).foregroundStyle(Paper.muted)
                            .position(x: x0 + l.x * w, y: 27)
                    }
                }
            }
            .frame(height: layout.letters.isEmpty ? 18 : 33)
            if let t = layout.firstClassText { Text(t).font(HWFont.body(11)).foregroundStyle(Paper.ink.opacity(0.8)) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layout.firstClassText ?? "Train layout")
    }

    private func unit(_ u: TrainUnit, _ total: CGFloat) -> some View {
        let w = max(4, u.w * total - 3)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(hex: 0x1A1D29))
            if let zones = u.zones {
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: w * NSStore.cab, height: 18)
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: w * NSStore.cab, height: 18).offset(x: w - w * NSStore.cab)
                ForEach(zones, id: \.self) { z in
                    ZStack {
                        Rectangle().fill(Color(hex: 0xF4C542))
                        Text("1").font(HWFont.body(10, bold: true)).foregroundStyle(Color(hex: 0x3B2A00))
                    }
                    .frame(width: max(2, (z.b - z.a) / u.w * w), height: 18)
                    .offset(x: (z.a - u.x) / u.w * w)
                }
                if let g = gap(u), (g.1 - g.0) / u.w > 0.12 {
                    Text("2").font(HWFont.body(10, bold: true)).foregroundStyle(Paper.ink.opacity(0.85))
                        .position(x: ((g.0 + g.1) / 2 - u.x) / u.w * w, y: 9)
                }
            } else {
                Text("?").font(HWFont.body(10, bold: true)).foregroundStyle(Paper.muted).frame(width: w, height: 18)
            }
        }
        .frame(width: w, height: 18, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Paper.ink.opacity(0.7), lineWidth: 1))
    }

    /// The longest 2nd class stretch, so the "2" isn't hidden behind the yellow.
    private func gap(_ u: TrainUnit) -> (Double, Double)? {
        var gaps: [(Double, Double)] = [(u.x, u.x + u.w)]
        for z in u.zones ?? [] {
            gaps = gaps.flatMap { g in [(g.0, min(g.1, z.a)), (max(g.0, z.b), g.1)].filter { $0.1 - $0.0 > 0.001 } }
        }
        return gaps.max { ($0.1 - $0.0) < ($1.1 - $1.0) }
    }
}

struct TrainExtras: View {
    let info: RailInfo?
    let pal: HWPalette
    var body: some View {
        if let s = info?.size {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.text).font(HWFont.body(11, bold: s.warn)).foregroundStyle(s.warn ? Paper.late : Paper.ink.opacity(0.75))
                if let l = s.layout { ConsistView(layout: l, pal: pal) }
            }
            .padding(.top, 2)
        }
    }
}

struct SmallTag: View {
    let text: String
    var icon: String? = nil
    let pal: HWPalette
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8, weight: .bold)) }
            Text(text).font(HWFont.body(9, bold: true)).tracking(1)
        }
        .foregroundStyle(Color(hex: 0x14121A)).padding(.horizontal, 5).padding(.vertical, 2).background(pal.band)
    }
}

// MARK: platform change

struct PlatformAlertView: View {
    let alert: PlatformAlert
    let pal: HWPalette
    let ok: () -> Void
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x2A1208), Color(hex: 0x0A0605)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Spacer()
                Text(alert.cancelled ? "TRAIN CANCELLED" : "PLATFORM CHANGE").font(HWFont.body(12, bold: true)).tracking(2).foregroundStyle(Paper.late)
                if alert.cancelled {
                    Text("Cancelled").font(HWFont.display(54)).foregroundStyle(Paper.ink)
                } else {
                    Text("Platform \(alert.now)").font(HWFont.display(54)).foregroundStyle(Paper.ink).minimumScaleFactor(0.6)
                    Text("was platform \(alert.was)").font(HWFont.display(20)).foregroundStyle(Paper.muted).strikethrough()
                }
                Text(alert.cancelled ? "Your \(alert.label) from \(alert.from) has been cancelled. Check the train list for the next one."
                                     : "Your \(alert.label) now leaves \(alert.from) from platform \(alert.now) instead of \(alert.was).")
                    .font(HWFont.body(15)).foregroundStyle(Paper.ink.opacity(0.85))
                Spacer()
                BandButton(title: "OK, got it", pal: pal, action: ok)
            }
            .padding(24)
        }
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: plan by train time

struct PlanSheet: View {
    @EnvironmentObject var planner: Planner
    @EnvironmentObject var trip: TripManager
    @Environment(\.dismiss) private var dismiss
    var byArrival = true                    // be there by a time (or else: your friend's train)
    @State private var arriveMode = true
    @State private var out = true
    @State private var time = Date()
    @State private var tomorrow = false
    @State private var error: String?
    var body: some View {
        let pal = HWPalette.of(home: !out)
        NavigationStack {
            Form {
                Section {
                    Picker("Plan by", selection: $arriveMode) { Text("Be there by").tag(true); Text("Friend’s train").tag(false) }.pickerStyle(.segmented)
                }
                Section {
                    Picker("Direction", selection: $out) { Text(arriveMode ? "To school" : "To Breda").tag(true); Text("Home").tag(false) }.pickerStyle(.segmented)
                    DatePicker(arriveMode ? (out ? "Be at BUas by" : "Be home by") : (out ? "Arrive in Breda at" : "Leave Breda at"), selection: $time, displayedComponents: .hourAndMinute)
                    Picker("Day", selection: $tomorrow) { Text("Today").tag(false); Text("Tomorrow").tag(true) }.pickerStyle(.segmented)
                } footer: {
                    if arriveMode {
                        Text("The app finds the trip that leaves the latest and still gets you \(out ? "to BUas" : "home to Veghel") in time, from \(out ? "your Veghel stops" : "BUas"), with live times. You get a reminder ten minutes before you have to leave.")
                    } else {
                        Text("Use the time of your friend’s train. The app finds that train, \(out ? "the bus from Veghel that gets you there in time and the bus to BUas after it" : "the bus from BUas to catch it and the bus to Veghel after it").")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(Paper.late) } }
                Section {
                    Button(arriveMode ? "Find the best trip" : "Find this trip") {
                        let e = arriveMode ? planner.setArrive(out: out, time: time, tomorrow: tomorrow) : planner.set(out: out, time: time, tomorrow: tomorrow)
                        if let e { error = e } else { dismiss() }
                    }
                    .foregroundStyle(pal.deep)
                    if arriveMode && planner.arrive != nil { Button("Remove this plan", role: .destructive) { planner.clearArrive(); dismiss() } }
                    if !arriveMode && planner.trip != nil { Button("Remove the trip", role: .destructive) { planner.clear(); dismiss() } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PaperFill().ignoresSafeArea()).preferredColorScheme(.light)
            .font(HWFont.body(15)).tint(pal.band)
            .navigationTitle(arriveMode ? "Be there by" : "Plan by train time")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear {
            arriveMode = byArrival
            if byArrival {
                if let a = planner.arrive, let w = a.when {
                    out = a.out; time = w; tomorrow = !Calendar.current.isDateInToday(w)
                } else {
                    out = trip.direction == .toSchool
                    tomorrow = Calendar.current.component(.hour, from: Date()) >= (out ? 9 : 17)
                    time = Calendar.current.date(bySettingHour: out ? 9 : 18, minute: 0, second: 0, of: Date()) ?? Date()
                }
            } else if let t = planner.trip, let w = t.when {
                out = t.out; time = w; tomorrow = !Calendar.current.isDateInToday(w)
            } else {
                out = trip.direction == .toSchool
                tomorrow = Calendar.current.component(.hour, from: Date()) >= 12
                time = Calendar.current.date(bySettingHour: out ? 8 : 16, minute: out ? 21 : 30, second: 0, of: Date()) ?? Date()
            }
        }
    }
}

private struct PassLeg: Identifiable {
    let id = UUID()
    let time: String
    let badge: String
    let to: String
    let grade: String?
    let lines: [PassLine?]
    var tag: String? = nil
    var gone = false
    var extra: AnyView? = nil
}

/// Your planned trip with your friend, as a boarding pass: bus, the train, bus.
struct PlannedPass: View {
    @EnvironmentObject var planner: Planner
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var ns: NSStore
    @EnvironmentObject var watch: WatchStore
    let edit: () -> Void
    let wake: (RoutePlan) -> Void

    var body: some View {
        if let t = planner.trip {
            let pal = HWPalette.of(home: !t.out)
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    HStack {
                        Text("BOARDING PASS").font(HWFont.display(13)).tracking(2).foregroundStyle(pal.deep)
                        Spacer()
                        Button("Change", action: edit).font(HWFont.body(12, bold: true)).foregroundStyle(pal.deep)
                    }
                    .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 7)
                    Rectangle().fill(pal.line).frame(height: 1)
                    if let op = planner.chosen {
                        content(op, t, pal)
                    } else {
                        sub(t, right: "", pal)
                        Text(planner.error ?? "Finding your train and buses…").font(HWFont.body(13)).foregroundStyle(Paper.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                }
                .brass(pal, pad: 8)
                if let op = planner.chosen, let r = RoutePlan.via(op.station) {
                    BandButton(title: "Wake me on this trip", pal: pal) { wake(r) }
                }
                if let u = planner.updated {
                    let watched = planner.chosen.map { watch.isWatched($0.train.first, from: $0.from) } ?? false
                    Text("Updated at \(Fmt.hhmm(u)).\((t.when?.timeIntervalSinceNow ?? 0) > 4 * 3600 ? " Live delays show up a few hours before." : "")\(watched ? " You get an alarm if this train changes platform or is cancelled." : "")")
                        .font(HWFont.body(11)).foregroundStyle(Paper.muted)
                }
            }
        }
    }

    private func sub(_ t: PlannedTrip, right: String, _ pal: HWPalette) -> some View {
        HStack {
            Text("\(t.dayLabel) · \(t.out ? "arrive Breda" : "leave Breda") \(t.time)".uppercased())
            Spacer()
            Text(right.uppercased())
        }
        .font(HWFont.body(11)).tracking(0.8).foregroundStyle(Paper.ink.opacity(0.8)).padding(.horizontal, 12).padding(.top, 6)
    }

    @ViewBuilder
    private func content(_ op: PlanOption, _ t: PlannedTrip, _ pal: HWPalette) -> some View {
        let built = build(op, out: t.out, pal)
        let legs = built.legs, stops = built.stops
        sub(t, right: built.right, pal)
        if planner.options.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(planner.options.enumerated()), id: \.offset) { i, x in
                        Button { planner.pick = i } label: {
                            Text("\(x.train.first.name.isEmpty ? "Train" : x.train.first.name) \(t.out ? "from \(x.from.short)" : "to \(x.to.short)")")
                                .font(HWFont.body(12, bold: true))
                                .foregroundStyle(i == planner.pick ? Color.white : Paper.ink)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(i == planner.pick ? Paper.ink : .clear)
                                .overlay(Rectangle().stroke(pal.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.top, 8)
        }
        if planner.inexact {
            Text("No train \(t.out ? "arrives in" : "leaves") Breda at exactly \(t.time). This is the closest one.")
                .font(HWFont.body(12, bold: true)).foregroundStyle(Paper.late).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 8)
        }
        RouteStrip(stops: stops, grades: legs.map(\.grade), pal: pal).padding(.top, 12)
        ForEach(legs) { l in
            PassSection(time: l.time, badge: l.badge, to: l.to, grade: l.grade, lines: l.lines.compactMap { $0 }, tag: l.tag, gone: l.gone, pal: pal, extra: l.extra)
        }
        let notes = [op.busInAlt.map { "Earlier bus: \($0.first.line) at \(Fmt.hhmm($0.first.departure))" },
                     op.busOutAlt.map { "Next one: \($0.first.line) at \(Fmt.hhmm($0.first.departure))" }].compactMap { $0 }
        HStack(alignment: .top) {
            Text(notes.isEmpty ? "Valid for this trip only" : notes.joined(separator: " · "))
            Spacer()
            if watch.isWatched(op.train.first, from: op.from) { Label("Watching \(op.train.first.line)", systemImage: "bell.fill") }
        }
        .font(HWFont.body(11)).foregroundStyle(Paper.ink.opacity(0.85))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .overlay(alignment: .top) { DottedLine(vertical: false).stroke(pal.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(height: 1.5) }
    }

    private func build(_ op: PlanOption, out: Bool, _ pal: HWPalette) -> (legs: [PassLeg], stops: [(name: String, time: String)], right: String) {
        let o = op.train, info = ns.rail(o.first), arr = o.last.arrival
        let train: PassLeg = PassLeg(time: Fmt.hhmm(o.first.departure), badge: o.first.line, to: out ? "to Breda" : "to \(op.to.short)",
                            grade: o.rides.count == 1 ? o.first.grade : o.last.grade,
                            lines: [RideText.passLine(o.first, info), o.changes.isEmpty ? nil : PassLine(text: "Change at \(o.changes.joined(separator: ", "))"),
                                    PassLine(text: "\(o.rideLabel) · arrives \(Fmt.hhmm(arr))")],
                            tag: "FRIEND", gone: o.first.cancelled || info?.cancelled == true, extra: AnyView(TrainExtras(info: info, pal: pal)))
        let bi = op.busIn, bo = op.busOut
        func mins(_ a: Date, _ b: Date) -> Int { Int((b.timeIntervalSince(a) / 60).rounded()) }
        if out {
            let a: PassLeg = bi.map { b -> PassLeg in
                PassLeg(time: Fmt.hhmm(b.first.departure), badge: "BUS \(b.first.line)", to: "to \(op.from.short)", grade: b.first.grade,
                        lines: [RideText.passLine(b.first, nil), PassLine(text: "\(b.rideLabel) · arrives \(Fmt.hhmm(b.last.arrival))"),
                                RideText.change(mins(b.end, o.first.departure), "change")], gone: b.first.cancelled)
            } ?? PassLeg(time: "–", badge: "BUS", to: "No bus in time", grade: nil, lines: [PassLine(text: "Take an earlier bus to \(op.from.short).", warn: true)])
            let c: PassLeg = bo.map { b -> PassLeg in
                PassLeg(time: Fmt.hhmm(b.first.departure), badge: "BUS \(b.first.line)", to: "to \(Fmt.place(b.last.toStop))", grade: b.first.grade,
                        lines: [RideText.passLine(b.first, nil), PassLine(text: "\(b.rideLabel)\(b.walkAfter > 0 ? " · \(b.walkAfter) min walk" : "")"),
                                RideText.change(mins(arr, b.first.departure) - b.first.walkBefore, "get to the bus")], gone: b.first.cancelled)
            } ?? PassLeg(time: "–", badge: "BUS", to: "No bus to BUas", grade: nil, lines: [PassLine(text: "Walking takes about 17 min.")])
            let stops: [(name: String, time: String)] = [(name: "Veghel", time: bi.map { Fmt.hhmm($0.first.departure) } ?? ""), (name: op.from.short, time: Fmt.hhmm(o.first.departure)),
                         (name: "Breda", time: bo.map { Fmt.hhmm($0.first.departure) } ?? Fmt.hhmm(arr)), (name: "BUas", time: bo.map { Fmt.hhmm($0.end) } ?? "")]
            return ([a, train, c], stops, bo.map { "At BUas \(Fmt.hhmm($0.end))" } ?? "Breda \(Fmt.hhmm(arr))")
        } else {
            let a: PassLeg = bi.map { b -> PassLeg in
                PassLeg(time: Fmt.hhmm(b.first.departure), badge: "BUS \(b.first.line)", to: "to Breda station", grade: b.first.grade,
                        lines: [RideText.passLine(b.first, nil), b.first.walkBefore > 0 ? PassLine(text: "Leave BUas \(Fmt.hhmm(b.start)), \(b.first.walkBefore) min walk") : nil,
                                RideText.change(mins(b.end, o.first.departure), "change")], gone: b.first.cancelled)
            } ?? PassLeg(time: "–", badge: "BUS", to: "No bus in time", grade: nil, lines: [PassLine(text: "Walk to the station, about 17 min.", warn: true)])
            let c: PassLeg = bo.map { b -> PassLeg in
                PassLeg(time: Fmt.hhmm(b.first.departure), badge: "BUS \(b.first.line)", to: "to \(Fmt.place(b.last.toStop))", grade: b.first.grade,
                        lines: [RideText.passLine(b.first, nil), PassLine(text: "\(b.rideLabel) to \(Fmt.place(b.last.toStop))"),
                                RideText.change(mins(arr, b.first.departure) - b.first.walkBefore, "get to the bus")], gone: b.first.cancelled)
            } ?? PassLeg(time: "–", badge: "BUS", to: "No bus to Veghel", grade: nil, lines: [])
            let stops: [(name: String, time: String)] = [(name: "BUas", time: bi.map { Fmt.hhmm($0.start) } ?? ""), (name: "Breda", time: Fmt.hhmm(o.first.departure)),
                         (name: op.to.short, time: bo.map { Fmt.hhmm($0.first.departure) } ?? Fmt.hhmm(arr)), (name: "Veghel", time: bo.map { Fmt.hhmm($0.last.arrival) } ?? "")]
            return ([a, train, c], stops, bo.map { "Home around \(Fmt.hhmm($0.last.arrival))" } ?? "")
        }
    }
}

// MARK: score and leaderboard

struct ScoreCard: View {
    let result: ScoreResult
    let pal: HWPalette
    var body: some View {
        let e = result.entry
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                VStack(spacing: 2) {
                    Text("\(e.score)").font(HWFont.display(34)).monospacedDigit()
                    Text("OF 500\nVALIDATED").font(HWFont.body(9, bold: true)).tracking(1.2).multilineTextAlignment(.center)
                }
                .foregroundStyle(HWPalette.stamp)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(HWPalette.stamp, lineWidth: 2))
                .rotationEffect(.degrees(-6))
                Coin(grade: e.grade, size: 54, pal: pal)
            }
            Text("\(Int(e.mins.rounded())) min\(e.est ? ". Your next trips on this route are compared with this one." : ". The fastest possible is about \(e.ref) min.")")
                .font(HWFont.body(13)).foregroundStyle(Paper.ink.opacity(0.85))
            if let f = result.flag { Text(f).font(HWFont.display(16)).foregroundStyle(pal.deep) }
        }
    }
}

struct LeaderboardView: View {
    @EnvironmentObject var scores: ScoreBook
    let pal: HWPalette
    @State private var home = true
    @State private var week = true
    var body: some View {
        let all = scores.trips.filter { $0.home == home }
        let list = Array(scores.board(home: home, week: week).prefix(10))
        let best = scores.bestThisWeek(home: home)
        VStack(alignment: .leading, spacing: 10) {
            Picker("Direction", selection: $home) { Text("Home").tag(true); Text("To Breda").tag(false) }.pickerStyle(.segmented)
            Picker("When", selection: $week) { Text("This week").tag(true); Text("All time").tag(false) }.pickerStyle(.segmented)
            if list.isEmpty {
                Text(all.isEmpty ? "No trips yet. Start the alarm under “Wake me up” and ride to your last stop. Each trip gets a score out of 500 here." : "No trips this week yet.")
                    .font(HWFont.body(12)).foregroundStyle(Paper.muted)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(HWFont.display(16)).foregroundStyle(Paper.muted).frame(width: 22)
                    Coin(grade: t.grade, size: 26, pal: pal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(t.mins.rounded())) min · \(t.score)/500").font(HWFont.display(15)).foregroundStyle(Paper.ink)
                        Text("\(Fmt.when(t.at)) · \(t.route)").font(HWFont.body(11)).foregroundStyle(Paper.muted)
                    }
                    Spacer(minLength: 4)
                    if t.id == best?.id { SmallTag(text: "BEST", pal: pal) }
                    Button { withAnimation { scores.remove(t.id) } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Paper.muted).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Remove this trip")
                }
                .padding(.vertical, 4)
                Rectangle().fill(Paper.rule).frame(height: 1)
            }
            Text("Time from starting the alarm until you reach your last stop, so waiting at the change counts. 500 means as fast as that route gets.")
                .font(HWFont.body(11)).foregroundStyle(Paper.muted)
        }
    }
}

// MARK: starting a trip

struct StartRequest: Identifiable {
    let id = UUID()
    var route: RoutePlan? = nil
    var stop: Place? = nil
}

struct StartSheet: View {
    let req: StartRequest
    @EnvironmentObject var trip: TripManager
    @Environment(\.dismiss) private var dismiss
    @State private var kms: [Double] = []
    @State private var mode: Mode = .train

    private var legs: [Leg] {
        if let r = req.route { return r.legs(trip.direction) }
        if let p = req.stop { return [Leg(mode: mode, from: .here(trip.here ?? p.coordinate), to: p)] }
        return []
    }
    private var title: String { req.stop?.name ?? (trip.direction == .toSchool ? "To school" : "Home") }

    var body: some View {
        let pal = HWPalette.of(home: trip.direction == .home)
        NavigationStack {
            Form {
                if req.stop != nil {
                    Section("You’re riding the") {
                        Picker("Riding", selection: $mode) { Text("Bus").tag(Mode.bus); Text("Train").tag(Mode.train) }.pickerStyle(.segmented)
                    }
                }
                ForEach(Array(legs.enumerated()), id: \.offset) { i, l in
                    Section(req.stop == nil ? "\(l.mode.title) to \(l.to.name)" : "Wake me") {
                        let k = kms[safe: i] ?? trip.km(for: l)
                        Stepper("Ring \(Fmt.km(k)) before the stop", value: km(i, l), in: 0.5...(l.mode == .bus ? 10 : 15), step: 0.5)
                        Text("That’s roughly \(RideText.roughly(km: k, mode: l.mode)) before you arrive.").font(HWFont.body(12)).foregroundStyle(Paper.muted)
                    }
                }
                Section {
                    Button("Start sleeping") { go() }.font(HWFont.display(17)).foregroundStyle(pal.deep)
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PaperFill().ignoresSafeArea()).preferredColorScheme(.light)
            .font(HWFont.body(15)).tint(pal.band)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            if let p = req.stop { mode = StopsStore.shared.mode(for: p) }
            kms = legs.map(trip.km(for:))
        }
        .onChange(of: mode) { _, _ in kms = legs.map(trip.km(for:)) }
    }

    private func km(_ i: Int, _ l: Leg) -> Binding<Double> {
        Binding(get: { kms[safe: i] ?? trip.km(for: l) }, set: { v in
            while kms.count <= i { kms.append(trip.km(for: legs[kms.count])) }
            kms[i] = v
        })
    }

    private func go() {
        if let r = req.route { trip.start(r, kms: kms) }
        else if let p = req.stop {
            StopsStore.shared.setMode(mode, for: p)
            trip.start(.stop(p, mode: mode, from: .here(trip.here ?? p.coordinate)), kms: kms)
        }
        dismiss()
    }
}

// MARK: single stops

struct StopsList: View {
    @EnvironmentObject var stops: StopsStore
    let pal: HWPalette
    let start: (Place) -> Void
    let edit: (SavedStop?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("For trips without a route.").font(HWFont.body(12)).foregroundStyle(Paper.muted)
                Spacer()
                Button("Add a stop") { edit(nil) }.font(HWFont.body(12, bold: true)).foregroundStyle(pal.deep)
            }
            .padding(.vertical, 8)
            ForEach(Place.all, id: \.key) { p in
                row(p.name, sub: p == .veghel ? "Your home stop" : p == .breda ? "Your school stop" : nil, editable: nil) { start(p) }
            }
            ForEach(stops.saved) { s in row(s.name, sub: nil, editable: s) { start(s.place) } }
        }
    }
    private func row(_ name: String, sub: String?, editable: SavedStop?, tap: @escaping () -> Void) -> some View {
        HStack {
            Button(action: tap) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(HWFont.display(16)).foregroundStyle(Paper.ink)
                    if let sub { Text(sub).font(HWFont.body(11)).foregroundStyle(Paper.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let e = editable {
                Button { edit(e) } label: { Image(systemName: "pencil").foregroundStyle(pal.deep).frame(width: 36, height: 36) }
                    .buttonStyle(.plain).accessibilityLabel("Edit \(name)")
            } else {
                Image(systemName: "bell.and.waves.left.and.right").foregroundStyle(pal.deep)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
    }
}

struct StopEditRequest: Identifiable {
    let id = UUID()
    let stop: SavedStop?
}

struct StopSheet: View {
    let req: StopEditRequest
    @EnvironmentObject var stops: StopsStore
    @EnvironmentObject var near: NearMe
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var query = ""
    @State private var hits: [Transit.StopHit] = []
    @State private var coord: CLLocationCoordinate2D?
    @State private var stopId: String?
    @State private var searching = false
    @State private var waitingForHere = false
    @State private var note: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Like Grandma’s or Breda Nassausingel", text: $name) }
                Section {
                    HStack {
                        TextField("Search a stop", text: $query).onSubmit { search() }.autocorrectionDisabled()
                        Button(searching ? "…" : "Search") { search() }.disabled(query.count < 2 || searching)
                    }
                    ForEach(hits) { h in
                        Button {
                            if name.isEmpty || hits.contains(where: { $0.name == name }) { name = h.name }
                            coord = .init(latitude: h.lat, longitude: h.lon); stopId = h.id; note = nil
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(h.name).foregroundStyle(Paper.ink)
                                    if !h.town.isEmpty { Text(h.town).font(HWFont.body(11)).foregroundStyle(Paper.muted) }
                                }
                                Spacer()
                                if stopId == h.id { Image(systemName: "checkmark").foregroundStyle(Paper.ok) }
                            }
                        }
                    }
                    Button("Use my current location") { waitingForHere = true; note = "Finding where you are…"; near.locate(force: true, ask: true) }
                } header: { Text("Where") } footer: {
                    Text(note ?? (coord.map { String(format: "Location set: %.5f, %.5f", $0.latitude, $0.longitude) } ?? "Search for the stop, or stand at it and use your location."))
                }
                Section {
                    Button(req.stop == nil ? "Add stop" : "Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || coord == nil)
                    if let s = req.stop { Button("Delete stop", role: .destructive) { stops.delete(s.id); dismiss() } }
                }
            }
            .navigationTitle(req.stop == nil ? "Add a stop" : "Edit stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear {
            if let s = req.stop { name = s.name; coord = .init(latitude: s.lat, longitude: s.lon); stopId = s.stopId }
        }
        .onChange(of: near.position) { _, p in
            guard waitingForHere, let p else { return }
            waitingForHere = false; coord = p.coordinate; stopId = nil
            note = "Location set to where you are (±\(Int(p.horizontalAccuracy)) m)."
        }
    }
    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        searching = true
        Task { hits = await Transit.findStops(q); searching = false; if hits.isEmpty { note = "No stops found for “\(q)”." } }
    }
    private func save() {
        guard let c = coord else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        if var s = req.stop { s.name = n; s.lat = c.latitude; s.lon = c.longitude; s.stopId = stopId; stops.update(s) }
        else { stops.add(name: n, at: c, stopId: stopId) }
        dismiss()
    }
}

// MARK: the live board's stops and lines

struct LiveSettingsSheet: View {
    @EnvironmentObject var stops: StopsStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [Transit.StopHit] = []
    @State private var lines = ""
    @State private var searching = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(stops.boardStops) { s in Text(s.name) }
                        .onDelete { stops.boardStops.remove(atOffsets: $0) }
                } header: { Text("Stops (up to \(StopsStore.maxBoardStops))") } footer: { Text("Swipe left on a stop to remove it.") }
                if stops.boardStops.count < StopsStore.maxBoardStops {
                    Section("Add a stop") {
                        HStack {
                            TextField("Search, like Veghel Bolkenplein", text: $query).onSubmit { search() }.autocorrectionDisabled()
                            Button(searching ? "…" : "Search") { search() }.disabled(query.count < 2 || searching)
                        }
                        ForEach(hits) { h in
                            Button {
                                if !stops.boardStops.contains(where: { $0.id == h.id }) { stops.boardStops.append(BoardStop(id: h.id, name: h.name)) }
                                hits = []; query = ""
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(h.name).foregroundStyle(Paper.ink)
                                    if !h.town.isEmpty { Text(h.town).font(HWFont.body(11)).foregroundStyle(Paper.muted) }
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("305, 306, 158", text: $lines).keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                } header: { Text("Your lines") } footer: { Text("“My lines” shows only these. Leave it empty to show every bus.") }
                Section {
                    Button("Back to Veghel Busstation and Bolkenplein") {
                        stops.boardStops = StopsStore.defaultBoard; stops.lines = StopsStore.defaultLines; lines = StopsStore.defaultLines.joined(separator: ", ")
                    }
                }
            }
            .navigationTitle("Live bus times stops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { lines = stops.lines.joined(separator: ", ") }
        .onDisappear {
            stops.lines = lines.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        searching = true
        Task { hits = await Transit.findStops(q); searching = false }
    }
}

// MARK: at a transfer: what leaves next from here

struct TransferList: View {
    @State private var earlier = false
    let all: [PanelTrip]
    let updated: Date?
    let error: String?
    let mode: Mode
    let dest: String
    let pal: HWPalette
    @EnvironmentObject var ns: NSStore
    @EnvironmentObject var watch: WatchStore
    @EnvironmentObject var planner: Planner
    var body: some View {
        let what = mode == .train ? "trains" : "buses"
        let mine = planner.chosen?.tripIds ?? []
        let list = Array(all.filter { $0.trip.first.departure > Date().addingTimeInterval(earlier ? -30 * 60 : -60) }.prefix(earlier ? 10 : 6))
        VStack(alignment: .leading, spacing: 6) {
            PlannerBar(title: "Next \(what) to \(dest)", sub: updated.map { "updated \(Fmt.hhmm($0))" })
            if list.isEmpty {
                Text(error ?? (updated == nil ? "Looking up the next \(what)…" : "No \(what) to \(dest) coming up."))
                    .font(BoardInk.sans(12, .regular)).foregroundStyle(Paper.ink.opacity(0.85)).padding(.vertical, 6)
            } else {
                PlannerColumns()
            }
            ForEach(list) { p in
                let t = p.trip, f = t.first, rail = f.isTrain, info = ns.rail(f)
                let plat = info?.track ?? f.platform
                PlannerBusRow(line: f.line, to: rail ? (f.headsign.isEmpty ? p.to.short : Fmt.place(f.headsign)) : Fmt.place(t.last.toStop),
                              time: f.departure, scheduled: f.scheduledDeparture, live: f.live, cancelled: f.cancelled || info?.cancelled == true,
                              grade: rail ? nil : (t.rides.count == 1 ? f.grade : t.last.grade), train: rail,
                              note: "\(t.rideLabel) · arrives \(Fmt.hhmm(t.last.arrival))\(plat.map { " · platform \($0)" } ?? "")",
                              heading: Heading.of(f), watched: rail && watch.isWatched(f, from: p.from), picked: mine.contains(f.tripId)) {
                    if rail { _ = watch.toggle(t, from: p.from, to: p.to) }
                }
            }
            Button(earlier ? "Hide earlier ones" : "Show earlier ones") { withAnimation { earlier.toggle() } }
                .font(BoardInk.sans(12, .semibold)).foregroundStyle(Paper.ink).padding(.top, 4)
            if mode == .train { Text("Tap a train to be told if its platform changes or it runs late.").font(BoardInk.sans(10, .regular)).foregroundStyle(Paper.ink.opacity(0.65)) }
        }
    }
}

// MARK: a departure on a stop's board

struct BoardRow: View {
    let d: BoardDeparture
    var ride: BoardRide? = nil          // how long to the station, and the rating
    var stopLabel: String? = nil        // when the board has several stops
    var watched = false
    let pal: HWPalette
    var onBell: (() -> Void)? = nil

    static func status(_ d: BoardDeparture) -> String {
        var st: String
        if d.cancelled { st = "cancelled" }
        else if !d.live { st = "timetable time" }
        else if d.delay >= 1 { st = "\(d.delay) min late, planned \(Fmt.hhmm(d.scheduled))" }
        else if d.delay <= -1 { st = "\(-d.delay) min early, planned \(Fmt.hhmm(d.scheduled))" }
        else { st = "on time" }
        if let p = d.platform, !p.isEmpty, !d.cancelled { st += ", platform \(p)" }
        return st.prefix(1).uppercased() + st.dropFirst()
    }
    static func when(_ d: BoardDeparture) -> String {
        let m = Int((d.time.timeIntervalSinceNow / 60).rounded())
        if d.cancelled { return m < 0 ? "was due" : "" }
        if m <= -1 { return "left \(-m) min ago" }
        return m == 0 ? "now" : "in \(m) min"
    }

    var body: some View {
        let gone = !d.cancelled && d.time < Date().addingTimeInterval(-60)
        HStack(alignment: .top, spacing: 10) {
            LineBullet(line: d.line, grade: d.cancelled ? nil : ride?.grade, height: 24, minWidth: 44, font: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.headsign).font(HWFont.display(16)).foregroundStyle(Paper.ink)
                if watched { SmallTag(text: "WATCHING", icon: "bell.fill", pal: pal) }
                Text([stopLabel, Self.status(d)].compactMap { $0 }.joined(separator: " · "))
                    .font(HWFont.body(12, bold: d.live || d.cancelled))
                    .foregroundStyle(d.delay != 0 || d.cancelled ? Paper.late : d.live ? Paper.ok : Paper.muted)
                if let r = ride, !d.cancelled {
                    Text("\(Fmt.rideText(r.minutes)) ride to \(r.station) station, arrives \(Fmt.hhmm(r.arrival))").font(HWFont.body(12)).foregroundStyle(Paper.ink.opacity(0.8))
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.hhmm(d.cancelled ? d.scheduled : d.time)).font(HWFont.display(23)).foregroundStyle(d.cancelled ? Paper.late : pal.deep).strikethrough(d.cancelled)
                Text(Self.when(d)).font(HWFont.body(12)).foregroundStyle(Paper.muted)
                if let onBell {
                    Button(action: onBell) {
                        Image(systemName: watched ? "bell.fill" : "bell").font(.system(size: 15, weight: .semibold)).foregroundStyle(watched ? pal.deep : pal.deep)
                            .frame(width: 36, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(watched ? "Stop watching the \(d.line)" : "Watch the \(d.line): get told when it's late, early or cancelled")
                }
            }
        }
        .padding(.vertical, 10)
        .opacity(gone ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

/// What you're watching right now: bus lines and trains, with how they're doing.
struct WatchingCard: View {
    @EnvironmentObject var lines: LineWatchStore
    @EnvironmentObject var trains: WatchStore
    let pal: HWPalette
    var board = false                   // in the planner's style, on the boards on the wall
    var body: some View {
        let manual = trains.watches.filter { !$0.auto && $0.target > Date().addingTimeInterval(-20 * 60) }
        if (!lines.watches.isEmpty || !manual.isEmpty) && board {
            boardCard(manual)
        } else if !lines.watches.isEmpty || !manual.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bell.badge.fill").foregroundStyle(pal.deep)
                    Text("Watching").font(HWFont.display(18)).foregroundStyle(Paper.ink)
                    Spacer()
                }
                ForEach(lines.watches) { w in
                    row(title: "\(w.line)\(w.headsign.isEmpty ? "" : " to \(w.headsign)") · \(Fmt.place(w.stopName))", sub: w.status,
                        warn: w.status.contains("late") || w.status.contains("early") || w.status.contains("cancelled")) { lines.stop(w.id) }
                }
                ForEach(manual) { w in
                    row(title: "\(w.label) · \(w.from)", sub: w.cancelled ? "Cancelled" : w.track.isEmpty ? "Platform not known yet" : "Platform \(w.track)",
                        warn: w.cancelled) { trains.remove(w.key) }
                }
                Text("You get a notification when it runs late, leaves early, changes platform or is cancelled. Bus lines stop by themselves once you’re on board.")
                    .font(HWFont.body(11)).foregroundStyle(Paper.muted)
            }
            .brass(pal, pad: 14)
        }
    }
    /// On the planner: a white header bar, then each line with its box (trains yellow, buses light blue) and a Stop button.
    private func boardCard(_ manual: [TrainWatch]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PlannerBar(title: "Watching", sub: "\(lines.watches.count + manual.count) for you")
            ForEach(lines.watches) { w in
                boardRow(line: w.line, train: false, title: w.headsign.isEmpty ? "Bus \(w.line)" : w.headsign,
                         sub: "from \(Fmt.place(w.stopName)) · \(w.status)",
                         warn: w.status.contains("late") || w.status.contains("early") || w.status.contains("cancelled")) { lines.stop(w.id) }
            }
            ForEach(manual) { w in
                boardRow(line: trainBadge(w.label), train: true, title: w.label,
                         sub: "from \(w.from) · " + (w.cancelled ? "Cancelled" : w.track.isEmpty ? "platform not known yet" : "platform \(w.track)"),
                         warn: w.cancelled) { trains.remove(w.key) }
            }
            Text("You get a notification when it runs late, leaves early, changes platform or is cancelled. Bus lines stop by themselves once you’re on board.")
                .font(BoardInk.sans(9.5, .regular)).foregroundStyle(Paper.ink.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func boardRow(line: String, train: Bool, title: String, sub: String, warn: Bool, stop: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            LineBullet(line: line, train: train, height: 22, minWidth: 38, font: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(BoardInk.sans(13)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.7)
                Text(sub).font(BoardInk.sans(10.5, warn ? .bold : .regular)).foregroundStyle(warn ? Paper.late : Paper.ok).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(action: stop) {
                Text("Stop").font(BoardInk.sans(11)).foregroundStyle(Paper.ink)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Paper.ink.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop watching \(title)")
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.ink.opacity(0.12)).frame(height: 1) }
    }
    private func trainBadge(_ label: String) -> String {
        let l = label.lowercased()
        return l.contains("sprinter") ? "SPR" : l.contains("intercity") ? "IC" : "Train"
    }

    private func row(title: String, sub: String, warn: Bool, stop: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(HWFont.display(15)).foregroundStyle(Paper.ink)
                Text(sub).font(HWFont.body(12, bold: warn)).foregroundStyle(warn ? Paper.late : Paper.ok)
            }
            Spacer()
            Button("Stop", action: stop).font(HWFont.body(12, bold: true)).foregroundStyle(pal.deep)
        }
        .padding(.vertical, 4)
    }
}

// MARK: small things

struct ToastView: View {
    let text: String
    let pal: HWPalette
    var body: some View {
        Text(text).font(HWFont.body(13, bold: true)).foregroundStyle(.white)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.navy.opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.ink.opacity(0.2), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            .padding(.horizontal, 18)
    }
}

struct TipsList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([
                "Set location to Always and keep Live Activities on, so it can follow you with the phone locked.",
                "Turn the volume up or wear earbuds. The alarm also rings in silent mode.",
                "Keep some battery: GPS uses a bit on long rides. Low Power Mode is fine.",
                "Run the test alarm once, in Settings.",
            ], id: \.self) { t in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Paper.ok).padding(.top, 2)
                    Text(t).font(HWFont.body(12)).foregroundStyle(Paper.ink.opacity(0.85))
                }
            }
        }
        .padding(.vertical, 8)
    }
}


/// Be there by a time: when to leave, how much time you have to spare, the trip as a metro line, the other ways that
/// also get you there in time (leaving earlier), and the alarm for it.
struct ArrivePass: View {
    @EnvironmentObject var planner: Planner
    let edit: () -> Void
    var go: () -> Void = {}
    let wake: (DoorTrip) -> Void
    var body: some View {
        if let a = planner.arrive {
            let dest = a.out ? "BUas" : "Veghel"
            VStack(alignment: .leading, spacing: 10) {
                PaperBand(home: !a.out) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("BE THERE BY · \(a.dayLabel.uppercased())").font(BoardInk.sans(10)).tracking(1.6).opacity(0.85)
                            Text("\(dest) by \(a.time)").font(HWFont.display(24)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        Spacer(minLength: 6)
                        Button(action: edit) {
                            Text("Change").font(BoardInk.sans(12)).foregroundStyle(.white).underline()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, -14).padding(.top, -14)
                if let t = planner.arriveChosen, let T = a.when {
                    let spare = Fmt.mins(T.timeIntervalSince(t.end))
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("LEAVE BY").font(BoardInk.sans(10)).tracking(1.4).foregroundStyle(Paper.muted)
                            Text(Fmt.hhmm(t.start)).font(HWFont.display(32)).foregroundStyle(Paper.ink).monospacedDigit()
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("THERE AT").font(BoardInk.sans(10)).tracking(1.4).foregroundStyle(Paper.muted)
                            Text(Fmt.hhmm(t.end)).font(HWFont.display(24)).foregroundStyle(Paper.ink).monospacedDigit()
                            Text(spare == 0 ? "just in time" : "\(spare) min to spare").font(BoardInk.sans(11.5)).foregroundStyle(spare < 3 ? Paper.late : Paper.ok)
                        }
                    }
                    if planner.arriveOptions.count > 1 {
                        // the best one first; the others leave earlier (more time to spare)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(planner.arriveOptions.enumerated()), id: \.offset) { i, o in
                                    Button { withAnimation(.easeInOut(duration: 0.2)) { planner.arrivePick = i } } label: {
                                        VStack(spacing: 0) {
                                            Text(Fmt.hhmm(o.first.departure)).font(BoardInk.sans(13))
                                            Text(i == 0 ? "best" : "\(Fmt.mins(T.timeIntervalSince(o.end))) spare").font(BoardInk.sans(9.5, .medium)).opacity(0.85)
                                        }
                                        .foregroundStyle(i == planner.arrivePick ? Color.white : Paper.ink)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(i == planner.arrivePick ? Paper.navy : Paper.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Rectangle().fill(Paper.rule).frame(height: 1)
                    TripLine(trip: t, others: planner.arriveOptions.filter { $0.id != t.id }, dest: dest)
                    PlanButtons(go: go, wake: { wake(t) })
                    Text("Leaves the latest and still gets you there in time. A reminder comes ten minutes before you have to leave.")
                        .font(BoardInk.sans(10.5, .regular)).foregroundStyle(Paper.muted).fixedSize(horizontal: false, vertical: true)
                } else if let e = planner.arriveError {
                    Text(e).font(BoardInk.sans(12.5)).foregroundStyle(Paper.late).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) { ProgressView(); Text("Finding the best trip…").font(BoardInk.sans(12.5, .regular)).foregroundStyle(Paper.muted) }
                }
            }
            .padding(14)
            .background(Paper.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.edge, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
