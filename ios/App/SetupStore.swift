import Foundation
import SwiftUI

/// The first-run setup (0.23): when it shows, what it starts from, and what Done saves. Also "Set up again" and "Test
/// the setup as a new user", whose backup (`SetupBackup`) keeps your own setup until "Back to my own".
@MainActor
final class SetupStore: ObservableObject {
    static let shared = SetupStore()

    enum Mode: Equatable, Sendable {
        /// A new install: shown by the profile (`setupDone` false), nothing to cancel to.
        case firstRun
        /// Settings › Set up again: what you have now, filled in; Cancel changes nothing.
        case again
        /// Settings › Test the setup as a new user: empty, as a new student sees it; your own is backed up.
        case test
    }

    /// The setup opened from Settings (a new install's shows by itself, from the profile).
    @Published private(set) var mode: Mode?
    /// A test setup is in use: the home shows "Test setup · Back to my own".
    @Published private(set) var testLive: Bool
    /// Done › Try a pretend trip: the demo opens once the setup has closed.
    @Published var demoAfter = false

    private let d = UserDefaults.standard

    private init() {
        testLive = SetupBackup(stored: UserDefaults.standard.object(forKey: SetupBackup.storageKey))?.live == true
    }

    /// The draft the setup starts from.
    func draft(for mode: Mode) -> SetupDraft {
        guard mode == .again else { return .empty }
        let places = PlacesStore.shared, profile = ProfileStore.shared.profile, school = SchoolAlarm.shared
        var dr = SetupDraft()
        dr.school = places.school
        dr.schoolCatalogId = profile.schoolCatalogId
        dr.campus = profile.campus
        dr.schoolNames = [places.school?.name].compactMap { $0 }
        dr.keptHints = profile.calendarHints
        dr.home = places.home
        dr.homeLabel = "As it is now"
        dr.board = StopsStore.shared.boardStops.map { SetupStop(id: $0.id, name: $0.name, lat: $0.lat, lon: $0.lon) }
        dr.boardChosen = false
        dr.others = places.list.filter { $0.kind == .custom }
        switch profile.schedule {
        case .calendars: dr.timetable = .calendars
        case .manual(let w): dr.timetable = .manual; dr.week = w
        case .none: dr.timetable = .later
        }
        dr.calendarIds = school.calendarIds
        dr.earlyMinutes = school.earlyMinutes
        dr.wakeMinutes = school.wakeMinutes
        dr.wakeOn = school.on
        return dr
    }

    // MARK: opening and closing

    /// Settings › Set up again (Settings closes first; the setup opens over the home).
    func setUpAgain() { open(.again) }

    /// Settings › Test the setup as a new user: your own setup is saved first, under its own key, then the setup opens
    /// empty. Never while a trip runs.
    func startTest(tripIdle: Bool) {
        guard tripIdle, !testLive, mode == nil else { return }
        let b = SetupBackup.take(read: { self.d.object(forKey: $0) }, now: Date())
        d.set(b.stored, forKey: SetupBackup.storageKey)
        open(.test)
    }

    private func open(_ m: Mode) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)          // Settings' sheet closes first
            self.mode = m
        }
    }

    /// Cancel, at any step. Nothing was saved yet (Done saves): a test's backup is simply dropped, your own setup is
    /// as it was.
    func cancel() {
        if mode == .test, let b = backup, !b.live { d.removeObject(forKey: SetupBackup.storageKey) }
        mode = nil
    }

    private var backup: SetupBackup? { SetupBackup(stored: d.object(forKey: SetupBackup.storageKey)) }

    // MARK: Done

    /// Done: the draft becomes your setup (a test's becomes the setup in use until "Back to my own").
    func finish(_ dr: SetupDraft, mode m: Mode, demo: Bool) {
        guard SetupLogic.canFinish(dr) else { return }
        // the profile first: the corridor decides the board's defaults and the roles
        ProfileStore.shared.replace(SetupLogic.profile(dr))
        if let b = SetupLogic.board(dr) {
            StopsStore.shared.setBoard(b.stops.map { BoardStop(id: $0.id, name: $0.name, lat: $0.lat, lon: $0.lon) }, lines: b.lines)
        }
        PlacesStore.shared.replaceAll(SetupLogic.places(dr))
        SchoolAlarm.shared.apply(calendarIds: SetupLogic.calendarIds(dr), early: dr.earlyMinutes, wake: dr.wakeMinutes, on: dr.wakeOn)
        // a new student (and the test of one) lands on Next trip first; Set up again keeps the home you picked
        if m != .again { d.set(HomeStyle.nextTrip.rawValue, forKey: HomeStyle.key) }
        if m == .test {
            // what was learnt for your own Home and School isn't the test's (it comes back with your own)
            ProfileStore.shared.rolesSwitched(clearingLearnt: true)
            if var b = backup { b.live = true; d.set(b.stored, forKey: SetupBackup.storageKey) }
            testLive = true
        }
        mode = nil
        if demo {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)      // the setup closes first
                self.demoAfter = true
            }
        }
    }

    // MARK: back to your own

    /// "Back to my own": every saved value the test could change goes back exactly as it was, the stores read them
    /// again, the saved answers go and the school week and the regions are planned again. Not during a trip.
    func backToMine(tripIdle: Bool) {
        guard tripIdle, let b = backup else { return }
        b.restore { k, v in if let v { self.d.set(v, forKey: k) } else { self.d.removeObject(forKey: k) } }
        reloadStores()
        d.removeObject(forKey: SetupBackup.storageKey)
        testLive = false
    }

    private func reloadStores() {
        ProfileStore.shared.reload()
        PlacesStore.shared.reload()
        StopsStore.shared.reload()
        SchoolAlarm.shared.reloadSaved()
        ProfileStore.shared.rolesSwitched(clearingLearnt: false)
    }

    /// At launch, before any store starts: a test that never went live (the app stopped during the setup, or while
    /// Done was saving) is put back now, into the saved values the stores then read. True when it put one back.
    nonisolated static func recoverAtLaunch() -> Bool {
        let d = UserDefaults.standard
        let b = SetupBackup(stored: d.object(forKey: SetupBackup.storageKey))
        switch SetupBackup.atLaunch(b) {
        case .nothing, .keepTesting: return false
        case .restore:
            b?.restore { k, v in if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            d.removeObject(forKey: SetupBackup.storageKey)
            return true
        }
    }
}
