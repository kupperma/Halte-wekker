import SwiftUI

/// The outfit screen: one look and you know what to wear. The grade when you set off (five, from peak summer to a very
/// cold winter) with its layers, a raincoat if it'll rain, and when to drop or add a layer during the day. Until you
/// get there it's the weather where you set off; after that, where you're going.
struct OutfitSheet: View {
    @ObservedObject private var store = OutfitStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let p = store.plan, let s = p.start {
                        headline(p, s)
                        dayNotes(p)
                        strip(p)
                        grades(p)
                        Text("Forecast by Open-Meteo, for \(p.here) until you get there (about \(Fmt.hhmm(p.arrive))) and \(p.there) after. “Feels” counts the wind.")
                            .font(BoardInk.sans(10.5, .regular)).foregroundStyle(Paper.muted).fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 10) {
                            if store.loading { ProgressView() } else { Image(systemName: "cloud.sun").font(.system(size: 22)).foregroundStyle(Paper.navy) }
                            Text(store.loading ? "Getting the forecast…" : "No forecast yet: it needs a connection.").font(BoardInk.sans(14)).foregroundStyle(Paper.ink)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paperCard()
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(Paper.paper.ignoresSafeArea())
            .navigationTitle("Outfit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundStyle(Paper.navy) }
                ToolbarItem(placement: .topBarLeading) {
                    if store.loading { ProgressView().controlSize(.small) }
                    else { Button { Task { await store.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }.foregroundStyle(Paper.navy) }
                }
            }
        }
        .task { await store.refresh() }
    }

    // MARK: what to wear when you set off

    private func headline(_ p: OutfitPlan, _ s: OutfitPlan.Hour) -> some View {
        let l = s.layer
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(p.tomorrow ? "TOMORROW" : "TODAY") · LEAVING \(p.here.uppercased()) \(Fmt.hhmm(p.leave))").font(BoardInk.sans(10)).tracking(1.4).opacity(0.85)
                    Text(l.name).font(HWFont.display(30)).lineLimit(1).minimumScaleFactor(0.6)
                    Text("\(l.layers) layer\(l.layers == 1 ? "" : "s")\(p.raincoat ? " + raincoat" : "")").font(HWFont.display(18)).opacity(0.95)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Image(systemName: s.w.symbol).symbolRenderingMode(.multicolor).font(.system(size: 30))
                    Text("\(Int(s.w.temp.rounded()))°").font(HWFont.display(28)).monospacedDigit()
                    Text("feels \(Int(s.w.feels.rounded()))°").font(BoardInk.sans(11)).opacity(0.85)
                }
            }
            Text(l.wear + (p.raincoat ? ", and your raincoat." : ".")).font(BoardInk.sans(13, .medium)).fixedSize(horizontal: false, vertical: true)
            // the layers, bottom to top, and the raincoat over them
            HStack(spacing: 6) {
                ForEach(Array(l.pieces.enumerated()), id: \.offset) { i, piece in
                    Text(piece).font(BoardInk.sans(11)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.white.opacity(0.12 + Double(i) * 0.08), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 1))
                }
                if p.raincoat {
                    Label("Raincoat", systemImage: "umbrella.fill").font(BoardInk.sans(11)).foregroundStyle(Paper.ink)
                        .padding(.horizontal, 8).padding(.vertical, 5).background(Paper.yellow, in: Capsule())
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(l.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Paper.ink.opacity(0.15), lineWidth: 1))
    }

    // MARK: during the day

    private func dayNotes(_ p: OutfitPlan) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("THROUGH THE DAY").font(BoardInk.sans(11)).tracking(1.4).foregroundStyle(Paper.ink.opacity(0.7))
            ForEach(p.changes, id: \.self) { c in
                let drop = c.to > c.from
                let n = abs(c.to.layers - c.from.layers)
                note(icon: drop ? "arrow.down.circle.fill" : "arrow.up.circle.fill", color: c.to.color,
                     "Around \(Fmt.hhmm(c.at)) in \(c.place): " + (n == 0 ? "it gets \(drop ? "warmer" : "colder")" : drop ? "drop \(n == 1 ? "a layer" : "\(n) layers")" : "add \(n == 1 ? "a layer" : "\(n) layers")")
                     + ". \(c.to.name), feels \(Int(c.feels.rounded()))°.")
            }
            if p.changes.isEmpty, let s = p.start {
                note(icon: "equal.circle.fill", color: s.layer.color, "The same all day: no layers to drop or add.")
            }
            if p.rain.isEmpty {
                note(icon: "sun.max.fill", color: Paper.ok, "No rain expected: leave the raincoat at home.")
            } else {
                ForEach(Array(p.rain.enumerated()), id: \.offset) { _, r in
                    let afterArrival = r.from >= p.arrive
                    note(icon: "cloud.rain.fill", color: Color(hex: 0x3B6FB6),
                         "Rain in \(r.place) \(Fmt.hhmm(r.from))–\(Fmt.hhmm(r.to))\(r.chance > 0 ? " (\(r.chance)%)" : "")" + (afterArrival ? ": raincoat for later." : ": raincoat on the way."))
                }
            }
            if let c = p.coldest, let w = p.warmest, w.w.feels - c.w.feels >= 3 {
                Text("Coldest: feels \(Int(c.w.feels.rounded()))° at \(Fmt.hhmm(c.w.time)) in \(c.there ? p.there : p.here) · warmest: \(Int(w.w.feels.rounded()))° at \(Fmt.hhmm(w.w.time)) in \(w.there ? p.there : p.here)")
                    .font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private func note(icon: String, color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(color).frame(width: 20)
            Text(text).font(BoardInk.sans(13, .medium)).foregroundStyle(Paper.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: hour by hour

    private func strip(_ p: OutfitPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("HOUR BY HOUR").font(BoardInk.sans(11)).tracking(1.4).foregroundStyle(Paper.ink.opacity(0.7))
                Spacer()
                Text("\(p.here) → \(p.there) from \(Fmt.hhmm(p.arrive))").font(BoardInk.sans(10.5, .regular)).foregroundStyle(Paper.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(p.hours.enumerated()), id: \.offset) { i, h in
                        if i > 0, h.there && !p.hours[i - 1].there {
                            VStack(spacing: 2) {
                                Rectangle().fill(Paper.navy).frame(width: 2)
                                Text(p.there).font(BoardInk.sans(8.5)).foregroundStyle(Paper.navy).fixedSize().rotationEffect(.degrees(-90)).frame(width: 12, height: 40)
                            }
                            .frame(height: 118)
                            .padding(.horizontal, 3)
                        }
                        hourColumn(h)
                    }
                }
            }
        }
        .paperCard()
    }

    private func hourColumn(_ h: OutfitPlan.Hour) -> some View {
        VStack(spacing: 4) {
            Text(Fmt.hhmm(h.w.time).prefix(2)).font(BoardInk.sans(11)).foregroundStyle(Paper.ink.opacity(0.75))
            Image(systemName: h.w.symbol).symbolRenderingMode(.multicolor).font(.system(size: 17)).frame(height: 20)
            Text("\(Int(h.w.temp.rounded()))°").font(BoardInk.sans(14)).foregroundStyle(Paper.ink).monospacedDigit()
            Text("\(Int(h.w.feels.rounded()))°").font(BoardInk.sans(10, .regular)).foregroundStyle(Paper.muted).monospacedDigit()
            Text(h.w.wet ? (h.w.rainChance > 0 ? "\(h.w.rainChance)%" : "rain") : " ").font(BoardInk.sans(10)).foregroundStyle(Color(hex: 0x3B6FB6))
            RoundedRectangle(cornerRadius: 2).fill(h.layer.color).frame(height: 8)
        }
        .frame(width: 40)
        .padding(.vertical, 2)
    }

    // MARK: the five

    private func grades(_ p: OutfitPlan) -> some View {
        let today = Set(p.hours.map(\.layer))
        return VStack(alignment: .leading, spacing: 8) {
            Text("THE FIVE").font(BoardInk.sans(11)).tracking(1.4).foregroundStyle(Paper.ink.opacity(0.7))
            ForEach(Layer.allCases.reversed(), id: \.self) { l in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: l.icon).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(l.color, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(l.name) · \(l.layers) layer\(l.layers == 1 ? "" : "s")").font(BoardInk.sans(13, today.contains(l) ? .bold : .medium)).foregroundStyle(Paper.ink)
                        Text("\(l.range): \(l.wear.prefix(1).lowercased() + l.wear.dropFirst())").font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if today.contains(l) { Text("today").font(BoardInk.sans(10)).foregroundStyle(l.color) }
                }
                .opacity(today.contains(l) ? 1 : 0.6)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "umbrella.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(Paper.ink)
                    .frame(width: 28, height: 28).background(Paper.yellow, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text("+ Raincoat").font(BoardInk.sans(13, p.raincoat ? .bold : .medium)).foregroundStyle(Paper.ink)
                    Text("over any of them, when rain is likely or some is expected while you’re out").font(BoardInk.sans(11, .regular)).foregroundStyle(Paper.muted)
                }
            }
            .opacity(p.raincoat ? 1 : 0.6)
        }
        .paperCard()
    }
}

