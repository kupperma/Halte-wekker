import CoreLocation
import EventKit
import SwiftUI

/// The first-run setup (0.23): welcome, your school, your home and its stops, other places, your timetable, your
/// mornings, and a summary. A new install sees it by itself; Settings › Your school and home opens it again ("Set up
/// again", filled in) or as a new student sees it ("Test the setup as a new user"). Nothing is saved until Done
/// (`SetupStore.finish`). The rules are `SetupLogic`'s.
struct SetupFlow: View {
    let mode: SetupStore.Mode
    @State private var step: SetupStep = .welcome
    @State private var draft: SetupDraft
    @EnvironmentObject var near: NearMe
    @ObservedObject private var store = SetupStore.shared

    init(mode: SetupStore.Mode, draft: SetupDraft) {
        self.mode = mode
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.s16) {
                        header.id("top")
                        page
                    }
                    .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: step) { _, _ in scroll.scrollTo("top", anchor: .top) }
            }
            .background(DS.page.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { bar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let p = SetupLogic.previous(step), step != .welcome {
                        Button { go(p) } label: {
                            HStack(spacing: 4) { Image(systemName: "chevron.left").font(.body.weight(.semibold)); Text("Back") }
                        }
                        .accessibilityLabel("Back to \(p.title.lowercased())")
                    }
                }
                ToolbarItem(placement: .principal) {
                    if mode == .test {
                        Label("Test setup", systemImage: "testtube.2").labelStyle(.titleAndIcon)
                            .font(DS.footnoteStrong).foregroundStyle(DS.accentText)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if mode != .firstRun {
                        Button(mode == .test ? "End test" : "Cancel") { store.cancel() }
                            .accessibilityHint(mode == .test ? "Your own setup stays as it is" : "Nothing changes")
                    }
                }
            }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .interactiveDismissDisabled()
    }

    private func go(_ s: SetupStep) { withAnimation(DS.quick) { step = s } }

    // MARK: the top and the bottom

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.s4) {
            if let c = SetupLogic.counter(step) {
                Text(c).font(DS.footnoteStrong).foregroundStyle(DS.secondary)
            }
            Text(step == .welcome ? "Welcome to Haltewekker" : step.title)
                .font(DS.largeTitle).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: SetupWelcome(test: mode == .test)
        case .school: SetupSchoolStep(draft: $draft, near: near.position?.coordinate)
        case .home: SetupHomeStep(draft: $draft)
        case .places: SetupPlacesStep(draft: $draft)
        case .timetable: SetupTimetableStep(draft: $draft)
        case .arrival: SetupMorningStep(draft: $draft)
        case .done: SetupDoneStep(draft: draft, test: mode == .test, change: go)
        }
    }

    private var why: String? {
        switch step {
        case .school where !SetupLogic.canContinue(.school, draft): return "Pick your school to go on."
        case .home where !SetupLogic.canContinue(.home, draft): return "Set your home to go on."
        default: return nil
        }
    }

    private var bar: some View {
        VStack(spacing: DS.s8) {
            if step == .done {
                DSPrimaryButton(title: "Open the map", icon: "map.fill") { store.finish(draft, mode: mode, demo: false) }
                    .disabled(!SetupLogic.canFinish(draft))
                DSQuietButton(title: "Try a pretend trip", icon: "play.circle.fill", full: true) { store.finish(draft, mode: mode, demo: true) }
                    .disabled(!SetupLogic.canFinish(draft))
                    .accessibilityHint("Saves this setup, then starts the demo trip")
            } else {
                let ok = SetupLogic.canContinue(step, draft)
                DSPrimaryButton(title: step == .welcome ? (mode == .test ? "Start the test" : "Start") : "Continue") {
                    if let n = SetupLogic.next(step) { go(n) }
                }
                .disabled(!ok)
                .opacity(ok ? 1 : 0.45)
                if let why { Text(why).font(DS.footnote).foregroundStyle(DS.secondary).frame(maxWidth: .infinity) }
            }
        }
        .padding(.horizontal, DS.s16).padding(.top, DS.s12).padding(.bottom, DS.s8)
        .background(DS.page.opacity(0.96).ignoresSafeArea(edges: .bottom))
    }
}

// MARK: 1. welcome

private struct SetupWelcome: View {
    let test: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var bell: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            Image(systemName: "alarm.waves.left.and.right.fill").font(.system(size: min(bell, 72), weight: .semibold))
                .foregroundStyle(DS.accentText).accessibilityHidden(true)
            Text("It wakes you before your stop, and in the morning for your first class, with the trip there.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DS.s12) {
                DSHeader(title: "What it asks")
                point("graduationcap.fill", "Your school", "Where trips to school go.")
                point("house.fill", "Your home and its stops", "Where your mornings start and trips home go.")
                point("calendar", "Your timetable, if you like", "Only the first class of each day: it sets the trip and the alarm.")
            }
            .dsPanel()
            Text("About two minutes. What you set here stays on this iPhone; trips are planned with Transitous’s open data.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            if test {
                DSNote(icon: "testtube.2", tint: DS.accentText,
                       text: "This is a test. Your own school, home, stops, timetable and school alarm are kept. End the test at any step, or tap “Back to my own” on the home after Done, and they come back exactly as they are now. Until then the school alarm follows the test setup.")
            }
        }
    }

    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.s12) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(DS.accentSoftText)
                .frame(width: 36, height: 36).background(DS.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.calloutStrong).foregroundStyle(DS.text)
                Text(text).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: parts the steps share

