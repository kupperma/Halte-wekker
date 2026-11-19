import Foundation

// Friends (0.27): chats as plain values, tested without the relay or the UI. Foundation only.
//
// A chat is one friend's (keyed by their account id) or a group's (keyed "g." + the group id). What's in it came as
// boxes (`message`, `trip`) or was written here; `seen` boxes say how far the others got and read. Nothing here sends:
// the store locks and sends what these values say is due.

/// Which chat: a friend's (their account id) or a group's ("g." + its id).
enum ChatKey {
    static func friend(_ account: String) -> String { account }
    static func group(_ id: String) -> String { "g." + id }
    static func groupId(_ key: String) -> String? { key.hasPrefix("g.") ? String(key.dropFirst(2)) : nil }
    static func isGroup(_ key: String) -> Bool { key.hasPrefix("g.") }
}

/// The body of a `message` box: a line of text; or an answer to a trip card ("I'm in", "Can't"), which says the card's
/// `n` and the answer too (the text is what an app that doesn't know answers shows).
struct ChatText: Codable, Equatable {
    static let maxLength = 1000

    var text: String
    /// The `n` of the trip card this answers.
    var re: String? = nil
    /// "in" or "cant" (with `re`).
    var answer: String? = nil

    /// As sent and shown: no control characters but line breaks, at most two line breaks in a row, trimmed, at most
    /// 1000 characters.
    static func clean(_ s: String) -> String {
        let lines: [String] = s.components(separatedBy: .newlines).map { line in
            let kept = line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\t" }
            return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        var blank = 0
        for l in lines {
            if l.isEmpty { blank += 1; if blank > 1 { continue } } else { blank = 0 }
            out.append(l)
        }
        let joined = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(joined.prefix(maxLength))
    }
}

/// An answer to a trip card.
enum TripAnswer: String, Codable, Equatable {
    case yes = "in"
    case no = "cant"

    var text: String { self == .yes ? "I’m in" : "Can’t make it" }
}

/// The body of a `seen` box: the newest of your messages (by your own `t`) the sender has got, and has read, in that
/// chat. Sent with slot `seen` (a group: `se.<group id>`), so only the newest waits on the relay.
struct ChatSeen: Codable, Equatable {
    var got: Int?
    var read: Int?

    /// Both, the further of each.
    func merged(_ o: ChatSeen) -> ChatSeen {
        ChatSeen(got: Self.max(got, o.got), read: Self.max(read, o.read))
    }

    static func max(_ a: Int?, _ b: Int?) -> Int? {
        guard let a else { return b }
        guard let b else { return a }
        return Swift.max(a, b)
    }
}

/// One line in a chat.
struct ChatMessage: Codable, Equatable, Identifiable {
    enum Content: Codable, Equatable {
        case text(ChatText)
        case trip(TripCard)
        /// What happened in a group ("Sam added Lou"), written on this phone.
        case note(String)
    }

    /// `from` + "|" + the box's `n` (the same box twice is the same message).
    var id: String
    /// Who wrote it (your own account for yours; "" for a note).
    var from: String
    var n: String
    /// The writer's own time (the box's `t`, unix seconds).
    var t: Int
    /// When this phone got it (or wrote it): the chat's order.
    var at: Date
    var content: Content
    /// Yours: it went to the relay (false: still waiting to go).
    var sent: Bool? = nil

    static func id(from: String, n: String) -> String { "\(from)|\(n)" }

    var isNote: Bool { if case .note = content { return true }; return false }
    var trip: TripCard? { if case .trip(let c) = content { return c }; return nil }
    var text: ChatText? { if case .text(let t) = content { return t }; return nil }
}

/// How far one of your messages got.
enum ChatDelivery: Equatable {
    /// Still on this phone (it goes at the next check).
    case waiting
    /// On the relay: it arrives when they open Haltewekker.
    case sent
    /// On their phone (`of` of `count` in a group).
    case delivered(Int, of: Int)
    /// Read (by `of` of `count` in a group).
    case read(Int, of: Int)
}

struct Chat: Codable, Equatable {
    var key: String
    var messages: [ChatMessage] = []
    /// You've seen everything that came until then.
    var readAt: Date?
    /// How far each of the others told you they got and read your messages.
    var marks: [String: ChatSeen] = [:]
    /// What you last told each writer about theirs.
    var told: [String: ChatSeen] = [:]

    var last: ChatMessage? { messages.last }
}

/// Every chat on this phone (kept in a file beside the friend list; not in the backup).
struct ChatBook: Codable, Equatable {
    var v = 1
    var chats: [String: Chat] = [:]

    /// A chat keeps its newest this many lines.
    static let keep = 500

    func chat(_ key: String) -> Chat? { chats[key] }

    /// Puts a line in a chat (made if it isn't there). False: it was there already (the same box again).
    @discardableResult
    mutating func add(_ m: ChatMessage, to key: String) -> Bool {
        var c = chats[key] ?? Chat(key: key)
        guard !c.messages.contains(where: { $0.id == m.id }) else { return false }
        // in the order this phone got them (a late box goes at the end, as it came)
        c.messages.append(m)
        if c.messages.count > Self.keep { c.messages.removeFirst(c.messages.count - Self.keep) }
        chats[key] = c
        return true
    }

