import AuthenticationServices
import SwiftUI
import UIKit

// Settings in the new look (0.32.1): a main page with a search over every setting, a card for you, and two lists of
// topics with what each is set to now; each topic its own page of grouped rows. The topics and the search are in
// SettingsIndex.swift; every row here carries its entry's id (`settingsAnchor`), so a search result opens the right
// page, scrolls to the row and lights it up for a moment. The old look (New look off, on the corridor) keeps its own
// Settings (`SettingsView`).

/// A page of Settings: a topic, and the row to scroll to when a search result opened it.
struct SettingsRoute: Hashable {
    let topic: SettingsTopic
    var focus: String? = nil
}

private struct SettingsFocusKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// The row a search result asked for, lit for a moment on its page.
    var settingsFocus: String? {
        get { self[SettingsFocusKey.self] }
        set { self[SettingsFocusKey.self] = newValue }
    }
}

/// A row's anchor for the search: its id to scroll to, and its background lit while it's the one asked for.
private struct SettingsAnchor: ViewModifier {
    let id: String
    @Environment(\.settingsFocus) private var focus
    func body(content: Content) -> some View {
        let fill: Color? = focus == id ? DS.accentSoft : nil
        return content
            .id(id)
            .listRowBackground(fill)
    }
}

extension View {
    /// This row is the setting `id` of `SettingsIndex` (in either look; only the new look's pages scroll to it).
    func settingsAnchor(_ id: String) -> some View { modifier(SettingsAnchor(id: id)) }
}

// MARK: the main page

/// Settings in the new look: opened from the home's gear.
struct SettingsHub: View {
    var tryDemo: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute] = []
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $path) {
            SettingsMainList(query: query)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.large)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
                .autocorrectionDisabled()
                .navigationDestination(for: SettingsRoute.self) { r in
                    SettingsTopicPage(route: r, tryDemo: tryDemo, dismissSettings: { dismiss() })
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .tint(DS.accentText)
        .environment(\.settingsNewLook, true)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

/// The main page's list: the search's results while something is typed; else you, and the topics.
private struct SettingsMainList: View {
    let query: String
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var music: NowPlaying
    @ObservedObject private var lineWatch = LineWatchStore.shared
    @ObservedObject private var trainWatch = WatchStore.shared
    @ObservedObject private var places = PlacesStore.shared
    @ObservedObject private var school = SchoolAlarm.shared
    @ObservedObject private var friends = FriendStore.shared
    @ObservedObject private var share = LogShareStore.shared
    @ObservedObject private var setup = SetupStore.shared
    @ObservedObject private var profile = ProfileStore.shared
    @AppStorage(HomeStyle.key) private var homeStyle = HomeStyle.live.rawValue
    @AppStorage(RealPositions.settingKey) private var realPositions = true
    @State private var battery = ""

    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            if typed.isEmpty {
                Section { SettingsYouCard() }
                Section {
                    ForEach(SettingsTopic.inGroup(1)) { t in topicLink(t) }
                }
                Section {
                    ForEach(SettingsTopic.inGroup(2)) { t in topicLink(t) }
                }
            } else {
                results
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DS.page.ignoresSafeArea())
        .onAppear(perform: readBattery)
    }

    // MARK: search

    @ViewBuilder private var results: some View {
        let list: [SettingsEntry] = SettingsIndex.entries(corridor: profile.profile.corridor != nil, testSetup: setup.testLive)
        let hits: [SettingsEntry] = SettingsIndex.search(typed, in: list)
        if hits.isEmpty {
            Section {
                Text("No settings for “\(typed)”.").font(DS.body).foregroundStyle(DS.secondary)
            }
        } else {
            Section {
                ForEach(hits) { e in
                    NavigationLink(value: SettingsRoute(topic: e.topic, focus: e.id)) { SettingsResultRow(entry: e) }
                }
            } header: { Text(hits.count == 1 ? "1 setting" : "\(hits.count) settings") }
        }
    }

    // MARK: topics

    private func topicLink(_ t: SettingsTopic) -> some View {
        NavigationLink(value: SettingsRoute(topic: t)) {
            SettingsTopicRow(topic: t, sub: subtitle(t))
        }
    }

    private func subtitle(_ t: SettingsTopic) -> String {
        switch t {
        case .trips: return tripsLine
        case .places: return placesLine
        case .school: return schoolLine
        case .friends: return friendsLine
        case .map: return mapLine
        case .notifications: return noticesLine
        case .battery: return battery
        case .share: return shareLine
        case .advanced: return setup.testLive ? "Test setup in use · logs, reset" : "Logs, diagnostics, reset"
        }
    }

    private var tripsLine: String {
        let backup: String = trip.backupMinutes == 0 ? "no backup alarm" : "backup after \(trip.backupMinutes) min"
        return "\(trip.soundKind.title) · \(backup)"
    }

    private var placesLine: String {
        let names: [String] = places.list.prefix(2).map(\.name)
        let more: Int = max(0, places.list.count - 2)
        return names.joined(separator: ", ") + (more > 0 ? ", \(more) more" : "")
    }

    private var schoolLine: String {
        guard school.on else { return "School alarm off" }
        return "School alarm on · wakes you \(school.wakeMinutes) min before you leave"
    }

    private var friendsLine: String {
        guard friends.hasAccount else { return "Add friends with a code" }
        let n: Int = friends.book?.friends.count ?? 0
        let count: String = n == 1 ? "1 friend" : "\(n) friends"
        return friends.badge > 0 ? "\(count) · \(friends.badge) new" : count
    }

    private var mapLine: String {
        "\(HomeStyle.of(homeStyle).title) · real positions \(realPositions ? "on" : "off")"
    }

    private var noticesLine: String {
        let n: Int = lineWatch.watches.count + trainWatch.watches.count
        let watched: String = n == 0 ? "Nothing watched" : "\(n) watched"
        return music.source == .off ? watched : "\(watched) · \(music.source.title) on the lock screen"
    }

    private var shareLine: String {
        switch (share.on, share.fixesOn) {
        case (false, false): return "Off"
        case (true, false): return "Ride logs on · to \(Maker.name)"
        case (false, true): return "GPS points on · to \(Maker.name)"
        case (true, true): return "Ride logs and GPS points on · to \(Maker.name)"
        }
    }

    private func readBattery() {
        let now = Date()
        let log = BatteryLog.shared
        let saved = log.snapshot(at: now)
        let key: String = log.dayKey(now)
        let mobile = BatteryReport.mobile(saved.days, today: now, calendar: .current, key: { log.dayKey($0) })
        let today: BatteryDay? = saved.days.last { $0.day == key }
        var line = "Today \(BatteryReport.mb(mobile.today)) mobile data"
        if let d = today, d.unplugged >= 60 { line = "Today −\(Int(d.drop.rounded()))% · \(BatteryReport.mb(mobile.today))" }
        battery = line
    }
}

