import Foundation

enum HevyError: Error, Equatable { case notText, empty, missingColumns([String]) }

/// One set of a Hevy workout export, as the file has it: the times as text, the numbers read (nil when empty).
struct HevyRow: Equatable {
    var title: String; var start: String; var end: String; var note: String; var exercise: String
    var superset: Int?; var exerciseNotes: String; var setIndex: Int; var setType: String
    var kg: Double?; var reps: Int?; var km: Double?; var seconds: Int?; var rpe: Double?
}

/// The rows that could be read, and how many could not.
struct HevyFile: Equatable { var rows: [HevyRow]; var skipped: Int }

/// One exercise of a workout in the file, with its sets in file order.
struct HevyBlock: Equatable { var title: String; var superset: Int?; var notes: String; var sets: [HevyRow] }

/// One workout in the file: the rows with the same title and start_time. `key` is "title|start_time".
struct HevyWorkout: Equatable { var key: String; var title: String; var start: Date; var end: Date?; var note: String; var blocks: [HevyBlock] }

/// An exercise title the library doesn't know, with its first set ("30 kg × 10").
struct HevyUnmatched: Equatable { var title: String; var example: String }

/// What an import would add. Every count but `duplicates`, `overlapping` and `skippedRows` is about the new workouts.
struct HevyPreview: Equatable {
    var workouts: Int; var sets: Int; var first: Date?; var last: Date?; var matched: Int; var total: Int
    var unmatched: [HevyUnmatched]; var dumbbellTitles: [String]; var duplicates: Int; var overlapping: Int; var skippedRows: Int
}

/// Per Hevy exercise title: the library exercise it is (`mapping`), a new exercise of its own (`keepAsIs`), or
/// dumbbell weights that were both hands together (`halve`).
struct HevyChoices: Equatable { var mapping: [String: String] = [:]; var keepAsIs: Set<String> = []; var halve: Set<String> = [] }

/// The Hevy CSV export: reading it, grouping it into workouts, and making the app's workouts from the new ones.
/// Pure, so it is tested in the hostless target.
enum HevyCSV {
    static let required = ["title", "start_time", "exercise_title"]
    static let zone = TimeZone(identifier: "Europe/Amsterdam")!

    // MARK: - Fields

    /// RFC 4180 records. A leading BOM goes; CRLF, LF and a lone CR end a record; a quoted field may hold commas, `""`
    /// and line breaks (read as "\n"). A trailing line break makes no empty record; a blank line is `[""]`.
    static func fields(_ text: String) -> [[String]] {
        // Quote, comma, CR and LF are ASCII, and no byte of a multi-byte UTF-8 character is: bytes are enough.
        let bytes = Array(text.utf8)
        let n = bytes.count
        var i = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var records: [[String]] = []
        var record: [String] = []
        var field: [UInt8] = []
        var quoted = false
        /// Something of this record was read since the last line break.
        var open = false

        func endField() {
            record.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        func endRecord() {
            endField()
            records.append(record)
            record = []
            open = false
        }

        while i < n {
            let b = bytes[i]
            if quoted {
                switch b {
                case 0x22:
                    if i + 1 < n, bytes[i + 1] == 0x22 {
                        field.append(0x22)
                        i += 1
                    } else {
                        quoted = false
                    }
                case 0x0D:
                    field.append(0x0A)
                    if i + 1 < n, bytes[i + 1] == 0x0A { i += 1 }
                default:
                    field.append(b)
                }
            } else {
                switch b {
                case 0x2C:
                    endField()
                    open = true
                case 0x0D, 0x0A:
                    if b == 0x0D, i + 1 < n, bytes[i + 1] == 0x0A { i += 1 }
                    endRecord()
                case 0x22 where field.isEmpty:
                    quoted = true
                    open = true
                default:
                    field.append(b)
                    open = true
                }
            }
            i += 1
        }
        if open { endRecord() }
        return records
    }

    // MARK: - Rows

    /// The rows by column name. A row is skipped (and counted) when its field count isn't the header's, its title or
    /// exercise title is empty, its start time can't be read, or a number field holds something that isn't a number.
    static func read(_ data: Data) throws -> HevyFile {
        // Valid UTF-8 decodes without a replacement character, so its bytes come back unchanged.
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf8.elementsEqual(data) else { throw HevyError.notText }
        let records = fields(text).filter { $0 != [""] }
        guard let header = records.first else { throw HevyError.empty }
        var column: [String: Int] = [:]
        for (i, name) in header.enumerated() {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if column[key] == nil { column[key] = i }
        }
        let missing = required.filter { column[$0] == nil }
        guard missing.isEmpty else { throw HevyError.missingColumns(missing) }

        var rows: [HevyRow] = []
        var skipped = 0
        // A workout's start time is on each of its rows: each text is read once.
        var readable: [String: Bool] = [:]
        for r in records.dropFirst() {
            guard r.count == header.count, let row = row(r, column, readable: &readable) else {
                skipped += 1
                continue
            }
            rows.append(row)
        }
        return HevyFile(rows: rows, skipped: skipped)
    }

    private struct NotANumber: Error {}

    private static func row(_ r: [String], _ column: [String: Int], readable: inout [String: Bool]) -> HevyRow? {
        func text(_ name: String) -> String { column[name].map { r[$0] } ?? "" }
        let title = text("title"), start = text("start_time"), exercise = text("exercise_title")
        guard !blank(title), !blank(exercise) else { return nil }
        if readable[start] == nil { readable[start] = date(start) != nil }
        guard readable[start] == true else { return nil }
        do {
            return HevyRow(title: title, start: start, end: text("end_time"), note: text("description"),
                           exercise: exercise, superset: try int(text("superset_id")),
                           exerciseNotes: text("exercise_notes"), setIndex: try int(text("set_index")) ?? 0,
                           setType: text("set_type"), kg: try number(text("weight_kg")), reps: try int(text("reps")),
                           km: try number(text("distance_km")), seconds: try int(text("duration_seconds")),
                           rpe: try number(text("rpe")))
        } catch {
            return nil
        }
    }

    private static func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// nil when empty. "." or "," before the decimals, an optional minus, nothing else.
    private static func number(_ s: String) throws -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty else { return nil }
        let minus = t.hasPrefix("-")
        var body = String(minus ? t.dropFirst() : Substring(t))
        guard body.contains(where: { $0 >= "0" && $0 <= "9" }),
              body.allSatisfy({ ($0 >= "0" && $0 <= "9") || $0 == "." }),
              body.filter({ $0 == "." }).count <= 1 else { throw NotANumber() }
        if body.hasPrefix(".") { body = "0" + body }
        if body.hasSuffix(".") { body.removeLast() }
        guard let v = Double((minus ? "-" : "") + body), v.isFinite else { throw NotANumber() }
        return v
    }

