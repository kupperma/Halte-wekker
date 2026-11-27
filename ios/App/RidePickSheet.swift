import SwiftUI

/// "I'm actually on…" (0.20.5): during a ride, the buses and trains that could be yours right now (`RidePick`), nearest
/// and moving with you first, the one it thinks it is checked. Tap the one you're on: the ride takes it (asking first
/// when it doesn't go to this leg's stop) and keeps it for the rest of the leg. Or none of these: it goes by your
/// location. Pull to refresh; it also refreshes every 10 s while open.
struct RidePickSheet: View {
    @EnvironmentObject var trip: TripManager
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [RidePick.Row] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var updated: Date?
    @State private var checking: String?               // the row tapped, while it looks at what picking it does
    @State private var confirm: TripManager.HandPick?
    @State private var note: String?

    private var riding: Bool { trip.phase == .sleeping || trip.phase == .awake }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s12) {
                    Text("Tap the one you’re on. It stays with that one for the rest of this leg, and wakes you for its stop.")
                        .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    if let note { DSNote(icon: "exclamationmark.triangle.fill", text: note) }
                    VStack(alignment: .leading, spacing: 0) {
                        if !loaded {
                            ForEach(0..<3, id: \.self) { _ in DSSkeletonRow() }
                        } else if rows.isEmpty {
                            Text("No buses or trains near you just now. Pull down to look again.")
                                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, DS.s12)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { k, r in
                            if k > 0 { Divider().overlay(DS.divider) }
                            row(r)
                        }
                    }
                    .dsPanel(padding: DS.s12)
                    if trip.leg != nil { noneRow.dsPanel(padding: DS.s12) }
                    if let u = updated {
                        Text("Updated at \(Fmt.hhmm(u)) · every 10 s").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                    }
                }
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s12)
            }
            .refreshable { await load() }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("I’m actually on…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundStyle(DS.accentText) }
                ToolbarItem(placement: .topBarTrailing) { if loading { ProgressView().controlSize(.small) } }
            }
            .alert(confirm.map { "Switch to the \($0.vehicle.title)?" } ?? "",
                   isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { p in
                Button("Switch") { Task { await trip.applyHandPick(p); dismiss() } }
                Button("Cancel", role: .cancel) { confirm = nil }
            } message: { p in
                Text(p.warning ?? "")
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        .onChange(of: riding) { _, r in if !r { dismiss() } }      // the stop, the alarm, the end: the sheet goes
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        let got = await trip.handPickChoices()
        loading = false
        rows = got; loaded = true; updated = Date()
    }

    private func row(_ r: RidePick.Row) -> some View {
        let title = RidePick.title(line: r.line, isTrain: r.isTrain, headsign: r.headsign)
        let detail = RidePick.detail(metres: r.metres, byGPS: r.byGPS)
        return Button { pick(r) } label: {
            HStack(spacing: DS.s12) {
                DSLinePill(line: r.line, train: r.isTrain, mode: r.mode).frame(width: 46, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                    if r.moves { Text("Moves with you").font(DS.footnoteStrong).foregroundStyle(DS.accentText) }
                }
                Spacer(minLength: 4)
                if checking == r.tripId {
                    ProgressView()
                } else if r.current {
                    Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(DS.accentText)
                }
            }
            .padding(.vertical, DS.s8)
            .frame(minHeight: DS.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(checking != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)\(r.moves ? ", moves with you" : "")\(r.current ? ", the one it thinks you’re on" : "")")
        .accessibilityHint("Tap if you’re on this one")
        .accessibilityAddTraits(r.current ? [.isButton, .isSelected] : [.isButton])
    }

    private var noneRow: some View {
        let chosen = trip.handLock != nil && trip.handLock?.tripId == nil
        return Button { trip.noneOfThese(); dismiss() } label: {
            HStack(spacing: DS.s12) {
                Image(systemName: "location.fill").font(.body.weight(.semibold)).foregroundStyle(DS.accentText).frame(width: 46, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("None of these: just use my location").font(DS.bodyStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    Text("The trip and the alarm go on by your GPS, without a bus or train.").font(DS.footnote).foregroundStyle(DS.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if chosen { Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(DS.accentText) }
            }
            .frame(minHeight: DS.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(checking != nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : [.isButton])
    }

    /// What picking it does first (its stops, the rest planned again from it); asked first when it doesn't go to this
    /// leg's stop.
    private func pick(_ r: RidePick.Row) {
        guard checking == nil else { return }
        checking = r.tripId; note = nil
        Task {
            let p = await trip.previewHandPick(r)
            checking = nil
            guard let p else { note = "The ride moved on meanwhile. Try again."; return }
            if p.warning != nil { confirm = p } else { await trip.applyHandPick(p); dismiss() }
        }
    }
}

/// "Not this one?" on the ride screen (0.20.5), next to the bus or train it says you're on: opens the "I'm actually on…"
/// sheet. "Which one are you on?" while it's still unsure or has none yet. 44 pt to tap.
struct RidePickButton: View {
    @EnvironmentObject var trip: TripManager
    let action: () -> Void

    /// Unsure (choosing between some) or none yet.
    private var asking: Bool { trip.vehicle == nil || trip.choosing.count > 1 }

    var body: some View {
        Button(action: action) {
            Text(asking ? "Which one are you on?" : "Not this one?")
                .font(DS.subStrong).foregroundStyle(DS.accentText)
                .frame(minWidth: DS.hit, minHeight: DS.hit, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asking ? "Pick the bus or train you’re on" : "I’m on a different bus or train")
    }
}

/// "Still on bus 306?" (0.20.5): the one you picked has been off its road for 3 minutes. Yes, or pick again.
/// 0.34: two trains on the same track still tied after 2 minutes, going different ways: which one are you on?
/// 0.38: buses too ("305 or 306?"), and a minute after you left the stop (`AskSooner`).
struct WhichTrainCard: View {
    @EnvironmentObject var trip: TripManager
    let trains: [Vehicle]
    let to: [String: String]
    var body: some View {
        let a = trains[0], b = trains[1]
        let train: Bool = a.isTrain
        let same: Bool = a.line.lowercased() == b.line.lowercased()
        let title: String = AskSooner.title((a.line, to[a.tripId] ?? ""), (b.line, to[b.tripId] ?? ""), train: train)
        VStack(alignment: .leading, spacing: DS.s12) {
            Label(title, systemImage: "questionmark.circle.fill")
                .font(DS.headline).foregroundStyle(DS.text)
            Text(AskSooner.body(train: train))
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.s8) {
                ForEach(trains, id: \.tripId) { v in
                    DSQuietButton(title: AskSooner.answer(line: v.line, to: to[v.tripId] ?? "", train: train, sameLine: same), full: true) {
                        Task { await trip.answerWhichTrain(v.tripId) }
                    }
                }
            }
        }
        .dsPanel()
    }
}

struct StillOnCard: View {
    @EnvironmentObject var trip: TripManager
    let v: Vehicle
    var body: some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            Label(RidePick.stillOn(line: v.line, isTrain: v.isTrain), systemImage: "questionmark.circle.fill")
                .font(DS.headline).foregroundStyle(DS.text)
            Text("Your GPS has been off its route for a few minutes.").font(DS.sub).foregroundStyle(DS.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.s8) {
                DSQuietButton(title: "Yes", full: true) { trip.answerStillOn(yes: true) }
                DSQuietButton(title: "Pick again", full: true) { trip.answerStillOn(yes: false) }
            }
        }
        .dsPanel()
    }
}

/// (0.42.9) A later stop of the one you're on gets you there sooner (`BetterStop`): "Do this" or "Keep my plan".
struct BetterStopCard: View {
    @EnvironmentObject var trip: TripManager
    let offer: TripManager.BetterOffer
    var body: some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            Label("A faster way: stay on", systemImage: "arrow.triangle.branch")
                .font(DS.headline).foregroundStyle(DS.text)
            Text(offer.text).font(DS.sub).foregroundStyle(DS.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.s8) {
                DSQuietButton(title: "Do this", full: true) { trip.takeBetterStop() }
                DSQuietButton(title: "Keep my plan", full: true) { trip.keepPlanNotBetterStop() }
            }
        }
        .dsPanel()
    }
}
