import MapKit
import SwiftUI

// "Where to?" for Fastest trip in the new look (0.21). The same as
// `DestinationSheet` (the old look keeps that one), in the phone’s light or dark.

/// Fastest trip › Change: where to, by name, or one you went to before.
struct DestinationSheetNew: View {
    @EnvironmentObject var live: LiveStore
    @Environment(\.dismiss) private var dismiss
    let picked: (Destination) -> Void
    @State private var q = ""
    @State private var hits: [Transit.StopHit] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                if q.trimmingCharacters(in: .whitespaces).count >= 2 {
                    if !hits.isEmpty {
                        Section("Stops and stations") {
                            ForEach(hits) { h in
                                row(icon: "mappin.and.ellipse", title: h.name, sub: h.town.isEmpty ? nil : h.town) {
                                    pick(Destination(id: h.id, name: h.name, lat: h.lat, lon: h.lon))
                                }
                            }
                        }
                    } else if searching {
                        HStack(spacing: DS.s8) { ProgressView(); Text("Searching…").foregroundStyle(DS.secondary) }
                    } else {
                        Text("No stops or stations found for “\(q)”").foregroundStyle(DS.secondary)
                    }
                }
                if !live.recents.isEmpty {
                    Section("Recent") {
                        ForEach(live.recents) { d in
                            row(icon: "clock.arrow.circlepath", title: d.name, sub: nil) { pick(d) }
                        }
                    }
                }
            }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "A stop, station or town")
            .textInputAutocapitalization(.words).autocorrectionDisabled()
            .navigationTitle("Where to?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: q) {
                let t = q.trimmingCharacters(in: .whitespaces)
                guard t.count >= 2 else { hits = []; searching = false; return }
                searching = true
                try? await Task.sleep(nanoseconds: 350_000_000)             // wait until you stop typing
                guard !Task.isCancelled else { return }
                let r = await Transit.findStops(t)
                guard !Task.isCancelled else { return }
                hits = r; searching = false
            }
        }
        .tint(DS.accentText)
    }

    private func pick(_ d: Destination) { picked(d); dismiss() }

    private func row(icon: String, title: String, sub: String?, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: DS.s12) {
                Image(systemName: icon).foregroundStyle(DS.accentText).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.bodyStrong).foregroundStyle(DS.text)
                    if let sub { Text(sub).font(DS.footnote).foregroundStyle(DS.secondary) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: DS.hit).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
