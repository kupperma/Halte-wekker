import SwiftUI
import Combine
import UserNotifications

// MARK: - The rest-over notification

/// The notification at the end of a rest: "Rest over", and what's next. It follows the running workout: each new rest
/// replaces it, and it goes when the rest or the workout does. Without permission it simply never shows.
@MainActor
final class WorkoutAlerts {
    static let shared = WorkoutAlerts()

    /// What was last asked for: one rest's end, with the words and the sound for it.
    private struct Planned: Equatable {
        var ends: Date
        var body: String
        var sound: Bool
    }

    private weak var store: WorkoutStore?
    private var watching: AnyCancellable?
    private var last: Planned?
    private var asked = false

    private init() {}

    /// Follows the store's running workout from now on. Calling it again changes nothing.
    func attach(_ store: WorkoutStore) {
        guard watching == nil || self.store !== store else { return }
        self.store = store
        // @Published sends the new value just before it is set, so `follow` works from the value it is handed.
        watching = store.$active.sink { [weak self] a in self?.follow(a) }
    }

    /// Alerts and sounds, asked the first time the running workout is on screen (iOS asks the person only once).
    func askPermission() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func follow(_ a: ActiveWorkout?) {
        let center = UNUserNotificationCenter.current()
        guard let a else {
            last = nil
            center.removePendingNotificationRequests(withIdentifiers: [RestAlert.id])
            center.removeDeliveredNotifications(withIdentifiers: [RestAlert.id])
            return
        }
        guard let r = a.rest, let store else {
            last = nil
            center.removePendingNotificationRequests(withIdentifiers: [RestAlert.id])
            return
        }
        let now = Date()
        let alert = Planned(ends: r.ends, body: Self.body(Session.liveState(a, library: store.library, now: now)),
                          sound: store.state.settings.restSound)
        guard alert != last else { return }
        let left = r.ends.timeIntervalSince(now)
        // A rest that has run out was told already, and one long over (the app opened again later) has nothing to
        // tell. A rest cut to now (−15 at the end) is told at once.
        if left <= 0, last?.ends == r.ends || left < -2 { return }

        let content = UNMutableNotificationContent()
        content.title = "Rest over"
        content.body = alert.body
        content.sound = alert.sound ? UNNotificationSound.default : nil
        content.interruptionLevel = .active
        content.threadIdentifier = "workout"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, left), repeats: false)
        center.add(UNNotificationRequest(identifier: RestAlert.id, content: content, trigger: trigger)) { _ in }
        last = alert
    }

    /// "Next: Lat pulldown · set 3/3 · 57.5 × 8" ("warm-up 1/2" before a warm-up).
    private static func body(_ s: WorkoutLiveState) -> String {
        guard !s.allDone, !s.exercise.isEmpty else { return "" }
        var parts = ["Next: \(s.exercise)", "\(s.warmup ? "warm-up" : "set") \(s.setNumber)/\(s.setCount)"]
        if !s.plannedShort.isEmpty { parts.append(s.plannedShort) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Type that follows Dynamic Type

/// The app's own point sizes, grown or shrunk with Dynamic Type as the system's text styles are, with tabular digits.
struct WorkoutScaledFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let display: Bool
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 100
    @ScaledMetric(relativeTo: .title2) private var titleScale: CGFloat = 100

    func body(content: Content) -> some View {
        let s = size * (display ? titleScale : bodyScale) / 100
        return content.font((display ? HWFont.display(s) : BoardInk.sans(s, weight)).monospacedDigit())
    }
}

extension View {
    /// `BoardInk.sans(size, weight)` with tabular digits, following Dynamic Type.
    func workoutFont(_ size: CGFloat, _ weight: Font.Weight = .bold) -> some View {
        modifier(WorkoutScaledFont(size: size, weight: weight, display: false))
    }

    /// `HWFont.display(size)` with tabular digits, following Dynamic Type.
    func workoutDisplay(_ size: CGFloat) -> some View {
        modifier(WorkoutScaledFont(size: size, weight: .bold, display: true))
    }
}

// MARK: - The running workout

/// A set whose values are being changed. It is found again by its id when they are saved.
private struct SetEdit: Identifiable {
    let id: UUID
    let exercise: Exercise
    let set: LoggedSet
    let step: Double
}

/// A hold being timed.
private struct Stopwatch: Equatable {
    let setId: UUID
    let start: Date
}

/// What the list scrolls to: the open exercise, and the next set in it.
private struct ScrollKey: Equatable {
    var block: UUID?
    var set: UUID?
}

/// One exercise as the list shows it, or a superset's members together at the first one's place (as `Session.order`).
private struct SessionBlock: Identifiable {
    let id: UUID                    // the first member's LoggedExercise.id
    let members: [Int]              // in `workout.exercises`
    let number: Int                 // from 1: the "5" of "5a/5b"
}

/// What the exercise picker is open for: adding one, or replacing the exercise with this id.
private struct PickerAsk: Identifiable {
    let id = UUID()
    let title: String
    let suggested: [String]
    let replacing: UUID?            // a LoggedExercise.id; nil: add
}

/// The note being written for an exercise of the workout.
private struct NoteAsk {
    let id: UUID                    // the LoggedExercise.id
    let name: String
}

/// An exercise with logged sets, asked about before it goes.
private struct RemoveAsk {
    let id: UUID                    // the LoggedExercise.id
    let name: String
    let logged: Int
}

/// The summary pushed after Finish: the workout as it would be saved, and the end time of that tap.
private struct FinishPage: Hashable {
    let id = UUID()
    let workout: Workout
    let summary: FinishSummary
    let end: Date
    /// The same moment on the uptime clock, for the double-tap guard (the wall clock can jump).
    let tapped = ProcessInfo.processInfo.systemUptime

    static func == (a: FinishPage, b: FinishPage) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// The running workout, as a large sheet that can't be swiped away. On top the exercise you're on, big, with a row per
/// set (last time, today's values, ✓); the other exercises folded up; at the thumb the rest and one Done for the next
/// set. Everything is saved with every tap. The workout changes as you go (the ⋯ by the exercise, a swipe or the set
/// number on a set, Add set, Add exercise, Reorder), and Finish shows the summary inside the sheet.
struct WorkoutSessionView: View {
    @ObservedObject private var store = WorkoutStore.shared
    @State private var confirmDiscard = false
    @State private var notSaved = false
    @State private var editing: SetEdit?
    /// The summary after Finish, pushed inside the sheet. Back keeps the workout running.
    @State private var finishing: FinishPage?
    @State private var picking: PickerAsk?
    @State private var reordering = false
    @State private var noteAsk: NoteAsk?
    @State private var noteText = ""
    @State private var removeAsk: RemoveAsk?
    /// Workouts saved from the summary, for the haptic.
    @State private var saved = 0
    /// The row that presses in under a done set.
    @State private var pressed: UUID?
    @State private var stopwatch: Stopwatch?
    /// "New best: 28 kg × 8", for 3 s.
    @State private var best: String?
    @State private var bests = 0
    /// Moved on when a rest runs out (and when the app comes back), so its bar goes.
    @State private var clock = Date()
    /// The last Done or ✓: a second Done this soon after is the same tap twice.
    @State private var lastDoneTap: Date?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            root
        }
        .tint(Paper.ink)                                // the summary's back button, the note's cursor
        .preferredColorScheme(.light)                   // ink on paper, the bars and the menus too
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sensoryFeedback(.impact(weight: .medium), trigger: doneCount, condition: { old, new in new > old })
        .sensoryFeedback(.success, trigger: bests)
        .sensoryFeedback(.success, trigger: saved)
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { store.discard() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("No work sets are logged.")
        }
        // the summary's Done couldn't write the history: the workout runs on, the summary and its note stay
        .alert("Can’t save this workout right now", isPresented: $notSaved) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Its sets are kept. Try again in a moment.")
        }
        .sheet(item: $editing) { e in
            SetValueSheet(exercise: e.exercise, set: e.set, step: e.step) { kg, reps, seconds in
                save(e.id, kg: kg, reps: reps, seconds: seconds)
            }
            .presentationDetents([.height(300)])
        }
        // no workout runs (finished, discarded, or gone in a reload): the sheet closes itself (Ruling W-28)
        .onChange(of: store.active == nil, initial: true) { _, gone in
            if gone { WorkoutNav.shared.session = false }
        }
        .onChange(of: store.active?.lastRecord) { _, record in
            if let record { showBest(record) }
        }
        .task(id: store.active?.rest?.ends) { await followRest() }
        // after the phone slept: a rest that ran out meanwhile goes at once
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { clock = Date() }
        }
        .task(id: bests) { await hideBest() }
        // on the outermost view, so a screen pushed inside never reads as the workout gone
        .onAppear {
            WorkoutNav.shared.screenAppeared()
            WorkoutAlerts.shared.attach(.shared)
            WorkoutAlerts.shared.askPermission()
            UIApplication.shared.isIdleTimerDisabled = store.state.settings.keepScreenOn
        }
        .onDisappear {
            WorkoutNav.shared.screenDisappeared()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// The list, and what changes it: the picker, the order, a note, a removal; the summary is pushed on top of it.
    private var root: some View {
        content
            .background(PaperFill().ignoresSafeArea())
            .navigationTitle(barTitle)                  // under the principal item; the summary's back button says it
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { topBar }
            .navigationDestination(item: $finishing) { page in
                FinishSummaryView(workout: page.workout, summary: page.summary,
                                  note: WorkoutNav.shared.noteDrafts[page.workout.id] ?? "",
                                  noteChanged: { WorkoutNav.shared.noteDrafts[page.workout.id] = $0 },
                                  done: { note in saveWorkout(note: note, page: page) })
            }
            .sheet(item: $picking) { ask in
                ExercisePicker(title: ask.title, suggested: ask.suggested) { id in picked(ask, id) }
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $reordering) {
                ReorderExercisesSheet()
                    .presentationDetents([.medium, .large])
            }
            .alert("Note", isPresented: noteShown, presenting: noteAsk) { ask in
                TextField("Note", text: $noteText)
                Button("Save") { saveNote(ask.id) }
                Button("Cancel", role: .cancel) {}
            } message: { ask in
                Text(verbatim: ask.name)
            }
            .confirmationDialog(removeTitle, isPresented: removeShown, titleVisibility: .visible,
                                presenting: removeAsk) { ask in
                Button("Remove", role: .destructive) { remove(ask.id) }
                Button("Keep it", role: .cancel) {}
            } message: { ask in
                Text(verbatim: ask.logged == 1 ? "Its logged set goes too." : "Its \(ask.logged) logged sets go too.")
            }
    }

    @ViewBuilder private var content: some View {
        if let a = store.active {
            running(a)
        } else {
            Color.clear
        }
    }

    private var barTitle: String { store.active?.workout.title ?? "" }

    private var noteShown: Binding<Bool> {
        Binding(get: { noteAsk != nil }, set: { if !$0 { noteAsk = nil } })
    }

    private var removeShown: Binding<Bool> {
        Binding(get: { removeAsk != nil }, set: { if !$0 { removeAsk = nil } })
    }

    private var removeTitle: String { removeAsk.map { "Remove \($0.name)?" } ?? "" }

    // MARK: the top bar

    @ToolbarContentBuilder private var topBar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { WorkoutNav.shared.session = false } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Paper.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Minimize")
        }
        ToolbarItem(placement: .principal) {
            if let a = store.active {
                (Text(verbatim: "\(a.workout.title) · ") + Text(a.workout.start, style: .timer))
                    .workoutFont(17)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)     // the bar doesn't grow
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { reordering = true } label: { Label("Reorder", systemImage: "arrow.up.arrow.down") }
                    .disabled((store.active?.workout.exercises.count ?? 0) < 2)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Paper.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(store.active == nil)
            .accessibilityLabel("Workout options")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: finish) {
                Text("Finish")
                    .workoutFont(17)
                    .foregroundStyle(WorkoutStyle.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(store.active == nil)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
        }
    }

    // MARK: the list

    private func running(_ a: ActiveWorkout) -> some View {
        let next = Session.next(a)
        let blocks = Self.blocks(a.workout)
        let open = Self.openIndex(a, next: next)
        let openId = open.flatMap { i in blocks.first { $0.members.contains(i) } }?.id
        let nextId = next.map { a.workout.exercises[$0.exercise].sets[$0.set].id }
        let flagged = store.flagged
        let started = a.workout.exercises.contains { $0.sets.contains(where: \.done) }
        return ScrollViewReader { proxy in
            List {
                if !started {
                    Text("Warm up 5 min")
                        .workoutFont(15, .semibold)
                        .foregroundStyle(Paper.ink)
                        .padding(.horizontal, 8)
                        .sessionRow(top: 12)
                }
                ForEach(blocks) { b in
                    if b.id == openId {
                        openRows(b, a, next: next, flagged: flagged)
                    } else {
                        foldedRow(b, a)
                    }
                }
                ForEach(a.closed) { c in
                    SessionClosedRow(name: exercise(c.exerciseId).name, reason: c.reason) {
                        withAnimation(.easeOut(duration: 0.25)) { store.addClosed(c.id) }
                    }
                    .sessionRow(top: 2, bottom: 2)
                }
                SessionAddRow(title: "Add exercise", spoken: "Add an exercise", action: askAdd)
                    .sessionRow(top: 6, bottom: 16)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(a, next: next) }
            // the exercise you're on goes to the top whenever the next set moves to another one; within it, the next
            // set moves up into view when the bar would cover it
            .onChange(of: ScrollKey(block: openId, set: nextId), initial: true) { old, key in
                guard let id = key.block else { return }
                if old == key {
                    // on opening: only when it isn't the first, so "Warm up 5 min" stays in view
                    guard id != blocks.first?.id else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
                } else if old.block != id {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                } else if let row = key.set, row != old.set {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(row) }
                }
            }
        }
    }

    /// The open exercise (each member of an open superset): its head, the column names and a row per set.
    private func openRows(_ b: SessionBlock, _ a: ActiveWorkout, next: SessionCursor?, flagged: [String]) -> some View {
        ForEach(Array(b.members.enumerated()), id: \.element) { k, i in
            memberRows(b, k: k, i: i, a, next: next, flagged: flagged)
        }
    }

    @ViewBuilder
    private func memberRows(_ b: SessionBlock, k: Int, i: Int, _ a: ActiveWorkout, next: SessionCursor?,
                            flagged: [String]) -> some View {
        let e = a.workout.exercises[i]
        let info = exercise(e.exerciseId)
        let places = Self.places(e)
        let rir = Self.rir(e.target)
        HStack(alignment: .top, spacing: 0) {
            SessionExerciseHead(mark: b.members.count > 1 ? "\(b.number)\(Self.letter(k))" : nil,
                                name: info.name,
                                ladder: ladderLine(e),
                                target: e.target.map { WorkoutFormat.target($0, info.kind) },
                                notes: notes(e),
                                plates: platesLine(e, info),
                                flagged: flagged.contains(e.exerciseId))
            exerciseMenu(e, name: info.name)
        }
        .id(e.id)
        .sessionRow(top: k == 0 ? 14 : 22, bottom: 6)
        let work = e.sets.filter { $0.kind != .warmup }.count
        // the table keeps its columns side by side; the text around it grows on
        SessionColumnHead(kind: info.kind, rir: rir != nil)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .sessionRow(bottom: 2)
        ForEach(Array(e.sets.enumerated()), id: \.element.id) { j, s in
            setRow(SessionCursor(exercise: i, set: j), s, e, info, a, place: places[j], of: work, rir: rir, next: next)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .id(s.id)
                .sessionRow(bottom: 4)
                // a logged set takes a swipe and a tap; one not done yet goes with a full swipe
                .swipeActions(edge: .trailing, allowsFullSwipe: !s.done) {
                    Button(role: .destructive) { removeSet(s.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
        SessionAddRow(title: "Add set", spoken: "Add a set to \(info.name)") { addSet(e.id) }
            .sessionRow(bottom: 4)
    }

    /// The open exercise's ⋯: another exercise in its place, one more set, a note, or out of the workout.
    private func exerciseMenu(_ e: LoggedExercise, name: String) -> some View {
        Menu {
            Button { askReplace(e) } label: { Label("Replace…", systemImage: "arrow.left.arrow.right") }
            Button { addSet(e.id) } label: { Label("Add set", systemImage: "plus") }
            Button { askNote(e.id, name: name) } label: { Label("Note", systemImage: "square.and.pencil") }
            Button(role: .destructive) { askRemove(e.id, name: name) } label: {
                Label("Remove exercise", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Paper.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .menuStyle(.button)
        .buttonStyle(.plain)                            // only the dots take the tap, not the whole list row
        .accessibilityLabel("Options for \(name)")
    }

    private func setRow(_ c: SessionCursor, _ s: LoggedSet, _ e: LoggedExercise, _ info: Exercise, _ a: ActiveWorkout,
                        place: Int, of work: Int, rir: ClosedRange<Int>?, next: SessionCursor?) -> some View {
        let warm = s.kind == .warmup
        let last = Previous.row(a.previous[e.id.uuidString] ?? [], warmup: warm, number: place)
        let timing = stopwatch.flatMap { $0.setId == s.id ? $0.start : nil }
        return SessionSetRow(mark: Self.mark(s, place: place),
                             spokenMark: Self.spokenMark(s, place: place),
                             setName: Self.setName(s, place: place, of: work),
                             last: last.map { WorkoutFormat.set($0, info.kind, .short) },
                             set: s,
                             kind: info.kind,
                             current: c == next,
                             rir: rir,
                             pressed: pressed == s.id,
                             timing: timing,
                             edit: { edit(s, info) },
                             done: { complete(s.id) },
                             setRIR: { r in withAnimation(.easeOut(duration: 0.2)) { store.setRIR(c, r) } },
                             time: { toggleStopwatch(c, s) },
                             setKind: { k in setKind(s.id, k) })
    }

    /// "Seated cable row  0/3  last 50 × 10, 10, 9", "5a/5b Lateral raise + Rear delt fly  0/6", or a finished one
    /// with its sets.
    private func foldedRow(_ b: SessionBlock, _ a: ActiveWorkout) -> some View {
        let members = b.members.map { a.workout.exercises[$0] }
        let work = members.flatMap { $0.sets.filter { $0.kind != .warmup } }
        let finished = members.allSatisfy { !$0.sets.isEmpty && $0.sets.allSatisfy(\.done) }
        var detail: [String] = []
        if finished {
            detail = members.map { e -> String in
                let kind = exercise(e.exerciseId).kind
                return e.sets.filter(\.counts).map { WorkoutFormat.set($0, kind, .compact) }.joined(separator: " · ")
            }
            .filter { !$0.isEmpty }
        } else if members.count == 1,
                  let last = Self.lastLine(a.previous[members[0].id.uuidString] ?? [],
                                           kind: exercise(members[0].exerciseId).kind) {
            detail = ["last \(last)"]
        }
        let marks = members.count > 1
            ? members.indices.map { "\(b.number)\(Self.letter($0))" }.joined(separator: "/") : nil
        return SessionFoldedRow(mark: marks,
                                title: members.map { exercise($0.exerciseId).name }.joined(separator: " + "),
                                count: "\(work.filter(\.done).count)/\(work.count)",
                                detail: detail,
                                finished: finished) {
            withAnimation(.easeOut(duration: 0.25)) { store.focus(b.members[0]) }
        }
        .id(b.id)
        .sessionRow(top: 2, bottom: 2)
    }

    // MARK: the bottom bar

    /// Where the thumb is: "New best" for a moment, the rest while it runs, and Done for the next set.
    private func bottomBar(_ a: ActiveWorkout, next: SessionCursor?) -> some View {
        VStack(spacing: 10) {
            if let best {
                Text(verbatim: best)
                    .workoutFont(15)
                    .foregroundStyle(WorkoutStyle.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
            }
            if let r = a.rest, r.ends > clock {
                SessionRestBar(rest: r, adjust: { s in
                    withAnimation(.easeOut(duration: 0.2)) { store.adjustRest(by: s) }
                }, skip: {
                    withAnimation(.easeOut(duration: 0.25)) { store.skipRest() }
                })
                .transition(.opacity)
            }
            doneButton(a, next: next)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(alignment: .top) {
            Paper.paper
                .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// "Set 2 of 3 · 57.5 kg × 8 · Done"; "All sets done · Finish" when nothing is left.
    private func doneButton(_ a: ActiveWorkout, next: SessionCursor?) -> some View {
        let label = Session.doneLabel(a, library: store.library)
        let hasSets = a.workout.exercises.contains { !$0.sets.isEmpty }
        let lead = label ?? (hasSets ? "All sets done" : "")
        let action = label == nil ? "Finish" : "Done"
        // the set this button shows now: a tap logs that one, never the one after it
        let shown = next.map { a.workout.exercises[$0.exercise].sets[$0.set].id }
        return Button {
            guard doneTapAllowed() else { return }
            if let shown { completeNext(shown) } else { finish() }
        } label: {
            HStack(spacing: 12) {
                if !lead.isEmpty {
                    Text(verbatim: lead)
                        .contentTransition(.numericText())
                        .lineLimit(2).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(verbatim: action)
                    .frame(maxWidth: lead.isEmpty ? CGFloat.infinity : nil)
            }
            .workoutFont(17)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(WorkoutStyle.accent, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(SessionPressStyle())
        .accessibilityLabel(lead.isEmpty ? action : "\(lead), \(action)")
    }

    // MARK: actions

    /// The ✓ in a row: that very set (found by its id) with the values it shows, a running stopwatch's time for a
    /// hold. Nothing when it is done already.
    private func complete(_ id: UUID) {
        lastDoneTap = Date()
        guard let c = cursor(of: id), let a = store.active, !a.workout.exercises[c.exercise].sets[c.set].done else {
            return
        }
        var timed: Int?
        if let w = stopwatch, w.setId == id {
            timed = Self.seconds(since: w.start)
            stopwatch = nil
        }
        press(id)
        withAnimation(.easeOut(duration: 0.25)) { store.complete(c, kg: nil, reps: nil, seconds: timed) }
    }

    /// Done: the set the button showed, as suggested, only while it is still the next one (Ruling W-20).
    private func completeNext(_ id: UUID) {
        if stopwatch?.setId == id {
            complete(id)
            return
        }
        press(id)
        withAnimation(.easeOut(duration: 0.25)) { _ = store.completeNext(setId: id) }
    }

    /// Done and Finish at the bottom take no tap within 0.6 s of the last Done or ✓, so a double tap logs one set
    /// (and never logs the last set and finishes too).
    private func doneTapAllowed() -> Bool {
        let now = Date()
        if let last = lastDoneTap, now.timeIntervalSince(last) < 0.6 { return false }
        lastDoneTap = now
        return true
    }

    /// The row gives under the thumb: in and out again in 0.2 s.
    private func press(_ id: UUID) {
        pressed = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            if pressed == id { pressed = nil }
        }
    }

    /// Without a done work set there is nothing to save: discard it, or keep going. Otherwise the summary, pushed inside
    /// the sheet, ending at this tap; its Done saves the workout.
    private func finish() {
        guard let a = store.active, finishing == nil else { return }
        let end = Date()
        guard let w = Session.finished(a, end: end, note: "") else {
            confirmDiscard = true
            return
        }
        let summary = Session.summary(w, before: store.index, library: store.library, ladders: store.ladders,
                                      state: store.state)
        finishing = FinishPage(workout: w, summary: summary, end: end)
    }

    /// The summary's Done. Saved: the sheet closes. A second tap finds nothing running and does nothing, and a tap
    /// within 0.6 s of Finish is the Finish tap twice (Done sits where "All sets done · Finish" was). When the history
    /// can't be written the workout runs on, and the summary stays with its note.
    private func saveWorkout(note: String, page: FinishPage) {
        guard ProcessInfo.processInfo.systemUptime - page.tapped >= 0.6, store.active != nil else { return }
        if store.finish(note: note, end: page.end) == nil {
            notSaved = true
        } else {
            WorkoutNav.shared.noteDrafts[page.workout.id] = nil
            saved += 1
            WorkoutNav.shared.session = false
        }
    }

    // MARK: changing the workout

    private func exerciseIndex(_ id: UUID) -> Int? {
        store.active?.workout.exercises.firstIndex { $0.id == id }
    }

    private func addSet(_ exercise: UUID) {
        guard let i = exerciseIndex(exercise) else { return }
        withAnimation(.easeOut(duration: 0.2)) { store.addSet(exercise: i) }
    }

    private func removeSet(_ id: UUID) {
        guard let c = cursor(of: id) else { return }
        if stopwatch?.setId == id { stopwatch = nil }
        withAnimation(.easeOut(duration: 0.25)) { store.removeSet(c) }
    }

    private func setKind(_ id: UUID, _ kind: SetKind) {
        guard let c = cursor(of: id) else { return }
        withAnimation(.easeOut(duration: 0.2)) { store.setKind(c, kind) }
    }

    private func askReplace(_ e: LoggedExercise) {
        picking = PickerAsk(title: "Replace", suggested: alternatives(e), replacing: e.id)
    }

    private func askAdd() {
        picking = PickerAsk(title: "Add exercise", suggested: [], replacing: nil)
    }

    /// Replacing it with itself changes nothing.
    private func picked(_ ask: PickerAsk, _ id: String) {
        if let old = ask.replacing {
            guard let i = exerciseIndex(old), store.active?.workout.exercises[i].exerciseId != id else { return }
            withAnimation(.easeOut(duration: 0.25)) { store.replaceExercise(i, with: id) }
        } else {
            withAnimation(.easeOut(duration: 0.25)) { store.addExercise(id) }
        }
    }

    private func askNote(_ id: UUID, name: String) {
        guard let i = exerciseIndex(id), let e = store.active?.workout.exercises[i] else { return }
        noteText = e.note
        noteAsk = NoteAsk(id: id, name: name)
    }

    private func saveNote(_ id: UUID) {
        guard let i = exerciseIndex(id) else { return }
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.easeOut(duration: 0.2)) { store.setExerciseNote(i, text) }
    }

    /// Asked first only when it holds logged sets.
    private func askRemove(_ id: UUID, name: String) {
        guard let i = exerciseIndex(id), let e = store.active?.workout.exercises[i] else { return }
        let logged = e.sets.filter(\.done).count
        if logged == 0 {
            remove(id)
        } else {
            removeAsk = RemoveAsk(id: id, name: name, logged: logged)
        }
    }

    private func remove(_ id: UUID) {
        guard let i = exerciseIndex(id), let e = store.active?.workout.exercises[i] else { return }
        if let w = stopwatch, e.sets.contains(where: { $0.id == w.setId }) { stopwatch = nil }
        withAnimation(.easeOut(duration: 0.25)) { store.removeExercise(i) }
    }

    /// "From your program" when replacing: the routine item's exercise and its alternatives, or the ladder's steps,
    /// without the exercise there now. One added during the workout finds its item in any routine.
    private func alternatives(_ e: LoggedExercise) -> [String] {
        var ids: [String] = []
        if let l = e.ladderId.flatMap({ store.ladder($0) }) {
            ids = l.steps.map(\.exerciseId)
        } else {
            let items = (store.routines.filter { $0.id == e.routineId } + store.routines).flatMap(\.items)
            let item = items.first { $0.exerciseId == e.exerciseId || $0.alternatives.contains(e.exerciseId) }
            if let item { ids = [item.exerciseId].compactMap { $0 } + item.alternatives }
        }
        var seen: Set<String> = [e.exerciseId]
        return ids.filter { seen.insert($0).inserted }
    }

    private func edit(_ s: LoggedSet, _ info: Exercise) {
        editing = SetEdit(id: s.id, exercise: info, set: s, step: Progression.step(info, settings: store.state.settings))
    }

    private func save(_ id: UUID, kg: Double?, reps: Int?, seconds: Int?) {
        guard let c = cursor(of: id) else { return }
        withAnimation(.easeOut(duration: 0.2)) { store.edit(c, kg: kg, reps: reps, seconds: seconds) }
    }

    /// Where the set with this id is now.
    private func cursor(of id: UUID) -> SessionCursor? {
        guard let a = store.active else { return nil }
        for (i, e) in a.workout.exercises.enumerated() {
            if let j = e.sets.firstIndex(where: { $0.id == id }) { return SessionCursor(exercise: i, set: j) }
        }
        return nil
    }

    /// Start, then Stop fills in the seconds.
    private func toggleStopwatch(_ c: SessionCursor, _ s: LoggedSet) {
        if let w = stopwatch, w.setId == s.id {
            stopwatch = nil
            withAnimation(.easeOut(duration: 0.2)) {
                store.edit(c, kg: nil, reps: nil, seconds: Self.seconds(since: w.start))
            }
        } else {
            stopwatch = Stopwatch(setId: s.id, start: Date())
        }
    }

    private func showBest(_ text: String) {
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { best = text }
        bests += 1
    }

    private func hideBest() async {
        guard best != nil else { return }
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        withAnimation(.easeOut(duration: 0.25)) { best = nil }
    }

    /// Wakes when the rest runs out, so the rest bar goes. The continuous clock keeps counting while the phone
    /// sleeps; a rest end that makes no sense waits an hour at most.
    private func followRest() async {
        clock = Date()
        guard let ends = store.active?.rest?.ends else { return }
        let wait = min(3600, max(0, ends.timeIntervalSince(clock)))
        guard wait > 0 else { return }
        do { try await Task.sleep(for: .seconds(wait + 0.05)) } catch { return }
        withAnimation(.easeOut(duration: 0.25)) { clock = Date() }
    }

    // MARK: what the rows say

    private var doneCount: Int {
        store.active?.workout.exercises.reduce(0) { $0 + $1.sets.filter(\.done).count } ?? 0
    }

    private func exercise(_ id: String) -> Exercise {
        store.exercise(id) ?? Exercise(id: id, name: id)
    }

    /// "Dragon flag · tuck negatives (2 of 7)": the ladder's step that is this exercise.
    private func ladderLine(_ e: LoggedExercise) -> String? {
        guard let l = e.ladderId.flatMap({ store.ladder($0) }), !l.steps.isEmpty else { return nil }
        let current = Ladders.current(l, state: store.state)
        let at: Int? = l.steps[current].exerciseId == e.exerciseId
            ? current : l.steps.firstIndex { $0.exerciseId == e.exerciseId }
        return at.map { Ladders.title(l, step: $0) }
    }

    /// The program's note for it (the routine item's, the ladder step's), and the one made in this workout.
    private func notes(_ e: LoggedExercise) -> [String] {
        var out: [String] = []
        let item = store.routines.first { $0.id == e.routineId }?.items.first { item in
            item.exerciseId == e.exerciseId || (item.ladderId != nil && item.ladderId == e.ladderId)
        }
        if let n = item?.note, !n.isEmpty { out.append(n) }
        if let l = e.ladderId.flatMap({ store.ladder($0) }),
           let step = l.steps.first(where: { $0.exerciseId == e.exerciseId }), !step.note.isEmpty {
            out.append(step.note)
        }
        let own = e.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty, !out.contains(own) { out.append(own) }
        return out
    }

    /// "20 + 2 × 15" for the planned weight on a barbell.
    private func platesLine(_ e: LoggedExercise, _ info: Exercise) -> String? {
        guard info.equipment == .barbell, info.kind == .weight else { return nil }
        let work = e.sets.filter { $0.kind != .warmup }
        guard let kg = (work.first(where: { !$0.done }) ?? work.first)?.kg else { return nil }
        return Plates.text(kg)
    }

    /// The exercise shown open: the one picked (`store.focus`), else the one holding the next set.
    private static func openIndex(_ a: ActiveWorkout, next: SessionCursor?) -> Int? {
        if let f = a.focus, let i = a.workout.exercises.firstIndex(where: { $0.id == f }) { return i }
        return next?.exercise
    }

    private static func blocks(_ w: Workout) -> [SessionBlock] {
        var out: [SessionBlock] = []
        var placed = Set<Int>()
        for (i, e) in w.exercises.enumerated() {
            if let g = e.superset {
                guard !placed.contains(g) else { continue }
                placed.insert(g)
                let members = w.exercises.indices.filter { w.exercises[$0].superset == g }
                out.append(SessionBlock(id: e.id, members: members, number: out.count + 1))
            } else {
                out.append(SessionBlock(id: e.id, members: [i], number: out.count + 1))
            }
        }
        return out
    }

    /// Each set's place, from 0, among the exercise's warm-ups or among its work sets (as "Set 2 of 3" counts).
    private static func places(_ e: LoggedExercise) -> [Int] {
        var warm = 0, work = 0
        return e.sets.map { s -> Int in
            if s.kind == .warmup {
                warm += 1
                return warm - 1
            }
            work += 1
            return work - 1
        }
    }

    private static func mark(_ s: LoggedSet, place: Int) -> String {
        switch s.kind {
        case .warmup: return "W"
        case .drop: return "D"
        case .failure: return "F"
        case .normal: return "\(place + 1)"
        }
    }

    /// "set 2 of 3", "warm-up 1": what ✓ logs, for VoiceOver.
    private static func setName(_ s: LoggedSet, place: Int, of work: Int) -> String {
        s.kind == .warmup ? "warm-up \(place + 1)" : "set \(place + 1) of \(work)"
    }

    private static func spokenMark(_ s: LoggedSet, place: Int) -> String {
        switch s.kind {
        case .warmup: return "Warm-up \(place + 1)"
        case .drop: return "Drop set"
        case .failure: return "Failure set"
        case .normal: return "Set \(place + 1)"
        }
    }

    private static func rir(_ t: Target?) -> ClosedRange<Int>? {
        guard let lo = t?.rirLo else { return nil }
        return lo...max(lo, t?.rirHi ?? lo)
    }

    private static func letter(_ k: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return String(letters[min(max(0, k), letters.count - 1)])
    }

    /// "50 × 10, 10, 9": last time's work sets, the weight once when it stayed the same.
    private static func lastLine(_ sets: [LoggedSet], kind: ExerciseKind) -> String? {
        let work = sets.filter { $0.kind != .warmup }
        guard !work.isEmpty else { return nil }
        let parts = work.map { WorkoutFormat.set($0, kind, .short) }
        let loaded: Set<ExerciseKind> = [.weight, .weighted, .assisted]
        if loaded.contains(kind), work.count > 1, let kg = work[0].kg, parts[0].contains("×"),
           work.allSatisfy({ $0.kg == kg && $0.reps != nil }) {
            let reps = work.dropFirst().compactMap { $0.reps }.map { String($0) }
            return ([parts[0]] + reps).joined(separator: ", ")
        }
        return parts.joined(separator: ", ")
    }

    private static func seconds(since start: Date) -> Int {
        min(3600, max(1, Int(Date().timeIntervalSince(start).rounded())))
    }
}

// MARK: - The rows

private extension View {
    /// A row of the session list: no background or separator of its own, 8 pt in from the edges.
    func sessionRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 8, bottom: bottom, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// The widths the column names and the set rows share. They grow with Dynamic Type as a title does (about a fifth at
/// xxxLarge, the largest the table takes), so the last-time column keeps room on a 375 pt phone. ✓ stays 56 × 56 and
/// the stopwatch 44.
private struct SessionColumns: DynamicProperty {
    static let gap: CGFloat = 4
    static let watch: CGFloat = 44
    static let check: CGFloat = 56
    @ScaledMetric(relativeTo: .title) var set: CGFloat = 24
    @ScaledMetric(relativeTo: .title) var kg: CGFloat = 56
    @ScaledMetric(relativeTo: .title) var reps: CGFloat = 42
    @ScaledMetric(relativeTo: .title) var seconds: CGFloat = 62
    @ScaledMetric(relativeTo: .title) var rir: CGFloat = 54
}

/// The exercise you're on: its name, big, then the ladder step, the target, its notes, the plates and a fall in reps.
private struct SessionExerciseHead: View {
    let mark: String?               // "5a" in a superset
    let name: String
    let ladder: String?
    let target: String?
    let notes: [String]
    let plates: String?
    let flagged: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            title
                .workoutDisplay(26)
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let ladder { line(ladder, weight: .medium, color: Paper.ink) }
            if let target { line(target, weight: .semibold, color: Paper.ink) }
            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                line("\u{201C}\(n)\u{201D}", weight: .medium, color: WorkoutStyle.quiet)
            }
            if let plates { line(plates, weight: .medium, color: WorkoutStyle.quiet) }
            if flagged { line("Reps fell two sessions running.", weight: .medium, color: Paper.ink) }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var title: Text {
        let n = Text(verbatim: name)
        guard let mark else { return n }
        return Text(verbatim: mark + " ").foregroundStyle(WorkoutStyle.quiet) + n
    }

    private func line(_ text: String, weight: Font.Weight, color: Color) -> some View {
        Text(verbatim: text)
            .workoutFont(14, weight)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// SET  LAST TIME  KG  REPS, over the same widths as the rows.
private struct SessionColumnHead: View {
    let kind: ExerciseKind
    let rir: Bool
    var columns = SessionColumns()

    var body: some View {
        HStack(spacing: SessionColumns.gap) {
            name("SET").frame(width: columns.set, alignment: .leading)
            name("LAST TIME").frame(maxWidth: .infinity, alignment: .leading)
            switch kind {
            case .weight, .weighted, .assisted:
                name(kind == .weight ? "KG" : (kind == .weighted ? "+KG" : "HELP")).frame(width: columns.kg)
                name("REPS").frame(width: columns.reps)
            case .bodyweight:
                name("REPS").frame(width: columns.reps)
            case .time, .cardio:
                name(kind == .time ? "SECONDS" : "TIME").frame(width: columns.seconds)
                Color.clear.frame(width: SessionColumns.watch, height: 1)
            }
            if rir { Color.clear.frame(width: columns.rir, height: 1) }
            Color.clear.frame(width: SessionColumns.check, height: 1)
        }
        .padding(.horizontal, 8)
        .accessibilityHidden(true)
    }

    private func name(_ text: String) -> some View {
        Text(verbatim: text)
            .tracking(0.6)
            .workoutFont(11)
            .foregroundStyle(WorkoutStyle.quiet)
            .lineLimit(1).minimumScaleFactor(0.7)
    }
}

/// One set: its number, last time, today's values (a tap changes them), after ✓ the RIR, and ✓. The set that's next
/// is the only row that lights up.
private struct SessionSetRow: View {
    let mark: String                // "1", "W", "D", "F"
    let spokenMark: String
    let setName: String             // "set 2 of 3", "warm-up 1"
    let last: String?               // "55 × 12"
    let set: LoggedSet
    let kind: ExerciseKind
    let current: Bool
    let rir: ClosedRange<Int>?      // the target's; nil: no RIR for this exercise
    let pressed: Bool
    let timing: Date?               // the stopwatch's start, while it runs for this set
    let edit: () -> Void
    let done: () -> Void
    let setRIR: (Int?) -> Void
    let time: () -> Void
    let setKind: (SetKind) -> Void
    var columns = SessionColumns()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        HStack(spacing: SessionColumns.gap) {
            markMenu
            Text(verbatim: last ?? "—")
                .workoutFont(14, .medium)
                .foregroundStyle(WorkoutStyle.quiet)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)                // the set number's hit area reaches under it
                .accessibilityLabel(spokenLast)
            values
            if let rir {
                if set.done {
                    chip(rir)
                } else {
                    Color.clear.frame(width: columns.rir, height: 1)
                }
            }
            check
        }
        .padding(.horizontal, 8)
        .frame(minHeight: SessionColumns.check)
        .background { if current { shape.fill(Paper.card) } }
        .overlay { if current { shape.strokeBorder(WorkoutStyle.accent, lineWidth: 1.5).allowsHitTesting(false) } }
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .animation(.easeOut(duration: 0.2), value: current)
    }

    @ViewBuilder private var values: some View {
        switch kind {
        case .weight, .weighted, .assisted:
            value(kgText, width: columns.kg, spoken: "\(kgText) kilos")
            value(set.reps.map { String($0) } ?? "—", width: columns.reps,
                  spoken: set.reps.map { "\($0) reps" } ?? "No reps")
        case .bodyweight:
            value(set.reps.map { String($0) } ?? "—", width: columns.reps,
                  spoken: set.reps.map { "\($0) reps" } ?? "No reps")
        case .time, .cardio:
            if let start = timing {
                Text(timerInterval: start...start.addingTimeInterval(3600), countsDown: false)
                    .workoutFont(17, .semibold)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: columns.seconds, height: 44)
            } else {
                value(secondsText, width: columns.seconds,
                      spoken: set.seconds.map { "\($0) seconds" } ?? "No time")
            }
            if set.done {
                Color.clear.frame(width: SessionColumns.watch, height: 1)
            } else {
                watch
            }
        }
    }

    /// The set's number: a tap picks its type, as in Hevy. The hit area is 44 pt wide, reaching into the row's edge and
    /// the last-time column (text only) without moving them.
    private var markMenu: some View {
        Menu {
            ForEach(SetKind.allCases, id: \.self) { k in
                Button { setKind(k) } label: {
                    if set.kind == k {
                        Label(k.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: k.title)
                    }
                }
            }
        } label: {
            Text(verbatim: mark)
                .workoutFont(15)
                .foregroundStyle(set.kind == .warmup ? WorkoutStyle.quiet : Paper.ink)
                .frame(width: columns.set, alignment: .leading)
                .padding(.leading, 8).padding(.trailing, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .menuStyle(.button)
        .buttonStyle(.plain)                            // only the number takes the tap, not the whole list row
        .padding(.leading, -8).padding(.trailing, -12)
        .accessibilityLabel(spokenMark)
        .accessibilityHint("Change the set type")
    }

    private var spokenLast: String {
        guard let last else { return "Nothing last time" }
        return "Last time \(last)"
    }

    private var kgText: String {
        guard let kg = set.kg else { return "—" }
        let v = WorkoutFormat.kg(kg)
        switch kind {
        case .weighted: return kg > 0 ? "+" + v : v
        case .assisted: return kg > 0 ? "\u{2212}" + v : v
        default: return v
        }
    }

    private var secondsText: String {
        guard let s = set.seconds else { return "—" }
        return kind == .cardio ? WorkoutFormat.rest(s) : String(s)
    }

    /// A value: a tap opens the − / + sheet. Boxed on the set that's next, like a field.
    private func value(_ text: String, width: CGFloat, spoken: String) -> some View {
        let box = RoundedRectangle(cornerRadius: 4)
        return Button(action: edit) {
            Text(verbatim: text)
                .workoutFont(17, .semibold)
                .foregroundStyle(Paper.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .frame(width: width, height: 40)
                .background { if current { box.fill(Paper.paper) } }
                .overlay { if current { box.stroke(Paper.edge, lineWidth: 1) } }
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityHint("Change it")
    }

    private var watch: some View {
        Button(action: time) {
            Image(systemName: timing == nil ? "stopwatch" : "stop.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(timing == nil ? WorkoutStyle.accent : Paper.ink)
                .frame(width: SessionColumns.watch, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(timing == nil ? "Start the stopwatch" : "Stop the stopwatch")
    }

    /// "RIR 1–2" as planned, or what was tapped: 0, 1, 2, 3 or 4+.
    private func chip(_ range: ClosedRange<Int>) -> some View {
        let planned = range.lowerBound == range.upperBound
            ? "RIR \(range.lowerBound)" : "RIR \(range.lowerBound)–\(range.upperBound)"
        let text = set.rir.map { $0 >= 4 ? "RIR 4+" : "RIR \($0)" } ?? planned
        let spoken: String = set.rir == nil ? "Reps in reserve, as planned" : "Reps in reserve, " + text.dropFirst(4)
        return Menu {
            ForEach(0..<5, id: \.self) { n in
                Button { setRIR(n) } label: {
                    let title = n == 4 ? "4+" : "\(n)"
                    if set.rir.map({ min($0, 4) }) == n {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: title)
                    }
                }
            }
            Button { setRIR(nil) } label: {
                if set.rir == nil {
                    Label("As planned", systemImage: "checkmark")
                } else {
                    Text("As planned")
                }
            }
        } label: {
            Text(verbatim: text)
                .workoutFont(12, .semibold)
                .foregroundStyle(set.rir == nil ? WorkoutStyle.quiet : Paper.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 5)
                .frame(height: 26)
                .overlay(Capsule().stroke(Paper.edge, lineWidth: 1))
                .frame(width: columns.rir, height: 44)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .menuStyle(.button)
        .buttonStyle(.plain)                            // the row now holds two menus: each takes only its own taps
        .accessibilityLabel(spoken)
    }

    private var check: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let edge: Color = set.done ? .clear : (current ? WorkoutStyle.accent : Paper.edge)
        let ink: Color = set.done ? .white : (current ? WorkoutStyle.accent : WorkoutStyle.quiet)
        return Button(action: done) {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 42, height: 42)
                .background { if set.done { shape.fill(WorkoutStyle.accent) } }
                .overlay(shape.strokeBorder(edge, lineWidth: 1.5))
                .frame(width: SessionColumns.check, height: SessionColumns.check)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecompPressStyle())                // no fading when it is done and off
        .disabled(set.done)
        .accessibilityLabel(set.done ? "Logged \(setName)" : "Log \(setName)")
        .accessibilityAddTraits(set.done ? .isSelected : [])
    }
}

/// An exercise that isn't open: a tap opens it.
private struct SessionFoldedRow: View {
    let mark: String?               // "5a/5b"
    let title: String
    let count: String               // "0/3"
    let detail: [String]            // "last 50 × 10, 10, 9", or a finished one's sets
    let finished: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if finished {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(WorkoutStyle.accent)
                        .accessibilityLabel("Done")
                }
                VStack(alignment: .leading, spacing: 2) {
                    heading
                        .workoutFont(16, .semibold)
                        .foregroundStyle(Paper.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(detail.enumerated()), id: \.offset) { _, d in
                        Text(verbatim: d)
                            .workoutFont(13, .medium)
                            .foregroundStyle(WorkoutStyle.quiet)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if !finished {
                    Text(verbatim: count)
                        .workoutFont(15, .semibold)
                        .foregroundStyle(Paper.ink)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var heading: Text {
        let t = Text(verbatim: title)
        guard let mark else { return t }
        return Text(verbatim: mark + " ").foregroundStyle(WorkoutStyle.quiet) + t
    }
}

/// "Hammer curl · Skipped on leg days · Add": a tap puts it in the workout.
private struct SessionClosedRow: View {
    let name: String
    let reason: String
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack(spacing: 8) {
                Text(verbatim: "\(name) · \(reason)")
                    .workoutFont(14, .medium)
                    .foregroundStyle(WorkoutStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("Add")
                    .workoutFont(14, .semibold)
                    .foregroundStyle(Paper.ink)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(name). \(reason)")
    }
}

/// "+ Add set" under the open exercise's sets, "+ Add exercise" at the end: plain ink, at least 44 pt high.
private struct SessionAddRow: View {
    let title: String
    let spoken: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text(verbatim: title)
                    .workoutFont(15, .semibold)
            }
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
    }
}

/// "Rest 1:42", the bar filling as it runs, and −15, +15 and Skip.
private struct SessionRestBar: View {
    let rest: RestState
    let adjust: (Int) -> Void
    let skip: () -> Void

    var body: some View {
        let range = rest.started...max(rest.started, rest.ends)
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    time(range)
                    Spacer(minLength: 8)
                    buttons
                }
                VStack(alignment: .leading, spacing: 6) {
                    time(range)
                    HStack(spacing: 8) { buttons }
                }
            }
            ProgressView(timerInterval: range, countsDown: false, label: { EmptyView() },
                         currentValueLabel: { EmptyView() })
                .progressViewStyle(.linear)
                .tint(WorkoutStyle.accent)
                .accessibilityHidden(true)
        }
    }

    private func time(_ range: ClosedRange<Date>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Rest").workoutFont(15, .semibold).foregroundStyle(Paper.ink)
            Text(timerInterval: range, countsDown: true)
                .workoutFont(17)
                .foregroundStyle(Paper.ink)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var buttons: some View {
        step("\u{2212}15", spoken: "15 seconds less") { adjust(-15) }
        step("+15", spoken: "15 seconds more") { adjust(15) }
        step("Skip", spoken: "Skip the rest", action: skip)
    }

    private func step(_ title: String, spoken: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).workoutFont(15).lineLimit(1)
        }
        .buttonStyle(RecompButtonStyle(filled: false))
        .accessibilityLabel(spoken)
    }
}

/// A big button that gives a little under the thumb (Done here and on the summary).
struct SessionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Changing a set's values

/// A set's values, with − and + (kg by the exercise's step, reps by 1, seconds by 5), or typed: "57,5" and "57.5" both
/// work. An emptied field keeps the value it had.
struct SetValueSheet: View {
    private enum Field: Hashable { case kg, reps, seconds }

    let exercise: Exercise
    let step: Double
    let save: (Double?, Int?, Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kg: String
    @State private var reps: String
    @State private var seconds: String
    @FocusState private var focus: Field?

    init(exercise: Exercise, set: LoggedSet, step: Double, save: @escaping (Double?, Int?, Int?) -> Void) {
        self.exercise = exercise
        self.step = step
        self.save = save
        let cardio = exercise.kind == .cardio
        _kg = State(initialValue: set.kg.map { WorkoutFormat.kg($0) } ?? "")
        _reps = State(initialValue: set.reps.map { String($0) } ?? "")
        _seconds = State(initialValue: set.seconds.map { cardio ? WorkoutFormat.rest($0) : String($0) } ?? "")
    }

    private var showsKg: Bool { [.weight, .weighted, .assisted].contains(exercise.kind) }
    private var showsReps: Bool { exercise.kind != .time && exercise.kind != .cardio }
    private var showsSeconds: Bool { exercise.kind == .time || exercise.kind == .cardio }

    private var kgValue: Double? { WorkoutInput.kg(kg) }
    private var repsValue: Int? { WorkoutInput.reps(reps) }
    private var secondsValue: Int? { WorkoutInput.seconds(seconds) }

    /// Every field shown reads, or is empty.
    private var valid: Bool {
        (!showsKg || Self.blank(kg) || kgValue != nil)
            && (!showsReps || Self.blank(reps) || repsValue != nil)
            && (!showsSeconds || Self.blank(seconds) || secondsValue != nil)
    }

    private var kgTitle: String {
        switch exercise.kind {
        case .weighted: return "EXTRA KG"
        case .assisted: return "HELP KG"
        default: return "KG"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: exercise.name)
                .workoutDisplay(20)
                .foregroundStyle(Paper.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            if showsKg {
                row(kgTitle, text: $kg, keyboard: .decimalPad, field: .kg,
                    minus: { stepKg(-step) }, plus: { stepKg(step) })
            }
            if showsReps {
                row("REPS", text: $reps, keyboard: .numberPad, field: .reps,
                    minus: { stepReps(-1) }, plus: { stepReps(1) })
            }
            if showsSeconds {
                row(exercise.kind == .cardio ? "TIME" : "SECONDS", text: $seconds, keyboard: .numbersAndPunctuation,
                    field: .seconds, minus: { stepSeconds(-5) }, plus: { stepSeconds(5) })
            }
            Spacer(minLength: 0)
            Button {
                save(showsKg ? kgValue : nil, showsReps ? repsValue : nil, showsSeconds ? secondsValue : nil)
                dismiss()
            } label: {
                Text("Save").workoutFont(17)
            }
            .buttonStyle(RecompButtonStyle(wide: true, height: 52))
            .disabled(!valid)
        }
        .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PaperFill().ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.light)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // it is a fixed 300 pt high
    }

    /// "KG  −  [57.5]  +". The whole box takes the tap, not just the text in it.
    private func row(_ title: String, text: Binding<String>, keyboard: UIKeyboardType, field: Field,
                     minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return HStack(spacing: 10) {
            Text(verbatim: title)
                .tracking(0.6)
                .workoutFont(12)
                .foregroundStyle(WorkoutStyle.quiet)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(minWidth: 64, alignment: .leading)
            stepper("minus", spoken: "Less", action: minus)
            TextField(title, text: text)
                .keyboardType(keyboard)
                .focused($focus, equals: field)
                .multilineTextAlignment(.center)
                .workoutFont(20, .semibold)
                .foregroundStyle(Paper.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background { shape.fill(Paper.paper).onTapGesture { focus = field } }
                .overlay(shape.stroke(focus == field ? WorkoutStyle.accent : Paper.edge, lineWidth: 1.2)
                    .allowsHitTesting(false))
            stepper("plus", spoken: "More", action: plus)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title.capitalized)
    }

    private func stepper(_ symbol: String, spoken: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Paper.ink)
                .frame(width: 44, height: 44)
                .background(Paper.paper, in: Circle())
                .overlay(Circle().stroke(Paper.edge, lineWidth: 1.2))
                .contentShape(Circle())
        }
        .buttonStyle(RecompPressStyle())
        .accessibilityLabel(spoken)
    }

    private func stepKg(_ by: Double) {
        let v = ((kgValue ?? 0) + by) * 100
        kg = WorkoutFormat.kg(min(500, max(0, v.rounded() / 100)))
    }

    private func stepReps(_ by: Int) {
        reps = String(min(200, max(1, (repsValue ?? 0) + by)))
    }

    private func stepSeconds(_ by: Int) {
        let v = min(3600, max(1, (secondsValue ?? 0) + by))
        seconds = exercise.kind == .cardio ? WorkoutFormat.rest(v) : String(v)
    }

    private static func blank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