/// On the home map, next to the bell: the temperature and what to wear, at a glance. Tap for the outfit screen.
struct OutfitTag: View {
    @ObservedObject private var store = OutfitStore.shared
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                if let p = store.plan, let s = p.start {
                    Image(systemName: s.w.symbol).symbolRenderingMode(.multicolor).font(.system(size: 13))
                    Text("\(Int(s.w.temp.rounded()))°").font(.system(size: 13, weight: .heavy)).monospacedDigit()
                    Text("· \(s.layer.layers) layer\(s.layer.layers == 1 ? "" : "s")").font(.system(size: 12, weight: .semibold))
                    if p.raincoat { Image(systemName: "umbrella.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(hex: 0x3B6FB6)) }
                } else {
                    Image(systemName: "tshirt.fill").font(.system(size: 13, weight: .semibold))
                    Text("Outfit").font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 11).frame(height: 34)
            .background(Paper.paper, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.plan?.start.map { "Outfit: \($0.layer.name), \($0.layer.layers) layers\(store.plan?.raincoat == true ? ", raincoat" : "")" } ?? "Outfit")
    }
}

/// One line for the morning screen: what to wear today.
struct OutfitLine: View {
    @ObservedObject private var store = OutfitStore.shared
    var body: some View {
        if let p = store.plan, let s = p.start {
            HStack(spacing: 8) {
                Image(systemName: s.layer.icon).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(s.layer.color, in: RoundedRectangle(cornerRadius: 5))
                Text("Wear: \(s.layer.name.lowercased()), \(s.layer.layers) layer\(s.layer.layers == 1 ? "" : "s")\(p.raincoat ? " + raincoat" : "")"
                     + (p.changes.first.map { " · \($0.to > $0.from ? "drop" : "add") one around \(Fmt.hhmm($0.at))" } ?? ""))
                    .font(BoardInk.sans(12)).foregroundStyle(Paper.ink).lineLimit(2).minimumScaleFactor(0.8)
            }
        }
    }
}