/// A row you tap to pick: an icon, a title and a line under it, and a tick when it's picked.
private struct SetupPickRow: View {
    let icon: String?
    let title: String
    var sub: String? = nil
    let picked: Bool
    var multiple = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.s12) {
                if let icon {
                    Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(DS.accentText)
                        .frame(width: 28).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.bodyStrong).foregroundStyle(DS.text).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let sub, !sub.isEmpty {
                        Text(sub).font(DS.footnote).foregroundStyle(DS.secondary).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: DS.s8)
                Image(systemName: picked ? (multiple ? "checkmark.circle.fill" : "largecircle.fill.circle") : "circle")
                    .font(.title3).foregroundStyle(picked ? DS.accentText : DS.divider)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, DS.s8)
            .frame(maxWidth: .infinity, minHeight: DS.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }
}

/// A search field in the new look.
private struct SetupField: View {
    let prompt: String
    @Binding var text: String
    var icon = "magnifyingglass"
    var keyboard: UIKeyboardType = .default
    var body: some View {
        HStack(spacing: DS.s8) {
            Image(systemName: icon).foregroundStyle(DS.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(DS.body).foregroundStyle(DS.text)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.secondary) }
                    .buttonStyle(.plain).frame(minWidth: DS.hit, minHeight: DS.hit).accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, DS.s12)
        .frame(minHeight: DS.hit + 4)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
    }
}

private func distanceWords(_ m: Double) -> String {
    m < 1000 ? "\(Int((m / 10).rounded()) * 10) m" : String(format: "%.1f km", m / 1000)
}

// MARK: 2. school

private struct SetupSchoolStep: View {
    @Binding var draft: SetupDraft
    let near: CLLocationCoordinate2D?
    @State private var query = ""
    @State private var picking: SchoolCatalog.Hit?
    @State private var finding = false
    private static let catalog = SchoolCatalog.load()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            Text("Where you have classes: trips to school go there, and the school alarm plans to it.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            if let s = draft.school, picking == nil { chosen(s) }
            SetupField(prompt: "Search your school", text: $query)
                .submitLabel(.search)
                .onChange(of: query) { _, _ in picking = nil }
            if let p = picking {
                campuses(p)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                results
            }
            DSQuietButton(title: "Search an address, stop or station", icon: "mappin.and.ellipse", full: true) { finding = true }
            Text("Not in the list, or another building? Search its address: trips go to that spot.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $finding) {
            PlaceFinderSheet(title: "Your school", prompt: "Address, stop or station", near: near) { chooseFound($0) }
        }
    }

