import Foundation

/// (0.42.9) Which side you get out of the train at this leg's stop (`DoorSide`): asked of the relay once the leg's train
/// says its platform there, again only when that (or the stop before) changes, never while the alarm rings. A question
/// that got no answer is asked again after 5 minutes at the earliest. Only station places and a platform are sent.
@MainActor
final class DoorSideStore: ObservableObject {
    static let shared = DoorSideStore()

    /// The line for the leg it was asked for ("Exit on the left · platform 4"), with that leg's stop.
    @Published private(set) var line: String?
    private(set) var answer: DoorSide.Answer?
    private(set) var stop: String?
    private var key: String?
    private var asking: String?
    private var tried: (key: String, at: Date)?
    private var answers: [String: DoorSide.Answer?] = [:]

    /// A relay that may take a while on a station it hasn't seen yet (it asks OpenStreetMap then).
    private static let budget = Budget(idle: 40, total: 65, retries: 0, backoff: 1, fastFailure: 2, minLeft: 3)

    /// The line for `stop` (the leg's stop's name), else nothing: an answer for another leg is never shown.
    func line(for stop: String?) -> String? {
        guard let stop, stop == self.stop else { return nil }
        return line
    }

    /// The answer for `stop`, the same way.
    func answer(for stop: String?) -> DoorSide.Answer? {
        guard let stop, stop == self.stop else { return nil }
        return answer
    }

    /// A new leg: nothing known for it yet.
    func reset() {
        line = nil; answer = nil; stop = nil; key = nil
    }

    /// The leg's train trip, as its live answer came: ask for its stop's side when that's new.
    func look(train: Bool, stops: [DoorSide.Stop], to: GeoPoint, toName: String, code: String?, ringing: Bool) {
        guard !ringing, let a = DoorSide.ask(train: train, stops: stops, to: to, code: code) else { return }
        if a.key == key, stop == toName { return }
        if let hit = answers[a.key] {
            key = a.key; stop = toName; answer = hit; line = DoorSide.line(hit, track: a.track)
            return
        }
        if asking == a.key { return }
        if let t = tried, t.key == a.key, Date().timeIntervalSince(t.at) < 300 { return }
        tried = (a.key, Date())
        asking = a.key
        Task { [weak self] in
            let got: Data?? = await Self.fetch(a)
            guard let self else { return }
            self.asking = nil
            guard let body = got else { return }                // no answer: asked again later
            let got1: DoorSide.Answer? = DoorSide.parse(body)
            let text: String? = DoorSide.line(got1, track: a.track)
            self.answers[a.key] = .some(got1)
            self.key = a.key; self.stop = toName; self.answer = got1; self.line = text
            FieldLog.shared.add(.ride, "exit side · \(a.station) platform \(a.track): \(text ?? "not known")")
        }
    }

    /// The relay's body (inner nil: it answered that it doesn't know); nil: no answer (busy, no network).
    private nonisolated static func fetch(_ a: DoorSide.Ask) async -> Data?? {
        guard let url = URL(string: NSStore.relay + "/rail/v1/side?" + a.query) else { return nil }
        var r = URLRequest(url: url)
        r.setValue(Transit.userAgent, forHTTPHeaderField: "User-Agent")
        guard let ans = try? await Net.response(r, lane: .background, budget: budget, label: "/rail/v1/side") else { return nil }
        if ans.status == 200 { return .some(ans.data) }
        if (400..<500).contains(ans.status) { return .some(nil) }
        return nil
    }
}