    /// A whole number ("8", or "8.0").
    private static func int(_ s: String) throws -> Int? {
        guard let v = try number(s) else { return nil }
        guard v == v.rounded(), abs(v) < 1e9 else { throw NotANumber() }
        return Int(v)
    }

    // MARK: - Dates

    /// DateFormatter isn't thread-safe and is slow to make: one per format and zone, behind a lock.
    private final class Formatters: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: DateFormatter] = [:]
        private let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()
        private let isoFraction: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        func date(_ s: String, format: String, zone: TimeZone) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            let key = zone.identifier + "|" + format
            let f: DateFormatter
            if let c = cache[key] {
                f = c
            } else {
                f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.calendar = Calendar(identifier: .gregorian)
                f.timeZone = zone
                f.dateFormat = format
                cache[key] = f
            }
            return f.date(from: s)
        }

        func iso8601(_ s: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return iso.date(from: s) ?? isoFraction.date(from: s)
        }
    }

    private static let formatters = Formatters()

    /// "13 Nov 2026, 19:16", else "Nov 13, 2026, 7:16 PM" (both local time in `timeZone`), else ISO 8601 with a zone.
    static func date(_ s: String, timeZone: TimeZone = zone) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        for format in ["d MMM yyyy, HH:mm", "MMM d, yyyy, h:mm a"] {
            if let d = formatters.date(t, format: format, zone: timeZone) { return d }
        }
        return formatters.iso8601(t)
    }

    // MARK: - Workouts

    /// Oldest first. The rows with the same title and start_time are one workout. Its blocks come in the order their
    /// exercise title first appears; a set_index 0 for a title that already has a block starts a new block.
    static func group(_ rows: [HevyRow], timeZone: TimeZone = zone) -> [HevyWorkout] {
        var keys: [String] = []
        var byKey: [String: [HevyRow]] = [:]
        for r in rows {
            let k = "\(r.title)|\(r.start)"
            if byKey[k] == nil { keys.append(k) }
            byKey[k, default: []].append(r)
        }
        var out: [HevyWorkout] = []
        for k in keys {
            guard let list = byKey[k], let first = list.first, let start = date(first.start, timeZone: timeZone) else { continue }
            var blocks: [HevyBlock] = []
            /// Exercise title → its latest block.
            var latest: [String: Int] = [:]
            for r in list {
                if let b = latest[r.exercise], !(r.setIndex == 0 && !blocks[b].sets.isEmpty) {
                    blocks[b].sets.append(r)
                    if blank(blocks[b].notes), !blank(r.exerciseNotes) { blocks[b].notes = r.exerciseNotes }
                    if blocks[b].superset == nil { blocks[b].superset = r.superset }
                } else {
                    latest[r.exercise] = blocks.count
                    blocks.append(HevyBlock(title: r.exercise, superset: r.superset,
                                            notes: blank(r.exerciseNotes) ? "" : r.exerciseNotes, sets: [r]))
                }
            }
            out.append(HevyWorkout(key: k, title: first.title, start: start, end: date(first.end, timeZone: timeZone),
                                   note: first.note, blocks: blocks))
        }
        return out.sorted { $0.start != $1.start ? $0.start < $1.start : $0.key < $1.key }
    }

    private enum Seen { case duplicate, overlapping }

    /// What is here already: the Hevy keys, and the time of every app workout (its end, else start + 3 h).
    private struct Known {
        let keys: Set<String>
        let app: [(start: Date, end: Date)]

        init(_ existing: [WorkoutSummary]) {
            keys = Set(existing.compactMap(\.hevyKey))
            app = existing.filter { $0.source == .app }
                .map { (start: $0.start, end: $0.end ?? $0.start.addingTimeInterval(3 * 3600)) }
        }

        func seen(key: String, start: Date) -> Seen? {
            if keys.contains(key) { return .duplicate }
            if app.contains(where: { $0.start <= start && start <= $0.end }) { return .overlapping }
            return nil
        }
    }

    /// The workouts that aren't here yet: no key already in `existing`, no start during an app workout there, and each
    /// id and key once. The store checks again with this when it writes, against the months as they are then.
    static func unseen(_ workouts: [Workout], existing: [WorkoutSummary]) -> [Workout] {
        let known = Known(existing)
        var ids = Set(existing.map(\.id))
        var keys = Set<String>()
        return workouts.filter { w in
            let key = w.hevyKey ?? ""
            guard known.seen(key: key, start: w.start) == nil else { return false }
            return ids.insert(w.id).inserted && keys.insert(key).inserted
        }
    }

    private static func fresh(_ f: HevyFile, existing: [WorkoutSummary]) -> [HevyWorkout] {
        let known = Known(existing)
        return group(f.rows).filter { known.seen(key: $0.key, start: $0.start) == nil }
    }

    static func preview(_ f: HevyFile, library: [Exercise], existing: [WorkoutSummary]) -> HevyPreview {
        let known = Known(existing)
        var duplicates = 0, overlapping = 0
        var new: [HevyWorkout] = []
        for w in group(f.rows) {
            switch known.seen(key: w.key, start: w.start) {
            case .duplicate?: duplicates += 1
            case .overlapping?: overlapping += 1
            case nil: new.append(w)
            }
        }
        var titles: [String] = []
        var firstSet: [String: HevyRow] = [:]
        for b in new.flatMap(\.blocks) where firstSet[b.title] == nil {
            guard let s = b.sets.first else { continue }
            titles.append(b.title)
            firstSet[b.title] = s
        }
        var matched = 0
        var unmatched: [HevyUnmatched] = []
        var dumbbell: [String] = []
        for t in titles {
            if let e = WorkoutProgram.match(hevy: t, in: library) {
                matched += 1
                if e.equipment == .dumbbell { dumbbell.append(t) }
            } else if let s = firstSet[t] {
                unmatched.append(HevyUnmatched(title: t, example: WorkoutFormat.set(loggedSet(s, halve: false), .weight, .long)))
            }
        }
        return HevyPreview(workouts: new.count, sets: new.reduce(0) { $0 + $1.blocks.reduce(0) { $0 + $1.sets.count } },
                           first: new.first?.start, last: new.last?.start, matched: matched, total: titles.count,
                           unmatched: unmatched, dumbbellTitles: dumbbell, duplicates: duplicates,
                           overlapping: overlapping, skippedRows: f.skipped)
    }

    /// The new workouts (not duplicates, not during an app workout), oldest first, and the exercises kept as is.
    /// Each block's exercise is `choices.mapping[title]`, else the library's match, else, when kept as is, a new custom
    /// exercise (it knows the title, so a later import matches it). A title with none of these is left out.
    static func workouts(_ f: HevyFile, library: [Exercise], existing: [WorkoutSummary], choices: HevyChoices)
        -> (workouts: [Workout], newExercises: [Exercise]) {
        let new = fresh(f, existing: existing)
        var titles: [String] = []
        var rowsOf: [String: [HevyRow]] = [:]
        for b in new.flatMap(\.blocks) {
            if rowsOf[b.title] == nil { titles.append(b.title) }
            rowsOf[b.title, default: []] += b.sets
        }
        var exerciseId: [String: String] = [:]
        var made: [Exercise] = []
        var taken = Set(library.map(\.id))
        for t in titles {
            if let id = choices.mapping[t] {
                exerciseId[t] = id
            } else if let e = WorkoutProgram.match(hevy: t, in: library) {
                exerciseId[t] = e.id
            } else if choices.keepAsIs.contains(t) {
                let e = custom(t, rows: rowsOf[t] ?? [], taken: taken)
                taken.insert(e.id)
                made.append(e)
                exerciseId[t] = e.id
            }
        }
        let out = new.map { w -> Workout in
            let name = w.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let routineId = ["push", "pull", "legs"].contains(name) ? name : nil
            let exercises = w.blocks.compactMap { b -> LoggedExercise? in
                guard let id = exerciseId[b.title] else { return nil }
                let halve = choices.halve.contains(b.title)
                return LoggedExercise(exerciseId: id, routineId: routineId, superset: b.superset, note: b.notes,
                                      sets: b.sets.map { loggedSet($0, halve: halve) })
            }
            return Workout(title: w.title, routineIds: [], start: w.start, end: w.end, note: w.note, source: .hevy,
                           hevyKey: w.key, exercises: exercises)
        }
        return (out, made)
    }

    /// Name = the title, id "custom-" + slug ("-2", "-3" … when taken), no muscles, equipment other. Its kind from its
    /// rows: any km → cardio; no reps but seconds → time; no kg → bodyweight; else weight.
    private static func custom(_ title: String, rows: [HevyRow], taken: Set<String>) -> Exercise {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = WorkoutProgram.slug(name)
        let base = "custom-" + (slug.isEmpty ? "exercise" : slug)
        var id = base
        var n = 2
        while taken.contains(id) {
            id = "\(base)-\(n)"
            n += 1
        }
        let kind: ExerciseKind
        if rows.contains(where: { $0.km != nil }) {
            kind = .cardio
        } else if rows.allSatisfy({ $0.reps == nil }), rows.contains(where: { $0.seconds != nil }) {
            kind = .time
        } else if rows.allSatisfy({ $0.kg == nil }) {
            kind = .bodyweight
        } else {
            kind = .weight
        }
        return Exercise(id: id, name: name.isEmpty ? title : name, equipment: .other, kind: kind, primary: [],
                        secondary: [], step: nil, hevyNames: [title], custom: true)
    }

    /// Done. RIR = 10 − RPE, rounded, 0…4.
    private static func loggedSet(_ r: HevyRow, halve: Bool) -> LoggedSet {
        let kind: SetKind
        switch r.setType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "warmup": kind = .warmup
        case "dropset": kind = .drop
        case "failure": kind = .failure
        default: kind = .normal
        }
        let rir = r.rpe.map { Int(min(4, max(0, (10 - $0).rounded()))) }
        return LoggedSet(kind: kind, kg: halve ? r.kg.map { $0 / 2 } : r.kg, reps: r.reps, seconds: r.seconds, km: r.km,
                         rir: rir, done: true)
    }

    // MARK: - Copy

    /// "3 workouts · 17 sets · 9 Nov 2026 – 12 Nov 2026 · 10 of 11 exercises matched", or "Nothing new in this file.".
    static func previewText(_ p: HevyPreview, timeZone: TimeZone = zone) -> String {
        guard p.workouts > 0 else { return "Nothing new in this file." }
        var parts = [plural(p.workouts, "workout"), plural(p.sets, "set")]
        if let a = p.first, let b = p.last {
            let from = WorkoutFormat.date(a, timeZone: timeZone), to = WorkoutFormat.date(b, timeZone: timeZone)
            parts.append(from == to ? from : "\(from) – \(to)")
        }
        parts.append("\(WorkoutFormat.count(p.matched)) of \(plural(p.total, "exercise")) matched")
        return parts.joined(separator: " · ")
    }

    /// Each line only when its number isn't 0.
    static func skippedText(_ p: HevyPreview) -> [String] {
        var out: [String] = []
        if p.overlapping > 0 { out.append("\(WorkoutFormat.count(p.overlapping)) skipped: already logged here") }
        if p.duplicates > 0 { out.append("\(WorkoutFormat.count(p.duplicates)) already imported") }
        if p.skippedRows > 0 { out.append(p.skippedRows == 1 ? "1 row skipped" : "\(WorkoutFormat.count(p.skippedRows)) rows skipped") }
        return out
    }

    private static func plural(_ n: Int, _ word: String) -> String {
        n == 1 ? "1 \(word)" : "\(WorkoutFormat.count(n)) \(word)s"
    }
}