    private var results: some View {
        let hits = SchoolCatalog.search(query, in: Self.catalog, limit: 8)
        return VStack(alignment: .leading, spacing: 0) {
            if hits.isEmpty {
                Text("No school called “\(query)” in the list. Search its address below.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, DS.s8)
            }
            ForEach(Array(hits.enumerated()), id: \.element.id) { i, h in
                if i > 0 { Divider() }
                SetupPickRow(icon: "graduationcap.fill", title: h.entry.name, sub: subLine(h),
                             picked: draft.schoolCatalogId == h.entry.id) { pick(h) }
            }
        }
        .dsPanel(padding: DS.s12)
    }

    /// "TU/e · Eindhoven", "Fontys · Eindhoven, Tilburg, Venlo"
    private func subLine(_ h: SchoolCatalog.Hit) -> String {
        let c = cities(h.campuses)
        return h.entry.short == h.entry.name ? c : "\(h.entry.short) · \(c)"
    }

    private func cities(_ c: [SchoolEntry.Campus]) -> String {
        var seen = Set<String>()
        return c.map(\.city).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    private func campuses(_ h: SchoolCatalog.Hit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DSHeader(title: "Which campus?", sub: h.entry.short).padding(.bottom, DS.s4)
            ForEach(Array(h.campuses.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Divider() }
                SetupPickRow(icon: "building.2.fill", title: c.label, sub: nil,
                             picked: draft.schoolCatalogId == h.entry.id && draft.campus == c.name) { choose(h.entry, c) }
            }
        }
        .dsPanel(padding: DS.s12)
    }

    private func pick(_ h: SchoolCatalog.Hit) {
        if h.campuses.count == 1, let c = h.campuses.first { choose(h.entry, c) } else { withAnimation(DS.quick) { picking = h } }
    }

    private func choose(_ e: SchoolEntry, _ c: SchoolEntry.Campus) {
        draft.school = SavedPlace(id: "school", name: e.short, kind: .school, lat: c.lat, lon: c.lon)
        draft.schoolCatalogId = e.id
        draft.campus = c.name
        draft.schoolNames = [e.short, e.name]
        draft.keptHints = nil
        withAnimation(DS.quick) { picking = nil; query = "" }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func chooseFound(_ h: Transit.PlaceHit) {
        let name = h.kind == .stop ? (h.name.range(of: ", ").map { String(h.name[$0.upperBound...]) } ?? h.name) : h.name
        draft.school = SavedPlace(id: "school", name: name, kind: .school, lat: h.lat, lon: h.lon)
        draft.schoolCatalogId = nil
        draft.campus = h.town.isEmpty ? nil : h.town
        draft.schoolNames = [name]
        draft.keptHints = nil
        picking = nil; query = ""
    }

    private func chosen(_ s: SavedPlace) -> some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            HStack(spacing: DS.s12) {
                Image(systemName: "graduationcap.fill").font(.title3).foregroundStyle(DS.accentText).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name.isEmpty ? "Your school" : s.name).font(DS.headline).foregroundStyle(DS.text)
                    Text(draft.campus.map { "\($0) · trips go to this campus" } ?? "Trips go to this spot")
                        .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(DS.accentText).accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your school: \(s.name), \(draft.campus ?? "")")
            if draft.schoolCatalogId == nil {
                VStack(alignment: .leading, spacing: DS.s4) {
                    Text("What you call it").font(DS.footnoteStrong).foregroundStyle(DS.secondary)
                    TextField("School", text: Binding(get: { draft.school?.name ?? "" }, set: { draft.school?.name = $0; draft.schoolNames = [$0] }))
                        .font(DS.body).padding(.horizontal, DS.s12).frame(minHeight: DS.hit)
                        .background(DS.surface2, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                    Text("The app says it like this: “At \(s.name.isEmpty ? "School" : s.name) 08:41”.")
                        .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .dsPanel()
    }
}

// MARK: 3. home

private struct SetupHomeStep: View {
    @Binding var draft: SetupDraft
    @EnvironmentObject var near: NearMe
    @State private var locating = false
    @State private var problem: String?
    @State private var finding = false
    @State private var choices: [SetupStop]?
    @State private var loading = false

    private var homeKey: String { draft.home.map { "\($0.lat),\($0.lon)" } ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            Text("Where your mornings start and trips home go. Then pick the stops you leave from: the home shows what leaves there.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            if let h = draft.home { chosen(h) }
            if draft.home == nil {
                DSPrimaryButton(title: "Use where I am now", icon: "location.fill") { useHere() }.disabled(locating)
            } else {
                DSQuietButton(title: "Use where I am now", icon: "location.fill", full: true) { useHere() }.disabled(locating)
            }
            if locating {
                HStack(spacing: DS.s8) { ProgressView(); Text("Finding where you are…").font(DS.sub).foregroundStyle(DS.secondary) }
                    .accessibilityElement(children: .combine)
            }
            if let problem { DSNote(icon: "location.slash.fill", text: problem) }
            DSQuietButton(title: "Search an address or stop", icon: "magnifyingglass", full: true) { finding = true }
            Text("Your location is only used while the app is open for this (iPhone asks once). Not home now? Search your address.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            if draft.home != nil { stops }
        }
        .task(id: homeKey) { await loadStops() }
        .sheet(isPresented: $finding) {
            PlaceFinderSheet(title: "Your home", prompt: "Address or stop", near: near.position?.coordinate) { setHome($0) }
        }
    }

    private func chosen(_ h: SavedPlace) -> some View {
        HStack(spacing: DS.s12) {
            Image(systemName: "house.fill").font(.title3).foregroundStyle(DS.accentText).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Home").font(DS.headline).foregroundStyle(DS.text)
                Text(draft.homeLabel ?? "Set").font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(DS.accentText).accessibilityHidden(true)
        }
        .dsPanel()
        .accessibilityElement(children: .combine)
    }

    /// The stops to pick from: those near home, and any already on the board that aren't among them.
    private var rows: [SetupStop] {
        let c = choices ?? []
        return draft.board.filter { b in !c.contains { $0.id == b.id } } + c
    }

    private var stops: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSHeader(title: "Your stops", sub: "\(draft.board.count) of \(SetupLogic.maxBoardStops) picked").padding(.bottom, DS.s4)
            if loading && choices == nil {
                HStack(spacing: DS.s8) { ProgressView(); Text("Finding the stops near home…").font(DS.sub).foregroundStyle(DS.secondary) }
                    .padding(.vertical, DS.s8)
            } else if rows.isEmpty {
                Text(choices == nil ? "Couldn’t look up the stops just now: trips start from home itself. Pick them later in Settings › Home bus stops and lines."
                                    : "No stops found near here: trips start from home itself.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, DS.s8)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Divider() }
                let picked = draft.board.contains { $0.id == s.id }
                SetupPickRow(icon: s.rail ? "tram.fill" : "bus.fill", title: s.name, sub: s.metres > 0 ? distanceWords(s.metres) : "On your board now",
                             picked: picked, multiple: true) {
                    draft.board = SetupLogic.toggle(s, in: draft.board)
                    draft.boardChosen = true
                }
            }
            Text("Up to three. The home board shows what leaves from them, and the school alarm’s trips start there.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, DS.s8)
        }
        .dsPanel(padding: DS.s12)
    }

    private func loadStops() async {
        guard let h = draft.home else { choices = nil; return }
        loading = true
        let found = await Transit.nearStopChoices(CLLocationCoordinate2D(latitude: h.lat, longitude: h.lon))
        guard !Task.isCancelled else { return }
        loading = false
        choices = found
        // a new home: its nearest stop to start with
        if draft.boardChosen, draft.board.isEmpty, let first = found?.first { draft.board = [first] }
    }

    private func useHere() {
        problem = nil
        let st = CLLocationManager().authorizationStatus
        if st == .denied || st == .restricted {
            problem = "Location is off for Haltewekker. Search your address instead, or allow it in Settings › Haltewekker › Location."
            return
        }
        locating = true
        Task { @MainActor in
            let asked = Date()
            near.locate(force: true, ask: true)
            var tick = 0
            while Date().timeIntervalSince(asked) < 25 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                tick += 1
                if let p = near.position, Date().timeIntervalSince(p.timestamp) < 120, p.horizontalAccuracy >= 0, p.horizontalAccuracy < 500 {
                    setHere(p); locating = false; return
                }
                let s = CLLocationManager().authorizationStatus
                if s == .denied || s == .restricted { break }
                if (s == .authorizedWhenInUse || s == .authorizedAlways) && tick % 4 == 1 { near.locate(force: true) }
            }
            locating = false
            let s = CLLocationManager().authorizationStatus
            problem = s == .denied || s == .restricted
                ? "Location is off for Haltewekker. Search your address instead, or allow it in Settings › Haltewekker › Location."
                : "Couldn’t find where you are just now. Search your address instead."
        }
    }

    private func setHere(_ l: CLLocation) {
        draft.home = SavedPlace(id: "home", name: "Home", kind: .home, lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        draft.homeLabel = "Where you were at \(Fmt.hhmm(l.timestamp))"
        draft.board = []; draft.boardChosen = true
        choices = nil
    }

    private func setHome(_ h: Transit.PlaceHit) {
        let stop = h.kind == .stop
        draft.home = SavedPlace(id: "home", name: "Home", kind: .home, lat: h.lat, lon: h.lon, stopIds: stop ? [h.id] : [])
        draft.homeLabel = h.town.isEmpty || h.name.contains(h.town) ? h.name : "\(h.name), \(h.town)"
        draft.board = stop ? [SetupStop(id: h.id, name: h.name, lat: h.lat, lon: h.lon)] : []
        draft.boardChosen = true
        choices = nil
    }
}

// MARK: 4. other places

private struct SetupPlacesStep: View {
    @Binding var draft: SetupDraft
    @State private var adding: Adding?

    private struct Adding: Identifiable {
        let name: String?
        var id: String { name ?? "" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            Text("Places you go often, for the chips under the search field and Plan. Skip this if you like: you can add them any time in Settings › Your places.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            if !draft.others.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(draft.others.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Divider() }
                        HStack(spacing: DS.s12) {
                            Image(systemName: "mappin").foregroundStyle(DS.accentText).frame(width: 28).accessibilityHidden(true)
                            Text(p.name).font(DS.bodyStrong).foregroundStyle(DS.text)
                            Spacer(minLength: 4)
                            Button { draft.others.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "minus.circle.fill").font(.title3).foregroundStyle(DS.warning)
                                    .frame(minWidth: DS.hit, minHeight: DS.hit)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(p.name)")
                        }
                    }
                }
                .dsPanel(padding: DS.s12)
            }
            VStack(alignment: .leading, spacing: DS.s12) {
                DSHeader(title: "Add a place")
                ChipFlow(spacing: DS.s8) {
                    ForEach(["Work", "Sports", "Station"], id: \.self) { n in chip(n, icon: "plus") { adding = Adding(name: n) } }
                    chip("Something else", icon: "magnifyingglass") { adding = Adding(name: nil) }
                }
            }
        }
        .sheet(item: $adding) { a in
            PlaceSearchSheet(title: "Add \(a.name ?? "a place")") { hit in
                let all = draft.others + [draft.home, draft.school].compactMap { $0 }
                let id = PlacesLogic.newId(all, seed: String(UUID().uuidString.prefix(6)).lowercased())
                draft.others.append(SavedPlace(id: id, name: a.name ?? Fmt.place(hit.name), kind: .custom, lat: hit.lat, lon: hit.lon, stopIds: [hit.id]))
            }
        }
    }

    private func chip(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(DS.subStrong).foregroundStyle(DS.accentText)
                .padding(.horizontal, 14).frame(minHeight: DS.hit)
                .background(DS.surface, in: Capsule())
        }
        .buttonStyle(DSPressStyle())
    }
}

// MARK: 5. timetable

private struct SetupTimetableStep: View {
    @Binding var draft: SetupDraft
    @Environment(\.scenePhase) private var scene
    @State private var access = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @State private var calendars: [SetupCalendar] = []
    @State private var schoolLike: Set<String> = []
    @State private var loaded = false
    @State private var link = ""
    @State private var before: Set<String>?
    @State private var waiting = false
    @State private var found: String?
    @State private var notFound = false

    private var hints: SchoolHints { SchoolHints.make(profileHints: SetupLogic.hints(draft), school: draft.schoolNames) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            Text("For the school alarm: the first class of each day sets the trip there and the alarm. Nothing else in it is read.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(TimetableChoice.allCases.enumerated()), id: \.element) { i, c in
                    if i > 0 { Divider() }
                    SetupPickRow(icon: icon(c), title: title(c), sub: sub(c), picked: draft.timetable == c) {
                        withAnimation(DS.quick) { draft.timetable = c }
                    }
                }
            }
            .dsPanel(padding: DS.s12)
            switch draft.timetable {
            case .calendars?: calendarsPart
            case .link?: linkPart
            case .manual?:
                VStack(alignment: .leading, spacing: DS.s8) {
                    DSHeader(title: "Your first class", sub: SetupLogic.weekWords(draft.week))
                    ManualWeekEditor(week: $draft.week)
                }
                .dsPanel(padding: DS.s12)
            case .later?:
                Text("You can set it up later in Settings › School alarm. Trips and the stop alarm work without it.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            case nil: EmptyView()
            }
        }
        .task { if access { await load() } }
        .onChange(of: scene) { _, s in if s == .active, waiting { Task { await lookForNew() } } }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            if waiting || notFound { Task { await lookForNew() } }
        }
    }

