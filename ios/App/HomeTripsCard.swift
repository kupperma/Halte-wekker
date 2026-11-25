import SwiftUI

/// Off the corridor (0.24), the home's cards end with your next door-to-door trips between Home and School (the live
/// store's `next`, up to four), instead of the corridor's lists of trains and campus buses: when each leaves and gets
/// there, its lines, the changes and, for a train, its platform. A tap opens Fastest trip.
struct HomeTripsCard: View {
    let trips: [DoorTrip]
    /// "Next to Fontys", "Next home".
    let title: String
    let loading: Bool
    let asOf: Date?
    let note: String?
    let open: () -> Void
    @EnvironmentObject var ns: NSStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            HStack(alignment: .firstTextBaseline, spacing: DS.s8) {
                Text(title).font(DS.headline).foregroundStyle(DS.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if let asOf {
                    Text("as of \(Fmt.hhmm(asOf))").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                }
            }
            if trips.isEmpty {
                if loading {
                    DSSkeletonRow(); DSSkeletonRow()
                } else {
                    Text(note ?? "No trips found right now. It tries again in a minute.").font(DS.sub).foregroundStyle(DS.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(trips.prefix(4).enumerated()), id: \.element.id) { i, t in
                if i > 0 { Divider().overlay(DS.divider) }
                row(t)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func row(_ t: DoorTrip) -> some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: DS.s12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Fmt.hhmm(t.start)) → \(Fmt.hhmm(t.end))").font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                    HStack(spacing: 4) {
                        ForEach(Array(t.rides.prefix(4).enumerated()), id: \.offset) { _, r in
                            DSLinePill(line: r.line, train: r.isTrain)
                        }
                    }
                    Text(detail(t)).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: DS.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(t))
        .accessibilityHint("Opens Fastest trip")
    }

    /// "Leave 08:04 · 1 change at Eindhoven Centraal · platform 4"
    private func detail(_ t: DoorTrip) -> String {
        var parts = ["Leave \(Fmt.hhmm(t.start))"]
        let ch = t.changes
        if !ch.isEmpty { parts.append("\(ch.count) change\(ch.count == 1 ? "" : "s") at \(ch.joined(separator: ", "))") }
        if let r = t.rides.first(where: \.isTrain), let p = ns.rail(r)?.track ?? r.platform, !p.isEmpty {
            parts.append("\(r.id != t.first.id ? "train from " : "")platform \(p)")
        }
        if t.first.cancelled { parts.append("cancelled") }
        // (0.40) no live data close to leaving, on a line that has it
        else if LiveStore.mayNotRun(t, among: trips) { parts.append(GhostDepartures.unsureShort) }
        return parts.joined(separator: " · ")
    }

    private func spoken(_ t: DoorTrip) -> String {
        let lines = t.rides.map { $0.isTrain ? "train \($0.line)" : "line \($0.line)" }.joined(separator: ", then ")
        return "Leave \(Fmt.hhmm(t.start)), there \(Fmt.hhmm(t.end)). \(lines). \(detail(t).components(separatedBy: " · ").dropFirst().joined(separator: ", "))"
    }
}
