import SwiftUI

/// Settings › Help improve Haltewekker (0.28.1; GPS points since 0.32): "Share ride logs" and "Share GPS points during
/// rides", both off unless you turn them on; what they send, shown with a line of your own as it would go; and "Delete
/// what I sent".
struct LogShareSection: View {
    @Environment(\.settingsNewLook) private var newLook
    private var ink: SettingsInk { SettingsInk(newLook: newLook) }
    @ObservedObject private var store = LogShareStore.shared
    @State private var confirmDelete = false

    private var share: Binding<Bool> {
        Binding(get: { store.on }, set: { store.setOn($0); store.markAsked() })
    }

    private var fixes: Binding<Bool> {
        Binding(get: { store.fixesOn }, set: { store.setFixesOn($0); store.markAsked() })
    }

    var body: some View {
        Section {
            Toggle(ShareAsk.logsTitle, isOn: share)
            Toggle(ShareAsk.fixesTitle, isOn: fixes)
            NavigationLink("What’s sent") { LogShareDetails() }
            if store.state != nil {
                Button(store.busy ? "Deleting…" : "Delete what I sent", role: .destructive) { confirmDelete = true }
                    .disabled(store.busy)
                    .confirmationDialog("Delete the ride logs and GPS points this phone sent?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete what I sent", role: .destructive) { Task { await store.deleteSent() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Everything this phone sent to \(Maker.name) is deleted from the server now. Sharing stays as it is; what comes later goes under a new random id.")
                    }
            }
            if let note = store.note {
                Text(note).font(ink.note(12)).foregroundStyle(ink.muted)
            }
        } header: { Text("Help improve Haltewekker") } footer: {
            Text("Made by \(Maker.name), who gets what you share here, to make the app pick the right bus or train more often. Both off unless you turn them on. Ride logs: how the app picked your bus or train, never where you are, your places’ names, your friends or your account. GPS points: only during trips, without the first and last 500 m of each trip or anything near your places. Not in Low Data Mode; kept 60 days.")
        }
    }
}

/// What "Share ride logs" and "Share GPS points during rides" send, in full, with a line from your own log as it would go.
struct LogShareDetails: View {
    @Environment(\.settingsNewLook) private var newLook
    private var ink: SettingsInk { SettingsInk(newLook: newLook) }
    @ObservedObject private var store = LogShareStore.shared
    @State private var example = LogShareRules.sample

    private var mono: Font { newLook ? Font.system(.caption, design: .monospaced) : Font.system(size: 11, design: .monospaced) }

    var body: some View {
        List {
            Section {
                Text(ShareAsk.intro).font(ink.note(13)).foregroundStyle(ink.ink).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text(example)
                    .font(mono)
                    .foregroundStyle(ink.ink)
                    .textSelection(.enabled)
                    .accessibilityLabel("Example line: \(example)")
            } header: { Text("Ride logs: a line as it’s sent") } footer: {
                Text("The newest ride line on this phone, as it would leave it. Your Home and School are only ever called “Home” and “School”.")
            }
            Section {
                point("What", "The matching and ride lines of Settings › Connection and matching log: the time, the bus or train line and the last 4 characters of its trip, distances rounded to 10 m, how old fixes were, how sure the app was and what it chose.")
                point("Not sent", "Coordinates, addresses, the names of your places (Home and School become “Home” and “School”), friends’ names, account ids and the requests the app makes. Public stop and station names may stay.")
            } header: { Text(ShareAsk.logsTitle) }
            Section {
                Text(ShareAsk.sampleFix)
                    .font(mono)
                    .foregroundStyle(ink.ink)
                    .textSelection(.enabled)
                    .accessibilityLabel("Example GPS point: \(ShareAsk.sampleFix)")
                point("What", "Only while a trip runs, a point every \(Int(GPSShareRules.every)) seconds: the time, where the phone was (5 decimals, about a metre), how accurate that was, your speed and direction, the leg (“1/3”) and the bus or train it was on as the ride lines name it, and a random id for the trip.")
                point("Left out", "The first and the last 500 m of every trip, and everything within 500 m of Home, School or another place you saved. Nothing outside trips, nothing from the pretend trip.")
                if store.fixesOn {
                    point("Waiting", store.fixesWaiting == 0 ? "No points waiting to go." : "\(store.fixesWaiting) points of trips that ended, to go with the next upload.")
                }
            } header: { Text(ShareAsk.fixesTitle) } footer: {
                Text("Turning it off deletes the points not sent yet from this phone.")
            }
            Section {
                point("Who gets it", "\(Maker.name), who makes Haltewekker, to make the app pick the right bus or train more often. Nobody else.")
                point("Grouped by", "A random id made on this phone for this only: not your Friends account, not your phone’s name.")
                point("When", "After each trip ends, and at most once an hour otherwise. Never during a trip, in Low Data Mode or in Low Power Mode. At most 200 KB of lines and 600 KB of points at a time, 2 MB and 4 MB a day.")
                point("Kept", "60 days, then deleted.")
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

/// On the home, once (0.32), for someone whose setup was done before the setup asked: "Help improve Haltewekker?",
/// with the same two switches in a sheet. "Not now" puts it away for good (Settings › Help improve Haltewekker has them).
struct ShareAskCard: View {
    @ObservedObject private var store = LogShareStore.shared
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            HStack(alignment: .top, spacing: DS.s12) {
                Image(systemName: "hand.raised.fill").font(.subheadline.weight(.semibold)).foregroundStyle(DS.accentSoftText)
                    .frame(width: 32, height: 32).background(DS.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Help improve Haltewekker?").font(DS.calloutStrong).foregroundStyle(DS.text)
                    Text("Share your rides with \(Maker.name), who makes the app, so it picks the right bus or train more often. Optional, off unless you turn it on.")
                        .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: DS.s8) {
                DSQuietButton(title: "Not now", full: true) { withAnimation(DS.quick) { store.markAsked() } }
                    .accessibilityHint("Puts this away. Settings › Help improve Haltewekker has the same switches.")
                DSQuietButton(title: "Choose…", icon: "slider.horizontal.3", full: true) { choosing = true }
            }
        }
        .padding(DS.s12)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
        .padding(.horizontal, DS.s12).padding(.top, DS.s4).padding(.bottom, DS.s8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $choosing) { ShareAskSheet() }
    }
}

/// The card's sheet: the setup's step on its own.
struct ShareAskSheet: View {
    @ObservedObject private var store = LogShareStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var logs = false
    @State private var fixes = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    Text(ShareAsk.intro).font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: DS.s12) {
                        ShareSwitch(title: ShareAsk.logsTitle, text: ShareAsk.logsText, isOn: $logs)
                        Divider()
                        ShareSwitch(title: ShareAsk.fixesTitle, text: ShareAsk.fixesText, isOn: $fixes)
                    }
                    .dsPanel()
                    DSNote(icon: "hand.raised.fill", tint: DS.accentText, text: ShareAsk.who)
                }
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s8)
            }
            .background(DS.page.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                DSPrimaryButton(title: "Done") {
                    store.answer(logs: logs, fixes: fixes)
                    dismiss()
                }
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s8)
                .background(DS.page.opacity(0.96).ignoresSafeArea(edges: .bottom))
            }
            .navigationTitle("Help improve Haltewekker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onAppear { logs = store.on; fixes = store.fixesOn }
    }
}
