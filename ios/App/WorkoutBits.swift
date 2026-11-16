import SwiftUI

// The ways into Workouts from the rest of the app: the tag on the map and the card under More. Each reads
// `WorkoutStore.shared` and opens the sheet or the running workout through `WorkoutNav.shared`; the screens only
// place them.

/// The look of Workouts: the app's paper, with one colour for everything that is done or starts something.
enum WorkoutStyle {
    static let accent = Paper.green
    /// Second lines on a card. Darker than `Paper.muted`, which is a little light for small text on the card.
    static let quiet = Paper.ink.opacity(0.7)
}

/// Which Workouts screen is up: the sheet, or the running workout as a full-screen cover. The cover can't come up
/// over the sheet, so a start from the sheet closes it first and shows the cover once it has gone.
@MainActor
final class WorkoutNav: ObservableObject {
    static let shared = WorkoutNav()

    @Published var sheet = false
    @Published var session = false
    /// A start or Resume from the sheet: the cover comes when the sheet has gone.
    private var sessionAfterSheet = false
    /// The Workouts screens (the sheet, the running workout) on screen now, counted, so a handoff from one to the
    /// other never reads as none while one is still up.
    private var onScreen = 0

    /// A Workouts screen is on screen, over the app's own banners and alerts: notices then come as system banners.
    var showing: Bool { onScreen > 0 }

    /// The sheet's and the running workout's onAppear.
    func screenAppeared() {
        onScreen += 1
    }

    /// Their onDisappear.
    func screenDisappeared() {
        onScreen = max(0, onScreen - 1)
    }

    func openWorkouts() {
        sheet = true
    }

    func openSession() {
        if sheet {
            sessionAfterSheet = true
            sheet = false
        } else {
            session = true
        }
    }

    /// The sheet's onDismiss.
    func sheetDismissed() {
        guard sessionAfterSheet else { return }
        sessionAfterSheet = false
        session = true
    }

    /// HomeView left the screen (a trip started, the alarm rang): the sheet goes, and the cover stays asked for only
    /// while a workout runs, so nothing pops up by itself when HomeView comes back.
    func homeLeft() {
        sheet = false
        sessionAfterSheet = false
        if WorkoutStore.shared.active == nil { session = false }
    }

    /// haltewekker://workout: the running workout, else the sheet.
    func openFromURL() {
        if WorkoutStore.shared.active != nil {
            openSession()
        } else {
            openWorkouts()
        }
    }
}

/// The body weight a workout counts with (pull-ups, dips): Recomp's week average ending that day, else the weigh-in
/// nearest to it.
enum WorkoutBody {
    @MainActor static func kg(on date: Date) -> Double? {
        Lifts.bodyWeight(on: RecompCalendar.day(for: date), weights: RecompStore.shared.data.weights)
    }
}

// MARK: - On the map

/// Next to the bell, the outfit and the protein: during a workout the time since it started (one tap back to it), on
/// a training day what's on today. Nothing on a rest day. Only the icon when the row gets too wide.
struct WorkoutTag: View {
    @ObservedObject private var store = WorkoutStore.shared

    var body: some View {
        if let a = store.active {
            tag(Text(a.workout.start, style: .timer), label: "Workout in progress") {
                WorkoutNav.shared.openSession()
            }
        } else if store.available,
                  Rotation.isTrainingDay(store.nextUp, workouts: store.index.workouts, today: store.today) {
            let title = Rotation.title(store.nextUp)
            tag(Text(verbatim: title), label: "Workout today: \(title)") {
                WorkoutNav.shared.openWorkouts()
            }
        }
    }

    private func tag(_ text: Text, label: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    icon
                    text.font(.system(size: 13, weight: .heavy)).monospacedDigit().lineLimit(1)
                }
                icon.frame(minWidth: 22)                     // a 44 pt wide capsule
            }
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 11).frame(height: 34)
            .background(Paper.paper, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
            // a 44 pt hit area round the 34 pt capsule, without moving the tags beside it
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -5)
        .accessibilityLabel(label)
    }

    private var icon: some View {
        Image(systemName: "dumbbell.fill").font(.system(size: 12, weight: .semibold))
    }
}

// MARK: - Under More

/// First under More: Workouts, with what's next (or the workout that runs, and for how long).
struct WorkoutCard: View {
    @ObservedObject private var store = WorkoutStore.shared
    let pal: HWPalette

    init(pal: HWPalette) {
        self.pal = pal
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "dumbbell.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(WorkoutStyle.accent, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workouts").font(HWFont.display(17)).foregroundStyle(Paper.ink)
                    subtitle.font(HWFont.body(12)).monospacedDigit().foregroundStyle(WorkoutStyle.quiet)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Paper.ink.opacity(0.8))
            }
            .contentShape(Rectangle())
            .brass(pal, pad: 14)
        }
        .buttonStyle(.plain)
    }

    /// "Push in progress · 32 min", "Next: Pull + legs · Push 2 days ago". Before anything: what it's for.
    @ViewBuilder private var subtitle: some View {
        if let a = store.active {
            let start = a.workout.start
            TimelineView(.periodic(from: start, by: 60)) { context in
                Text(verbatim: "\(a.workout.title) in progress · \(Self.minutes(from: start, to: context.date)) min")
            }
        } else if let last = store.lastWorkout {
            Text(verbatim: Rotation.cardLine(store.nextUp, last: last, today: store.today))
        } else {
            Text("Your sets and reps, and what to lift next time.")
        }
    }

    private func open() {
        if store.active != nil {
            WorkoutNav.shared.openSession()
        } else {
            WorkoutNav.shared.openWorkouts()
        }
    }

    private static func minutes(from start: Date, to now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(start) / 60))
    }
}
