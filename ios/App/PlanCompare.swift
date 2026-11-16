import Foundation

/// Plan a trip's option cards: one comparison label each (Fastest, Latest still in time, Most room to change, Fewest
/// changes), and which actions the trip offers. Plain values, so it's tested.
enum PlanCompare {
    struct Option: Equatable {
        let id: String
        let depart: Date
        let arrive: Date
        let changes: Int
        /// The least room at any change, in minutes (nil: no change).
        let minRoom: Int?
    }

    enum Label: String, Equatable {
        case fastest = "Fastest"
        case latest = "Latest still in time"
        case room = "Most room to change"
        case fewest = "Fewest changes"
    }

    /// At most one label per option; each label on one option. `deadline`: Be there by.
    static func labels(_ opts: [Option], deadline: Date?) -> [String: Label] {
        var out: [String: Label] = [:]
        guard !opts.isEmpty else { return out }
        let inTime = deadline.map { d in opts.filter { $0.arrive <= d } } ?? opts
        let pool = inTime.isEmpty ? opts : inTime
        guard let fastest = pool.min(by: { ($0.arrive, $0.changes, -$0.depart.timeIntervalSince1970) < ($1.arrive, $1.changes, -$1.depart.timeIntervalSince1970) })
        else { return out }
        out[fastest.id] = .fastest
        if deadline != nil, let latest = inTime.max(by: { ($0.depart, -$0.arrive.timeIntervalSince1970) < ($1.depart, -$1.arrive.timeIntervalSince1970) }),
           out[latest.id] == nil, latest.depart > fastest.depart {
            out[latest.id] = .latest
        }
        // (a direct fastest needs no room: then no "most room")
        if let fRoom = fastest.minRoom,
           let room = pool.filter({ ($0.minRoom ?? -1) > fRoom && out[$0.id] == nil })
            .max(by: { ($0.minRoom ?? 0, -$0.arrive.timeIntervalSince1970) < ($1.minRoom ?? 0, -$1.arrive.timeIntervalSince1970) }) {
            out[room.id] = .room
        }
        if let few = pool.filter({ $0.changes < fastest.changes && out[$0.id] == nil }).min(by: { ($0.changes, $0.arrive) < ($1.changes, $1.arrive) }) {
            out[few.id] = .fewest
        }
        return out
    }

    /// Drop the ones another option beats outright (leaves no earlier and arrives sooner), the earliest first.
    static func useful(_ opts: [Option]) -> [Option] {
        opts.filter { t in !opts.contains { $0.id != t.id && $0.depart >= t.depart && $0.arrive < t.arrive } }
            .sorted { $0.depart < $1.depart }
    }

    enum When: Equatable {
        case now
        case leave(Date)
        case arrive(Date)
    }

    /// Go (the hands-free Fastest trip) is offered from your location, to leave now or to be there by a time within
    /// the next `goHours`.
    static let goHours = 3.0
    static func offersGo(fromHere: Bool, when: When, now: Date) -> Bool {
        guard fromHere else { return false }
        switch when {
        case .now: return true
        case .leave: return false
        case .arrive(let t): return t > now && t.timeIntervalSince(now) <= goHours * 3600
        }
    }

    /// Remind me (today's planned trip with its leave reminder) is offered between Home and School only, for a later
    /// time today or tomorrow. `day`: 0 today, 1 tomorrow, anything else no.
    static func offersRemind(homeSchool: Bool, fromHere: Bool, when: When, day: Int) -> Bool {
        guard homeSchool, !fromHere, day == 0 || day == 1 else { return false }
        if case .now = when { return false }
        return true
    }
}
