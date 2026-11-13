import SwiftUI

/// Compare how steady the buses (and trains) are right now: how late each is running, how often it's more than three
/// minutes late around this time, how long to leave for a change after it, and its rank through the day (rush hour is
/// when buses run late).
struct SteadySheet: View {
    @EnvironmentObject private var live: LiveStore
    @ObservedObject private var delays = LiveDelays.shared
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var updated: Date?

    struct Line: Hashable { let line: String; let train: Bool }

    /// Your commute's lines, then any seen running now or seen before.
    private var lines: [Line] {
        var out: [String: Bool] = ["306": false, "305": false, "158": false, "1": false, "IC": true, "SPR": true]
        for l in delays.lines { out[l.line] = l.train }
        for l in DelayBook.shared.lines where out[l] == nil { out[l] = Self.isTrain(l) }
        return out.map { Line(line: $0.key, train: $0.value) }
    }

    static func isTrain(_ l: String) -> Bool { ["IC", "SPR", "ICE", "EC", "IR", "ICD", "ES", "THA"].contains(l) }

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { tl in
                let now = tl.date
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header(now)
                        let buses = lines.filter { !$0.train }.sorted { Steady.late(line: $0.line, train: false, at: now) > Steady.late(line: $1.line, train: false, at: now) }
                        let trains = lines.filter { $0.train }.sorted { $0.line < $1.line }
                        group("Buses", sub: "least steady first", buses, now)
                        group("Trains", sub: "they're rarely the problem", trains, now)
                        legend
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
            .background(PaperFill().ignoresSafeArea())
            .navigationTitle("How steady, now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundStyle(Paper.navy) }
                ToolbarItem(placement: .topBarLeading) {
                    if loading { ProgressView().controlSize(.small) }
                    else { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.foregroundStyle(Paper.navy) }
                }
            }
        }
        .preferredColorScheme(.light)                   // ink on paper, the title too
        .task { await load() }
    }

    /// The live times at your places and around you, so "right now" is right now.
    private func load() async {
        loading = true
        var ids = Place.veghel.ids + Place.denBosch.ids + Place.eindhoven.ids + Place.breda.ids
        ids += live.nearStops.map(\.id)
        _ = await Transit.board(stopIds: Array(Set(ids)), from: Date().addingTimeInterval(-10 * 60), n: 30)
        updated = Date()
        loading = false
    }

    private func header(_ now: Date) -> some View {
        let p = Steady.period(now)
        let text: String
        switch p.name {
        case "rush hour": text = "Rush hour: buses run late much more often now. Leave more time to change after one."
        case "busy": text = "Busy: buses run a little late more often than in the middle of the day."
        case "daytime": text = "The quiet middle of the day: buses mostly keep to time."
        case "weekend": text = "Weekend: fewer buses, and mostly on time."
        default: text = "Quiet hours: buses mostly keep to time."
        }
        return PaperBand {
            VStack(alignment: .leading, spacing: 2) {
                Text("RIGHT NOW · \(Fmt.hhmm(now)) · \(p.name.uppercased())").font(BoardInk.sans(10)).tracking(1.4).opacity(0.85)
                Text(text).font(HWFont.display(17)).fixedSize(horizontal: false, vertical: true)
                if let u = updated { Text("Live times from \(Fmt.hhmm(u))").font(BoardInk.sans(10.5, .regular)).opacity(0.75) }
            }
        }
    }

    private func group(_ title: String, sub: String, _ list: [Line], _ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text(title.uppercased()).font(BoardInk.sans(11)).tracking(1.4).foregroundStyle(Paper.ink.opacity(0.7))
                Spacer()
                Text(sub).font(BoardInk.sans(10.5, .regular)).foregroundStyle(Paper.muted)
            }
            .padding(.bottom, 6)
            ForEach(list, id: \.self) { l in row(l.line, train: l.train, now) }
        }
        .paperCard()
    }

    private func row(_ line: String, train: Bool, _ now: Date) -> some View {
        let p = Steady.late(line: line, train: train, at: now)
        let g = Steady.rank(p)
        let running = delays.now(line: line)
        let seen = DelayBook.shared.count(line: line, at: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                LineBullet(line: line, train: train, at: now, height: 28, minWidth: 46, font: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Steady.meaning(g)) · late 3+ min \(Int((p * 100).rounded()))%").font(BoardInk.sans(13.5)).foregroundStyle(Paper.ink)
                    Text(nowText(running)).font(BoardInk.sans(11.5, .regular)).foregroundStyle(running.contains { $0 >= 3 } ? Paper.late : Paper.muted)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Steady.room(line: line, train: train, at: now)) min").font(HWFont.display(18)).foregroundStyle(Paper.navy).monospacedDigit()
                    Text("to change").font(BoardInk.sans(9.5, .regular)).foregroundStyle(Paper.muted)
                }
            }
            day(line, train: train, now)
            if seen >= 3 {
                Text("Seen \(seen) times around this hour on your trips and boards.").font(BoardInk.sans(10, .regular)).foregroundStyle(Paper.muted)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.rule).frame(height: 1) }
    }

    private func nowText(_ d: [Double]) -> String {
        guard !d.isEmpty else { return "No live times for it right now" }
        let avg = d.reduce(0, +) / Double(d.count), worst = d.max() ?? 0
        let n = d.count == 1 ? "1 running" : "\(d.count) running"
        if avg < 1 && worst < 2 { return "Now: on time (\(n))" }
        return "Now: \(Int(avg.rounded())) min late on average, up to \(Int(worst.rounded())) (\(n))"
    }

    /// Its rank hour by hour today, 6 to 23: where the bad times are.
    private func day(_ line: String, train: Bool, _ now: Date) -> some View {
        let c = Calendar.current
        let start = c.startOfDay(for: now)
        let hours = Array(6...23)
        let nowHour = c.component(.hour, from: now)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                ForEach(hours, id: \.self) { h in
                    let t = start.addingTimeInterval(Double(h) * 3600 + 1800)
                    let g = Steady.rank(line: line, train: train, at: t)
                    RoundedRectangle(cornerRadius: 2).fill(RatingStyle.fill(g))
                        .frame(height: 12)
                        .overlay { if h == nowHour { RoundedRectangle(cornerRadius: 2).stroke(Paper.ink, lineWidth: 1.5) } }
                        .overlay { Text(g).font(.system(size: 7.5, weight: .heavy)).foregroundStyle(RatingStyle.ink(g)) }
                }
            }
            HStack {
                ForEach([6, 9, 12, 15, 18, 21], id: \.self) { h in
                    Text("\(h)").font(BoardInk.sans(8.5, .regular)).foregroundStyle(Paper.muted)
                    if h != 21 { Spacer() }
                }
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([("S", "Nearly always on time: more than 3 min late under 10% of the time"),
                     ("A", "Mostly on time: under 25%"),
                     ("B", "Often a few minutes late: under 45%"),
                     ("C", "Late a lot: 45% or more")], id: \.0) { g, t in
                HStack(spacing: 8) {
                    Coin(grade: g, size: 20)
                    Text(t).font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.ink.opacity(0.85))
                }
            }
            Text("“To change” is the time to leave after it so you make the next one 9 times out of 10. Ranks come from the time of day, how the line is running right now, and what the app has seen of it at that hour on your trips and on the boards: the more you use it, the better it knows.")
                .font(BoardInk.sans(10.5, .regular)).foregroundStyle(Paper.muted).fixedSize(horizontal: false, vertical: true)
        }
        .paperCard()
    }
}
