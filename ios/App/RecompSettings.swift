import SwiftUI

/// Goal, calorie limit, sources and habits. Every change is saved straight away.
struct RecompSettingsView: View {
    private let store = RecompStore.shared
    @State private var goal: Double
    @State private var kcalLimit: Double
    @State private var followsWeight: Bool
    @State private var notify: Bool
    @State private var sources: [ProteinSource]
    @State private var habits: [Habit]

    init() {
        let store = RecompStore.shared
        let data = store.data
        _goal = State(initialValue: data.goal)
        _kcalLimit = State(initialValue: store.kcalLimit)
        _followsWeight = State(initialValue: data.calories.followsWeight)
        _notify = State(initialValue: data.calories.notify)
        _sources = State(initialValue: data.sources)
        _habits = State(initialValue: data.habits)
    }

    var body: some View {
        Form {
            goalSection
            kcalSection
            sourcesSection
            habitsSection
        }
        .tint(RecompStyle.accent)
        .navigationTitle("Recomp settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onChange(of: goal) { store.setGoal(goal) }
        .onChange(of: kcalLimit) { store.setKcalLimit(kcalLimit) }
        .onChange(of: followsWeight) { store.setKcalFollowsWeight(followsWeight) }
        .onChange(of: notify) { store.setKcalNotify(notify) }
        .onChange(of: sources) { store.saveSources(sources) }
        .onChange(of: habits) { store.saveHabits(habits) }
    }

    // MARK: goal

    private var goalSection: some View {
        Section("Daily protein goal") {
            Stepper(value: $goal, in: 100...250, step: 5) {
                Text("\(Int(goal.rounded())) g")
                    .monospacedDigit()
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(minHeight: 44)
        }
    }

    // MARK: calories

    /// The limit, set by hand with − and +; it moves with the week average when that's on.
    private var kcalSection: some View {
        Section {
            Stepper(value: $kcalLimit, in: KcalMath.limitRange, step: KcalMath.limitStep) {
                Text(verbatim: "\(KcalMath.number(kcalLimit)) kcal" + (followsWeight ? " · moves with your weight" : ""))
                    .monospacedDigit()
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2).minimumScaleFactor(0.8)
            }
            .frame(minHeight: 44)
            Toggle("Move with my weight", isOn: $followsWeight)
                .frame(minHeight: 44)
            Toggle("Notify me at my limit", isOn: $notify)
                .frame(minHeight: 44)
        } header: {
            Text("Daily calorie limit")
        } footer: {
            Text("Counts only what you log. With your weight, it moves 15 kcal for every kg of your week average.")
                .monospacedDigit()
        }
    }

    // MARK: sources

    private var sourcesSection: some View {
        Section {
            // By id, not `ForEach($sources)`: a field still typing in a row being deleted must not reach for an
            // index that is gone.
            ForEach(sources) { s in
                SourceEditor(source: binding(for: s))
            }
            .onDelete { sources.remove(atOffsets: $0) }
            .onMove { sources.move(fromOffsets: $0, toOffset: $1) }
            Button {
                sources.append(ProteinSource(name: "New", unit: "portion", units: "portions",
                                             gramsPerUnit: 10, step: 1, kcalPerUnit: 0))
            } label: {
                Label("Add source", systemImage: "plus")
                    .frame(minHeight: 44, alignment: .leading)
            }
            .disabled(sources.count >= RecompData.maxSources)
        } header: {
            Text("Sources")
        } footer: {
            if sources.count >= RecompData.maxSources {
                Text("Up to \(RecompData.maxSources) sources. Remove one to add another.").monospacedDigit()
            }
        }
    }

    // MARK: habits

    private var habitsSection: some View {
        Section {
            ForEach(habits) { h in
                TextField("Habit", text: title(for: h))
                    .frame(minHeight: 44)
            }
            .onDelete { habits.remove(atOffsets: $0) }
            .onMove { habits.move(fromOffsets: $0, toOffset: $1) }
            Button {
                habits.append(Habit(title: "New habit"))
            } label: {
                Label("Add habit", systemImage: "plus")
                    .frame(minHeight: 44, alignment: .leading)
            }
            .disabled(habits.count >= RecompData.maxHabits)
        } header: {
            Text("Habits")
        } footer: {
            if habits.count >= RecompData.maxHabits {
                Text("Up to \(RecompData.maxHabits) habits.").monospacedDigit()
            }
        }
    }

    // MARK: bindings by id

    /// The source with that id. Once it's deleted, reads give the last value and writes do nothing.
    private func binding(for source: ProteinSource) -> Binding<ProteinSource> {
        let id = source.id
        return Binding(
            get: { sources.first { $0.id == id } ?? source },
            set: { new in
                if let i = sources.firstIndex(where: { $0.id == id }) { sources[i] = new }
            })
    }

    /// The habit's title, the same way.
    private func title(for habit: Habit) -> Binding<String> {
        let id = habit.id
        return Binding(
            get: { habits.first { $0.id == id }?.title ?? habit.title },
            set: { new in
                if let i = habits.firstIndex(where: { $0.id == id }) { habits[i].title = new }
            })
    }
}

/// One source. The grams and kcal fields keep their own text, so a half-typed number never fights the store.
private struct SourceEditor: View {
    @Binding var source: ProteinSource
    @State private var gramsText: String
    @State private var kcalText: String

    init(source: Binding<ProteinSource>) {
        _source = source
        _gramsText = State(initialValue: Self.text(source.wrappedValue.gramsPerUnit))
        _kcalText = State(initialValue: Self.text(source.wrappedValue.kcalPerUnit.rounded()))
    }

    private static func text(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Name", text: $source.name)
                .font(.system(size: 17, weight: .semibold))
                .frame(minHeight: 44)
            TextField("Unit (singular)", text: $source.unit)
                .frame(minHeight: 44)
            TextField("Plural", text: $source.units)
                .frame(minHeight: 44)
            HStack {
                Text("Protein per \(source.unit.isEmpty ? "unit" : source.unit)")
                    .foregroundStyle(RecompStyle.quiet)
                Spacer(minLength: 8)
                TextField("g", text: $gramsText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 80)
                Text("g").foregroundStyle(RecompStyle.quiet)
            }
            .frame(minHeight: 44)
            .onChange(of: gramsText) {
                if let g = RecompInput.protein(gramsText) { source.gramsPerUnit = g }
            }
            HStack {
                Text("Calories per \(source.unit.isEmpty ? "unit" : source.unit)")
                    .foregroundStyle(RecompStyle.quiet)
                Spacer(minLength: 8)
                TextField("kcal", text: $kcalText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 80)
                Text("kcal").foregroundStyle(RecompStyle.quiet)
            }
            .frame(minHeight: 44)
            .onChange(of: kcalText) {
                if let k = RecompInput.kcal(kcalText) { source.kcalPerUnit = k }
            }
            Picker("Step", selection: $source.step) {
                Text("¼").tag(0.25)
                Text("½").tag(0.5)
                Text("1").tag(1.0)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
        }
        .padding(.vertical, 4)
    }
}