    private func icon(_ c: TimetableChoice) -> String {
        switch c {
        case .calendars: return "calendar"
        case .link: return "link"
        case .manual: return "clock"
        case .later: return "arrow.uturn.forward"
        }
    }
    private func title(_ c: TimetableChoice) -> String {
        switch c {
        case .calendars: return "On this iPhone"
        case .link: return "I have a roster link"
        case .manual: return "Same times every week"
        case .later: return "Later"
        }
    }
    private func sub(_ c: TimetableChoice) -> String {
        switch c {
        case .calendars: return "A calendar you already have: TimeEdit’s, MyTimetable’s, Google, Outlook…"
        case .link: return "An iCal or webcal link from your school’s timetable site"
        case .manual: return "Your first class, day by day"
        case .later: return "Skip it for now"
        }
    }

    // calendars on the phone

    @ViewBuilder private var calendarsPart: some View {
        if !access {
            VStack(alignment: .leading, spacing: DS.s8) {
                DSPrimaryButton(title: "Allow calendar access", icon: "calendar") { Task { await ask() } }
                Text("Haltewekker reads only the calendars you pick, and only the first class of each day.")
                    .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            calendarList
        }
    }

    private var calendarList: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSHeader(title: "Your school calendar", sub: draft.calendarIds.isEmpty ? "Pick one" : "\(draft.calendarIds.count) picked")
                .padding(.bottom, DS.s4)
            if loaded && calendars.isEmpty {
                Text("No calendars on this iPhone yet.").font(DS.sub).foregroundStyle(DS.secondary).padding(.vertical, DS.s8)
            } else if !loaded {
                ProgressView().padding(.vertical, DS.s8)
            }
            ForEach(Array(calendars.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Divider() }
                let like = schoolLike.contains(c.id)
                SetupPickRow(icon: nil, title: c.title, sub: like ? "\(c.source) · looks like your timetable" : c.source,
                             picked: draft.calendarIds.contains(c.id), multiple: true) {
                    if draft.calendarIds.contains(c.id) { draft.calendarIds.remove(c.id) } else { draft.calendarIds.insert(c.id) }
                }
            }
            Text("Pick only the calendar your timetable is in.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, DS.s8)
        }
        .dsPanel(padding: DS.s12)
    }

