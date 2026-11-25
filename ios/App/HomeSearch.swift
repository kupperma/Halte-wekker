import CoreLocation
import SwiftUI

/// Search on the home map (0.40). "When you click search it opens a whole new map screen instead of staying on the
/// normal map." Search is a sheet over the home now: the map stays as it is behind it (the same camera, its stops and
/// buses), the stops found are drawn on it, and once you pick one the ways there are in the sheet with Go, the route
/// on the same map. The whole Plan (from elsewhere, another time, trains or buses only, More ways) is one tap away.
struct HomeSearchSheet: View {
    @ObservedObject var model: PlanTripModel
    /// The stops found, drawn on the home map while you look.
    @Binding var hits: [Transit.StopHit]
    /// The whole Plan over the map, as before (with what's picked so far).
    let morePlan: () -> Void
    let close: () -> Void
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var near: NearMe
    @EnvironmentObject var goStore: GoStore
    @EnvironmentObject var live: LiveStore
    @ObservedObject private var places = PlacesStore.shared
    @State private var query = ""
    @State private var searching = false
    @State private var recents: [Destination] = PlanTripModel.recents()
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.to == nil {
                searchPart
            } else {
                waysPart
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.page.ignoresSafeArea())
        .task(id: query) { await find() }
        .task(id: runKey) {
            guard model.to != nil else { return }
            await model.run(here: near.position)
        }
        .onChange(of: model.to) { _, e in if let e { makeHome(e) } }
        .onAppear { if model.to == nil { typing = true } }
    }

    private var runKey: String {
        guard case .place(let p, _)? = model.to else { return "" }
        return "\(near.position == nil)|\(p.key)|\(p.ids.joined(separator: ","))"
    }

    // MARK: searching

    private var searchPart: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.s8) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.body.weight(.semibold)).foregroundStyle(DS.secondary)
                    TextField("Search a stop or place", text: $query)
                        .font(DS.body).foregroundStyle(DS.text)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($typing)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(DS.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear the search")
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(DS.surface, in: Capsule())
                Button("Cancel") { close() }
                    .font(DS.bodyStrong).foregroundStyle(DS.accentText)
                    .frame(minHeight: DS.hit)
            }
            .padding(.horizontal, DS.edge).padding(.top, DS.s16).padding(.bottom, DS.s8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    results
                }
                .padding(.horizontal, DS.edge).padding(.bottom, DS.s24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder private var results: some View {
        let q: String = query.trimmingCharacters(in: .whitespaces)
        if q.count < 2 {
            section("Your places")
            ForEach(places.list) { p in
                row(icon: p.symbol, title: p.name, sub: nil) { choose(.place(places.place(p), name: p.name)) }
            }
            if !recents.isEmpty {
                section("Recent")
                ForEach(recents) { d in
                    row(icon: "clock.arrow.circlepath", title: d.short, sub: d.name == d.short ? nil : d.name) { choose(.place(d.place)) }
                }
            }
            section("More")
            row(icon: "slider.horizontal.3", title: "Plan with more options", sub: "From elsewhere, another time, More ways") { morePlan() }
        } else {
            if searching && hits.isEmpty {
                HStack(spacing: DS.s8) { ProgressView(); Text("Searching…").font(DS.sub).foregroundStyle(DS.secondary) }
                    .frame(minHeight: DS.hit)
            } else if hits.isEmpty {
                Text("No stops or stations found for “\(q)”").font(DS.sub).foregroundStyle(DS.secondary)
                    .frame(minHeight: DS.hit)
            }
            if !hits.isEmpty {
                Text("Also on the map").font(DS.footnote).foregroundStyle(DS.secondary).padding(.vertical, 4)
            }
            ForEach(hits) { h in
                row(icon: "mappin.and.ellipse", title: h.name, sub: h.town.isEmpty ? nil : h.town) { pick(h) }
            }
        }
    }

    private func section(_ t: String) -> some View {
        Text(t).font(DS.footnoteStrong).foregroundStyle(DS.secondary)
            .padding(.top, DS.s12).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(icon: String, title: String, sub: String?, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(DS.accentText).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(2)
                    if let sub { Text(sub).font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 48).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(DS.divider).frame(height: 1) }
        }
        .buttonStyle(.plain)
    }

    /// The stops for what's typed (a moment after the typing stops).
    private func find() async {
        let q: String = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { hits = []; searching = false; return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        searching = true
        let found: [Transit.StopHit] = await Transit.findStops(q)
        guard !Task.isCancelled else { return }
        searching = false
        hits = found
    }

    private func pick(_ h: Transit.StopHit) {
        let d = Destination(id: h.id, name: h.name, lat: h.lat, lon: h.lon)
        PlanTripModel.remember(d)
        choose(.place(d.place))
    }

    private func choose(_ e: PlanTripModel.End) {
        typing = false
        model.from = .here
        model.when = .now
        model.to = e
    }

    // MARK: the ways there

    private var destLabel: String { model.to?.label ?? "" }

    private var waysPart: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.s8) {
                Button {
                    model.clear(); model.to = nil
                    typing = true
                } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.bold)).foregroundStyle(DS.text)
                        .frame(width: DS.hit, height: DS.hit)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the search")
                VStack(alignment: .leading, spacing: 1) {
                    Text("To \(destLabel)").font(DS.headline).foregroundStyle(DS.text).lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    Text("From your location · leave now").font(DS.footnote).foregroundStyle(DS.secondary)
                }
                Spacer(minLength: 4)
                Button("Done") { close() }
                    .font(DS.bodyStrong).foregroundStyle(DS.accentText)
                    .frame(minHeight: DS.hit)
            }
            .padding(.horizontal, DS.edge).padding(.top, DS.s12).padding(.bottom, DS.s8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ways
                    goButton
                    Button { morePlan() } label: {
                        Label("Another time or more options", systemImage: "slider.horizontal.3")
                            .font(DS.subStrong).foregroundStyle(DS.accentText)
                            .frame(maxWidth: .infinity, minHeight: DS.hit)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DS.edge).padding(.bottom, DS.s24)
            }
        }
    }

    @ViewBuilder private var ways: some View {
        if model.loading && model.options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Finding the ways there…").font(DS.headline).foregroundStyle(DS.text)
                DSSkeletonRow(); DSSkeletonRow()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(radius: DS.cardRadiusSmall, padding: 14)
        } else if let e = model.error, model.options.isEmpty {
            Text(e).font(DS.sub).foregroundStyle(DS.text).frame(maxWidth: .infinity, alignment: .leading)
                .dsCard(radius: DS.cardRadiusSmall, padding: 14)
        } else {
            ForEach(model.options) { t in option(t) }
        }
    }

    private func option(_ t: DoorTrip) -> some View {
        let on: Bool = t.id == (model.focused ?? model.options.first?.id)
        return OptionCard(trip: t, label: model.labels[t.id], selected: on, legBar: true,
                          mayNotRun: LiveStore.mayNotRun(t, among: model.options))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(DS.quick) { model.focused = t.id } }
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Shows it on the map; Go takes this one")
    }

    private var focusedTrip: DoorTrip? { model.options.first { $0.id == model.focused } ?? model.options.first }

    @ViewBuilder private var goButton: some View {
        if case .place(let dest, _)? = model.to, trip.phase == .idle, !model.options.isEmpty {
            let stop: String = focusedTrip.map { Fmt.place($0.last.toStop) } ?? dest.short
            DSPrimaryButton(title: "Go · wake me before \(stop)", icon: "bell.and.waves.left.and.right") { go(dest) }
        }
    }

    /// Go: the hands-free Fastest trip, on the option you looked at (as Plan's Go).
    private func go(_ dest: Place) {
        guard trip.phase == .idle else { return }
        if dest.key == Place.school.key, trip.direction != .toSchool { trip.pick(.toSchool) }
        if dest.key == Place.home.key, trip.direction != .home { trip.pick(.home) }
        let chosen: DoorTrip? = ChosenRide.pinned(focused: model.focused, suggested: model.suggested).flatMap { id in model.options.first { $0.id == id } }
        let seed: [DoorTrip] = chosen == nil ? [] : model.options
        let from: CLLocation? = near.position
        close()
        withAnimation(.easeInOut(duration: 0.35)) { goStore.open(to: dest, from: from, seed: seed, chosen: chosen) }
    }

    /// A place you searched becomes the home's destination, as in Plan (`PlanTripOverlay.makeHome`).
    private func makeHome(_ e: PlanTripModel.End) {
        guard trip.phase == .idle, case .place(let p, let name) = e else { return }
        if p.key == Place.home.key || p.key == Place.school.key {
            guard live.custom != nil, p.key == (trip.direction == .toSchool ? Place.school.key : Place.home.key) else { return }
            live.go(to: nil)
        } else {
            let d = Destination(id: p.ids.first ?? "\(p.coordinate.latitude),\(p.coordinate.longitude)", name: name ?? p.name,
                                lat: p.coordinate.latitude, lon: p.coordinate.longitude)
            guard live.custom != d else { return }
            live.go(to: d)
        }
        Task { await live.refresh(trip.direction, at: near.position) }
    }
}

/// A stop found by the search, on the home map: tap it to see the ways there.
struct SearchHitMark: View {
    let hit: Transit.StopHit
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            VStack(spacing: 0) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(DS.onAccent, DS.accent)
                Text(Fmt.place(hit.name)).font(DS.caption).foregroundStyle(DS.text).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(DS.surface.opacity(0.9), in: Capsule())
            }
            .frame(minWidth: DS.hit, minHeight: DS.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel("\(hit.name), found")
        .accessibilityHint("Shows the ways there")
    }
}
