import PhotosUI
import SwiftUI

// The detail pages, the platform alert and the morning screen in the new look (0.20, phase 2): the same content as
// TrainPage / BusPage (SteadyBlock, RankBlock, the train's make-up, how busy, your ride), PlatformAlertView and
// MorningView, in the new tokens.

// MARK: a line's page: how steady, its speed rank, the train

/// How steady a line is at that time of day: its rank, what it means, and why (as `SteadyBlock`).
struct DSSteadyInfo: View {
    let line: String
    let train: Bool
    let stop: String?
    let at: Date
    @ObservedObject private var live = LiveDelays.shared
    var body: some View {
        let g = Steady.rank(line: line, train: train, stop: stop, at: at)
        let p = Steady.late(line: line, train: train, stop: stop, at: at)
        let period = Steady.period(at).name
        let seen = DelayBook.shared.count(line: line, at: at)
        let now = abs(at.timeIntervalSinceNow) < 3600 ? live.now(line: LiveDelays.name(line, train: train)) : []
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "How steady", sub: "around \(Fmt.hhmm(at)) · \(period)")
            HStack(alignment: .top, spacing: DS.s12) {
                DSGrade(grade: g, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(g)-rank · \(Steady.meaning(g))").font(DS.bodyStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    Text("More than 3 min late about \(Int((p * 100).rounded()))% of the time around now. For a change after it, leave \(Steady.room(line: line, train: train, stop: stop, at: at)) min to be safe.")
                        .font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(why(seen: seen, now: now, period: period)).font(DS.sub).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
    private func why(seen: Int, now: [Double], period: String) -> String {
        var parts: [String] = []
        if now.count >= 2 {
            let avg = now.reduce(0, +) / Double(now.count)
            parts.append(avg >= 1 ? "Right now they're running \(Int(avg.rounded())) min late on average (\(now.count) seen)." : "Right now they're on time (\(now.count) seen).")
        }
        if seen >= 3 { parts.append("Seen \(seen) times around this hour.") }
        else { parts.append(train ? "Trains are rarely more than a couple of minutes late." : period == "rush hour" ? "Rush hour: buses run late much more often." : "From the time of day, until it has seen this line more.") }
        return parts.joined(separator: " ")
    }
}

/// A ride's speed rank: the rank, what it means, and the numbers behind it (as `RankBlock`).
struct DSRankInfo: View {
    let rank: RankInfo
    var cancelled = false
    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Speed rank", sub: rank.stretch)
            HStack(alignment: .top, spacing: DS.s12) {
                DSGrade(grade: rank.grade, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(DS.bodyStrong).foregroundStyle(DS.text)
                    Text(meaning).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    if let n = numbers { Text(n).font(DS.sub).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var title: String {
        guard let g = rank.grade else { return cancelled ? "No rank: it’s cancelled" : "No rank yet" }
        return "\(g)-rank"
    }
    private var meaning: String {
        switch rank.grade {
        case "S": return "As fast as it gets on this stretch."
        case "A": return "A little slower than the fastest seen here: up to 3 min, or 18% longer."
        case "B": return "Slower than the fastest seen here: up to 30% longer."
        case "C": return "Much slower than the fastest seen here."
        default: return "A rank compares a ride with the fastest one seen on the same stretch."
        }
    }
    private var numbers: String? {
        guard rank.grade != nil, rank.minutes > 0 else { return nil }
        var t = "This ride: \(Fmt.rideText(rank.minutes))"
        if let b = rank.best, b > 0 {
            let e = Int((rank.minutes - b).rounded())
            t += " · the fastest: \(Fmt.rideText(b))" + (e >= 1 ? " (\(e) min slower)" : "")
        }
        return t + ". Delays count, so a late one drops a rank."
    }
}

/// A train: how it's made up (with where 1st class is) and how busy NS expects it (as on `TrainPage`).
struct DSTrainInfo: View {
    let info: RailInfo?
    let nsMissing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            VStack(alignment: .leading, spacing: DS.s8) {
                DSHeader(title: "The train", sub: info?.size.map { "\($0.cars) coaches" })
                if let s = info?.size {
                    Text(s.text).font(DS.sub).monospacedDigit().foregroundStyle(s.warn ? DS.warning : DS.secondary)
                    if let l = s.layout { ConsistView(layout: l, pal: .toBreda, newLook: true) }
                } else {
                    Text(nsMissing ? "Train details need the NS key in your relay (see the GitHub page)." : "NS hasn’t said how this train is made up yet.")
                        .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: DS.s8) {
                DSHeader(title: "How busy", sub: "NS forecast")
                if let c = info?.crowd, c > 0 {
                    DSCrowd(level: c)
                } else {
                    Text("No forecast for this train.").font(DS.sub).foregroundStyle(DS.secondary)
                }
            }
        }
    }
}

// MARK: the platform alert

/// Your train's platform changed, or it was cancelled: big, with one thing to do.
struct PlatformAlertViewNew: View {
    let alert: PlatformAlert
    let ok: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var big: CGFloat = 64
    var body: some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            Spacer()
            Label(alert.cancelled ? "Train cancelled" : "Platform change", systemImage: alert.cancelled ? "xmark.octagon.fill" : "arrow.left.arrow.right")
                .font(DS.headline).foregroundStyle(DS.warning)
            if alert.cancelled {
                Text("Cancelled").font(DS.hero(min(big, 88))).foregroundStyle(DS.text).lineLimit(1).minimumScaleFactor(0.5)
            } else {
                Text("Platform \(alert.now)").font(DS.hero(min(big, 88))).monospacedDigit().foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("was platform \(alert.was)").font(DS.title).monospacedDigit().foregroundStyle(DS.secondary).strikethrough()
            }
            Text(alert.cancelled ? "Your \(alert.label) from \(alert.from) has been cancelled. Check the train list for the next one."
                                 : "Your \(alert.label) now leaves \(alert.from) from platform \(alert.now) instead of \(alert.was).")
                .font(DS.body).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            DSPrimaryButton(title: "OK, got it", icon: "checkmark", action: ok)
        }
        .padding(DS.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(DS.page.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: the morning screen

/// After the school alarm: the time, when to leave and your first class, what to wear, and Go hands-free; over the
/// picture you picked (as `MorningView`).
struct MorningViewNew: View {
    @EnvironmentObject private var trip: TripManager
    @ObservedObject private var morning = Morning.shared
    @ObservedObject private var school = SchoolAlarm.shared
    let go: (SchoolAlarm.Planned) -> Void
    @State private var picking: [PhotosPickerItem] = []
    @State private var showOutfit = false
    @ScaledMetric(relativeTo: .largeTitle) private var clock: CGFloat = 88
    @ScaledMetric(relativeTo: .largeTitle) private var big: CGFloat = 44

    /// Today's (or the next) school day.
    private var day: SchoolAlarm.Planned? {
        school.week.filter { $0.classStart > Date().addingTimeInterval(-3 * 3600) }.min { $0.classStart < $1.classStart }
    }

    var body: some View {
        let look = morning.look()
        let light = look.light
        let text: Color = light ? Color(hex: 0x14171A) : .white
        let shade: Color = light ? .clear : .black.opacity(0.45)
        ZStack {
            backdrop(look)
            // a little darker behind the time and under the card, so they read on any picture
            LinearGradient(colors: light ? [.white.opacity(0.45), .clear] : [.black.opacity(0.45), .clear, .clear, .black.opacity(0.5)],
                           startPoint: .top, endPoint: light ? .init(x: 0.5, y: 0.3) : .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                TimelineView(.everyMinute) { tl in
                    Text(Fmt.hhmm(tl.date)).font(DS.hero(min(clock, 120))).monospacedDigit().foregroundStyle(text)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .shadow(color: shade, radius: 10, y: 4)
                }
                .padding(.top, 30)
                Text("Good morning").font(DS.title).foregroundStyle(text).shadow(color: shade, radius: 6, y: 2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DS.s16)
                card
            }
            .padding(.horizontal, DS.edge).padding(.bottom, 10)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onChange(of: picking) { _, items in
            guard !items.isEmpty else { return }
            Task { await morning.add(items); picking = [] }
        }
        .sheet(isPresented: $showOutfit) { OutfitSheet().presentationDetents([.large]) }
        .task { await OutfitStore.shared.refresh() }
    }

    /// The picture fills the screen and is cut to it (a wide photo mustn't push the time and the card off the sides).
    @ViewBuilder private func backdrop(_ look: MorningLook) -> some View {
        if case .station = look {
            StationBackdrop(home: false, moving: trip.movingStation, dim: 0.1)
        } else if let img = morning.image(look) {
            GeometryReader { g in
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: g.size.width, height: g.size.height).clipped()
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        } else {
            DS.page.ignoresSafeArea()
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            if let p = day {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(SchoolAlarm.dayWord(p.classStart)) · first class \(Fmt.hhmm(p.classStart))").font(DS.subStrong).monospacedDigit().foregroundStyle(DS.secondary)
                    Text(p.title).font(DS.title).foregroundStyle(DS.text).lineLimit(2)
                    if let r = p.room, !r.isEmpty { Text(r).font(DS.sub).foregroundStyle(DS.secondary).lineLimit(1) }
                }
                .accessibilityElement(children: .combine)
                HStack(alignment: .lastTextBaseline) {
                    if let l = p.leave {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Leave").font(DS.footnoteStrong).foregroundStyle(DS.secondary)
                            Text(Fmt.hhmm(l)).font(DS.hero(min(big, 64))).monospacedDigit().foregroundStyle(DS.text)
                            TimelineView(.everyMinute) { tl in
                                let m = Fmt.mins(l.timeIntervalSince(tl.date))
                                Text(l < tl.date ? "now" : m >= 60 ? "in \(m / 60) h \(String(format: "%02d", m % 60))" : "in \(m) min")
                                    .font(DS.subStrong).monospacedDigit().foregroundStyle(m < 10 ? DS.warning : DS.accentText)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Spacer()
                    if let a = p.arrive {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("At BUas").font(DS.footnoteStrong).foregroundStyle(DS.secondary)
                            Text(Fmt.hhmm(a)).font(DS.bigNumber).monospacedDigit().foregroundStyle(DS.text)
                            if let lines = p.lines { Text(lines).font(DS.footnote).foregroundStyle(DS.secondary) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Button { showOutfit = true } label: { DSOutfitLine() }.buttonStyle(.plain)
                DSPrimaryButton(title: "Go hands-free", icon: "bolt.fill") { go(p) }
            } else {
                Text("No class planned today.").font(DS.headline).foregroundStyle(DS.text)
            }
            HStack {
                DSQuietButton(title: "I’m up") { withAnimation(.easeInOut(duration: 0.35)) { morning.showing = false } }
                Spacer()
                PhotosPicker(selection: $picking, maxSelectionCount: 10, matching: .images) {
                    Label(morning.photos.isEmpty ? "Add your photos" : "Add photos", systemImage: "photo.on.rectangle")
                        .font(DS.subStrong).foregroundStyle(DS.accentText).frame(minHeight: DS.hit)
                }
            }
        }
        .dsCard()
    }
}

/// What to wear today, in one line (as `OutfitLine`).
struct DSOutfitLine: View {
    @ObservedObject private var store = OutfitStore.shared
    var body: some View {
        if let p = store.plan, let s = p.start {
            HStack(spacing: 10) {
                Image(systemName: s.layer.icon).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(s.layer.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text("Wear: \(s.layer.name.lowercased()), \(s.layer.layers) layer\(s.layer.layers == 1 ? "" : "s")\(p.raincoat ? " + raincoat" : "")"
                     + (p.changes.first.map { " · \($0.to > $0.from ? "drop" : "add") one around \(Fmt.hhmm($0.at))" } ?? ""))
                    .font(DS.sub).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary).accessibilityHidden(true)
            }
            .frame(minHeight: DS.hit)
            .contentShape(Rectangle())
            .accessibilityHint("What to wear today")
        }
    }
}