    private func ask() async {
        access = await SchoolAlarm.shared.askCalendarAccess()
        if access { await load() }
    }

    private func load() async {
        let r = await SchoolAlarm.shared.setupCalendars(hints: hints)
        calendars = r.all; schoolLike = r.school; loaded = true
        if draft.timetable == .calendars, draft.calendarIds.isEmpty { draft.calendarIds = r.school }
        // (calendars picked that are gone don't count)
        draft.calendarIds = draft.calendarIds.filter { id in r.all.contains { $0.id == id } }
    }

    // a roster link

    private var linkURL: URL? { SetupLogic.webcalURL(link) }

    private var linkPart: some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            HStack(spacing: DS.s8) {
                SetupField(prompt: "https://… or webcal://…", text: $link, icon: "link", keyboard: .URL)
                PasteButton(payloadType: String.self) { s in
                    Task { @MainActor in link = (s.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.iconOnly).buttonBorderShape(.capsule)
            }
            if !link.isEmpty && linkURL == nil {
                Text("That doesn’t look like a web link. Copy the whole link from your school’s timetable site (it often ends in .ics).")
                    .font(DS.footnote).foregroundStyle(DS.warning).fixedSize(horizontal: false, vertical: true)
            }
            DSPrimaryButton(title: "Subscribe in Calendar", icon: "calendar.badge.plus") { Task { await subscribe() } }
                .disabled(linkURL == nil || waiting)
                .opacity(linkURL == nil ? 0.45 : 1)
            if waiting {
                HStack(spacing: DS.s8) { ProgressView(); Text("Looking for the new calendar…").font(DS.sub).foregroundStyle(DS.secondary) }
            }
            if let found { DSNote(icon: "checkmark.circle.fill", tint: DS.accentText, text: found) }
            if notFound {
                DSNote(icon: "info.circle.fill", text: access
                       ? "No new calendar yet. Add it in Settings › Calendar › Accounts (Add Account › Other › Add Subscribed Calendar), then pick it here."
                       : "Allow calendar access to find the new calendar, or add it in Settings › Calendar › Accounts and pick it later in Settings › School alarm.")
            }
            if access && (notFound || found != nil) { calendarList }
            Text("iPhone asks before it subscribes, and then refreshes subscribed calendars on its own schedule, so a change to your roster can take a while to show here.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func subscribe() async {
        guard let url = linkURL else { return }
        if !access { await ask() }
        if access { await load(); before = Set(calendars.map(\.id)) } else { before = nil }
        found = nil; notFound = false
        waiting = true
        let opened = await UIApplication.shared.open(url)
        if !opened { waiting = false; notFound = true }
    }

    /// Back from subscribing: the new subscribed calendar is picked (it can take a moment to appear).
    private func lookForNew() async {
        guard access, let before else { waiting = false; notFound = true; return }
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            await load()
            let new = SetupLogic.newSubscription(before: before, after: calendars)
            if !new.isEmpty {
                draft.calendarIds.formUnion(new.map(\.id))
                found = "Found “\(new.map(\.title).joined(separator: "”, “"))”: that’s your timetable now."
                waiting = false; notFound = false
                return
            }
        }
        waiting = false
        if found == nil { notFound = true }
    }
}

/// Same times every week: a first-class time per weekday, or none that day; (0.28) and, if you like, when the day
/// ends and what it is (for comparing timetables with friends and riding home together).
struct ManualWeekEditor: View {
    @Binding var week: ManualWeek
    private static let order = [2, 3, 4, 5, 6, 7, 1]
    private static let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.order.enumerated()), id: \.element) { i, wd in
                if i > 0 { Divider() }
                dayRow(wd)
            }
        }
    }

    @ViewBuilder private func dayRow(_ wd: Int) -> some View {
        let on: Bool = week.minutes(weekday: wd) != nil
        let name: String = Self.names[wd - 1]
        VStack(alignment: .leading, spacing: DS.s4) {
            HStack(spacing: DS.s8) {
                Toggle(isOn: Binding(get: { on }, set: { week.set(weekday: wd, minutes: $0 ? 8 * 60 + 30 : nil) })) {
                    Text(name).font(DS.bodyStrong).foregroundStyle(DS.text)
                }
                if on {
                    DatePicker("\(name)’s first class", selection: time(wd), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }
            .frame(minHeight: DS.hit + 4)
            if on { extras(wd, name: name) }
        }
        .padding(.bottom, on ? DS.s8 : 0)
    }

    @ViewBuilder private func extras(_ wd: Int, name: String) -> some View {
        let end: Int? = week.end(weekday: wd)
        HStack(spacing: DS.s8) {
            Text("Ends").font(DS.sub).foregroundStyle(DS.secondary)
            Spacer(minLength: DS.s8)
            if end != nil {
                DatePicker("\(name)’s last class ends", selection: endTime(wd), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Button { week.setEnd(weekday: wd, minutes: nil) } label: {
                    Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(DS.secondary)
                        .frame(minWidth: DS.hit, minHeight: DS.hit)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("No end time on \(name)")
            } else {
                Button { week.setEnd(weekday: wd, minutes: defaultEnd(wd)) } label: {
                    Text("Add end time").font(DS.subStrong).foregroundStyle(DS.accentText)
                        .frame(minHeight: DS.hit)
                }
                .buttonStyle(.plain)
                .accessibilityHint("For riding home together with friends")
            }
        }
        TextField("What it is (optional)", text: title(wd))
            .font(DS.sub)
            .textInputAutocapitalization(.sentences)
            .padding(.horizontal, DS.s12).padding(.vertical, 8)
            .frame(minHeight: DS.hit)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
            .accessibilityLabel("What \(name) is, optional")
    }

    private func defaultEnd(_ wd: Int) -> Int {
        let start: Int = week.minutes(weekday: wd) ?? 510
        return min(23 * 60 + 30, max(15 * 60, start + 6 * 60))
    }

    private func clock(_ m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }

    private func minutes(_ d: Date, or fallback: Int) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        guard let h = c.hour, let m = c.minute else { return fallback }
        return h * 60 + m
    }

    private func time(_ wd: Int) -> Binding<Date> {
        Binding(get: { clock(week.minutes(weekday: wd) ?? 510) },
                set: { d in week.set(weekday: wd, minutes: minutes(d, or: 510)) })
    }

    private func endTime(_ wd: Int) -> Binding<Date> {
        Binding(get: { clock(week.end(weekday: wd) ?? defaultEnd(wd)) },
                set: { d in week.setEnd(weekday: wd, minutes: minutes(d, or: defaultEnd(wd))) })
    }

    private func title(_ wd: Int) -> Binding<String> {
        Binding(get: { week.title(weekday: wd) ?? "" },
                set: { t in week.setTitle(weekday: wd, t) })
    }
}

// MARK: 6. mornings

private struct SetupMorningStep: View {
    @Binding var draft: SetupDraft
    @State private var permission: String?
    @State private var allowed = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            Text("How the school alarm plans your mornings. You can change these any time in Settings › School alarm.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DS.s12) {
                Stepper(value: $draft.earlyMinutes, in: SetupLogic.earlyRange, step: 5) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Be there \(draft.earlyMinutes) min before class").font(DS.bodyStrong).foregroundStyle(DS.text)
                        Text("Time to walk in and sit down.").font(DS.footnote).foregroundStyle(DS.secondary)
                    }
                }
                Divider()
                Stepper(value: $draft.wakeMinutes, in: SetupLogic.wakeRange, step: 5) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wake me \(draft.wakeMinutes) min before I leave").font(DS.bodyStrong).foregroundStyle(DS.text)
                        Text("Time to get up and ready.").font(DS.footnote).foregroundStyle(DS.secondary)
                    }
                }
            }
            .dsPanel()
            VStack(alignment: .leading, spacing: DS.s8) {
                Toggle(isOn: $draft.wakeOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wake me for school").font(DS.bodyStrong).foregroundStyle(DS.text)
                        Text("An alarm before you have to leave for your first class, moved when the buses change.")
                            .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if draft.wakeOn, let permission {
                    Label(permission, systemImage: allowed ? "checkmark.circle.fill" : "info.circle.fill")
                        .font(DS.footnote).foregroundStyle(allowed ? DS.accentText : DS.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .dsPanel()
            if draft.wakeOn && SetupLogic.schedule(draft) == ScheduleSource.none {
                DSNote(icon: "calendar.badge.exclamationmark",
                       text: "It needs your timetable to know your first class: go back a step, or set it later in Settings › School alarm.")
            }
        }
        .onChange(of: draft.wakeOn) { _, on in if on { Task { await askAlarm() } } }
        .task { if draft.wakeOn { await readPermission() } }
    }

    /// Asked here, in context: AlarmKit on iOS 26, else notifications.
    private func askAlarm() async {
        _ = await WakeAlarm.requestPermission()
        await readPermission()
    }

    private func readPermission() async {
        let p = await Task.detached { WakeAlarm.permission }.value
        allowed = p.ok
        permission = p.ok ? "Alarms are allowed: it rings like the Clock app’s." : p.text
    }
}

// MARK: 7. done

private struct SetupDoneStep: View {
    let draft: SetupDraft
    let test: Bool
    let change: (SetupStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            Text(test ? "This is what a new student has now. Try it for real: trips, the board and the school alarm use this test setup until you go back to your own."
                      : "That’s all it needs. Change any of it later in Settings › Your school and home.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                row("graduationcap.fill", "School", [draft.school?.name, draft.campus].compactMap { $0 }.joined(separator: " · "), .school)
                Divider()
                row("house.fill", "Home", draft.home == nil ? "Not set" : (draft.homeLabel ?? "Set"), .home)
                Divider()
                row("bus.fill", "Stops", draft.board.isEmpty ? "None: trips start from home itself" : draft.board.map(\.name).joined(separator: ", "), .home)
                if !draft.others.isEmpty {
                    Divider()
                    row("mappin", "Places", draft.others.map(\.name).joined(separator: ", "), .places)
                }
                Divider()
                row("calendar", "Timetable", SetupLogic.timetableWords(draft), .timetable)
                Divider()
                row("alarm.fill", "Mornings",
                    "At school \(draft.earlyMinutes) min early · wake \(draft.wakeMinutes) min before you leave · school alarm \(draft.wakeOn ? "on" : "off")", .arrival)
            }
            .dsPanel(padding: DS.s12)
            if test {
                DSNote(icon: "arrow.uturn.backward.circle.fill", tint: DS.accentText,
                       text: "“Back to my own” at the top of the home (and in Settings › Your school and home) puts your own setup back exactly as it was.")
            }
        }
    }

    private func row(_ icon: String, _ title: String, _ value: String, _ step: SetupStep) -> some View {
        Button { change(step) } label: {
            HStack(alignment: .top, spacing: DS.s12) {
                Image(systemName: icon).foregroundStyle(DS.accentText).frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.footnoteStrong).foregroundStyle(DS.secondary)
                    Text(value).font(DS.body).foregroundStyle(DS.text).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary).accessibilityHidden(true)
            }
            .padding(.vertical, DS.s8)
            .frame(maxWidth: .infinity, minHeight: DS.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Changes it")
    }
}

