import SwiftUI

/// "How steady are they now?" in the new look (0.21), from Settings and Fastest trip. The same as `SteadySheet` (the
/// old look keeps it): how late each line is running, how often it's more than three minutes late around this time,
/// how long to leave for a change after it, and its rank through the day; in the phone's light or dark.
struct SteadySheetNew: View {
    @EnvironmentObject private var live: LiveStore
    @ObservedObject private var delays = LiveDelays.shared
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var updated: Date?

    private typealias Line = SteadySheet.Line

    /// Your commute's lines, then any seen running now or seen before (as `SteadySheet`).
    private var lines: [Line] {
        var out: [String: Bool] = ["306": false, "305": false, "158": false, "1": false, "IC": true, "SPR": true]
        for l in delays.lines { out[l.line] = l.train }
        for l in DelayBook.shared.lines where out[l] == nil { out[l] = SteadySheet.isTrain(l) }
        return out.map { Line(line: $0.key, train: $0.value) }
    }

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { tl in
                let now = tl.date
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.s12) {
                        header(now)
                        let buses = lines.filter { !$0.train }.sorted { Steady.late(line: $0.line, train: false, at: now) > Steady.late(line: $1.line, train: false, at: now) }
                        let trains = lines.filter { $0.train }.sorted { $0.line < $1.line }
                        group("Buses", sub: "least steady first", buses, now)
                        group("Trains", sub: "they’re rarely the problem", trains, now)
                        legend
                    }
                    .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
                }
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("How steady, now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    if loading { ProgressView().controlSize(.small) }
                    else {
                        Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh the live times")
                    }
                }
            }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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

    // MARK: right now

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
        return VStack(alignment: .leading, spacing: DS.s8) {
            Text("Right now · \(Fmt.hhmm(now)) · \(p.name.capitalizedFirst)")
                .font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.accentText)
            Text(text).font(DS.headline).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let u = updated {
                Text("Live times from \(Fmt.hhmm(u))").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    // MARK: the lines

    private func group(_ title: String, sub: String, _ list: [Line], _ now: Date) -> some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            DSHeader(title: title, sub: sub)
            ForEach(Array(list.enumerated()), id: \.element) { i, l in
                if i > 0 { Divider().overlay(DS.divider) }
                row(l.line, train: l.train, now)
            }
        }
        .dsPanel()
    }

    private func row(_ line: String, train: Bool, _ now: Date) -> some View {
        let p = Steady.late(line: line, train: train, at: now)
        let g = Steady.rank(p)
        let running = delays.now(line: line)
        let seen = DelayBook.shared.count(line: line, at: now)
        let room = Steady.room(line: line, train: train, at: now)
        let lateNow = running.contains { $0 >= 3 }
        return VStack(alignment: .leading, spacing: DS.s8) {
            HStack(alignment: .center, spacing: DS.s12) {
                DSLinePill(line: line, train: train).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Steady.meaning(g)) · late 3+ min \(Int((p * 100).rounded()))%")
                        .font(DS.calloutStrong).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    Text(nowText(running)).font(DS.footnote).monospacedDigit()
                        .foregroundStyle(lateNow ? DS.warning : DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(room) min").font(DS.bigNumber).monospacedDigit().foregroundStyle(DS.text).lineLimit(1)
                    Text("to change").font(DS.footnote).foregroundStyle(DS.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(train ? "Train" : "Line") \(line): \(g)-rank, \(Steady.meaning(g)). More than 3 minutes late \(Int((p * 100).rounded())) percent of the time. \(nowText(running)). Leave \(room) minutes to change after it.")
            day(line, train: train, now)
            if seen >= 3 {
                Text("Seen \(seen) times around this hour on your trips and boards.")
                    .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
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
        let ranks = hours.map { h in Steady.rank(line: line, train: train, at: start.addingTimeInterval(Double(h) * 3600 + 1800)) }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                ForEach(Array(hours.enumerated()), id: \.element) { i, h in
                    let g = ranks[i]
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(RatingStyle.fill(g))
                        .frame(height: 14)
                        .overlay { if h == nowHour { RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(DS.text, lineWidth: 1.5) } }
                        .overlay { Text(g).font(.system(size: 8, weight: .heavy)).foregroundStyle(RatingStyle.ink(g)) }
                }
            }
            HStack {
                ForEach([6, 9, 12, 15, 18, 21], id: \.self) { h in
                    Text("\(h)").font(.caption2).monospacedDigit().foregroundStyle(DS.secondary)
                    if h != 21 { Spacer() }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Through the day: " + zip(hours, ranks).map { "\($0):00 \($1)" }.joined(separator: ", "))
    }

    // MARK: what the ranks mean

    private var legend: some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            DSHeader(title: "What the ranks mean")
            ForEach([("S", "Nearly always on time: more than 3 min late under 10% of the time"),
                     ("A", "Mostly on time: under 25%"),
                     ("B", "Often a few minutes late: under 45%"),
                     ("C", "Late a lot: 45% or more")], id: \.0) { g, t in
                HStack(spacing: DS.s12) {
                    DSGrade(grade: g, size: 26)
                    Text(t).font(DS.sub).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Text("“To change” is the time to leave after it so you make the next one 9 times out of 10. Ranks come from the time of day, how the line is running right now, and what the app has seen of it at that hour on your trips and on the boards: the more you use it, the better it knows.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .dsPanel()
    }
}
