import SwiftUI

// The ways into Recomp from the rest of the app: the tag on the map, the card under More, the weigh-in on the
// morning screen and a line on the ride home. Each reads `RecompStore.shared`; the screens only place them.

// MARK: - On the map

/// Next to the bell and the outfit: how far along today's protein is, as a small ring and "62%". Opens Recomp.
struct RecompTag: View {
    @ObservedObject private var store = RecompStore.shared
    let open: () -> Void

    var body: some View {
        let total = store.todayTotal
        let goal = store.data.goal
        let percent = ProteinMath.percent(total: total, goal: goal)
        return Button(action: open) {
            HStack(spacing: 5) {
                RecompRing(fill: goal > 0 ? total / goal : 0)
                Text(verbatim: "\(percent)%")
                    .font(.system(size: 13, weight: .heavy)).monospacedDigit()
                    .contentTransition(.numericText(value: Double(percent)))
            }
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 11).frame(height: 34)
            .background(Paper.paper, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
            // a 44 pt hit area round the 34 pt capsule, without moving the bell and the outfit beside it
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -5)
        .animation(.easeOut(duration: 0.25), value: percent)
        .accessibilityLabel("Protein today: \(percent) percent of your goal")
    }
}

/// A small ring that fills with the accent towards the day's goal.
private struct RecompRing: View {
    let fill: Double

    var body: some View {
        let f = CGFloat(min(max(fill, 0), 1))
        return ZStack {
            Circle().stroke(Paper.edge, lineWidth: 2.5)
            Circle().trim(from: 0, to: f)
                .stroke(RecompStyle.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

// MARK: - Under More

/// After the outfit: Recomp, with what's left of today's protein and the week's average weight.
struct RecompCard: View {
    @ObservedObject private var store = RecompStore.shared
    let pal: HWPalette
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "fork.knife").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(RecompStyle.accent, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recomp").font(HWFont.display(17)).foregroundStyle(Paper.ink)
                    Text(verbatim: subtitle).font(HWFont.body(12)).monospacedDigit().foregroundStyle(Paper.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Paper.ink.opacity(0.8))
            }
            .contentShape(Rectangle())
            .brass(pal, pad: 14)
        }
        .buttonStyle(.plain)
    }

    /// "60 g protein to go · week avg 88,1 kg". Before anything is logged: what it's for.
    private var subtitle: String {
        let d = store.data
        if d.entries.isEmpty && d.weights.isEmpty { return "Protein, habits and your weekly weight." }
        let protein = ProteinMath.toGo(total: store.todayTotal, goal: d.goal) ?? "Protein goal reached"
        guard let avg = store.weekAverage else { return protein }
        return "\(protein) · week avg \(RecompFormat.kg(avg))"
    }
}

// MARK: - On the ride home

/// Under the tiles, going home: the protein still to go today. Nothing once the goal is reached, going out, or on
/// the wake-up screen (that one is about your stop).
struct RecompRideLine: View {
    @EnvironmentObject var trip: TripManager
    @ObservedObject private var store = RecompStore.shared

