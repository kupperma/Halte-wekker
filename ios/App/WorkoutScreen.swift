import SwiftUI

/// The Workouts screen, from top to bottom: the workout that runs (Resume), or what's on today with one big Start;
/// the body weight and waist from Recomp; the sets per week; and the way to the history, the exercises, the routines
/// and the settings.
struct WorkoutsSheet: View {
    @ObservedObject private var store = WorkoutStore.shared
    @ObservedObject private var recomp = RecompStore.shared
    @Environment(\.dismiss) private var dismiss
    /// The routines that start once the body weight has been asked.
    @State private var pending: [String]?
    @State private var askingWeight = false
    /// Start and Resume, for the haptic.
    @State private var taps = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !store.available { unavailableLine }
                    if let a = store.active {
                        resumeCard(a)
                    } else {
                        startCard
                    }
                    if let line = bodyLine {
                        Text(verbatim: line)
                            .font(BoardInk.sans(13, .medium)).monospacedDigit().foregroundStyle(WorkoutStyle.quiet)
                            .padding(.horizontal, 2)
                    }
                    WorkoutSetsCard()
                    links
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .animation(.easeOut(duration: 0.25), value: store.active == nil)
            }
            .background(PaperFill().ignoresSafeArea())
            .navigationTitle("Workouts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundStyle(Paper.navy) }
            }
            .sheet(isPresented: $askingWeight, onDismiss: startPending) {
                WorkoutBodyWeightSheet { kg in saveBodyWeight(kg) }
            }
        }
        .preferredColorScheme(.light)                   // ink on paper, the title too
        .sensoryFeedback(.impact, trigger: taps)
        .onAppear {
            store.refresh()
            WorkoutNav.shared.screenAppeared()
        }
        .onDisappear { WorkoutNav.shared.screenDisappeared() }
    }

    /// Before the first unlock after a restart the files can't be read: nothing starts until they can.
    private var unavailableLine: some View {
        Text("Can’t read your workouts right now. Unlock your iPhone and try again.")
            .font(BoardInk.sans(13, .medium)).foregroundStyle(WorkoutStyle.quiet)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    // MARK: the workout that runs

    /// "Pull · 32:10" and one big Resume.
    private func resumeCard(_ a: ActiveWorkout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            (Text(verbatim: "\(a.workout.title) · ") + Text(a.workout.start, style: .timer))
                .font(HWFont.display(24)).monospacedDigit().foregroundStyle(Paper.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Button {
                taps += 1
                WorkoutNav.shared.openSession()
            } label: {
                Text("Resume").font(BoardInk.sans(17))
            }
            .buttonStyle(RecompButtonStyle(wide: true, height: 56))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: what's on today

    private var startCard: some View {
        let next = store.nextUp
        let title = Rotation.title(next)
        let ids = Rotation.routineIds(next)
        let plan = store.preview(ids)
        let other = Self.other(next, days: Rotation.days(store.index.workouts))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(verbatim: next == .restThenPush ? "Rest day. Next: Push" : title)
                    .font(HWFont.display(24)).foregroundStyle(Paper.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                optionsMenu
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Session.planLine(plan))
                    .font(BoardInk.sans(14, .semibold)).monospacedDigit().foregroundStyle(Paper.ink)
                    .contentTransition(.numericText())
                Text(verbatim: Session.namesLine(plan, library: store.library, ladders: store.ladders))
                    .font(BoardInk.sans(13, .medium)).foregroundStyle(WorkoutStyle.quiet)
                    .lineLimit(1)
            }
            Button { start(ids) } label: {
                Text(verbatim: "Start \(title)").font(BoardInk.sans(17))
            }
            .buttonStyle(RecompButtonStyle(wide: true, height: 56))
            .disabled(!store.available)
            HStack(spacing: 2) {
                Button("\(other.title) instead") { start(other.ids) }
                Text(verbatim: "·").font(BoardInk.sans(14, .semibold)).foregroundStyle(WorkoutStyle.quiet)
                    .accessibilityHidden(true)
                Button("Empty workout") { start([]) }
            }
            .buttonStyle(WorkoutLinkStyle())
            .disabled(!store.available)
            .padding(.leading, -8)                      // the words line up with the lines above, not their hit areas
            .padding(.vertical, -6)
            if let last = store.lastWorkout {
                Text(verbatim: Rotation.lastLine(last))
                    .font(BoardInk.sans(13, .medium)).monospacedDigit().foregroundStyle(WorkoutStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.state.deload.active {
                Text("Deload this cycle: fewer sets, the same weights.")
                    .font(BoardInk.sans(13, .medium)).foregroundStyle(Paper.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = store.deloadLine { deloadPrompt(line) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    /// The other routine: a Pull (with legs when it's their turn) when Push is next, else Push.
    private static func other(_ n: NextUp, days: [RotationDay]) -> (title: String, ids: [String]) {
        let o: NextUp
        switch n {
        case .push, .restThenPush: o = Rotation.pullNow(days)
        case .pull: o = .push
        }
        return (Rotation.title(o), Rotation.routineIds(o))
    }

    private var optionsMenu: some View {
        Menu {
            if store.state.deload.active {
                Button("Cancel deload") { withAnimation(.easeOut(duration: 0.25)) { store.cancelDeload() } }
            } else {
                Button("Deload this cycle") { withAnimation(.easeOut(duration: 0.25)) { store.startDeload() } }
            }
            Button("Empty workout") { start([]) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Paper.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!store.available)
        .accessibilityLabel("Options")
        // the dots sit at the card's edge; the 44 pt hit area reaches into its padding
        .padding(.trailing, -12).padding(.vertical, -8)
    }

    /// "Week 6 since your last deload. Take one this cycle?" with Deload and Not yet.
    private func deloadPrompt(_ line: DeloadLine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: Deload.text(line))
                .font(BoardInk.sans(14, .medium)).monospacedDigit().foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Deload") { withAnimation(.easeOut(duration: 0.25)) { store.startDeload() } }
                    .buttonStyle(RecompButtonStyle())
                Button("Not yet") { withAnimation(.easeOut(duration: 0.25)) { store.snoozeDeload() } }
                    .buttonStyle(RecompButtonStyle(filled: false))
            }
            .disabled(!store.available)
        }
        .padding(.top, 2)
    }

    // MARK: Recomp

    /// "Body 88.1 kg · waist 92 cm": Recomp's week average and the last waist, each only when there is one.
    private var bodyLine: String? {
        let weight = recomp.weekAverage.map { "\(WorkoutFormat.kg(($0 * 10).rounded() / 10)) kg" }
        let waist = recomp.data.waists.max(by: { $0.day < $1.day })
            .map { "\(WorkoutFormat.kg(($0.value * 10).rounded() / 10)) cm" }
        switch (weight, waist) {
        case let (w?, c?): return "Body \(w) · waist \(c)"
        case let (w?, nil): return "Body \(w)"
        case let (nil, c?): return "Waist \(c)"
        case (nil, nil): return nil
        }
    }

    // MARK: the way on

    /// History · Exercises · Routines · Settings. The screens behind them come later.
    private var links: some View {
        HStack(spacing: 0) {
            link("History")
            dot
            link("Exercises")
            dot
            link("Routines")
            dot
            link("Settings")
        }
        .padding(.leading, -6)
    }

    private var dot: some View {
        Text(verbatim: "·").font(BoardInk.sans(15, .medium)).foregroundStyle(WorkoutStyle.quiet)
            .accessibilityHidden(true)
    }

    private func link(_ title: String) -> some View {
        NavigationLink {
            WorkoutPlaceholder(title: title)
        } label: {
            Text(verbatim: title)
                .font(BoardInk.sans(15, .medium)).foregroundStyle(Paper.ink)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: starting

    /// A routine with pull-ups or dips needs a body weight: without one, it is asked once first.
    private func start(_ ids: [String]) {
        guard store.available, store.active == nil else { return }
        taps += 1
        if needsBodyWeight(ids) {
            pending = ids
            askingWeight = true
        } else {
            begin(ids)
        }
    }

    private func needsBodyWeight(_ ids: [String]) -> Bool {
        guard store.bodyWeightNow == nil else { return false }
        return store.preview(ids).workout.exercises.contains { e in
            switch store.exercise(e.exerciseId)?.kind {
            case .bodyweight?, .weighted?, .assisted?: return true
            default: return false
            }
        }
    }

    private func begin(_ ids: [String]) {
        store.start(ids)
        guard store.active != nil else { return }
        WorkoutNav.shared.openSession()
    }

    /// The body weight sheet has gone, saved or not: the workout starts.
    private func startPending() {
        guard let ids = pending else { return }
        pending = nil
        begin(ids)
    }

    private func saveBodyWeight(_ kg: Double) {
        var s = store.state.settings
        s.fixedBodyWeight = kg
        store.updateSettings(s)
    }
}

// MARK: - Sets per week

/// The hard sets per week over the last 21 days against what the routines plan: the seven groups of the program,
/// and the rest under More.
private struct WorkoutSetsCard: View {
    @ObservedObject private var store = WorkoutStore.shared

    var body: some View {
        let counts = store.weeklySets
        let targets = store.targets
        let more = SetRow.more.filter { row in
            let c = counts[row]
            return (c?.direct ?? 0) + (c?.indirect ?? 0) > 0 || (targets[row] ?? 0) > 0
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SETS PER WEEK").font(BoardInk.sans(12, .bold)).tracking(0.6).foregroundStyle(Paper.ink)
                Spacer(minLength: 8)
                Text("last 3 weeks").font(BoardInk.sans(12, .medium)).foregroundStyle(WorkoutStyle.quiet)
            }
            .padding(.bottom, 4)
            ForEach(SetRow.main, id: \.self) { row in
                WorkoutSetRow(row: row, count: counts[row], target: targets[row])
            }
            if !more.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(more, id: \.self) { row in
                            WorkoutSetRow(row: row, count: counts[row], target: targets[row])
                        }
                    }
                } label: {
                    Text("More").font(BoardInk.sans(14, .semibold)).foregroundStyle(Paper.ink)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .tint(Paper.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }
}

/// "Side delts  ▓▓▓▓▓▓▓░  15 / 16", and "+4 indirect" under the numbers when there are some.
private struct WorkoutSetRow: View {
    let row: SetRow
    let count: RowCount?
    let target: Int?

    var body: some View {
        let exact = count?.direct ?? 0
        let direct = Int(exact.rounded())
        let indirect = Int((count?.indirect ?? 0).rounded())
        let goal = max(0, target ?? 0)
        let least = WeeklySets.priorityFloor
        let priority = WeeklySets.priority.contains(row)
        // a priority group's bar reaches at least to its floor, so the tick is always on it
        let scale = priority ? max(goal, least) : goal
        let tick: Double? = priority ? Double(least) / Double(scale) : nil
        return HStack(spacing: 10) {
            Text(verbatim: row.title)
                .font(BoardInk.sans(14, .semibold)).foregroundStyle(Paper.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 96, alignment: .leading)
            if scale > 0 {
                WorkoutBar(fill: min(exact / Double(scale), 1), tick: tick)
            } else {
                Spacer(minLength: 0)                    // nothing planned: no bar to fill
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: goal > 0 ? "\(direct) / \(goal)" : "\(direct)")
                    .font(BoardInk.sans(14, .semibold)).monospacedDigit().foregroundStyle(Paper.ink)
                    .contentTransition(.numericText())
                if indirect > 0 {
                    Text(verbatim: "+\(indirect) indirect")
                        .font(BoardInk.sans(11, .medium)).monospacedDigit().foregroundStyle(WorkoutStyle.quiet)
                }
            }
            .frame(width: 76, alignment: .trailing)
        }
        .frame(minHeight: 34)
        .animation(.easeOut(duration: 0.25), value: exact)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(spoken(direct: direct, goal: goal, indirect: indirect))
    }

    private func spoken(direct: Int, goal: Int, indirect: Int) -> String {
        var v = goal > 0 ? "\(direct) of \(goal) sets a week" : "\(direct) sets a week"
        if indirect > 0 { v += ", \(indirect) indirect" }
        return v
    }
}

/// The accent fills it towards the target (a priority group's: towards its floor of 12 at least), and a priority
/// group has a thin tick at that floor.
private struct WorkoutBar: View {
    let fill: Double
    let tick: Double?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Paper.edge).frame(height: 8)
                Capsule().fill(WorkoutStyle.accent)
                    .frame(width: fill > 0 ? max(8, w * CGFloat(fill)) : 0, height: 8)
                if let tick {
                    Rectangle().fill(Paper.ink.opacity(0.6))
                        .frame(width: 2, height: 14)
                        .offset(x: min(max(0, w * CGFloat(tick) - 1), max(0, w - 2)))
                }
            }
            .frame(width: w, height: 14, alignment: .leading)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - Pieces

/// The small words under Start: no box, at least 44 pt high, and they fade when they can't be used.
private struct WorkoutLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkoutLinkBody(configuration: configuration)
    }
}

private struct WorkoutLinkBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(BoardInk.sans(14, .semibold))
            .foregroundStyle(Paper.ink)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Asked once, before the first workout with pull-ups or dips, when Recomp has no weight either. Save or Skip, the
/// workout starts when it has gone.
private struct WorkoutBodyWeightSheet: View {
    let save: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var kg: Double? {
        guard let v = WorkoutInput.kg(text), v > 0 else { return nil }
        return v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your body weight (kg)").font(HWFont.display(22)).foregroundStyle(Paper.ink)
            HStack(spacing: 8) {
                field
                Button("Save") {
                    guard let kg else { return }
                    save(kg)
                    dismiss()
                }
                .buttonStyle(RecompButtonStyle())
                .disabled(kg == nil)
                Button("Skip") { dismiss() }                // starts without it
                    .buttonStyle(RecompButtonStyle(filled: false))
            }
        }
        .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PaperFill().ignoresSafeArea())
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.light)
        .task {
            try? await Task.sleep(nanoseconds: 350_000_000)     // once the sheet is up
            focused = true
        }
    }

    /// A decimal-pad field. The whole box takes the tap, not just the text in it.
    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return TextField("Weight", text: $text)
            .keyboardType(.decimalPad)
            .focused($focused)
            .font(BoardInk.sans(17, .semibold))
            .monospacedDigit()
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background { shape.fill(Paper.paper).onTapGesture { focused = true } }
            .overlay(shape.stroke(focused ? WorkoutStyle.accent : Paper.edge, lineWidth: 1.2).allowsHitTesting(false))
    }
}

/// Until the screen behind a link is built.
private struct WorkoutPlaceholder: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(HWFont.display(20)).foregroundStyle(WorkoutStyle.quiet)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PaperFill().ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
