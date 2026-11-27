import SwiftUI

// 0.42.6: "Be there at …" for one school day, on Your day / Your week and the school alarm's card. The rules are in
// `SchoolArrive` (tested); the plan and the alarm follow at once (`SchoolAlarm.setArrival`).

/// A day's "Be there at 10:50", to change for that day only; "Changed: be there 09:00 (class 11:00)" once you did.
struct ArriveRow: View {
    let day: String
    /// On the paper card (the classic look) instead of Your day's.
    var paper = false
    @ObservedObject private var school = SchoolAlarm.shared
    @State private var open = false

    private var planned: SchoolAlarm.Planned? { school.week.first { $0.day == day } }

    var body: some View {
        if let p = planned {
            let at: Date = school.arrival(day) ?? school.timetableBeThere(p)
            let changed: String? = school.changedLine(day)
            let done: Bool = p.rang || p.classStart <= Date()
            let ink: Color = paper ? Paper.ink : DS.text
            let soft: Color = paper ? Paper.muted : DS.secondary
            let mark: Color = paper ? Paper.navy : DS.accentText
            let note: Color = changed != nil ? mark : soft
            let big: Font = paper ? BoardInk.sans(13) : DS.subStrong
            let small: Font = paper ? BoardInk.sans(11, .regular) : DS.footnote
            Button { open = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.subheadline.weight(.semibold))
                        .foregroundStyle(mark)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Be there at \(Fmt.hhmm(at))").font(big).monospacedDigit().foregroundStyle(ink)
                        Text(changed ?? "As your timetable says · change it for this day")
                            .font(small).monospacedDigit().foregroundStyle(note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if !done {
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold))
                            .foregroundStyle(soft).accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(done)
            .accessibilityHint("Change when you want to be there, this day only")
            .sheet(isPresented: $open) {
                ArriveSheet(day: day).presentationDetents([.medium, .large])
            }
        }
    }
}

/// Be there at …: a time, the quick choices, no alarm this day, back to the timetable.
struct ArriveSheet: View {
    let day: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var school = SchoolAlarm.shared
    @State private var time = Date()
    @State private var ready = false

    private var planned: SchoolAlarm.Planned? { school.week.first { $0.day == day } }

    var body: some View {
        NavigationStack {
            Form {
                if let p = planned {
                    let tt: Date = school.timetableBeThere(p)
                    pickSection(p, timetable: tt)
                    quickSection(timetable: tt)
                    otherSection(p)
                } else {
                    Text("This day has no class planned any more.").foregroundStyle(DS.secondary)
                }
            }
            .navigationTitle("Be there at")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear {
                guard !ready, let p = planned else { return }
                ready = true
                time = school.arrival(day) ?? school.timetableBeThere(p)
            }
        }
    }

    private func dayRange(_ p: SchoolAlarm.Planned) -> ClosedRange<Date> {
        let cal = Calendar.current
        let start: Date = cal.startOfDay(for: p.classStart)
        let end: Date = start.addingTimeInterval(24 * 3600 - 60)
        return start...end
    }

    @ViewBuilder private func pickSection(_ p: SchoolAlarm.Planned, timetable tt: Date) -> some View {
        let title: String = DayTimeline.title(p.classStart, now: Date(), cal: Calendar.current)
        Section {
            DatePicker("Be there at", selection: $time, in: dayRange(p), displayedComponents: .hourAndMinute)
            Button("Plan for \(Fmt.hhmm(time))") {
                school.setArrival(day, time)
                dismiss()
            }
            .font(DS.bodyStrong)
        } header: {
            Text("\(title) · first class \(Fmt.hhmm(p.classStart))")
        } footer: {
            Text("Your timetable: be there \(Fmt.hhmm(tt)). The trip and your wake-up alarm are planned again for the time you pick, for this day only.")
        }
    }

    private func quickSection(timetable tt: Date) -> some View {
        Section {
            ForEach(SchoolArrive.Quick.allCases, id: \.self) { q in
                Button {
                    school.setArrival(day, quick: q)
                    dismiss()
                } label: {
                    HStack {
                        Text(q.title).foregroundStyle(DS.text)
                        Spacer()
                        Text("be there \(Fmt.hhmm(SchoolArrive.quick(q, timetable: tt)))").monospacedDigit().foregroundStyle(DS.secondary)
                    }
                }
            }
        } header: {
            Text("Quick")
        }
    }

    private func otherSection(_ p: SchoolAlarm.Planned) -> some View {
        Section {
            Toggle("No alarm this day", isOn: Binding(get: { school.isSkipped(day) }, set: { school.setSkipped(day, $0) }))
                .tint(DS.accent)
                .disabled(p.rang)
            Button("Reset to timetable") {
                school.setArrival(day, nil)
                dismiss()
            }
            .disabled(school.arrival(day) == nil)
        } footer: {
            if let w = school.goingWords(day) {
                Text("Its alarm was taken off: you were \(w). Turn it back on above if you still want it.")
            }
        }
    }
}