    var body: some View {
        if trip.direction == .home, trip.phase != .awake,
           let line = ProteinMath.rideLine(total: store.todayTotal, goal: store.data.goal) {
            HStack(spacing: 6) {
                Circle().fill(RecompStyle.accent).frame(width: 6, height: 6)
                Text(verbatim: line)
                    .font(HWFont.body(12, bold: true)).monospacedDigit().foregroundStyle(Paper.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 16).padding(.top, 8)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - On the morning screen

/// Under the outfit: the weigh-in, and the waist when it's due. Once weighed, one line of how it's going.
struct RecompMorningLine: View {
    @ObservedObject private var store = RecompStore.shared
    @State private var weight = ""
    @State private var waist = ""
    @State private var saves = 0
    @FocusState private var focus: Field?

    private enum Field: Hashable { case weight, waist }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let kg = store.todayWeight {
                Text(verbatim: summary(kg))
                    .font(BoardInk.sans(13, .medium)).monospacedDigit().foregroundStyle(Paper.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if store.waistDue { waistRow(withSave: true) }
            } else {
                HStack(spacing: 8) {
                    field("Weight (kg)", text: $weight, .weight)
                    button("Save", filled: true) { save() }
                        .disabled(!canSave)
                }
                if store.waistDue { waistRow(withSave: false) }
            }
            if focus != nil { doneLine }
        }
        .paperCard()
        .environment(\.colorScheme, .light)             // ink on paper: the prompts in the fields too
        .sensoryFeedback(.success, trigger: saves)
        .toolbar {
            // the decimal pad has no return key. Outside a NavigationStack this bar may not show, hence `doneLine`.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
    }

    /// While a field is being typed in: puts the keyboard away, keeping what's typed. Always there, unlike the bar
    /// above the keyboard.
    private var doneLine: some View {
        Button { focus = nil } label: {
            Text("Done")
                .font(BoardInk.sans(15, .semibold)).foregroundStyle(RecompStyle.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel("Done typing")
    }

    /// "Weighed: 88,4 kg · week avg 88,1 kg"
    private func summary(_ kg: Double) -> String {
        var line = "Weighed: \(RecompFormat.kg(kg))"
        if let avg = store.weekAverage { line += " · week avg \(RecompFormat.kg(avg))" }
        return line
    }

    /// The waist under the weight (the Save above takes both), or on its own once weighed.
    private func waistRow(withSave: Bool) -> some View {
        HStack(spacing: 8) {
            field("Waist (cm)", text: $waist, .waist)
            if withSave {
                button("Save", filled: true) { saveWaist() }
                    .disabled(RecompInput.waist(waist) == nil)
            }
            button("Skip", filled: false) { skipWaist() }
        }
    }

    /// Save takes whatever is typed. Something that doesn't read as a number keeps it from saving at all.
    private var canSave: Bool {
        let w = weight.trimmingCharacters(in: .whitespaces)
        let c = store.waistDue ? waist.trimmingCharacters(in: .whitespaces) : ""
        let kg = RecompInput.weight(w)
        let cm = RecompInput.waist(c)
        guard w.isEmpty || kg != nil, c.isEmpty || cm != nil else { return false }
        return kg != nil || cm != nil
    }

    /// A decimal-pad field. The whole box takes the tap, not just the text in it.
    private func field(_ prompt: String, text: Binding<String>, _ f: Field) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return TextField(prompt, text: text)
            .keyboardType(.decimalPad)
            .focused($focus, equals: f)
            .font(BoardInk.sans(17, .semibold))
            .monospacedDigit()
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background { shape.fill(Paper.paper).onTapGesture { focus = f } }
            .overlay(shape.stroke(focus == f ? RecompStyle.accent : Paper.edge, lineWidth: 1.2).allowsHitTesting(false))
    }

    /// Save and Skip the same width, so the fields above each other end in the same place.
    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minWidth: 40) }
            .buttonStyle(RecompButtonStyle(filled: filled))
    }

    private func save() {
        guard canSave else { return }
        let kg = RecompInput.weight(weight)
        let cm = store.waistDue ? RecompInput.waist(waist) : nil
        withAnimation(.easeOut(duration: 0.2)) {
            if let kg { store.logWeight(kg) }
            if let cm { store.logWaist(cm) }
        }
        if kg != nil { weight = "" }
        if cm != nil { waist = "" }
        focus = nil
        saves += 1
    }

    private func saveWaist() {
        guard let cm = RecompInput.waist(waist) else { return }
        withAnimation(.easeOut(duration: 0.2)) { store.logWaist(cm) }
        waist = ""
        focus = nil
        saves += 1
    }

    private func skipWaist() {
        withAnimation(.easeOut(duration: 0.2)) { store.skipWaist() }
        waist = ""
        if focus == .waist { focus = nil }
    }
}
