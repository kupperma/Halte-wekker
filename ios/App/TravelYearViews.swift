import SwiftUI

/// Your year in travel (0.35, `TravelYear`): swipeable cards in the new look, from Settings › Advanced and the home's
/// December card. Each card can go out as a picture through the share sheet: without any stop or place in it.
struct TravelYearScreen: View {
    /// Shown from the home's card (in a sheet): with Done.
    var done: (() -> Void)? = nil
    @ObservedObject private var log = TravelLogStore.shared
    @ObservedObject private var scores = ScoreBook.shared
    @State private var page = 0
    @State private var picture: Image?

    var body: some View {
        let s: TravelStats = log.stats()
        let cards: [YearCard] = TravelYear.cards(s, calendar: .current)
        let at: Int = min(page, max(0, cards.count - 1))
        VStack(spacing: DS.s12) {
            if cards.isEmpty {
                Spacer()
                VStack(spacing: DS.s12) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(DS.accentText).accessibilityHidden(true)
                    Text("Nothing to count yet").font(DS.title).foregroundStyle(DS.text)
                    Text("Ride with the alarm on: your hours on buses and trains, kilometres, CO₂ saved and favourites add up here, on this phone only.")
                        .font(DS.sub).foregroundStyle(DS.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DS.s24)
                Spacer()
            } else {
                TabView(selection: $page) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                        YearCardView(card: c, index: i, count: cards.count)
                            .padding(.horizontal, DS.s16)
                            .padding(.bottom, 36)                   // room for the dots
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                shareRow(cards[at], stats: s)
                    .padding(.horizontal, DS.s16)
                Text("Worked out on this phone from your rides with the alarm on\(s.fullYear ? ", the last 12 months" : ""). Kilometres are about: the straight line between your stops, a bit more for the road. CO₂ against driving alone in a car.")
                    .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.s16).padding(.bottom, DS.s8)
            }
        }
        .padding(.top, DS.s8)
        .background(DS.page.ignoresSafeArea())
        .navigationTitle(s.fullYear ? "Your year in travel" : "Your travel so far")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if let done { Button("Done") { done() } }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .task(id: "\(at)|\(cards.count)|\(cards[safe: at]?.value ?? "")") {
            picture = cards[safe: at].flatMap { Self.render($0, index: at, count: cards.count, year: s.fullYear) }
        }
    }

    @ViewBuilder private func shareRow(_ c: YearCard, stats s: TravelStats) -> some View {
        if let picture {
            ShareLink(item: picture, preview: SharePreview(c.title, image: picture)) {
                Label("Share this card", systemImage: "square.and.arrow.up")
                    .font(DS.bodyStrong).foregroundStyle(DS.onAccent)
                    .frame(maxWidth: .infinity, minHeight: DS.cta)
                    .background(DS.accent, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
            }
            .accessibilityHint("A picture of this card, without any stop or place in it")
        }
    }

    /// The card as a picture to share: light, 3×, without places (`shareSub`).
    @MainActor static func render(_ c: YearCard, index: Int, count: Int, year: Bool) -> Image? {
        let v = YearCardView(card: c, index: index, count: count, forShare: true, fullYear: year)
            .frame(width: 360, height: 460)
            .environment(\.colorScheme, .light)
        let r = ImageRenderer(content: v)
        r.scale = 3
        guard let ui = r.uiImage else { return nil }
        return Image(uiImage: ui)
    }
}

/// One card: its symbol, the small title, the big value and a line.
struct YearCardView: View {
    let card: YearCard
    let index: Int
    let count: Int
    var forShare = false
    var fullYear = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            HStack {
                Image(systemName: card.symbol).font(.title2.weight(.semibold)).foregroundStyle(DS.accentText).accessibilityHidden(true)
                Spacer()
                if !forShare {
                    Text("\(index + 1) of \(count)").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(card.title.uppercased()).font(DS.footnoteStrong).tracking(1.2).foregroundStyle(DS.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(card.value).font(DS.hero(54)).monospacedDigit().foregroundStyle(DS.text).lineLimit(1).minimumScaleFactor(0.4)
            Text(forShare ? (card.shareSub ?? card.sub) : card.sub).font(DS.body).foregroundStyle(DS.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if forShare {
                HStack {
                    Text("Haltewekker").font(DS.footnoteStrong).foregroundStyle(DS.accentText)
                    Spacer()
                    Text(fullYear ? "My year in travel" : "My travel so far").font(DS.footnote).foregroundStyle(DS.secondary)
                }
            }
        }
        .padding(DS.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [DS.accentSoft, DS.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

/// The home's card in December (or after a year of rides): opens Your year in travel; × puts it away for the year.
struct TravelYearBanner: View {
    let year: Int
    let open: () -> Void
    @ObservedObject private var log = TravelLogStore.shared

    var body: some View {
        HStack(spacing: DS.s12) {
            Button(action: open) {
                HStack(spacing: DS.s12) {
                    Image(systemName: "sparkles").font(.body.weight(.semibold)).foregroundStyle(DS.accentText)
                        .frame(width: 32, height: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Your \(String(year)) in travel").font(DS.subStrong).foregroundStyle(DS.text)
                        Text("Hours, kilometres, CO₂ saved and favourites").font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { withAnimation(DS.quick) { log.dismiss(year: year) } } label: {
                Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
                    .frame(width: DS.hit, height: DS.hit).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not now")
        }
        .padding(.leading, DS.s12)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.chipRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
