import SwiftUI

// 0.36: the travel help on screen — the student OV line on plan options and the Go card, the home's card (works on your
// route, the last way home) and the settings rows.

/// "Free with your student OV" / "Costs money now (weekday) — ~€3.60 with 40% off", under a way or a ride you'd take.
/// Nothing without a student travel product (Settings › Trips & alarm).
struct StudentFareLine: View {
    let rides: [Ride]
    @ObservedObject private var notes = TravelNotes.shared

    private var ends: (from: String, to: String)? { TravelNotes.railEnds(rides) }

    var body: some View {
        let cents: Int? = ends.flatMap { notes.fullFare(from: $0.from, to: $0.to) }
        let rows: [(train: Bool, at: Date)] = rides.map { (train: $0.isTrain, at: $0.departure) }
        if let text = StudentOV.tripLine(notes.student, rides: rows, fullCents: cents) {
            let free = text.hasPrefix("Free")
            Label(text, systemImage: free ? "checkmark.seal" : "eurosign.circle")
                .font(DS.footnote)
                .foregroundStyle(free ? DS.accentText : DS.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .task(id: ends.map { "\($0.from)>\($0.to)" } ?? "") {
                    guard !free, let e = ends else { return }
                    await notes.askPrice(from: e.from, to: e.to)
                }
        }
    }
}

/// The home's card: works or a disruption on your route today or tomorrow, and in the evening away from home, the
/// last way home. While no trip runs.
struct TravelNotesBanner: View {
    @ObservedObject private var notes = TravelNotes.shared

    var body: some View {
        let works = notes.homeWorks
        let way = notes.lastHome ? notes.lastWay : nil
        if works != nil || way != nil {
            cards(works: works, way: way)
        }
    }

    private func cards(works: RailWorks.Impact?, way: LastTrip.Option?) -> some View {
        VStack(spacing: 8) {
            if let i = works {
                row(icon: i.works ? "wrench.and.screwdriver" : "exclamationmark.triangle", title: notes.headline(i), sub: nil,
                    warn: true) { withAnimation(DS.quick) { notes.dismiss(i) } }
            }
            if let o = way {
                row(icon: "moon.stars", title: LastTrip.cardText(o, hhmm: Fmt.hhmm),
                    sub: "Home \(Fmt.hhmm(o.arrive)) · first ride \(Fmt.hhmm(o.firstDeparture))", warn: false, close: nil)
            }
        }
    }

    private func row(icon: String, title: String, sub: String?, warn: Bool, close: (() -> Void)?) -> some View {
        HStack(spacing: DS.s12) {
            Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(warn ? DS.warning : DS.accentText)
                .frame(width: 32, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.subStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                if let sub { Text(sub).font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary)
                        .frame(width: DS.hit, height: DS.hit).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not now")
            }
        }
        .padding(.leading, DS.s12)
        .padding(.vertical, close == nil ? 8 : 0)
        .padding(.trailing, close == nil ? DS.s12 : 0)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.chipRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Trips & alarm: the student travel product, the check-out reminder and money back for a late train.
struct TravelHelpTripRows: View {
    @ObservedObject private var notes = TravelNotes.shared

    var body: some View {
        Section {
            Picker("Student travel product", selection: $notes.student) {
                ForEach(StudentOV.Product.allCases) { p in Text(p.title).tag(p) }
            }
            .settingsAnchor("trips.studentOV")
            Toggle("Check-out reminder", isOn: $notes.checkOut)
                .settingsAnchor("trips.checkOut")
            Toggle("Money back for a late train", isOn: $notes.delayClaim)
                .settingsAnchor("trips.delayClaim")
        } header: { Text("OV-chipkaart") } footer: {
            Text("With a student travel product, plans and the Go card say when a train or bus is free for you, and what it costs otherwise (NS’s price, less your discount). The check-out reminder comes a minute after you get off at the end of a trip, and where you change between bus and train or train companies — the app can’t see your card, it only reminds you. With a train 30 minutes late or more, it tells you after the trip that you can claim money back from NS.")
        }
    }
}

/// Settings › Notifications: works and disruptions on your routes, and the last way home.
struct TravelHelpNoticeRows: View {
    @ObservedObject private var notes = TravelNotes.shared

    var body: some View {
        Section {
            Toggle("Works and disruptions on my routes", isOn: $notes.works)
                .settingsAnchor("notices.works")
            if notes.works {
                if notes.impacts.isEmpty {
                    Text(notes.usualRides.isEmpty ? "No train rides of yours known yet: they’re learned from your trips between home and school, and the trips you plan."
                                                  : "Nothing on your trains for the next 7 days.")
                        .font(DS.footnote).foregroundStyle(DS.secondary)
                } else {
                    ForEach(notes.impacts.prefix(6), id: \.key) { i in
                        Text(notes.headline(i)).font(DS.footnote).foregroundStyle(DS.text)
                    }
                }
            }
            Toggle("Last way home", isOn: $notes.lastHome)
                .settingsAnchor("notices.lastHome")
        } footer: {
            Text("NS’s planned works and disruptions on the trains you usually take, today and the next 7 days: on the home, and a notification the evening before. In the evening, more than 3 km from home, the home shows the last bus or train that still gets you home, with a notification 30 minutes before it leaves.")
        }
        .task { await notes.refreshWorks(force: false) }
    }
}