    /// Your lines that went to the relay.
    mutating func markSent(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for (k, var c) in chats {
            var changed = false
            for i in c.messages.indices where ids.contains(c.messages[i].id) && c.messages[i].sent != true {
                c.messages[i].sent = true
                changed = true
            }
            if changed { chats[k] = c }
        }
    }

    /// You looked at the chat: everything in it is read.
    mutating func read(_ key: String, now: Date) {
        guard var c = chats[key] else { return }
        let newest = c.messages.map(\.at).max() ?? now
        c.readAt = max(c.readAt ?? .distantPast, max(now, newest))
        chats[key] = c
    }

    /// Lines from others that came after you last looked.
    func unread(_ key: String, me: String) -> Int {
        guard let c = chats[key] else { return 0 }
        return Self.unread(c, me: me)
    }

    static func unread(_ c: Chat, me: String) -> Int {
        let since = c.readAt ?? .distantPast
        return c.messages.filter { !$0.isNote && $0.from != me && $0.at > since }.count
    }

    func unreadTotal(me: String, among keys: Set<String>? = nil) -> Int {
        chats.values.filter { keys?.contains($0.key) ?? true }.reduce(0) { $0 + Self.unread($1, me: me) }
    }

    /// Someone told you how far they got with your lines in this chat.
    mutating func seen(_ s: ChatSeen, from: String, in key: String) {
        guard var c = chats[key] else { return }
        c.marks[from] = (c.marks[from] ?? ChatSeen()).merged(s)
        chats[key] = c
    }

    /// What to tell each writer in this chat (one `seen` box each), because you got or read more of theirs than you
    /// told them. `told` is then updated by `told(_:to:in:)` once it's queued.
    func marksDue(_ key: String, me: String) -> [(to: String, seen: ChatSeen)] {
        guard let c = chats[key] else { return [] }
        let readAt = c.readAt ?? .distantPast
        var byWriter: [String: ChatSeen] = [:]
        for m in c.messages where !m.isNote && m.from != me && !m.from.isEmpty {
            var s = byWriter[m.from] ?? ChatSeen()
            s.got = ChatSeen.max(s.got, m.t)
            if m.at <= readAt { s.read = ChatSeen.max(s.read, m.t) }
            byWriter[m.from] = s
        }
        var out: [(to: String, seen: ChatSeen)] = []
        for (w, s) in byWriter.sorted(by: { $0.key < $1.key }) {
            let had = c.told[w] ?? ChatSeen()
            let more = (s.got ?? Int.min) > (had.got ?? Int.min) || (s.read ?? Int.min) > (had.read ?? Int.min)
            if more { out.append((to: w, seen: s.merged(had))) }
        }
        return out
    }

    mutating func told(_ s: ChatSeen, to writer: String, in key: String) {
        guard var c = chats[key] else { return }
        c.told[writer] = (c.told[writer] ?? ChatSeen()).merged(s)
        chats[key] = c
    }

    /// How far one of your lines got, with `others` the chat's other people (a friend, or a group's other members).
    func delivery(_ m: ChatMessage, in key: String, others: [String]) -> ChatDelivery {
        guard m.sent == true else { return .waiting }
        let marks = chats[key]?.marks ?? [:]
        let count = max(1, others.count)
        let read = others.filter { (marks[$0]?.read ?? Int.min) >= m.t }.count
        if read > 0 { return .read(read, of: count) }
        let got = others.filter { (marks[$0]?.got ?? Int.min) >= m.t || (marks[$0]?.read ?? Int.min) >= m.t }.count
        if got > 0 { return .delivered(got, of: count) }
        return .sent
    }

    /// The answers to a trip card (its `n`), the newest per person.
    func answers(to card: String, in key: String) -> [String: TripAnswer] {
        guard let c = chats[key] else { return [:] }
        var out: [String: TripAnswer] = [:]
        for m in c.messages {
            guard let t = m.text, t.re == card, let a = t.answer.flatMap(TripAnswer.init(rawValue:)) else { continue }
            out[m.from] = a
        }
        return out
    }

    /// The chats with something in them, the newest first.
    var recent: [Chat] {
        chats.values.filter { !$0.messages.isEmpty }.sorted { ($0.last?.at ?? .distantPast) > ($1.last?.at ?? .distantPast) }
    }

    mutating func remove(_ key: String) { chats[key] = nil }
}

/// The quick replies under the field: "On the 305" first while you're on one.
enum QuickReplies {
    static let always = ["Running 5 min late", "Save me a seat", "Wait for me", "I’m at the stop"]

    /// `line`: what you're on now ("305", "IC 3512"), if a trip runs.
    static func list(line: String?) -> [String] {
        guard let l = line?.trimmingCharacters(in: .whitespaces), !l.isEmpty else { return always }
        return ["On the \(l)"] + always
    }
}

/// A chat's last line as the list shows it.
enum ChatWords {
    static func preview(_ m: ChatMessage, me: String, name: (String) -> String, group: Bool) -> String {
        let who: String = m.from == me ? "You: " : (group && !m.from.isEmpty ? "\(name(m.from)): " : "")
        switch m.content {
        case .text(let t): return who + String(t.text.replacingOccurrences(of: "\n", with: " ").prefix(90))
        case .trip(let c): return who + "Trip: " + TripCardWords.short(c)
        case .note(let s): return s
        }
    }
}
