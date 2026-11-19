import Combine
import CoreLocation
import Foundation

/// Friends (0.26): your trip, to the friends you show your trips to. It only watches the trip (`TripManager`'s
/// published state, and the ride's own network tick, which comes every 30 s while a trip runs): it never changes the
/// trip, the alarm or the Live Activity, and it has no loop of its own.
///
/// Shared while a trip runs and you're confirmed on board (the app matched your bus or train, you picked it, said
/// "I'm on it", or started the trip yourself), and only once the one-time screen is answered: every minute, and when
/// the leg changes. Taken back from the relay when the trip ends (`TravelShareRules`).
@MainActor
final class FriendTravelShare: ObservableObject {
    static let shared = FriendTravelShare()

    /// Confirmed on board with friends to share with, but the one-time screen isn't answered yet: the ride screen asks.
    @Published private(set) var needsAnswer = false
    /// The coach you marked, for the train you're on now.
    @Published private(set) var coach: TravelState.Coach?
    /// The train it's for (its trip id).
    @Published private(set) var coachTrip: String?
    /// A train's number by its trip id, once known (for NS's drawing and for friends).
    @Published private(set) var numbers: [String: String] = [:]

    /// This trip's state went out (so the trip's end takes it back).
    private(set) var sharing = false
    private weak var trip: TripManager?
    private var subs: Set<AnyCancellable> = []
    private var confirmed = false
    private var lastSent: Date?
    private var lastFetch: Date?
    private var lastKey = ""
    private var sending = false
    private var asking: Set<String> = []

    private init() {}

