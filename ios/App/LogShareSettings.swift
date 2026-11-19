import SwiftUI

/// Settings › Help improve Haltewekker (0.28.1): "Share ride logs", off unless you turn it on; what it sends, shown
/// with a line of your own as it would go; and "Delete what I sent".
struct LogShareSection: View {
    @Environment(\.settingsNewLook) private var newLook
    private var ink: SettingsInk { SettingsInk(newLook: newLook) }
    @ObservedObject private var store = LogShareStore.shared
    @State private var confirmDelete = false

    private var share: Binding<Bool> {
        Binding(get: { store.on }, set: { store.setOn($0) })
    }

    var body: some View {
        Section {
            Toggle("Share ride logs", isOn: share)
            NavigationLink("What’s sent") { LogShareDetails() }
            if store.state != nil {
                Button(store.busy ? "Deleting…" : "Delete what I sent", role: .destructive) { confirmDelete = true }
                    .disabled(store.busy)
                    .confirmationDialog("Delete the ride logs this phone sent?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete what I sent", role: .destructive) { Task { await store.deleteSent() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Everything this phone sent is deleted from the server now. Sharing stays as it is; what comes later goes under a new random id.")
                    }
            }
            if let note = store.note {
                Text(note).font(ink.note(12)).foregroundStyle(ink.muted)
            }
        } header: { Text("Help improve Haltewekker") } footer: {
            Text("Off unless you turn it on. After each trip it sends the lines about how the app picked your bus or train and how the ride went: line numbers, distances in metres, how old a GPS fix was, what it decided. Never where you are, your places’ names, your friends or your account. Not in Low Data Mode; kept 60 days.")
        }
    }
}

/// What "Share ride logs" sends, in full, with a line from your own log as it would go.
struct LogShareDetails: View {
    @Environment(\.settingsNewLook) private var newLook
    private var ink: SettingsInk { SettingsInk(newLook: newLook) }
    @ObservedObject private var store = LogShareStore.shared
    @State private var example = LogShareRules.sample

    private var mono: Font { newLook ? Font.system(.caption, design: .monospaced) : Font.system(size: 11, design: .monospaced) }

    var body: some View {
        List {
            Section {
                Text(example)
                    .font(mono)
                    .foregroundStyle(ink.ink)
                    .textSelection(.enabled)
                    .accessibilityLabel("Example line: \(example)")
            } header: { Text("A line as it’s sent") } footer: {
                Text("The newest ride line on this phone, as it would leave it. Your Home and School are only ever called “Home” and “School”.")
            }
            Section {
                point("What", "The matching and ride lines of Settings › Connection and matching log: the time, the bus or train line and the last 4 characters of its trip, distances rounded to 10 m, how old fixes were, how sure the app was and what it chose.")
                point("Not sent", "Coordinates, addresses, the names of your places (Home and School become “Home” and “School”), friends’ names, account ids and the requests the app makes. Public stop and station names may stay.")
                point("Grouped by", "A random id made on this phone for this only: not your Friends account, not your phone’s name.")
                point("When", "After each trip ends, and at most once an hour otherwise. Never during a trip, in Low Data Mode or in Low Power Mode. At most 200 KB at a time and 2 MB a day.")
                point("Kept", "60 days, then deleted. Only the developer can read them, to make the app pick the right bus or train more often.")
            } footer: {
                Text("“Delete what I sent” deletes everything this phone sent, at once. Only this phone can: it holds the key.")
            }
        }
        .navigationTitle("What’s sent")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { example = store.example() }
    }

    private func point(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(ink.strong(13)).foregroundStyle(ink.ink)
            Text(text).font(ink.note(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
