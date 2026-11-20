import SwiftUI

/// The "New look" switch, in both looks' Settings: only on the Veghel ⇄ BUas corridor (the station look is drawn for
/// it; off it the new look is all there is).
struct NewLookSwitch: View {
    @AppStorage(NewLook.key) private var newLook = true
    @ObservedObject private var profile = ProfileStore.shared
    var body: some View {
        if profile.profile.corridor != nil {
            Section {
                Toggle("New look", isOn: $newLook)
                    .settingsAnchor("map.newLook")
            } footer: {
                Text("The map-first home with your day and Plan a trip, and the trip screens with it: Fastest trip, the ride, the alarm and the change. Off brings back the station look of 0.18 for now.")
            }
        }
    }
}

/// Settings › Your places › a place: rename it, change its stop, or remove it (Home and School stay).
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
