import SwiftUI

/// Goal, sources and habits. Every change is saved straight away.
struct RecompSettingsView: View {
    private let store = RecompStore.shared
    @State private var goal: Double
    @State private var sources: [ProteinSource]
    @State private var habits: [Habit]

    init() {
        let data = RecompStore.shared.data
        _goal = State(initialValue: data.goal)
        _sources = State(initialValue: data.sources)
        _habits = State(initialValue: data.habits)
    }

    var body: some View {
        Form {
            goalSection
            sourcesSection
            habitsSection
        }
        .tint(RecompStyle.accent)
        .navigationTitle("Goal, sources and habits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onChange(of: goal) { store.setGoal(goal) }
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

    // MARK: sources

    private var sourcesSection: some View {
        Section {
            ForEach($sources) { $source in
                SourceEditor(source: $source)
            }
            .onDelete { sources.remove(atOffsets: $0) }
            .onMove { sources.move(fromOffsets: $0, toOffset: $1) }
            Button {
                sources.append(ProteinSource(name: "New", unit: "portion", units: "portions",
                                             gramsPerUnit: 10, step: 1))
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
            ForEach($habits) { $habit in
                TextField("Habit", text: $habit.title)
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
}

/// One source. The grams field keeps its own text, so a half-typed number never fights the store.
private struct SourceEditor: View {
    @Binding var source: ProteinSource
    @State private var gramsText: String

    init(source: Binding<ProteinSource>) {
        _source = source
        _gramsText = State(initialValue: Self.text(source.wrappedValue.gramsPerUnit))
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
