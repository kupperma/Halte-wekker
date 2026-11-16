import SwiftUI

// Changing a running workout and finishing it: the exercise picker (also for the routines editor and the Hevy import),
// the order of the exercises, and the summary after Finish.

// MARK: - Names

extension SetKind {
    /// "Warm-up", "Normal", "Failure", "Drop".
    var title: String {
        switch self {
        case .warmup: return "Warm-up"
        case .normal: return "Normal"
        case .failure: return "Failure"
        case .drop: return "Drop"
        }
    }
}

extension ExerciseKind {
    /// What one set of it holds: "kg × reps", "Reps", "Extra kg × reps", "Help kg × reps", "Seconds".
    var logs: String {
        switch self {
        case .weight: return "kg × reps"
        case .bodyweight: return "Reps"
        case .weighted: return "Extra kg × reps"
        case .assisted: return "Help kg × reps"
        case .time: return "Seconds"
        case .cardio: return "Time and km"
        }
    }
}

extension Equipment {
    var title: String {
        switch self {
        case .dumbbell: return "Dumbbell"
        case .barbell: return "Barbell"
        case .cable: return "Cable"
        case .machine: return "Machine"
        case .smith: return "Smith machine"
        case .bodyweight: return "Body weight"
        case .other: return "Other"
        }
    }
}

// MARK: - Picking an exercise

/// One section of the picker: a muscle group, or "Other".
private struct PickerGroup: Identifiable {
    let title: String
    let items: [Exercise]
    var id: String { title }
}

/// Picks an exercise: first "From your program" (`suggested`: a routine item's alternatives when replacing), then the
/// library by primary muscle in the order of the sets overview, "Other" for those without one, and last "New
/// exercise…". The search takes the words of a name or a Hevy name, with or without spaces and dashes ("pullup",
/// "db press"). A tap calls `pick` with the exercise's id and closes. It has its own NavigationStack: present it as a
/// sheet.
struct ExercisePicker: View {
    @ObservedObject private var store = WorkoutStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// One pick per opening, so a second tap while it closes adds nothing.
    @State private var chosen = false
    private let title: String
    private let suggested: [String]
    private let pick: (String) -> Void

    init(title: String, suggested: [String], pick: @escaping (String) -> Void) {
        self.title = title
        self.suggested = suggested
        self.pick = pick
    }

