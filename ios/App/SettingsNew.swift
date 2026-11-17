import SwiftUI

/// Settings that came with the new look (0.19): the map, your places, notifications and what left the home screen
/// (leaderboard, how steady the lines are, trying it at home, tips). Shown at the top of Settings in the new look.
struct NewLookSettings: View {
    let tryDemo: (() -> Void)?
    let dismissSettings: () -> Void
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var live: LiveStore
    @AppStorage(HomeMapStyle.key) private var styleRaw = HomeMapStyle.standard.rawValue
    @AppStorage(NewLook.vehiclesKey) private var vehicles = true
    @AppStorage(RealPositions.settingKey) private var realPositions = true
    @AppStorage(HomeStyle.key) private var homeStyle = HomeStyle.live.rawValue
    @AppStorage(RideGPS.settingKey) private var longRides = true
    @State private var showNotices = false
    @State private var showSteady = false
    @State private var liveStops = false

    var body: some View {
        Section {
            Picker("Home style", selection: $homeStyle) {
                ForEach(HomeStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
        } header: { Text("Home") } footer: {
            Text(HomeStyle.of(homeStyle) == .live
                 ? "The map with what leaves from the stops around you, and your day under it."
                 : "Your next trip big, with when to leave and Start, on a dark map. Home, School, Plan and your week at the bottom.")
        }
        Section {
            Picker("Style", selection: $styleRaw) {
                ForEach(HomeMapStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Live buses and trains", isOn: $vehicles)
        } header: { Text("Map") } footer: {
            Text("Buses and trains move on the map while you look at it, zoomed in to a town or closer. Not in Low Power Mode.")
        }
        Section {
            Toggle("Real bus and train positions", isOn: $realPositions)
        } footer: {
            Text("Shows buses and trains where their GPS says they are (open data from OVapi and NS), and uses it to tell which one you’re on. Uses about 10 MB an hour while a map is open or it checks which one you’re on during a ride; off in Low Data Mode and Low Power Mode.")
        }
        Section {
            NavigationLink("Your places") { PlacesSettingsView() }
            Button("Home bus stops and lines") { liveStops = true }
                .sheet(isPresented: $liveStops, onDismiss: { Task { await live.refresh(trip.direction, force: true) } }) { LiveSettingsSheet(newLook: true) }
        } header: { Text("Places") } footer: {
            Text((HomeStyle.of(homeStyle) == .live
                  ? "Your places are the chips under the search field."
                  : "Home and School are in the bar at the bottom; all your places show when you search.")
                 + " The bus stops and lines are the ones the home shows near home and the school alarm plans from.")
        }
        Section {
            NavigationLink("Battery & data") { BatteryDataScreen() }
            Toggle("Save battery on long rides", isOn: $longRides)
        } header: { Text("Battery") } footer: {
            Text("Uses less precise GPS far from your stop; switches back well before it wakes you.")
        }
        Section("Notifications") {
            Button("Notifications and what’s watched") { showNotices = true }
                .sheet(isPresented: $showNotices) { NotificationsSheetNew().presentationDetents([.medium, .large]) }
        }
        Section("More") {
            NavigationLink("Leaderboard") { LeaderboardScreenNew() }
            Button("How steady are they now?") { showSteady = true }
                .sheet(isPresented: $showSteady) { SteadySheetNew().presentationDetents([.large]) }
            if let tryDemo, trip.phase == .idle {
                Button("Try it at home: a pretend trip") { dismissSettings(); tryDemo() }
            }
            NavigationLink("Before you nap") { TipsScreenNew() }
        }
    }
}

/// The "New look" switch, in both looks' Settings.
struct NewLookSwitch: View {
    @AppStorage(NewLook.key) private var newLook = true
    var body: some View {
        Section {
            Toggle("New look", isOn: $newLook)
        } footer: {
            Text("The map-first home with your day and Plan a trip, and the trip screens with it: Fastest trip, the ride, the alarm and the change. Off brings back the station look of 0.18 for now.")
        }
    }
}

/// Settings › Your places: rename, move, change or remove them, or add one. Home and School stay (they can be changed).
struct PlacesSettingsView: View {
    @ObservedObject private var places = PlacesStore.shared
    @State private var adding = false
    var body: some View {
        List {
            Section {
                ForEach(places.list) { p in
                    NavigationLink { PlaceEditView(id: p.id) } label: {
                        Label(p.name, systemImage: p.symbol)
                    }
                    .deleteDisabled(p.kind != .custom)
                }
                .onMove { from, to in if let f = from.first { places.move(from: f, to: to) } }
                .onDelete { set in for i in set { if let p = places.list[safe: i] { places.remove(p.id) } } }
            } footer: { Text("The chips under the search field show them in this order: tap Edit to move them. Your trip direction and the school alarm still use today’s home and school.") }
            Section { Button("Add a place") { adding = true } }
        }
        .navigationTitle("Your places")
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) {
            PlaceSearchSheet(title: "Add a place") { hit in places.add(name: Fmt.place(hit.name), lat: hit.lat, lon: hit.lon, stopIds: [hit.id]) }
        }
    }
}

struct PlaceEditView: View {
    let id: String
    @ObservedObject private var places = PlacesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var changing = false
    private var place: SavedPlace? { places.list.first { $0.id == id } }
    var body: some View {
        Form {
            if let p = place {
                Section("Name") {
                    TextField("Name", text: $name)
                        .onSubmit { save(p) }
                }
                Section {
                    Button("Change the stop or station") { changing = true }
                } footer: { Text(p.stopIds.isEmpty ? "Planned to its spot on the map." : "Planned to \(p.stopIds.count == 1 ? "its stop" : "its \(p.stopIds.count) stops").") }
                if p.kind == .custom {
                    Section { Button("Remove this place", role: .destructive) { places.remove(p.id); dismiss() } }
                }
            }
        }
        .navigationTitle(place?.name ?? "Place")
        .onAppear { name = place?.name ?? "" }
        .onDisappear { if let p = place { save(p) } }
        .sheet(isPresented: $changing) {
            PlaceSearchSheet(title: "Change \(place?.name ?? "place")") { hit in
                guard var p = place else { return }
                p.lat = hit.lat; p.lon = hit.lon; p.stopIds = [hit.id]
                places.update(p)
            }
        }
    }
    private func save(_ p: SavedPlace) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != p.name else { return }
        var q = p; q.name = n
        places.update(q)
    }
}

// MARK: Settings' own rows in either look

private struct SettingsNewLookKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Settings is open in the new look (0.21): the rows it shares with the old look (the school alarm, the morning
    /// screen, the freeze and matching logs) take the new tokens, through `SettingsInk`.
    var settingsNewLook: Bool {
        get { self[SettingsNewLookKey.self] }
        set { self[SettingsNewLookKey.self] = newValue }
    }
}

/// The colours and text of Settings' rows: the paper's in the old look, the new tokens (light or dark) in the new.
struct SettingsInk {
    let newLook: Bool
    var ink: Color { newLook ? DS.text : Paper.ink }
    var muted: Color { newLook ? DS.secondary : Paper.muted }
    /// A button or link in a row.
    var link: Color { newLook ? DS.accentText : Paper.navy }
    var late: Color { newLook ? DS.warning : Paper.late }
    var ok: Color { newLook ? DS.accentText : Paper.ok }
    /// A row's small note (the old look's size in points).
    func note(_ size: CGFloat = 12) -> Font { newLook ? DS.footnote : HWFont.body(size) }
    /// A row's bold line.
    func strong(_ size: CGFloat = 13) -> Font { newLook ? DS.subStrong : HWFont.body(size, bold: true) }
    /// A small label, as on a tile.
    func caption(_ size: CGFloat, bold: Bool = false) -> Font {
        newLook ? (bold ? DS.footnoteStrong : DS.footnote) : HWFont.body(size, bold: bold)
    }
}
