import Foundation

/// Live times for the home screen: your next door-to-door trip and the boards per leg.
@MainActor
final class LiveStore: ObservableObject {
    @Published private(set) var next: [DoorTrip] = []
    @Published private(set) var nextError: String?
    @Published private(set) var board: [BoardDeparture] = []
    @Published private(set) var trains: [DoorTrip] = []
    @Published private(set) var buas: [DoorTrip] = []
    @Published private(set) var toVeghel: [DoorTrip] = []
    @Published private(set) var updated: Date?
    @Published var pick = 0
    private var loadedFor: Direction?
    private var busy = false
    private var lastPanels = Date.distantPast

    /// The lines you take in Veghel (others are left off the board).
    let myLines: Set<String> = ["305", "306", "158"]

    func refresh(_ dir: Direction, force: Bool = false) async {
        if busy && loadedFor == dir { return }
        if loadedFor != dir { next = []; board = []; trains = []; buas = []; toVeghel = []; pick = 0; nextError = nil }
        if !force, loadedFor == dir, let u = updated, Date().timeIntervalSince(u) < 60 { return }
        busy = true; loadedFor = dir
        defer { busy = false }
        let trips = await Transit.nextTrips(dir)
        guard loadedFor == dir else { return }
        next = trips
        nextError = trips.isEmpty ? "No trips found right now. It tries again in a minute." : nil
        if pick >= trips.count { pick = 0 }
        updated = Date()
        // The boards per leg every two minutes.
        guard force || Date().timeIntervalSince(lastPanels) > 120 else { return }
        lastPanels = Date()
        let now = Date().addingTimeInterval(-60)
        if dir == .toSchool {
            async let b = Transit.board(stopIds: Place.veghel.ids)
            async let t1 = Transit.plan(from: .eindhoven, to: .breda, modes: "RAIL", at: now, count: 4, maxTransfers: 1)
            async let t2 = Transit.plan(from: .denBosch, to: .breda, modes: "RAIL", at: now, count: 4, maxTransfers: 1)
            async let u = Transit.plan(from: .breda, to: .buas, modes: "BUS", at: now, count: 6, maxTransfers: 0)
            let (bb, a, c, d) = await (b, t1, t2, u)
            guard loadedFor == dir else { return }
            board = bb.filter { myLines.contains($0.line) && $0.time > Date().addingTimeInterval(-60) }
            trains = (a + c).sorted { $0.first.departure < $1.first.departure }
            buas = d
        } else {
            async let u = Transit.plan(from: .buas, to: .breda, modes: "BUS", at: now, count: 6, maxTransfers: 0)
            async let t1 = Transit.plan(from: .breda, to: .eindhoven, modes: "RAIL", at: now, count: 4, maxTransfers: 1)
            async let t2 = Transit.plan(from: .breda, to: .denBosch, modes: "RAIL", at: now, count: 4, maxTransfers: 1)
            async let v1 = Transit.plan(from: .denBosch, to: .veghel, modes: "BUS", at: now, count: 3, maxTransfers: 0)
            async let v2 = Transit.plan(from: .eindhoven, to: .veghel, modes: "BUS", at: now, count: 3, maxTransfers: 0)
            let (uu, a, c, d, e) = await (u, t1, t2, v1, v2)
            guard loadedFor == dir else { return }
            buas = uu
            trains = (a + c).sorted { $0.first.departure < $1.first.departure }
            toVeghel = (d + e).sorted { $0.first.departure < $1.first.departure }
        }
    }
}