    /// Starts watching the trip (once, as the app starts).
    func attach(_ t: TripManager) {
        guard trip == nil else { return }
        trip = t
        t.onNetTick = { [weak self] in self?.tick() }
        let changes: [AnyPublisher<Void, Never>] = [
            t.$phase.map { _ in () }.eraseToAnyPublisher(),
            t.$index.map { _ in () }.eraseToAnyPublisher(),
            t.$vehicle.map { _ in () }.eraseToAnyPublisher(),
            t.$choosing.map { _ in () }.eraseToAnyPublisher(),
            t.$pickedByHand.map { _ in () }.eraseToAnyPublisher(),
            t.$handLock.map { _ in () }.eraseToAnyPublisher(),
        ]
        // (published before the change lands: a moment later it reads the trip as it is)
        Publishers.MergeMany(changes)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] in self?.changed() }
            .store(in: &subs)
        // a trip that ended while the app was gone: its state is taken back (nothing happens if none went out)
        if !Self.running(t) { Task { await FriendStore.shared.clearTravel() } }
    }

    // MARK: what the trip says

    private static func running(_ t: TripManager) -> Bool {
        switch t.phase {
        case .sleeping, .awake, .alarm, .transfer: return true
        case .idle, .finished: return false
        }
    }

    private func signals(_ t: TripManager) -> TravelShareRules.Signals {
        var s = TravelShareRules.Signals()
        s.running = Self.running(t)
        s.demo = t.demo
        s.startedByHand = !t.autoStarted
        s.vehicleMatched = t.vehicle != nil && t.choosing.count <= 1 && !t.byTimetable
        s.pickedByHand = t.pickedByHand || t.handLock != nil
        return s
    }

    private func stage(_ t: TripManager) -> TravelState.Stage {
        if t.phase == .transfer { return .change }
        return t.waitingToBoard ? .waiting : .riding
    }

    private func key(_ t: TripManager) -> String {
        "\(t.index)|\(t.vehicle?.tripId ?? "-")|\(stage(t).rawValue)|\(coach?.n ?? 0)"
    }

    // MARK: when

    /// The phase, the leg or the vehicle changed (or how sure it is): send now if the leg is another, or take it back.
    private func changed() {
        guard let t = trip else { return }
        let s = signals(t)
        confirmed = s.running ? TravelShareRules.confirmed(before: confirmed, s) : false
        if coachTrip != nil, coachTrip != t.vehicle?.tripId { coach = nil; coachTrip = nil }
        evaluate(force: key(t) != lastKey)
    }

    /// The ride's network tick (every 30 s on a trip): the next state when a minute has gone by, and friends' states.
    private func tick() {
        evaluate(force: false)
        let store = FriendStore.shared
        guard store.hasFriends, !sending, TravelAge.due(last: lastFetch, now: Date()) else { return }
        lastFetch = Date()
        Task { await store.fetchTravel() }
    }

    /// The switches changed (the one-time screen, the pause, a friend's switch).
    func settingsChanged() { evaluate(force: true) }

    private func evaluate(force: Bool) {
        guard let t = trip else { return }
        let store = FriendStore.shared
        let d = TravelShareRules.decide(consent: store.travelConsent, paused: store.travelPaused, confirmed: confirmed,
                                        friends: store.travelFriends, sentBefore: sharing)
        needsAnswer = d == .ask
        switch d {
        case .share(let ids):
            if force || TravelAge.due(last: lastSent, now: Date()) { send(ids, t) }
        case .clear:
            clear()
        case .ask, .none:
            break
        }
    }

    // MARK: sending

    private func send(_ ids: [String], _ t: TripManager) {
        guard !sending, var s = build(t) else { return }
        sending = true
        sharing = true
        lastSent = Date()
        lastKey = key(t)
        Task {
            if s.isTrain, s.num == nil, let id = s.trip { s.num = await self.number(id) }
            await FriendStore.shared.putTravel(s, to: ids)
            await FriendStore.shared.fetchTravel()
            self.lastFetch = Date()
            self.sending = false
        }
    }

    private func clear() {
        sharing = false
        lastSent = nil
        lastKey = ""
        Task { await FriendStore.shared.clearTravel() }
    }

    // MARK: the state

    /// A place as friends see it: a stop's name and where it is; never where Home is.
    private static func spot(_ p: Place) -> TravelState.Spot {
        if p.key == RoleLogic.homeKey || p.key == "here" { return TravelState.Spot(name: p.key == "here" ? "Here" : "Home") }
        return TravelState.Spot(name: p.short, lat: p.coordinate.latitude, lon: p.coordinate.longitude)
    }

    private static func rounded(_ x: Double) -> Double { (x * 100_000).rounded() / 100_000 }

    private func build(_ t: TripManager) -> TravelState? {
        guard let leg = t.leg else { return nil }
        let st = stage(t)
        var s = TravelState(state: st.rawValue, mode: leg.mode == .train ? "train" : "bus", from: Self.spot(leg.from), to: Self.spot(leg.to))
        s.leg = t.index + 1
        s.legs = t.legs.count
        s.end = t.arrival
        if let last = t.legs.last, last.to != leg.to { s.dest = Self.spot(last.to) }
        if st == .change {
            // between two legs: where you change, and the next ride
            if let nl = t.legs[safe: t.index + 1] {
                s.from = Self.spot(nl.from)
                s.to = Self.spot(nl.to)
                s.mode = nl.mode == .train ? "train" : "bus"
                s.leg = t.index + 2
            }
            if let n = t.next {
                s.mode = n.isTrain ? "train" : "bus"
                s.line = n.isTrain ? Transit.trainLabel(n.name.isEmpty ? n.line : n.name) : n.line
                s.num = n.num.isEmpty ? nil : n.num
                s.trip = n.tripId
                s.eta = n.arrival
            }
        } else {
            s.eta = t.legArrival ?? t.legTo
            if let v = t.vehicle {
                s.mode = v.isTrain ? "train" : "bus"
                s.line = v.isTrain ? Transit.trainLabel(v.line) : v.line
                s.trip = v.tripId
                s.num = numbers[v.tripId]
                if v.isTrain, coachTrip == v.tripId { s.coach = coach }
            }
        }
        if let f = t.lastFix, f.horizontalAccuracy >= 0, f.horizontalAccuracy < 500, -f.timestamp.timeIntervalSinceNow < 300 {
            s.pos = TravelState.Position(lat: Self.rounded(f.coordinate.latitude), lon: Self.rounded(f.coordinate.longitude),
                                         acc: f.horizontalAccuracy.rounded(), at: f.timestamp)
        }
        return s
    }

    /// A train's number by its trip id: from the list of what leaves, else its live trip (one look per train).
    func number(_ tripId: String) async -> String? {
        if let n = numbers[tripId] { return n }
        if let n = trip?.upcoming.first(where: { $0.trip.first.tripId == tripId })?.trip.first.num, !n.isEmpty {
            numbers[tripId] = n
            return n
        }
        guard !asking.contains(tripId) else { return nil }
        asking.insert(tripId)
        defer { asking.remove(tripId) }
        if let n = await Transit.liveTrip(tripId, maxAge: RideTick.tripCache)?.num, !n.isEmpty {
            numbers[tripId] = n
            return n
        }
        return nil
    }

    // MARK: the coach

    /// You marked your coach (nil: took it away): friends get it with the next state, which goes now.
    func setCoach(_ c: TravelState.Coach?, trip tripId: String) {
        coach = c
        coachTrip = c == nil ? nil : tripId
        evaluate(force: true)
    }
}