/// A topic's row: its outline icon in the secondary colour, its name and what it's set to.
private struct SettingsTopicRow: View {
    let topic: SettingsTopic
    let sub: String
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: DS.s12) {
            Image(systemName: topic.symbol)
                .font(.body)
                .foregroundStyle(DS.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title).font(DS.bodyStrong).foregroundStyle(DS.text)
                if !sub.isEmpty {
                    Text(sub).font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A search result: the setting, and the topic it's on.
private struct SettingsResultRow: View {
    let entry: SettingsEntry
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: DS.s12) {
            Image(systemName: entry.topic.symbol)
                .font(.body)
                .foregroundStyle(DS.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(DS.body).foregroundStyle(DS.text)
                Text(entry.topic.title).font(DS.footnote).foregroundStyle(DS.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.title), in \(entry.topic.title)")
    }
}

/// You: your Friends name and picture (when you have an account), your school, home town and the app's version.
/// Opens Your places.
private struct SettingsYouCard: View {
    @ObservedObject private var friends = FriendStore.shared
    @ObservedObject private var places = PlacesStore.shared
    @ObservedObject private var profile = ProfileStore.shared
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 54

    private var name: String {
        let n: String = friends.hasAccount ? friends.myName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return n.isEmpty ? "Your school and home" : n
    }

    private var line: String {
        let w = RoleWords.current
        var parts: [String] = []
        let school: String = places.school?.name ?? w.school
        if !school.isEmpty { parts.append(school) }
        parts.append(w.onCorridor ? "Home in \(w.homeTown)" : (places.home == nil ? "No home set" : "Home set"))
        let v: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if !v.isEmpty { parts.append("v\(v)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationLink(value: SettingsRoute(topic: .places)) {
            HStack(spacing: DS.s12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(DS.headline).foregroundStyle(DS.text).lineLimit(2)
                    Text(line).font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(3)
                }
            }
            .padding(.vertical, DS.s4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens your places")
    }

    @ViewBuilder private var avatar: some View {
        if friends.hasAccount {
            FriendAvatar(name: friends.myName, id: friends.myAccount ?? "", picture: friends.myPicture, size: size)
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: size * 0.9, weight: .light))
                .foregroundStyle(DS.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

// MARK: a topic's page

/// A topic's page: its rows, scrolled to (and lighting up) the one a search result asked for.
struct SettingsTopicPage: View {
    let route: SettingsRoute
    let tryDemo: (() -> Void)?
    let dismissSettings: () -> Void
    @State private var lit: String?

    var body: some View {
        ScrollViewReader { proxy in
            List { rows }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(DS.page.ignoresSafeArea())
                .environment(\.settingsFocus, lit)
                .task { await show(proxy) }
        }
        .navigationTitle(route.topic.pageTitle)
        .navigationBarTitleDisplayMode(.large)
        .font(DS.body)
        .toolbar {
            // (Your places: move the chips' order, or remove a place)
            ToolbarItem(placement: .primaryAction) { if route.topic == .places { EditButton() } }
        }
    }

    @ViewBuilder private var rows: some View {
        switch route.topic {
        case .trips: TripsSettingsRows()
        case .places: PlacesSettingsRows()
        case .school: SchoolSettingsRows(dismissSettings: dismissSettings)
        case .friends: FriendsSettingsSection()
        case .map: MapSettingsRows()
        case .notifications: NoticesSettingsRows()
        case .battery: BatterySettingsRows()
        case .share: LogShareSection()
        case .advanced: AdvancedSettingsRows(tryDemo: tryDemo, dismissSettings: dismissSettings)
        }
    }

    private func show(_ proxy: ScrollViewProxy) async {
        guard let f = route.focus, lit == nil else { return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        withAnimation(DS.quick) { lit = f; proxy.scrollTo(f, anchor: .center) }
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        withAnimation(.easeOut(duration: 0.6)) { lit = "" }
    }
}

/// A switch with a line under its title.
struct SettingsSwitch: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.body).foregroundStyle(DS.text)
                if let detail {
                    Text(detail).font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(DS.accent)
    }
}

/// A row with a value on the right (for a link: the chevron comes after it).
struct SettingsValueRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(DS.body).foregroundStyle(DS.text)
            Spacer(minLength: DS.s8)
            Text(value).font(DS.body).foregroundStyle(DS.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Trips & alarm

private struct TripsSettingsRows: View {
    @EnvironmentObject var trip: TripManager
    @ObservedObject private var motion = Motion.shared
    @State private var showSteady = false

    var body: some View {
        ride
        alarm
        Section {
            Button { trip.testAlarm() } label: {
                Label("Test the alarm", systemImage: "play.fill").font(DS.bodyStrong).foregroundStyle(DS.accentText)
            }
            .settingsAnchor("alarm.test")
        }
        backup
        wakeBy
        learnWake
        wake
        TravelHelpTripRows()                      // (0.36) student OV, check-out reminder, money back for a late train
        learned
        more
    }

    @ObservedObject private var habits = HabitStore.shared
    @State private var confirmReset = false

    /// 0.34: what it learned from your rides and walks, on this phone only, and a reset.
    @ViewBuilder private var learned: some View {
        Section {
            ForEach(Habits.rows(habits.book), id: \.label) { r in
                HStack(alignment: .firstTextBaseline) {
                    Text(r.label).foregroundStyle(DS.text)
                    Spacer(minLength: DS.s8)
                    Text(r.value).foregroundStyle(DS.secondary).multilineTextAlignment(.trailing)
                }
                .settingsAnchor(r.label == "Walking speed" ? "trips.learned" : "trips.learned.\(r.label)")
            }
            Button("Reset what it learned", role: .destructive) { confirmReset = true }
                .disabled(habits.book.isEmpty && habits.changes.days.isEmpty)
                .confirmationDialog("Forget your walking speed, change time, stops, usual lines and how your changes went?", isPresented: $confirmReset,
                                    titleVisibility: .visible) {
                    Button("Reset", role: .destructive) { habits.reset() }
                }
        } header: { Text("Learned from your rides") } footer: {
            Text("From your own rides and walks, kept on this phone only. Plans use your walking speed for the walks, your change time as the least room a change needs, and give a plan from a stop you prefer a little head start. A change you’ve made 3 times or more says how often it worked. Your usual line at a time of day breaks a tie when two buses or trains fit about as well (never against their own GPS).")
        }
    }

    @ViewBuilder private var ride: some View {
        Section {
            SettingsSwitch(title: "Start trips by itself", detail: "Notices when you leave your stop or station on a bus or train, and starts the alarm. Needs location set to Always.", isOn: $trip.autoStart)
                .settingsAnchor("trips.autoStart")
            if trip.autoStart && !trip.always {
                Button("Allow location Always") { trip.askForAlways() }.foregroundStyle(DS.accentText)
            }
            SettingsSwitch(title: "Station announcement", detail: "A jingle and a voice that names your stop, before the alarm.", isOn: $trip.announce)
                .settingsAnchor("trips.announce")
            SettingsSwitch(title: "Just a notification when I’m on my phone", detail: "If your phone is unlocked and in use when it would ring, you’re awake: one chime instead of the alarm on repeat, still with Stop alarm on the lock screen and in the app. Locked, it rings as usual. (Only with a passcode on your phone.)", isOn: $trip.quietWhenInUse)
                .settingsAnchor("trips.quiet")
            SettingsSwitch(title: "Chime at the stop", detail: "The station jingle, the announcement and a notification when you arrive. No second alarm to stop: the leg ends by itself.", isOn: $trip.ringAtStop)
                .settingsAnchor("trips.chime")
            SettingsSwitch(title: "Switch to Home at school", detail: "When you reach \(RoleWords.current.school), the app switches to going home once that day. Switch back whenever you like.", isOn: $trip.autoHome)
                .settingsAnchor("trips.autoHome")
            if Motion.available {
                SettingsSwitch(title: MotionWords.title, detail: MotionWords.detail, isOn: $motion.on)
                    .settingsAnchor("trips.motion")
                if motion.on && motion.denied {
                    Text(MotionWords.denied).font(DS.footnote).foregroundStyle(DS.secondary)
                }
            }
        } header: { Text("When you ride") }
    }

    @ViewBuilder private var wakeBy: some View {
        Section {
            Picker("Wake me", selection: $trip.wake.by) {
                Text("By time").tag(WakeBy.time)
                Text("By distance").tag(WakeBy.distance)
            }
            .settingsAnchor("wake.by")
            if trip.wake.by == .time {
                Stepper("Train: \(trip.wake.trainMinutes) min", value: $trip.wake.trainMinutes, in: WakeSettings.range)
                    .settingsAnchor("wake.trainMin")
                Stepper("Bus: \(trip.wake.busMinutes) min", value: $trip.wake.busMinutes, in: WakeSettings.range)
                    .settingsAnchor("wake.busMin")
            }
        } header: { Text("Wake me … before my stop") } footer: {
            Text(trip.wake.by == .time
                 ? "It rings this long before your stop, by the bus or train’s live arrival, else by how far it still has to go at your speed. The wake distance below stays as a safety net: whichever comes first."
                 : "It rings at the wake distance below, as before.")
        }
    }

    @ObservedObject private var wakeLearn = AdaptiveWakeStore.shared
    @State private var confirmWakeReset = false

    /// 0.39: the adaptive wake-up: how soon you get up after it rings, learned per bus and train; only ever earlier.
    @ViewBuilder private var learnWake: some View {
        Section {
            SettingsSwitch(title: "Learn when I get up",
                           detail: "Notices how soon you stop the alarm and how much time that leaves before your stop. Short of time again and again? It wakes you a minute earlier (3 at most on a train, 2 on a bus), never later than you set it.",
                           isOn: $wakeLearn.on)
                .settingsAnchor("wake.learn")
            if wakeLearn.on {
                Text(AdaptiveWake.summary(wakeLearn.book, by: trip.wake.by)).font(DS.body).foregroundStyle(DS.secondary)
            }
            Button("Reset what it learned about waking", role: .destructive) { confirmWakeReset = true }
                .disabled(wakeLearn.book.isEmpty)
                .confirmationDialog("Wake you as you set it again, and forget how soon you got up?", isPresented: $confirmWakeReset,
                                    titleVisibility: .visible) {
                    Button("Reset", role: .destructive) { wakeLearn.reset() }
                }
        } footer: {
            Text("Kept on this phone only. The wake distance stays as the safety net, and the alarm always rings.")
        }
    }

    @ViewBuilder private var alarm: some View {
        Section {
            Picker("Alarm sound", selection: $trip.soundKind) {
                ForEach(AlarmSound.Kind.allCases) { k in Text(k.title).tag(k) }
            }
            .onChange(of: trip.soundKind) { _, k in trip.sound.play(preview: k) }
            .settingsAnchor("alarm.sound")
            Text(trip.soundKind.detail).font(DS.footnote).foregroundStyle(DS.secondary)
            SettingsSwitch(title: "Sound only with headphones", detail: "Without Bluetooth, wired or USB headphones, the alarm and the announcer only vibrate (a strong buzz on repeat until you stop it), so the rest of the train doesn’t hear it. It also rings on the lock screen, with Stop alarm.", isOn: $trip.headphonesOnly)
                .settingsAnchor("alarm.headphones")
            if trip.headphonesOnly {
                // (0.42.8) off for everyone: without headphones it never goes out of the speaker unless you say so
                SettingsSwitch(title: "Out loud if I don’t stop it (after 1 min)", detail: "Without headphones: not stopped after a minute, it rings out of the speaker. Off unless you turn it on, so it never wakes the rest of the train.", isOn: $trip.outLoudLater)
                    .settingsAnchor("alarm.loudLater")
            }
            Picker("If music is playing", selection: $trip.pauseMusic) {
                Text("Keep it playing").tag(false)
                Text("Pause it").tag(true)
            }
            .settingsAnchor("alarm.music")
            Text(trip.pauseMusic ? "The loudest option: your music stops while it rings. To start it again, press play on your earbuds."
                                 : "The alarm plays over your music, a little louder than it.")
                .font(DS.footnote).foregroundStyle(DS.secondary)
            // (0.37.1) the phone's notifications on a paired Apple Watch (no watch app: it can't be installed without
            // a paid developer account)
            Label { Text("On an Apple Watch: the wake-up taps your wrist; tap Stop alarm there.") } icon: { Image(systemName: "applewatch") }
                .font(DS.footnote).foregroundStyle(DS.secondary)
                .settingsAnchor("alarm.watch")
        } header: { Text("Alarm") } footer: {
            Text("It also rings in silent mode (with headphones, or out loud when Sound only with headphones is off). Keep the volume up. Every alarm rings on the lock screen too, also while it only vibrates or while you use your phone: stop it there with Stop alarm, on the trip or on the notification.")
        }
    }

    @ViewBuilder private var backup: some View {
        Section {
            Picker("Backup alarm", selection: $trip.backupMinutes) {
                Text("Off").tag(0)
                ForEach([10, 15, 20, 25, 30, 40, 50, 60, 75, 90], id: \.self) { m in Text("After \(m) min").tag(m) }
            }
            .settingsAnchor("alarm.backup")
        } footer: {
            Text("On every leg it also rings after this time, even if GPS drops out. Pick a bit longer than your longest ride.")
        }
    }

    @ViewBuilder private var wake: some View {
        Section {
            Stepper("Bus: \(String(format: "%.1f", trip.busKm)) km", value: $trip.busKm, in: 0.5...10, step: 0.5)
                .settingsAnchor("wake.bus")
            Stepper("Train: \(String(format: "%.1f", trip.trainKm)) km", value: $trip.trainKm, in: 0.5...15, step: 0.5)
                .settingsAnchor("wake.train")
        } header: { Text("Usual wake distance") } footer: {
            Text("Used until you pick a distance for a stop when you start. After that, it remembers your choice.")
        }
    }

    @ViewBuilder private var more: some View {
        Section {
            NavigationLink("Before you nap") { TipsScreenNew() }
                .settingsAnchor("more.tips")
            // (on the corridor it scores its two routes; off it your door-to-door trips between Home and School, 0.24)
            NavigationLink("Leaderboard") { LeaderboardScreenNew() }
                .settingsAnchor("more.leaderboard")
            Button("How steady are they now?") { showSteady = true }
                .foregroundStyle(DS.text)
                .settingsAnchor("more.steady")
                .sheet(isPresented: $showSteady) { SteadySheetNew().presentationDetents([.large]) }
        } header: { Text("More") }
    }
}

// MARK: Your places

private struct PlacesSettingsRows: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var live: LiveStore
    @ObservedObject private var places = PlacesStore.shared
    @ObservedObject private var profile = ProfileStore.shared
    @ObservedObject private var school = SchoolAlarm.shared
    @AppStorage(HomeStyle.key) private var homeStyle = HomeStyle.live.rawValue
    @State private var adding = false
    @State private var liveStops = false

    private var timetable: String {
        switch profile.profile.schedule {
        case .calendars: return school.calendarIds.isEmpty ? "A calendar on this iPhone (none picked)" : "A calendar on this iPhone (\(school.calendarIds.count) picked)"
        case .manual(let w): return "Same times every week: \(SetupLogic.weekWords(w))"
        case .none: return "Not set up"
        }
    }

    private var schoolLine: String { [places.school?.name, profile.profile.campus].compactMap { $0 }.joined(separator: " · ") }
    private var homeLine: String {
        places.home.map { $0.stopIds.isEmpty ? "Its spot on the map" : "\($0.stopIds.count == 1 ? "1 stop" : "\($0.stopIds.count) stops")" } ?? "Not set"
    }

    var body: some View {
        Section {
            SettingsValueRow(title: "School", value: schoolLine.isEmpty ? "Not set" : schoolLine)
                .settingsAnchor("places.now")
            SettingsValueRow(title: "Home", value: homeLine)
            SettingsValueRow(title: "Timetable", value: timetable)
        } header: { Text("Your school and home") } footer: {
            Text("To change these, Set up again in Advanced.")
        }
        Section {
            ForEach(places.list) { p in
                NavigationLink { PlaceEditView(id: p.id) } label: {
                    Label { Text(p.name).foregroundStyle(DS.text) } icon: { Image(systemName: p.symbol.replacingOccurrences(of: ".fill", with: "")).foregroundStyle(DS.secondary) }
                }
                .deleteDisabled(p.kind != .custom)
                .settingsAnchor(p.id == places.list.first?.id ? "places.list" : "places.row.\(p.id)")
            }
            .onMove { from, to in if let f = from.first { places.move(from: f, to: to) } }
            .onDelete { set in for i in set { if let p = places.list[safe: i] { places.remove(p.id) } } }
            Button { adding = true } label: { Label("Add a place", systemImage: "plus") }
                .foregroundStyle(DS.accentText)
                .settingsAnchor("places.add")
                .sheet(isPresented: $adding) {
                    PlaceSearchSheet(title: "Add a place") { hit in places.add(name: Fmt.place(hit.name), lat: hit.lat, lon: hit.lon, stopIds: [hit.id]) }
                }
        } header: { Text("Places") } footer: {
            Text(HomeStyle.of(homeStyle) == .live
                 ? "Your places are the chips under the search field, in this order: tap Edit to move them."
                 : "Home and School are in the bar at the bottom; all your places show when you search. Tap Edit to move them.")
        }
        Section {
            Button("Home bus stops and lines") { liveStops = true }
                .foregroundStyle(DS.text)
                .settingsAnchor("places.stops")
                .sheet(isPresented: $liveStops, onDismiss: { Task { await live.refresh(trip.direction, force: true) } }) {
                    LiveSettingsSheet(newLook: true)
                }
        } footer: {
            Text("The ones the home shows near home and the school alarm plans from.")
        }
    }
}

// MARK: School & mornings

private struct SchoolSettingsRows: View {
    let dismissSettings: () -> Void

    var body: some View {
        SchoolAlarmSection()
        MorningSection(preview: { look in
            dismissSettings()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let look { Morning.shared.tryOut(look) } else { Morning.shared.showing = true }
            }
        })
    }
}

// MARK: Map & home

private struct MapSettingsRows: View {
    @EnvironmentObject var trip: TripManager
    @AppStorage(HomeMapStyle.key) private var styleRaw = HomeMapStyle.standard.rawValue
    @AppStorage(NewLook.vehiclesKey) private var vehicles = true
    @AppStorage(RealPositions.settingKey) private var realPositions = true
    @AppStorage("map.busPosition") private var busPosition = "real"         // (0.40.3) `RealDraw.modeKey`
    @AppStorage(HomeStyle.key) private var homeStyle = HomeStyle.live.rawValue

    var body: some View {
        Section {
            Picker("Home style", selection: $homeStyle) {
                ForEach(HomeStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .settingsAnchor("map.homeStyle")
        } header: { Text("Home") } footer: {
            Text(HomeStyle.of(homeStyle) == .live
                 ? "The map with what leaves from the stops around you, and your day under it."
                 : "Your next trip big, with when to leave and Start, on a dark map. Home, School, Plan and your week at the bottom.")
        }
        Section {
            Picker("Map style", selection: $styleRaw) {
                ForEach(HomeMapStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .settingsAnchor("map.style")
            SettingsSwitch(title: "Live buses and trains", isOn: $vehicles)
                .settingsAnchor("map.vehicles")
        } header: { Text("Map") } footer: {
            Text("Buses and trains move on the map while you look at it, zoomed in to a town or closer. Not in Low Power Mode.")
        }
        Section {
            SettingsSwitch(title: "Real bus and train positions", isOn: $realPositions)
                .settingsAnchor("map.real")
            Picker("Bus position", selection: $busPosition) {
                Text("Real GPS").tag("real")
                Text("Estimated").tag("estimated")
            }
            .disabled(!realPositions)
            .settingsAnchor("map.busPosition")
        } footer: {
            Text("Shows buses and trains where their GPS says they are (open data from OVapi and NS), and uses it to tell which one you’re on. Uses about 10 MB an hour while a map is open or it checks which one you’re on during a ride; off in Low Data Mode and Low Power Mode. Bus position: Real GPS draws the one you wait for where it last said it was, with how old that is, and a faint dot where it’s expected; Estimated mixes its GPS with its times.")
        }
        Section {
            SettingsSwitch(title: "Moving station", detail: "The station and train behind the home and ride screens. It pauses when the screen is off. Off shows a still picture.", isOn: $trip.movingStation)
                .settingsAnchor("map.movingStation")
        }
        TripExtrasSettingsRows()                  // (0.37) rain advice, OV-fiets, the widget and Siri
        NewLookSwitch()
    }
}

// MARK: Notifications

private struct NoticesSettingsRows: View {
    @ObservedObject private var lineWatch = LineWatchStore.shared
    @ObservedObject private var trainWatch = WatchStore.shared
    @State private var showNotices = false

    private var watched: String {
        let n: Int = lineWatch.watches.count + trainWatch.watches.count
        return n == 0 ? "None" : "\(n)"
    }

    var body: some View {
        Section {
            Button { showNotices = true } label: {
                SettingsValueRow(title: "Notifications and what’s watched", value: watched)
            }
            .settingsAnchor("notices.watched")
            .sheet(isPresented: $showNotices) { NotificationsSheetNew().presentationDetents([.medium, .large]) }
        } footer: {
            Text("The buses and trains it watches for you, the way to stop them all, and every notification you had.")
        }
        TravelHelpNoticeRows()                    // (0.36) works on your routes, the last way home
        LockScreenSection()
    }
}

/// Settings' Lock screen rows (either look): the music it shows, connecting Spotify, and the preview.
struct LockScreenSection: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var music: NowPlaying
    @Environment(\.settingsNewLook) private var newLook
    @Environment(\.webAuthenticationSession) private var webAuth
    private var ink: SettingsInk { SettingsInk(newLook: newLook) }
    /// A button in a row: the direction's colour in the old look, the accent in the new.
    private var link: Color { newLook ? DS.accentText : HWPalette.of(home: trip.direction == .home).deep }

    var body: some View {
        Section {
            Picker("Show music from", selection: $music.source) {
                ForEach(MusicSource.allCases) { m in Text(m.title).tag(m) }
            }
            .settingsAnchor("lock.music")
            if music.source == .spotify { spotifyRows }
            if music.source == .appleMusic && !music.appleMusicAllowed {
                Text("Let Haltewekker see Apple Music: iPhone Settings → Apps → Haltewekker → Media & Apple Music.").font(ink.note(12)).foregroundStyle(ink.late)
            }
            if let s = music.song {
                Label("\(s.title)\(s.artist.isEmpty ? "" : " · \(s.artist)")", systemImage: s.playing ? "music.note" : "pause.fill").font(ink.note(13))
            }
            Button("Preview on the lock screen") { music.checkOnce(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { trip.previewActivity() } }
                .foregroundStyle(link).disabled(trip.isRiding)
                .settingsAnchor("lock.preview")
        } header: { Text("Lock screen") } footer: {
            Text("During a trip your lock screen shows a little train screen: how far to go, a metro that drives along as you get closer, your arrival time and the song you’re playing. The preview runs for about a minute: lock your phone to see it.")
        }
    }

    @ViewBuilder private var spotifyRows: some View {
        if music.spotifyConnected {
            Label("Spotify is connected", systemImage: "checkmark.circle.fill").foregroundStyle(ink.ok)
                .settingsAnchor("lock.spotify")
            Button("Check what’s playing") { music.checkOnce() }.foregroundStyle(link)
            Button("Disconnect Spotify", role: .destructive) { music.disconnectSpotify() }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spotify only tells apps what’s playing if you make a (free) Spotify app for it. Once, on developer.spotify.com with your Premium account:")
                Text("1. Dashboard → Create app. Tick “Web API”.\n2. Redirect URI: the link below.\n3. Settings → User Management: add your own name and Spotify email.\n4. Copy the Client ID and paste it here.")
            }
            .font(ink.note(12)).foregroundStyle(ink.muted)
            Button { UIPasteboard.general.string = NowPlaying.redirect } label: { Label("Copy the redirect link", systemImage: "doc.on.doc") }
                .foregroundStyle(link)
            Text(NowPlaying.redirect).font(ink.note(11)).foregroundStyle(ink.muted).textSelection(.enabled)
            HStack {
                TextField("Client ID", text: $music.clientId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(ink.note(13))
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in music.clientId = (strings.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.iconOnly).buttonBorderShape(.capsule)
            }
            Button(music.busy ? "Connecting…" : "Connect Spotify") { Task { await connectSpotify() } }
                .foregroundStyle(link)
                .disabled(music.clientId.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 || music.busy)
                .settingsAnchor("lock.spotify")
        }
        if let e = music.spotifyError { Text(e).font(ink.note(12)).foregroundStyle(ink.late) }
    }

    private func connectSpotify() async {
        guard let url = music.spotifySignInURL() else { return }
        do {
            let back = try await webAuth.authenticate(using: url, callbackURLScheme: "haltewekker", preferredBrowserSession: .shared)
            await music.finish(back)
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { music.report("Couldn’t sign in: \(error.localizedDescription)") }
        }
    }
}

// MARK: Battery & data

private struct BatterySettingsRows: View {
    @AppStorage(RideGPS.settingKey) private var longRides = true

    var body: some View {
        Section {
            NavigationLink { BatteryDataScreen() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Battery and data use").font(DS.body).foregroundStyle(DS.text)
                    Text("What the app used today: GPS, network, mobile data and the last rides.").font(DS.footnote).foregroundStyle(DS.secondary)
                }
            }
            .settingsAnchor("battery.use")
        }
        Section {
            SettingsSwitch(title: "Save battery on long rides", isOn: $longRides)
                .settingsAnchor("battery.longRides")
        } footer: {
            Text("Uses less precise GPS far from your stop; switches back well before it wakes you.")
        }
    }
}

// MARK: Advanced

private struct AdvancedSettingsRows: View {
    let tryDemo: (() -> Void)?
    let dismissSettings: () -> Void
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var planner: Planner
    @ObservedObject private var setup = SetupStore.shared
    @State private var confirmBack = false
    @State private var confirmReset = false
    @State private var froze = !Watchdog.freezes.isEmpty
    private var idle: Bool { trip.phase == .idle }

    var body: some View {
        if let tryDemo, idle {
            Section {
                Button { dismissSettings(); tryDemo() } label: {
                    Label("Try it at home: a pretend trip", systemImage: "play.circle").foregroundStyle(DS.accentText)
                }
                .settingsAnchor("adv.demo")
            } footer: { Text("Fastest trip with the map and notifications, being recognised on the bus, the ride ring, the alarm and arriving, all pretend.") }
        }
        // (0.35) Your year in travel
        Section {
            NavigationLink { TravelYearScreen() } label: {
                Label("Your year in travel", systemImage: "sparkles")
            }
            .settingsAnchor("adv.year")
        } footer: { Text("Hours on buses and trains, kilometres, CO₂ saved against driving, favourites and more, worked out on this phone from your rides.") }
        FieldLogSection()
        if froze {
            FreezeSection()
        } else {
            Section {
                SettingsValueRow(title: "When the app froze", value: "Not once")
                    .settingsAnchor("adv.freeze")
            } footer: { Text("If the app stops responding for more than a few seconds, it notes what it was doing and where, here.") }
        }
        setupRows
        Section {
            Button("Reset everything", role: .destructive) { confirmReset = true }
                .settingsAnchor("adv.reset")
                .confirmationDialog("Reset everything?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset everything", role: .destructive) { trip.resetAll(); planner.clear(); NewLook.resetAll() }
                } message: { Text("Your settings, learned speed ratings, leaderboard, watched trains, stops and Spotify sign-in are removed.") }
        } footer: { Text("Your settings, learned speed ratings, leaderboard, watched trains, stops and Spotify sign-in are removed.") }
        about
    }

    @ViewBuilder private var setupRows: some View {
        if setup.testLive {
            Section {
                Button("Back to my own") { confirmBack = true }.foregroundStyle(DS.accentText).disabled(!idle)
                    .settingsAnchor("adv.backToMine")
                    .confirmationDialog("Back to your own setup?", isPresented: $confirmBack, titleVisibility: .visible) {
                        Button("Back to my own") { setup.backToMine(tripIdle: idle) }
                        Button("Keep testing", role: .cancel) {}
                    } message: { Text("The test setup goes; your own comes back exactly as it was.") }
            } header: { Text("Test setup") } footer: {
                Text(idle ? "You’re using the test setup. This puts your own school, home, stops, timetable and school alarm back, exactly as they were before the test."
                          : "Not while a trip is running: end the trip first.")
            }
        }
        Section {
            Button("Set up again") { dismissSettings(); setup.setUpAgain() }.foregroundStyle(DS.accentText).disabled(!idle)
                .settingsAnchor("adv.setupAgain")
            if !setup.testLive {
                Button("Test the setup as a new user") { dismissSettings(); setup.startTest(tripIdle: idle) }
                    .foregroundStyle(DS.accentText).disabled(!idle)
                    .settingsAnchor("adv.testSetup")
            }
        } header: { Text("Setup") } footer: {
            Text(!idle ? "Not while a trip is running: end the trip first."
                 : setup.testLive ? "The setup with what you have now filled in. Nothing changes until you tap Done at the end."
                 : "Set up again: the setup with what you have now filled in; nothing changes until you tap Done. Test: the first-run setup as a new student sees it, with empty fields. Your own setup is saved first, and “Back to my own” (on the home, and here) puts it back exactly.")
        }
    }

    private var about: some View {
        Section {
            SettingsValueRow(title: "Haltewekker", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                .settingsAnchor("adv.about")
        } header: { Text("About") } footer: {
            Text("Open data: trips by Transitous (© OpenStreetMap contributors and open transit data), bus positions by OVapi, trains by NS, weather by Open-Meteo, NS station list by Rijden de Treinen (CC BY 4.0).")
        }
    }
}
