import SwiftUI

/// The look of Recomp: the app's paper, with one colour for everything protein (the bar, the ticks, the buttons).
enum RecompStyle {
    static let accent = Paper.green
    /// Second lines on a card. Darker than `Paper.muted`, which is a little light for small text on the card.
    static let quiet = Paper.ink.opacity(0.7)
}

/// The Recomp screen, from top to bottom: the weigh-in (and the waist when it's due), protein with its sources and
/// what you've had today, today's habits, and the weekly check. The settings are at the bottom.
struct RecompSheet: View {
    @ObservedObject private var store = RecompStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// The recomp day on screen. The store doesn't publish when the day turns over at 04:00, so this does.
    @State private var day = RecompCalendar.day(for: Date())
    @State private var picked: ProteinSource?
    @State private var editing: ProteinEntry?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    RecompWeightCard()
                    RecompProteinCard(pick: { picked = $0 }, edit: { editing = $0 }, scan: { scanning = true })
                    RecompHabitsCard()
                    RecompCheckCard()
                    settingsLink
                }
                .id(day)                                // a new day starts with fresh fields
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PaperFill().ignoresSafeArea())
            .navigationTitle("Recomp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundStyle(Paper.navy) }
            }
            .sheet(item: $picked) { s in addSheet(s) }
            .sheet(item: $editing) { e in editSheet(e) }
            .sheet(isPresented: $scanning) {
                // Task 7: ScanSheet
                Text("Scanning comes next").presentationDetents([.large])
            }
        }
        .preferredColorScheme(.light)                   // ink on paper, the title too
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private func refresh() {
        store.refreshCheck()
        let today = store.today
        if day != today { day = today }
    }

    private var settingsLink: some View {
        NavigationLink {
            // Task 8: RecompSettingsView
            Text("Settings come next")
        } label: {
            HStack(spacing: 8) {
                Text("Goal, sources and habits").font(BoardInk.sans(15, .medium))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(Paper.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paper.edge, lineWidth: 1.2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: how much

    private func addSheet(_ s: ProteinSource) -> some View {
        AmountSheet(name: s.name, unit: s.unit, units: s.units, gramsPerUnit: s.gramsPerUnit,
                    step: s.step, start: 1, button: "Add") { amount in
            store.add(s, amount: amount)
        }
        .presentationDetents([.height(300)])
    }

    private func editSheet(_ e: ProteinEntry) -> some View {
        AmountSheet(name: e.name, unit: e.unit, units: e.units, gramsPerUnit: e.gramsPerUnit,
                    step: step(for: e), start: e.amount, button: "Save") { amount in
            store.setAmount(e.id, amount)
        }
        .presentationDetents([.height(300)])
    }

    /// An entry doesn't keep its step: take its source's, but never one coarser than the amount already logged.
    private func step(for e: ProteinEntry) -> Double {
        let frac = e.amount - e.amount.rounded(.down)
        let fits: Double = abs(frac) < 0.01 ? 1 : abs(frac - 0.5) < 0.01 ? 0.5 : 0.25
        if let s = store.data.sources.first(where: { $0.name == e.name && $0.unit == e.unit }), s.step > 0 {
            return min(s.step, fits)
        }
        return e.unit == "pack" ? 0.25 : fits
    }
}

// MARK: - Weight

private enum RecompField: Hashable { case weight, waist }

/// The week average big; today's weigh-in (or the field for it); the waist when it's due, or how it's going.
private struct RecompWeightCard: View {
    @ObservedObject private var store = RecompStore.shared
    @State private var weight = ""
    @State private var waist = ""
    @State private var changingWeight = false
    @State private var changingWaist = false
    @State private var saves = 0
    @FocusState private var focus: RecompField?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            weightRow
            waistRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
        .sensoryFeedback(.success, trigger: saves)
    }

    @ViewBuilder private var headline: some View {
        if let avg = store.weekAverage {
            VStack(alignment: .leading, spacing: 2) {
                Text(RecompFormat.kg(avg))
                    .font(HWFont.display(34)).monospacedDigit().foregroundStyle(Paper.ink)
                    .contentTransition(.numericText(value: avg))
                Text(weekLine)
                    .font(BoardInk.sans(13, .medium)).monospacedDigit().foregroundStyle(RecompStyle.quiet)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Weigh in to see your week average")
                .font(HWFont.display(20)).foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var weekLine: String {
        guard let c = store.weekChange else { return "week average" }
        return "week average · \(RecompFormat.change(c)) vs last week"
    }

    @ViewBuilder private var weightRow: some View {
        if let kg = store.todayWeight, !changingWeight {
            HStack(spacing: 8) {
                Text(verbatim: "Today \(RecompFormat.kg(kg))")
                    .font(BoardInk.sans(15, .medium)).monospacedDigit().foregroundStyle(Paper.ink)
                Spacer(minLength: 8)
                Button("Change") { startChange(.weight, from: kg) }
                    .buttonStyle(RecompButtonStyle(filled: false))
            }
        } else {
            HStack(spacing: 8) {
                numberField("Weight (kg)", text: $weight, .weight)
                Button("Save") { saveWeight() }
                    .buttonStyle(RecompButtonStyle())
                    .disabled(RecompInput.weight(weight) == nil)
            }
        }
    }

    @ViewBuilder private var waistRow: some View {
        if store.waistDue || changingWaist {
            HStack(spacing: 8) {
                numberField("Waist (cm)", text: $waist, .waist)
                Button("Save") { saveWaist() }
                    .buttonStyle(RecompButtonStyle())
                    .disabled(RecompInput.waist(waist) == nil)
                if !changingWaist {
                    Button("Skip") { skipWaist() }
                        .buttonStyle(RecompButtonStyle(filled: false))
                }
            }
        } else if let line = waistLine {
            HStack(spacing: 8) {
                Text(verbatim: line)
                    .font(BoardInk.sans(13, .medium)).monospacedDigit().foregroundStyle(RecompStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // a typo can be put right the same day (it would otherwise stand for two weeks)
                if let last = lastWaist, last.day == store.today {
                    Button("Change") { startChange(.waist, from: last.value) }
                        .buttonStyle(RecompButtonStyle(filled: false))
                }
            }
        }
    }

    /// "Waist 92 cm · −2,5 since 16 Nov"
    private var waistLine: String? {
        guard let s = WeightMath.waistSummary(store.data.waists) else { return nil }
        var line = "Waist \(RecompNum.plain(s.latest)) cm"
        if abs(s.sinceFirst) >= 0.05 {
            line += " · \(RecompNum.signed(s.sinceFirst)) since \(RecompCalendar.shortText(s.firstDay))"
        }
        return line
    }

    private var lastWaist: Measure? { store.data.waists.max { $0.day < $1.day } }

    /// A decimal-pad field. The whole box takes the tap, not just the text in it.
    private func numberField(_ prompt: String, text: Binding<String>, _ field: RecompField) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return TextField(prompt, text: text)
            .keyboardType(.decimalPad)
            .focused($focus, equals: field)
            .font(BoardInk.sans(17, .semibold))
            .monospacedDigit()
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background { shape.fill(Paper.paper).onTapGesture { focus = field } }
            .overlay(shape.stroke(focus == field ? RecompStyle.accent : Paper.edge, lineWidth: 1.2).allowsHitTesting(false))
    }

    private func startChange(_ field: RecompField, from value: Double) {
        withAnimation(.easeOut(duration: 0.2)) {
            if field == .weight {
                weight = RecompNum.plain(value)
                changingWeight = true
            } else {
                waist = RecompNum.plain(value)
                changingWaist = true
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)     // once the field is on screen
            focus = field
        }
    }

    private func saveWeight() {
        guard let kg = RecompInput.weight(weight) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            store.logWeight(kg)
            changingWeight = false
        }
        weight = ""
        focus = nil
        saves += 1
    }

    private func saveWaist() {
        guard let cm = RecompInput.waist(waist) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            store.logWaist(cm)
            changingWaist = false
        }
        waist = ""
        focus = nil
        saves += 1
    }

    private func skipWaist() {
        withAnimation(.easeOut(duration: 0.2)) { store.skipWaist() }
        waist = ""
        focus = nil
    }
}

// MARK: - Protein

/// What's left to eat, the bar, the sources to tap (and Scan), and what you've had today.
private struct RecompProteinCard: View {
    @ObservedObject private var store = RecompStore.shared
    let pick: (ProteinSource) -> Void
    let edit: (ProteinEntry) -> Void
    let scan: () -> Void

    private static let rowHeight: CGFloat = 46
    private static let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let entries = store.todayEntries
        let todayTotal = entries.reduce(0.0) { $0 + $1.grams }
        return VStack(alignment: .leading, spacing: 12) {
            headline(todayTotal)
            progress(todayTotal)
            sources
            if !entries.isEmpty { todayList(entries) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
        .animation(.easeOut(duration: 0.25), value: todayTotal)
        .sensoryFeedback(.success, trigger: todayTotal) { old, new in new > old }
    }

    private func headline(_ total: Double) -> some View {
        Text(verbatim: ProteinMath.toGo(total: total, goal: store.data.goal) ?? "Protein goal reached")
            .font(HWFont.display(24)).monospacedDigit().foregroundStyle(Paper.ink)
            .lineLimit(1).minimumScaleFactor(0.7)
            .contentTransition(.numericText(countsDown: true))
    }

    private func progress(_ total: Double) -> some View {
        let goal = store.data.goal
        let percent = ProteinMath.percent(total: total, goal: goal)
        let fill = goal > 0 ? min(max(total / goal, 0), 1) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                RecompBar(fill: fill)
                Text(verbatim: "\(percent)%")
                    .font(BoardInk.sans(15)).monospacedDigit().foregroundStyle(Paper.ink)
                    .contentTransition(.numericText(value: Double(percent)))
                    .frame(minWidth: 52, alignment: .trailing)
            }
            Text(verbatim: "\(RecompNum.whole(total)) of \(RecompFormat.grams(goal))")
                .font(BoardInk.sans(12, .medium)).monospacedDigit().foregroundStyle(RecompStyle.quiet)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Protein today")
        .accessibilityValue("\(percent) percent, \(RecompNum.whole(total)) of \(RecompNum.whole(goal)) grams")
    }

    private var sources: some View {
        LazyVGrid(columns: Self.columns, spacing: 8) {
            ForEach(Array(store.data.sources.prefix(RecompData.maxSources))) { s in
                Button { pick(s) } label: { tile(s) }
                    .buttonStyle(RecompTileStyle())
            }
            Button { scan() } label: { scanTile }
                .buttonStyle(RecompTileStyle())
        }
    }

    private func tile(_ s: ProteinSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: s.name.isEmpty ? "Source" : s.name)
                .font(BoardInk.sans(15)).foregroundStyle(Paper.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            if !s.unit.isEmpty {
                Text(verbatim: "per \(s.unit)")
                    .font(BoardInk.sans(12, .regular)).foregroundStyle(RecompStyle.quiet)
                    .lineLimit(1)
            }
        }
    }

    private var scanTile: some View {
        HStack(spacing: 8) {
            Image(systemName: "barcode.viewfinder").font(.system(size: 20, weight: .semibold))
            Text("Scan").font(BoardInk.sans(15))
        }
        .foregroundStyle(Paper.ink)
    }

    /// Today's entries, newest first. Swipe one away, or tap it to change the amount.
    private func todayList(_ entries: [ProteinEntry]) -> some View {
        List {
            ForEach(entries) { e in
                row(e)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { store.remove(e.id) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .frame(height: CGFloat(entries.count) * Self.rowHeight)
    }

    private func row(_ e: ProteinEntry) -> some View {
        Button { edit(e) } label: {
            HStack(spacing: 8) {
                Text(verbatim: Self.label(e))
                    .font(BoardInk.sans(15, .medium)).monospacedDigit().foregroundStyle(Paper.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(verbatim: RecompFormat.grams(e.grams))
                    .font(BoardInk.sans(13, .medium)).monospacedDigit().foregroundStyle(RecompStyle.quiet)
            }
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(Paper.edge).frame(height: 1) }
    }

    /// "¾ tub Kwark", and "3 eggs" rather than "3 eggs Eggs".
    private static func label(_ e: ProteinEntry) -> String {
        let amount = ProteinMath.amountLabel(e.amount, unit: e.unit, units: e.units)
        let name = e.name.lowercased()
        if name.isEmpty || name == e.unit.lowercased() || name == e.units.lowercased() { return amount }
        return "\(amount) \(e.name)"
    }
}

/// The protein bar: the accent fills it towards the day's goal.
private struct RecompBar: View {
    let fill: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Paper.edge)
                Capsule().fill(RecompStyle.accent)
                    .frame(width: fill > 0 ? max(16, g.size.width * CGFloat(fill)) : 0)
            }
        }
        .frame(height: 16)
    }
}

// MARK: - Habits

/// Today's habits. One that didn't happen just stays an empty circle.
private struct RecompHabitsCard: View {
    @ObservedObject private var store = RecompStore.shared

    var body: some View {
        let habits = Array(store.data.habits.prefix(RecompData.maxHabits))
        if !habits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Today").font(HWFont.display(18)).foregroundStyle(Paper.ink).padding(.bottom, 4)
                ForEach(habits) { h in
                    RecompHabitRow(title: h.title, done: store.isDone(h.id)) {
                        withAnimation(.easeOut(duration: 0.2)) { store.toggleHabit(h.id) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperCard()
        }
    }
}

private struct RecompHabitRow: View {
    let title: String
    let done: Bool
    let toggle: () -> Void

    var body: some View {
        Button { toggle() } label: {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(done ? Color.white : Paper.ink.opacity(0.55), RecompStyle.accent)
                    .font(.system(size: 26))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30)
                Text(verbatim: title)
                    .font(BoardInk.sans(15, .medium)).foregroundStyle(Paper.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: done)
        .accessibilityValue(done ? Text("Done") : Text("Not done"))
    }
}

// MARK: - Weekly check

/// What the weekly check says, and the button to say you've acted on it.
private struct RecompCheckCard: View {
    @ObservedObject private var store = RecompStore.shared

    var body: some View {
        let text = WeeklyCheck.text(store.verdict)
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: text.title)
                .font(BoardInk.sans(15)).monospacedDigit().foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = text.detail {
                Text(verbatim: detail)
                    .font(BoardInk.sans(13, .regular)).monospacedDigit().foregroundStyle(RecompStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if asksToAdjust {
                Button("Done, I've adjusted") {
                    withAnimation(.easeOut(duration: 0.2)) { store.markAdjusted() }
                }
                .buttonStyle(RecompButtonStyle(wide: true))
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private var asksToAdjust: Bool {
        switch store.verdict {
        case .eatLess, .eatMore: return true
        default: return false
        }
    }
}

// MARK: - How much (a source, or an entry from today)

/// How much of one thing: a big − and + by its step (from one step up to 20), what that is in protein, and one button.
struct AmountSheet: View {
    let name: String
    let unit: String
    let units: String
    let gramsPerUnit: Double
    let step: Double
    let start: Double
    let button: String
    let done: (Double) -> Void

    static let most: Double = 20

    @Environment(\.dismiss) private var dismiss
    @State private var amount: Double

    init(name: String, unit: String, units: String, gramsPerUnit: Double, step: Double, start: Double,
         button: String, done: @escaping (Double) -> Void) {
        let s = step > 0 && step.isFinite ? step : 1
        self.name = name
        self.unit = unit
        self.units = units
        self.gramsPerUnit = gramsPerUnit
        self.step = s
        self.start = start
        self.button = button
        self.done = done
        let first = start.isFinite ? start : s
        _amount = State(initialValue: min(max(first, s), AmountSheet.most))
    }

    private var canLess: Bool { amount - step >= step - 0.001 }
    private var canMore: Bool { amount + step <= AmountSheet.most + 0.001 }

    var body: some View {
        VStack(spacing: 14) {
            Text(verbatim: name)
                .font(HWFont.display(22)).foregroundStyle(Paper.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 12) {
                stepButton("minus", label: "Less", enabled: canLess) { amount = max(step, amount - step) }
                Text(verbatim: ProteinMath.amountLabel(amount, unit: unit, units: units))
                    .font(HWFont.display(32)).monospacedDigit().foregroundStyle(Paper.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText(value: amount))
                stepButton("plus", label: "More", enabled: canMore) { amount = min(AmountSheet.most, amount + step) }
            }
            Text(verbatim: "≈ \(RecompFormat.grams(amount * gramsPerUnit)) protein")
                .font(BoardInk.sans(14, .medium)).monospacedDigit().foregroundStyle(RecompStyle.quiet)
            Button(button) {
                done(amount)
                dismiss()
            }
            .buttonStyle(RecompButtonStyle(wide: true, height: 52))
        }
        .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PaperFill().ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.light)
        .sensoryFeedback(.selection, trigger: amount)
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool, _ go: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { go() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .bold)).foregroundStyle(Paper.ink)
                .frame(width: 64, height: 64)
                .background(Paper.card, in: Circle())
                .overlay(Circle().stroke(Paper.edge, lineWidth: 1.2))
                .contentShape(Circle())
        }
        .buttonStyle(RecompPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

// MARK: - Buttons

/// The Recomp buttons: filled with the accent for the thing to do (Save, Add), quiet paper for the rest (Change, Skip).
/// At least 44 pt high; they give a little when pressed and fade when they can't be used.
struct RecompButtonStyle: ButtonStyle {
    var filled = true
    var wide = false
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        RecompButtonBody(configuration: configuration, filled: filled, wide: wide, height: height)
    }
}

private struct RecompButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let filled: Bool
    let wide: Bool
    let height: CGFloat
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        let pressed = configuration.isPressed
        return configuration.label
            .font(BoardInk.sans(15))
            .foregroundStyle(filled ? Color.white : Paper.ink)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(maxWidth: wide ? CGFloat.infinity : nil, minHeight: height)
            .background(filled ? RecompStyle.accent : Paper.paper, in: shape)
            .overlay(shape.stroke(filled ? Color.clear : Paper.edge, lineWidth: 1.2))
            .contentShape(shape)
            .opacity(enabled ? (pressed ? 0.8 : 1) : 0.4)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

/// A source tile: paper that gives under your thumb.
private struct RecompTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        let pressed = configuration.isPressed
        return configuration.label
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(pressed ? Paper.rule : Paper.paper, in: shape)
            .overlay(shape.stroke(Paper.edge, lineWidth: 1.2))
            .contentShape(shape)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

private struct RecompPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Numbers

/// Numbers the phone's own way ("92", "92,5", "−2,5").
private enum RecompNum {
    private static func formatter(_ fewest: Int, _ most: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .decimal
        f.minimumFractionDigits = fewest
        f.maximumFractionDigits = most
        f.usesGroupingSeparator = false
        return f
    }

    /// "92" or "92,5"
    static func plain(_ v: Double) -> String {
        formatter(0, 1).string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// "−2,5" or "+1,0"
    static func signed(_ v: Double) -> String {
        let a = abs(v)
        let body = formatter(1, 1).string(from: NSNumber(value: a)) ?? "\(a)"
        return (v < 0 ? "\u{2212}" : "+") + body
    }

    static func whole(_ v: Double) -> Int { v.isFinite ? Int(v.rounded()) : 0 }
}
