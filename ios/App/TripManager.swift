import ActivityKit
import CoreLocation
import Foundation
import LocalAuthentication
import UIKit
import UserNotifications

/// The bus or train you're on, once it's recognised.
struct Vehicle: Equatable {
    let tripId: String
    let line: String
    let isTrain: Bool
    var title: String { isTrain ? (line == "IC" ? "Intercity" : line == "SPR" ? "Sprinter" : line) : "Bus \(line)" }
}

/// A bus or train that fits where you've been: `meters` from where its times put it; `cost`, how well it fits by itself
/// (classic matching: those metres; the matcher: the seconds you are off its times), for the one-look and "about as
/// well" thresholds; `score` to rank by (the matcher: the planned one 45 s less; classic: the metres).
struct Match: Equatable { let vehicle: Vehicle; let meters: Double; let score: Double; let cost: Double }

/// Runs a trip: follows GPS (also with the phone locked), rings before each stop with an announcement,
/// recognises the vehicle you're on, keeps the arrival time up to date and drives the Live Activity.
/// With "Start trips by itself" on, it watches your stations and starts a trip when you leave on a bus or train.
@MainActor
final class TripManager: NSObject, ObservableObject, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    enum Phase: Equatable { case idle, sleeping, awake, alarm(approach: Bool), transfer, finished }

    /// A direction you picked yourself sticks for 3 hours, then it follows the clock again.
    @Published private(set) var direction: Direction = TripManager.savedDirection()
    @Published var toast: String?
    @Published private(set) var phase: Phase = .idle {
        didSet {
            // the home screen's stills (some 25 MB decoded) aren't kept while a trip runs; back when it's over
            LiveStore.rideOn = phase != .idle     // (the home's own on-board look waits while a trip runs)
            if oldValue == .idle, phase != .idle { StillCache.shared.purge() }
            else if oldValue != .idle, phase == .idle, UIApplication.shared.applicationState != .background { StillCache.shared.warm() }
        }
    }
    @Published private(set) var route: RoutePlan? { didSet { if route != oldValue { watchTrains() } } }
    @Published private(set) var legs: [Leg] = []
    @Published private(set) var index = 0
    @Published private(set) var distance: Double?
    @Published private(set) var accuracy: Double?
    @Published private(set) var arrival: Date?
    @Published private(set) var next: Ride?
    @Published private(set) var vehicle: Vehicle? {
        didSet {
            if oldValue?.tripId != vehicle?.tripId { wakeLive = nil; wakeRoute = [] }   // (another one's times aren't this one's)
            // (0.36) at a change, the next leg found the one you got off: still on board, no "Did you check out?"
            if let p = checkOutPending, let v = vehicle, v.tripId == p.gotOff, oldValue?.tripId != v.tripId { checkOutLook(speed: nil, sameVehicle: true) }
        }
    }
    @Published private(set) var legArrival: Date?
    @Published private(set) var legFrom: Date?          // when this bus or train left (or should have)
    @Published private(set) var legTo: Date?            // when it reaches your stop: live, or from the timetable
    @Published private(set) var locationDenied = false
    @Published private(set) var autoStarted = false
    @Published var arrivedAt: String?

    @Published var busKm: Double = UserDefaults.standard.object(forKey: "busKm") as? Double ?? 2 { didSet { UserDefaults.standard.set(busKm, forKey: "busKm") } }
    @Published var trainKm: Double = UserDefaults.standard.object(forKey: "trainKm") as? Double ?? 5 { didSet { UserDefaults.standard.set(trainKm, forKey: "trainKm") } }
    /// 0.33: Settings › Trips & alarm › "Wake me … before my stop": by time (the default) or by distance.
    @Published var wake: WakeSettings = WakeSettings.load() { didSet { wake.save() } }
    @Published var ringAtStop: Bool = UserDefaults.standard.object(forKey: "ringAtStop") as? Bool ?? true { didSet { UserDefaults.standard.set(ringAtStop, forKey: "ringAtStop") } }
    @Published var announce: Bool = UserDefaults.standard.object(forKey: "announce") as? Bool ?? true { didSet { UserDefaults.standard.set(announce, forKey: "announce") } }
    @Published var movingStation: Bool = UserDefaults.standard.object(forKey: "movingStation") as? Bool ?? true { didSet { UserDefaults.standard.set(movingStation, forKey: "movingStation") } }
    @Published var autoStart: Bool = UserDefaults.standard.object(forKey: "autoStart") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart"); updateWatching() }
    }
    @Published var soundKind: AlarmSound.Kind { didSet { sound.kind = soundKind } }
    @Published var pauseMusic: Bool = UserDefaults.standard.bool(forKey: "pauseMusic") {
        didSet { UserDefaults.standard.set(pauseMusic, forKey: "pauseMusic"); sound.pauseMusic = pauseMusic }
    }
    /// Without headphones the alarm and the announcer only vibrate. In Settings.
    @Published var headphonesOnly: Bool = UserDefaults.standard.object(forKey: "headphonesOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(headphonesOnly, forKey: "headphonesOnly"); sound.headphonesOnly = headphonesOnly }
    }
    /// (0.42.8) Settings › Trips & alarm › "Out loud if I don't stop it (after 1 min)": without headphones the alarm
    /// goes out loud after a minute. Off for everyone (it would wake the whole train); existing installs too, once.
    @Published var outLoudLater: Bool = TripManager.loadOutLoudLater() {
        didSet { UserDefaults.standard.set(outLoudLater, forKey: "outLoudLater"); sound.loudLaterOn = outLoudLater }
    }
    /// Off once for every install (`outLoudLaterSet`: the one-time switch-off done), then as you set it.
    nonisolated static func loadOutLoudLater() -> Bool {
        let d = UserDefaults.standard
        if !d.bool(forKey: "outLoudLaterSet") { d.set(false, forKey: "outLoudLater"); d.set(true, forKey: "outLoudLaterSet") }
        return d.bool(forKey: "outLoudLater")
    }
    /// If you're using your phone when it would ring, you're awake: one notification instead of the alarm.
    @Published var quietWhenInUse: Bool = UserDefaults.standard.object(forKey: "quietWhenInUse") as? Bool ?? true {
        didSet { UserDefaults.standard.set(quietWhenInUse, forKey: "quietWhenInUse") }
    }
    /// The backup alarm on every leg: it also rings after this many minutes, even if GPS drops out (0: off). In Settings.
    @Published var backupMinutes: Int = UserDefaults.standard.integer(forKey: "backupMinutes") {
        didSet { UserDefaults.standard.set(backupMinutes, forKey: "backupMinutes") }
    }
    @Published var autoHome: Bool = UserDefaults.standard.object(forKey: "autoHome") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoHome, forKey: "autoHome"); updateWatching() }
    }
    /// Wake distance per stop, once you've picked one ("bus:ht" → 2.5).
    @Published private(set) var kmMem: [String: Double] = UserDefaults.standard.dictionary(forKey: "kmMem") as? [String: Double] ?? [:]
    @Published private(set) var backupAt: Date?
    @Published private(set) var lastScore: ScoreResult?
    // Before you're on board, and at a transfer: what leaves next for this leg.
    @Published private(set) var upcoming: [PanelTrip] = []
    @Published private(set) var upcomingAt: Date?
    @Published private(set) var upcomingError: String?
    @Published private(set) var upcomingBoard: [BoardDeparture] = []    // buses: the stop's board, with cancelled and departed ones
    /// When the next departures shown were the live answer, while they're the leg's saved answer (nil: live). Shown as
    /// "as of 08:12".
    @Published private(set) var upcomingAsOf: Date?
    /// The last next departures per leg, saved in `<Caches>/answers` and shown at once when that leg comes up again. A leg
    /// from where you were (an alarm for one stop) also keeps where that was: its list is used only within 300 m of it.
    struct SavedUpcoming: Codable {                                                                  // "upcoming|<leg key>"
        let upcoming: [PanelTrip]
        let board: [BoardDeparture]
        let lat: Double?
        let lon: Double?
    }
    // Once it knows which bus or train you're on.
    @Published private(set) var vehicleStops: [TripStop] = []
    @Published private(set) var matchMeters: Int?            // how far its live position was from yours
    @Published private(set) var pickedByHand = false
    @Published private(set) var byTimetable = false         // no live position matched: it took the planned one once you'd clearly left
    @Published private(set) var speed: Double?               // m/s, from GPS, for the screens: only when it's worth drawing again
    /// The GPS speed of the newest fix (m/s), for the trip's own decisions; `speed` follows it on screen.
    private(set) var currentSpeed: Double?
    @Published private(set) var startDistance: Double?       // how far you are from where this leg starts
    @Published private(set) var always = false
    /// A pretend ride (the demo): it moves along by itself, without your GPS.
    @Published private(set) var demo = false
    private var demoTask: Task<Void, Never>?
    private var guessDirection = true            // on launch (and back after a while): where you are decides the direction
    private var awaySince: Date?

    let sound = AlarmSound()
    let music = NowPlaying()
    private let location = CLLocationManager()
    private var activity: Activity<TripAttributes>?
    private var legStart = Date()
    private var forceArrival = false
    private var lastEta = Date.distantPast
    private var lastActivity = Date.distantPast
    private var lastActivityKey = ""
    private var lastActivitySay = ""                       // what the lock screen said you should do (title, awake, ringing, kicker)
    private var endedActivity: Activity<TripAttributes>?   // after the last stop: ended, still on the lock screen for a while
    private var samples: [CLLocation] = []
    private var detectTask: Task<Void, Never>?
    private var watchLeft: (place: Place, at: Date)?      // auto-start: which station you just left (while it looks)
    private var gpsApplied: GPSPolicy.Plan?               // what GPS was last set to (`applyGPS`)
    private var transferAnchor: TransferPolicy.Anchor?    // at a change: where you've stood, since when
    private var changeSince: Date?                        // at a change: when you got off
    private var changeFirst: TransferPolicy.Listed?       // …the first departure listed for the next leg after that (live)
    private var changePlanned: TransferPolicy.Listed?     // …the planned next one, at its live time while it's listed
    private var lastRegionRetry = Date.distantPast
    private var finishedAt: Date?                         // after the last stop: when you got there
    private var finishTask: Task<Void, Never>?
    private var tightTold: String?                        // the leg (and bus) it told you had a tight change after it
    private var maxDistance: Double?                      // furthest from the stop on this leg, for progress without times
    private var tripStart: Date?
    // (0.37.1) the alarm's one repeat after 30 s, for a paired Apple Watch: which ring it's for, and whether it went
    private var againTask: Task<Void, Never>?
    private var ringSerial = 0
    private var againSent = false
    private var startedAtLeg = 0
    private var backupTask: Task<Void, Never>?
    private var lastWatchCheck = Date.distantPast
    private var upcomingKey = ""
    private var upcomingBusy = false
    private var lastVehicleRefresh = Date.distantPast
    private var lastIdleMatch = Date.distantPast
    // 0.20.7: less battery and data
    private var lastNetTick: Date?                         // a ride's network: what's due goes on one 30 s tick
    private var rideFarOn = false                          // the far GPS tier is on (`RideGPS`)
    private var backstopHit = false                        // …the region around this leg's stop was entered: the best
    private var backstopKey: String?                       // the leg the backstop region is up for
    private var farTask: Task<Void, Never>?                // while far: a look every minute (time can bring the stop near)
    private var lastEnd: (place: String, at: Date)?        // where a leg last ended (no station look right after)
    private var lastEndSpot: (spot: CLLocationCoordinate2D, at: Date)?     // and where that was (off the corridor, 0.24)
    private var tripStartSpot: CLLocationCoordinate2D?    // where you were when the trip started (its score), if that fix was fresh
    private var tripPlannedEnd: Date?                     // (0.35) the trip's scheduled arrival as it started (a replan keeps it)
    private var tripLate: (line: String, mins: Double)?   // (0.35) its latest ride at your stop so far
    /// (0.36) "Did you check out?" waiting to come (a minute after you got off), taken back if you're still on board.
    private struct CheckOutPending { let id: String; let at: Date; var speeds: [Double]; let gotOff: String?; let end: Bool }
    private var checkOutPending: CheckOutPending?
    private var trainLate: [Double] = []                  // (0.36) this trip's trains' delays at your stops (money back from NS)
    private var claimTold: Date?                          // …the trip (by its start) it told you about
    private var activityLater: Task<Void, Never>?          // a Live Activity change held back for the 30 s
    private var gpsWhy: GPSReason?                         // why GPS is on, as the battery log has it
    private var sameOK: (tripId: String, looks: Int)?      // "still the same bus?" looks in a row that passed, for this one
    private nonisolated static let backstopId = "backstop"
    // 0.33: waking by time (`WakeRule`), and Motion & Fitness (`MotionRules`)
    private var smoother = SpeedSmoother()                 // your speed, smoothed, for the time to your stop
    private var lastSpeedFix: Fix?
    private var wakeLive: (arrival: Date, at: Date)?       // your stop's live arrival by the vehicle's own answer, asked when
    private var wakeRoute: [GeoPoint] = []                 // the vehicle's road from where you got on to your stop
    private var motionVehicle = false                      // Motion & Fitness said "automotive" at the last change
    private var waitLowOn = false                          // the rough GPS while you wait for the one you get on
    private var detectWake: (id: Int, c: CheckedContinuation<Void, Never>)?
    private var detectWakeN = 0
    private var idleBest: String?
    private var notSureLogged: [String: Date] = [:]          // the matcher's last "not sure" line in the field log, per place
    private let arriveM = 450.0
    // still the same bus? (on board, every half minute)
    private var sameCheckAt = Date.distantPast
    private var offRoad = 0
    private var checkingSame = false
    private var roadOf: (tripId: String, trip: LiveTrip, at: Date)?
    private var farLooks = 0                               // looks in a row far from where its own times put it
    // still choosing between buses that fit about as well (two that left a stop together)
    private struct Candidate {
        let vehicle: Vehicle
        var trip: LiveTrip?
        var fetched = Date.distantPast
        var road: [Double] = []           // how far you were from its road, look by look
        var time: [Double] = []           // how far from where its times put it
    }
    private var cands: [Candidate] = []
    private var candSince: Date?
    private var candLead: (id: String, n: Int)?
    private var candSwitch = SwitchState()                // the matcher: who has been beating the one it shows, since when
    private var candMisses: [String: Int] = [:]           // …and the looks in a row each one failed
    private var candGPS = GPSChoice()                     // …and what their own GPS said (0.26.1): it decides, not "planned"
    private var candTimedOut: TimedOut?                   // the last choice that ran out of time, between which ones
    private var candCheckAt = Date.distantPast
    private var resolving = false
    /// While it's still choosing: the buses it could be (the first is the one it shows).
    @Published private(set) var choosing: [Vehicle] = []
    private var boardAlternatives: [DoorTrip] = []        // started from Fastest trip: the ways it was choosing between
    private var legClosest: Double?                       // the nearest you've been to this leg's stop
    private var awayLooked = false                        // it looked once already: going another way than this leg
    private var legStartMetres: Double?                   // how far from its stop this leg started (its first good fix)
    /// The ride you said you're on for this leg ("I'm on it" before it knew which one): it holds against another one it
    /// sees that doesn't go where the leg goes, while you're on its road (`RideGuards.onOtherVehicle`).
    private var heldPick: String?
    private var heldFromPlan = false                      // …made at a change from the planned one's road, not by you
    private var rideLogged: [String: Date] = [:]          // the field log's last ride line per thing, so a look doesn't repeat it
    /// 0.20.5: you said during the ride which one you're on (the "I'm actually on…" sheet), or "none of these": the
    /// matcher doesn't change the ride's vehicle by itself for the rest of this leg (`HandLock`).
    @Published private(set) var handLock: HandLock?
    /// The one you picked, off its road for 3 minutes: "Still on bus 306?" on the ride screen (nil: not asked now).
    @Published private(set) var stillOnAsk: Vehicle?
    /// 0.34: two trains still tied after 2 minutes that go different ways: "IC to 's-Hertogenbosch or IC to Eindhoven?"
    /// on the ride screen and as a notification (empty: not asked now). `whichTrainTo`: where each goes, by trip id.
    @Published private(set) var whichTrain: [Vehicle] = []
    @Published private(set) var whichTrainTo: [String: String] = [:]
    private var whichTrainAsked = false                   // asked once for this choice
    private var rivalLookAt = Date.distantPast            // the next look at the other trains on your track (0.34)
    private var trainSeen: [String: TrainRules.Seen] = [:] // what you did at the stations while choosing between trains
    private var lastJudged: [Judgement] = []              // the matcher's last look (`matchByJudging`), for the rivals look
    // 0.38: picking the one you're on (`PickRules`)
    private var departure: Departure?                     // the last time you went from standing at a stop to moving
    private var departLogged: (at: Date, line: String)?   // …its field log line, once per moment and outcome
    private var busSeen: [String: BusStops.Seen] = [:]    // what you did at the bus stops while choosing between buses
    private var busLogged = ""                            // the stop pattern's last field log line, this choice
    private var usualHeld: String?                        // your usual line's tie-break holds this one (hysteresis)
    private var candLeftAt: Date?                         // when you left the stop, as a choice began (for asking sooner)
    private var lastLines: [String: String] = [:]
    nonisolated static let whichTrainId = "which-train"
    nonisolated static let whichTrainCategory = "WHICHTRAIN"
    // 0.34: following in tunnels and dead zones (`DeadReckon`)
    private var reckonTimer: Timer?
    private var lastGood: (at: Date, coordinate: CLLocationCoordinate2D)?   // this leg's newest good fix
    private var reckonFrom: (metres: Double, at: Date)?   // where along the leg's route it reckons from
    /// The ride's place is reckoned along its route now (no good GPS: a tunnel, a dead zone).
    @Published private(set) var reckoning = false
    // 0.39: smoother rides
    /// The change ahead (`ChangeGuide`): platforms, the walk, the minutes; that you'll miss it and what instead.
    @Published private(set) var changeGuide: ChangeGuide.Guide?
    /// Switching the rest of the trip onto the next one you make (the change guide's button).
    @Published private(set) var switchingChange = false
    /// The platform you get in at on this ride, and how late it is there (minutes), by its live times.
    @Published private(set) var arrivePlatform: String?
    @Published private(set) var legDelay: Int?
    /// No answer from the network: the ride goes on from the stops and times saved when it started (`RideCache`).
    @Published private(set) var offline = false
    @Published private(set) var usingSaved = false
    private var nextOptions: [Ride] = []                  // the next leg's rides after this one gets in (`refreshEta`)
    private var readyTold = false                         // "Get ready" one stop before yours, told for this leg
    // 0.42.3: a field log of 27 November (`MissCall`, `ShortLeg`, `RideGuards.plannedNextAmong`)
    private var missHold = MissCall.Hold()                // a miss is told only once it has held a minute
    private var quietLeg = false                          // awake without the alarm (short, or started inside its wake)
    private var ringInUse = false                         // (0.42.8) the ring now is the one chime while you used the phone
    /// (0.42.8) Where the vehicle you're on really goes (its last stop, else the planned headsign): the ride's headline.
    @Published private(set) var headsign = ""
    /// (0.42.8) This leg stays on the vehicle past a planned change: "Stay on to Eindhoven". Nil: no such change.
    @Published private(set) var stayOnTo: String?
    /// The ring before your stop, for the adaptive wake-up (`AdaptiveWake`): when, which mode, when you stopped it.
    private var ringNote: (at: Date, train: Bool, stopped: Date?)?
    private var plannedNextAt = Date.distantPast           // the next leg's planned ride last asked (its live time, platform)
    private var plannedNextTrip: (id: String, trip: LiveTrip, at: Date)?   // …and its answer (where its own GPS puts it)
    // 0.39.1: the field report of 25 November (`MissRule`, `TimetableStart`, `WrongBus`, `OtherAtStop`)
    private var meant: PlannedRide?                       // the ride this leg was planned with (a switch it made itself keeps it)
    private var meantTo: Place?                           // …and where that leg went
    private var gpsRuns: [String: WrongBus.Run] = [:]     // each vehicle's run of fits by its own GPS
    private var wrongBusTold = false                      // "You're on the 154, not your 306": told on this trip
    /// "You're on the 154 to Schijndel, not your 306" and the best way on, on the ride screen (`WrongBus`).
    @Published private(set) var wrongBus: WrongBus.Alert?
    /// Waiting at your stop: "That's the 154 to Schijndel — not yours" (`OtherAtStop`).
    @Published private(set) var otherAtStop: WrongBus.Alert?
    private var otherTold: Set<String> = []               // …told by notification, by trip id
    private var otherClosed: Set<String> = []             // …its card closed, by trip id
    private var otherBoard: (key: String, at: Date, list: [BoardDeparture])?   // the stop's whole board, every line
    private var otherLooking = false
    // 0.34: what it learns from your rides (`HabitStore`)
    private var changeArrived: (at: Date, fromLine: String)?   // at a change: when you got off, and off what
    private var changeToRecord = false                    // the next leg's change outcome isn't noted yet
    private var boardedNoted = false                      // this trip's first boarding stop is noted
    /// "Pick again" (on the ride screen or the notification): the ride screen opens the sheet, and sets it back.
    @Published var pickAgain = false
    private var headsignOf: [String: String] = [:]        // where the sheet's vehicles go, by trip id
    /// Friends (0.26): told on each ride network tick, to send what's due on the same wake (it only reads the trip).
    var onNetTick: (@MainActor () -> Void)?
    /// Friends (0.29): told when you get to or leave a region (its id, true: got there), before the trip looks at it;
    /// for "Show friends when I'm at school" and the wake-up buddy. It only reads.
    var onRegion: (@MainActor (String, Bool) -> Void)?
    /// (0.29) "Show friends when I'm at school" is on: School's region also tells when you get there and leave.
    static let campusRegionKey = "friends.campusRegion"

    var leg: Leg? { index < legs.count ? legs[index] : nil }
    var wakeKm: Double { leg.map(km(for:)) ?? busKm }
    var finalName: String {
        if let r = route, !r.isFixed { return r.custom != nil ? r.station.short : (leg?.to.short ?? "") }
        // (a fixed route ends at Breda station; off the corridor there are none: your school)
        return direction == .home ? "Home" : RoleWords.current.toSchoolWord
    }
    func km(for l: Leg) -> Double { kmMem["\(l.mode.rawValue):\(l.to.key)"] ?? (l.mode == .bus ? busKm : trainKm) }
    /// This leg is by train (the one you're on, else the plan).
    private var legIsTrain: Bool { vehicle?.isTrain ?? (leg?.mode == .train) }
    /// The wake settings the rules go by (0.39): yours, a little earlier where the adaptive wake-up learned that
    /// (`AdaptiveWake`: only ever earlier, never later than you set it).
    var effectiveWake: WakeSettings { AdaptiveWakeStore.shared.effective(wake) }
    /// The wake distance the far GPS tier and its backstop keep clear of: by time, the time rule's reach (0.33).
    private var gpsWakeMetres: Double { WakeRule.gpsWakeMetres(wakeMetres: wakeKm * 1000, effectiveWake, isTrain: legIsTrain) }
    /// What the notifications say it rings: "3 min before your stop (or 5 km)", "2 km before your stop".
    var wakeWords: String { WakeRule.says(effectiveWake, isTrain: legIsTrain, wakeMetres: wakeKm * 1000) }
    var here: CLLocationCoordinate2D? { location.location?.coordinate }
    /// Your last GPS fix.
    var lastFix: CLLocation? { samples.last ?? location.location }
    /// Your fixes of the last 2 minutes with a known accuracy under 150 m, each at its own time, for the matcher.
    var recentFixes: [Fix] {
        let since = Date().addingTimeInterval(-120)
        return samples.filter { $0.timestamp > since && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 150 }.map { Fix($0) }
    }

    /// Moving like a bus or train in the last three minutes (by the GPS's speed, or between two fixes): standing at a
    /// stop on board still counts.
    /// (Indoors the GPS can jump a hundred metres between two fixes and still say it's within 40: one jump isn't a bus.
    /// So: its own speed, sure of it, twice; or three fixes of 25 m or better, half a minute or more apart, every stretch
    /// at bus speed.)
    var movedRecently: Bool {
        let r = samples.filter { $0.timestamp > Date().addingTimeInterval(-180) && LiveStore.goodFix($0) }
        if r.filter(LiveStore.movingFix).count >= 2 { return true }
        let g = r.filter { $0.horizontalAccuracy <= 25 }
        guard g.count >= 3, let a = g.first, let b = g.last, b.timestamp.timeIntervalSince(a.timestamp) >= 30 else { return false }
        let mid = g[g.count / 2]
        func v(_ p: CLLocation, _ q: CLLocation) -> Double { q.distance(from: p) / max(1, q.timestamp.timeIntervalSince(p.timestamp)) }
        return v(a, mid) >= 4 && v(mid, b) >= 4 && v(a, b) >= 5
    }
    /// `movedRecently`, with Motion & Fitness's word (0.33): "automotive" is moving like a bus or train at once;
    /// walking quickly, running or cycling (at your own speeds) isn't. Without it: `movedRecently`.
    var movingLikeVehicle: Bool {
        MotionRules.movingLikeVehicle(byFixes: movedRecently, motion: Motion.shared.now(), speed: currentSpeed)
    }
    /// The Fastest trip screen is open: it needs GPS (also locked) to plan from where you are and notice when you get on.
    private(set) var going = false

    private static func savedDirection() -> Direction {
        let d = UserDefaults.standard
        if let at = d.object(forKey: "dirAt") as? Date, Date().timeIntervalSince(at) < 3 * 3600, let raw = d.string(forKey: "dir"), let dir = Direction(rawValue: raw) { return dir }
        return Calendar.current.component(.hour, from: Date()) < 12 ? .toSchool : .home
    }
    /// You tapped the big button.
    func pick(_ d: Direction) {
        direction = d
        UserDefaults.standard.set(d.rawValue, forKey: "dir"); UserDefaults.standard.set(Date(), forKey: "dirAt")
        UserDefaults.standard.set(Date(), forKey: "dirPickedAt")
    }

    /// When the app opens (or comes back after half an hour): in Veghel you're going to Breda, in Breda you're going home.
    /// Somewhere else it keeps what it had. A direction you just picked yourself (in the last 20 minutes) stays.
    func guessFromPlace(_ l: CLLocation) {
        guard guessDirection, !isRiding, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 1500, l.timestamp.timeIntervalSinceNow > -600 else { return }
        guessDirection = false
        if let at = UserDefaults.standard.object(forKey: "dirPickedAt") as? Date, Date().timeIntervalSince(at) < 20 * 60 { return }
        func near(_ p: Place, _ m: Double) -> Bool { l.distance(from: CLLocation(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude)) < m }
        let corridor = RoleSnapshot.corridor != nil
        let d: Direction? = near(.home, 5000) ? .toSchool : ((corridor && near(.breda, 6000)) || near(.school, 6000)) ? .home : nil
        guard let d, d != direction else { return }
        direction = d
        UserDefaults.standard.set(d.rawValue, forKey: "dir"); UserDefaults.standard.set(Date(), forKey: "dirAt")
        toast = d == .toSchool ? RoleWords.current.atHomeToast : RoleWords.current.atSchoolTownToast
    }
    /// After 3 hours the direction follows the clock again.
    private func followClock() {
        guard !isRiding else { return }
        let d = Self.savedDirection()
        if d != direction { direction = d }
    }

    /// Reaching BUas switches to going home, once a day.
    func maybeAutoHome(_ l: CLLocation) {
        let today = Fmt.ymd.string(from: Date())
        guard autoHome, direction == .toSchool, !isRiding, UserDefaults.standard.string(forKey: "autoHomeDay") != today, NearMe.atSchool(l) else { return }
        UserDefaults.standard.set(today, forKey: "autoHomeDay")
        pick(.home)
        toast = RoleWords.current.autoHomeToast
    }
    var isRiding: Bool { phase != .idle }

    override init() {
        soundKind = AlarmSound.Kind(rawValue: UserDefaults.standard.string(forKey: "sound") ?? "") ?? .steam
        super.init()
        Watchdog.shared.mark("starting the trip engine (location, notifications)")
        BatteryMeter.start()                              // the battery and data log (0.20.7)
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 25
        location.activityType = .otherNavigation
        location.pausesLocationUpdatesAutomatically = false
        always = location.authorizationStatus == .authorizedAlways
        DispatchQueue.main.async { [weak self] in self?.updateKeepAlive() }
        music.onChange = { [weak self] in self?.pushActivity(force: true) }
        LineWatchStore.shared.onChange = { [weak self] in self?.updateKeepAlive() }
        Motion.shared.listen("trip") { [weak self] in self?.motionChanged() }
        GoStore.shared.trip = self
        SchoolAlarm.shared.trip = self
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.awaySince = Date()
                // (whatever screen is up, a ride's too: what's waiting to be written goes now)
                FieldLog.shared.flush(); DelayBook.shared.save()
                if self?.phase != .idle { StillCache.shared.purge() }     // (a trip runs: the home screen's stills go)
                self?.endFinishedIfDue()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.endFinishedIfDue(back: true)
                if self.phase == .idle {
                    StillCache.shared.warm()
                    // (a trip that ended in the background may have asked for GPS for a line watch from there)
                    if self.gpsApplied?.on == true { self.applyGPS(restart: true) }
                }
            }
        }
        // Home or School moved (Your places): the wake distances for the old one are gone (`ProfileStore` cleared them
        // in the saved copy), and the regions go where they are now
        NotificationCenter.default.addObserver(forName: .rolesMoved, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.kmMem = UserDefaults.standard.dictionary(forKey: "kmMem") as? [String: Double] ?? [:]
                self.updateWatching(force: true)
            }
        }
        // "Stop alarm" right on the alarm notification. (No .foreground or .authenticationRequired: it runs on the
        // phone in the background, locked or not, so it also works from a paired Apple Watch, 0.37.1.)
        let stop = UNNotificationAction(identifier: WristNotice.stopAction, title: WristNotice.stopTitle, options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "stop.circle.fill"))
        // "Still on bus 306?" after a pick by hand (0.20.5): Yes, or Pick again (that one opens the app)
        let yes = UNNotificationAction(identifier: "STILL_YES", title: "Yes", options: [])
        let again = UNNotificationAction(identifier: "STILL_PICK", title: "Pick again", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            // (customDismissAction: swiping the alarm away is reported, and stops it, 0.24.6)
            // (0.42.1: its title shows even with Show Previews "When Unlocked", so you see what rings before you stop it)
            UNNotificationCategory(identifier: WristNotice.alarmCategory, actions: [stop], intentIdentifiers: [],
                                   options: [.customDismissAction, .hiddenPreviewsShowTitle]),
            // (0.37.1) the heads-up, arriving and the backup: Stop alarm too (the chime, the announcement, or the alarm
            // ringing meanwhile)
            UNNotificationCategory(identifier: WristNotice.tripCategory, actions: [stop], intentIdentifiers: [], options: []),
            // the school wake-up's notifications: Stop alarm takes the repeats away (0.37.1)
            UNNotificationCategory(identifier: WristNotice.wakeCategory, actions: [stop], intentIdentifiers: [],
                                   options: [.customDismissAction, .hiddenPreviewsShowTitle]),
            UNNotificationCategory(identifier: Self.stillOnCategory, actions: [yes, again], intentIdentifiers: [], options: []),
            // 0.34: "IC to 's-Hertogenbosch or IC to Eindhoven?" (its buttons are named when it asks)
            Self.whichTrainButtons(["The first one", "The other one"]),
        ])
        // (0.42.1) `AlarmResponder` is the notifications' delegate from launch on (so a button pressed while the app
        // wasn't running isn't lost); from here it hands them all to this, as before
        AlarmResponder.shared.attach(self)
        sound.pauseMusic = pauseMusic
        sound.headphonesOnly = headphonesOnly
        sound.loudLaterOn = outLoudLater
        WatchStore.shared.holdAlerts = { [weak self] in self?.phase == .sleeping }
        // (0.42.4) a platform change of a train of this trip: on the change card and the lock screen at once
        WatchStore.shared.onChange = { [weak self] in
            guard let self, self.phase != .idle else { return }
            self.updateChangeGuide()
            self.pushActivity(force: true)
        }
        WatchStore.shared.chime = { [weak self] in
            guard let self else { return }
            self.sound.play(preview: self.soundKind)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                guard let self, WatchStore.shared.alert != nil else { return }
                self.sound.play(preview: self.soundKind)
            }
        }
        updateWatching()
        // a trip doesn't outlive the app: whatever is still on the lock screen from before is stale
        Self.endLeftoverActivities()
        RideCacheStore.shared.clear()                     // (0.39) and so is a saved copy of its rides
    }

    // MARK: trip flow

    /// `picked`: you said you're on `v` (as "I'm on this one" in the list): it's the one, not a guess to check.
    /// `onIt`: without `v`, you said you're on the ride this leg was planned with ("I'm on it"): it holds while you're on
    /// its road. `how`: how it started, for the field log.
    func start(_ r: RoutePlan, at legIndex: Int = 0, vehicle v: Vehicle? = nil, auto: Bool = false, kms: [Double]? = nil, backup: Int? = nil, stops: [TripStop]? = nil,
               alternatives: [DoorTrip] = [], couldBe: [Vehicle] = [], picked: Bool = false, onIt: Bool = false, how: String = "hand") {
        if !demo { BatteryMeter.rideStart() }             // (a ride already on ends there first)
        resumable = nil                                   // (a new trip: the one you ended isn't gone on with)
        route = r
        boardAlternatives = alternatives
        legs = r.legs(direction)
        index = min(legIndex, legs.count - 1)
        autoStarted = auto
        if let kms {
            for (l, k) in zip(legs, kms) { kmMem["\(l.mode.rawValue):\(l.to.key)"] = k }
            UserDefaults.standard.set(kmMem, forKey: "kmMem")
        }
        tripStart = Date(); startedAtLeg = index; lastScore = nil; betterKept = []
        wrongBusTold = false; wrongBus = nil; gpsRuns = [:]; otherTold = []; otherClosed = []; otherAtStop = nil; otherBoard = nil
        tripStartSpot = lastFix.flatMap { Date().timeIntervalSince($0.timestamp) < ScoreRules.freshStart ? $0.coordinate : nil }
        tripPlannedEnd = r.plannedEnd; tripLate = nil; trainLate = []
        if !demo { TravelNotes.shared.tripStarted(); TravelNotes.shared.noteLegs(legs) }   // (0.36) your usual trains
        boardedNoted = demo || index > 0 || r.custom == nil; changeArrived = nil
        if !demo, index == 0, let first = r.custom?.first { HabitStore.shared.plannedFrom(first.from.name) }
        setBackup(backup ?? backupMinutes)
        sound.startTrip()
        music.start()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        beginLeg(vehicle: v, stops: stops, how: how)
        watchLeft = nil                                   // (a trip runs: the look after leaving a station is over)
        if picked, v != nil { pickedByHand = true }
        if onIt, v == nil { heldPick = r.planned?[safe: index]?.tripId }
        if let v { beginChoosing([v] + couldBe) }
        startActivity()
        saveRidesAhead()                                  // (0.39) the trip's rides on the phone, for stretches without signal
    }

    private func beginLeg(vehicle v: Vehicle? = nil, stops: [TripStop]? = nil, how: String = "hand") {
        // GPS was running already (a ride, a change, Fastest trip, a station you left): a fix that has had no newer one
        // is still where you are (it comes every 25 m)
        let tracked: Bool
        switch phase {
        case .idle, .finished: tracked = going || watchLeft != nil
        default: tracked = true
        }
        phase = .sleeping
        distance = nil; forceArrival = false; maxDistance = legSpan; legStartMetres = nil; heldPick = nil; heldFromPlan = false
        legStart = Date()
        arrival = nil; next = nil; legArrival = nil; legFrom = nil; legTo = nil
        vehicle = v
        vehicleStops = []; matchMeters = nil; pickedByHand = false; byTimetable = false; startDistance = nil
        handLock = nil; stillOnAsk = nil
        roadOf = nil; offRoad = 0; farLooks = 0; sameCheckAt = Date().addingTimeInterval(45)
        cands = []; choosing = []; candSince = nil; candLead = nil; candSwitch = SwitchState(); candMisses = [:]; candTimedOut = nil; candGPS = GPSChoice()
        legClosest = nil; awayLooked = false
        transferAnchor = nil; changeSince = nil; finishedAt = nil; finishTask?.cancel(); finishTask = nil
        backstopHit = false; sameOK = nil
        smoother = SpeedSmoother(); lastSpeedFix = nil; wakeLive = nil; wakeRoute = []
        whichTrain = []; whichTrainTo = [:]; whichTrainAsked = false; trainSeen = [:]; rivalLookAt = Date().addingTimeInterval(60)
        lastGood = nil; reckonFrom = nil; reckoning = false
        readyTold = false; ringNote = nil; arrivePlatform = nil; legDelay = nil; changeGuide = nil; nextOptions = []; usingSaved = false
        missHold = MissCall.Hold(); quietLeg = false; ringInUse = false; headsign = ""; stayOnTo = nil
        betterOffer = nil; betterTask?.cancel(); betterTask = nil; betterAt = .distantPast
        meant = route?.planned?[safe: index]; meantTo = leg?.to; wrongBus = nil; otherAtStop = nil      // (0.39.1)
        if index > 0, !demo, let a = changeArrived, let l = leg { noteChangeWalk(arrived: a.at, at: l.from) }
        changeToRecord = index > 0 && changeArrived != nil
        Motion.shared.live(!demo, for: "trip")
        applyGPS(restart: true)                           // the best GPS, also locked (far from the stop: `RideGPS`)
        // A leg that starts inside its wake distance (a short one, or one started near its stop): awake from the start,
        // without the alarm, whenever its first fix comes; the announcement comes at the stop. (Without a fix that says
        // where you are now, the first fix within 20 s decides, in `handle`.)
        if let f = startFix(tracked: tracked), let l = leg {
            legStartMetres = f.distance(from: CLLocation(latitude: l.to.coordinate.latitude, longitude: l.to.coordinate.longitude))
        }
        rideLog(FieldFormat.rideStart(how: how, vehicle: v.map(Self.logLabel), stopMetres: legStartMetres, leg: index + 1, of: legs.count))
        if !demo, RideGuards.wakeAtStart(targetMetres: legStartMetres, wakeMetres: wakeKm * 1000) == .awakeSilently {
            phase = .awake; forceArrival = true; quietLeg = true
            rideLog(FieldFormat.rideWake(startedMetres: legStartMetres))
        }
        if let v { Task { await self.vehicleFound(v, stops: stops) } } else { startDetecting() }
        refreshEta(force: true)
        Task { await loadUpcoming(force: true) }
    }

    /// Your fix as a leg starts, when it still says where you are: one within 100 m of the last minute, or, with GPS
    /// running already, of the last two.
    private func startFix(tracked: Bool) -> CLLocation? {
        guard let f = lastFix, f.horizontalAccuracy >= 0, f.horizontalAccuracy < 100 else { return nil }
        let age = -f.timestamp.timeIntervalSinceNow
        return age <= 60 || (tracked && age <= 120) ? f : nil
    }

    /// "bus 321·1280" in the field log.
    nonisolated static func logLabel(_ v: Vehicle) -> String { FieldFormat.vehicle(line: v.line, tripId: v.tripId, isTrain: v.isTrain) }

    /// (0.42.4) Every train of the trip is watched for a platform change or a cancellation, not only a first ride that is
    /// a train (bus 305, then the Intercity at Eindhoven): its station, number and planned time (`PlatformWatch`), again
    /// whenever the trip is planned again. No trip: none of the trip's watches.
    private func watchTrains() {
        guard !demo, let r = route, let custom = r.custom, let planned = r.planned, planned.count == custom.count else {
            if route == nil || demo { WatchStore.shared.setRideWatches([]) }
            return
        }
        let now = Date()
        let list: [PlatformWatch.Leg] = custom.indices.map { k in
            let p: PlannedRide = planned[k]
            let code: String? = p.isTrain ? NSStore.code(custom[k].from) : nil
            return PlatformWatch.Leg(train: p.isTrain, num: p.num, code: code, planned: p.scheduled ?? p.departure)
        }
        let rides: [WatchStore.RideWatch] = PlatformWatch.toWatch(list, now: now).compactMap { k -> WatchStore.RideWatch? in
            guard let c = list[k].code else { return nil }
            let p: PlannedRide = planned[k]
            let name: String = p.line == "IC" ? "Intercity" : p.line
            let label: String = "\(Fmt.hhmm(list[k].planned)) \(name) to \(custom[k].to.short)"
            return WatchStore.RideWatch(code: c, num: p.num, planned: list[k].planned, label: label, from: custom[k].from.short,
                                        platform: p.platform)
        }
        WatchStore.shared.setRideWatches(rides)
    }

    /// (0.42.4) How old a vehicle's own GPS fix was in the matcher's last look (nil: judged by its times there, or not in
    /// it), for Fastest trip's look at what you got on (`WaitStart`).
    func gpsAge(of tripId: String) -> TimeInterval? {
        guard let j = lastJudged.first(where: { $0.id == tripId }), let e = j.evidence, e.gps else { return nil }
        return max(0, e.gpsAge ?? 0)
    }

    /// (0.42.4) How long a vehicle's own GPS has fitted you without a long gap (`WrongBus.Run`; nil: not lately).
    func gpsWithYou(_ tripId: String, now: Date = Date()) -> TimeInterval? {
        guard let r = gpsRuns[tripId], now.timeIntervalSince(r.last) <= WrongBus.fresh else { return nil }
        return r.last.timeIntervalSince(r.first)
    }

    /// A ride line in the field log; with `once`, not again for the same thing within `every` seconds.
    private func rideLog(_ text: String, once key: String? = nil, every: TimeInterval = 30) {
        if let key {
            let now = Date()
            if let t = rideLogged[key], now.timeIntervalSince(t) < every { return }
            if rideLogged.count > 60 { rideLogged = rideLogged.filter { now.timeIntervalSince($0.value) < 600 } }
            rideLogged[key] = now
        }
        FieldLog.shared.add(.ride, text)
    }

    /// How far your last fix is from this leg's stop.
    private var metresToLegStop: Double? {
        guard let f = lastFix, let l = leg else { return nil }
        return f.distance(from: CLLocation(latitude: l.to.coordinate.latitude, longitude: l.to.coordinate.longitude))
    }

    /// A ride started without you (by itself, by Fastest trip, or planned again from a vehicle) whose first stop is
    /// where you are already would ring and say "You're at …" at once: refused (`RideGuards.startsAtItsStop`), with a
    /// line in the field log. (Started by hand it still goes.)
    func refusesAtItsStop(_ r: RoutePlan, at i: Int = 0, direction dir: Direction? = nil, what: String, vehicle v: Vehicle) -> Bool {
        guard let f = lastFix, let l = r.legs(dir ?? direction)[safe: i] else { return false }
        let d = f.distance(from: CLLocation(latitude: l.to.coordinate.latitude, longitude: l.to.coordinate.longitude))
        guard RideGuards.startsAtItsStop(targetMetres: d, accuracy: f.horizontalAccuracy) else { return false }
        rideLog(FieldFormat.rideRefused(what, vehicle: Self.logLabel(v), stopMetres: d, accuracy: f.horizontalAccuracy),
                once: "refused|\(what)|\(v.tripId)", every: 60)
        return true
    }

    /// Still at the start of this leg (within 2 km) and not on board yet: show what leaves next.
    /// (Not once you said "none of these" during the ride: then you're on board, going by your location.)
    var waitingToBoard: Bool { phase == .sleeping && vehicle == nil && handLock == nil && (startDistance ?? 0) < 2000 }

    func stopAlarm() {
        ringInUse = false
        sound.stop()
        cancelAgain()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        guard case .alarm(let approach) = phase else { return }
        if approach, var n = ringNote, n.stopped == nil { n.stopped = Date(); ringNote = n }   // (0.39) how soon you reacted
        if approach && (ringAtStop || forceArrival) { phase = .awake; pushActivity(force: true); WatchStore.shared.showNext() } else { legDone(why: "alarm stopped") }
    }

    /// You're at the end of a leg (by GPS, by the alarm, or "I'm off"); `why`, for the field log.
    func legDone(why: String = "by hand") {
        rideLog(FieldFormat.rideArrive(why: why, metres: distance, accuracy: accuracy, legAge: Date().timeIntervalSince(legStart), started: legStartMetres))
        // (0.39) at your stop (by GPS, or you said you're off): how much time the ring before it left you
        if ["by GPS", "by GPS, quietly", "by hand"].contains(why) { noteWakeOutcome(arrivedRinging: false) }
        ringNote = nil
        let gotOff = vehicle?.tripId
        if !demo, TravelNotes.shared.checkOut { remindCheckOut(gotOff: gotOff) }     // (0.36)
        let rideId: String? = demo ? nil : leg.flatMap { l in tripStart.flatMap { keepRide(l, tripStart: $0) } }
        if let v = vehicle, let l = leg, !demo { noteDelay(v, at: l.to, rideId: rideId) }
        // 0.38: a ride it found by itself and you rode to the end of the leg teaches your usual line (a pick by hand
        // taught it already)
        // 0.39.1: only on the line it was planned with (`UsualLine.learnsFound`): not the 154 you were on by mistake
        if let v = vehicle, !pickedByHand, handLock == nil, Date().timeIntervalSince(legStart) >= 120 {
            if UsualLine.learnsFound(line: v.line, train: v.isTrain, plannedLine: meant?.line, plannedTrain: meant?.isTrain) {
                learnLine(v, weight: UsualLine.confirmed)
            } else {
                rideLog("usual line · not learned: \(Self.logLabel(v)) isn't the planned \(meant?.line ?? "?")")
            }
        }
        handLock = nil; stillOnAsk = nil                   // (a pick by hand holds for its leg only)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.stillOnId])
        sound.stop()
        cancelAgain()
        setBackup(0)
        arrivedAt = leg?.to.short
        if let l = leg { lastEnd = (l.to.key, Date()); lastEndSpot = (l.to.coordinate, Date()) }
        stopReckon()
        whichTrain = []; whichTrainTo = [:]
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.whichTrainId])
        if index + 1 < legs.count {
            phase = .transfer
            changeArrived = (Date(), route?.planned?[safe: index]?.line ?? vehicle?.line ?? "")
            changeSince = Date(); changeFirst = nil
            changePlanned = route?.planned?[safe: index + 1].map { TransferPolicy.Listed(id: $0.tripId, departure: $0.departure) }
            transferAnchor = lastFix.flatMap { TransferPolicy.update(nil, with: Fix($0)) }      // standing where you got off
            // Keep looking for the next bus or train, so the next leg starts by itself once you're on board: not the one
            // you just got off (unless the next leg was planned with it too).
            let exclude = gotOff.flatMap { id in route?.planned?[safe: index + 1]?.tripId == id ? nil : id }
            vehicle = nil; pickedByHand = false; startDetecting(forNextLeg: true, excluding: exclude)
            updateChangeGuide()                           // (0.39) the platforms, the walk, the minutes to the next one
            Task { await loadUpcoming(force: true) }
        } else {
            phase = .finished
            finishedAt = Date()
            scoreTrip()
            considerClaim()                                   // (0.36) a train 30 min late: money back from NS
        }
        applyGPS()                  // a change: as on the ride, until you stand still a while; the end: off
        pushActivity(force: true)
        if phase == .finished { afterArrival() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { WatchStore.shared.showNext() }
    }

    /// (0.36) "Did you check out?" a minute after you got off, where the OV-chipkaart wants you to (`CheckOut`): the
    /// trip's end, off a bus, between bus and train, between train companies. Taken back when you turn out to be still
    /// on board in that minute (the next leg found the one you got off; at the end, two fixes at a vehicle's speed).
    private func remindCheckOut(gotOff: String?) {
        guard TravelNotes.shared.checkOut, let l = leg else { return }      // (0.42.4: off unless you turn it on)
        let planned = route?.planned
        var rides: [CheckOut.Ride] = legs.indices.map { k in CheckOut.Ride(train: legs[k].mode == .train, company: planned?[safe: k]?.agency) }
        if let v = vehicle, rides.indices.contains(index) { rides[index] = CheckOut.Ride(train: v.isTrain, company: rides[index].company) }
        guard CheckOut.due(after: index, of: rides) else { return }
        let next: CheckOut.Ride? = index + 1 < rides.count ? rides[index + 1] : nil
        let t = CheckOut.text(at: l.to.short, change: next.map { (fromTrain: rides[index].train, toTrain: $0.train) })
        if let p = checkOutPending { TravelNotes.cancel(id: p.id) }
        let id = "checkout-\(Int(Date().timeIntervalSince1970))-\(index)"
        checkOutPending = CheckOutPending(id: id, at: Date(), speeds: [], gotOff: gotOff, end: next == nil)
        TravelNotes.post(id: id, title: t.title, body: t.body, kind: "info", after: CheckOut.after)
        rideLog("check-out reminder in \(Int(CheckOut.after)) s (\(next == nil ? "the end" : "a change"))")
    }

    /// In the minute after you got off: still on board takes the reminder back.
    private func checkOutLook(speed: Double?, sameVehicle: Bool) {
        guard var p = checkOutPending else { return }
        guard Date().timeIntervalSince(p.at) < CheckOut.after else { checkOutPending = nil; return }
        if let s = speed { p.speeds.append(s) }
        if CheckOut.stillAboard(speeds: p.speeds, sameVehicle: sameVehicle) {
            TravelNotes.cancel(id: p.id)
            checkOutPending = nil
            rideLog("check-out reminder taken back: still on board")
        } else {
            checkOutPending = p
        }
    }

    /// (0.36) NS's money back for a late train (`DelayClaim`): after the trip, once, when its trains got you there 30
    /// minutes late or more, with a link to NS's claim page.
    private func considerClaim() {
        guard !demo, TravelNotes.shared.delayClaim, let s = tripStart, claimTold != s else { return }
        guard phase == .finished || phase == .idle else { return }
        let lastIsTrain = phase == .finished && legs.last?.mode == .train
        let end: Date? = phase == .finished ? finishedAt : nil
        let m = DelayClaim.minutesLate(plannedEnd: lastIsTrain ? tripPlannedEnd : nil, actualEnd: lastIsTrain ? end : nil, trainDelays: trainLate)
        guard DelayClaim.due(minutesLate: m, told: false), let mins = m else { return }
        claimTold = s
        let t = DelayClaim.text(minutesLate: mins)
        TravelNotes.post(id: "nsclaim-\(Int(s.timeIntervalSince1970))", title: t.title, body: t.body, kind: "late", after: 60, url: DelayClaim.claimURL)
        rideLog("money back from NS: \(Int(mins.rounded())) min late")
    }

    /// The trip at its last stop goes on the leaderboard (`ScoreRules.board`): a corridor route by its name, a planned
    /// trip between Home and School as "home→school" / "school→home", on or off the corridor (0.35: until then a
    /// planned trip on the corridor, which is every trip the new look's home starts, was never scored).
    private func scoreTrip() {
        guard let r = route, let s = tripStart else { return }
        let kind: ScoreRules.Kind = r.isFixed ? .fixed(r.name) : r.single != nil ? .single : .custom
        var starts: [GeoPoint] = []
        if let a = tripStartSpot { starts.append(GeoPoint(a)) }
        if let f = r.custom?.first?.from.coordinate { starts.append(GeoPoint(f)) }
        let f = ScoreRules.Finished(kind: kind, demo: demo, startedAtLeg: startedAtLeg, home: direction == .home, starts: starts,
                                    end: legs.last.map { GeoPoint($0.to.coordinate) },
                                    homePlace: Place.home.point, school: Place.school.point)
        guard let k = ScoreRules.board(f) else { return }
        if case .fixed = kind {
            lastScore = ScoreBook.shared.log(route: r, home: k.home, start: s)
        } else {
            let plan = tripPlannedEnd.map { $0.timeIntervalSince(s) / 60 }
            lastScore = ScoreBook.shared.log(door: k.route, home: k.home, start: s, plan: plan, lateLine: tripLate?.line, late: tripLate?.mins)
        }
    }

    /// After the last stop: once the arrival chime has played, the silent keep-alive sound, the music look and the lock
    /// screen's updates stop (nothing is left to ring: the backup alarm went at the stop); after 10 minutes the trip
    /// ends by itself (also when the app comes back after that, if iOS paused it meanwhile).
    private func afterArrival() {
        finishTask?.cancel()
        guard let at = finishedAt else { return }
        finishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AfterArrival.quietAfter * 1_000_000_000))
            guard let self, !Task.isCancelled, self.phase == .finished, self.finishedAt == at else { return }
            // (what the last stop wrote, its delay and the ride lines, before iOS may pause the app)
            FieldLog.shared.flush(); DelayBook.shared.save()
            self.sound.endTrip()
            self.music.stop()
            if let a = self.activity {
                // "You're there" stays on the lock screen until the trip would end by itself
                let content = ActivityContent(state: self.state, staleDate: nil)
                self.activity = nil; self.endedActivity = a
                Task { await a.end(content, dismissalPolicy: .after(at.addingTimeInterval(AfterArrival.endAfter))) }
            }
            try? await Task.sleep(nanoseconds: UInt64((AfterArrival.endAfter - AfterArrival.quietAfter) * 1_000_000_000))
            // after 10 minutes, once the app isn't on screen (with "You're there" in front of you, it waits for Done)
            while !Task.isCancelled, self.phase == .finished, self.finishedAt == at {
                if self.endFinishedIfDue() { return }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    /// The finished trip ends 10 minutes after the last stop, in the background only: now (`back`: coming back to the
    /// screen, if those 10 minutes went by while the app was away). True: it ended.
    @discardableResult private func endFinishedIfDue(back: Bool = false) -> Bool {
        guard phase == .finished, let f = finishedAt, AfterArrival.end(finishedAt: f, now: Date()) else { return false }
        if back {
            guard let a = awaySince, a <= f.addingTimeInterval(AfterArrival.endAfter) else { return false }
        } else {
            guard UIApplication.shared.applicationState == .background else { return false }
        }
        rideLog(FieldFormat.rideEnd("10 min after the last stop"))
        endTrip()
        return true
    }

    /// `held`: the ride it holds on its road (see `heldPick`): one you picked, or (`fromPlan`) the planned one you're on
    /// the road of at a change.
    func nextLeg(vehicle v: Vehicle? = nil, backup: Int? = nil, stops: [TripStop]? = nil, how: String = "next leg by hand", held: String? = nil,
                 fromPlan: Bool = false) {
        guard index + 1 < legs.count else { return }
        index += 1
        sound.startTrip()
        setBackup(backup ?? backupMinutes)
        beginLeg(vehicle: v, stops: stops, how: how)
        if v == nil { heldPick = held; heldFromPlan = held != nil && fromPlan }
        pushActivity(force: true)
    }

    /// A trip you ended by hand before its last leg (0.26.2): the home offers to go on with it for a while, from that
    /// leg (`TripResume`). Kept while the app runs; a new trip forgets it.
    struct Resumable {
        let route: RoutePlan
        let direction: Direction
        let leg: Int
        let legs: [Leg]
        let endedAt: Date
        /// (0.35) How the trip began, so going on with it is still the same trip on the leaderboard.
        var began: (start: Date, leg: Int, spot: CLLocationCoordinate2D?, plannedEnd: Date?, late: (line: String, mins: Double)?)?
        var from: Place { legs[leg].from }
        var next: Leg { legs[leg] }
        var destName: String { legs.last?.to.short ?? route.station.short }
    }
    @Published private(set) var resumable: Resumable?

    /// Go on with the trip you ended by hand (`resumable`): from its leg, looking for the one you get on, as at a change.
    func resumeTrip() {
        guard phase == .idle, let r = resumable else { return }
        resumable = nil
        if direction != r.direction { pick(r.direction) }
        start(r.route, at: r.leg, how: "go on after ending by hand")
        // (0.35) the same trip as before: scored from where and when it first started
        if let b = r.began {
            tripStart = b.start; startedAtLeg = b.leg; tripStartSpot = b.spot; tripPlannedEnd = b.plannedEnd; tripLate = b.late
        }
    }

    /// "Not now" on the home's offer to go on with it.
    func forgetResumable() { resumable = nil }

    /// `byHand`: you ended it (Hold to end trip, End trip here): before its last leg it can be gone on with (`resumable`).
    func endTrip(byHand: Bool = false) {
        var resume: Resumable?
        if byHand, phase != .idle, !demo {
            rideLog(FieldFormat.rideEnd(phase == .transfer ? "by hand at a change" : "by hand"))
            if let r = route, let n = TripResume.leg(atChange: phase == .transfer, finished: phase == .finished, index: index, count: legs.count) {
                resume = Resumable(route: r, direction: direction, leg: n, legs: legs, endedAt: Date(),
                                   began: tripStart.map { (start: $0, leg: startedAtLeg, spot: tripStartSpot, plannedEnd: tripPlannedEnd, late: tripLate) })
            }
        }
        if phase != .idle, !demo { BatteryMeter.rideEnd(legs: max(1, index - startedAtLeg + 1)) }   // its line in the field log
        if phase != .idle, let v = vehicle { HomeActions.rideEnded(on: v) }   // (the home doesn't start it again by itself)
        activityLater?.cancel(); activityLater = nil
        farTask?.cancel(); farTask = nil
        detectTask?.cancel(); detectTask = nil
        demoTask?.cancel(); demoTask = nil; demo = false
        finishTask?.cancel(); finishTask = nil; finishedAt = nil
        watchLeft = nil; transferAnchor = nil; changeSince = nil; changeFirst = nil; changePlanned = nil
        setBackup(0)
        sound.endTrip()
        music.stop()
        phase = .idle
        route = nil; legs = []; distance = nil; arrival = nil; next = nil; vehicle = nil; legArrival = nil; arrivedAt = nil
        upcoming = []; upcomingAt = nil; upcomingError = nil; upcomingKey = ""; upcomingBoard = []; upcomingAsOf = nil; vehicleStops = []; matchMeters = nil; speed = nil; currentSpeed = nil; startDistance = nil
        roadOf = nil; offRoad = 0; farLooks = 0; boardAlternatives = []
        cands = []; choosing = []; candSince = nil; candLead = nil; candSwitch = SwitchState(); candMisses = [:]; candTimedOut = nil; candGPS = GPSChoice()
        legFrom = nil; legTo = nil; maxDistance = nil
        handLock = nil; stillOnAsk = nil; pickAgain = false; headsignOf = [:]
        smoother = SpeedSmoother(); lastSpeedFix = nil; wakeLive = nil; wakeRoute = []; waitLowOn = false
        stopReckon(); whichTrain = []; whichTrainTo = [:]; changeArrived = nil; changeToRecord = false
        changeGuide = nil; switchingChange = false; arrivePlatform = nil; legDelay = nil; nextOptions = []; readyTold = false; ringNote = nil
        missHold = MissCall.Hold(); quietLeg = false; ringInUse = false; headsign = ""; stayOnTo = nil
        betterOffer = nil; betterTask?.cancel(); betterTask = nil; betterAt = .distantPast
        offline = false; usingSaved = false; plannedNextAt = .distantPast; plannedNextTrip = nil
        meant = nil; meantTo = nil; gpsRuns = [:]; wrongBus = nil; otherAtStop = nil; otherTold = []; otherClosed = []; otherBoard = nil
        RideCacheStore.shared.clear()                     // (0.39) the saved copy of the trip's rides goes with it
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.whichTrainId])
        Motion.shared.live(false, for: "trip")
        let a = activity, e = endedActivity; activity = nil; endedActivity = nil
        Task {
            await a?.end(nil, dismissalPolicy: .immediate)
            await e?.end(nil, dismissalPolicy: .immediate)
        }
        resumable = resume
        considerClaim()                                   // (0.36) ended by hand after a late train: still told once
        updateKeepAlive()                                 // GPS off, unless Fastest trip or a line watch wants it
        FieldLog.shared.flush(); DelayBook.shared.save()
    }

    /// While you watch a bus line (and no trip runs), cheap location keeps the app awake to check it,
    /// and notices when you get on that bus. (No trip: `applyGPS` for what's open.)
    func updateKeepAlive() {
        guard phase == .idle else { return }
        applyGPS()
    }

    private var gpsPhase: GPSPolicy.Phase {
        switch phase {
        case .idle: return .idle
        case .transfer: return .transfer
        case .finished: return .finished
        case .sleeping, .awake, .alarm: return .riding
        }
    }

    /// GPS as `GPSPolicy` has it for now: the trip's phase, Fastest trip, a line watch, the look after leaving a station;
    /// far from the stop with the vehicle confirmed (`RideGPS`), or Fastest trip standing with long to go (`GoGPS`).
    /// `restart`: start it again even when nothing changed (a fresh fix as a leg begins).
    private func applyGPS(restart: Bool = false) {
        let far = rideFarNow()
        let low = waitLowNow()
        let p = GPSPolicy.plan(phase: gpsPhase, demo: demo, going: going, lineWatch: !LineWatchStore.shared.watches.isEmpty,
                               regionLook: watchLeft != nil, rideFar: far, goCoarse: goCoarseNow(), waitLow: low)
        if low != waitLowOn {
            waitLowOn = low
            rideLog(low ? "gps · waiting, standing or walking about (motion): 100 m, every 50 m"
                        : "gps · the best again (\(motionWords))", once: "waitLow|\(low)", every: 60)
        }
        if far != rideFarOn {
            rideFarOn = far
            rideLog(far ? "gps · far from the stop, the vehicle confirmed: 10 m, every 75 m"
                        : "gps · the best again (\(FieldFormat.metres(metresToLegStop)) from the stop)", once: "far|\(far)", every: 60)
            farTask?.cancel(); farTask = nil
            if far {
                farTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        guard let self, !Task.isCancelled, self.rideFarOn else { return }
                        self.applyGPS()
                    }
                }
            }
        }
        updateBackstop(far)
        // (the battery log: the mode and why, also when only the why changed, as from a ride to a change)
        let why = p.on ? gpsReason : nil
        if restart || p != gpsApplied || why != gpsWhy { gpsWhy = why; BatteryMeter.tripGPS(p, reason: why) }
        guard restart || p != gpsApplied else { return }
        gpsApplied = p
        if p.on {
            switch p.accuracy {
            case .best: location.desiredAccuracy = kCLLocationAccuracyBest
            case .tenMetres: location.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            case .hundredMetres: location.desiredAccuracy = kCLLocationAccuracyHundredMeters
            }
            location.distanceFilter = p.filter
            location.allowsBackgroundLocationUpdates = p.background
            location.showsBackgroundLocationIndicator = p.background
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            location.startUpdatingLocation()
        } else {
            location.stopUpdatingLocation()
            location.allowsBackgroundLocationUpdates = false
        }
    }

    /// Why GPS is on, for the battery log.
    private var gpsReason: GPSReason? {
        switch gpsPhase {
        case .riding: return .ride
        case .transfer: return .change
        case .finished: return nil
        case .idle:
            if going { return .fastest }
            if watchLeft != nil { return .regionLook }
            return LineWatchStore.shared.watches.isEmpty ? nil : .lineWatch
        }
    }

    /// The vehicle you're on is confirmed: its "still the same bus?" look passed (the last one, for this one), none to
    /// choose between, on its road and near its times, not picked by hand during the ride (that one is watched on its
    /// road), not taken by its timetable alone.
    private var rideConfirmed: Bool {
        guard let v = vehicle, let ok = sameOK, ok.tripId == v.tripId, ok.looks >= 1 else { return false }
        return cands.isEmpty && choosing.isEmpty && offRoad == 0 && farLooks == 0 && handLock == nil && stillOnAsk == nil
            && !byTimetable && !demo
    }

    /// A "still the same bus?" look on `v`: passed (counted on), or not (back to none).
    private func noteSameLook(_ v: Vehicle, passed: Bool) {
        if passed { sameOK = (v.tripId, sameOK?.tripId == v.tripId ? (sameOK?.looks ?? 0) + 1 : 1) } else { sameOK = nil }
        applyGPS()
    }

    /// The far GPS tier for this leg now (`RideGPS.far`).
    private func rideFarNow() -> Bool {
        guard gpsPhase == .riding, !demo, let l = leg else { return false }
        let f = lastFix
        let input = RideGPS.Input(enabled: RideGPS.enabled(), asleep: phase == .sleeping, confirmed: rideConfirmed,
                                  metresToStop: metresToLegStop, accuracy: f?.horizontalAccuracy,
                                  fixAge: f.map { -$0.timestamp.timeIntervalSinceNow }, wakeMetres: gpsWakeMetres,
                                  isTrain: vehicle?.isTrain ?? (l.mode == .train), speed: currentSpeed,
                                  secondsToStop: (legArrival ?? legTo).map { $0.timeIntervalSinceNow },
                                  backstop: backstopHit, wasFar: rideFarOn,
                                  steady: MotionRules.steadyVehicle(Motion.shared.now(), now: Date()))
        return RideGPS.far(input)
    }

    /// The rough GPS while you wait for the one you get on (`MotionRules.waitLow`, 0.33): at a leg's first stop with
    /// nothing found yet, or at a change; Motion & Fitness says you stand or walk about, and your fixes don't move.
    private func waitLowNow() -> Bool {
        guard !demo, Motion.shared.usable else { return false }
        let fixesMove = movedRecently || RideGuards.movingNow(recentFixes, now: Date())
        if phase == .transfer, let n = legs[safe: index + 1], let f = lastFix {
            let d = f.distance(from: CLLocation(latitude: n.to.coordinate.latitude, longitude: n.to.coordinate.longitude))
            return MotionRules.waitLow(waiting: true, motion: Motion.shared.now(), movingByFixes: fixesMove, metresToStop: d,
                                       wakeMetres: WakeRule.gpsWakeMetres(wakeMetres: km(for: n) * 1000, effectiveWake, isTrain: n.mode == .train))
        }
        return MotionRules.waitLow(waiting: waitingToBoard && detectTask != nil, motion: Motion.shared.now(), movingByFixes: fixesMove,
                                   metresToStop: metresToLegStop, wakeMetres: gpsWakeMetres)
    }

    /// "motion: walking (high)", for the ride log.
    private var motionWords: String {
        guard let m = Motion.shared.now() else { return Motion.shared.on ? "motion: nothing yet" : "motion off" }
        return "motion: \(m.kind.rawValue) (\(m.confidence))"
    }

    /// Motion & Fitness said something new (0.33): during a trip, a line in the ride log; "automotive" while you wait
    /// for the one you get on (at its stop, or at a change) looks for it at once; and the GPS as it should be now.
    private func motionChanged() {
        guard phase != .idle, !demo else { return }
        let m = Motion.shared.now()
        let v = MotionRules.inVehicle(m)
        defer { motionVehicle = v }
        if let m { rideLog("motion · \(m.kind.rawValue) (\(m.confidence))", once: "motion|\(m.kind.rawValue)", every: 120) }
        if v, !motionVehicle, detectTask != nil, waitingToBoard || phase == .transfer {
            rideLog("motion · automotive: looking for the one you're on now", once: "motionKick", every: 30)
            wakeDetect()
        }
        applyGPS()
    }

    /// The detect loop's wait between looks: `seconds`, or less once `wakeDetect` says to look now.
    private func detectPause(_ seconds: TimeInterval) async {
        detectWakeN += 1
        let id = detectWakeN
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if let old = detectWake { old.c.resume() }
            detectWake = (id, c)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                self?.wakeDetect(id)
            }
        }
    }

    /// The detect loop looks now (nil), or the pause `id` is over.
    private func wakeDetect(_ id: Int? = nil) {
        guard let w = detectWake, id == nil || w.id == id else { return }
        detectWake = nil
        w.c.resume()
    }

    /// Fastest trip's rough GPS now: you leave more than 12 minutes from now, standing (`GoGPS`).
    private func goCoarseNow() -> Bool {
        guard going, phase == .idle, !demo, let b = GoStore.shared.best else { return false }
        let fixes = samples.map { Fix($0) }
        return GoGPS.coarse(leaveIn: b.start.timeIntervalSinceNow, standing: GoGPS.standing(fixes, now: Date()))
    }

    /// Fastest trip looked again: its GPS as it should be now (the time to leave comes nearer without a new fix).
    func goGPSCheck() { if phase == .idle { applyGPS() } }

    /// The backstop for the far tier: a region around this leg's stop (its wake distance and 4 km more) while the far tier
    /// is on, so it's the best GPS again well before the wake point even if the fixes say otherwise. Needs "Always".
    private func updateBackstop(_ far: Bool) {
        let key: String? = far ? leg.map { "\(index)|\($0.to.key)|\(Int(gpsWakeMetres))" } : nil
        guard key != backstopKey else { return }
        for r in location.monitoredRegions where r.identifier == Self.backstopId { location.stopMonitoring(for: r) }
        backstopKey = nil
        guard let key, let l = leg, location.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let radius = min(RideGPS.backstopRadius(wakeMetres: gpsWakeMetres), location.maximumRegionMonitoringDistance)
        let r = CLCircularRegion(center: l.to.coordinate, radius: radius, identifier: Self.backstopId)
        r.notifyOnEntry = true
        r.notifyOnExit = false
        location.startMonitoring(for: r)
        backstopKey = key
    }

    /// The region around the leg's stop was entered: the best GPS for the rest of the leg.
    private func backstopEntered() {
        guard gpsPhase == .riding, !backstopHit else { return }
        backstopHit = true
        rideLog("gps · backstop entered: the best again (\(FieldFormat.metres(metresToLegStop)) from the stop)")
        applyGPS()
    }

    /// The next leg's departures as listed just now, live: the first after you got there is latched, and it and the
    /// planned one follow their live times while they're listed (`TransferPolicy.firstListed`).
    /// `listFrom`: the time the list was asked from (older ones aren't in it because they're old, not cancelled).
    private func noteChangeList(listFrom: Date) {
        guard phase == .transfer, upcomingAsOf == nil, let since = changeSince else { return }
        let list = changeListed()
        changeFirst = TransferPolicy.firstListed(changeFirst, live: list, arrived: since, listFrom: listFrom)
        if let p = changePlanned { changePlanned = TransferPolicy.firstListed(p, live: list, arrived: since, listFrom: listFrom) }
    }

    /// The next leg's departures as listed now (not the cancelled ones).
    private func changeListed() -> [TransferPolicy.Listed] {
        guard let n = legs[safe: index + 1] else { return [] }
        return upcoming.filter { $0.from.key == n.from.key && !$0.trip.first.cancelled }
            .map { TransferPolicy.Listed(id: $0.trip.first.tripId, departure: $0.trip.first.departure) }
    }

    /// At a change with no ride an hour after the last one you could take (the latest of: you got there, the planned
    /// next one, the first listed after you got there, at their live times), while you've stood at the change for 10
    /// minutes: the trip ends, and says so. (Nothing rings at a change: the next leg's alarm comes only once you're on
    /// it.) True: it ended.
    private func endIfNoRide() -> Bool {
        let now = Date()
        guard phase == .transfer, let since = changeSince else { return false }
        let known = [changePlanned?.departure, changeFirst?.departure].compactMap { $0 }.max()
        guard TransferPolicy.giveUp(since: since, firstKnown: known, standingSince: transferAnchor?.since,
                                    listed: changeListed().map(\.departure), now: now) else { return false }
        let at = leg?.to.short ?? "the change"
        rideLog(FieldFormat.rideEnd("no ride an hour after the change"))
        let c = UNMutableNotificationContent()
        c.title = "Trip ended"
        c.body = "You didn’t get on at \(at) within the hour, so the trip has ended. Start it again when you go on."
        c.sound = .default
        c.userInfo = ["kind": "info"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "trip-ended", content: c, trigger: nil)) { _ in }
        endTrip()
        return true
    }

    /// The Fastest trip screen opened or closed.
    func setGo(_ on: Bool) {
        going = on
        updateKeepAlive()
    }

    /// When the app comes back to the screen: start the Live Activity if a trip started by itself in the background.
    func appBecameActive() {
        Watchdog.shared.mark("coming back to the screen")
        always = location.authorizationStatus == .authorizedAlways
        Task { await NoticeLog.shared.collectDelivered() }       // off the lock screen, into the app's list
        WakeAlarm.stopRinging()                                   // the school alarm still ringing: you're up (0.24.6)
        Task { await SchoolAlarm.shared.refresh() }               // the timetable may have changed: plan again (5 minutes apart at most)
        Morning.shared.checkAfterAlarm()                          // just woke up from the school alarm: the morning screen
        if let a = awaySince, Date().timeIntervalSince(a) > 30 * 60 { guessDirection = true }
        awaySince = nil
        followClock()
        if isRiding && activity == nil { startActivity() }
    }

    // MARK: location

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        NoticeSweep.soon()                                         // old notifications off the lock screen (once a minute)
        Task { @MainActor in if !self.demo { self.handle(loc) } }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.locationDenied = (s == .denied || s == .restricted)
            self.always = s == .authorizedAlways
            self.updateWatching()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let center = (region as? CLCircularRegion)?.center
        let id = region.identifier
        NoticeSweep.soon()
        Task { @MainActor in
            self.onRegion?(id, false)
            // (School's exit watched only for "at school" (0.29) starts nothing: the trip sees only the exits it asked for)
            if id == RoleRegions.schoolId, !RoleRegions.exitStartsTrip(id, base: self.wantedRegions()) { return }
            self.leftRegion(id, center: center)
        }
    }

    /// A region iOS couldn't watch (it says so once): register them all again, at most every 10 minutes.
    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        Task { @MainActor in
            guard Date().timeIntervalSince(self.lastRegionRetry) > 600 else { return }
            self.lastRegionRetry = Date()
            self.updateWatching(force: true)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        NoticeSweep.soon()
        if region.identifier == Self.backstopId { Task { @MainActor in self.backstopEntered() }; return }
        guard region.identifier == RoleRegions.schoolId else { return }
        let id = region.identifier
        Task { @MainActor in self.onRegion?(id, true) }
        Task { @MainActor in self.maybeAutoHome(CLLocation(latitude: Place.school.coordinate.latitude, longitude: Place.school.coordinate.longitude)) }
    }

    private func handle(_ loc: CLLocation) {
        // (0.32: Help improve Haltewekker › GPS points during rides, only when turned on and a trip runs; it only reads)
        if LogShareStore.shared.fixesOn { LogShareStore.shared.heard(loc, trip: self) }
        samples.append(loc)
        samples.removeAll { $0.timestamp < Date().addingTimeInterval(-240) }
        if phase == .finished, checkOutPending?.end == true, loc.speed >= 0 { checkOutLook(speed: loc.speed, sameVehicle: false) }   // (0.36)
        if loc.speed >= 0 {
            currentSpeed = loc.speed
            // (each new value redraws every screen that shows the trip: the home screen too, on every fix while idle)
            if SpeedPublish.worth(old: speed, new: loc.speed) { speed = loc.speed }
        }
        // A ride's network on one clock (0.20.7): whatever is due goes on the same 30 s tick, so the radio wakes once.
        let now = Date()
        let tick = (phase == .transfer || phase == .sleeping || phase == .awake) && RideTick.due(last: lastNetTick, now: now)
        if tick { lastNetTick = now; onNetTick?() }
        if phase == .transfer {
            transferAnchor = TransferPolicy.update(transferAnchor, with: Fix(loc))     // (standing at the change: for the hour's end)
            if tick { Task { await loadUpcoming() }; refreshPlannedNext(); updateChangeGuide(); checkOtherAtStop(); pushActivity(force: false) }
            // (0.42.4) the next train's platform at a change too (`WatchStore.check` asks at most once a minute)
            if tick { Task { await WatchStore.shared.check() } }
        }
        // Fastest trip: rough GPS while you stand with long to go, the best as soon as you move (`GoGPS`)
        if phase == .idle, going { applyGPS() }
        // (the look after leaving a station takes some 6 minutes: if it went without saying so, GPS doesn’t stay on for it)
        if phase == .idle, let w = watchLeft, Date().timeIntervalSince(w.at) > 10 * 60 { watchLeft = nil; applyGPS() }
        if phase == .idle, !LineWatchStore.shared.watches.isEmpty, Date().timeIntervalSince(lastIdleMatch) > 20 {
            lastIdleMatch = Date()
            Task {
                let R = MatchRules.current()
                guard let m = await self.matchVehicle(mode: .bus) else { self.idleBest = nil; return }
                let watched = LineWatchStore.shared.watches.contains { $0.line == m.vehicle.line }
                if watched && (m.cost < R.oneLookWatched || self.idleBest == m.vehicle.tripId) { LineWatchStore.shared.boarded(line: m.vehicle.line); self.idleBest = nil }
                else { self.idleBest = m.vehicle.tripId }
            }
        }
        guard let leg, phase == .sleeping || phase == .awake else { return }
        // (0.34) a good fix: where you are, and the end of any reckoning; on a ride its timer follows you meanwhile
        if DeadReckon.good(accuracy: loc.horizontalAccuracy) {
            lastGood = (loc.timestamp, loc.coordinate)
            if reckoning { reckoning = false; reckonFrom = nil; rideLog("reckon · good GPS again: where you are", once: "reckon-back") }
        }
        if vehicle != nil, !demo { startReckon() }
        startDistance = loc.distance(from: CLLocation(latitude: leg.from.coordinate.latitude, longitude: leg.from.coordinate.longitude))
        if vehicle == nil { if handLock == nil, tick { Task { await loadUpcoming() }; checkOtherAtStop() } }
        else if tick, now.timeIntervalSince(lastVehicleRefresh) >= RideTick.vehicleEvery - 1 { lastVehicleRefresh = now; Task { await refreshVehicle() } }
        // (choosing between buses is doubt: on its own 12 s clock)
        if vehicle != nil, !cands.isEmpty, Date() >= candCheckAt { candCheckAt = Date().addingTimeInterval(12); Task { await resolveCandidates() } }
        else if vehicle != nil, cands.isEmpty, tick, now >= sameCheckAt.addingTimeInterval(-1) { sameCheckAt = now.addingTimeInterval(30); Task { await checkSameBus() } }
        let d = loc.distance(from: CLLocation(latitude: leg.to.coordinate.latitude, longitude: leg.to.coordinate.longitude))
        distance = d
        // Further from this leg's stop than you've been, at train or bus speed (800 m when it's near, 2 km else): you're going
        // another way (past Boxtel to Den Bosch where it planned Eindhoven; on the 306 out of Den Bosch where it thought
        // you were on a bus into it). It looks at what you're really on, by the road, and plans the rest from it.
        if loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 150 {
            legClosest = min(legClosest ?? d, d)
            let gap: Double = (legClosest ?? d) < 3000 ? 800 : 2000
            if !awayLooked, !demo, route?.single == nil, HandLock.autoSwitch(handLock, leg: index), let c = legClosest, d > c + gap, LiveStore.movingFix(loc) {
                awayLooked = true
                Task { await self.wrongWay(loc) }
            }
        }
        if loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 250 { maxDistance = max(maxDistance ?? 0, d) }
        accuracy = loc.horizontalAccuracy
        let good = loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 250
        if good, legStartMetres == nil { legStartMetres = d }
        noteSpeed(loc)
        // The distance rule as it always was; by time (0.33) also the time rule, whichever comes first (`WakeRule`).
        // Within 20 s of the leg's start either one wakes it silently, as a leg that starts inside its wake distance.
        if phase == .sleeping && good, let fire = wakeFire(loc, metres: d) {
            // (0.42.3) a short leg doesn't ring; nothing rings in a leg's first minute (`ShortLeg.onFire`)
            let age: TimeInterval = Date().timeIntervalSince(legStart)
            let short: Bool = legIsShort
            switch ShortLeg.onFire(legAge: age, short: short) {
            case .quiet:
                // (a short leg: no alarm at the start, a quiet word a stop before, the announcement at the stop)
                phase = .awake; forceArrival = true; quietLeg = true
                if short { rideLog(FieldFormat.rideShort(spanMetres: legSpan, wakeMetres: wakeKm * 1000, after: age)) }
                else { rideLog(FieldFormat.rideWake(startedMetres: d, after: age)) }
            case .wait:
                rideLog(FieldFormat.rideRingHeld(legAge: age, metres: d), once: "ring-held|\(index)", every: 120)
            case .ring:
                ring(approach: true, why: WakeRule.log(fire), fire: fire)
            }
        } else if phase == .awake && d <= arriveM && loc.horizontalAccuracy <= 600 {
            // (0.42.3) a quiet leg is at its stop only after its first minute, and nearer (`ShortLeg.mayArrive`)
            let early: Bool = quietLeg && !ShortLeg.mayArrive(legAge: Date().timeIntervalSince(legStart), metres: d, startedMetres: legStartMetres)
            if early {
                rideLog("arrive · not yet: \(Int(d.rounded())) m from the stop of a short leg", once: "arrive-early|\(index)", every: 60)
            } else if ringAtStop || forceArrival { arrive() } else { legDone(why: "by GPS, quietly") }
        } else if case .alarm(approach: true) = phase, d <= arriveM, loc.horizontalAccuracy <= 600 {
            noteWakeOutcome(arrivedRinging: true)         // (0.39) there before you stopped it: next time a little earlier
            // (0.42.8) the one chime while you used the phone, never stopped: at the stop it goes on as before (the
            // announcement, or the leg ends quietly); a ring on repeat rings on until you stop it
            if ringInUse {
                ringInUse = false
                sound.stop(); cancelAgain()
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [WristNotice.alarmId])
                if ringAtStop || forceArrival { arrive() } else { legDone(why: "by GPS, quietly") }
            }
        }
        if phase == .sleeping { checkGetReady() }         // (0.39) "Get ready" one stop before yours
        if phase == .awake, quietLeg { checkShortNotice(metres: d) }    // (0.42.3) "Get off at the next stop"
        applyGPS()                                        // (far from the stop, or the best again: `RideGPS`)
        if tick { noteNetwork(); refreshPlannedNext(); updateChangeGuide() }
        if tick { refreshEta(force: false) }
        pushActivity(force: false)
        if tick, now.timeIntervalSince(lastWatchCheck) >= 59 { lastWatchCheck = now; Task { await WatchStore.shared.check() } }
    }

    /// Your speed for the time rule, from a good fix (`SpeedSmoother`).
    private func noteSpeed(_ loc: CLLocation) {
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 100 else { return }
        let f = Fix(loc)
        if let v = SpeedSmoother.reading(f, previous: lastSpeedFix) { smoother.add(v, at: f.t) }
        lastSpeedFix = f
    }

    /// What rings this leg now, from a good fix `metres` from its stop (`WakeRule.decide`; nil: nothing yet).
    private func wakeFire(_ loc: CLLocation, metres d: Double) -> WakeRule.Fire? {
        let train = legIsTrain
        let w = wakeKm * 1000
        let wake = effectiveWake                          // (0.39: a little earlier where it learned that)
        // (further than the time rule ever rings from: only the distance rule could, and it doesn't)
        if d > w, wake.by == .distance || d > WakeRule.reach(isTrain: train, minutes: wake.minutes(isTrain: train)) { return nil }
        let now = Date()
        let input = WakeRule.Input(by: wake.by, minutes: wake.minutes(isTrain: train), isTrain: train, metres: d,
                                   routeMetres: RouteLeft.metres(from: GeoPoint(loc.coordinate), along: wakeRoute), wakeMetres: w,
                                   liveArrival: wakeLive?.arrival, liveAge: wakeLive.map { now.timeIntervalSince($0.at) },
                                   speed: smoother.speed(now: loc.timestamp), fromStartMetres: startDistance, now: now)
        return WakeRule.decide(input)
    }

    /// The vehicle's own answer (asked `at`): your stop's live arrival for the time rule, and its road from where you got
    /// on to your stop for the distance left along it. Not live (timetable only): no arrival, the road still counts.
    private func noteWakeTrip(_ t: LiveTrip, at: Date) {
        guard let l = leg, t.stops.count >= 2 else { return }
        func d(_ i: Int, _ c: CLLocationCoordinate2D) -> Double { Geo.metres(GeoPoint(t.stops[i].coordinate), GeoPoint(c)) }
        guard let mine = t.stops.indices.min(by: { d($0, l.to.coordinate) < d($1, l.to.coordinate) }), d(mine, l.to.coordinate) < 1500 else {
            wakeLive = nil; wakeRoute = []
            return
        }
        let before = t.stops.indices.filter { $0 < mine }
        let board = before.min(by: { d($0, l.from.coordinate) < d($1, l.from.coordinate) }).flatMap { d($0, l.from.coordinate) < 1500 ? $0 : nil } ?? 0
        wakeRoute = t.road(from: t.metres(ofStop: board), to: t.metres(ofStop: mine)).map { GeoPoint($0) }
        wakeLive = t.live ? t.arrival(mine).map { (arrival: $0, at: at) } : nil
    }

    // MARK: alarm + announcement

    /// At the stop: the jingle and the announcement once, and a notification. The leg ends by itself: no second alarm.
    private func arrive() {
        let place = leg?.to.short
        let text = announcement(approach: false)
        let then = nextText
        legDone(why: "by GPS")
        sound.chime(announcement: text)
        let c = UNMutableNotificationContent()
        let t = WristNotice.arrived(stop: place, then: then, finished: phase == .finished)
        c.title = t.title
        c.body = t.body
        c.sound = sound.quietNow ? nil : .default         // no headphones: no ding for the whole train
        c.interruptionLevel = .timeSensitive
        c.userInfo = ["kind": "ok"]
        tripNotice(c, .arrived, category: WristNotice.tripCategory)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "arrived-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil)) { _ in }
    }

    private func announcement(approach: Bool) -> String? {
        guard announce, let leg else { return nil }
        let place = leg.mode == .train && !leg.to.spoken.contains("station") && !leg.to.spoken.contains("Central") ? "\(leg.to.spoken) station" : leg.to.spoken
        let veh = leg.mode == .train ? "train" : "bus"
        return approach ? "Attention please. We are now approaching \(place). Please get ready to leave the \(veh)."
                        : "Arriving at \(place). This is your stop. Please leave the \(veh) here."
    }

    /// (0.42.8) Every ring rings the same way (`RingShow`): the ringing state with Stop on the lock screen, the alarm's
    /// own notification, the alarm card in the app. In use, it's one chime (no loop); no headphones, vibration only.
    private func ring(approach: Bool, why: String = "approach", fire: WakeRule.Fire? = nil) {
        let inUse = quietWhenInUse && phoneInUse() && !demo
        let quiet: Bool = sound.quietNow
        let kind: RingShow.Kind = RingShow.kind(inUse: inUse, quiet: quiet)
        let how: String = inUse ? ", phone in use: one chime" : quiet ? ", no headphones: vibration only" : ""
        rideLog(FieldFormat.rideRing(why + how + ", ringing on the lock screen", metres: distance,
                                     legAge: Date().timeIntervalSince(legStart), started: legStartMetres))
        setBackup(0)
        // (0.37.1) short and the stop first, for a glance at a paired Apple Watch: "Get off at Breda · 2 min"
        var secs: Double?
        if case .time(_, _, let s)? = fire { secs = s }
        let t = WristNotice.ring(approach: approach, stop: leg?.to.short, soon: soonText(secs), inUse: inUse)
        let c = UNMutableNotificationContent()
        c.title = t.title
        c.body = t.body
        c.sound = sound.quietNow ? nil : .default         // no headphones: it buzzes instead
        c.interruptionLevel = .timeSensitive
        c.userInfo = ["kind": "go"]
        // Using your phone right now? Then you're awake: one chime, not the alarm on repeat; but it rings as every ring
        // does (0.42.8: it was one plain notification, with nothing on the lock screen to stop)
        phase = .alarm(approach: approach)
        ringInUse = inUse
        if approach, !demo { ringNote = (Date(), legIsTrain, nil) }      // (0.39) for the adaptive wake-up
        if RingShow.sound(kind, quiet: quiet, outLoudLater: outLoudLater) == .chimeOnce {
            sound.chime(announcement: announcement(approach: approach))
        } else {
            sound.ring(announcement: announcement(approach: approach))
        }
        tripNotice(c, .alarm, category: RingShow.category(kind))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: RingShow.notificationId(kind) ?? WristNotice.alarmId, content: c, trigger: nil))
        pushActivity(force: true)
        if !inUse { scheduleAgain(approach: approach, secs: secs) }
    }

    /// How soon, as the title says it: by the time rule's seconds, else the distance.
    private func soonText(_ secs: Double?) -> String { secs.map(WristNotice.minutes) ?? Fmt.distance(distance ?? 0) }

    /// The trip's notifications: grouped per trip, the ringing ones on top, and their Stop alarm button (0.37.1).
    private func tripNotice(_ c: UNMutableNotificationContent, _ kind: WristNotice.Kind, category: String) {
        c.categoryIdentifier = category
        c.threadIdentifier = WristNotice.thread(tripStart: tripStart)
        c.relevanceScore = WristNotice.relevance(kind)
    }

    /// (0.37.1) The alarm's notification once more after 30 s while it still rings, so a paired Apple Watch taps your
    /// wrist again. Only for that same alarm (a new ring, Stop alarm or the leg ending cancels it), and only once.
    private func scheduleAgain(approach: Bool, secs: Double?) {
        cancelAgain()
        ringSerial += 1
        let serial = ringSerial, rangAt = Date()
        againTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WristNotice.againAfter * 1_000_000_000))
            guard let self, !Task.isCancelled, self.ringSerial == serial else { return }
            let ringing: Bool = { if case .alarm(let a) = self.phase { return a == approach }; return false }()
            guard WristNotice.againDue(rangAt: rangAt, now: Date(), stillRinging: ringing, sent: self.againSent) else { return }
            self.againSent = true
            let t = WristNotice.ring(approach: approach, stop: self.leg?.to.short, soon: self.soonText(WristNotice.secsAtAgain(secs)), again: true)
            let c = UNMutableNotificationContent()
            c.title = t.title
            c.body = t.body
            c.sound = self.sound.quietNow ? nil : .default
            c.interruptionLevel = .timeSensitive
            c.userInfo = ["kind": "go"]
            self.tripNotice(c, .again, category: WristNotice.alarmCategory)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: WristNotice.againId, content: c, trigger: nil)) { _ in }
        }
    }

    private func cancelAgain() {
        againTask?.cancel(); againTask = nil
        againSent = false
    }

    /// Unlocked and in use. (Without a passcode the phone never says it's locked, so then it always rings.)
    private func phoneInUse() -> Bool {
        guard UIApplication.shared.isProtectedDataAvailable else { return false }
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    // MARK: the demo

    /// A pretend bus ride from `c`, two and a half minutes long, to try everything at home: the ring with the bus going round,
    /// the stops, the speed, your song, the alarm at the wake distance and again at the stop, and arriving.
    func startDemo(from c: CLLocationCoordinate2D?, line: String = "300") {
        guard phase == .idle else { return }
        let a = c ?? here ?? Place.home.coordinate
        let k = cos(a.latitude * .pi / 180)
        let total = 4600.0, secs = 150.0
        func along(_ m: Double) -> CLLocationCoordinate2D { .init(latitude: a.latitude + m * 0.3 / 110_540, longitude: a.longitude + m * 0.95 / (111_320 * k)) }
        let dn = RoleWords.current.demoNames          // (the corridor's villages to Den Bosch; off it made-up stops, 0.24)
        let names = dn.rideStops
        let now = Date()
        let stops = names.enumerated().map { i, n in
            TripStop(name: n, coordinate: along(total * Double(i) / Double(names.count - 1)), arrival: now.addingTimeInterval(secs * Double(i) / Double(names.count - 1)))
        }
        let end = along(total)
        let from = Place(key: "demo-from", name: "Your stop", short: "Your stop", ids: ["\(a.latitude),\(a.longitude)"], coordinate: a, spoken: "your stop")
        let to = Place(key: "demo-to", name: dn.rideEnd, short: dn.rideEndShort, ids: ["\(end.latitude),\(end.longitude)"], coordinate: end, spoken: dn.rideEndShort)
        demo = true
        start(RoutePlan(id: "demo", name: "Demo ride", station: to, custom: [Leg(mode: .bus, from: from, to: to)]),
              vehicle: Vehicle(tripId: "demo-\(line)", line: line, isTrain: false), backup: 0, stops: stops, how: "demo")
        location.stopUpdatingLocation()                     // the pretend ride doesn't use your GPS
        let t0 = Date()
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.demo, self.phase != .idle, self.phase != .finished else { return }
                let f = min(1.0, Date().timeIntervalSince(t0) / secs)
                let loc = CLLocation(coordinate: along(total * f), altitude: 0, horizontalAccuracy: 6, verticalAccuracy: 6,
                                     course: 75, speed: f >= 1 ? 0 : 14 + 4 * sin(f * 14), timestamp: Date())
                self.handle(loc)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: notifications

    /// "Stop alarm" on the notification (or tapping it while it rings).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.identifier, action = response.actionIdentifier
        // (0.27) a friend's message: Friends opens at that chat
        if id.hasPrefix("friends-chat-"), action == UNNotificationDefaultActionIdentifier {
            FriendChats.tapped(response.notification.request.content.userInfo)
        }
        Task { @MainActor in
            // (Stop alarm from a paired Apple Watch comes here too, the phone still locked, 0.37.1)
            // (0.42.1: the rules in `AlarmStop`, the same with the phone locked, from the Watch, or in the app)
            let how: AlarmStop.Action = AlarmStop.action(action, open: UNNotificationDefaultActionIdentifier,
                                                         dismiss: UNNotificationDismissActionIdentifier)
            AlarmResponder.apply(AlarmStop.plan(id: id, action: how), trip: self)
            // (0.36) "claim money back from NS": NS's claim page
            if id.hasPrefix("nsclaim-"), action == UNNotificationDefaultActionIdentifier, let u = URL(string: DelayClaim.claimURL) {
                _ = await UIApplication.shared.open(u)
            }
            if id == Self.stillOnId, action == "STILL_YES" || action == "STILL_PICK" {
                self.answerStillOn(yes: action == "STILL_YES", fromNotification: true)
            }
            if id == Self.whichTrainId, action == "TRAIN_A" || action == "TRAIN_B" {
                let k = action == "TRAIN_A" ? 0 : 1
                if let v = self.whichTrain[safe: k] { await self.answerWhichTrain(v.tripId, fromNotification: true) }
            }
            done()
        }
    }

    /// With the app open: the alarm and platform alerts are already on screen; the rest pop up inside the app (with their
    /// sound), and stay in the notification list.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        let c = notification.request.content
        let title = c.title, body = c.body, kind = Notices.kind(of: c.title, c.userInfo)
        let at = notification.date
        Task { @MainActor in NoticeLog.shared.add(key: id, title: title, body: body, kind: kind, at: at) }
        if id == WristNotice.alarmId || id == WristNotice.againId || id.hasPrefix("platform-") { done([]); return }
        // the calorie limit: from the Recomp sheets, so a system banner, over them
        if id.hasPrefix(RecompKcalNotice.idPrefix) { done([.banner, .list, .sound]); return }
        // in the app as a banner, with its sound; kept in the app's list instead of the notification centre
        Task { @MainActor in Notices.shared.show(title: title, body: body, kind: kind) }
        done([.sound])
    }

    func testAlarm() {
        let text = announce ? "This is a test. Attention please. We are now arriving at Breda station." : nil
        sound.ring(announcement: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in if self?.phase == .idle { self?.sound.stop() } }
    }

    // MARK: backup alarm

    /// Rings after this many minutes even if GPS drops out (0 = off).
    private func setBackup(_ minutes: Int) {
        backupTask?.cancel(); backupTask = nil; backupAt = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["backup"])
        guard minutes > 0 else { return }
        backupAt = Date().addingTimeInterval(Double(minutes) * 60)
        backupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            // (also awake: a leg that started inside its wake distance has had no alarm yet; one that rang cancelled this)
            guard let self, !Task.isCancelled, self.phase == .sleeping || self.phase == .awake else { return }
            self.ring(approach: true, why: "backup")
        }
        // A notification as well, in case iOS stops the app.
        let c = UNMutableNotificationContent()
        let t = WristNotice.backup(stop: leg?.to.short)
        c.title = t.title
        c.body = t.body
        // (0.42.8) without headphones, not out of the speaker (unless "Out loud if I don't stop it" is on)
        c.sound = headphonesOnly && !outLoudLater ? nil : .default
        c.interruptionLevel = .timeSensitive
        c.userInfo = ["kind": "go"]
        tripNotice(c, .backup, category: RingShow.category(.backup))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "backup", content: c,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(minutes) * 60, repeats: false))) { _ in }
    }

    // MARK: which bus or train you're on

    /// Keeps comparing your GPS with every bus and train nearby until it knows which one you're on.
    /// One look is enough when it's one of the departures it expected; otherwise it wants the same one twice.
    /// At a change (`forNextLeg`) it takes none until you're going and away from the stop you got off at, and never
    /// plans again from `gotOff`, the one you just got off (one that goes on to the next leg's stop it still takes).
    /// At a change, once you're going, on the road of the ride the next leg was planned with: that's its line, and the
    /// next leg starts (no vehicle, its alarm armed), holding on that road. One that doesn't go where the leg goes
    /// replaces the ride held (`heldPick`) only once you're clearly off that one's road; otherwise the rest is planned
    /// again from it. A plan again refused (its stop where you are), or not to be had at a change, is tried again after
    /// a minute while you're going. A look that comes back after you picked one by hand does nothing.
    private func startDetecting(forNextLeg: Bool = false, excluding gotOff: String? = nil) {
        detectTask?.cancel()
        detectTask = Task { [weak self] in
            var lastBest: String?
            var rejected = Set<String>()
            var wait: TimeInterval = 3
            var leftSince: Date?                                    // since when you've clearly left on the planned one
            var pickLooks: [(at: Date, metres: Double?)] = []       // the one you picked: how far you were from its road, look by look
            var retryAt: [String: Date] = [:]                       // a plan again refused: not again before then
            while !Task.isCancelled {
                // (Motion & Fitness saying "automotive" ends the wait at once: `motionChanged`)
                await self?.detectPause(wait)
                guard let self, !Task.isCancelled else { return }
                // first look soon, then every 7 seconds; standing or walking about at the stop by Motion & Fitness, and
                // your fixes not moving, every 15 (0.33)
                wait = MotionRules.lookWait(base: 7, motion: Motion.shared.now(), movingByFixes: self.movedRecently)
                if forNextLeg {
                    guard self.phase == .transfer else { return }
                    if self.endIfNoRide() { return }
                }
                else { guard self.vehicle == nil, self.phase == .sleeping || self.phase == .awake else { return } }
                let li = forNextLeg ? self.index + 1 : self.index
                let mode = self.legs[safe: li]?.mode
                let planned = self.route?.planned?[safe: li]
                let R = MatchRules.current()
                // At a change: standing or walking about among the buses at a bus station isn't riding one, and the one
                // you came in on may still be moving: none until you're going and away from where you got off. (The
                // planned one by its timetable still can, once you've clearly left: below.)
                var ranked: [Match] = []
                let gateOpen = !forNextLeg || self.goingFromChange()
                if gateOpen {
                    // every kind: you can be on a train where it planned a bus (it'll plan again from it); the kind it
                    // planned comes first
                    ranked = await self.matchVehicles(mode: nil, excluding: rejected, planned: planned?.tripId, place: "detect")
                    guard !Task.isCancelled, !self.pickedByHand else { return }
                }
                let kind = ranked.filter { mode == nil || $0.vehicle.isTrain == (mode == .train) }
                guard var m = kind.first ?? ranked.first else {
                    lastBest = nil
                    // At a change, going and away, none matched: on the planned one's road, that's its line (late, missed
                    // and a later one, or none of them showing): the next leg, held on that road. Your own routes plan
                    // nothing for the next leg: the one listed for it that just left (`changeReference`) is the road.
                    if forNextLeg, gateOpen, let p = planned ?? self.changeReference() {
                        let how = planned == nil ? "next leg, on the listed one's road" : "next leg, on the planned one's road"
                        if await self.startOnPlannedRoad(p, how: how) { return }
                        guard !Task.isCancelled, !self.pickedByHand else { return }
                    }
                    // No live match (some have no live position): the one it planned, once you've clearly left on it.
                    // (The matcher before your fixes span 20 s isn't "no match" but not sure yet: it waits, but a minute
                    // at most once you've clearly left: sparse GPS, on a train, may never give it enough fixes.)
                    let now = Date()
                    // 0.39.1: by its live departure, and never more than 2 minutes before it (`TimetableStart`): the
                    // 305 that leaves at 17:35 isn't the one you're on at 17:24, so the looks for the one you're on go on
                    var left = false
                    if let p = planned, let l = self.legs[safe: li], self.leftAtSpeed(from: l.from) {
                        let dep: Date = self.liveDeparture(of: p, leg: li).at
                        left = TimetableStart.allowed(now: now, departure: dep)
                        if !left, now < dep {
                            let label = TripManager.logLabel(Vehicle(tripId: p.tripId, line: p.line, isTrain: p.isTrain))
                            let mins = Int((dep.timeIntervalSince(now) / 60).rounded())
                            self.rideLog(TimetableStart.waitLine(label: label, leaves: Fmt.hhmm(dep), minutes: mins), once: "tt-wait|\(p.tripId)", every: 120)
                        }
                    }
                    leftSince = VehicleMatch.heldSince(leftSince, holds: left, now: now)
                    let sure = MatchSettings.classic()
                        || VehicleMatch.fallbackSure(enough: VehicleMatch.enough(self.recentFixes), leftSince: leftSince, now: now)
                    if sure, left, let p = planned {
                        let v = Vehicle(tripId: p.tripId, line: p.line, isTrain: p.isTrain)
                        if forNextLeg { if self.phase == .transfer { self.nextLeg(vehicle: v, how: "next leg by its timetable"); self.byTimetable = true } }
                        else { self.byTimetable = true; await self.vehicleFound(v) }
                        return
                    }
                    continue
                }
                // Two buses that leave a stop together (the 305 and the 306 at Veghel) fit about the same at first: the
                // one it planned wins when it fits nearly as well.
                if let p = planned, m.vehicle.tripId != p.tripId,
                   let pm = ranked.first(where: { $0.vehicle.tripId == p.tripId }), pm.score < m.score + R.plannedEdge { m = pm }
                // 0.38: nothing planned decides it: your usual line here at this time breaks a tie (`UsualLine.tieBreak`)
                if planned.map({ $0.tripId != m.vehicle.tripId }) ?? true, let u = self.usualTie(kind.isEmpty ? ranked : kind, best: m) { m = u }
                // One look is enough for one it expects, or one right with you of the line it planned; others it wants
                // to see twice.
                let otherKind = mode != nil && m.vehicle.isTrain != (mode == .train)
                // (a saved list of next departures isn't one it expects: only a live answer can)
                let expected = ((self.upcomingAsOf == nil && self.upcoming.contains { $0.trip.first.tripId == m.vehicle.tripId })
                                || planned?.tripId == m.vehicle.tripId) && m.cost < R.expected && !otherKind
                let sameLine = (planned.map { $0.line == m.vehicle.line } ?? true) && !otherKind
                if expected || (m.cost < R.oneLook && sameLine) || m.vehicle.tripId == lastBest {
                    // Its own timetable must still have your stop ahead: not one going the other way, not an earlier run.
                    // (on its way like the matching itself: during a pause after a 429 a background ask gets nothing,
                    // and with no stops it would trust the match)
                    let urgentAsk = self.isRiding || self.going
                    let stops = await Transit.$urgent.withValue(urgentAsk) { await Transit.tripStops(m.vehicle.tripId) }
                    guard !Task.isCancelled, !self.pickedByHand else { return }
                    let dests: [Place] = forNextLeg ? [self.legs[safe: self.index + 1]?.to].compactMap { $0 } : self.legDestinations
                    guard dests.contains(where: { self.goesAhead(stops, to: $0) }) else {
                        // Not where this leg goes. Seen twice: you're on another one than it planned (the Sprinter to Den
                        // Bosch where it planned the Intercity to Eindhoven). On a trip from Fastest trip the rest is
                        // planned again from that one; on your own route it's not yours.
                        // (the one you just got off, going on elsewhere: not one to plan again from)
                        if m.vehicle.tripId == gotOff { rejected.insert(m.vehicle.tripId); lastBest = nil; continue }
                        if m.vehicle.tripId == lastBest {
                            guard self.route?.isFixed == false else { rejected.insert(m.vehicle.tripId); lastBest = nil; continue }
                            if let t = retryAt[m.vehicle.tripId], t > Date() { lastBest = nil; continue }
                            // At a change, on the planned one's road: that's its line (the next Intercity to Breda, where
                            // the Den Bosch one on the track they share is what it sees): the next leg, held on that road.
                            if forNextLeg, let p = planned, p.tripId != m.vehicle.tripId {
                                if await self.startOnPlannedRoad(p) { return }
                                guard !Task.isCancelled, !self.pickedByHand else { return }
                            }
                            // The ride you said you're on holds while you're on its road: on a track two trains share
                            // (the Intercity to Breda and the one to Den Bosch, out of Eindhoven to Boxtel) until their
                            // roads part.
                            let held = planned.flatMap { p in p.tripId == self.heldPick && p.tripId != m.vehicle.tripId ? p : nil }
                            var ruledOut = true
                            if let p = held {
                                if let look = await self.roadLook(of: p.tripId) { pickLooks.append(look) }
                                guard !Task.isCancelled, !self.pickedByHand else { return }
                                ruledOut = RideGuards.pickRuledOut(pickLooks, isTrain: p.isTrain, fromPlan: self.heldFromPlan)
                            }
                            switch RideGuards.onOtherVehicle(atChange: forNextLeg, picked: held != nil, ruledOut: ruledOut) {
                            case .keepPick:
                                if let p = held {
                                    self.rideLog(FieldFormat.pickKept(FieldFormat.vehicle(line: p.line, tripId: p.tripId, isTrain: p.isTrain),
                                                                      metres: pickLooks.last?.metres), once: "pick|\(p.tripId)", every: 60)
                                }
                                continue
                            case .startNextLeg:
                                // (never waiting at a change without an alarm: the next leg, on the one you picked)
                                if self.phase == .transfer { self.nextLeg(how: "next leg, on the picked one's road", held: held?.tripId) }
                                return
                            case .replan:
                                let result = await self.replanOnto(m.vehicle, stops: stops)
                                if result == .done { return }
                                guard !Task.isCancelled, !self.pickedByHand else { return }
                                // refused (its stop where you are just now), or not to be had at a change: again in a minute
                                // while you're going (you may well be on it); standing (a bus at the bus station), not again
                                if result == .refused || forNextLeg, RideGuards.movingNow(self.recentFixes, now: Date()) {
                                    retryAt[m.vehicle.tripId] = Date().addingTimeInterval(60); lastBest = nil
                                    continue
                                }
                            }
                            rejected.insert(m.vehicle.tripId); lastBest = nil
                        } else {
                            lastBest = m.vehicle.tripId
                        }
                        continue
                    }
                    // the ones that fit about as well stay in the running, until there's real distance between them
                    let close = ranked.filter { $0.vehicle.tripId != m.vehicle.tripId && $0.cost < m.cost + R.close }.map(\.vehicle)
                    if forNextLeg {
                        if self.phase == .transfer { self.nextLeg(vehicle: m.vehicle, stops: stops, how: "next leg"); self.matchMeters = Int(m.meters) }
                    } else {
                        await self.vehicleFound(m.vehicle, meters: m.meters, stops: stops)
                    }
                    self.beginChoosing([m.vehicle] + close)
                    return
                }
                lastBest = m.vehicle.tripId
            }
        }
    }

    /// At a change: going (100 m in the last 30 s) and away from the stop you got off at (600 m: past its arrival
    /// radius). Not yet: a line in the field log, once a minute at most.
    private func goingFromChange() -> Bool {
        let now = Date(), fixes = recentFixes
        let from = metresToLegStop                  // (at a change this leg is the one you finished: its stop is where you got off)
        // (0.33: walking quickly or cycling away from the change, by Motion & Fitness, isn't going on a bus or train)
        let moving = MotionRules.movingLikeVehicle(byFixes: RideGuards.movingNow(fixes, now: now), motion: Motion.shared.now(), speed: currentSpeed)
        if RideGuards.mayTakeAtChange(moving: moving, fromChangeStop: from) { return true }
        rideLog(FieldFormat.rideWait(moved: RideGuards.movedMetres(fixes, now: now), fromStop: from), once: "wait", every: 60)
        return false
    }

    /// At a change, going: one look at the planned one's road (`RideGuards.atChange`). On it, the next leg starts with
    /// no vehicle, its alarm armed, the planned one held on that road (from the plan: it gives way off its road, or
    /// after a minute of its road not to be had). True then.
    private func startOnPlannedRoad(_ p: PlannedRide, how: String = "next leg, on the planned one's road") async -> Bool {
        guard let look = await roadLook(of: p.tripId), !Task.isCancelled, !pickedByHand, phase == .transfer,
              RideGuards.atChange(plannedRoadMetres: look.metres, isTrain: p.isTrain) == .startNextLeg else { return false }
        nextLeg(how: how, held: p.tripId, fromPlan: true)
        return true
    }

    /// At a change on one of your own routes (nothing planned for the next leg, as by the big button): the ride to go
    /// by the road of (`RideGuards.roadReference`): of the next leg's list, the newest that has left since you got off,
    /// else the first after. Nil: a planned trip (it has its own), or nothing listed.
    private func changeReference() -> PlannedRide? {
        guard phase == .transfer, route?.planned?[safe: index + 1] == nil, let n = legs[safe: index + 1], let since = changeSince else { return nil }
        let list = upcoming.filter { $0.from.key == n.from.key }.map(\.trip.first)
        guard let i = RideGuards.roadReference(list.map(\.departure), arrived: since, now: Date()) else { return nil }
        let r = list[i]
        return PlannedRide(tripId: r.tripId, line: r.line, isTrain: r.isTrain, departure: r.departure)
    }

    /// One look at how far you are from a trip's road: your newest fix within 150 m of the last 30 s (none: no look),
    /// and its distance from that road (nil: its road couldn't be had).
    private func roadLook(of tripId: String) async -> (at: Date, metres: Double?)? {
        let now = Date()
        guard let fix = samples.last(where: { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 150 && $0.timestamp > now.addingTimeInterval(-30) })
        else { return nil }
        let urgentAsk = isRiding || going
        let t = await Transit.$urgent.withValue(urgentAsk, operation: { await Transit.liveTrip(tripId) })
        guard let t, t.path.count >= 2 else { return (at: fix.timestamp, metres: nil) }
        return (at: fix.timestamp, metres: Self.metres(from: fix.coordinate, to: t.path))
    }

    /// You've left the start of the leg at bus or train speed (when the planned one leaves: `TimetableStart`, 0.39.1).
    private func leftAtSpeed(from start: Place) -> Bool {
        let now = Date()
        let last3 = samples.suffix(3)
        guard last3.count == 3, let last = last3.last, last.timestamp > now.addingTimeInterval(-30), last.horizontalAccuracy < 150,
              last3.allSatisfy({ $0.speed >= 4 }) else { return false }
        return last.distance(from: CLLocation(latitude: start.coordinate.latitude, longitude: start.coordinate.longitude)) > 400
    }

    /// Compares where you've been in the last minutes with where every nearby bus or train should have been.
    func matchVehicle(mode: Mode?, excluding: Set<String> = []) async -> Match? {
        await matchVehicles(mode: mode, excluding: excluding).first
    }

    /// Every bus or train that moves with you, the best first (see `matchByJudging`); `planned` (the one it planned or
    /// shows) gets 45 s off, `place` names the look in the field log.
    /// Classic matching: every bus or train whose timetable position follows where you've been, the closest first (score:
    /// those metres). (Two that leave a stop together both fit at first: the one you meant to take can be a close second.)
    func matchVehicles(mode: Mode?, excluding: Set<String> = [], planned: String? = nil, place: String = "match") async -> [Match] {
        if !MatchSettings.classic() { return await matchByJudging(mode: mode, excluding: excluding, planned: planned, place: place) }
        let recent = samples.filter { $0.timestamp > Date().addingTimeInterval(-120) && $0.horizontalAccuracy < 150 }
        guard let last = recent.last, recent.count >= 2 else { return [] }
        let speed = max(last.speed, recent.first.map { last.distance(from: $0) / max(1, last.timestamp.timeIntervalSince($0.timestamp)) } ?? 0)
        guard speed > 2.5 else { return [] }                    // not moving: not on board yet
        BatteryLog.shared.check()
        // Each bus or train in pieces from stop to stop: put them together, so it isn't lost when it passes a stop.
        let urgentAsk = going || isRiding      // someone is waiting for it on a ride or on Fastest trip
        let segs = await Transit.$urgent.withValue(urgentAsk) { await Transit.vehicles(near: last.coordinate, radiusDeg: speed > 15 ? 0.04 : 0.02) }
        let byTrip = Dictionary(grouping: segs, by: { $0.tripId })
        func at(_ list: [VehicleSegment], _ t: Date) -> CLLocationCoordinate2D? {
            list.first(where: { t >= $0.departure && t <= $0.arrival })?.position(at: t) ?? list.lazy.compactMap { $0.position(at: t) }.first
        }
        // Which way you're going, in metres east and north.
        let pts = Array(recent.suffix(4)), a = pts.first!, b = pts.last!
        func vec(_ p: CLLocationCoordinate2D, _ q: CLLocationCoordinate2D) -> (Double, Double) {
            ((q.longitude - p.longitude) * 111_320 * cos(p.latitude * .pi / 180), (q.latitude - p.latitude) * 110_540)
        }
        let me = vec(a.coordinate, b.coordinate), meLen = hypot(me.0, me.1)
        var found: [(vehicle: Vehicle, meters: Double)] = []
        for (id, list) in byTrip {
            guard let s = list.first else { continue }
            if let mode, (mode == .train) != s.isTrain { continue }
            if excluding.contains(id) { continue }
            // A bus at the same stop that leaves the other way is not yours.
            if meLen > 40, let pa = at(list, a.timestamp), let pb = at(list, b.timestamp) {
                let v = vec(pa, pb), vLen = hypot(v.0, v.1)
                if vLen > 40 && (me.0 * v.0 + me.1 * v.1) / (meLen * vLen) < 0.5 { continue }
                // standing at a stop by its times (waiting at the bus station) while you ride on: not the one you're on
                if meLen > 80 && vLen < 15 { continue }
            }
            var total = 0.0, n = 0.0
            for p in recent.suffix(4) {
                guard let c = at(list, p.timestamp) else { continue }
                total += p.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)); n += 1
            }
            guard n >= 2 else { continue }
            let avg = total / n
            if avg < LiveStore.matchTolerance(train: s.isTrain, speed: speed) { found.append((Vehicle(tripId: s.tripId, line: s.isTrain ? Transit.trainLabel(s.line) : s.line, isTrain: s.isTrain), avg)) }
        }
        let sorted = found.sorted { $0.meters < $1.meters }
        let logged: [(label: String, metres: Double)] = sorted.map { (label: FieldFormat.label($0.vehicle.tripId, [$0.vehicle.tripId: $0.vehicle.line]), metres: $0.meters) }
        FieldLog.shared.add(.match, FieldFormat.classic(place, logged))
        return sorted.map { Match(vehicle: $0.vehicle, meters: $0.meters, score: $0.meters, cost: $0.meters) }
    }

    /// The matcher's `matchVehicles`: every bus or train near you judged on your fixes of the last half minute, each
    /// compared with where its own times put it at that fix's time: on its path, going its way, at a possible speed,
    /// keeping pace with its times and near them (today's allowed distance). The ones that pass, by the seconds you are
    /// off their times; `planned` 45 s less (it only ranks: `cost` is without it). The best 10, and `planned` when it
    /// passed. Not sure yet (none, and a line in the field log at most every 30 s per place) until your fixes span 20 s.
    /// One with a fresh GPS fix of its own is judged by where that puts it (0.20.3; the matcher's places fetch the
    /// positions meanwhile, `RealPositionsStore.forMatcher`). Boarding (`fastLanePlaces`): before 20 s, the fast lane
    /// may take one after 8 s (`MatchRules.fastLane`); then it's the only one.
    private func matchByJudging(mode: Mode?, excluding: Set<String>, planned: String?, place: String) async -> [Match] {
        let recent = samples.filter { $0.timestamp > Date().addingTimeInterval(-120) && $0.horizontalAccuracy < 150 }
        guard let last = recent.last, recent.count >= 2 else { return [] }
        let speed = max(last.speed, recent.first.map { last.distance(from: $0) / max(1, last.timestamp.timeIntervalSince($0.timestamp)) } ?? 0)
        guard speed > 2.5 else { return [] }                    // not moving: not on board yet
        let gpsLook = Self.gpsPlaces.contains(place)
        // (looking for the one you're on: the positions are fetched from now on, so the next looks have them)
        if gpsLook { RealPositionsStore.shared.matcherLooks(trains: mode == .train) }
        let spread = VehicleMatch.spread(recentFixes)
        let enough = spread.fixes >= VehicleMatch.minFixes && spread.span >= VehicleMatch.minSpan
        let laneTry = !enough && Self.fastLanePlaces.contains(place) && spread.fixes >= MatchRules.fastFixes
            && spread.span >= MatchRules.fastSpan && speed > MatchRules.fastSpeed && RealPositionsStore.shared.hasFixes
        func notSure(_ s: (fixes: Int, span: TimeInterval)) {
            if Date().timeIntervalSince(notSureLogged[place] ?? .distantPast) >= 30 {
                notSureLogged[place] = Date()
                FieldLog.shared.add(.match, FieldFormat.notSure(place, fixes: s.fixes, span: s.span))
            }
        }
        guard enough || laneTry else {
            // not sure yet: nothing would pass, so no need to ask
            notSure(spread)
            return []
        }
        BatteryLog.shared.check()
        // every trip on a piece several share (coupled and through trains), each put together from its pieces
        let urgentAsk = going || isRiding      // someone is waiting for it on a ride or on Fastest trip
        // (no trip running: an answer of the last 10 s from within 50 m does; on a ride or at a change always a new one)
        let reuse = phase == .idle
        let segs = await Transit.$urgent.withValue(urgentAsk) {
            await Transit.vehicles(near: last.coordinate, radiusDeg: speed > 15 ? 0.04 : 0.02, allTrips: true, reuse: reuse, speed: speed)
        }
        // (a late bus by its times without catching up: its live times have it make its delay up within a few stops)
        let all = VehicleTrack.group(Transit.noCatchUp(segs, asOf: Date()).map { MapPiece($0) })
        var tracks = all.filter { v in
            !excluding.contains(v.tripId) && (mode.map { ($0 == .train) == v.isTrain } ?? true)
        }
        // each one with its own fresh GPS fix, when the open data has one
        if gpsLook { tracks = await RealPositionsStore.shared.forMatcher(tracks) }
        let fixesNow = recentFixes                                      // with the fixes that came in while it asked
        let judged: [Judgement]
        let ranked: [Ranked]
        var lane: String?
        if enough {
            judged = VehicleMatch.judgeAll(fixesNow, tracks)
            // (0.26.2) getting on: a train by its own GPS before one of about the same fit by its times (`trainGPSEdge`)
            var byRank: [Ranked] = Self.fastLanePlaces.contains(place) ? OnBoardRules.rank(judged, planned: planned)
                                                                         : VehicleMatch.rank(judged, planned: planned)
            // 0.38: getting on, the one that alone left your stop when you did comes first (`DepartMatch.bonuses`)
            if Self.fastLanePlaces.contains(place) { byRank = VehicleMatch.nudged(byRank, departBonuses(judged, tracks: tracks)) }
            ranked = VehicleMatch.top(byRank, keep: planned)
        } else {
            // the fast lane: with 2 fixes over 8 s, only one by its own GPS right with you, nothing else near
            judged = VehicleMatch.judgeAll(fixesNow, tracks, minFixes: MatchRules.fastFixes, minSpan: MatchRules.fastSpan)
            let s = VehicleMatch.spread(fixesNow)
            lane = MatchRules.fastLane(VehicleMatch.lane(judged), yourSpeed: speed, fixes: s.fixes, span: s.span)
            guard let id = lane else { notSure(s); return [] }
            ranked = VehicleMatch.rank(judged.filter { $0.id == id }, planned: planned)
        }
        let lines = Dictionary(tracks.map { ($0.tripId, $0.line) }, uniquingKeysWith: { a, _ in a })
        lastJudged = judged; lastLines = lines
        noteGPSRuns(judged)                               // (0.39.1)
        let outcome = ranked.first.map { (lane != nil ? "fast lane " : "best ") + FieldFormat.label($0.id, lines) } ?? "none"
        let plannedLeftOut = planned.map { p in all.contains { $0.tripId == p } && !tracks.contains { $0.tripId == p } } ?? false
        FieldLog.shared.add(.match, FieldFormat.match(place, judged, outcome: outcome, planned: planned, count: judged.count, plannedExcluded: plannedLeftOut))
        if let id = lane, let j = judged.first(where: { $0.id == id }) {
            let s = VehicleMatch.spread(fixesNow)
            FieldLog.shared.add(.match, FieldFormat.fastLane(place, label: FieldFormat.label(id, lines), metres: j.evidence.map { abs($0.offset) },
                                                             gpsAge: j.evidence?.gpsAge, fixes: s.fixes, span: s.span, speed: speed))
        }
        return ranked.compactMap { r -> Match? in
            guard let v = tracks.first(where: { $0.tripId == r.id }), let j = judged.first(where: { $0.id == r.id }),
                  case .success(let cost) = j.result else { return nil }
            return Match(vehicle: Vehicle(tripId: v.tripId, line: v.line, isTrain: v.isTrain),
                         meters: abs(j.evidence?.offset ?? 0), score: r.cost, cost: cost)
        }
    }

    /// The looks for the one you're on that judge by the vehicles' own GPS (0.20.3; not the idle look for a watched line).
    private static let gpsPlaces: Set<String> = ["board", "confirm", "detect", "same bus", "find nearby", "rivals"]
    /// …and those that may take one in the fast lane: boarding.
    private static let fastLanePlaces: Set<String> = ["board", "confirm", "detect"]

    /// Where this leg can take you: on the first leg of a route either station (it follows the one you take).
    private var legDestinations: [Place] {
        guard let l = leg else { return [] }
        return index == 0 && route?.isFixed == true && !RoutePlan.all.isEmpty ? RoutePlan.all.map { $0.legs(direction)[0].to } : [l.to]
    }

    /// Does this bus or train still reach `dest` from where you are now?
    /// False for one going the other way (it passed your stop already) or one that doesn't go there at all.
    private func goesAhead(_ stops: [TripStop], to dest: Place) -> Bool {
        let timed = stops.filter { $0.arrival != nil }
        guard !timed.isEmpty else { return true }                // no times known: trust the match
        func d(_ s: TripStop, _ c: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: CLLocation(latitude: s.coordinate.latitude, longitude: s.coordinate.longitude))
        }
        guard let ti = timed.indices.min(by: { d(timed[$0], dest.coordinate) < d(timed[$1], dest.coordinate) }),
              d(timed[ti], dest.coordinate) < 1500 else { return false }
        if timed[ti].arrival! < Date().addingTimeInterval(-120) { return false }
        if let here = samples.last?.coordinate,
           let hi = timed.indices.min(by: { d(timed[$0], here) < d(timed[$1], here) }), hi > ti { return false }
        return true
    }

    /// "I'm on this one", picked on the stop's board.
    func choose(board d: BoardDeparture) {
        if let p = upcoming.first(where: { $0.trip.first.tripId == d.tripId }) { choose(p); return }
        detectTask?.cancel()
        pickedByHand = true
        let v = Vehicle(tripId: d.tripId, line: d.line, isTrain: false)
        learnLine(v, weight: UsualLine.said, at: d.scheduled)       // (0.38)
        Task { await vehicleFound(v, meters: nil) }
    }

    /// "I'm on this one": you picked it in the list.
    func choose(_ p: PanelTrip) {
        let f = p.trip.first
        detectTask?.cancel()
        pickedByHand = true
        let v = Vehicle(tripId: f.tripId, line: f.line, isTrain: f.isTrain)
        learnLine(v, weight: UsualLine.said, at: f.scheduledDeparture)       // (0.38)
        Task { await vehicleFound(v, meters: nil, dest: p.to) }
    }

    /// Found it: use that vehicle's own live arrival at your stop. On the first leg it follows the route
    /// of the bus or train you actually took (via Den Bosch or via Eindhoven).
    private func vehicleFound(_ v: Vehicle, meters: Double? = nil, dest: Place? = nil, stops known: [TripStop]? = nil) async {
        vehicle = v
        if let meters { matchMeters = Int(meters) }
        if v.isTrain { WatchStore.shared.boarded(num: upcoming.first(where: { $0.trip.first.tripId == v.tripId })?.trip.first.num ?? "") }
        else { LineWatchStore.shared.boarded(line: v.line) }
        var stops: [TripStop]
        if let known { stops = known } else { stops = await Transit.tripStops(v.tripId) }
        // (0.39) no answer: the copy saved when the trip started (`RideCache`)
        if stops.isEmpty, !demo { stops = RideCacheStore.shared.tripStops(v.tripId, trip: tripStart); if !stops.isEmpty { noteNoAnswer() } }
        if index == 0, let r = route, r.isFixed {
            let names = stops.map { $0.name.lowercased() }
            func goes(_ p: Place) -> Bool { names.contains { $0.contains(p == .denBosch ? "hertogenbosch" : "eindhoven") } }
            let fromList = upcoming.first(where: { $0.trip.first.tripId == v.tripId })?.to
            let to = dest ?? fromList ?? (goes(r.station) ? r.station : RoutePlan.all.map(\.station).first(where: goes))
            if let to, to != r.station, let nr = RoutePlan.via(to) {
                route = nr; legs = nr.legs(direction); distance = nil; maxDistance = legSpan
            }
        }
        boardedHere(v, stops: stops)
        noteBoarding(v, stops: stops)
        if vehicle == v { headsign = ""; noteHeadsign(v, stops: stops) }
        stayOnIfItGoes(stops)
        applyStops(stops)
        if !demo {
            // (0.39) its road, platforms and delay; saved on the phone for the stretches without signal
            if let c = await Transit.cachedLiveTrip(v.tripId), vehicle == v {
                // (0.42.8) its train number, now known: the plan may have split this very train
                if !c.trip.num.isEmpty, stayOnIfItGoes(stops, num: c.trip.num) { applyStops(stops) }
                noteRideDetails(c.trip)
                RideCacheStore.shared.save(c.trip, tripId: v.tripId, at: c.at, trip: tripStart, force: true)
                if wakeRoute.isEmpty { noteWakeTrip(c.trip, at: c.at) }
            } else if vehicle == v {
                useSaved(v)
            }
        }
        refreshEta(force: true)
        pushActivity(force: true)
    }

    /// Your bus or train also goes to where a later leg starts, in time for it: stay on instead of changing. A Sprinter
    /// to Tilburg, then an Intercity to Breda, when the Sprinter goes on to Breda anyway and makes the same bus.
    /// 0.34 (`TrainRules.stayOn`): also when it goes to where the trip's last ride ends: stay on to there.
    /// 0.42.8: on 2026-11-27 the Intercity you were on went on to Eindhoven, where the plan changed at Tilburg to another
    /// train to Eindhoven and the bus from there; it rang at Tilburg. It only looked for the train at the next ride's
    /// boarding stop (the bus bay, a stop of its own by the station, often further than the 400 m it allowed) and by
    /// that bus's departure, never at where the next leg itself gets off, and only once, when the vehicle was found.
    /// Now, by the vehicle's own stops: where a later leg gets off (by place, or by the station's name) or where the
    /// ride after it gets on, no later than the planned ride gets there (+2 min) and a minute before the ride after it;
    /// always when the plan split one train (the same number); looked at again with each new answer of its stops.
    /// `num`: the vehicle's train number when its trip answer said it. True: the legs were merged.
    @discardableResult
    private func stayOnIfItGoes(_ stops: [TripStop], num known: String = "") -> Bool {
        guard let r = route, var custom = r.custom, var planned = r.planned, planned.count == custom.count,
              index + 1 < custom.count, let v = vehicle else { return false }
        let now = Date()
        let num: String = v.isTrain ? stayNum(v, known: known) : ""        // (a train's number only: buses' trip names repeat)
        let spots: [TrainRules.StayLeg] = custom.indices.map { k in
            let l: Leg = custom[k], p: PlannedRide = planned[k]
            return TrainRules.StayLeg(from: GeoPoint(l.from.coordinate), to: GeoPoint(l.to.coordinate), fromName: l.from.name,
                                      toName: l.to.name, departure: p.departure, arrival: p.arrival, tripId: p.tripId,
                                      num: p.isTrain ? p.num : "")
        }
        let calls: [TrainRules.StayCall] = stops.map { TrainRules.StayCall(name: $0.name, p: GeoPoint($0.coordinate), arrival: $0.arrival) }
        guard let hit = TrainRules.stayOn(index: index, legs: spots, tripId: v.tripId, num: num, calls: calls, now: now) else { return false }
        let k = hit.leg
        let to: Place
        var reachesAt: Date? = planned[k].arrival
        if let ci = hit.call {
            let s = stops[ci]
            let name = Fmt.place(s.name)
            to = Place(key: "s:\(s.name)|\(s.coordinate.latitude),\(s.coordinate.longitude)", name: s.name, short: name,
                       ids: ["\(s.coordinate.latitude),\(s.coordinate.longitude)"], coordinate: s.coordinate, spoken: name)
            reachesAt = s.arrival ?? reachesAt
        } else {
            to = custom[k].to
        }
        let skipped: [String] = custom[(index + 1)...k].map(\.from.short)
        let changeAt: String = custom[index].to.short
        let changeTime: String = (planned[index].arrival ?? legTo).map(Fmt.hhmm) ?? ""
        let was: PlannedRide = planned[index + 1]
        let wasLabel: String = was.num.isEmpty ? was.line : "\(was.line) \(TrainRules.digits(was.num))"
        let mineLabel: String = num.isEmpty ? Self.logLabel(v) : "\(v.line) \(TrainRules.digits(num))"
        let cur = custom[index]
        let nextRide: PlannedRide? = k + 1 < planned.count ? planned[k + 1] : nil
        var mine: PlannedRide = planned[index]
        mine.arrival = reachesAt
        custom = Array(custom[..<index]) + [Leg(mode: cur.mode, from: cur.from, to: to)] + Array(custom[(k + 1)...])
        planned = Array(planned[..<index]) + [mine] + Array(planned[(k + 1)...])
        let nr = RoutePlan(id: r.id, name: r.name, station: r.station, custom: custom, planned: planned, plannedEnd: r.plannedEnd)
        applyStayRoute(nr, to: to)
        rideLog(TrainRules.stayLog(vehicle: mineLabel, reaches: to.short, at: reachesAt.map(Fmt.hhmm) ?? "", changeAt: changeAt,
                                   changeTime: changeTime, next: wasLabel, nextTime: Fmt.hhmm(was.departure), sameTrain: hit.sameTrain))
        let no: String = skipped.joined(separator: ", ")
        if let nextRide {
            let then = nextRide.isTrain ? (nextRide.line == "IC" ? "Intercity" : nextRide.line) : "bus \(nextRide.line)"
            tellBus("Stay on to \(to.short)", "This \(v.title) goes on to \(to.short) in time for the same \(then) at \(Fmt.hhmm(nextRide.departure)): no change at \(no).")
        } else {
            tellBus("Stay on to \(to.short)", "This \(v.title) goes all the way to \(to.short): no change at \(no).")
        }
        return true
    }

    /// (0.42.8) The trip now stays on the vehicle you're on to `to` (this leg's new end), the rest as in `nr`: the
    /// wake-up for the new stop, no ring for the change it skips (one ringing for it goes), the lock screen and the
    /// change guide after it.
    private func applyStayRoute(_ nr: RoutePlan, to: Place) {
        route = nr
        legs = nr.legs(direction)
        distance = nil; arrival = nil; next = nil; legArrival = nil; legTo = nil
        maxDistance = legSpan
        // the wake-up goes by the new stop: not by the old one's live arrival or road
        wakeLive = nil; wakeRoute = []; legClosest = nil; awayLooked = false
        stayOnTo = to.short
        betterOffer = nil
        if phase == .awake { phase = .sleeping; forceArrival = false; quietLeg = false }
        if case .alarm = phase {
            // it rang for the change it now skips: that ring goes, the alarm is for the new stop
            ringInUse = false; ringNote = nil
            sound.stop(); cancelAgain()
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [WristNotice.alarmId, WristNotice.againId])
            phase = .sleeping; forceArrival = false; quietLeg = false
        }
        watchTrains()
        updateChangeGuide()
        pushActivity(force: true)
        Task { await loadUpcoming(force: true) }
    }

    // MARK: (0.42.8) the best place to get off

    /// A faster way from a later stop of the vehicle you're on (`BetterStop`): offered, taken only with a tap.
    struct BetterOffer: Equatable {
        let stop: Place
        let reachesAt: Date             // when the vehicle gets there
        let trip: DoorTrip              // the plan from there
        let text: String
        let log: String
    }
    @Published private(set) var betterOffer: BetterOffer?
    private var betterAt = Date.distantPast
    private var betterTask: Task<Void, Never>?
    private var betterKept: Set<String> = []        // stops you said "Keep my plan" to, this trip

    /// The vehicle's stops go on past where this leg gets off: plan from a few of them (at most every 5 minutes, a
    /// question each, on the planner's own limits), and offer one that gets you there sooner.
    private func lookForBetterStop(_ stops: [TripStop]) {
        guard !demo, betterOffer == nil, betterTask == nil, let v = vehicle, phase == .sleeping || phase == .awake,
              let r = route, r.custom != nil, let planned = r.planned, index + 1 < legs.count,
              let l = leg, let final = legs.last else { return }
        let now = Date()
        guard now.timeIntervalSince(betterAt) >= BetterStop.every else { return }
        betterAt = now
        let calls: [TrainRules.StayCall] = stops.map { TrainRules.StayCall(name: $0.name, p: GeoPoint($0.coordinate), arrival: $0.arrival) }
        guard let after = TrainRules.callAt(GeoPoint(l.to.coordinate), name: l.to.name, in: calls, now: now) else { return }
        let picks: [Int] = BetterStop.candidates(calls: calls, after: after, dest: GeoPoint(final.to.coordinate), now: now)
            .filter { !betterKept.contains(stops[$0].name) }
        guard !picks.isEmpty, let current = arrival ?? planned.last?.arrival else { return }
        let changes: Int = legs.count - index - 1
        let destKey: String = "\(final.to.coordinate.latitude),\(final.to.coordinate.longitude)"
        let destWord: String = direction == .home ? "home" : final.to.short
        betterTask = Task { [weak self] in
            var options: [BetterStop.Option] = []
            var plans: [Int: DoorTrip] = [:]
            for i in picks {
                guard let a = calls[i].arrival else { continue }
                let from: String = "\(calls[i].p.lat),\(calls[i].p.lon)"
                let found: [DoorTrip] = await Transit.plan(from: from, to: destKey, modes: nil, at: a.addingTimeInterval(BetterStop.changeRoom),
                                                           count: 3, maxTransfers: 2)
                guard let self, !Task.isCancelled else { return }
                guard self.vehicle == v else { self.betterTask = nil; return }
                let ok: [DoorTrip] = found.filter { $0.first.tripId != v.tripId && $0.first.departure >= a.addingTimeInterval(BetterStop.changeRoom) }
                guard let t = ok.min(by: { $0.last.arrival < $1.last.arrival }), RoutePlan.from(t) != nil else { continue }
                options.append(BetterStop.Option(stop: i, arrival: t.last.arrival, changes: t.rides.count - 1))
                plans[i] = t
            }
            guard let self else { return }
            self.betterTask = nil
            guard self.vehicle == v, self.betterOffer == nil,
                  let o = BetterStop.best(current: current, currentChanges: changes, options: options), let t = plans[o.stop] else { return }
            self.offerBetterStop(stops[o.stop], trip: t, current: current, destWord: destWord)
        }
    }

    private func offerBetterStop(_ s: TripStop, trip t: DoorTrip, current: Date, destWord: String) {
        let name = Fmt.place(s.name)
        let stop = Place(key: "s:\(s.name)|\(s.coordinate.latitude),\(s.coordinate.longitude)", name: s.name, short: name,
                         ids: ["\(s.coordinate.latitude),\(s.coordinate.longitude)"], coordinate: s.coordinate, spoken: name)
        let f = t.first
        let trainName: String = f.line == "IC" ? "Intercity" : f.line
        let what: String = f.isTrain ? trainName : "bus \(f.line)"
        let then: String = "\(what) at \(Fmt.hhmm(f.departure))"
        let newAt: String = Fmt.hhmm(t.last.arrival)
        let text = BetterStop.offerText(stop: name, dest: destWord, newAt: newAt, oldAt: Fmt.hhmm(current), then: then)
        let log = BetterStop.log(stop: name, dest: destWord, newAt: newAt, minutes: BetterStop.minutesSooner(current: current, better: t.last.arrival))
        betterOffer = BetterOffer(stop: stop, reachesAt: s.arrival ?? t.first.departure, trip: t, text: text, log: log)
        rideLog(log)
        // a quiet word (no sound): the card on the ride screen has the buttons
        let c = UNMutableNotificationContent()
        c.title = "Stay on to \(name)"
        c.body = text
        c.sound = nil
        c.interruptionLevel = .passive
        c.userInfo = ["kind": "info"]
        tripNotice(c, .headsUp, category: WristNotice.tripCategory)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "betterstop", content: c, trigger: nil)) { _ in }
    }

    /// "Do this": this leg goes on to that stop (the wake-up there), then the new plan from there.
    func takeBetterStop() {
        guard let o = betterOffer else { return }
        betterOffer = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["betterstop"])
        guard let r = route, var custom = r.custom, var planned = r.planned, planned.count == custom.count, index < custom.count,
              let from = RoutePlan.from(o.trip), let newLegs = from.custom, let newRides = from.planned else { return }
        let cur = custom[index]
        var mine: PlannedRide = planned[index]
        mine.arrival = o.reachesAt
        custom = Array(custom[..<index]) + [Leg(mode: cur.mode, from: cur.from, to: o.stop)] + newLegs
        planned = Array(planned[..<index]) + [mine] + newRides
        let nr = RoutePlan(id: r.id, name: r.name, station: r.station, custom: custom, planned: planned, plannedEnd: from.plannedEnd)
        applyStayRoute(nr, to: o.stop)
        rideLog(o.log + " · taken")
        Task { await refreshVehicle() }
    }

    /// "Keep my plan": not offered again for that stop on this trip.
    func keepPlanNotBetterStop() {
        guard let o = betterOffer else { return }
        betterKept.insert(o.stop.name)
        betterOffer = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["betterstop"])
        rideLog("better stop · kept the plan (not at \(o.stop.short))")
    }

    /// The train number of the vehicle you're on: from its trip answer, else the ride this leg was planned with when
    /// it's that one, else the departures listed (`upcoming`).
    private func stayNum(_ v: Vehicle, known: String) -> String {
        if !known.isEmpty { return known }
        if let p = route?.planned?[safe: index], p.tripId == v.tripId, !p.num.isEmpty { return p.num }
        return upcoming.first(where: { $0.trip.first.tripId == v.tripId })?.trip.first.num ?? ""
    }

    /// (0.42.8) Where the vehicle really goes, for the ride's headline: its trip's last stop (else the planned headsign).
    private func noteHeadsign(_ v: Vehicle, stops: [TripStop]) {
        if let last = stops.last?.name, !last.isEmpty { headsign = Fmt.place(last); return }
        if headsign.isEmpty, let p = route?.planned?[safe: index], p.tripId == v.tripId, !p.headsign.isEmpty { headsign = Fmt.place(p.headsign) }
    }

    /// It got you there: how late it was against its timetable (by its own live times when it has them), so next time
    /// a change after it gets the room it needs.
    /// (0.35) The ride just ended, kept for Your year in travel (`TravelLogStore`, this phone only): from the planned
    /// departure once that had passed (else from when the leg began), its line, stops, kilometres and your coach.
    /// Nil: under a minute, nothing to keep.
    private func keepRide(_ l: Leg, tripStart ts: Date) -> String? {
        let now = Date()
        let planned: PlannedRide? = route?.planned?[safe: index]
        var dep: Date = legStart
        if let p = planned?.departure, p > legStart, p < now { dep = p }
        guard now.timeIntervalSince(dep) >= 60 else { return nil }
        let train: Bool = vehicle?.isTrain ?? planned?.isTrain ?? (l.mode == .train)
        let label: String = vehicle?.title ?? planned.map { Vehicle(tripId: $0.tripId, line: $0.line, isTrain: $0.isTrain).title } ?? l.mode.title
        let share = FriendTravelShare.shared
        let coach: Int? = train && vehicle != nil && share.coachTrip == vehicle?.tripId ? share.coach?.n : nil
        let metres: Double = Geo.metres(GeoPoint(l.from.coordinate), GeoPoint(l.to.coordinate))
        let id = "r" + String(Int(dep.timeIntervalSince1970), radix: 36) + "-\(index)"
        TravelLogStore.shared.add(RideRecord(id: id, trip: ts, dep: dep, arr: now, train: train, label: label, from: l.from.short,
                                             to: l.to.short, km: TravelYear.km(metres: metres, train: train), coach: coach))
        return id
    }

    private func noteDelay(_ v: Vehicle, at stop: Place, rideId: String? = nil) {
        let now = Date(), start = tripStart
        Task {
            guard let t = await Transit.liveTrip(v.tripId) else { return }
            let target = CLLocation(latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude)
            func d(_ i: Int) -> Double { target.distance(from: CLLocation(latitude: t.stops[i].coordinate.latitude, longitude: t.stops[i].coordinate.longitude)) }
            guard let i = t.stops.indices.min(by: { d($0) < d($1) }), d(i) < 1200, let sch = t.stops[i].scheduled else { return }
            // no live times: when you got there (it notices a little before the stop)
            let real = t.live ? (t.stops[i].arrival ?? now) : now.addingTimeInterval(45)
            let late = real.timeIntervalSince(sch) / 60
            DelayBook.shared.record(line: v.line, stop: t.stops[i].name, scheduled: sch, delay: late)
            self.noteLate(v, mins: late, tripStart: start)
            if v.isTrain, start != nil, start == self.tripStart { self.trainLate.append(late); self.considerClaim() }   // (0.36)
            if let rideId { TravelLogStore.shared.noteLate(rideId, mins: late) }
        }
    }

    /// (0.35) A ride's delay at your stop, for today's ranking ("the 305 was 18 min late"): the trip keeps its latest
    /// ride; once it's scored already (the last ride's delay comes after), its board entry gets it. Not a trip since then.
    private func noteLate(_ v: Vehicle, mins: Double, tripStart start: Date?) {
        guard mins >= 1, start != nil, start == tripStart else { return }
        let w = ScoreRules.worse(tripLate, (line: v.isTrain ? v.title : v.line, mins: mins))
        tripLate = w
        if let id = lastScore?.entry.id { ScoreBook.shared.noteLate(id, line: w.line, mins: w.mins) }
    }

    // MARK: "I'm actually on…": picked by hand during the ride (0.20.5)

    static let stillOnId = "still-on"
    static let stillOnCategory = "STILLON"

    /// What the sheet lists now (`RidePick.gather`): the one it shows and the ones it's choosing between, and the buses
    /// and trains of the live map pieces around you that move with you or are within 600 m of you (by their own fresh
    /// GPS fix, else by their times), each judged on your fixes as the matcher does; with where each one goes.
    func handPickChoices() async -> [RidePick.Row] {
        guard phase == .sleeping || phase == .awake, let here = lastFix, here.horizontalAccuracy >= 0 else { return [] }
        let now = Date()
        let segs = await Transit.$urgent.withValue(true) { await Transit.vehicles(near: here.coordinate, radiusDeg: 0.02, allTrips: true) }
        var tracks = VehicleTrack.group(Transit.noCatchUp(segs, asOf: now).map { MapPiece($0) })
        var modes: [String: String] = [:]
        for s in segs where modes[s.tripId] == nil { modes[s.tripId] = s.mode }
        // the one it shows and the ones it's choosing between, also when the map pieces around you don't have them
        var known = cands.map(\.vehicle)
        if let v = vehicle { known.insert(v, at: 0) }
        var seen = Set(tracks.map(\.tripId))
        let missing = known.filter { seen.insert($0.tripId).inserted }
        let jobs: [@Sendable () async -> LiveTrip?] = missing.map(\.tripId).map { id in { @Sendable in await Transit.liveTrip(id) } }
        let trips = await Progressive.all(jobs)
        for (v, t) in zip(missing, trips) {
            guard let t else { continue }
            RealPositionsStore.shared.learn(v.tripId, trip: t)
            if modes[v.tripId] == nil { modes[v.tripId] = t.mode }
            if !t.headsign.isEmpty { headsignOf[v.tripId] = Fmt.place(t.headsign) }
            if let k = VehicleTrack(tripId: v.tripId, line: v.line, isTrain: v.isTrain, trip: t.noCatchUp(asOf: now, isTrain: v.isTrain)) {
                tracks.append(k)
            }
        }
        tracks = await RealPositionsStore.shared.forMatcher(tracks)
        let judged = VehicleMatch.judgeAll(recentFixes, tracks, strictTimes: false)
        let here2 = lastFix ?? here
        var rows = RidePick.gather(here: GeoPoint(here2.coordinate), now: Date(), tracks: tracks, judged: judged,
                                   candidates: cands.map(\.vehicle.tripId), current: vehicle?.tripId, modes: modes)
        // where each one goes (its trip, asked once a sheet)
        let ask = rows.map(\.tripId).filter { headsignOf[$0] == nil }
        let headJobs: [@Sendable () async -> String?] = ask.map { id in { @Sendable in await Transit.liveTrip(id)?.headsign } }
        let heads = await Progressive.all(headJobs)
        if headsignOf.count > 200 { headsignOf = [:] }
        for (id, h) in zip(ask, heads) { if let h, !h.isEmpty { headsignOf[id] = Fmt.place(h) } }
        for k in rows.indices { rows[k].headsign = headsignOf[rows[k].tripId] ?? "" }
        return rows
    }

    /// A row picked in the sheet, looked at before the ride takes it.
    struct HandPick: Identifiable {
        let vehicle: Vehicle
        let stops: [TripStop]
        let route: RoutePlan?           // the rest planned again from it (nil: the route stays)
        let alternatives: [DoorTrip]
        let warning: String?            // it doesn't go to this leg's stop: what then (asked before switching)
        let leg: Int
        let routeId: String?
        let metres: Double?             // how far from you it was in the sheet, and by what (for the field log)
        let byGPS: Bool
        var id: String { vehicle.tripId }
    }

    /// What picking `row` would do, as an automatic switch does it: its stops (does it still go to this leg's stop?), and
    /// on a trip from Fastest trip the rest planned again from it (the way it was choosing between, or the planner's from
    /// it: `switchVehicle`). On one of your own routes or a single stop it follows the station it goes to by itself
    /// (`vehicleFound`); on your own routes one that goes to neither gets the rest planned from it too. One that doesn't go
    /// to this leg's stop: what then, said before switching (`warning`). Nil: the ride moved on meanwhile.
    func previewHandPick(_ row: RidePick.Row) async -> HandPick? {
        guard phase == .sleeping || phase == .awake, let l = leg else { return nil }
        let i = index, rid = route?.id
        let v = Vehicle(tripId: row.tripId, line: row.line, isTrain: row.isTrain)
        let stops = await Transit.$urgent.withValue(true) { await Transit.tripStops(v.tripId) }
        guard phase == .sleeping || phase == .awake, index == i, route?.id == rid else { return nil }
        let same = v.tripId == vehicle?.tripId
        let goes = same || legDestinations.contains { goesAhead(stops, to: $0) }
        var plan: DoorTrip?, alts: [DoorTrip] = []
        if !same, let r = route, r.single == nil, !r.isFixed || !goes, let final = legs.last?.to {
            if !r.isFixed, let alt = boardAlternatives.first(where: { $0.first.tripId == v.tripId }), RoutePlan.from(alt) != nil {
                plan = alt; alts = boardAlternatives
            } else if let here = samples.last,
                      let ob = await Transit.$urgent.withValue(true, operation: { await LiveStore.onBoardTrips(here, to: final, tripId: v.tripId) }),
                      let t = ob.1.first, RoutePlan.from(t) != nil {
                plan = t; alts = ob.1
            }
            guard phase == .sleeping || phase == .awake, index == i, route?.id == rid else { return nil }
        }
        var warning: String?
        if !goes {
            let then = plan.map { t in t.rides.dropFirst().map { "\(GoStore.what($0)) at \(Fmt.hhmm($0.departure))" } } ?? []
            let end = plan.flatMap { t in legs.last.map { "\($0.to.short) at \(Fmt.hhmm(t.end))" } }
            warning = RidePick.doesntGo(v.title, to: l.to.short, getOff: plan.map { Fmt.place($0.first.toStop) }, then: then, end: end)
        }
        return HandPick(vehicle: v, stops: stops, route: plan.flatMap { RoutePlan.from($0) }, alternatives: alts, warning: warning,
                        leg: i, routeId: rid, metres: row.metres, byGPS: row.byGPS)
    }

    /// You're on this one (picked in the sheet): the ride takes it the way an automatic switch does (the rest planned
    /// again from it when `previewHandPick` did; its stops, its times, the alarm for its stop on this leg, the Live
    /// Activity), and the matcher doesn't change it by itself for the rest of this leg (`HandLock`).
    func applyHandPick(_ p: HandPick) async {
        guard phase == .sleeping || phase == .awake, index == p.leg, route?.id == p.routeId else { return }
        let old = vehicle
        detectTask?.cancel(); detectTask = nil
        cands = []; choosing = []; candSince = nil; candLead = nil; candSwitch = SwitchState(); candMisses = [:]; candGPS.restart()
        roadOf = nil; offRoad = 0; farLooks = 0; heldPick = nil; heldFromPlan = false
        pickedByHand = true; byTimetable = false; matchMeters = nil
        // (its own times come with its stops; until then the timetable's)
        legArrival = nil; legFrom = nil; legTo = nil
        if let nr = p.route {
            boardAlternatives = p.alternatives
            setRoute(nr)
        }
        handLock = HandLock(tripId: p.vehicle.tripId, leg: index)
        stillOnAsk = nil; whichTrain = []; whichTrainTo = [:]
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.stillOnId])
        // 0.38: what you said teaches your usual line (the one it had: not this one)
        learnLine(p.vehicle, weight: UsualLine.said)
        if let o = old, o.tripId != p.vehicle.tripId, o.line != p.vehicle.line { learnLine(o, weight: UsualLine.notThis) }
        await vehicleFound(p.vehicle, stops: p.stops)
        rideLog(FieldFormat.handPick(Self.logLabel(p.vehicle), was: old.map { FieldFormat.label($0.tripId, [$0.tripId: $0.line]) },
                                     metres: p.metres, byGPS: p.metres == nil ? nil : p.byGPS))
        if p.route != nil {
            rideLog(FieldFormat.rideStart(how: "hand pick, planned again", vehicle: Self.logLabel(p.vehicle), stopMetres: metresToLegStop,
                                          leg: index + 1, of: legs.count))
            // planned again to a stop you're inside the wake distance of already: awake from now, without the alarm, as a
            // leg that starts there (the announcement comes at the stop)
            if !demo, phase == .sleeping, let f = startFix(tracked: true), let l = leg {
                let d = f.distance(from: CLLocation(latitude: l.to.coordinate.latitude, longitude: l.to.coordinate.longitude))
                legStartMetres = d
                if RideGuards.wakeAtStart(targetMetres: d, wakeMetres: wakeKm * 1000) == .awakeSilently {
                    phase = .awake; forceArrival = true; quietLeg = true
                    rideLog(FieldFormat.rideWake(startedMetres: d))
                }
            }
        }
        sameCheckAt = Date().addingTimeInterval(30)
        pushActivity(force: true)
    }

    /// "None of these: just use my location": the trip and the alarm go on without a vehicle (as a leg started with
    /// "I'm on it" before it knows which one), by your GPS to this leg's stop, and the matcher takes none by itself for
    /// the rest of this leg.
    func noneOfThese() {
        guard phase == .sleeping || phase == .awake, leg != nil else { return }
        let old = vehicle
        detectTask?.cancel(); detectTask = nil
        cands = []; choosing = []; candSince = nil; candLead = nil; candSwitch = SwitchState(); candMisses = [:]; candGPS.restart()
        roadOf = nil; offRoad = 0; farLooks = 0; heldPick = nil; heldFromPlan = false
        vehicle = nil; vehicleStops = []; matchMeters = nil; byTimetable = false; pickedByHand = true
        legArrival = nil; legFrom = nil; legTo = nil
        handLock = HandLock(tripId: nil, leg: index)
        stillOnAsk = nil; whichTrain = []; whichTrainTo = [:]
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.stillOnId])
        rideLog(FieldFormat.handPick(nil, was: old.map { FieldFormat.label($0.tripId, [$0.tripId: $0.line]) }, metres: nil, byGPS: nil))
        refreshEta(force: true)
        pushActivity(force: true)
    }

    /// The answer to "Still on bus 306?": yes (not asked again for this pick), or pick again (the sheet opens).
    func answerStillOn(yes: Bool, fromNotification: Bool = false) {
        guard let v = stillOnAsk ?? (fromNotification && handLock?.tripId != nil ? vehicle : nil) else { return }
        stillOnAsk = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.stillOnId])
        rideLog(FieldFormat.stillOnAnswered(Self.logLabel(v), yes: yes, fromNotification: fromNotification))
        if yes { handLock?.confirmed() } else { pickAgain = true }
    }

    /// The "same bus" look while you picked by hand: the matcher judges the one you picked as it always does (a line in
    /// the field log), and your last fix's distance from its road goes to `HandLock.look`. It never switches, chooses or
    /// plans again: off its road for 3 minutes, it asks you once.
    private func watchHandPick() async {
        guard let v = vehicle, handLock?.tripId == v.tripId, !demo, !checkingSame, phase == .sleeping || phase == .awake else { return }
        let now = Date()
        guard let last = samples.last(where: { $0.timestamp > now.addingTimeInterval(-45) && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 80 })
        else { return }
        checkingSame = true
        defer { checkingSame = false }
        if roadOf?.tripId != v.tripId || roadOf.map({ now.timeIntervalSince($0.at) > 60 }) ?? true {
            let urgentAsk = isRiding || going
            if let t = await Transit.$urgent.withValue(urgentAsk, operation: { await Transit.liveTrip(v.tripId, maxAge: RideTick.tripCache) }), t.path.count >= 2 {
                roadOf = (v.tripId, t, now)
            }
        }
        guard vehicle == v, handLock?.tripId == v.tripId else { return }
        let road = roadOf.flatMap { $0.tripId == v.tripId ? $0 : nil }
        let metres = road.map { Self.metres(from: last.coordinate, to: $0.trip.path) }
        var judged: [Judgement] = []
        if let r = road, let plain = VehicleTrack(tripId: v.tripId, line: v.line, isTrain: v.isTrain, trip: r.trip.noCatchUp(asOf: r.at, isTrain: v.isTrain)) {
            RealPositionsStore.shared.learn(v.tripId, trip: r.trip)
            // (only looking, on its road: the positions at most every 2 minutes, no hold on the feed: 0.20.7)
            await RealPositionsStore.shared.refresh(trains: v.isTrain, ifOlderThan: FeedPolicy.confirmedEvery)
            let tracks = await RealPositionsStore.shared.forMatcher([plain], hold: false)
            judged = VehicleMatch.judgeAll(recentFixes, tracks, strictTimes: false)
            BatteryLog.shared.check()
        }
        guard vehicle == v, var lock = handLock, lock.tripId == v.tripId else { return }
        let at = Date()
        let look = lock.look(metres: metres, isTrain: v.isTrain, now: at)
        handLock = lock
        let shown = FieldFormat.label(v.tripId, [v.tripId: v.line])
        let off = metres.map { VehicleMatch.offRoad($0, isTrain: v.isTrain) } ?? false
        let note = metres == nil ? " · its road not known" : off ? " · off its road \(Int(lock.offFor(now: at).rounded())) s" : ""
        FieldLog.shared.add(.match, FieldFormat.match("same bus", judged, outcome: "keep \(shown) · picked by hand" + note,
                                                      planned: v.tripId, count: judged.count))
        if look == .ask { askStillOn(v, metres: metres, offFor: lock.offFor(now: at)) }
    }

    /// "Still on bus 306?": on the ride screen, and as a notification when the app isn't in front.
    private func askStillOn(_ v: Vehicle, metres: Double?, offFor: TimeInterval) {
        stillOnAsk = v
        rideLog(FieldFormat.stillOnAsked(Self.logLabel(v), offFor: offFor, metres: metres))
        guard UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = RidePick.stillOn(line: v.line, isTrain: v.isTrain)
        c.body = "Your GPS has been off its route for a few minutes. On another one? Pick it, so it wakes you at the right stop."
        c.sound = .default
        c.categoryIdentifier = Self.stillOnCategory
        c.userInfo = ["kind": "info"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.stillOnId, content: c, trigger: nil)) { _ in }
    }


    // MARK: two trains on the same track (0.34)

    /// The confirmed train passes by its times or road, not by its own NS position: the other trains on your track, each
    /// judged by its own (`matchByJudging`, "rivals"). One with you by its NS position while the one shown isn't starts a
    /// choice between them (`TrainRules.rivals`). True: it started one.
    private func lookAtRivals(_ v: Vehicle, mine: Judgement?) async -> Bool {
        lastJudged = []; lastLines = [:]
        _ = await matchVehicles(mode: .train, excluding: [v.tripId], place: "rivals")
        guard vehicle == v, cands.isEmpty, phase == .sleeping || phase == .awake, HandLock.autoSwitch(handLock, leg: index) else { return false }
        let ids = TrainRules.rivals(shown: mine, others: lastJudged)
        guard !ids.isEmpty else { return false }
        let found = ids.map { Vehicle(tripId: $0, line: lastLines[$0] ?? "", isTrain: true) }
        let names = lastLines.merging([v.tripId: v.line]) { a, _ in a }
        FieldLog.shared.add(.match, "rivals · \(FieldFormat.label(v.tripId, names)) not with you by its own GPS · "
                            + found.map { FieldFormat.label($0.tripId, names) }.joined(separator: ", ") + " by theirs → choose")
        beginChoosing([v] + found)
        return !cands.isEmpty
    }

    /// The trains it's choosing between that the stopping pattern rules out (`TrainRules.outByStops`): their stations from
    /// their trips (a station counts as on a train's track when its track passes within 150 m), what you did at each by
    /// your fixes of the last 4 minutes, kept for the rest of the choice.
    private func trainPatternOut(_ list: [Candidate]) -> Set<String> {
        var stations: [String: GeoPoint] = [:], calls: [String: Set<String>] = [:]
        for c in list {
            guard let t = c.trip else { return [] }
            var mine = Set<String>()
            for st in t.stops {
                let k = Habits.key(st.name)
                guard !k.isEmpty else { continue }
                mine.insert(k)
                if stations[k] == nil { stations[k] = GeoPoint(st.coordinate) }
            }
            calls[c.vehicle.tripId] = mine
        }
        var through: [String: Set<String>] = [:]
        for c in list {
            let path = (c.trip?.path ?? []).map { GeoPoint($0) }
            guard path.count >= 2 else { continue }
            through[c.vehicle.tripId] = Set(stations.filter { st in Geo.project(st.value, on: path).map { $0.crossTrack <= 150 } ?? false }.keys)
        }
        let fixes = samples.map { Fix($0) }
        for (k, p) in stations { if let seen = TrainRules.seen(fixes, at: p) { trainSeen[k] = seen } }
        return TrainRules.outByStops(calls: calls, runsThrough: through, seen: trainSeen)
    }

    // MARK: picking the one you're on (0.38, `PickRules`)

    private static let pickCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam") ?? .current
        return c
    }()

    /// The moment you last went from standing at a stop to moving (`DepartMatch.moment`, from the last 4 minutes of
    /// fixes), while it's fresh enough to judge by.
    private func departureNow(_ now: Date = Date()) -> Departure? {
        let fixes: [Fix] = samples.map { Fix($0) }
        if let d = DepartMatch.moment(fixes), d.t > (departure?.t ?? .distantPast) { departure = d }
        return DepartMatch.usable(departure, now: now)
    }

    /// "depart · stood 40 s, left 07:42:25 · 305·7821 left then (live 5 s) · …", once per moment and outcome.
    private func logDeparture(_ d: Departure, _ clues: [DepartClue], lines: [String: String]) {
        let said: [DepartClue] = Array(clues.filter { $0.offBy != nil || $0.elsewhere }.prefix(4))
        let line: String = DepartMatch.logLine(d, said, lines: lines, calendar: Self.pickCalendar)
        if let l = departLogged, l.at == d.t, l.line == line { return }
        departLogged = (d.t, line)
        FieldLog.shared.add(.match, line)
    }

    /// Looking for the one you got on: `DepartMatch.bonus` off the one of those that passed that alone left your stop when
    /// you did.
    private func departBonuses(_ judged: [Judgement], tracks: [VehicleTrack]) -> [String: Double] {
        guard let d = departureNow() else { return [:] }
        let passed: Set<String> = Set(judged.filter { (j: Judgement) -> Bool in
            if case .success = j.result { return true }
            return false
        }.map(\.id))
        let clues: [DepartClue] = tracks.filter { passed.contains($0.tripId) }.map { DepartMatch.clue($0, at: d) }
        guard !clues.isEmpty else { return [:] }
        let lines: [String: String] = Dictionary(tracks.map { ($0.tripId, $0.line) }, uniquingKeysWith: { a, _ in a })
        logDeparture(d, clues, lines: lines)
        return DepartMatch.bonuses(clues, ids: clues.map(\.id))
    }

    /// While choosing: the one of `ids` that left the stop with you (`DepartMatch.pick`), by their tracks (with their
    /// own GPS). Nil: no fresh moment, or it doesn't tell them apart.
    private func departPick(_ tracks: [VehicleTrack], ids: [String], lines: [String: String], now: Date) -> String? {
        guard ids.count > 1, let d = departureNow(now) else { return nil }
        let clues: [DepartClue] = tracks.map { DepartMatch.clue($0, at: d) }
        logDeparture(d, clues, lines: lines)
        return DepartMatch.pick(clues, ids: ids)
    }

    /// While choosing between buses: the stopping pattern (`BusStops`). Every candidate's stop near your fixes of the
    /// last 4 minutes, which of them call there (a stop within 60 m), wait there by their timetable, or drive past it
    /// (their road within 40 m); what you did there, kept for the rest of the choice (standing wins). Seconds added to
    /// each one's cost.
    private func busPatternNudge(_ list: [Candidate], lines: [String: String]) -> [String: Double] {
        let fixes: [Fix] = samples.map { Fix($0) }
        guard fixes.count >= 3 else { return [:] }
        var stops: [String: BusStops.Stop] = [:]
        for c in list {
            guard let t = c.trip else { continue }
            for st in t.stops {
                let p = GeoPoint(st.coordinate)
                guard fixes.contains(where: { Geo.metres($0.p, p) <= 300 }) else { continue }
                let k = Habits.key(st.name) + String(format: "|%.4f,%.4f", p.lat, p.lon)
                if stops[k] == nil { stops[k] = BusStops.Stop(key: k, point: p) }
            }
        }
        guard !stops.isEmpty else { return [:] }
        for c in list {
            guard let t = c.trip else { continue }
            let id = c.vehicle.tripId
            let path: [GeoPoint] = t.path.map { GeoPoint($0) }
            for k in Array(stops.keys) {
                guard var s = stops[k] else { continue }
                let calls: [LiveTrip.Stop] = t.stops.filter { Geo.metres(GeoPoint($0.coordinate), s.point) <= BusStops.serves }
                if !calls.isEmpty { s.served.insert(id) }
                for x in calls {
                    let a: Date? = x.scheduledArrival ?? x.arrival, dp: Date? = x.scheduledDeparture ?? x.departure
                    if let a, let dp, dp.timeIntervalSince(a) >= BusStops.dwell { s.waits.insert(id) }
                }
                if path.count >= 2, let pr = Geo.project(s.point, on: path), pr.crossTrack <= BusStops.passes { s.passing.insert(id) }
                stops[k] = s
            }
        }
        for (k, s) in stops where busSeen[k] != .stood {
            if let seen = BusStops.seen(fixes, at: s.point) { busSeen[k] = seen }
        }
        let ids: [String] = list.map(\.vehicle.tripId)
        let against: [String: Int] = BusStops.against(Array(stops.values), seen: busSeen, ids: ids)
        let pen: [String: Double] = BusStops.penalties(against, ids: ids)
        if !pen.isEmpty {
            let words: [String] = pen.keys.sorted().map { id in
                "\(FieldFormat.label(id, lines)) +\(Int(pen[id] ?? 0)) s (\(against[id] ?? 0) against it)"
            }
            let line = "choose · bus stop pattern · " + words.joined(separator: ", ")
            if line != busLogged { busLogged = line; FieldLog.shared.add(.match, line) }
        }
        return pen
    }

    /// While choosing: your usual line breaks a tie (`UsualLine.tieBreak`, held with hysteresis for the rest of the
    /// choice while it stays close). Its slot: the moment you left, else the planned departure, else when choosing began.
    private func usualChoice(_ list: [Candidate], judged: [Judgement], nudge: [String: Double], now: Date) -> String? {
        let planned: Date? = route?.planned?[safe: index]?.departure
        let at: Date = DepartMatch.usable(departure, now: now)?.t ?? planned ?? candSince ?? now
        let cands: [(id: String, line: String, train: Bool)] = list.map { (id: $0.vehicle.tripId, line: $0.vehicle.line, train: $0.vehicle.isTrain) }
        let u: String? = HabitStore.shared.usual(cands, at: at)
        let costs: [UsualLine.Cand] = judged.compactMap { (j: Judgement) -> UsualLine.Cand? in
            guard case .success(let c) = j.result else { return nil }
            return UsualLine.Cand(id: j.id, cost: c + (nudge[j.id] ?? 0), byGPS: VehicleMatch.passedByGPS(j))
        }
        let was = usualHeld
        usualHeld = UsualLine.tieBreak(costs, usual: u, held: was)
        let names: [String: String] = Dictionary(list.map { ($0.vehicle.tripId, $0.vehicle.line) }, uniquingKeysWith: { a, _ in a })
        if let h = usualHeld, h != was {
            FieldLog.shared.add(.match, "choose · usual line · \(FieldFormat.label(h, names)) breaks the tie (\(Int(UsualLine.bonus)) s)")
        } else if let w = was, usualHeld == nil {
            FieldLog.shared.add(.match, "choose · usual line · lets go of \(FieldFormat.label(w, names))")
        }
        return usualHeld
    }

    /// Looking for the one you got on: of `list` (best first), your usual line here at this time when it fits about as
    /// well as `best` (`UsualLine.tieBreak`; never over one that fits by its own GPS while it doesn't).
    private func usualTie(_ list: [Match], best: Match) -> Match? {
        guard list.count > 1 else { return nil }
        let at: Date = DepartMatch.usable(departure, now: Date())?.t ?? Date()
        let cands: [(id: String, line: String, train: Bool)] = list.map { (id: $0.vehicle.tripId, line: $0.vehicle.line, train: $0.vehicle.isTrain) }
        guard let u = HabitStore.shared.usual(cands, at: at), u != best.vehicle.tripId,
              let um = list.first(where: { $0.vehicle.tripId == u }) else { return nil }
        let byGPS: Set<String> = Set(lastJudged.filter { VehicleMatch.passedByGPS($0) }.map(\.id))
        let costs: [UsualLine.Cand] = list.map { UsualLine.Cand(id: $0.vehicle.tripId, cost: $0.score, byGPS: byGPS.contains($0.vehicle.tripId)) }
        guard UsualLine.tieBreak(costs, usual: u, held: nil) == u else { return nil }
        let names: [String: String] = [u: um.vehicle.line, best.vehicle.tripId: best.vehicle.line]
        let gap = Int((um.score - best.score).rounded())
        FieldLog.shared.add(.match, "detect · usual line · \(FieldFormat.label(u, names)) over \(FieldFormat.label(best.vehicle.tripId, names)) (\(gap) s apart)")
        return um
    }

    /// 0.38: what you rode teaches your usual line (`UsualLine`): `weight` confirmed, said, or not this one; its slot the
    /// planned departure (`at`, else the planned one's for this leg, else the moment you left, else when it left).
    private func learnLine(_ v: Vehicle, weight: Int, at: Date? = nil) {
        guard !demo, !v.line.isEmpty else { return }
        let planned: Date? = route?.planned?[safe: index].flatMap { $0.tripId == v.tripId ? $0.departure : nil }
        let when: Date = at ?? planned ?? DepartMatch.usable(departure, now: Date())?.t ?? legFrom ?? Date()
        HabitStore.shared.rode(line: v.line, train: v.isTrain, at: when, weight: weight)
        rideLog("usual line · \(Self.logLabel(v)) \(weight > 0 ? "+" : "")\(weight)")
    }

    /// The notification's buttons for "IC to 's-Hertogenbosch or IC to Eindhoven?".
    nonisolated static func whichTrainButtons(_ titles: [String]) -> UNNotificationCategory {
        let a = UNNotificationAction(identifier: "TRAIN_A", title: titles.first ?? "The first one", options: [])
        let b = UNNotificationAction(identifier: "TRAIN_B", title: titles.dropFirst().first ?? "The other one", options: [])
        return UNNotificationCategory(identifier: whichTrainCategory, actions: [a, b], intentIdentifiers: [], options: [])
    }

    /// Ask once which of two trains you're on: on the ride screen (`whichTrain`), and as a notification with both as
    /// buttons when the app isn't in front.
    private func askWhichTrain(_ a: Vehicle, _ b: Vehicle, to dest: [String: String]) {
        whichTrainAsked = true
        whichTrain = [a, b]
        whichTrainTo = dest.filter { $0.key == a.tripId || $0.key == b.tripId }
        let train = a.isTrain
        let same = a.line.lowercased() == b.line.lowercased()
        let words = [a, b].map { AskSooner.answer(line: $0.line, to: dest[$0.tripId] ?? "", train: train, sameLine: same) }
        let title = AskSooner.title((a.line, dest[a.tripId] ?? ""), (b.line, dest[b.tripId] ?? ""), train: train)
        rideLog("which \(train ? "train" : "bus") · asked: " + title)
        guard UIApplication.shared.applicationState != .active else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { cats in
            var all = cats.filter { $0.identifier != TripManager.whichTrainCategory }
            all.insert(TripManager.whichTrainButtons(words))
            center.setNotificationCategories(all)
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = AskSooner.body(train: train)
            c.sound = .default
            c.categoryIdentifier = TripManager.whichTrainCategory
            c.userInfo = ["kind": "info"]
            center.add(UNNotificationRequest(identifier: TripManager.whichTrainId, content: c, trigger: nil)) { _ in }
        }
    }

    /// The answer: that train, as a pick by hand (`previewHandPick`/`applyHandPick`: the rest of the trip follows it, and
    /// it isn't changed by itself for the rest of this leg).
    func answerWhichTrain(_ tripId: String, fromNotification: Bool = false) async {
        guard let v = whichTrain.first(where: { $0.tripId == tripId }) else { return }
        whichTrain = []; whichTrainTo = [:]
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.whichTrainId])
        rideLog("which \(v.isTrain ? "train" : "bus") · " + Self.logLabel(v) + (fromNotification ? " (notification)" : " (ride screen)"))
        let row = RidePick.Row(tripId: v.tripId, line: v.line, isTrain: v.isTrain, metres: nil, byGPS: false, moves: true,
                               current: v.tripId == vehicle?.tripId, candidate: true)
        guard let p = await previewHandPick(row) else { return }
        await applyHandPick(p)
    }

    // MARK: following without GPS (0.34)

    /// On a ride with its vehicle known: a step every 5 s (`reckonStep`).
    private func startReckon() {
        guard reckonTimer == nil else { return }
        let t = Timer(timeInterval: DeadReckon.every, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reckonStep() }
        }
        RunLoop.main.add(t, forMode: .common)
        reckonTimer = t
    }

    private func stopReckon() {
        reckonTimer?.invalidate(); reckonTimer = nil
        reckonFrom = nil
        if reckoning { reckoning = false }
    }

    /// No good fix for 15 s on a confirmed ride (a tunnel, a dead zone): the ride's place goes on along the vehicle's
    /// route from your last good fix (`DeadReckon.along`): by the vehicle's own fresh GPS, else at its pace (the distance
    /// left over the time to its own arrival, else your last speed). The distance, the time rule, the ETA, the ride screen
    /// and the lock screen keep going by it; only the time rule may ring on it (`DeadReckon.mayRing`). A good fix ends it
    /// (`handle`).
    private func reckonStep() {
        guard phase == .sleeping || phase == .awake, let v = vehicle, let l = leg, !demo else { stopReckon(); return }
        let now = Date()
        guard cands.isEmpty, DeadReckon.needed(lastGoodAt: lastGood?.at, now: now), wakeRoute.count >= 2, let g = lastGood else { return }
        let end = Geo.length(wakeRoute)
        if reckonFrom == nil {
            guard let pr = Geo.project(GeoPoint(g.coordinate), on: wakeRoute), pr.crossTrack <= RouteLeft.offRoute else { return }
            reckonFrom = (pr.along, g.at)
            reckoning = true
            rideLog("reckon · no good GPS for \(Int(now.timeIntervalSince(g.at))) s · on along its route", once: "reckon-start")
        }
        guard let from = reckonFrom else { return }
        let train = legIsTrain
        let pace = DeadReckon.pace(remaining: end - from.metres, arrival: legArrival ?? legTo, now: from.at, lastSpeed: currentSpeed, isTrain: train)
        // the vehicle's own fresh fix, on its route, moved on at that pace (2 minutes at most)
        var byGPS: Double?
        if let f = RealPositionsStore.shared.fix(for: v.tripId, now: now), now.timeIntervalSince(f.at) <= RealPositions.matchFresh,
           let pr = Geo.project(f.point, on: wakeRoute), pr.crossTrack <= 150 {
            byGPS = pr.along + (pace ?? 0) * min(RealPositions.maxAdvanceSeen, max(0, now.timeIntervalSince(f.at)))
        }
        let e = DeadReckon.along(from: from.metres, at: from.at, now: now, pace: pace, gps: byGPS, times: nil, end: end, isTrain: train)
        guard let at = Geo.point(atMetres: e.metres, on: wakeRoute) else { return }
        let d = Geo.metres(at, GeoPoint(l.to.coordinate))
        distance = d
        let tick = RideTick.due(last: lastNetTick, now: now)
        if tick { lastNetTick = now; onNetTick?() }
        if tick, now.timeIntervalSince(lastVehicleRefresh) >= RideTick.vehicleEvery - 1 { lastVehicleRefresh = now; Task { await refreshVehicle() } }
        if phase == .sleeping, now.timeIntervalSince(legStart) >= ShortLeg.noRingFor {   // (0.42.3: not in the first minute)
            let wake = effectiveWake
            let input = WakeRule.Input(by: wake.by, minutes: wake.minutes(isTrain: train), isTrain: train, metres: d,
                                       routeMetres: max(0, end - e.metres), wakeMetres: wakeKm * 1000,
                                       liveArrival: wakeLive?.arrival, liveAge: wakeLive.map { now.timeIntervalSince($0.at) },
                                       speed: pace, fromStartMetres: startDistance, now: now)
            let fire = DeadReckon.decide(input)
            if DeadReckon.mayRing(fire, deadReckoned: true), let fire {
                if legIsShort {
                    // (0.42.3) a short leg doesn't ring: awake, the quiet word and the announcement (`ShortLeg`)
                    phase = .awake; forceArrival = true; quietLeg = true
                    rideLog(FieldFormat.rideShort(spanMetres: legSpan, wakeMetres: wakeKm * 1000))
                    pushActivity(force: true)
                    return
                }
                ring(approach: true, why: "reckoned (\(e.source.rawValue)) · " + WakeRule.log(fire), fire: fire)
                return
            }
        }
        if phase == .sleeping { checkGetReady() }
        if tick { noteNetwork(); updateChangeGuide(); refreshEta(force: false) }
        pushActivity(force: false)
    }

    // MARK: smoother rides (0.39)

    /// The network said so, or a ride's answer didn't come: `offline` (the ride goes on from its saved copy). Back
    /// online after it was gone: ask again at once.
    private var netDown = false
    private var noAnswer = false
    private func setOffline() {
        let o = netDown || noAnswer
        if o != offline { offline = o }
    }

    private func noteNetwork() {
        let on = Net.online
        if RideCache.backOnline(wasOffline: netDown, online: on) {
            netDown = false
            rideLog("network · back: asking again", once: "net-back", every: 60)
            lastVehicleRefresh = Date()
            Task { await refreshVehicle() }
            refreshEta(force: true)
            refreshPlannedNext(force: true)
        } else if !on, !netDown {
            netDown = true
            rideLog("network · gone: the ride goes by its saved stops and times", once: "net-gone", every: 60)
        }
        setOffline()
    }

    private func noteAnswer() {
        noAnswer = false
        if usingSaved { usingSaved = false }
        setOffline()
    }

    private func noteNoAnswer() {
        noAnswer = true
        setOffline()
    }

    /// No answer for the ride: its stops, times, platform and road from the copy saved on the phone (`RideCache`), where
    /// the ride doesn't have them already. The ride screen, the wake rules and the following without GPS go on by it.
    private func useSaved(_ v: Vehicle) {
        guard !demo, let c = RideCacheStore.shared.liveTrip(v.tripId, trip: tripStart) else { return }
        if vehicleStops.isEmpty || legTo == nil { applyStops(RideCacheStore.shared.tripStops(v.tripId, trip: tripStart)) }
        if wakeRoute.isEmpty { noteWakeTrip(c.trip, at: c.at) }
        if arrivePlatform == nil { noteRideDetails(c.trip) }
        if !usingSaved {
            usingSaved = true
            rideLog("saved · no answer: going by the copy saved at \(Fmt.hhmm(c.at))", once: "saved|\(v.tripId)", every: 300)
        }
        updateChangeGuide()
        pushActivity(force: false)
    }

    /// The ride's own answer: the platform you get in at, and how late it is at your stop.
    private func noteRideDetails(_ t: LiveTrip) {
        if !t.headsign.isEmpty { headsign = Fmt.place(t.headsign) }      // (0.42.8) where it really goes
        guard let l = leg, t.stops.count >= 2 else { return }
        let mine = GeoPoint(l.to.coordinate)
        func d(_ i: Int) -> Double { Geo.metres(GeoPoint(t.stops[i].coordinate), mine) }
        guard let i = t.stops.indices.min(by: { d($0) < d($1) }), d(i) < RideCache.near else { return }
        let s = t.stops[i]
        let track: String? = s.track?.trimmingCharacters(in: .whitespaces)
        arrivePlatform = (track?.isEmpty ?? true) ? nil : track
        if t.live, let sch = s.scheduledArrival ?? s.scheduled, let a = s.arrival ?? s.departure {
            legDelay = Int((a.timeIntervalSince(sch) / 60).rounded())
        } else {
            legDelay = nil
        }
    }

    /// As the trip starts: its planned rides (from this leg on) saved on the phone, for the stretches without signal.
    private func saveRidesAhead() {
        guard !demo, let start = tripStart else { return }
        let ids: [String] = (route?.planned ?? []).dropFirst(index).map(\.tripId).filter { !$0.isEmpty && !Demo.isDemo($0) }
        let list: [String] = Array(ids.prefix(RideCache.maxRides))
        guard !list.isEmpty else { return }
        Task { [weak self] in
            var n = 0
            for id in list {
                guard let t = await Transit.liveTrip(id) else { continue }
                guard let me = self, me.tripStart == start else { return }
                RideCacheStore.shared.save(t, tripId: id, at: Date(), trip: start, force: true)
                n += 1
            }
            self?.rideLog("saved · \(n) of \(list.count) rides of the trip on the phone")
        }
    }

    /// With a change within 25 minutes (or at it): the next leg's planned ride asked again every 2 minutes, for its live
    /// time and platform (and saved).
    private func refreshPlannedNext(force: Bool = false) {
        guard !demo, index + 1 < legs.count, let p = route?.planned?[safe: index + 1], Net.online else { return }
        let now = Date()
        let soon: Bool = phase == .transfer || ((legTo ?? legArrival).map { $0.timeIntervalSince(now) < 25 * 60 } ?? false)
        guard soon, force || now.timeIntervalSince(plannedNextAt) >= RideCache.every else { return }
        plannedNextAt = now
        let start = tripStart, id = p.tripId
        Task { [weak self] in
            guard let t = await Transit.liveTrip(id, maxAge: 60), let me = self, me.tripStart == start else { return }
            RideCacheStore.shared.save(t, tripId: id, at: Date(), trip: start, force: true)
            RealPositionsStore.shared.learn(id, trip: t)
            me.plannedNextTrip = (id: id, trip: t, at: Date())      // (0.39.1: where its own GPS puts it)
            me.updateChangeGuide()
            me.pushActivity(force: false)
        }
    }

    /// A ride as the change guide takes it: its platform by NS's live one when there is.
    private func guideRide(_ r: Ride) -> ChangeGuide.Ride {
        var plat: String? = NSStore.shared.rail(r)?.track ?? r.platform
        // (0.42.4) a watched train's platform as NS has it now, the moment it changes
        if r.isTrain, let w = WatchStore.shared.liveTrack(num: r.num, planned: r.scheduledDeparture) { plat = w }
        var g = ChangeGuide.Ride(tripId: r.tripId, line: r.line, isTrain: r.isTrain, departure: r.departure, platform: plat, walk: r.walkBefore)
        if let a = r.fromLat, let o = r.fromLon { g.from = GeoPoint(lat: a, lon: o) }      // (0.42.3: where it leaves from)
        return g
    }

    /// The next leg's planned ride at its live time (the planner's answer, the change's list, or its own saved answer),
    /// else the next one found. 0.39.1: its own answer of the last minutes first (asked every 2 minutes at a change):
    /// the change's list can be older, and the plan's time is the timetable's.
    /// (0.42.3) With whether its departure is a live one (`live`; a ride the plan doesn't name: its own flag).
    private func plannedGuideRide() -> (ride: ChangeGuide.Ride, live: Bool)? {
        guard let p = route?.planned?[safe: index + 1] else {
            guard let n = next else { return nil }
            return (ride: guideRide(n), live: n.live)
        }
        let pool: [Ride] = [next].compactMap { $0 } + nextOptions + (phase == .transfer ? upcoming.map(\.trip.first) : [])
        let found: Ride? = pool.first(where: { $0.tripId == p.tripId })
        let d = liveDeparture(of: p, leg: index + 1)
        if let r = found, !d.fresh { return (ride: guideRide(r), live: r.live) }
        var plat: String? = p.platform
        if let r = found, let rp = guideRide(r).platform { plat = rp }
        if plat == nil, let l = legs[safe: index + 1], let sr = RideCacheStore.shared.ride(p.tripId, trip: tripStart),
           let k = RideCache.stop(near: GeoPoint(l.from.coordinate), in: sr) {
            plat = sr.stops[k].platform
        }
        // (0.42.4) a watched train's platform as NS has it now, the moment it changes
        if p.isTrain, let w = WatchStore.shared.liveTrack(num: p.num, planned: p.scheduled ?? p.departure) { plat = w }
        let walk: Int = found?.walkBefore ?? next?.walkBefore ?? 0
        let ride = ChangeGuide.Ride(tripId: p.tripId, line: p.line, isTrain: p.isTrain, departure: d.at, platform: plat, walk: walk)
        return (ride: ride, live: d.live)
    }

    /// 0.39.1: a planned ride's departure from leg `li`'s stop, live when it can be had: its own answer saved in the last
    /// `liveFresh` (`fresh`), else the planner's answer or the leg's list, else its own saved answer, else the plan's.
    private func liveDeparture(of p: PlannedRide, leg li: Int) -> (at: Date, live: Bool, fresh: Bool) {
        let now = Date()
        var saved: (at: Date, live: Bool, savedAt: Date)?
        if let l = legs[safe: li], let sr = RideCacheStore.shared.ride(p.tripId, trip: tripStart),
           let k = RideCache.stop(near: GeoPoint(l.from.coordinate), in: sr), let d = sr.stops[k].departure ?? sr.stops[k].arrival {
            saved = (at: d, live: sr.live, savedAt: sr.savedAt)
        }
        if let s = saved, s.live, now.timeIntervalSince(s.savedAt) <= Self.liveFresh { return (s.at, true, true) }
        let pool: [Ride] = [next].compactMap { $0 } + nextOptions + upcoming.map(\.trip.first)
        if let r = pool.first(where: { $0.tripId == p.tripId }) { return (r.departure, r.live, false) }
        if let s = saved { return (s.at, s.live, false) }
        return (p.departure, false, false)
    }

    /// s: a planned ride's own answer this new is its live time (`liveDeparture`).
    private static let liveFresh: TimeInterval = 180

    /// 0.39.1: the next leg's planned ride is at its stop or still before it by its own GPS (`MissRule.notLeft`).
    /// 0.42.3: or well past it (`MissCall.seen`); nothing to go by: `none`.
    private func plannedSeen(_ id: String) -> MissCall.Seen {
        guard let c = plannedNextTrip, c.id == id, let l = legs[safe: index + 1], c.trip.stops.count >= 2,
              let f = RealPositionsStore.shared.fix(for: id) else { return .none }
        let trip: LiveTrip = c.trip
        let mine = GeoPoint(l.from.coordinate)
        let ds: [Double] = trip.stops.map { Geo.metres(GeoPoint($0.coordinate), mine) }
        guard let k = ds.indices.min(by: { ds[$0] < ds[$1] }), ds[k] < RideCache.near else { return .none }
        let now = Date()
        let at: Double? = trip.gpsPlace(f, now: now)?.raw
        let stopAt: Double = trip.metres(ofStop: k)
        return MissCall.seen(vehicleMetres: at, stopMetres: stopAt, fixAge: now.timeIntervalSince(f.at))
    }

    /// (0.42.3) The ride you're on has fresh data on when you're in (`MissCall.fresh`): its own GPS, or its live times.
    private func feedingFresh(now: Date) -> Bool {
        let gpsAge: TimeInterval? = vehicle.flatMap { RealPositionsStore.shared.fix(for: $0.tripId, now: now) }.map { now.timeIntervalSince($0.at) }
        let liveAge: TimeInterval? = wakeLive.map { now.timeIntervalSince($0.at) }
        return MissCall.fresh(gpsAge: gpsAge, liveAge: liveAge)
    }

    /// (0.42.3) The ride into the change (on it, or just off it): never the one offered instead.
    private func feedingRide() -> MissCall.Feeding? {
        let p: PlannedRide? = route?.planned?[safe: index]
        if let v = vehicle { return MissCall.Feeding(tripId: v.tripId, line: v.line, isTrain: v.isTrain) }
        if let p { return MissCall.Feeding(tripId: p.tripId, line: p.line, isTrain: p.isTrain) }
        guard let l = legs[safe: index], let a = changeArrived, !a.fromLine.isEmpty else { return nil }
        return MissCall.Feeding(tripId: nil, line: a.fromLine, isTrain: l.mode == .train)
    }

    /// The change ahead (or at it): the platforms, the walk and the minutes; when your ride's live times have you there
    /// too late for the planned one, which one you make instead (`ChangeGuide`).
    private func updateChangeGuide() {
        let on: Bool = phase == .sleeping || phase == .awake || phase == .transfer
        guard !demo, on, index + 1 < legs.count else {
            if changeGuide != nil { changeGuide = nil }
            return
        }
        let now = Date()
        let arrive: Date? = phase == .transfer ? (changeSince ?? now) : (legTo ?? legArrival)
        guard let arr = arrive, let pg = plannedGuideRide() else {
            if changeGuide != nil { changeGuide = nil }
            return
        }
        let planned: ChangeGuide.Ride = pg.ride
        var later: [ChangeGuide.Ride] = []
        var seenIds = Set<String>()
        let pool: [Ride] = nextOptions + (phase == .transfer ? upcoming.map(\.trip.first) : [])
        for r in pool where !r.cancelled && seenIds.insert(r.tripId).inserted { later.append(guideRide(r)) }
        let learned: Double? = Habits.changeMinutes(HabitStore.shared.book)
        let fromTrain: Bool = phase == .transfer ? legs[index].mode == .train : legIsTrain
        let grade: String? = phase == .transfer ? nil : rideGradeNow
        // 0.39.1: at the change, missed only once it has left without you (`MissRule`): its own GPS at or before the stop
        // is still coming; near its time the positions are fetched for it
        let atChange: Bool = phase == .transfer
        let toGo: TimeInterval = planned.departure.timeIntervalSince(now)
        if atChange, toGo < 5 * 60, toGo > -20 * 60 { RealPositionsStore.shared.matcherLooks(trains: planned.isTrain) }
        // 0.42.3 (`MissCall`): at the change also whether its time is a live one and how near its stop you are; on the
        // way whether the ride you're on has fresh data; a miss told only once it held a minute; the one instead from
        // the change, never the ride you're on
        let seen: MissCall.Seen = atChange ? plannedSeen(planned.tripId) : .none
        let nextStop: Place? = legs[safe: index + 1]?.from
        var you: Double?
        if atChange, let f = lastFix, let p = nextStop, now.timeIntervalSince(f.timestamp) < 120, f.horizontalAccuracy >= 0, f.horizontalAccuracy < 150 {
            you = f.distance(from: CLLocation(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude))
        }
        let known = MissCall.Next(live: pg.live, seen: seen, youMetres: you)
        let fresh: Bool = atChange || feedingFresh(now: now)
        let first: MissCall.Call = ChangeGuide.call(arrive: arr, next: planned, learned: learned, now: now, atChange: atChange,
                                                    seen: known, fresh: fresh)
        let step = MissCall.step(missHold, call: first, key: "\(index)|\(planned.tripId)", now: now)
        missHold = step.hold
        var changeAt: [GeoPoint] = []
        if let p = nextStop { changeAt.append(GeoPoint(p.coordinate)) }
        if let l = legs[safe: index] { changeAt.append(GeoPoint(l.to.coordinate)) }
        let g = ChangeGuide.guide(arrive: arr, arrivePlatform: arrivePlatform, fromTrain: fromTrain, grade: grade, next: planned,
                                  later: later, learned: learned, now: now, hhmm: { Fmt.hhmm($0) }, atChange: atChange,
                                  seen: known, fresh: fresh, call: step.call, feeding: feedingRide(), changeAt: changeAt)
        let at: String = Fmt.hhmm(planned.departure)
        if seen == .notLeft, now.timeIntervalSince(planned.departure) > MissRule.grace {
            rideLog("change · the \(at) is still at or before the stop by its own GPS: not missed",
                    once: "notleft|\(planned.tripId)", every: 300)
        }
        if step.retract { rideLog("change · the \(at) not missed after all", once: "unmiss|\(index)|\(planned.tripId)", every: 300) }
        if first == .missed, step.call != .missed {
            rideLog("change · maybe missing the \(at): held a minute before it's told", once: "maybe|\(index)|\(planned.tripId)", every: 300)
        }
        if g.call == .lookOut {
            rideLog(FieldFormat.changeLookOut(at, live: pg.live, youMetres: you), once: "lookout|\(index)|\(planned.tripId)", every: 300)
        }
        if first == .tight, !atChange {
            rideLog("change · tight for the \(at), not missed\(fresh ? "" : " (the ride you're on has no fresh data)")",
                    once: "tight|\(index)|\(planned.tripId)", every: 300)
        }
        if step.call == .missed, g.call == .tight {
            rideLog("change · no ride instead from the change: tight, run for the \(at)", once: "noinstead|\(index)|\(planned.tripId)", every: 300)
        }
        guard g != changeGuide else { return }
        if g.missed, changeGuide?.missed != true { rideLog("change · \(g.missText ?? "missed")", once: "miss|\(index)|\(planned.tripId)", every: 300) }
        changeGuide = g
    }

    /// The change guide's switch is offered: the planned one is missed, another one is made, and the trip is a planned
    /// one (its rides known leg by leg) so the rest can be planned again.
    var canSwitchChange: Bool {
        guard let g = changeGuide, g.missed, let p = g.planned, g.target.tripId != p.tripId, let r = route,
              let c = r.custom, let pl = r.planned, pl.count == c.count else { return false }
        return index + 1 < c.count
    }

    /// One tap: the rest of the trip from the change, planned again onto the one you make (`ChangeGuide.pickPlan`).
    func switchChange() async {
        guard canSwitchChange, !switchingChange, let g = changeGuide, let r = route, let custom = r.custom, let planned = r.planned,
              let final = custom.last?.to else { return }
        let to = g.target, i = index
        switchingChange = true
        defer { switchingChange = false }
        let from = custom[i + 1].from
        let changes = max(0, custom.count - i - 2) + 1
        let opts = await Transit.$urgent.withValue(true) {
            await Transit.plan(from: from, to: final, modes: nil, at: to.departure.addingTimeInterval(-5 * 60), count: 6, maxTransfers: changes)
        }
        guard route?.id == r.id, index == i, phase != .idle else { return }
        let firsts: [(tripId: String, departure: Date)] = opts.map { (tripId: $0.first.tripId, departure: $0.first.departure) }
        guard let k = ChangeGuide.pickPlan(firsts, instead: to), let rest = RoutePlan.from(opts[k]), let restLegs = rest.custom,
              let restPlanned = rest.planned else {
            toast = "Couldn’t plan the rest from the \(Fmt.hhmm(to.departure)) just now. Try again in a minute."
            return
        }
        let t = opts[k]
        let legsNow: [Leg] = Array(custom[...i]) + restLegs
        let plannedNow: [PlannedRide] = Array(planned[...i]) + restPlanned
        let nr = RoutePlan(id: r.id, name: r.name, station: r.station, custom: legsNow, planned: plannedNow, plannedEnd: r.plannedEnd)
        route = nr
        legs = nr.legs(direction)
        next = t.first
        arrival = t.last.arrival
        if phase == .transfer { changePlanned = TransferPolicy.Listed(id: t.first.tripId, departure: t.first.departure) }
        rideLog("change · switched to \(t.first.line) \(Fmt.hhmm(t.first.departure)) at \(from.short)")
        let plat: String = guideRide(t.first).platform.map { " from platform \($0)" } ?? ""
        toast = "Switched to the \(Fmt.hhmm(t.first.departure))\(plat)"
        updateChangeGuide()
        saveRidesAhead()
        refreshEta(force: true)
        Task { await loadUpcoming(force: true) }
        pushActivity(force: true)
    }

    /// "Get ready" one stop before yours (`GetReady`), once a leg, while the alarm hasn't rung: quiet.
    private func checkGetReady() {
        guard !demo, phase == .sleeping, !readyTold, let b = GetReady.before(count: vehicleStops.count) else { return }
        let yours: Date? = legTo ?? vehicleStops.last?.arrival
        let ew = effectiveWake
        let within: TimeInterval = ew.by == .time ? Double(ew.minutes(isTrain: legIsTrain)) * 60 : 0
        let now = Date()
        guard GetReady.due(beforeYours: vehicleStops[b].arrival, yours: yours, now: now, alarmWithin: within, asleep: true, told: false) else { return }
        readyTold = true
        let w = GetReady.words(stop: leg?.to.short ?? "", secondsLeft: yours.map { $0.timeIntervalSince(now) })
        rideLog("get ready · one stop before yours", once: "ready|\(index)", every: 600)
        let c = UNMutableNotificationContent()
        c.title = w.title
        c.body = w.body
        c.sound = nil                                     // quiet: the alarm is what rings
        c.interruptionLevel = .active
        c.userInfo = ["kind": "info"]
        tripNotice(c, .arrived, category: WristNotice.tripCategory)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: GetReady.id(tripStart: tripStart, leg: index), content: c, trigger: nil)) { _ in }
        if UIApplication.shared.applicationState == .active { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        pushActivity(force: true)
    }

    /// (0.42.3) A short leg's quiet "Get off at the next stop" (`ShortLeg`): once a leg, not in its first minute, about
    /// a stop before yours (by its times), a minute and a half before it's in, or (no times) halfway there.
    private func checkShortNotice(metres d: Double) {
        guard !demo, phase == .awake, quietLeg, !readyTold else { return }
        let now = Date()
        let yours: Date? = legTo ?? vehicleStops.last?.arrival
        var reached = false
        if let b = GetReady.before(count: vehicleStops.count), let t = vehicleStops[b].arrival {
            reached = now >= t.addingTimeInterval(-GetReady.early)
        }
        let left: Double? = yours.map { $0.timeIntervalSince(now) }
        let age: TimeInterval = now.timeIntervalSince(legStart)
        guard ShortLeg.noticeDue(legAge: age, told: readyTold, beforeReached: reached, secondsLeft: left, metres: d,
                                 startedMetres: legStartMetres) else { return }
        readyTold = true
        let w = ShortLeg.words(stop: leg?.to.short ?? "")
        rideLog("get ready · short leg: get off at the next stop (\(Int(d.rounded())) m, leg \(Int(age.rounded())) s old)",
                once: "short-ready|\(index)", every: 600)
        let c = UNMutableNotificationContent()
        c.title = w.title
        c.body = w.body
        c.sound = nil                                     // quiet: a reminder, not the alarm
        c.interruptionLevel = .active
        c.userInfo = ["kind": "info"]
        tripNotice(c, .arrived, category: WristNotice.tripCategory)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: GetReady.id(tripStart: tripStart, leg: index), content: c, trigger: nil)) { _ in }
        if UIApplication.shared.applicationState == .active { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        pushActivity(force: true)
    }

    /// (adaptive wake-up) The ring before your stop, as it went: how soon you stopped it, against how soon you were at
    /// your stop (`arrivedRinging`: there with it still ringing). Learned per mode (`AdaptiveWake`).
    private func noteWakeOutcome(arrivedRinging: Bool) {
        guard !demo, let n = ringNote else { return }
        ringNote = nil
        let now = Date()
        let react: Double? = arrivedRinging ? nil : n.stopped.map { $0.timeIntervalSince(n.at) }
        guard arrivedRinging || react != nil else { return }
        let s = WakeSample(train: n.train, react: react, lead: now.timeIntervalSince(n.at), at: now)
        let before = AdaptiveWakeStore.shared.book.extra(isTrain: n.train)
        if AdaptiveWakeStore.shared.note(s) {
            let after = AdaptiveWakeStore.shared.book.extra(isTrain: n.train)
            rideLog("wake · learned: \(n.train ? "trains" : "buses") \(before) → \(after) min earlier")
        }
    }

    // MARK: what it learns from your rides (0.34)

    /// At the start of the leg after a change: how long the walk across took, and how fast you walked it.
    private func noteChangeWalk(arrived: Date, at from: Place) {
        let fixes = samples.filter { $0.timestamp >= arrived }.map { Fix($0) }
        if let m = Habits.changeMinutes(arrived: arrived, fixes: fixes, stop: GeoPoint(from.coordinate)) { HabitStore.shared.addChange(m) }
        if let v = Habits.walkSpeed(of: fixes) { HabitStore.shared.addWalk(v) }
    }

    /// The one you got on, found: where you got on (the trip's first ride), how fast you walked there, and whether you
    /// made the change before it (the one planned, or one leaving with it: `ChangeOdds.made`).
    /// (0.42.4) Got on at another stop of its trip than the leg was planned from (the bus station a stop or two before
    /// Biezendijk): the leg starts where you got on (`WaitStart.repoint`: of its stops, the one nearest to where you
    /// started moving at bus speed); where you get off and the rest of the trip stay as they were.
    private func boardedHere(_ v: Vehicle, stops: [TripStop]) {
        guard !demo, index == 0, let r = route, var custom = r.custom, !custom.isEmpty, let here = samples.last,
              phase == .sleeping || phase == .awake else { return }
        let now = Date()
        let list: [WaitStart.Stop] = stops.map { WaitStart.Stop(name: $0.name, point: GeoPoint($0.coordinate), time: $0.arrival) }
        let cur: Leg = custom[0]
        let had = GeoPoint(cur.from.coordinate)
        let start: GeoPoint? = WaitStart.startedMoving(recentFixes, now: now)
        guard let i = WaitStart.repoint(list, startedAt: start, here: GeoPoint(here.coordinate), planned: had) else { return }
        let s: TripStop = stops[i]
        let name: String = Fmt.place(s.name)
        let spot: String = "\(s.coordinate.latitude),\(s.coordinate.longitude)"
        let from = Place(key: "s:\(s.name)|\(spot)", name: s.name, short: name, ids: [spot], coordinate: s.coordinate, spoken: name)
        // (the alarm first: never a leg made short by it, one that rings no more)
        let to = GeoPoint(cur.to.coordinate)
        let wake: Double = wakeKm * 1000
        let wasShort: Bool = ShortLeg.isShort(spanMetres: Geo.metres(had, to), wakeMetres: wake)
        guard wasShort || !ShortLeg.isShort(spanMetres: Geo.metres(GeoPoint(s.coordinate), to), wakeMetres: wake) else { return }
        custom[0] = Leg(mode: cur.mode, from: from, to: cur.to)
        let nr = RoutePlan(id: r.id, name: r.name, station: r.station, custom: custom, planned: r.planned, plannedEnd: r.plannedEnd)
        route = nr
        legs = nr.legs(direction)
        maxDistance = legSpan
        let off: Int = Int((Geo.metres(had, GeoPoint(s.coordinate)) / 10).rounded()) * 10
        rideLog("board · \(Self.logLabel(v)) got on at its stop \(i + 1) of \(stops.count), \(off) m from where the leg was planned from")
    }

    private func noteBoarding(_ v: Vehicle, stops: [TripStop]) {
        guard !demo, let l = leg else { return }
        if index == 0, !boardedNoted, let here = samples.last {
            boardedNoted = true
            let me = GeoPoint(here.coordinate)
            if let s = stops.min(by: { Geo.metres(GeoPoint($0.coordinate), me) < Geo.metres(GeoPoint($1.coordinate), me) }),
               Geo.metres(GeoPoint(s.coordinate), me) <= 300 {
                HabitStore.shared.boarded(at: s.name)
            }
            let walked = samples.filter { $0.timestamp >= here.timestamp.addingTimeInterval(-240) }.map { Fix($0) }
            if let w = Habits.walkSpeed(of: walked) { HabitStore.shared.addWalk(w) }
        }
        if index > 0, changeToRecord, let a = changeArrived, let p = route?.planned?[safe: index] {
            changeToRecord = false
            let from = GeoPoint(l.from.coordinate)
            let dep = stops.filter { Geo.metres(GeoPoint($0.coordinate), from) <= 1500 }
                .min { Geo.metres(GeoPoint($0.coordinate), from) < Geo.metres(GeoPoint($1.coordinate), from) }?.arrival
            if let made = ChangeOdds.made(plannedTrip: p.tripId, plannedDeparture: p.departure, boardedTrip: v.tripId, boardedDeparture: dep) {
                HabitStore.shared.recordChange(from: a.fromLine, to: p.line, at: l.from.name, time: p.departure, made: made)
                rideLog("change · \(made ? "made it" : "missed it") · \(a.fromLine) → \(p.line) at \(l.from.short)")
            }
        }
    }

    // MARK: still the same bus?

    /// Every half minute on board: are you still on its road, and about where its times say? Two buses that leave a stop
    /// together (the 305 to Eindhoven and the 306 to Den Bosch at Veghel, or two 306s close behind each other) look the
    /// same at first. Off its road: it finds the one you are on and switches to it (its stops, its times, and the rest of
    /// your trip). Far from where its times put it while another of the line is right with you: it looks at both again.
    private func checkSameBus() async {
        // picked by hand during the ride: it only looks (and asks once when you're clearly off its road)
        if !HandLock.autoSwitch(handLock, leg: index) { await watchHandPick(); return }
        guard let v = vehicle, let leg, !demo, !pickedByHand, !checkingSame, cands.isEmpty, phase == .sleeping || phase == .awake else { return }
        let now = Date()
        let recent = samples.filter { $0.timestamp > now.addingTimeInterval(-45) && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 80 }
        guard let last = recent.last, max(last.speed, currentSpeed ?? 0) >= 4 else { return }      // a clear fix, moving with it
        checkingSame = true
        defer { checkingSame = false }
        if roadOf?.tripId != v.tripId || now.timeIntervalSince(roadOf!.at) > 60 {
            // (the same answer as the vehicle's own times, of the last minute: one fetch for both)
            guard let t = await Transit.liveTrip(v.tripId, maxAge: RideTick.tripCache), t.path.count >= 2 else { return }
            roadOf = (v.tripId, t, now)
        }
        guard let road = roadOf, vehicle == v, cands.isEmpty else { return }
        let t = road.trip
        let limit: Double = v.isTrain ? 700 : 300
        if !MatchSettings.classic() {
            await sameBusByJudging(v, trip: t.noCatchUp(asOf: road.at, isTrain: v.isTrain), leg: leg, last: last, limit: limit, now: now)
            return
        }
        if Self.metres(from: last.coordinate, to: t.path) < limit {
            offRoad = 0
            if !v.isTrain, !t.line.isEmpty, t.line != v.line {
                // the same trip, under another number in its own live data
                vehicle = Vehicle(tripId: v.tripId, line: t.line, isTrain: false)
                tellBus("Your bus is listed as \(t.line) now", "The same bus as before, still to \(leg.to.short).")
                pushActivity(force: true)
            }
            // on its road, but far from where its times put it, three looks in a row (a minute and a half): if another of
            // the same line is right where you are, look at both again
            let w = t.position(now), at = t.coordinate(atMetres: w.metres)
            let far = w.done || last.distance(from: CLLocation(latitude: at.latitude, longitude: at.longitude)) > (v.isTrain ? 2500 : 1000)
            farLooks = far ? farLooks + 1 : 0
            noteSameLook(v, passed: !far)
            if farLooks >= 3 {
                farLooks = 0
                let R = MatchRules.current()
                let near = await matchVehicles(mode: leg.mode, excluding: [v.tripId], place: "same bus")
                    .filter { $0.cost < R.sameLineNear && $0.vehicle.line == v.line }.prefix(2).map(\.vehicle)
                if !near.isEmpty, vehicle == v { beginChoosing([v] + near) }
            }
            return
        }
        offRoad += 1
        noteSameLook(v, passed: false)                        // (in doubt: the best GPS, at once)
        guard offRoad >= 2 else { return }                    // off its road twice, half a minute apart
        offRoad = 0
        if let found = await findBusYoureOn(not: v, at: last, limit: limit), vehicle == v {
            await switchVehicle(from: v, to: found.vehicle, stops: found.stops)
            // others fit about as well (lines that share the road out of a bus station): they stay in the running
            // (still on it after the switch: a stop or another switch meanwhile leaves no stale candidates)
            if !found.others.isEmpty, vehicle == found.vehicle { beginChoosing([found.vehicle] + found.others) }
        } else {
            sameCheckAt = Date().addingTimeInterval(120)      // a detour, or no better one: look again in a while
        }
    }

    /// `checkSameBus` with the matcher, from its road check on: the one it shows is judged on your fixes along its own
    /// road and times (a timetable-only one by its road and your speed, not by its times). While it's not sure yet (too
    /// few fixes, no times now, no track), today's road check decides: 300 m off a bus's road (700 m off a train's) is
    /// a miss, else it's no look at all. Two misses in a row: it finds the one you're on, and chooses between them, so it
    /// switches (and tells you) only once that one has clearly been the one for a while. Otherwise as today: a new line
    /// number, and the looks far from its times (not for a timetable-only one, or one whose times are done, and not the
    /// same choice again within 10 minutes of one that ran out of time).
    /// Its own GPS (0.20.3): judged by where its fix puts it when it has a fresh one; and within 200 m of you, moving
    /// with you, it's kept (`VehicleMatch.gpsKeeps`: no miss, no looking for another), whatever its judging alone says.
    /// The positions feed (0.20.7): with the vehicle confirmed at most every 2 minutes and no hold on the feed; a look in
    /// doubt (it fails, isn't sure, or was far from its times) fetches fresh positions and judges again before it counts.
    private func sameBusByJudging(_ v: Vehicle, trip t: LiveTrip, leg: Leg, last: CLLocation, limit: Double, now: Date) async {
        let feed = RealPositionsStore.shared
        feed.learn(v.tripId, trip: t)
        await feed.refresh(trains: v.isTrain, ifOlderThan: FeedPolicy.confirmedEvery)
        guard vehicle == v, cands.isEmpty else { return }
        let plain = VehicleTrack(tripId: v.tripId, line: v.line, isTrain: v.isTrain, trip: t)
        var track = plain
        if let k = plain { track = await feed.forMatcher([k], hold: false).first }
        guard vehicle == v, cands.isEmpty else { return }
        BatteryLog.shared.check()
        var judged = track.map { VehicleMatch.judgeAll(recentFixes, [$0], strictTimes: false) } ?? []
        let away = VehicleMatch.offRoad(Self.metres(from: last.coordinate, to: t.path), isTrain: v.isTrain)
        var verdict = VehicleMatch.verdict(judged.first?.result, offRoad: away)
        var mine = judged.first
        var byGPS = VehicleMatch.gpsKeeps(mine?.evidence, isTrain: v.isTrain)
        if FeedPolicy.fetchOnDoubt(verdict, farLooks: farLooks, keptByGPS: byGPS), let k = plain,
           await feed.refresh(trains: v.isTrain, ifOlderThan: FeedPolicy.doubtFresh) {
            guard vehicle == v, cands.isEmpty else { return }
            track = await feed.forMatcher([k], hold: false).first
            guard vehicle == v, cands.isEmpty else { return }
            judged = track.map { VehicleMatch.judgeAll(recentFixes, [$0], strictTimes: false) } ?? []
            verdict = VehicleMatch.verdict(judged.first?.result, offRoad: away)
            mine = judged.first
            byGPS = VehicleMatch.gpsKeeps(mine?.evidence, isTrain: v.isTrain)
        }
        let shown = FieldFormat.label(v.tripId, [v.tripId: v.line])
        var keptNote = ""
        if byGPS, verdict != .passes {
            // its GPS has it right with you: kept, whatever its judging alone said
            let instead: String
            if case .failure(let why)? = mine?.result { instead = FieldFormat.reject(why, mine?.evidence) }
            else { instead = away ? "off its road" : "" }
            FieldLog.shared.add(.match, FieldFormat.keptByGPS(label: shown, metres: mine?.evidence.map { abs($0.offset) },
                                                              gpsAge: mine?.evidence?.gpsAge, instead: instead))
            verdict = .passes; keptNote = " · by GPS"
        }
        // its own GPS fitted a moment ago (0.26.1): a failure by its times alone is not sure, not a miss (so it doesn't
        // go looking for another one, and flip back to the one it just left, while the bus's GPS feed is quiet)
        VehicleMatch.noteGPSFits(judged, into: &candGPS.fitAt, now: now)
        noteGPSRuns(judged, kept: byGPS ? v.tripId : nil)                 // (0.39.1)
        if verdict == .fails, !away, let m = mine, VehicleMatch.softened(m, fitAt: candGPS.fitAt[v.tripId], now: now) {
            verdict = .notSure; keptNote = " · its GPS fitted a moment ago"
        }
        // 0.34: a train whose track went elsewhere (300 m off it, or twice the fixes' accuracy): find the one you're on at
        // once (choosing then switches at once to one that fits: `VehicleMatch.choose`'s roads parted)
        if v.isTrain, verdict == .fails, let m = mine, VehicleMatch.roadsParted(m) { offRoad = max(offRoad, 1) }
        if verdict != .fails {
            if verdict == .passes { offRoad = 0 }            // not sure yet, on its road: neither a miss nor a reset
            // 0.34: a train kept by its times or road, not by its own NS position: the other trains on your track, each by
            // its own, every 2 minutes; one with you by its NS position starts a choice (`TrainRules.rivals`)
            if v.isTrain, !byGPS, now >= rivalLookAt {
                rivalLookAt = now.addingTimeInterval(TrainRules.rivalEvery)
                if await lookAtRivals(v, mine: mine) { return }
            }
            FieldLog.shared.add(.match, FieldFormat.match("same bus", judged, outcome: "keep \(shown)" + (verdict == .notSure ? ", not sure" : "") + keptNote,
                                                          planned: v.tripId, count: judged.count))
            if !v.isTrain, !t.line.isEmpty, t.line != v.line {
                // the same trip, under another number in its own live data
                vehicle = Vehicle(tripId: v.tripId, line: t.line, isTrain: false)
                tellBus("Your bus is listed as \(t.line) now", "The same bus as before, still to \(leg.to.short).")
                pushActivity(force: true)
            }
            // on its road, but far from where its live times put it, three looks in a row (a minute and a half): if
            // another of the same line is right where you are, look at both again (timetable times, or times that are
            // done, can't tell two apart). By its own GPS: far from where that puts it (kept by it: not far).
            let w = t.position(now), at = t.coordinate(atMetres: w.metres)
            let far: Bool
            if let e = mine?.evidence, e.gps {
                far = !byGPS && abs(e.offset) > (v.isTrain ? 2500 : 1000)
            } else {
                far = t.live && !w.done && last.distance(from: CLLocation(latitude: at.latitude, longitude: at.longitude)) > (v.isTrain ? 2500 : 1000)
            }
            farLooks = far ? farLooks + 1 : 0
            noteSameLook(v, passed: verdict == .passes && !far)
            if farLooks >= 3 {
                farLooks = 0
                let R = MatchRules.current()
                let near = await matchVehicles(mode: leg.mode, excluding: [v.tripId], place: "same bus")
                    .filter { $0.cost < R.sameLineNear && $0.vehicle.line == v.line }.prefix(2).map(\.vehicle)
                if !near.isEmpty, vehicle == v, !VehicleMatch.sameChoice(([v] + near).map(\.tripId), as: candTimedOut, now: Date()) {
                    beginChoosing([v] + near)
                }
            }
            // 0.39.1: still on another line than planned, its own GPS with you long enough now: say so (once a trip)
            if verdict == .passes, !far, cands.isEmpty, vehicle == v { await checkWrongBus() }
            return
        }
        offRoad += 1
        noteSameLook(v, passed: false)                        // (in doubt: the best GPS, at once)
        let note = VehicleMatch.verdict(judged.first?.result, offRoad: false) != .fails ? " (off its road)" : ""
        FieldLog.shared.add(.match, FieldFormat.match("same bus", judged, outcome: (offRoad >= 2 ? "find another" : "keep \(shown), 1 miss") + note,
                                                      planned: v.tripId, count: judged.count))
        guard offRoad >= 2 else { return }                    // missed twice, half a minute apart
        offRoad = 0
        if let found = await findBusYoureOn(not: v, at: last, limit: limit), vehicle == v {
            // even one that's clearly the best by one look: it chooses between them (and tells you only once it's sure)
            beginChoosing([v, found.vehicle] + found.others)
        } else {
            sameCheckAt = Date().addingTimeInterval(120)      // a detour, or no better one: look again in a while
        }
    }

    /// Start choosing between buses that fit about as well. Nothing changes on screen but "checking"; the one it shows
    /// stays until one is clearly the one.
    private func beginChoosing(_ vs: [Vehicle]) {
        var seen = Set<String>()
        let list = Array(vs.filter { seen.insert($0.tripId).inserted }.prefix(3))
        guard list.count > 1, !demo, !pickedByHand, HandLock.autoSwitch(handLock, leg: index) else { cands = []; choosing = []; return }
        cands = list.map { Candidate(vehicle: $0) }
        choosing = list
        candSince = Date(); candLead = nil; candSwitch = SwitchState(); candMisses = [:]; candGPS.restart()
        whichTrainAsked = false; trainSeen = [:]
        busSeen = [:]; busLogged = ""; usualHeld = nil; candLeftAt = departureNow()?.t
        candCheckAt = Date().addingTimeInterval(8)
        applyGPS()                                            // (choosing: the best GPS, at once)
    }

    /// Every dozen seconds while choosing: how far you are from each one's road and from where its times put it. One
    /// off its road twice is out. Buses of different lines are told apart by their roads (they part somewhere); two
    /// of the same line by their times: once one has been clearly closer (half a kilometre, and less than half as far)
    /// two looks in a row. Still together after twelve minutes: they run as one, it keeps the one it shows.
    private func resolveCandidates() async {
        guard !cands.isEmpty, !resolving, !demo, phase == .sleeping || phase == .awake else { return }
        let now = Date()
        guard let last = samples.last, last.timestamp > now.addingTimeInterval(-30), last.horizontalAccuracy >= 0, last.horizontalAccuracy < 100 else { return }
        resolving = true
        defer { resolving = false }
        var list = cands
        for i in list.indices where list[i].trip == nil || now.timeIntervalSince(list[i].fetched) > 60 {
            if let t = await Transit.liveTrip(list[i].vehicle.tripId) { list[i].trip = t; list[i].fetched = now }
        }
        guard list.map(\.vehicle.tripId) == cands.map(\.vehicle.tripId), phase == .sleeping || phase == .awake else { return }
        if !MatchSettings.classic() { await chooseByJudging(list, last: last, now: now); return }
        let limit: Double = list[0].vehicle.isTrain ? 700 : 300
        for i in list.indices {
            guard let t = list[i].trip, t.path.count >= 2 else { continue }
            list[i].road.append(Self.metres(from: last.coordinate, to: t.path))
            let w = t.position(now), at = t.coordinate(atMetres: w.metres)
            list[i].time.append(w.done ? 99_999 : last.distance(from: CLLocation(latitude: at.latitude, longitude: at.longitude)))
        }
        func offItsRoad(_ c: Candidate) -> Bool { c.road.count >= 2 && c.road.suffix(2).allSatisfy { $0 > limit } }
        let alive = list.filter { !offItsRoad($0) }
        func mean(_ c: Candidate) -> Double { let x = c.time.suffix(4); return x.isEmpty ? .infinity : x.reduce(0, +) / Double(x.count) }
        var winner: Candidate?
        if alive.count == 1 {
            winner = alive[0]
        } else if alive.isEmpty {
            winner = list.min { mean($0) < mean($1) }        // off every road (a detour): the closest by its times
        } else if Set(alive.map(\.vehicle.line)).count == 1, alive.allSatisfy({ $0.time.count >= 3 }) {
            let scored = alive.sorted { mean($0) < mean($1) }
            let a = mean(scored[0]), b = mean(scored[1])
            if b - a > 500 && b > 2 * a {
                let id = scored[0].vehicle.tripId
                let n = candLead?.id == id ? candLead!.n + 1 : 1
                candLead = (id: id, n: n)
                if candLead!.n >= 2 { winner = scored[0] }
            } else {
                candLead = nil
            }
        }
        if winner == nil, let s = candSince, now.timeIntervalSince(s) > 12 * 60 {
            winner = alive.first { $0.vehicle.tripId == vehicle?.tripId } ?? alive.min { mean($0) < mean($1) }
        }
        cands = alive.isEmpty ? list : alive
        choosing = cands.map(\.vehicle)
        if let w = winner { await settle(w.vehicle) }
    }

    /// `resolveCandidates` with the matcher (`VehicleMatch.choose`): each one judged on your fixes (a timetable-only one
    /// by its road and your speed, not by its times). One that fails twice in a row is out ("not sure yet" isn't failing;
    /// the one it shows is never out this way, and while it's not sure yet, today's road check decides whether it
    /// fails). It switches only when the same other one has been a minute better (or the one it shows failed) in 3 looks
    /// in a row spanning 45 s, and never by the times of a timetable-only one: then it keeps the one it shows until their
    /// roads part. Only the one it shows left: it's sure. Still choosing after twelve minutes: it keeps the one it shows,
    /// or, when that one keeps failing, takes the best one.
    private func chooseByJudging(_ list: [Candidate], last: CLLocation, now: Date) async {
        let shown = vehicle?.tripId
        for c in list { RealPositionsStore.shared.learn(c.vehicle.tripId, trip: c.trip) }
        let plain: [VehicleTrack] = list.compactMap { c in
            c.trip.flatMap { VehicleTrack(tripId: c.vehicle.tripId, line: c.vehicle.line, isTrain: c.vehicle.isTrain,
                                          trip: $0.noCatchUp(asOf: c.fetched, isTrain: c.vehicle.isTrain)) }
        }
        // (each with its own fresh GPS fix, when the open data has one)
        let tracks = await RealPositionsStore.shared.forMatcher(plain)
        guard list.map(\.vehicle.tripId) == cands.map(\.vehicle.tripId), phase == .sleeping || phase == .awake else { return }
        BatteryLog.shared.check()
        let judgedAll = VehicleMatch.judgeAll(recentFixes, tracks, strictTimes: false)
        noteGPSRuns(judgedAll)                            // (0.39.1: how long each one's own GPS has fitted you)
        // 0.34: trains: the stopping pattern rules out the ones that call where you went through at speed, or run through
        // where you stood (never all of them)
        var out: Set<String> = list.allSatisfy({ $0.vehicle.isTrain }) ? trainPatternOut(list) : []
        if !out.isEmpty {
            let names = Dictionary(list.map { ($0.vehicle.tripId, $0.vehicle.line) }, uniquingKeysWith: { a, _ in a })
            FieldLog.shared.add(.match, "choose · stopping pattern · not " + out.sorted().map { FieldFormat.label($0, names) }.joined(separator: ", "))
        }
        if let s = shown, out.contains(s) {
            // the one it shows can't be it: the best of the others that fits now, at once (none fits: as before)
            let rest = list.filter { !out.contains($0.vehicle.tripId) }
            if let best = VehicleMatch.rank(judgedAll.filter { j in rest.contains { $0.vehicle.tripId == j.id } }, planned: nil).first?.id,
               let w = rest.first(where: { $0.vehicle.tripId == best }) {
                await settle(w.vehicle); return
            }
            out.remove(s)
        }
        let kept = list.filter { !out.contains($0.vehicle.tripId) }
        let judged = judgedAll.filter { j in kept.contains { $0.vehicle.tripId == j.id } }
        // the one it shows, by today's road check: your last fix from its road
        let mine = kept.first { $0.vehicle.tripId == shown }
        let road = mine?.trip.flatMap { $0.path.count >= 2 ? Self.metres(from: last.coordinate, to: $0.path) : nil }
        let away = VehicleMatch.offRoad(road, isTrain: mine?.vehicle.isTrain ?? false)
        let lines = Dictionary(kept.map { ($0.vehicle.tripId, $0.vehicle.line) }, uniquingKeysWith: { a, _ in a })
        // 0.38: the one that left the stop with you (`DepartMatch`), the bus stopping pattern (`BusStops`) and your usual
        // line (`UsualLine`, a tie-breaker)
        let keptIds: [String] = kept.map(\.vehicle.tripId)
        let keptTracks: [VehicleTrack] = tracks.filter { t in keptIds.contains(t.tripId) }
        let departed: String? = departPick(keptTracks, ids: keptIds, lines: lines, now: now)
        var nudge: [String: Double] = kept.allSatisfy({ !$0.vehicle.isTrain }) ? busPatternNudge(kept, lines: lines) : [:]
        if let u = usualChoice(kept, judged: judged, nudge: nudge, now: now) { nudge[u, default: 0] -= UsualLine.bonus }
        let choosingFor: TimeInterval = candSince.map { now.timeIntervalSince($0) } ?? 0
        let c = VehicleMatch.choose(keptIds, judged: judged, shown: shown, shownOffRoad: away, choosingFor: choosingFor,
                                    misses: &candMisses, state: &candSwitch, gps: &candGPS, now: now, nudge: nudge, departed: departed)
        var note = ""
        if away, VehicleMatch.verdict(judged.first(where: { $0.id == shown })?.result, offRoad: false) == .notSure { note += " · off its road" }
        switch c.why {
        case .onlyOneLeft?: note += " · the only one left"
        case .timedOut?: note += " · 12 minutes"
        case .byGPS?: note += " · by its GPS"
        case .split?: note += " · roads split"
        case .departed?: note += " · left the stop with you"
        case .farByGPS?: note += " · its own GPS far from you, the other one's fits"
        case .decided?, nil: break
        }
        FieldLog.shared.add(.match, FieldFormat.match("choose", judged, outcome: FieldFormat.outcome(c, shown: shown, lines: lines) + note,
                                                      planned: shown, count: judged.count))
        if c.why == .timedOut { candTimedOut = TimedOut(ids: Set(c.alive), at: now) }
        cands = kept.filter { c.alive.contains($0.vehicle.tripId) }
        choosing = cands.map(\.vehicle)
        // 0.34: two trains still tied that go different ways: ask once which one. 0.38: buses too ("305 or 306?"), a
        // minute after you left the stop (`AskSooner`; 3 minutes while your usual line breaks the tie)
        let sameKind: Bool = kept.allSatisfy({ $0.vehicle.isTrain }) || kept.allSatisfy({ !$0.vehicle.isTrain })
        if c.settle == nil, whichTrain.isEmpty, sameKind {
            let dest = Dictionary(kept.compactMap { x in x.trip.map { (x.vehicle.tripId, Fmt.place($0.headsign)) } }, uniquingKeysWith: { a, _ in a })
            let ago: TimeInterval? = candLeftAt.map { now.timeIntervalSince($0) }
            let movingFor: TimeInterval = min(ago ?? .infinity, choosingFor + VehicleMatch.minSpan)
            if AskSooner.due(alive: c.alive, movingFor: movingFor, asked: whichTrainAsked, tieBroken: usualHeld != nil),
               let a = kept.first(where: { $0.vehicle.tripId == c.alive[0] })?.vehicle,
               let b = kept.first(where: { $0.vehicle.tripId == c.alive[1] })?.vehicle,
               AskSooner.worthAsking(lines: (a.line, b.line), destinations: (dest[a.tripId] ?? "", dest[b.tripId] ?? "")) {
                FieldLog.shared.add(.match, "ask · still tied \(Int(movingFor.rounded())) s after leaving · "
                                    + FieldFormat.label(a.tripId, lines) + " or " + FieldFormat.label(b.tripId, lines))
                askWhichTrain(a, b, to: dest)
            }
        }
        guard let id = c.settle, let w = kept.first(where: { $0.vehicle.tripId == id })?.vehicle else { return }
        await settle(w, split: c.why == .split)
        // the one it shows keeps failing and every other one is out: a detour, or none of these; look again in a while
        if c.why == .onlyOneLeft, c.shownFailing { sameCheckAt = Date().addingTimeInterval(120) }
    }

    /// Sure now: the one it showed (just stop saying "checking"), or the other one (switch to it, and tell you).
    private func settle(_ w: Vehicle, split: Bool = false) async {
        cands = []; choosing = []; candLead = nil; candSince = nil; candSwitch = SwitchState(); candMisses = [:]; candGPS.restart()
        if !whichTrain.isEmpty {
            whichTrain = []; whichTrainTo = [:]
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.whichTrainId])
        }
        offRoad = 0; farLooks = 0; sameCheckAt = Date().addingTimeInterval(30)
        guard let old = vehicle, w.tripId != old.tripId else { pushActivity(force: true); return }
        let urgentAsk = isRiding || going      // on a ride: a pause after a 429 mustn't leave it without stops
        let stops = await Transit.$urgent.withValue(urgentAsk) { await Transit.tripStops(w.tripId) }
        guard vehicle == old else { return }
        await switchVehicle(from: old, to: w, stops: stops, split: split)
    }

    /// The one you're on, when it's not the one it thought: first the one planned for this leg and the others it was
    /// choosing between when you got on, then every one whose timetable follows you. It has to run on the road you're
    /// on, and be about where its times say (it may be running late).
    /// `others`: the ones that fit about as well as it, to keep choosing between (classic matching: none, and the first
    /// that fits is the one).
    private func findBusYoureOn(not v: Vehicle, at here: CLLocation, limit: Double) async -> (vehicle: Vehicle, stops: [TripStop], others: [Vehicle])? {
        if !MatchSettings.classic() { return await findByJudging(not: v) }
        let mode = leg?.mode
        var ids: [(id: String, line: String, train: Bool)] = []
        if let p = route?.planned?[safe: index] { ids.append((p.tripId, p.line, p.isTrain)) }
        ids += boardAlternatives.map { ($0.first.tripId, $0.first.line, $0.first.isTrain) }
        ids += await matchVehicles(mode: mode, excluding: [v.tripId]).map { ($0.vehicle.tripId, $0.vehicle.line, $0.vehicle.isTrain) }
        var tried: Set<String> = [v.tripId]
        for c in ids where tried.insert(c.id).inserted {
            if tried.count > 8 { break }
            if let mode, (mode == .train) != c.train { continue }
            guard let t = await Transit.liveTrip(c.id), t.path.count >= 2,
                  Self.metres(from: here.coordinate, to: t.path) < limit else { continue }
            let w = t.position(Date())
            guard !w.done else { continue }
            let at = t.coordinate(atMetres: w.metres)
            guard here.distance(from: CLLocation(latitude: at.latitude, longitude: at.longitude)) < (c.train ? 6000 : 3000) else { continue }
            let line = t.line.isEmpty ? c.line : (c.train ? Transit.trainLabel(t.line) : t.line)
            let urgentAsk = isRiding || going
            let stops = await Transit.$urgent.withValue(urgentAsk) { await Transit.tripStops(c.id) }
            return (Vehicle(tripId: c.id, line: line, isTrain: c.train), stops, [])
        }
        return nil
    }

    /// `findBusYoureOn` with the matcher: every candidate is judged on your fixes (a timetable-only one by its road and
    /// your speed, not by its times), and the best is the one only when it's clearly the best; else it and the ones
    /// close to it stay in the running. On a trip from Fastest trip, when your speed doesn't fit the one it has (or you
    /// don't move with it), the other kind counts too: a train where it planned a bus.
    private func findByJudging(not v: Vehicle) async -> (vehicle: Vehicle, stops: [TripStop], others: [Vehicle])? {
        let mode = leg?.mode
        var anyKind = false
        if route?.custom != nil, let road = roadOf, road.tripId == v.tripId,
           let plain = VehicleTrack(tripId: v.tripId, line: v.line, isTrain: v.isTrain, trip: road.trip.noCatchUp(asOf: road.at, isTrain: v.isTrain)),
           let mine = await RealPositionsStore.shared.forMatcher([plain]).first,
           case .failure(let why)? = VehicleMatch.judgeAll(recentFixes, [mine], strictTimes: false).first?.result {
            anyKind = VehicleMatch.otherKindPossible(why)
        }
        var ids: [(id: String, line: String, train: Bool)] = []
        let planned = route?.planned?[safe: index]
        if let p = planned { ids.append((p.tripId, p.line, p.isTrain)) }
        ids += boardAlternatives.map { ($0.first.tripId, $0.first.line, $0.first.isTrain) }
        ids += await matchVehicles(mode: anyKind ? nil : mode, excluding: [v.tripId], place: "find nearby").map { ($0.vehicle.tripId, $0.vehicle.line, $0.vehicle.isTrain) }
        // each once (not the one it has), of this leg's kind unless it may be the other, at most 8
        var seen: Set<String> = [v.tripId]
        let picked = Array(ids.filter { c in
            guard seen.insert(c.id).inserted else { return false }
            return anyKind || (mode.map { ($0 == .train) == c.train } ?? true)
        }.prefix(8))
        let jobs: [@Sendable () async -> LiveTrip?] = picked.map { $0.id }.map { id in
            { @Sendable in await Transit.liveTrip(id) }
        }
        let trips = await Progressive.all(jobs)
        var tracks: [VehicleTrack] = []
        var found: [String: Vehicle] = [:]
        for (c, t) in zip(picked, trips) {
            guard let t else { continue }
            RealPositionsStore.shared.learn(c.id, trip: t)
            let line = t.line.isEmpty ? c.line : (c.train ? Transit.trainLabel(t.line) : t.line)
            guard let track = VehicleTrack(tripId: c.id, line: line, isTrain: c.train, trip: t.noCatchUp(asOf: Date(), isTrain: c.train)) else { continue }
            tracks.append(track)
            found[c.id] = Vehicle(tripId: c.id, line: line, isTrain: c.train)
        }
        // (each with its own fresh GPS fix, when the open data has one)
        tracks = await RealPositionsStore.shared.forMatcher(tracks)
        let judged = VehicleMatch.judgeAll(recentFixes, tracks, strictTimes: false)
        // 0.39.1: what their own GPS said here goes into the choice that follows (one that fitted a moment ago isn't
        // dropped as "the only one left", and wins when the one shown is far by its own GPS)
        VehicleMatch.noteGPSFits(judged, into: &candGPS.fitAt, now: Date())
        noteGPSRuns(judged)
        let ranked = VehicleMatch.rank(judged, planned: planned?.tripId)
        var state = SwitchState()
        let live = VehicleMatch.liveIds(judged)
        let d = VehicleMatch.decide(shown: nil, ranked: ranked, liveIds: live, state: &state, now: Date())
        // (what it finds is only chosen between: sameBusByJudging starts choosing with it, and switches only once sure)
        FieldLog.shared.add(.match, FieldFormat.match("find", judged, outcome: FieldFormat.outcome(d, lines: found.mapValues(\.line), choosing: true),
                                                      planned: planned?.tripId, count: judged.count))
        let chosen: [String]
        switch d {
        case .switchTo(let id): chosen = [id]
        case .undecided(let xs): chosen = xs
        case .keep, .none: return nil
        }
        guard let first = chosen.first, let x = found[first] else { return nil }
        let urgentAsk = isRiding || going
        let stops = await Transit.$urgent.withValue(urgentAsk) { await Transit.tripStops(first) }
        return (x, stops, chosen.dropFirst().compactMap { found[$0] })
    }

    /// Switch to the bus you're really on, and tell you.
    private func switchVehicle(from old: Vehicle, to v: Vehicle, stops: [TripStop], split: Bool = false) async {
        // (a pick by hand meanwhile holds: never switched away by itself)
        guard HandLock.autoSwitch(handLock, leg: index) else { return }
        roadOf = nil
        // A trip from Fastest trip: the rest of it goes with this bus (the way it was choosing between, or planned again
        // from it), on any leg. Your own two routes follow the station it goes to by themselves.
        if let r = route, !r.isFixed, r.single == nil {
            if let alt = boardAlternatives.first(where: { $0.first.tripId == v.tripId }), let nr = RoutePlan.from(alt) {
                setRoute(nr)
            } else if let here = samples.last, let final = legs.last?.to,
                      let ob = await LiveStore.onBoardTrips(here, to: final, tripId: v.tripId), let t = ob.1.first, let nr = RoutePlan.from(t) {
                setRoute(nr)
            }
        }
        await vehicleFound(v, stops: stops)
        rideLog(FieldFormat.rideStart(how: "switch", vehicle: Self.logLabel(v), stopMetres: metresToLegStop, leg: index + 1, of: legs.count))
        cands = []; choosing = []
        // 0.39.1: on another line than planned, and sure of it: "You're on the 154 to Schijndel, not your 306" instead
        if await checkWrongBus(split: split) { return }
        let to = leg?.to.short ?? "your stop"
        let when = legArrival.map { " · there \(Fmt.hhmm($0))" } ?? ""
        if v.line == old.line {
            tellBus("It’s the other \(v.title)", "Two were close together\(legFrom.map { ": you’re on the one from \(Fmt.hhmm($0))" } ?? ""). Fixed its times: it wakes you for \(to)\(when).")
        } else {
            tellBus("You’re on the \(v.title), not the \(old.title)", "They looked the same when you got on. Fixed: it now wakes you for \(to)\(when).")
        }
    }

    /// Going away from where this leg should take you: what you're really on, found by the road you're on (it may be
    /// running well off its times, so where its times put it can be kilometres away), and the rest planned from it. The
    /// one it has is on this road going this way after all (a route that loops round): it carries on. Nothing found: it
    /// looks again after another stretch.
    private func wrongWay(_ loc: CLLocation) async {
        guard let final = legs.last?.to, phase == .sleeping || phase == .awake else { return }
        let onRoad = await LiveStore.vehiclesByRoad(loc)
        if let v = vehicle, cands.isEmpty, onRoad.contains(where: { $0.tripId == v.tripId }) {
            legClosest = distance; awayLooked = false
            return
        }
        // (0.42.3) on the ride the next leg was planned with: you're on the next leg already (`RideGuards.plannedNextAmong`)
        let plannedNext: String? = route?.planned?[safe: index + 1]?.tripId
        if let id = RideGuards.plannedNextAmong(onRoad.map { $0.tripId }, plannedNext: plannedNext),
           let r = onRoad.first(where: { $0.tripId == id }) {
            boardedPlannedNext(Vehicle(tripId: r.tripId, line: r.line, isTrain: r.isTrain), why: "on its road")
            return
        }
        // Near a station a lot of lines share the first stretch of road (out of Den Bosch: the 154, 306, 3, 60, 156, 1).
        // The ones that also go where you're going come first (the 306 passes Veghel, the 154 doesn't); with more than one,
        // it keeps them all in the running until their roads part.
        let top = Array(onRoad.filter { $0.tripId != vehicle?.tripId }.prefix(6))
        let urgentAsk = isRiding || going
        let goes: Set<String> = await withTaskGroup(of: String?.self) { g in
            for r in top { g.addTask { await Transit.$urgent.withValue(urgentAsk) { await Self.reaches(r.tripId, final) } ? r.tripId : nil } }
            var out = Set<String>()
            for await id in g { if let id { out.insert(id) } }
            return out
        }
        let pool = top.filter { goes.contains($0.tripId) }.isEmpty ? Array(top.prefix(3)) : top.filter { goes.contains($0.tripId) }
        var ob: (LiveStore.OnBoard, [DoorTrip])?
        if let r = pool.first {
            ob = await LiveStore.onBoardTrips(loc, to: final, tripId: r.tripId, late: r.late, line: r.line, isTrain: r.isTrain)
        }
        if ob == nil { ob = await LiveStore.onBoardTrips(loc, to: final, wasMoving: true, history: { self.recentFixes }) }
        guard let ob, ob.0.vehicle.tripId != vehicle?.tripId, let t = ob.1.first, let nr = RoutePlan.from(t),
              phase == .sleeping || phase == .awake, HandLock.autoSwitch(handLock, leg: index) else {
            legClosest = distance; awayLooked = false
            return
        }
        let old = vehicle, v = ob.0.vehicle
        if RideGuards.plannedNextAmong([v.tripId], plannedNext: route?.planned?[safe: index + 1]?.tripId) != nil {
            boardedPlannedNext(v, why: "found on board")          // (0.42.3)
            return
        }
        cands = []; choosing = []
        boardAlternatives = ob.1
        setRoute(nr)
        await vehicleFound(v)
        rideLog(FieldFormat.rideStart(how: "wrong way", vehicle: Self.logLabel(v), stopMetres: metresToLegStop, leg: index + 1, of: legs.count))
        let rest = pool.filter { $0.tripId != v.tripId }.prefix(2).map { Vehicle(tripId: $0.tripId, line: $0.line, isTrain: $0.isTrain) }
        if !rest.isEmpty { beginChoosing([v] + rest) }
        if await checkWrongBus() { pushActivity(force: true); return }        // (0.39.1)
        tellBus(old.map { "You’re on the \(v.title), not the \($0.title)" } ?? "You’re going another way than planned",
                "It was taking you the other way, so the rest is planned from the \(v.title): off at \(legs.first?.to.short ?? "the next stop"), \(final.short) at \(Fmt.hhmm(t.end)).")
        pushActivity(force: true)
    }

    /// 0.42.3: going away from this leg's stop on the ride the next leg was planned with: this leg ends (you got off it)
    /// and the next one starts on that ride, as at a change ("next leg"): its alarm armed, nothing to pick, the plan
    /// kept. (It was "wrong way": the rest planned again from it, a choice between it and another train on the same
    /// track, and a pick by hand of the same train.)
    private func boardedPlannedNext(_ v: Vehicle, why: String) {
        guard phase == .sleeping || phase == .awake, index + 1 < legs.count else { return }
        rideLog("arrive · already on the next leg's \(Self.logLabel(v)) (\(why)): this leg is done", once: "on-next|\(index)", every: 120)
        legDone(why: "on the next leg's ride")
        guard phase == .transfer else { return }
        nextLeg(vehicle: v, how: "next leg (its planned ride, \(why))")
    }

    /// Does this trip still get to `p` (within a kilometre and a half), from now on?
    nonisolated static func reaches(_ tripId: String, _ p: Place) async -> Bool {
        let stops = await Transit.tripStops(tripId)
        let target = CLLocation(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude)
        let now = Date()
        return stops.contains { s in
            (s.arrival ?? .distantFuture) > now && target.distance(from: CLLocation(latitude: s.coordinate.latitude, longitude: s.coordinate.longitude)) < 1500
        }
    }

    private enum Replan { case done, failed, refused }

    /// You're on another bus or train than the one planned, and it doesn't go where this leg does: the rest of the trip
    /// is planned again from it (where to get off, and what then), and the ride follows it.
    /// Not when its next stop is where you are already (a bus standing at the bus station you're at, or pulling in):
    /// that would ring and say "You're at …" at once (`refused`). And not once you've picked one by hand meanwhile.
    private func replanOnto(_ v: Vehicle, stops: [TripStop]) async -> Replan {
        guard let here = samples.last, let final = legs.last?.to else { return .failed }
        let atChange = phase == .transfer
        let urgentAsk = isRiding || going
        let ob = await Transit.$urgent.withValue(urgentAsk) { await LiveStore.onBoardTrips(here, to: final, tripId: v.tripId) }
        let still = atChange ? phase == .transfer : (phase == .sleeping || phase == .awake) && vehicle == nil
        guard !Task.isCancelled, !pickedByHand, still, let ob, let t = ob.1.first, let nr = RoutePlan.from(t) else { return .failed }
        if refusesAtItsStop(nr, what: atChange ? "replan at a change onto" : "replan onto", vehicle: v) { return .refused }
        boardAlternatives = ob.1
        if atChange {
            // (0.39.1) the ride you meant for the next leg stays what it was planned with
            let was: PlannedRide? = route?.planned?[safe: index + 1]
            let wasTo: Place? = legs[safe: index + 1]?.to
            route = nr; legs = nr.legs(direction); index = 0
            beginLeg(vehicle: v, stops: stops, how: "replan at a change")
            meant = was; meantTo = wasTo
        } else {
            setRoute(nr)
            await vehicleFound(v, stops: stops)
            rideLog(FieldFormat.rideStart(how: "replan on board", vehicle: Self.logLabel(v), stopMetres: metresToLegStop, leg: index + 1, of: legs.count))
        }
        // 0.39.1: on another line than planned, and sure of it: "You're on the 154 to Schijndel, not your 306" instead
        if await checkWrongBus() { pushActivity(force: true); return .done }
        tellBus("You’re on the \(v.title)", "Not the one it planned, so the rest is planned from this one: off at \(legs.first?.to.short ?? "the next stop"), \(final.short) at \(Fmt.hhmm(t.end)).")
        pushActivity(force: true)
        return .done
    }

    // MARK: the wrong bus (0.39.1)

    /// This look's fits by each vehicle's own GPS (and `kept`: the ride's own one kept by its GPS), for how long its GPS
    /// has been with you (`WrongBus.Run`).
    private func noteGPSRuns(_ judged: [Judgement], kept: String? = nil) {
        var ids: [String] = judged.filter { VehicleMatch.passedByGPS($0) }.map(\.id)
        if let k = kept { ids.append(k) }
        gpsRuns = WrongBus.note(gpsRuns, fitted: ids, now: Date())
    }

    /// Where a trip goes ("Schijndel"), from its own answer.
    private func headsign(_ tripId: String) async -> String {
        if let c = await Transit.cachedLiveTrip(tripId) { return Fmt.place(c.trip.headsign) }
        let urgentAsk = isRiding || going
        let t = await Transit.$urgent.withValue(urgentAsk) { await Transit.liveTrip(tripId) }
        return t.map { Fmt.place($0.headsign) } ?? ""
    }

    /// Sure you're on another line than the leg was planned with (or the same line somewhere else), one that doesn't
    /// take you where that leg went: say so once a trip, on the ride screen and as a notification, with the best way on
    /// from here (`WrongBus`). Sure: the roads parted (`split`), or its own GPS has been with you 75 s. Never for one you
    /// picked yourself. True: it told you now.
    @discardableResult
    private func checkWrongBus(split: Bool = false) async -> Bool {
        guard !demo, !wrongBusTold, let v = vehicle, let m = meant, m.tripId != v.tripId, !pickedByHand, handLock == nil,
              cands.isEmpty, phase == .sleeping || phase == .awake else { return false }
        let now = Date()
        guard WrongBus.sure(gpsRuns[v.tripId], split: split, now: now) else { return false }
        let urgentAsk = isRiding || going
        let stops: [TripStop] = await Transit.$urgent.withValue(urgentAsk) { await Transit.tripStops(v.tripId) }
        // (one that takes you where that leg went anyway is no wrong bus)
        if let dest = meantTo, !stops.isEmpty, goesAhead(stops, to: dest) { return false }
        let to: String = await headsign(v.tripId)
        let sameLine: Bool = WrongBus.norm(m.line) == WrongBus.norm(v.line)
        var plannedTo = ""
        if sameLine { plannedTo = await headsign(m.tripId) }
        guard WrongBus.differs(plannedLine: m.line, plannedTo: plannedTo, line: v.line, to: to) else { return false }
        guard !wrongBusTold, vehicle == v, !pickedByHand, handLock == nil else { return false }
        wrongBusTold = true
        let next: String? = stops.first(where: { ($0.arrival ?? .distantPast) > Date() }).map { Fmt.place($0.name) }
        let fix: String = await wrongBusFix(v, nextStop: next)
        let title: String = WrongBus.title(line: v.line, to: to, planned: m.line)
        wrongBus = WrongBus.Alert(title: title, body: fix, tripId: v.tripId)
        rideLog(WrongBus.logLine(label: Self.logLabel(v), to: to, planned: m.line, fix: fix) + (split ? " · roads split" : ""))
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = fix
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        c.userInfo = ["kind": "info"]
        let id = WrongBus.id(tripStart: tripStart ?? now)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { _ in }
        pushActivity(force: true)
        return true
    }

    /// The best way on from the wrong one, by the planner: the trip planned again from it already (Fastest trip: where
    /// it has you get off, and what then), else planned now from where you are.
    private func wrongBusFix(_ v: Vehicle, nextStop: String?) async -> String {
        if let pl = route?.planned, pl[safe: index]?.tripId == v.tripId, let l = leg {
            let stop: String = l.to.short
            guard let n = pl[safe: index + 1] else { return WrongBus.fix(getOff: stop, nextStop: nextStop == stop, then: nil, at: nil) }
            return WrongBus.fix(getOff: stop, nextStop: nextStop == stop, then: n.line, at: Fmt.hhmm(n.departure))
        }
        guard let here = samples.last, let final = legs.last?.to else { return WrongBus.noFix }
        let ob = await Transit.$urgent.withValue(true) { await LiveStore.onBoardTrips(here, to: final, tripId: v.tripId) }
        guard let t = ob?.1.first else { return WrongBus.noFix }
        let stop: String = Fmt.place(t.first.toStop)
        guard t.rides.count >= 2 else { return WrongBus.fix(getOff: stop, nextStop: nextStop == stop, then: nil, at: nil) }
        let n: Ride = t.rides[1]
        return WrongBus.fix(getOff: stop, nextStop: nextStop == stop, then: n.line, at: Fmt.hhmm(n.departure))
    }

    /// The ride screen's wrong-bus card, closed.
    func dismissWrongBus() { wrongBus = nil }

    /// The "not yours" card at the stop, closed.
    func dismissOtherAtStop() {
        if let a = otherAtStop { otherClosed.insert(a.tripId) }
        otherAtStop = nil
    }

    /// The one you wait for at leg `li`'s stop: the planned one at its live time, else (your own routes) the first of
    /// the leg's list, every line of it yours.
    private func yoursAtStop(leg li: Int, now: Date) -> OtherAtStop.Yours? {
        if let p = route?.planned?[safe: li] {
            let dep: Date = liveDeparture(of: p, leg: li).at
            return OtherAtStop.Yours(line: p.line, departure: dep, lines: [p.line])
        }
        let rides: [Ride] = upcoming.map(\.trip.first).filter { !$0.cancelled && !$0.isTrain && $0.departure > now.addingTimeInterval(-60) }
        guard let first = rides.min(by: { $0.departure < $1.departure }) else { return nil }
        return OtherAtStop.Yours(line: first.line, departure: first.departure, lines: Set(rides.map(\.line)))
    }

    /// 0.39.1: waiting at the stop you get on at (at a change, or before the first leg), another line's bus stands there
    /// before yours, by its own GPS (`OtherAtStop`): a card, and once a bus a notification. Quiet when you're not at the
    /// stop, or yours is more than 10 minutes off. The stop's whole board is asked once a minute meanwhile.
    private func checkOtherAtStop() {
        let li: Int = phase == .transfer ? index + 1 : index
        let waiting: Bool = phase == .transfer || (phase == .sleeping && vehicle == nil && handLock == nil)
        let now = Date()
        guard !demo, waiting, let l = legs[safe: li], l.mode == .bus, let f = lastFix, f.horizontalAccuracy >= 0,
              f.horizontalAccuracy < 100, now.timeIntervalSince(f.timestamp) < 60, let y = yoursAtStop(leg: li, now: now) else {
            if otherAtStop != nil { otherAtStop = nil }
            return
        }
        let stop = CLLocation(latitude: l.from.coordinate.latitude, longitude: l.from.coordinate.longitude)
        let toStop: Double = f.distance(from: stop)
        let wait: TimeInterval = y.departure.timeIntervalSince(now)
        guard toStop <= OtherAtStop.near, wait >= -60, wait <= OtherAtStop.within else {
            if otherAtStop != nil { otherAtStop = nil }
            return
        }
        RealPositionsStore.shared.matcherLooks(trains: false)     // (the buses' own positions, while it may matter)
        guard !otherLooking else { return }
        otherLooking = true
        let key: String = l.from.key
        let me = GeoPoint(f.coordinate)
        Task { [weak self] in
            guard let self else { return }
            defer { self.otherLooking = false }
            var list: [BoardDeparture] = self.otherBoard.flatMap { $0.key == key ? $0.list : nil } ?? []
            let stale: Bool = self.otherBoard.map { $0.key != key || Date().timeIntervalSince($0.at) >= 60 } ?? true
            if stale {
                let b = await Transit.board(stopIds: l.from.ids, from: Date().addingTimeInterval(-5 * 60), n: 30)
                if !b.isEmpty { list = b; self.otherBoard = (key: key, at: Date(), list: b) }
            }
            guard self.phase == .transfer || self.phase == .sleeping, self.legs[safe: li]?.from.key == key else { return }
            let at = Date()
            let seen: [OtherAtStop.Seen] = list.filter { !$0.cancelled && !$0.train }.map { (d: BoardDeparture) -> OtherAtStop.Seen in
                let g: GPSFix? = RealPositionsStore.shared.fix(for: d.tripId, now: at)
                let m: Double? = g.map { Geo.metres($0.point, me) }
                let age: TimeInterval? = g.map { at.timeIntervalSince($0.at) }
                return OtherAtStop.Seen(tripId: d.tripId, line: d.line, to: Fmt.place(d.headsign), departure: d.time, metres: m, fixAge: age)
            }
            guard let s = OtherAtStop.pick(seen, yours: y, youToStop: toStop, now: at) else {
                if self.otherAtStop != nil { self.otherAtStop = nil }
                return
            }
            let w = OtherAtStop.words(s, yours: y, now: at)
            let a = WrongBus.Alert(title: w.title, body: w.body, tripId: s.tripId)
            if self.otherClosed.contains(s.tripId) {                // (closed: stays closed)
                if self.otherAtStop != nil { self.otherAtStop = nil }
            } else if self.otherAtStop != a {
                self.otherAtStop = a
            }
            guard self.otherTold.insert(s.tripId).inserted else { return }
            let label = FieldFormat.label(s.tripId, [s.tripId: s.line])
            self.rideLog("other at stop · \(label) to \(s.to) by its own GPS \(Int((s.metres ?? 0).rounded())) m from you · not yours · your \(y.line) at \(Fmt.hhmm(y.departure))")
            let c = UNMutableNotificationContent()
            c.title = w.title
            c.body = w.body
            c.sound = .default
            c.userInfo = ["kind": "info"]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: OtherAtStop.id(s.tripId), content: c, trigger: nil)) { _ in }
        }
    }

    /// The rest of the trip, changed under way (still on its first leg).
    private func setRoute(_ nr: RoutePlan) {
        route = nr
        legs = nr.legs(direction)
        index = 0
        distance = nil; arrival = nil; next = nil; legArrival = nil; legFrom = nil; legTo = nil
        maxDistance = legSpan
        legClosest = nil; awayLooked = false; legStartMetres = nil; heldPick = nil; heldFromPlan = false
        missHold = MissCall.Hold()
        if phase == .awake { phase = .sleeping; quietLeg = false }
        Task { await loadUpcoming(force: true) }
    }

    private func tellBus(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.userInfo = ["kind": "info"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "samebus-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil)) { _ in }
    }

    /// How far a point is from a road (a line through points), in metres.
    nonisolated static func metres(from c: CLLocationCoordinate2D, to path: [CLLocationCoordinate2D]) -> Double {
        guard path.count >= 2 else { return .greatestFiniteMagnitude }
        let kx = cos(c.latitude * .pi / 180) * 111_320, ky = 110_540.0
        var best = Double.greatestFiniteMagnitude
        for i in 1..<path.count {
            let ax = (path[i - 1].longitude - c.longitude) * kx, ay = (path[i - 1].latitude - c.latitude) * ky
            let bx = (path[i].longitude - c.longitude) * kx, by = (path[i].latitude - c.latitude) * ky
            let dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy
            let f = l2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / l2)) : 0
            let px = ax + f * dx, py = ay + f * dy
            best = min(best, px * px + py * py)
        }
        return best.squareRoot()
    }

    /// Every minute while riding: the vehicle's live times (delays, next stop).
    private func refreshVehicle() async {
        guard let v = vehicle, !demo else { return }
        let stops = await Transit.tripStops(v.tripId, maxAge: RideTick.tripCache)
        guard vehicle == v else { return }
        guard !stops.isEmpty else {
            // (0.39) no answer (a tunnel, bad 5G): on from the copy saved when the trip started
            noteNoAnswer()
            useSaved(v)
            return
        }
        noteAnswer()
        // (0.42.8) a new answer of its stops: does it go on past the change after all (the first answer may have been
        // none, or a copy saved without the stops further on)
        noteHeadsign(v, stops: stops)
        let num: String = await Transit.cachedLiveTrip(v.tripId)?.trip.num ?? ""
        guard vehicle == v else { return }
        stayOnIfItGoes(stops, num: num)
        applyStops(stops)
        lookForBetterStop(stops)                          // (0.42.8) a later stop of it may be the faster way
        // (the same answer, as it was asked: no request of its own)
        if let c = await Transit.cachedLiveTrip(v.tripId), vehicle == v {
            noteWakeTrip(c.trip, at: c.at)
            noteRideDetails(c.trip)
            RideCacheStore.shared.save(c.trip, tripId: v.tripId, at: c.at, trip: tripStart)
        }
        updateChangeGuide()
        pushActivity(force: false)
    }

    private func applyStops(_ stops: [TripStop]) {
        guard let leg else { return }
        let target = CLLocation(latitude: leg.to.coordinate.latitude, longitude: leg.to.coordinate.longitude)
        let timed = stops.filter { $0.arrival != nil }
        func d(_ s: TripStop, _ to: CLLocation) -> Double { to.distance(from: CLLocation(latitude: s.coordinate.latitude, longitude: s.coordinate.longitude)) }
        guard let s = timed.min(by: { d($0, target) < d($1, target) }), d(s, target) < 1500,
              s.arrival! > Date().addingTimeInterval(-120) else { vehicleStops = stops; return }
        legArrival = s.arrival
        legTo = s.arrival
        let from = CLLocation(latitude: leg.from.coordinate.latitude, longitude: leg.from.coordinate.longitude)
        var start = 0
        if let b = timed.min(by: { d($0, from) < d($1, from) }), d(b, from) < 1500, let dep = b.arrival, dep < s.arrival! {
            legFrom = dep
            start = stops.firstIndex(where: { $0.name == b.name && $0.arrival == b.arrival }) ?? 0
        }
        // Only the stops from where you got on up to yours.
        if let end = stops.firstIndex(where: { $0.name == s.name && $0.arrival == s.arrival }), end >= start { vehicleStops = Array(stops[start...end]) } else { vehicleStops = stops }
        checkTightChange()
    }

    /// On a slow bus (C-rank: much slower than the fastest seen on its stretch) with a change ahead: once the room left
    /// for the next one drops under the 6 minutes a change after such a bus needs, it tells you, once for this leg, so
    /// you're at the doors and go straight across; with no room left at all, that you'll likely miss it and when the
    /// next one leaves. (Only a notification: the alarm is as it was.)
    private func checkTightChange() {
        guard !demo, phase == .sleeping || phase == .awake, let v = vehicle, !v.isTrain, let r = route, index + 1 < legs.count,
              let arr = legTo ?? legArrival else { return }
        let key = "\(r.id)|\(index)"
        guard tightTold != key else { return }
        let planned = r.planned?[safe: index + 1]
        guard let dep = planned?.departure ?? next?.departure else { return }
        let walk = (planned == nil || next?.tripId == planned?.tripId) ? Double(next?.walkBefore ?? 0) : 0
        let room = dep.timeIntervalSince(arr) / 60 - walk
        guard let g = rideGrade(v), ChangeRoom.warnOnRide(grade: g, roomMinutes: room) else { return }
        tightTold = key
        rideLog(FieldFormat.rideTight(Self.logLabel(v), grade: g, minutes: room))
        func what(_ train: Bool, _ line: String, _ name: String) -> String { train ? (line == "IC" ? "Intercity" : name.isEmpty ? line : name) : "bus \(line)" }
        let then = planned.map { what($0.isTrain, $0.line, $0.line) } ?? next.map { what($0.isTrain, $0.line, $0.name) } ?? "next one"
        let at = leg?.to.short ?? "your stop"
        // (0.42.3) "likely miss" only more than a minute short with fresh data of this bus (`MissCall`); the next one named
        // only when it isn't this line again
        if room < -MissCall.margin, feedingFresh(now: Date()) {
            // too late for it by its times: the next one refreshEta found that you can make, if it's a later one
            let later: String = next.flatMap { (n: Ride) -> String? in
                let again: Bool = n.tripId == v.tripId || (n.line == v.line && n.isTrain == v.isTrain)
                return n.departure > dep && !again ? " The next \(what(n.isTrain, n.line, n.name)) leaves \(Fmt.hhmm(n.departure))." : nil
            } ?? ""
            tellBus("You’ll likely miss the \(then) at \(at)",
                    "This \(v.title) is slow (\(g)-rank) and gets there after the \(then) at \(Fmt.hhmm(dep)) leaves.\(later)")
        } else {
            let mins: Int = max(0, Int(room.rounded()))
            tellBus("Tight change at \(at)",
                    "This \(v.title) is slow (\(g)-rank): \(mins) min to the \(then) at \(Fmt.hhmm(dep)). Be at the doors and go straight across.")
        }
    }

    /// The speed rank of the bus you're on, only read: its ride as planned (the stretch the planner ranks), with its own
    /// times on this leg once it's known. Not in the list it was chosen from (a ride that started by itself): by its
    /// own timetable, its live minutes on this leg against the timetable's (`ChangeRoom.ownTimetableGrade`).
    private func rideGrade(_ v: Vehicle) -> String? {
        let rides = upcoming.map(\.trip.first) + boardAlternatives.flatMap(\.rides)
        if let r = rides.first(where: { $0.tripId == v.tripId }) {
            let dep = legFrom ?? r.departure, arr = legTo ?? r.arrival
            return Ratings.shared.peekGrade(key: "\(r.fromId)>\(r.toStop)", minutes: arr.timeIntervalSince(dep) / 60,
                                            scheduled: r.scheduledArrival.timeIntervalSince(r.scheduledDeparture) / 60, cancelled: r.cancelled)
        }
        // its own stop times (its road, as the same-bus check last had it)
        guard let l = leg, let road = roadOf, road.tripId == v.tripId, let from = legFrom, let to = legTo else { return nil }
        func nearest(_ p: Place) -> LiveTrip.Stop? {
            let c = CLLocation(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude)
            func d(_ s: LiveTrip.Stop) -> Double { c.distance(from: CLLocation(latitude: s.coordinate.latitude, longitude: s.coordinate.longitude)) }
            return road.trip.stops.min { d($0) < d($1) }.flatMap { d($0) < 1500 ? $0 : nil }
        }
        guard let a = nearest(l.from)?.scheduled, let b = nearest(l.to)?.scheduled, b > a else { return nil }
        return ChangeRoom.ownTimetableGrade(liveMinutes: to.timeIntervalSince(from) / 60, scheduledMinutes: b.timeIntervalSince(a) / 60)
    }

    /// The speed rank of the bus you're on, for the ride screen's change ahead (read only: nothing is remembered).
    var rideGradeNow: String? { vehicle.flatMap { $0.isTrain ? nil : rideGrade($0) } }

    /// The next stop the bus or train reaches, and when.
    var nextStop: TripStop? { vehicleStops.first { ($0.arrival ?? .distantPast) > Date() } }

    /// The stops along the way, for the track: every station for a train; for a bus only the bigger ones
    /// (the first stop in each new town, and stations), at most four.
    var stopMarks: [StopMark] {
        guard vehicleStops.count > 2, let v = vehicle else { return [] }
        let mid = Array(vehicleStops.dropFirst().dropLast())
        let town: (String) -> String = { $0.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? $0 }
        var picked: [(TripStop, String)] = []
        if v.isTrain {
            let list = mid.count <= 6 ? mid : (0..<6).map { mid[$0 * (mid.count - 1) / 5] }
            picked = list.map { ($0, Fmt.place($0.name)) }
        } else {
            var last = town(vehicleStops[0].name)
            for s in mid {
                let t = town(s.name), station = s.name.lowercased().contains("station")
                if t != last || station { picked.append((s, station ? Fmt.place(s.name) : t)); last = t }
            }
            picked = Array(picked.prefix(4))
        }
        let a = legFrom ?? vehicleStops.first?.arrival, b = legTo ?? vehicleStops.last?.arrival
        return picked.enumerated().map { (i, p) -> StopMark in
            var f = Double(i + 1) / Double(picked.count + 1)
            if let a, let b, let t = p.0.arrival, b > a { f = min(1, max(0, t.timeIntervalSince(a) / b.timeIntervalSince(a))) }
            return StopMark(name: p.1, time: p.0.arrival, fraction: f)
        }
    }

    // MARK: what leaves next

    /// The next buses or trains for the leg you're about to take (before you're on board, and at a transfer).
    /// On the first leg it lists both routes: towards BUas via Den Bosch or Eindhoven, or home the same way.
    func loadUpcoming(force: Bool = false) async {
        var target: (from: Place, to: [Place], mode: Mode)?
        if phase == .transfer, let n = legs[safe: index + 1] { target = (n.from, [n.to], n.mode) }
        else if (phase == .sleeping || phase == .awake) && vehicle == nil, let l = leg {
            let both = index == 0 && route?.isFixed == true && !RoutePlan.all.isEmpty
            target = (l.from, both ? RoutePlan.all.map { $0.legs(direction)[0].to } : [l.to], l.mode)
        }
        guard let t = target else { return }
        let k = "\(t.from.key)>\(t.to.map(\.key).joined(separator: ","))>\(t.mode.rawValue)>\(index)"
        if k != upcomingKey {
            upcomingKey = k; upcomingAt = nil; upcomingError = nil
            // This leg's last answer at once, minus what has left, "as of" until the live one is in; nothing saved: none.
            let now = Date()
            var s = SnapshotStore.shared.load(SavedUpcoming.self, key: "upcoming|\(k)", now: now)
            if let v = s?.value, let la = v.lat, let lo = v.lon,
               !Snapshots.closeEnough(saved: (lat: la, lon: lo), here: (lat: t.from.coordinate.latitude, lon: t.from.coordinate.longitude), metres: 300) { s = nil }
            upcoming = Snapshots.upcoming(s?.value.upcoming ?? [], now: now) { $0.trip.rides.first?.departure ?? .distantPast }
            upcomingBoard = Snapshots.upcoming(s?.value.board ?? [], now: now) { $0.cancelled ? $0.scheduled : $0.time }
            upcomingAsOf = upcoming.isEmpty && upcomingBoard.isEmpty ? nil : s?.at
        }
        // (at a change, standing, with the next one more than 10 minutes off: every 3 minutes, 0.20.7)
        var gap: TimeInterval = 60
        if phase == .transfer {
            let next = changeListed().map(\.departure).filter { $0 > Date() }.min()
            gap = ChangePace.gap(standingFor: transferAnchor.map { Date().timeIntervalSince($0.since) }, nextIn: next.map { $0.timeIntervalSinceNow })
        }
        guard !upcomingBusy, force || upcomingAt.map({ Date().timeIntervalSince($0) >= gap }) ?? true else { return }
        upcomingBusy = true
        defer { upcomingBusy = false }
        let asked = Date()          // (what comes in is at least this new: it's saved as of then)
        let rail = t.mode == .train
        let from = t.from.key == "veghel" ? StopsStore.shared.homePlace : t.from
        // For buses also the stop's own board (asked first, so it runs beside the plans): it shows cancelled buses
        // (the planner leaves them out) and the ones that left.
        async let boardAsk: [BoardDeparture] = rail ? [] : Transit.board(stopIds: from.ids, from: Date().addingTimeInterval(-30 * 60), n: 40)
        let planJobs: [@Sendable () async -> [DoorTrip]] = t.to.map { dest in
            { @Sendable in
                await Transit.plan(from: from, to: dest, modes: rail ? "RAIL" : "BUS", at: Date().addingTimeInterval(-30 * 60), count: 10, maxTransfers: rail ? 1 : 0)
            }
        }
        let planned = await Progressive.all(planJobs)
        var all: [PanelTrip] = []
        for (dest, l) in zip(t.to, planned) {
            Ratings.shared.learn(from, dest, l)
            all += l.map { PanelTrip(trip: $0, from: from, to: dest) }
        }
        var keptSavedBoard = false
        if !rail {
            let names = t.to.map(\.short) + t.to.map(\.name)
            let ids = Set(all.map { $0.trip.first.tripId })
            let b = await boardAsk
            guard k == upcomingKey else { return }
            if b.isEmpty && upcomingAsOf != nil {
                // The board didn't come: the saved one stays, minus what has left, still "as of".
                upcomingBoard = Snapshots.upcoming(upcomingBoard, now: Date()) { $0.cancelled ? $0.scheduled : $0.time }
                keptSavedBoard = !upcomingBoard.isEmpty
            } else {
                upcomingBoard = b.filter { d in ids.contains(d.tripId) || names.contains { !$0.isEmpty && d.headsign.localizedCaseInsensitiveContains($0) } }
            }
        } else {
            guard k == upcomingKey else { return }       // (a late round for another leg leaves its lists alone)
            upcomingBoard = []
        }
        upcomingAt = Date()
        guard !all.isEmpty else {
            if upcomingAsOf != nil {
                // Nothing live yet: the saved list stays, minus what has left; once nothing of it is left, it's gone.
                upcoming = Snapshots.upcoming(upcoming, now: Date()) { $0.trip.rides.first?.departure ?? .distantPast }
                if upcoming.isEmpty && upcomingBoard.isEmpty { upcomingAsOf = nil }
            }
            if upcoming.isEmpty { upcomingError = "Couldn’t load the next \(rail ? "trains" : "buses") just now. It tries again in a minute." }
            return
        }
        // The same bus can come up from both Veghel stops: keep it once, with the least walking.
        var seen = Set<String>()
        let once = all.sorted { $0.trip.first.walkBefore < $1.trip.first.walkBefore }.filter { seen.insert($0.trip.first.tripId).inserted }
        // Hide an option when one that leaves later still gets you there as early.
        let kept = once.filter { o in !once.contains { q in q.id != o.id && q.to == o.to && q.trip.first.departure > o.trip.first.departure && q.trip.last.arrival <= o.trip.last.arrival } }
        upcoming = kept.sorted { $0.trip.first.departure < $1.trip.first.departure }
        upcomingError = nil
        // A saved board that stayed (its own answer didn't come) goes with the rest of the saved answer: all that shows is live.
        if keptSavedBoard { upcomingBoard = [] }
        upcomingAsOf = nil
        noteChangeList(listFrom: asked.addingTimeInterval(-30 * 60))     // (at a change: what the hour's end counts from)
        let fromHere = t.from.key == "here"        // (a leg from where you were: saved with where that was)
        SnapshotStore.shared.save(SavedUpcoming(upcoming: upcoming, board: upcomingBoard,
                                                lat: fromHere ? t.from.coordinate.latitude : nil, lon: fromHere ? t.from.coordinate.longitude : nil),
                                  key: "upcoming|\(k)", at: asked)
        if rail {
            let rows = upcoming.map { ($0.trip, $0.from, $0.to) }
            Task { await NSStore.shared.enrich(rows) }     // the trains show first; NS fills in after
        }
    }

    // MARK: starting by itself

    /// Watches your stations with region monitoring (cheap): full GPS only switches on once you leave one.
    /// The regions iOS already watches (it keeps them across launches) stay when they're the ones wanted: no stopping and
    /// starting all of them at every launch and every authorization callback.
    /// `force`: register them again even when they look the same (one of them failed).
    private func updateWatching(force: Bool = false) {
        // On the corridor its stations' regions start your fixed routes (0.21's list exactly); off it, your home stops
        // and School start a door-to-door trip (0.24: `RoleRegions`).
        var wanted: [RegionSpec] = wantedRegions()
        // (0.29) "Show friends when I'm at school": School's region tells both ways too
        if location.authorizationStatus == .authorizedAlways, UserDefaults.standard.bool(forKey: Self.campusRegionKey) {
            let c = Place.school.coordinate
            wanted = RoleRegions.withCampus(wanted, school: GeoPoint(lat: c.latitude, lon: c.longitude), radius: NearMe.schoolRadius)
        }
        // (the far tier's backstop around a ride's stop is its own: `updateBackstop`)
        let current: [RegionSpec] = location.monitoredRegions.filter { $0.identifier != Self.backstopId }.map { r in
            let c = r as? CLCircularRegion
            return RegionSpec(id: r.identifier, lat: c?.center.latitude ?? .nan, lon: c?.center.longitude ?? .nan,
                              radius: c?.radius ?? -1, entry: r.notifyOnEntry, exit: r.notifyOnExit)
        }
        if force || !RegionPlan.same(wanted: wanted, current: current) {
            for r in location.monitoredRegions where r.identifier != Self.backstopId { location.stopMonitoring(for: r) }
            for w in wanted {
                let r = CLCircularRegion(center: CLLocationCoordinate2D(latitude: w.lat, longitude: w.lon), radius: w.radius, identifier: w.id)
                r.notifyOnEntry = w.entry; r.notifyOnExit = w.exit
                location.startMonitoring(for: r)
            }
        }
        guard autoStart || autoHome else { return }
        if location.authorizationStatus != .authorizedAlways,
           autoStart && location.authorizationStatus == .authorizedWhenInUse { location.requestAlwaysAuthorization() }
    }

    /// The regions the trip itself wants (auto-start, auto-home): as before 0.29.
    private func wantedRegions() -> [RegionSpec] {
        guard location.authorizationStatus == .authorizedAlways else { return [] }
        let homeStops = StopsStore.shared.boardStops.compactMap { b in b.lat.flatMap { la in b.lon.map { GeoPoint(lat: la, lon: $0) } } }
        return RoleRegions.wanted(roles: RoleSnapshot.current, homeStops: homeStops, autoStart: autoStart, autoHome: autoHome,
                                  schoolRadius: NearMe.schoolRadius)
    }

    /// (0.29) A Friends switch that watches School's region changed: the regions again.
    func regionsChanged() { updateWatching() }

    /// (0.29) Whether location is allowed always (regions work only then).
    var locationAlways: Bool { location.authorizationStatus == .authorizedAlways }

    func askForAlways() { location.requestAlwaysAuthorization() }

    private func leftRegion(_ key: String, center: CLLocationCoordinate2D? = nil) {
        guard autoStart, phase == .idle else { return }
        let place: Place
        var ended = lastEnd
        if RoleSnapshot.corridor != nil {
            guard let p = Place.all.first(where: { $0.key == key }) else { return }
            place = p
        } else {
            // off the corridor (0.24): a home stop's region or School's
            guard let role = RoleRegions.role(ofRegion: key) else { return }
            place = role == .home ? .home : .school
            // (a door-to-door trip's last stop has its own key: it ended "here" when it ended inside this region)
            if let e = lastEndSpot, let c = center,
               CLLocation(latitude: e.spot.latitude, longitude: e.spot.longitude).distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) < RoleRegions.homeRadius + 150 {
                ended = (key, e.at)
            }
        }
        // right after a ride ended there: you're walking away from the bus you got off (unless at vehicle speed)
        let fresh = lastFix.flatMap { -$0.timestamp.timeIntervalSinceNow < 60 && $0.speed >= 0 ? $0.speed : nil }
        if RegionLook.skip(place: key, lastEnd: ended, speed: fresh, now: Date()) {
            rideLog("look · left \(key == "veghel" || place == .home ? "the home station" : place == .school ? "school" : "a station") right after a ride ended there: not looking",
                    once: "regionSkip|\(key)", every: 600)
            return
        }
        watchLeft = (place, Date())
        applyGPS()
        detectTask?.cancel()
        detectTask = Task { [weak self] in
            var lastBest: String?
            // (0.33: Motion & Fitness, asked once on this wake-up: already "automotive", the first look in 12 s, not 35)
            await Motion.shared.refresh()
            var first = true
            for _ in 0..<10 {
                let wait = first ? MotionRules.firstRegionLook(Motion.shared.now()) : MotionRules.regionLookUsual
                if first, wait < MotionRules.regionLookUsual { self?.rideLog("motion · automotive on leaving a station: looking in \(Int(wait)) s") }
                first = false
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, !Task.isCancelled, self.phase == .idle else { return }
                guard let v = await self.matchVehicle(mode: nil)?.vehicle else { lastBest = nil; continue }
                if v.tripId == lastBest, await self.autoStartTrip(from: place, on: v) { return }
                lastBest = v.tripId
            }
            guard let self, self.phase == .idle else { return }
            self.watchLeft = nil                            // nothing found: back to cheap watching (or what's open)
            self.applyGPS()
        }
    }

    /// Works out which of your routes this bus or train belongs to, then starts the trip at that leg.
    private func autoStartTrip(from place: Place, on v: Vehicle) async -> Bool {
        // (by the corridor's station names; off it, door to door)
        guard RoleSnapshot.corridor != nil else { return await autoStartDoor(from: place, on: v) }
        let stops = await Transit.tripStops(v.tripId)
        let names = stops.map { $0.name.lowercased() }
        func goes(_ p: Place) -> Bool {
            let w = p == .denBosch ? "hertogenbosch" : p == .eindhoven ? "eindhoven" : p == .breda ? "breda" : "veghel"
            return names.contains { $0.contains(w) }
        }
        var pick: (Direction, RoutePlan, Int)?
        switch place {
        case .home where !v.isTrain:
            if goes(.denBosch) { pick = (.toSchool, RoutePlan.via(.denBosch)!, 0) } else if goes(.eindhoven) { pick = (.toSchool, RoutePlan.via(.eindhoven)!, 0) }
        case .breda where v.isTrain:
            if goes(.denBosch) { pick = (.home, RoutePlan.via(.denBosch)!, 0) } else if goes(.eindhoven) { pick = (.home, RoutePlan.via(.eindhoven)!, 0) }
        case .denBosch, .eindhoven:
            if v.isTrain && goes(.breda) { pick = (.toSchool, RoutePlan.via(place)!, 1) }
            else if !v.isTrain && goes(.home) { pick = (.home, RoutePlan.via(place)!, 1) }
        default: break
        }
        guard let chosen = pick else { return false }
        let (dir, r, i) = chosen
        guard let target = r.legs(dir)[safe: i]?.to, goesAhead(stops, to: target),
              !refusesAtItsStop(r, at: i, direction: dir, what: "auto-start on", vehicle: v) else { return false }
        direction = dir
        start(r, at: i, vehicle: v, auto: true, stops: stops, how: "auto (station left)")
        let c = UNMutableNotificationContent()
        c.title = "Trip started by itself"
        // (a leg that started inside its wake distance has no alarm: it tells you at the stop)
        c.body = "\(v.title): get off at \(legs[safe: i]?.to.short ?? "your stop"). "
            + (phase == .awake ? "It tells you when you’re there." : "It rings \(wakeWords).")
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "autostart", content: c, trigger: nil)) { _ in }
        return true
    }

    /// Off the corridor (0.24): you left your home stop (or School) on this bus or train. The trip to the other one is
    /// planned on from it, the same way Fastest trip starts one when it sees you on board (`LiveStore.onBoardTrips` →
    /// `RoutePlan.from`), and starts.
    private func autoStartDoor(from place: Place, on v: Vehicle) async -> Bool {
        let home = place == .home
        let dest: Place = home ? .school : .home
        guard let here = lastFix,
              let ob = await LiveStore.onBoardTrips(here, to: dest, tripId: v.tripId), ob.0.vehicle.tripId == v.tripId,
              let t = ob.1.first, let r = RoutePlan.from(t), phase == .idle else { return false }
        let dir: Direction = home ? .toSchool : .home
        guard !refusesAtItsStop(r, direction: dir, what: "auto-start on", vehicle: v) else { return false }
        direction = dir
        start(r, vehicle: v, auto: true, alternatives: ob.1, how: "auto (stop left)")
        let c = UNMutableNotificationContent()
        c.title = "Trip started by itself"
        // (a leg that started inside its wake distance has no alarm: it tells you at the stop)
        c.body = "\(v.title): get off at \(legs.first?.to.short ?? "your stop"), on your way to \(home ? RoleWords.current.school : "home"). "
            + (phase == .awake ? "It tells you when you’re there." : "It rings \(wakeWords).")
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "autostart", content: c, trigger: nil)) { _ in }
        return true
    }

    // MARK: expected arrival

    private func refreshEta(force: Bool) {
        if demo { arrival = legArrival ?? legTo; return }
        // every 5 minutes; every 2 when a change is within 15 (the vehicle's own arrival comes every minute anyway)
        let changeIn = index + 1 < legs.count ? (legArrival ?? legTo).map { $0.timeIntervalSinceNow } : nil
        guard force || Date().timeIntervalSince(lastEta) >= RideTick.etaGap(changeIn: changeIn) else { return }
        lastEta = Date()
        let legs = self.legs, i = index, start = legStart, known = legArrival
        Task {
            guard i < legs.count else { return }
            var t: Date
            var window: (Date, Date)?
            if let known, known > Date().addingTimeInterval(-120) { t = known } else {
                // Not recognised yet: the ride that left closest to when you started this leg.
                let l = legs[i]
                let opts = await Transit.plan(from: l.from, to: l.to, modes: l.mode.transitModes, at: start.addingTimeInterval(-40 * 60), count: 8, maxTransfers: l.mode == .train ? 1 : 0)
                    .filter { abs($0.first.departure.timeIntervalSince(start)) < 40 * 60 }
                guard let on = opts.min(by: { abs($0.first.departure.timeIntervalSince(start)) < abs($1.first.departure.timeIntervalSince(start)) }) else { return }
                t = on.rides.last!.arrival
                window = (on.first.departure, t)
            }
            var firstNext: Ride?
            var options: [Ride] = []
            for k in (i + 1)..<max(i + 1, legs.count) {
                let l = legs[k]
                let opts = await Transit.plan(from: l.from, to: l.to, modes: l.mode.transitModes, at: t.addingTimeInterval(120), count: 4, maxTransfers: l.mode == .train ? 1 : 0)
                    .filter { $0.start >= t.addingTimeInterval(60) }
                guard let best = opts.min(by: { ($0.rides.last!.arrival, $0.first.departure) < ($1.rides.last!.arrival, $1.first.departure) }) else { return }
                if firstNext == nil { firstNext = best.first; options = opts.map(\.first) }   // (0.39) the others, for the change guide
                t = best.rides.last!.arrival
            }
            await MainActor.run {
                guard self.index == i, self.phase != .idle else { return }
                self.arrival = t; self.next = firstNext
                if !options.isEmpty { self.nextOptions = options }
                self.updateChangeGuide()
                if let window, self.legArrival == nil { self.legFrom = window.0; self.legTo = window.1 }
                self.pushActivity(force: true)
                self.checkTightChange()
            }
        }
    }

    var nextText: String? {
        guard let n = next, index + 1 < legs.count else { return nil }
        return "Then \(n.isTrain ? n.name : "bus \(n.line)") at \(Fmt.hhmm(n.departure)) from \(legs[index + 1].from.short)"
    }

    /// How far along this leg you are, 0…1: by the clock when the times are known, else by distance.
    /// How far this leg's two ends are apart: the least the leg can be (also when you start it halfway, on board).
    private var legSpan: Double? {
        guard let l = leg else { return nil }
        return CLLocation(latitude: l.from.coordinate.latitude, longitude: l.from.coordinate.longitude)
            .distance(from: CLLocation(latitude: l.to.coordinate.latitude, longitude: l.to.coordinate.longitude))
    }

    /// (0.42.3) This leg is shorter than its wake distance (`ShortLeg.isShort`): it doesn't ring at the start.
    private var legIsShort: Bool { ShortLeg.isShort(spanMetres: legSpan, wakeMetres: wakeKm * 1000) }

    func progress(at now: Date = Date()) -> Double {
        switch phase {
        case .transfer, .finished: return 1
        case .idle: return 0
        default: break
        }
        var byDistance: Double?
        if let d = distance, let m = maxDistance, m > 200 { byDistance = 1 - d / m }
        if let a = legFrom, let b = legTo, b.timeIntervalSince(a) > 60 {
            let t = now.timeIntervalSince(a) / b.timeIntervalSince(a)
            // a late vehicle: don't let the clock run ahead of where you really are (once we know which one you're on,
            // its own live times already have the delay in them)
            if vehicle == nil, let bd = byDistance, t > bd + 0.25 { return min(1, max(0, bd)) }
            return min(0.98, max(0, t))
        }
        return min(1, max(0, byDistance ?? 0))
    }

    private var kicker: String {
        switch phase {
        case .transfer: return "CHANGE HERE"
        case .finished: return "YOU’RE THERE"
        case .alarm(let a): return a ? "WAKE UP" : "GET OFF NOW"
        case .awake: return "GET READY"
        // (0.39) the quiet "Get ready" one stop before yours
        default: return waitingToBoard ? "WAITING TO BOARD" : readyTold ? "GET READY" : "NOW RIDING"
        }
    }

    // MARK: Live Activity

    private var state: TripAttributes.ContentState {
        let title: String
        switch phase {
        case .transfer: title = "Change at \(leg?.to.short ?? "")"
        case .finished: title = "You’re there"
        case .alarm(let a): title = a ? "Wake up: \(leg?.to.short ?? "")" : "Get off now"
        default:
            // (0.42.8) where it really goes, and where you get off ("Intercity to Zwolle · get off at Tilburg")
            let end: String = leg?.to.short ?? ""
            title = vehicle.map { TrainRules.lockHeadline(vehicle: $0.title, headsign: headsign, legEnd: end, stayOnTo: stayOnTo) } ?? leg?.title ?? ""
        }
        var awake = false
        if case .alarm = phase { awake = true } else if phase == .awake { awake = true }
        let song = music.song
        let ride = rideKind
        let extra = lockExtras
        var st: TripAttributes.ContentState = .init(legTitle: title, isTrain: leg?.mode == .train, distanceText: distance.map { Fmt.distance($0) } ?? "–",
                     arrival: arrival, finalName: finalName, nextText: nextText, awake: awake, goingHome: direction == .home,
                     kicker: kicker, stopName: leg?.to.spoken ?? "", progress: (progress() * 100).rounded() / 100,
                     legFrom: legFrom, legTo: legTo, song: song?.title, artist: song?.artist, songPlaying: song?.playing ?? false,
                     musicApp: song?.app, stops: stopMarks.map(\.fraction), ringing: { () -> Bool in if case .alarm = phase { return true }; return false }(),
                     vehicle: ride.kind.rawValue, line: ride.line)
        // (0.39) the next stop, the delay and the platform; the change ahead
        st.nextStop = extra.nextStop
        st.delay = extra.delay
        st.platform = extra.platform
        st.changeText = extra.changeText
        st.changeLeaves = extra.changeLeaves
        st.changeMiss = extra.changeMiss
        st.walkTurn = isRiding ? walkTurn : nil                         // (0.41) walking with arrows
        return st
    }

    /// (0.41) Walking with arrows (`WalkGuideView`) to the next stop during a trip: its next turn on the lock screen
    /// ("→ 40 m · Hoogstraat"). Nil when it's closed.
    var walkTurn: String? {
        didSet { if walkTurn != oldValue, activity != nil { pushActivity(force: false) } }
    }

    /// (0.39) The lock screen's next stop (not yours), delay and platform, and the change ahead.
    private var lockExtras: (nextStop: String?, delay: Int?, platform: String?, changeText: String?, changeLeaves: Date?, changeMiss: String?) {
        var nextName: String?
        let riding = phase == .sleeping || phase == .awake
        if riding, let n = nextStop, let last = vehicleStops.last, !(n.name == last.name && n.arrival == last.arrival) { nextName = Fmt.stop(n.name) }
        var text: String?
        if let g = changeGuide {
            let parts: [String] = [g.lockLine, g.countdown, g.note ?? ""].filter { !$0.isEmpty }    // (0.42.3: "Look out for it")
            text = parts.joined(separator: " · ")
        }
        let delay: Int? = riding ? legDelay : nil
        let platform: String? = riding ? arrivePlatform : nil
        return (nextName, delay, platform, text, changeGuide?.target.departure, changeGuide?.missText)
    }

    /// What the Live Activity draws on its track and puts on its pill: from the bus or train you're on (else the one
    /// this leg was planned with, else the leg's own mode), by its mode and its line.
    private var rideKind: (kind: VehicleKind, line: String) {
        // ("none of these" during the ride: not the planned one's line either)
        let planned = handLock == nil ? route?.planned?[safe: index] : nil
        let line = vehicle?.line ?? planned?.line ?? ""
        let train = vehicle?.isTrain ?? planned?.isTrain ?? (leg?.mode == .train)
        return (VehicleKind.of(mode: train ? "RAIL" : "BUS", line: line, isTrain: train), line)
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let route, activity == nil, phase != .finished else { return }
        Self.endLeftoverActivities()
        activity = try? Activity.request(attributes: TripAttributes(routeName: route.name), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
    }

    /// Live Activities from an earlier run of the app (it was closed, or updated, during a trip): iOS keeps them on the lock
    /// screen, but nothing updates them any more. They go.
    static func endLeftoverActivities(keeping id: String? = nil) {
        for a in Activity<TripAttributes>.activities where a.id != id {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The lock screen follows (0.20.7, `ActivityThrottle`): only what really changed, at most every 30 s (the countdown is
    /// a timer text: it runs by itself), and what it says you should do (waking, ringing, a change, arriving, the
    /// vehicle) at once. A change held back goes once the 30 s are up. `force`: a moment worth looking (as before), not a
    /// reason to send what didn't change.
    private func pushActivity(force: Bool) {
        // riding without one (it couldn't start, or it was lost): start it now
        guard let activity else { if isRiding { startActivity() }; return }
        let s = state
        var key: String = "\(s.legTitle)|\(s.distanceText)|\(s.arrival?.timeIntervalSince1970 ?? 0)|\(s.awake)|\(ActivityThrottle.progressStep(s.progress))"
            + "|\(s.song ?? "")|\(s.artist ?? "")|\(s.songPlaying)|\(s.ringing)|\(s.nextText ?? "")|\(s.vehicle)|\(s.line)"
            + "|\(s.legFrom?.timeIntervalSince1970 ?? 0)|\(s.legTo?.timeIntervalSince1970 ?? 0)|\(s.stops.count)|\(s.finalName)"
        let more: String = "|\(s.nextStop ?? "")|\(s.delay ?? -999)|\(s.platform ?? "")|\(s.changeText ?? "")|\(s.changeMiss ?? "")"
            + "|\(s.walkTurn ?? "")"
        key += more                                                       // (0.39)
        let say: String = "\(s.legTitle)|\(s.awake)|\(s.ringing)|\(s.kicker)|\(s.changeMiss ?? "")"
            + "|\(s.walkTurn ?? "")"                                       // (0.41: a new turn goes at once; it changes only per turn)
        let since = Date().timeIntervalSince(lastActivity)
        let changed = key != lastActivityKey
        guard ActivityThrottle.send(changed: changed, phaseChanged: say != lastActivitySay, sinceLast: since) else {
            if changed { pushActivityLater(after: ActivityThrottle.later(sinceLast: since)) }
            return
        }
        activityLater?.cancel(); activityLater = nil
        lastActivity = Date(); lastActivityKey = key; lastActivitySay = say
        BatteryLog.shared.activityUpdate()
        Task { await activity.update(ActivityContent(state: s, staleDate: nil)) }
    }

    /// A change held back by the 30 s: it goes then (with whatever changed meanwhile).
    private func pushActivityLater(after seconds: TimeInterval) {
        guard activityLater == nil else { return }
        activityLater = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.activityLater = nil
            self.pushActivity(force: false)
        }
    }

    /// Settings → Reset everything.
    func resetAll() {
        if isRiding { endTrip() }
        let d = UserDefaults.standard
        for k in ["busKm", "trainKm", "ringAtStop", "announce", "movingStation", "autoStart", "sound", "pauseMusic", "autoHome", "kmMem", "dir", "dirAt", "autoHomeDay", "quietWhenInUse", "headphonesOnly", "outLoudLater", "backupMinutes", RideGPS.settingKey] { d.removeObject(forKey: k) }
        BatteryLog.shared.clear(); BatteryLog.shared.flush()          // (the battery and data log too)
        busKm = 2; trainKm = 5; ringAtStop = true; announce = true; movingStation = true; autoStart = true
        soundKind = .steam; pauseMusic = false; autoHome = true; quietWhenInUse = true; headphonesOnly = true; outLoudLater = false; kmMem = [:]; lastScore = nil
        direction = Self.savedDirection()
        Ratings.shared.reset(); ScoreBook.shared.reset(); TravelLogStore.shared.reset(); WatchStore.shared.reset(); StopsStore.shared.reset(); LineWatchStore.shared.reset()
        music.disconnectSpotify(); music.source = .off
    }

    /// Settings → "Preview on the lock screen": a made-up trip for a minute, so you can see how it looks.
    func previewActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let now = Date(), home = direction == .home
        let song = music.song
        // (on the corridor today's bus 306 home and Intercity to Breda; off it a bus to Home or your school: 0.24)
        let ride = RoleWords.current.previewRide(home: home)
        let stop = home ? Place.home.spoken : RoleSnapshot.corridor != nil ? Place.breda.spoken : Place.school.spoken
        let s = TripAttributes.ContentState(
            legTitle: ride.legTitle, isTrain: ride.isTrain, distanceText: Fmt.distance(ride.metres),
            arrival: now.addingTimeInterval(ride.arrivalMinutes * 60), finalName: finalName,
            nextText: ride.nextText, awake: false, goingHome: home,
            kicker: "NOW RIDING", stopName: stop, progress: 0.15,
            legFrom: now.addingTimeInterval(-4 * 60), legTo: now.addingTimeInterval(ride.legEndMinutes * 60),
            song: song?.title ?? "Your song", artist: song?.artist ?? "The artist", songPlaying: true, musicApp: song?.app ?? "Spotify",
            vehicle: ride.isTrain ? VehicleKind.ic.rawValue : VehicleKind.bus.rawValue, line: ride.line)
        guard let a = try? Activity.request(attributes: TripAttributes(routeName: "Preview"), content: ActivityContent(state: s, staleDate: nil), pushType: nil) else { return }
        Task {
            // the vehicle drives along, so you can see it move
            for p in [0.35, 0.55, 0.75, 0.95] {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                var n = s; n.progress = p
                n.distanceText = Fmt.distance(ride.metres * (1 - p))
                await a.update(ActivityContent(state: n, staleDate: nil))
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