    var body: some View {
        let words = Self.words(query)
        let found = store.library.filter { Self.matches($0, words) }
        let program = Self.unique(suggested).compactMap { id in found.first { $0.id == id } }
        return NavigationStack {
            List {
                if !program.isEmpty {
                    Section {
                        ForEach(program) { row($0) }
                    } header: {
                        sectionTitle("From your program")
                    }
                }
                ForEach(Self.groups(found)) { g in
                    Section {
                        ForEach(g.items) { row($0) }
                    } header: {
                        sectionTitle(g.title)
                    }
                }
                Section {
                    NavigationLink {
                        NewExerciseForm(name: query.trimmingCharacters(in: .whitespacesAndNewlines)) { e in
                            choose(e.id)
                        }
                    } label: {
                        Label("New exercise…", systemImage: "plus")
                            .workoutFont(16, .semibold)
                            .foregroundStyle(Paper.ink)
                            .frame(minHeight: 44)
                    }
                    .listRowBackground(Paper.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(PaperFill().ignoresSafeArea())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .autocorrectionDisabled()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(Paper.ink)
        .preferredColorScheme(.light)
    }

    private func row(_ e: Exercise) -> some View {
        Button { choose(e.id) } label: {
            Text(verbatim: e.name)
                .workoutFont(16, .medium)
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .listRowBackground(Paper.card)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(verbatim: text)
            .workoutFont(13, .semibold)
            .foregroundStyle(WorkoutStyle.quiet)
    }

    private func choose(_ id: String) {
        guard !chosen else { return }
        chosen = true
        pick(id)
        dismiss()
    }

    /// By the first primary muscle, in the order of the sets overview (every leg muscle under Legs), each A to Z.
    private static func groups(_ list: [Exercise]) -> [PickerGroup] {
        let rows = SetRow.main + SetRow.more
        var buckets = Array(repeating: [Exercise](), count: rows.count)
        var other: [Exercise] = []
        for e in list {
            if let m = e.primary.first, let k = rows.firstIndex(where: { $0.contains(m) }) {
                buckets[k].append(e)
            } else {
                other.append(e)
            }
        }
        var out: [PickerGroup] = []
        for (k, row) in rows.enumerated() where !buckets[k].isEmpty {
            out.append(PickerGroup(title: row.title, items: byName(buckets[k])))
        }
        if !other.isEmpty { out.append(PickerGroup(title: "Other", items: byName(other))) }
        return out
    }

    private static func byName(_ list: [Exercise]) -> [Exercise] {
        list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The search's words, each without case, accents, spaces, dashes or brackets.
    private static func words(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map { key(String($0)) }.filter { !$0.isEmpty }
    }

    private static func key(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    /// Every word is in its name, or in one of its Hevy names.
    private static func matches(_ e: Exercise, _ words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        return ([e.name] + e.hevyNames).contains { name in
            let k = key(name)
            return words.allSatisfy { k.contains($0) }
        }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// "New exercise…": a name, what a set of it holds, and the equipment. Add puts it in the library and picks it.
private struct NewExerciseForm: View {
    /// Cardio comes only from the Hevy import.
    private static let kinds: [ExerciseKind] = [.weight, .bodyweight, .weighted, .assisted, .time]

    @ObservedObject private var store = WorkoutStore.shared
    private let made: (Exercise) -> Void
    @State private var name: String
    @State private var kind: ExerciseKind = .weight
    @State private var equipment: Equipment = .machine
    @State private var added = false
    @FocusState private var focused: Bool

    init(name: String, made: @escaping (Exercise) -> Void) {
        self.made = made
        _name = State(initialValue: name)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .focused($focused)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .frame(minHeight: 44)
            }
            .listRowBackground(Paper.card)
            Section {
                Picker("Each set", selection: $kind) {
                    ForEach(Self.kinds, id: \.self) { k in Text(verbatim: k.logs).tag(k) }
                }
                .frame(minHeight: 44)
                Picker("Equipment", selection: $equipment) {
                    ForEach(Equipment.allCases, id: \.self) { q in Text(verbatim: q.title).tag(q) }
                }
                .frame(minHeight: 44)
            }
            .listRowBackground(Paper.card)
            if !store.available {
                Text("Can’t save it right now. Unlock your iPhone and try again.")
                    .foregroundStyle(WorkoutStyle.quiet)
                    .listRowBackground(Color.clear)
            }
        }
        .workoutFont(16, .medium)
        .foregroundStyle(Paper.ink)
        .scrollContentBackground(.hidden)
        .background(PaperFill().ignoresSafeArea())
        .navigationTitle("New exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", action: add)
                    .disabled(trimmed.isEmpty || !store.available || added)
            }
        }
        .task {
            guard trimmed.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))      // once it has slid in
            focused = true
        }
    }

    private func add() {
        guard !added, !trimmed.isEmpty else { return }
        let e = store.newExercise(name: trimmed, kind: kind, equipment: equipment)
        guard store.exercise(e.id) != nil else { return }      // not saved: nothing to pick
        added = true
        made(e)
    }
}

// MARK: - The order

/// The running workout's exercises in order, each with a handle to drag it to another place. A superset's members
/// carry the marks the workout shows ("5a", "5b"), so they read as one group.
struct ReorderExercisesSheet: View {
    @ObservedObject private var store = WorkoutStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let a = store.active {
                    let marks = Self.marks(a.workout)
                    ForEach(a.workout.exercises) { e in row(e, mark: marks[e.id]) }
                        .onMove { from, to in store.moveExercise(from: from, to: to) }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(PaperFill().ignoresSafeArea())
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Paper.ink)
        .preferredColorScheme(.light)
        .presentationDragIndicator(.visible)
    }

    /// "Lat pulldown  1/3", "5a Lateral raise  0/3": the work sets done of the work sets.
    private func row(_ e: LoggedExercise, mark: String?) -> some View {
        let work = e.sets.filter { $0.kind != .warmup }
        let name = Text(verbatim: store.exercise(e.exerciseId)?.name ?? e.exerciseId)
        let title = mark.map { Text(verbatim: $0 + " ").foregroundStyle(WorkoutStyle.quiet) + name } ?? name
        return HStack(spacing: 8) {
            title
                .workoutFont(16, .semibold)
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(verbatim: "\(work.filter(\.done).count)/\(work.count)")
                .workoutFont(14, .medium)
                .foregroundStyle(WorkoutStyle.quiet)
        }
        .frame(minHeight: 44)
        .listRowBackground(Paper.card)
        .accessibilityElement(children: .combine)
    }

    /// "5a", "5b" … for the members of a superset, numbered as the workout lists them (a superset at its first
    /// member's place); nothing for an exercise on its own.
    private static func marks(_ w: Workout) -> [UUID: String] {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var out: [UUID: String] = [:]
        var number = 0
        var placed = Set<Int>()
        for e in w.exercises {
            guard let g = e.superset else {
                number += 1
                continue
            }
            guard !placed.contains(g) else { continue }
            placed.insert(g)
            number += 1
            let members = w.exercises.filter { $0.superset == g }
            guard members.count > 1 else { continue }
            for (k, m) in members.enumerated() {
                out[m.id] = "\(number)\(letters[min(k, letters.count - 1)])"
            }
        }
        return out
    }
}

// MARK: - After Finish

/// The summary, pushed inside the running workout's sheet after Finish: a heading that says what it was ("Pull + legs ·
/// 84 min · 27 sets"), the new bests, per exercise what was done with the change since last time (a fall in the same
/// ink, never red) and what to do next time, a note, and Done. Going back keeps the workout running. `note` is the
/// draft to start from and `noteChanged` hears every change, so the caller can keep it over Back and Finish again.
struct FinishSummaryView: View {
    private static let moveUpWords = "Move up"

    /// Where a ladder stands for one line: on this exercise's step with one above, past it, or neither.
    private enum Rung {
        case canMove(String)        // the ladder's id
        case moved
        case neither
    }

    @ObservedObject private var store = WorkoutStore.shared
    private let workout: Workout
    private let summary: FinishSummary
    private let noteChanged: (String) -> Void
    private let done: (String) -> Void
    @State private var note: String
    /// Ladders moved up here, for the haptic.
    @State private var moves = 0
    @FocusState private var noteFocused: Bool

    init(workout: Workout, summary: FinishSummary, note: String = "",
         noteChanged: @escaping (String) -> Void = { _ in }, done: @escaping (String) -> Void) {
        self.workout = workout
        self.summary = summary
        self.noteChanged = noteChanged
        self.done = done
        _note = State(initialValue: note)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading
                if !summary.records.isEmpty { records }
                if !summary.lines.isEmpty { exercises }
                noteField
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PaperFill().ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { doneBar }
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: moves)
        .onChange(of: note) { _, text in noteChanged(text) }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: summary.heading)
                .workoutDisplay(22)
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if workout.deload {
                Text("Deload: fewer sets on purpose, so nothing is compared.")
                    .workoutFont(14, .medium)
                    .foregroundStyle(WorkoutStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: the new bests

    /// "• Lat pulldown 60 kg × 8", each with an accent dot.
    private var records: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("NEW BESTS")
            ForEach(Array(summary.records.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(WorkoutStyle.accent)
                        .frame(width: 8, height: 8)
                    Text(verbatim: r)
                        .workoutFont(16, .semibold)
                        .foregroundStyle(Paper.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "New best: \(r)"))
            }
        }
    }

    // MARK: per exercise

    private var exercises: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(summary.lines.enumerated()), id: \.offset) { i, line in
                if i > 0 {
                    Rectangle().fill(Paper.rule).frame(height: 1).accessibilityHidden(true)
                }
                lineRow(i, line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    /// The sets and the change, then what to do next time in bold.
    private func lineRow(_ i: Int, _ line: FinishLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Self.compared(line)
                .workoutFont(15, .semibold)
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let next = line.next { nextRow(i, next) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Pull-up 9 · 9 · 8, +2 reps": the change in the same ink as the sets, a fall too.
    private static func compared(_ line: FinishLine) -> Text {
        let sets = Text(verbatim: line.text)
        guard let change = line.change else { return sets }
        return sets + Text(verbatim: ", " + change).fontWeight(.regular)
    }

    /// "All sets at 10. Next time 28 kg", or "Ready for tuck reps?" with a Move up button in place of the words. Once
    /// the ladder stands past this exercise's step (moved up here, or before Back and Finish again) the question
    /// carries "Moved up"; with neither, the line is left out, so a question never stands without its answer.
    @ViewBuilder
    private func nextRow(_ i: Int, _ next: String) -> some View {
        if next.hasSuffix(Self.moveUpWords) {
            let question = String(next.dropLast(Self.moveUpWords.count)).trimmingCharacters(in: .whitespaces)
            switch rung(i) {
            case .canMove(let id):
                HStack(spacing: 10) {
                    if !question.isEmpty { nextText(question) }
                    Spacer(minLength: 8)
                    Button { moveUp(id) } label: {
                        Text("Move up").workoutFont(15)
                    }
                    .buttonStyle(RecompButtonStyle(filled: false))
                    .disabled(!store.available)
                }
                .transition(.opacity)
            case .moved:
                HStack(spacing: 10) {
                    if !question.isEmpty { nextText(question) }
                    Spacer(minLength: 8)
                    movedUp
                }
                .transition(.opacity)
            case .neither:
                EmptyView()
            }
        } else {
            nextText(next)
        }
    }

    private func nextText(_ text: String) -> some View {
        Text(verbatim: text)
            .workoutFont(14, .bold)
            .foregroundStyle(Paper.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "✓ Moved up": the check in the accent, the words in ink.
    private var movedUp: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(WorkoutStyle.accent)
            Text("Moved up")
                .workoutFont(14, .semibold)
                .foregroundStyle(Paper.ink)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// The exercise's step on its ladder in the workout (a line per exercise, in the workout's order): the current
    /// step when it is this exercise, else the first that is.
    private func rung(_ i: Int) -> Rung {
        guard workout.exercises.indices.contains(i), let id = workout.exercises[i].ladderId,
              let l = store.ladder(id), !l.steps.isEmpty else { return .neither }
        let exerciseId = workout.exercises[i].exerciseId
        let current = Ladders.current(l, state: store.state)
        let at: Int? = l.steps[current].exerciseId == exerciseId
            ? current : l.steps.firstIndex(where: { $0.exerciseId == exerciseId })
        guard let at else { return .neither }
        if current > at { return .moved }
        if current == at, at < l.steps.count - 1 { return .canMove(id) }
        return .neither
    }

    private func moveUp(_ id: String) {
        guard let l = store.ladder(id) else { return }
        let before = Ladders.current(l, state: store.state)
        withAnimation(.easeOut(duration: 0.2)) { store.moveUp(id) }
        if Ladders.current(l, state: store.state) != before { moves += 1 }      // else not saved: the button stays
    }

    // MARK: the note and Done

    /// A few lines that grow; the whole box takes the tap.
    private var noteField: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return TextField("Note", text: $note, axis: .vertical)
            .lineLimit(3...8)
            .focused($noteFocused)
            .workoutFont(16, .regular)
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .background { shape.fill(Paper.paper).onTapGesture { noteFocused = true } }
            .overlay(shape.stroke(noteFocused ? WorkoutStyle.accent : Paper.edge, lineWidth: 1.2)
                .allowsHitTesting(false))
    }

    /// One wide Done at the thumb: saves the workout with the note.
    private var doneBar: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return Button {
            done(note.trimmingCharacters(in: .whitespacesAndNewlines))
        } label: {
            Text("Done")
                .workoutFont(17)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(WorkoutStyle.accent, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(SessionPressStyle())
        .accessibilityHint("Saves the workout")
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(alignment: .top) {
            Paper.paper
                .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .tracking(0.6)
            .workoutFont(12)
            .foregroundStyle(Paper.ink)
            .accessibilityAddTraits(.isHeader)
    }
}
