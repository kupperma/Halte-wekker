import SwiftUI
import UIKit

/// The outfit sheet in the new look (0.20.9), from the weather chip on the home map and the morning card. The same
/// plan as `OutfitSheet` (OutfitStore, Open-Meteo), in the phone's light or dark: the temperature big with one line of
/// what to wear, the layers as chips, when to drop or add one during the day, the day hour by hour, and where the
/// forecast is for. The words are `OutfitWords`.
struct OutfitSheetNew: View {
    @ObservedObject private var store = OutfitStore.shared
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var big: CGFloat = 64
    @ScaledMetric(relativeTo: .largeTitle) private var sky: CGFloat = 46
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 48
    @ScaledMetric(relativeTo: .subheadline) private var dot: CGFloat = 28
    @ScaledMetric(relativeTo: .footnote) private var hourWidth: CGFloat = 48

    /// Rain, as text or an icon (5.3:1 on the light card, 8:1 on the dark one).
    static let rainBlue = DS.dynamic(0x2F6DB5, 0x82B4F0)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s12) {
                    if let p = store.plan, let s = p.start {
                        top(p, s)
                        outfit(p, s)
                        day(p, s)
                        hourly(p, s)
                        whereCard(p)
                        Text("Forecast by Open-Meteo. “Feels” counts the wind.")
                            .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, DS.s4)
                    } else {
                        status
                    }
                }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("What to wear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    if store.loading { ProgressView().controlSize(.small) }
                    else {
                        Button { Task { await store.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh the forecast")
                    }
                }
            }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .task { await store.refresh() }
    }

    // MARK: the top: the temperature and one line

    /// The rain in a few words ("rain from 16:00"), from the hour you set off to the end of the day.
    private func rainWords(_ p: OutfitPlan, _ s: OutfitPlan.Hour) -> String? {
        let end = (p.hours.last?.w.time ?? s.w.time).addingTimeInterval(3600)
        return OutfitWords.rain(p.rain.map { OutfitWords.Rain(from: $0.from, to: $0.to, chance: $0.chance) },
                                start: s.w.time, end: end, clock: Fmt.hhmm)
    }

    private func top(_ p: OutfitPlan, _ s: OutfitPlan.Hour) -> some View {
        let t = Int(s.w.temp.rounded()), f = Int(s.w.feels.rounded())
        let rain = rainWords(p, s)
        let from = p.here == "where you are" ? "" : p.here + " "
        return VStack(alignment: .leading, spacing: DS.s8) {
            Text((p.tomorrow ? "Tomorrow" : "Today") + " · leaving \(from)at \(Fmt.hhmm(p.leave))")
                .font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DS.s4) {
                HStack(alignment: .center, spacing: DS.s12) {
                    Text("\(t)°").font(DS.hero(min(big, 96))).monospacedDigit().foregroundStyle(DS.text)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Image(systemName: s.w.symbol).symbolRenderingMode(.multicolor).font(.system(size: min(sky, 70)))
                    Spacer(minLength: 0)
                }
                Text("Feels \(f)°").font(DS.subStrong).monospacedDigit().foregroundStyle(DS.secondary)
                Text(OutfitWords.line(grade: s.layer.rawValue, raincoat: p.raincoat, rain: rain))
                    .font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.s4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OutfitWords.spoken(temp: t, feels: f, grade: s.layer.rawValue, raincoat: p.raincoat, rain: rain))
            .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    // MARK: the outfit, as chips

    private func outfit(_ p: OutfitPlan, _ s: OutfitPlan.Hour) -> some View {
        let l = s.layer
        return VStack(alignment: .leading, spacing: DS.s12) {
            HStack(spacing: DS.s8) {
                Image(systemName: l.icon).font(.footnote.weight(.bold)).foregroundStyle(.white)
                    .frame(width: dot, height: dot)
                    .background(l.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text(l.name).font(DS.headline).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text("\(l.layers) layer\(l.layers == 1 ? "" : "s")\(p.raincoat ? " + raincoat" : "")")
                    .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            ChipFlow(spacing: DS.s8) {
                ForEach(Array(OutfitWords.chips(pieces: l.pieces, raincoat: p.raincoat).enumerated()), id: \.offset) { _, c in
                    chip(c)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func chip(_ c: OutfitWords.Chip) -> some View {
        let drawn = c.symbols.first == OutfitWords.sweaterGlyph
        let symbol = c.symbols.first { UIImage(systemName: $0) != nil }
        return HStack(spacing: 6) {
            if drawn {
                SweaterGlyph().fill(c.rain ? Self.rainBlue : DS.accentText)
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)
            } else if let symbol {
                Image(systemName: symbol).font(.subheadline.weight(.semibold))
                    .foregroundStyle(c.rain ? Self.rainBlue : DS.accentText)
                    .accessibilityHidden(true)
            }
            Text(c.label).font(DS.subStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 36)
        .background(c.rain ? Self.rainBlue.opacity(0.14) : DS.surface3, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: during the day

    private struct Moment {
        let time: String
        let icon: String
        let tint: Color
        let title: String
        let detail: String
        let at: Date?
    }

    private func moments(_ p: OutfitPlan) -> [Moment] {
        var all: [Moment] = []
        if p.changes.isEmpty {
            all.append(Moment(time: "All day", icon: "equal", tint: DS.secondary, title: "No layers to drop or add",
                              detail: "The same all day", at: nil))
        }
        if p.rain.isEmpty {
            all.append(Moment(time: "All day", icon: "sun.max.fill", tint: DS.accentText, title: "No rain expected",
                              detail: "Leave the raincoat at home", at: nil))
        }
        var timed: [Moment] = p.changes.map { c in
            let warmer = c.to > c.from
            return Moment(time: Fmt.hhmm(c.at), icon: warmer ? "arrow.down" : "arrow.up", tint: DS.accentText,
                          title: OutfitWords.change(fromLayers: c.from.layers, toLayers: c.to.layers, warmer: warmer),
                          detail: OutfitWords.changeDetail(place: c.place, gradeName: c.to.name, feels: Int(c.feels.rounded())), at: c.at)
        }
        timed += p.rain.map { r in
            Moment(time: Fmt.hhmm(r.from), icon: "umbrella.fill", tint: Self.rainBlue,
                   title: OutfitWords.rainTitle(to: r.to, chance: r.chance, clock: Fmt.hhmm),
                   detail: OutfitWords.rainDetail(place: r.place, afterArrival: r.from >= p.arrive), at: r.from)
        }
        return all + timed.sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
    }

    private func day(_ p: OutfitPlan, _ s: OutfitPlan.Hour) -> some View {
        let items = moments(p)
        return VStack(alignment: .leading, spacing: DS.s12) {
            DSHeader(title: "During the day")
            VStack(alignment: .leading, spacing: DS.s12) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, m in
                    moment(m, last: i == items.count - 1)
                }
            }
            if let c = p.coldest, let w = p.warmest, w.w.feels - c.w.feels >= 3 {
                Text("Coldest: feels \(Int(c.w.feels.rounded()))° at \(Fmt.hhmm(c.w.time)) in \(c.there ? p.there : p.here) · warmest: \(Int(w.w.feels.rounded()))° at \(Fmt.hhmm(w.w.time)) in \(w.there ? p.there : p.here)")
                    .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    /// One moment of the day: its time, a dot on the line, what happens.
    private func moment(_ m: Moment, last: Bool) -> some View {
        HStack(alignment: .top, spacing: DS.s12) {
            Text(m.time).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(m.at == nil ? DS.secondary : DS.text)
                .lineLimit(2).minimumScaleFactor(0.8)
                .frame(width: timeWidth, alignment: .leading)
                .padding(.top, 5)
            Image(systemName: m.icon).font(.footnote.weight(.bold)).foregroundStyle(m.tint)
                .frame(width: dot, height: dot)
                .background(DS.surface3, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(DS.subStrong).monospacedDigit().foregroundStyle(DS.text)
                Text(m.detail).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        // the line down to the next moment, under the dots
        .background(alignment: .topLeading) {
            if !last {
                Rectangle().fill(DS.divider).frame(width: 2)
                    .padding(.top, dot).padding(.bottom, -DS.s12)
                    .padding(.leading, timeWidth + DS.s12 + dot / 2 - 1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: hour by hour

    private func hourly(_ p: OutfitPlan, _ s: OutfitPlan.Hour) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Hour by hour")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DS.s4) {
                    ForEach(Array(p.hours.enumerated()), id: \.offset) { i, h in
                        hourCell(h, now: h == s, arriving: i > 0 && h.there && !p.hours[i - 1].there ? p.there : nil)
                    }
                }
                .padding(.vertical, 2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    /// An hour: its time, the sky, the temperature and the chance of rain. `now`: the hour you set off;
    /// `arriving`: the first hour at the place you're going (its name over it).
    private func hourCell(_ h: OutfitPlan.Hour, now: Bool, arriving: String?) -> some View {
        let t = Int(h.w.temp.rounded())
        let time = Fmt.hhmm(h.w.time)
        return VStack(spacing: DS.s4) {
            Text(arriving ?? " ").font(DS.caption).foregroundStyle(DS.accentText)
                .lineLimit(1).fixedSize()
                .frame(width: hourWidth, alignment: .leading)
            Text(time.prefix(2)).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(now ? DS.accentSoftText : DS.secondary)
            Image(systemName: h.w.symbol).symbolRenderingMode(.multicolor).font(.title3)
                .frame(minHeight: 28)
            Text("\(t)°").font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
            Text(h.w.wet ? (h.w.rainChance > 0 ? "\(h.w.rainChance)%" : "rain") : " ")
                .font(DS.caption).monospacedDigit().foregroundStyle(Self.rainBlue)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: hourWidth)
        .padding(.vertical, DS.s8)
        .background(now ? DS.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            if arriving != nil { Capsule().fill(DS.accent).frame(width: 2).padding(.vertical, DS.s8).offset(x: -3) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((arriving.map { "In \($0) from here on. " } ?? "")
            + OutfitWords.hourSpoken(time: time, code: h.w.code, temp: t, feels: Int(h.w.feels.rounded()), wet: h.w.wet, chance: h.w.rainChance))
        .accessibilityAddTraits(now ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    // MARK: where it applies

    private func whereCard(_ p: OutfitPlan) -> some View {
        HStack(alignment: .top, spacing: DS.s12) {
            Image(systemName: "mappin.and.ellipse").font(.body.weight(.semibold)).foregroundStyle(DS.accentText)
                .accessibilityHidden(true)
            Text(OutfitWords.whereLine(here: p.here, there: p.there, arrive: p.arrive,
                                       hereHours: p.hours.contains { !$0.there }, thereHours: p.hours.contains { $0.there },
                                       clock: Fmt.hhmm))
                .font(DS.sub).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: loading and not got

    private var status: some View {
        let waiting = store.loading || !store.tried
        return VStack(alignment: .leading, spacing: DS.s12) {
            HStack(alignment: .top, spacing: DS.s12) {
                if waiting { ProgressView() }
                else { Image(systemName: "cloud.sun").font(.title3).foregroundStyle(DS.secondary).accessibilityHidden(true) }
                Text(waiting ? "Getting the forecast…" : "Couldn’t get the forecast just now. Tap ↻ to try again.")
                    .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if waiting {
                ForEach(0..<3, id: \.self) { _ in DSSkeletonRow() }
            } else {
                DSQuietButton(title: "Try again", icon: "arrow.clockwise") { Task { await store.refresh(force: true) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}

/// Chips in rows: as many as fit on a line, then the next line (Dynamic Type's big sizes wrap them).
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let rows = arrange(subviews, width: width ?? .infinity)
        let w = rows.flatMap { $0 }.map { $0.frame.maxX }.max() ?? 0
        let h = rows.last?.map { $0.frame.maxY }.max() ?? 0
        return CGSize(width: width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                                           proposal: ProposedViewSize(width: item.frame.width, height: item.frame.height))
            }
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, frame: CGRect)]] {
        var rows: [[(index: Int, frame: CGRect)]] = [[]]
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for i in subviews.indices {
            var size = subviews[i].sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if width.isFinite { size.width = min(size.width, width) }
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
                rows.append([])
            }
            rows[rows.count - 1].append((index: i, frame: CGRect(x: x, y: y, width: size.width, height: size.height)))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return rows
    }
}


/// A long-sleeved sweater, drawn like an SF Symbol (there is none): body, neckline, sleeves and a ribbed hem (0.37.2).
struct SweaterGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 24, ox = r.minX + (r.width - 24 * s) / 2, oy = r.minY + (r.height - 24 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var path = Path()
        path.move(to: p(8.6, 2.5))
        path.addQuadCurve(to: p(15.4, 2.5), control: p(12, 6.2))
        path.addLine(to: p(19.6, 4.2))
        path.addQuadCurve(to: p(21.4, 6.4), control: p(20.9, 4.9))
        path.addLine(to: p(23.4, 16.6))
        path.addLine(to: p(20.2, 17.4))
        path.addLine(to: p(18.4, 10.2))
        path.addLine(to: p(18.4, 19.6))
        path.addLine(to: p(5.6, 19.6))
        path.addLine(to: p(5.6, 10.2))
        path.addLine(to: p(3.8, 17.4))
        path.addLine(to: p(0.6, 16.6))
        path.addLine(to: p(2.6, 6.4))
        path.addQuadCurve(to: p(4.4, 4.2), control: p(3.1, 4.9))
        path.closeSubpath()
        // the ribbed hem and cuffs
        path.addRoundedRect(in: CGRect(origin: p(5.6, 20.3), size: CGSize(width: 12.8 * s, height: 2.2 * s)), cornerSize: CGSize(width: 0.8 * s, height: 0.8 * s))
        return path
    }
}
