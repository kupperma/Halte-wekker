import SwiftUI
import UIKit

/// Settings › Battery & data (0.20.7): what the app itself cost today (GPS, network, CPU, time behind the screen), the
/// mobile data of today and this week, and the last rides. From the app's own counts (`BatteryLog`): iOS gives an app
/// no energy figure of its own. No places, no coordinates.
struct BatteryDataScreen: View {
    @State private var saved = BatteryLog.shared.snapshot()
    @State private var now = Date()
    @State private var copied = false
    @State private var confirmClear = false

    private var log: BatteryLog { .shared }
    private var todayKey: String { log.dayKey(now) }
    private var today: BatteryDay { saved.days.last { $0.day == todayKey } ?? BatteryDay(day: todayKey) }
    private var mobile: (today: Int, week: Int, measured: Bool) {
        BatteryReport.mobile(saved.days, today: now, calendar: .current, key: { log.dayKey($0) })
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DS.s4) {
                    Text(batteryLine).font(DS.headline).foregroundStyle(DS.text)
                    Text("On screen \(BatteryReport.duration(today.foreground)) · behind the screen \(BatteryReport.duration(today.background))")
                        .font(DS.sub).foregroundStyle(DS.secondary)
                }
                .padding(.vertical, DS.s4)
                .accessibilityElement(children: .combine)
            }
            Section {
                ForEach(Array(BatteryReport.bars(today).enumerated()), id: \.offset) { _, b in BarRow(bar: b) }
            } header: { Text("Today") } footer: {
                Text("Each bar against today’s biggest, by rough weights (a minute of the best GPS counts 1, a radio wake 0.15, a CPU minute 1, a minute behind the screen 0.05). The battery drop is what really happened.")
            }
            Section {
                row("Today", BatteryReport.mb(mobile.today))
                row("This week", BatteryReport.mb(mobile.week))
                row("All data today, Wi‑Fi too", BatteryReport.mb(today.bytes))
            } header: { Text("Mobile data") } footer: {
                Text(mobile.measured || today.requests == 0
                     ? "The bytes really sent and received over the mobile network, headers included."
                     : "Not measured yet: the sizes of what came back are shown instead.")
            }
            let kinds = BatteryReport.kinds(today)
            if !kinds.isEmpty {
                Section("What it asked for today") {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { _, k in
                        row(k.kind.label.prefix(1).uppercased() + k.kind.label.dropFirst(), "\(BatteryReport.mb(k.bytes)) · \(k.requests)×")
                    }
                }
            }
            Section {
                if let r = saved.ride {
                    Text("A ride on now, since \(Fmt.hhmm(r.start))").font(DS.sub).foregroundStyle(DS.secondary)
                }
                if saved.rides.isEmpty {
                    Text("No rides yet.").font(DS.sub).foregroundStyle(DS.secondary)
                }
                ForEach(Array(saved.rides.reversed().prefix(12).enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(BatteryReport.rideLine(r)).font(DS.footnote).foregroundStyle(DS.text).monospacedDigit()
                        // (0.42.9) the best GPS against the rough tiers of long rides and waits at a change
                        if let split = BatteryReport.gpsSplit(r) {
                            Text(split).font(DS.footnote).foregroundStyle(DS.secondary).monospacedDigit()
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: { Text("Last rides") } footer: {
                Text("Reduced: the rough GPS of a long ride far from the stop with the vehicle confirmed, and of a wait at a change. The best comes back near the stop, on any doubt, and before the alarm.")
            }
            Section {
                Button(copied ? "Copied: paste it in the chat" : "Copy as text") {
                    BatteryLog.shared.flush()
                    UIPasteboard.general.string = BatteryReport.text(BatteryLog.shared.snapshot(), today: Date(), calendar: .current,
                                                                     key: { BatteryLog.shared.dayKey($0) })
                    copied = true
                }
                Button("Clear", role: .destructive) { confirmClear = true }
            } footer: {
                Text("Counted by the app itself, kept on this phone for 14 days and the last 30 rides: kinds, counts, sizes and times only, no places or coordinates.")
            }
        }
        .navigationTitle("Battery & data")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { reload() }
        .confirmationDialog("Clear the battery and data log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                BatteryLog.shared.clear(); BatteryLog.shared.flush(); reload()
            }
        }
    }

    private var batteryLine: String {
        let d = today
        guard d.unplugged >= 60 else { return "Battery: not enough time unplugged yet today" }
        let drop = Int(d.drop.rounded())
        return "Battery −\(drop)% while unplugged" + (BatteryReport.perHour(d).map { " · \($0)" } ?? "")
    }

    private func reload() {
        BatteryMeter.sampleBattery()
        now = Date()
        saved = BatteryLog.shared.snapshot(at: now)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(DS.body).foregroundStyle(DS.text)
            Spacer()
            Text(value).font(DS.bodyStrong).foregroundStyle(DS.text).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// One of today's bars: what, how much, a bar against the day's biggest, and the detail under it.
private struct BarRow: View {
    let bar: BatteryReport.Bar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(bar.title).font(DS.bodyStrong).foregroundStyle(DS.text)
                Spacer()
                Text(bar.value).font(DS.bodyStrong).foregroundStyle(DS.text).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.surface3)
                    Capsule().fill(DS.accent).frame(width: max(bar.fraction > 0 ? 6 : 0, g.size.width * bar.fraction))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            Text(bar.detail).font(DS.footnote).foregroundStyle(DS.secondary)
        }
        .padding(.vertical, DS.s4)
        .accessibilityElement(children: .combine)
    }
}