// MARK: search for an address, a place or a stop

/// Find an address, a named place, a stop or a station (Transitous's search), for the setup's School and Home.
struct PlaceFinderSheet: View {
    let title: String
    let prompt: String
    let near: CLLocationCoordinate2D?
    let pick: (Transit.PlaceHit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [Transit.PlaceHit] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                if searching && hits.isEmpty {
                    HStack { ProgressView(); Text("Searching…").foregroundStyle(DS.secondary) }
                } else if hits.isEmpty && query.count >= 3 {
                    Text("Nothing found for “\(query)”. Try the street and number, and the town.").foregroundStyle(DS.secondary)
                } else if query.count < 3 {
                    Text("For example “Hopmansstraat 2 Breda” or “Eindhoven Centraal”.").font(DS.footnote).foregroundStyle(DS.secondary)
                }
                ForEach(hits) { h in
                    Button { pick(h); dismiss() } label: {
                        HStack(spacing: DS.s12) {
                            Image(systemName: h.kind == .stop ? "bus.fill" : h.kind == .address ? "house" : "building.2")
                                .foregroundStyle(DS.accentText).frame(width: 24).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.name).font(DS.bodyStrong).foregroundStyle(DS.text)
                                Text([h.kind == .stop ? "Stop" : h.kind == .address ? "Address" : "Place", h.town].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(DS.footnote).foregroundStyle(DS.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 3 else { hits = []; return }
                try? await Task.sleep(nanoseconds: 400_000_000)        // (one search when you pause typing)
                guard !Task.isCancelled else { return }
                searching = true
                let found = await Transit.findPlaces(q, near: near)
                searching = false
                guard !Task.isCancelled else { return }
                hits = found
            }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

// MARK: the test setup's banner and Settings

/// On the home while a test setup is in use: "Test setup · Back to my own".
struct TestSetupBanner: View {
    @ObservedObject private var setup = SetupStore.shared
    @EnvironmentObject var trip: TripManager
    @State private var asking = false

    var body: some View {
        HStack(spacing: DS.s8) {
            Image(systemName: "testtube.2").font(.subheadline.weight(.semibold)).foregroundStyle(DS.accentSoftText).accessibilityHidden(true)
            Text("Test setup").font(DS.subStrong).foregroundStyle(DS.accentSoftText).lineLimit(1)
            Spacer(minLength: DS.s8)
            Button { asking = true } label: {
                Text("Back to my own").font(DS.subStrong).foregroundStyle(DS.onAccent).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(DS.accent, in: Capsule())
                    .frame(minHeight: DS.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DSPressStyle())
            .accessibilityLabel("Back to my own setup")
        }
        .padding(.horizontal, DS.s16)
        .background(DS.accentSoft.ignoresSafeArea(edges: .top))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .confirmationDialog("Back to your own setup?", isPresented: $asking, titleVisibility: .visible) {
            Button("Back to my own") { setup.backToMine(tripIdle: trip.phase == .idle) }
            Button("Keep testing", role: .cancel) {}
        } message: { Text("Your own school, home, stops, timetable and school alarm come back exactly as they were. The test setup goes.") }
    }
}

/// Settings › Your school and home: in either look.
struct SetupSettingsSection: View {
    let dismissSettings: () -> Void
    @Environment(\.settingsNewLook) private var newLook
    @ObservedObject private var setup = SetupStore.shared
    var body: some View {
        Section {
            NavigationLink { SetupSettingsView(dismissSettings: dismissSettings) } label: {
                HStack {
                    Text("Your school and home")
                    Spacer()
                    if setup.testLive { Text("Test setup").foregroundStyle(SettingsInk(newLook: newLook).late) }
                }
            }
        } footer: { Text("Set up again, or try the first-run setup as a new student would.") }
    }
}

struct SetupSettingsView: View {
    let dismissSettings: () -> Void
    @EnvironmentObject var trip: TripManager
    @Environment(\.settingsNewLook) private var newLook
    @ObservedObject private var setup = SetupStore.shared
    @ObservedObject private var places = PlacesStore.shared
    @ObservedObject private var profile = ProfileStore.shared
    @ObservedObject private var school = SchoolAlarm.shared
    @State private var confirmBack = false
    private var ink: SettingsInk { SettingsInk(newLook: newLook) }
    private var idle: Bool { trip.phase == .idle }

    private var timetable: String {
        switch profile.profile.schedule {
        case .calendars: return school.calendarIds.isEmpty ? "A calendar on this iPhone (none picked)" : "A calendar on this iPhone (\(school.calendarIds.count) picked)"
        case .manual(let w): return "Same times every week: \(SetupLogic.weekWords(w))"
        case .none: return "Not set up"
        }
    }

    var body: some View {
        Form {
            Section("Now") {
                row("School", [places.school?.name, profile.profile.campus].compactMap { $0 }.joined(separator: " · "))
                row("Home", places.home.map { $0.stopIds.isEmpty ? "Its spot on the map" : "\($0.stopIds.count == 1 ? "1 stop" : "\($0.stopIds.count) stops")" } ?? "Not set")
                row("Timetable", timetable)
            }
            if setup.testLive {
                Section {
                    Button("Back to my own") { confirmBack = true }.foregroundStyle(ink.link).disabled(!idle)
                } footer: {
                    Text(idle ? "You’re using the test setup. This puts your own school, home, stops, timetable and school alarm back, exactly as they were before the test."
                              : "Not while a trip is running: end the trip first.")
                }
            }
            Section {
                Button("Set up again") { dismissSettings(); setup.setUpAgain() }.foregroundStyle(ink.link).disabled(!idle)
            } footer: {
                Text("The setup with what you have now filled in. Nothing changes until you tap Done at the end.")
            }
            if !setup.testLive {
                Section {
                    Button("Test the setup as a new user") { dismissSettings(); setup.startTest(tripIdle: idle) }
                        .foregroundStyle(ink.link).disabled(!idle)
                } footer: {
                    Text(idle ? "Runs the first-run setup as a new student sees it, with empty fields. Your own setup is saved first; after Done you can really try trips and the school alarm with the test one, and “Back to my own” (on the home, and here) puts yours back exactly."
                              : "Not while a trip is running: end the trip first.")
                }
            }
        }
        .scrollContentBackground(newLook ? .automatic : .hidden)
        .background(PaperFill().ignoresSafeArea().opacity(newLook ? 0 : 1))
        .navigationTitle("Your school and home")
        .confirmationDialog("Back to your own setup?", isPresented: $confirmBack, titleVisibility: .visible) {
            Button("Back to my own") { setup.backToMine(tripIdle: idle) }
            Button("Keep testing", role: .cancel) {}
        } message: { Text("The test setup goes; your own comes back exactly as it was.") }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k)
            Spacer(minLength: 8)
            Text(v.isEmpty ? "Not set" : v).foregroundStyle(ink.muted).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings › School alarm › Your week (a profile with the same times every week).
struct ManualWeekScreen: View {
    @ObservedObject private var profile = ProfileStore.shared
    @State private var week = ManualWeek.workdays
    @Environment(\.settingsNewLook) private var newLook
    var body: some View {
        Form {
            Section {
                ManualWeekEditor(week: $week)
            } footer: { Text("Your first class each day: the school alarm plans the trip there and sets the alarm from it. When the day ends and what it is are only for comparing timetables with friends (and riding home together); you choose who sees them in Friends.") }
        }
        .scrollContentBackground(newLook ? .automatic : .hidden)
        .background(PaperFill().ignoresSafeArea().opacity(newLook ? 0 : 1))
        .navigationTitle("Your week")
        .onAppear { if case .manual(let w) = profile.profile.schedule { week = w } }
        .onChange(of: week) { _, w in profile.setSchedule(w.isEmpty ? ScheduleSource.none : .manual(w)) }
    }
}
