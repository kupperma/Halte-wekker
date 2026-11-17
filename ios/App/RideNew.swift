import SwiftUI

// The ride, the alarm, the change and the arrival in the new look (0.20, phase 2): the same content and controls as
// RideView, AlarmView, ArrivalView and ChangeBar, over the same TripManager. One main thing each, big where it matters.

// MARK: the ride

struct RideViewNew: View {
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var music: NowPlaying
    @EnvironmentObject var ns: NSStore
    @EnvironmentObject var planner: Planner
    @EnvironmentObject var lines: LineWatchStore
    @Environment(\.scenePhase) private var scene
    @State private var earlier = false
    @State private var walkTo: WalkTarget?
    @ScaledMetric(relativeTo: .largeTitle) private var big: CGFloat = 96

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    if trip.waitingToBoard { boarding } else { riding }
                }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s16)
            }
            VStack(spacing: 10) {
                if trip.phase == .awake && !trip.waitingToBoard {
                    DSPrimaryButton(title: "I’m off, end this leg", icon: "figure.walk.departure") { trip.legDone() }
                }
                DSHoldButton(title: "Hold to end trip", icon: "stop.circle") { trip.endTrip() }
            }
            .padding(.horizontal, DS.s16).padding(.top, 10).padding(.bottom, 6)
            .background(DS.page)
        }
        .background(DS.page.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sheet(item: $walkTo) { WalkMapSheet(target: $0).presentationDetents([.large]) }
        .animation(DS.quick, value: trip.waitingToBoard)
        .onAppear {
            music.setFast(scene == .active)
            Handoff.fromBoards = false              // (the old look's turn from the boards: nothing to turn here)
        }
        .onDisappear { music.setFast(false) }
        .onChange(of: scene) { _, s in music.setFast(s == .active) }
        .task(id: trip.index) {
            while !Task.isCancelled {
                if trip.waitingToBoard { await trip.loadUpcoming() }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    // MARK: the top

    private var legWord: String? { trip.legs.count > 1 ? "Leg \(trip.index + 1) of \(trip.legs.count)" : nil }

    /// GPS, and how the trip started.
    private var gpsLine: some View {
        HStack(spacing: DS.s8) {
            Label(trip.accuracy.map { "GPS ±\(Int($0)) m" } ?? "Finding GPS…", systemImage: "location.fill")
                .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
            Spacer(minLength: 4)
            if trip.demo { Text("Demo").font(DS.footnoteStrong).foregroundStyle(DS.warning) }
            else if trip.autoStarted { Text("Started by itself").font(DS.footnoteStrong).foregroundStyle(DS.accentText) }
        }
    }

    // MARK: still at the stop: what you can take

    private var boardingTitle: String {
        guard let l = trip.leg else { return "" }
        if trip.index == 0 && trip.route?.isFixed == true { return trip.direction == .toSchool ? "Next buses towards BUas" : "Next trains home" }
        return "Next \(l.mode == .train ? "trains" : "buses") to \(l.to.short)"
    }

    @ViewBuilder private var boarding: some View {
        let rail = trip.leg?.mode == .train
        let now = Date()
        let list = Array(trip.upcoming.filter { $0.trip.first.departure > now.addingTimeInterval(earlier ? -30 * 60 : -90) }.prefix(earlier ? 12 : 8))
        // Buses: the stop's own board, so cancelled ones and the ones that just left show too.
        let board = Array(trip.upcomingBoard.filter { d in
            earlier ? d.scheduled > now.addingTimeInterval(-30 * 60) || d.time > now.addingTimeInterval(-30 * 60)
                    : d.time > now.addingTimeInterval(-90) || (d.cancelled && d.scheduled > now.addingTimeInterval(-15 * 60))
        }.prefix(earlier ? 14 : 9))
        let mine = planner.chosen?.tripIds ?? []
        let what = rail ? "trains" : "buses"
        let emptyNote: String = trip.upcomingError ?? (trip.upcomingAsOf != nil && trip.upcomingAt != nil
                                                  ? "Couldn’t load the next \(what) just now. It tries again in a minute." : "Looking up the next \(what)…")
        VStack(alignment: .leading, spacing: 4) {
            Text([legWord, "Waiting to board"].compactMap { $0 }.joined(separator: " · ")).font(DS.subStrong).foregroundStyle(DS.secondary)
            Text(boardingTitle).font(DS.largeTitle).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
        }
        gpsLine
        Text("It notices which one you get on by itself: your GPS against the live position of every \(rail ? "train" : "bus") nearby. Or tap the one you’re on.")
            .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        if let l = trip.leg {
            // (from a saved list: just the way there, without "Leave by … (in 5 min)")
            let first = trip.upcomingAsOf == nil ? list.first : nil
            DSQuietButton(title: "Show the way to \(l.from.short)", icon: "figure.walk", full: true) {
                walkTo = WalkTarget(name: l.from.short, lat: l.from.coordinate.latitude, lon: l.from.coordinate.longitude, rail: rail,
                                    catchText: first.map { "the \($0.trip.first.line) at \(Fmt.hhmm($0.trip.first.departure))" }, leaves: first?.trip.first.departure)
            }
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let a = trip.upcomingAsOf, !(list.isEmpty && board.isEmpty) {
                    Text(Snapshots.asOf(a)).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.secondary)
                }
                Spacer()
                Button(earlier ? "Hide earlier ones" : "Show earlier ones") { withAnimation(DS.quick) { earlier.toggle() } }
                    .font(DS.subStrong).foregroundStyle(DS.accentText).frame(minHeight: DS.hit)
            }
            if list.isEmpty && board.isEmpty {
                HStack(spacing: 10) {
                    if trip.upcomingError == nil && trip.upcomingAt == nil { ProgressView() }
                    Text(emptyNote).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, DS.s12)
            }
            if !rail && !board.isEmpty {
                ForEach(board) { d in
                    let p = trip.upcoming.first(where: { $0.trip.first.tripId == d.tripId })
                    let ride: BoardRide? = p.map { BoardRide(minutes: $0.trip.rideMinutes, station: $0.to.short, arrival: $0.trip.last.arrival, grade: $0.trip.first.grade) }
                    DSBoardRow(d: d, ride: ride, stopLabel: Fmt.place(d.stopName),
                               watched: lines.isWatched(stopId: d.stopId, stopName: d.stopName, line: d.line, headsign: d.headsign), saved: trip.upcomingAsOf != nil,
                               choose: { if !d.cancelled { trip.choose(board: d) } }) {
                        lines.toggle(stopId: d.stopId, stopName: d.stopName, line: d.line, headsign: d.headsign, tripId: d.tripId, delay: d.live ? d.delay : nil)
                    }
                }
            } else {
                ForEach(list) { p in
                    let t = p.trip
                    Button { trip.choose(p) } label: {
                        DSTripRow(trip: t, head: t.first.isTrain ? "\(t.first.name.isEmpty ? "Train" : t.first.name) to \(p.to.short)" : "To \(Fmt.place(t.last.toStop))",
                                  extra: "\(t.rideLabel) · arrives \(Fmt.hhmm(t.last.arrival))",
                                  info: t.first.isTrain ? ns.rail(t.first) : nil, mine: mine.contains(t.first.tripId), saved: trip.upcomingAsOf != nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Tap if you’re on this one")
                }
            }
            if !rail { Text("Tap the bell to get told when a bus runs late, leaves early or is cancelled.").font(DS.footnote).foregroundStyle(DS.secondary).padding(.top, DS.s8) }
            if let u = trip.upcomingAt, trip.upcomingAsOf == nil {
                Text("Updated at \(Fmt.hhmm(u)).").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).padding(.top, 4)
            }
        }
        .dsPanel()
    }

    // MARK: on board

    /// "Leg 1 of 3 · You're on"
    private var rideKicker: String {
        let k = trip.vehicle == nil ? "Now riding" : trip.pickedByHand ? "You picked" : trip.choosing.count > 1 ? "Checking which bus" : "You’re on"
        return [legWord, k].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var riding: some View {
        let v = trip.vehicle
        let to = trip.leg?.to.short ?? ""
        let eta = trip.legArrival ?? trip.legTo
        VStack(alignment: .leading, spacing: 6) {
            Text(rideKicker).font(DS.subStrong).foregroundStyle(DS.secondary)
            HStack(spacing: 10) {
                if let v { DSLinePill(line: v.isTrain ? Transit.trainLabel(v.line) : v.line, train: v.isTrain) }
                Text(v.map { "\($0.title) to \(to)" } ?? (trip.leg?.title ?? "")).font(DS.title).foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        gpsLine
        if v == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for the bus or train you’re on…").font(DS.sub).foregroundStyle(DS.secondary)
            }
        } else if trip.choosing.count > 1 {
            let c = trip.choosing
            let same = Set(c.map(\.line)).count == 1
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                Text(same ? "\(c.count == 2 ? "Two" : "\(c.count)") \(c[0].title)s were close together: it’s sure which one once there’s some distance between them."
                          : "On \(RideView.choosingText(c)): it’s sure once their roads part.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        // the one big thing: how long to your stop, and how far along you are
        TimelineView(.periodic(from: .now, by: 2)) { tl in
            countdown(eta: eta, to: to, now: tl.date, train: v?.isTrain ?? (trip.leg?.mode == .train))
        }
        .id(trip.index)
        stats(eta: eta)
        if trip.phase == .awake {
            DSNote(icon: "bell.and.waves.left.and.right.fill", tint: DS.warning,
                   text: trip.ringAtStop ? "You’re awake. A chime when you’re there." : "You’re awake. Get your things ready.")
        }
        stopsAhead
        changeAhead
        if let line = howKnown { Text(line).font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true) }
        if let song = music.song { DSSongCard(song: song) }
    }

    /// The minutes to your stop, big (or the distance before the times are known), with how far along you are.
    private func countdown(eta: Date?, to: String, now: Date, train: Bool) -> some View {
        let c = RideAhead.countdown(eta: eta, metres: trip.distance, now: now)
        let p = min(1, max(0, trip.progress(at: now)))
        let thereAt = eta.flatMap { c?.unit == "min" ? ", there at \(Fmt.hhmm($0))" : nil } ?? ""
        let spoken = c.map { "\($0.spoken) to \(to)\(thereAt)" } ?? "Finding how far it is to \(to)"
        return VStack(alignment: .leading, spacing: DS.s12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(c?.value ?? "–").font(DS.hero(min(big, 128))).monospacedDigit().foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(c?.unit ?? "") to \(to)").font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(2)
                    if let eta, c?.unit == "min" { Text("there at \(Fmt.hhmm(eta))").font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            // the way along: done in the line's colour, the stops on the way as ticks, the bus or train where it is now
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.surface3).frame(height: 10)
                    Capsule().fill(DS.mode(train: train)).frame(width: max(10, w * p), height: 10)
                    ForEach(Array(trip.stopMarks.enumerated()), id: \.offset) { _, m in
                        Circle().fill(DS.surface).frame(width: 6, height: 6).offset(x: min(w - 6, max(0, w * m.fraction - 3)))
                    }
                    Image(systemName: train ? "tram.fill" : "bus.fill").font(.caption.weight(.bold)).foregroundStyle(DS.onAccent)
                        .frame(width: 28, height: 28).background(DS.mode(train: train), in: Circle())
                        .overlay(Circle().stroke(DS.surface, lineWidth: 2.5))
                        .offset(x: min(w - 28, max(0, w * p - 14)))
                }
                .frame(height: 28)
                .animation(.easeInOut(duration: 2), value: p)
            }
            .frame(height: 28)
            .accessibilityElement()
            .accessibilityLabel("Trip \(Int(p * 100)) percent done")
        }
        .dsPanel(padding: DS.s20)
    }

    /// Small, under it: how far, how fast, the next stop.
    private func stats(eta: Date?) -> some View {
        let speed = trip.speed.flatMap { $0 > 1 ? "\(Int(($0 * 3.6).rounded())) km/h" : nil }
        let minutesShown = eta.map { $0 > Date().addingTimeInterval(-120) } ?? false
        return HStack(spacing: DS.s8) {
            // the big number shows the minutes: the distance goes here (or the other way round)
            if minutesShown, let d = trip.distance {
                DSStat(value: Fmt.distance(d), label: "to go")
            } else if !minutesShown, let a = trip.arrival {
                DSStat(value: Fmt.hhmm(a), label: "there around")
            }
            DSStat(value: speed ?? "–", label: speed == nil ? "standing still" : "speed")
            if let m = trip.matchMeters, !trip.pickedByHand, !trip.byTimetable {
                DSStat(value: "\(m) m", label: "recognised")
            }
        }
        .padding(.vertical, DS.s12)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous))
    }

    /// The next stop and the ones after it, then yours.
    @ViewBuilder private var stopsAhead: some View {
        let marks = trip.stopMarks
        let next = trip.nextStop
        // the next stop, then the bigger stops after it (on a bus: the towns and stations)
        let ahead = RideAhead.ahead(times: marks.map(\.time), now: next?.arrival ?? Date(), limit: next == nil ? 3 : 2)
        if !ahead.isEmpty || next != nil || trip.legTo != nil {
            VStack(alignment: .leading, spacing: 0) {
                DSHeader(title: "Stops ahead").padding(.bottom, 6)
                if let n = next, let t = n.arrival, Fmt.place(n.name) != Fmt.place(trip.leg?.to.name ?? "") {
                    stopRow(Fmt.stop(n.name), t, next: true, yours: false)
                }
                ForEach(Array(ahead.enumerated()), id: \.offset) { k, i in
                    stopRow(marks[i].name, marks[i].time, next: k == 0 && next == nil, yours: false)
                }
                stopRow(trip.leg?.to.short ?? "Your stop", trip.legTo, next: false, yours: true)
            }
            .dsPanel()
        }
    }

    private func stopRow(_ name: String, _ time: Date?, next: Bool, yours: Bool) -> some View {
        HStack(spacing: DS.s12) {
            Circle().fill(yours ? DS.accent : next ? DS.text : DS.surface3).frame(width: 10, height: 10)
                .overlay(Circle().stroke(yours || next ? .clear : DS.legQuiet, lineWidth: 1.5))
            Text(name).font(yours || next ? DS.bodyStrong : DS.body).foregroundStyle(DS.text).lineLimit(2)
            if next { Text("next").font(DS.footnoteStrong).foregroundStyle(DS.accentText) }
            if yours { Text("your stop").font(DS.footnoteStrong).foregroundStyle(DS.accentText) }
            Spacer(minLength: 4)
            if let time { Text(Fmt.hhmm(time)).font(DS.calloutStrong).monospacedDigit().foregroundStyle(DS.text) }
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }

    /// The change ahead: the next one, and the room to make it (more after a slow bus).
    @ViewBuilder private var changeAhead: some View {
        if let n = trip.next, trip.index + 1 < trip.legs.count {
            let at = trip.legs[trip.index + 1].from.short
            let arrive = trip.legTo ?? trip.legArrival
            let ch = arrive.map { RideAhead.change(arrive: $0, leaves: n.departure, walk: n.walkBefore, isTrain: trip.vehicle?.isTrain ?? false,
                                                   grade: trip.rideGradeNow, at: at) }
            VStack(alignment: .leading, spacing: DS.s8) {
                DSHeader(title: "Then", sub: trip.arrival.map { "\(trip.finalName) around \(Fmt.hhmm($0))" })
                HStack(spacing: 10) {
                    DSLinePill(line: n.isTrain ? Transit.trainLabel(n.line) : n.line, train: n.isTrain)
                    Text("\(n.isTrain ? n.name : "Bus \(n.line)") at \(Fmt.hhmm(n.departure))").font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                if let ch {
                    Label(ch.text, systemImage: ch.tight ? "exclamationmark.triangle.fill" : "arrow.triangle.swap")
                        .font(DS.subStrong).monospacedDigit().foregroundStyle(ch.tight ? DS.warning : DS.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("From \(at)").font(DS.sub).foregroundStyle(DS.secondary)
                }
            }
            .dsPanel()
        }
    }

    /// How it knows the bus.
    private var howKnown: String? {
        if trip.pickedByHand { return "You picked it in the list." }
        if trip.byTimetable { return "Going by its timetable." }
        if trip.nextStop != nil, let m = trip.matchMeters { return "Recognised: \(m) m from you." }
        return nil
    }
}

// MARK: rows for the lists of what leaves

/// A bus on its stop's board: tap it if you're on it; the bell watches its line.
struct DSBoardRow: View {
    let d: BoardDeparture
    var ride: BoardRide? = nil
    var stopLabel: String? = nil
    var watched = false
    var saved = false
    let choose: () -> Void
    let bell: () -> Void
    var body: some View {
        let gone = !d.cancelled && d.time < Date().addingTimeInterval(-60)
        let late = d.cancelled || d.delay != 0
        HStack(alignment: .center, spacing: 10) {
            Button(action: choose) {
                HStack(alignment: .top, spacing: 10) {
                    DSLinePill(line: d.line, train: d.train).frame(width: 46, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.place(d.headsign)).font(DS.bodyStrong).foregroundStyle(DS.text).strikethrough(d.cancelled).lineLimit(2)
                        Text([stopLabel, BoardRow.status(d, saved: saved)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(DS.footnoteStrong).monospacedDigit().foregroundStyle(late ? DS.warning : d.live && !saved ? DS.accentText : DS.secondary)
                        if let r = ride, !d.cancelled {
                            Text("\(Fmt.rideText(r.minutes)) ride to \(r.station) station, arrives \(Fmt.hhmm(r.arrival))").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.hhmm(d.cancelled ? d.scheduled : d.time)).font(DS.bigNumber).monospacedDigit()
                            .foregroundStyle(d.cancelled ? DS.warning : DS.text).strikethrough(d.cancelled)
                        if !saved { Text(BoardRow.when(d)).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary) }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(d.cancelled ? "" : "Tap if you’re on this one")
            .accessibilityAction(named: "I’m on this one") { choose() }
            Button(action: bell) {
                Image(systemName: watched ? "bell.fill" : "bell").font(.body.weight(.semibold)).foregroundStyle(DS.accentText)
                    .frame(width: DS.hit, height: DS.hit).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(watched ? "Stop watching the \(d.line)" : "Watch the \(d.line): get told when it's late, early or cancelled")
        }
        .padding(.vertical, 10)
        .opacity(gone ? 0.55 : 1)
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
    }
}

/// A trip in a list of what leaves (the next trains, or buses with their whole way): its line, rank and how it runs,
/// the train's length and how busy, and when.
struct DSTripRow: View {
    let trip: DoorTrip
    var head: String? = nil
    var extra: String? = nil
    var info: RailInfo? = nil
    var watched = false
    var mine = false
    var saved = false
    var body: some View {
        let r = trip.first, last = trip.last
        let st = RideText.status(r, info, saved: saved)
        let gone = r.cancelled || info?.cancelled == true
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 6) {
                DSLinePill(line: r.isTrain ? Transit.trainLabel(r.line) : r.line, train: r.isTrain)
                if let c = info?.crowd, c > 0 { DSCrowd(level: c, words: false) }
            }
            .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    DSGrade(grade: trip.rides.count == 1 ? r.grade : last.grade, size: 20)
                    Text(head ?? (r.isTrain ? "\(r.name) to \(Fmt.place(last.toStop))" : "From \(Fmt.place(r.fromStop))")).font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(2)
                }
                if mine || watched {
                    HStack(spacing: 6) {
                        if mine { tag("Your plan", icon: "checkmark") }
                        if watched { tag("Watching", icon: "bell.fill") }
                    }
                }
                if !st.text.isEmpty {
                    Text(st.text).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(st.warn ? DS.warning : st.ok ? DS.accentText : DS.secondary)
                }
                Text(extra ?? "\(trip.rideLabel) · arrives \(Fmt.hhmm(last.arrival))").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                if r.isTrain, let s = info?.size {
                    Text(s.text).font(DS.footnote).foregroundStyle(s.warn ? DS.warning : DS.secondary)
                    if let l = s.layout { ConsistView(layout: l, pal: .toBreda, newLook: true) }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.hhmm(r.departure)).font(DS.bigNumber).monospacedDigit().foregroundStyle(DS.text).strikethrough(gone)
                if !saved { Text(Self.when(r.departure)).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary) }
            }
        }
        .padding(.vertical, 10)
        .opacity(!gone && r.departure < Date().addingTimeInterval(-60) ? 0.55 : 1)
        .contentShape(Rectangle())
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private func tag(_ t: String, icon: String) -> some View {
        Label(t, systemImage: icon).font(DS.caption).foregroundStyle(DS.accentSoftText)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(DS.accentSoft, in: Capsule())
    }

    static func when(_ d: Date) -> String {
        let m = Int((d.timeIntervalSinceNow / 60).rounded())
        if m <= -1 { return "left \(-m) min ago" }
        return m == 0 ? "now" : "in \(m) min"
    }
}

// MARK: the alarm

/// Wake up / get off now: the stop, how far, and one thing to do, hold to stop the alarm.
struct AlarmViewNew: View {
    @EnvironmentObject var trip: TripManager
    @ScaledMetric(relativeTo: .largeTitle) private var big: CGFloat = 64
    var approach: Bool { if case .alarm(let a) = trip.phase { return a }; return true }
    /// The warning colour as a fill, the same in light and dark (white text on it 5.9:1).
    private let alarmFill = Color(hex: 0xA84219)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            Image(systemName: "bell.and.waves.left.and.right.fill").font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating)
                .padding(.top, DS.s24)
                .accessibilityHidden(true)
            Text(approach ? "Wake up" : "Get off now").font(DS.hero(min(big, 96))).foregroundStyle(.white)
                .lineLimit(2).minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: DS.s8) {
                Text(trip.leg?.to.name ?? "").font(DS.title).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                Text(approach ? "\(Fmt.distance(trip.distance ?? 0)) to go. Get ready to get off." : "You’re at \(trip.leg?.to.short ?? "your stop").")
                    .font(DS.body).monospacedDigit().foregroundStyle(.white.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
                if let n = trip.nextText { Text(n).font(DS.callout).monospacedDigit().foregroundStyle(.white.opacity(0.92)).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: DS.s16)
            DSHoldButton(title: "Hold to stop alarm", seconds: 1.2, icon: "bell.slash.fill", fill: DS.surface) { trip.stopAlarm() }
        }
        .padding(.horizontal, DS.s20).padding(.bottom, DS.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alarmFill.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

// MARK: a change, and the end of the trip

struct ArrivalViewNew: View {
    @EnvironmentObject var trip: TripManager
    var browse: (() -> Void)? = nil             // to the map and the boards, while the change stays open
    @State private var pop = false
    @ScaledMetric(relativeTo: .largeTitle) private var big: CGFloat = 52
    private var nextLeg: Leg? { trip.phase == .transfer ? trip.legs[safe: trip.index + 1] : nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    if let n = nextLeg { change(n) } else { arrived }
                }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s16)
            }
            VStack(spacing: 6) {
                if nextLeg != nil {
                    DSPrimaryButton(title: "Start next leg", icon: "play.fill") { trip.nextLeg() }
                    Button("End trip here") { trip.endTrip() }
                        .font(DS.bodyStrong).foregroundStyle(DS.secondary).frame(maxWidth: .infinity, minHeight: DS.hit)
                } else {
                    DSPrimaryButton(title: "Done", icon: "checkmark") { trip.endTrip() }
                }
            }
            .padding(.horizontal, DS.s16).padding(.top, 10).padding(.bottom, 6)
            .background(DS.page)
        }
        .background(DS.page.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { pop = true } }
        .task(id: trip.index) {
            while !Task.isCancelled {
                if nextLeg != nil { await trip.loadUpcoming() }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    /// You're there: a tick, where, and how the trip went.
    @ViewBuilder private var arrived: some View {
        Image(systemName: "checkmark.circle.fill").font(.system(size: 64, weight: .bold)).foregroundStyle(DS.accentText)
            .scaleEffect(pop ? 1 : 0.6).opacity(pop ? 1 : 0)
            .padding(.top, DS.s24)
            .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.route?.isFixed == false ? "You’re at \(trip.arrivedAt ?? trip.route?.station.short ?? "your stop")" : trip.direction == .home ? "You’re home" : "You’re in Breda")
                .font(DS.hero(min(big, 64))).foregroundStyle(DS.text).lineLimit(3).minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            Text("Trip finished.").font(DS.body).foregroundStyle(DS.secondary)
        }
        if let s = trip.lastScore { DSScoreCard(result: s) }
    }

    /// A change: where you are, the next bus or train big, and what else leaves.
    @ViewBuilder private func change(_ n: Leg) -> some View {
        if let browse {
            DSQuietButton(title: "Map", icon: "chevron.left", action: browse)
                .accessibilityLabel("Back to the map. Your change stays open.")
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("You’re at \(trip.arrivedAt ?? trip.leg?.to.short ?? "")").font(DS.subStrong).foregroundStyle(DS.secondary)
            Text("Change at \(trip.leg?.to.short ?? "")").font(DS.largeTitle).foregroundStyle(DS.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        VStack(alignment: .leading, spacing: DS.s12) {
            DSHeader(title: "Next", sub: trip.arrival.map { "\(trip.finalName) around \(Fmt.hhmm($0))" })
            if let r = trip.next {
                HStack(alignment: .center, spacing: DS.s12) {
                    DSLinePill(line: r.isTrain ? Transit.trainLabel(r.line) : r.line, train: r.isTrain)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.isTrain ? r.name : "Bus \(r.line)") to \(n.to.short)").font(DS.bodyStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                        Text([r.platform.map { "Platform \($0)" }, "\(r.rideMinutes) min ride"].compactMap { $0 }.joined(separator: " · "))
                            .font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                    }
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 15)) { tl in
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(Fmt.hhmm(r.departure)).font(DS.hero(min(big, 52))).monospacedDigit().foregroundStyle(DS.text)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Text(Self.inMinutes(r.departure, now: tl.date)).font(DS.subStrong).monospacedDigit().foregroundStyle(DS.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("\(n.mode.title) to \(n.to.short)").font(DS.bodyStrong).foregroundStyle(DS.text)
            }
            Text("It starts by itself once you’re on board.").font(DS.footnote).foregroundStyle(DS.secondary)
        }
        .dsPanel()
        DSTransferList(all: trip.upcoming, updated: trip.upcomingAt, error: trip.upcomingError, mode: n.mode,
                       dest: n.mode == .train ? n.to.short : "Veghel", asOf: trip.upcomingAsOf)
            .dsPanel()
    }

    static func inMinutes(_ d: Date, now: Date) -> String {
        let m = Int((d.timeIntervalSince(now) / 60).rounded())
        return m <= -1 ? "left \(-m) min ago" : m == 0 ? "now" : "in \(m) min"
    }
}

/// The trip's score out of 500, its rank and what it means.
struct DSScoreCard: View {
    let result: ScoreResult
    var body: some View {
        let e = result.entry
        VStack(alignment: .leading, spacing: DS.s12) {
            HStack(alignment: .center, spacing: DS.s16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(e.score)").font(DS.hero(44)).monospacedDigit().foregroundStyle(DS.text)
                    Text("of 500").font(DS.footnoteStrong).foregroundStyle(DS.secondary)
                }
                DSGrade(grade: e.grade, size: 48)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Score \(e.score) of 500, \(e.grade) rank")
            Text("\(Int(e.mins.rounded())) min\(e.est ? ". Your next trips on this route are compared with this one." : ". The fastest possible is about \(e.ref) min.")")
                .font(DS.sub).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            if let f = result.flag { Text(f).font(DS.headline).foregroundStyle(DS.accentText) }
        }
        .dsPanel()
    }
}

/// The next buses or trains for your next leg (at a change): tap a train to be told about its platform.
struct DSTransferList: View {
    @State private var earlier = false
    let all: [PanelTrip]
    let updated: Date?
    let error: String?
    let mode: Mode
    let dest: String
    var asOf: Date? = nil
    @EnvironmentObject var ns: NSStore
    @EnvironmentObject var watch: WatchStore
    @EnvironmentObject var planner: Planner
    var body: some View {
        let what = mode == .train ? "trains" : "buses"
        let mine = planner.chosen?.tripIds ?? []
        let list = Array(all.filter { $0.trip.first.departure > Date().addingTimeInterval(earlier ? -30 * 60 : -60) }.prefix(earlier ? 10 : 6))
        let emptyNote: String = error ?? (updated == nil ? "Looking up the next \(what)…"
                                     : asOf != nil ? "Couldn’t load the next \(what) just now. It tries again in a minute." : "No \(what) to \(dest) coming up.")
        VStack(alignment: .leading, spacing: 0) {
            DSHeader(title: "Next \(what) to \(dest)", sub: asOf.map { Snapshots.asOf($0) } ?? updated.map { "updated \(Fmt.hhmm($0))" })
                .padding(.bottom, 6)
            if list.isEmpty {
                HStack(spacing: 10) {
                    if updated == nil && error == nil { ProgressView() }
                    Text(emptyNote).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, DS.s8)
            }
            ForEach(list) { p in
                let t = p.trip, f = t.first, rail = f.isTrain, info = ns.rail(f)
                let plat = info?.track ?? f.platform
                let row = DSTripRow(trip: t, head: rail ? "\(f.name.isEmpty ? "Train" : f.name) to \(f.headsign.isEmpty ? p.to.short : Fmt.place(f.headsign))" : "To \(Fmt.place(t.last.toStop))",
                                    extra: "\(t.rideLabel) · arrives \(Fmt.hhmm(t.last.arrival))\(plat.map { " · platform \($0)" } ?? "")",
                                    info: info, watched: rail && watch.isWatched(f, from: p.from), mine: mine.contains(f.tripId), saved: asOf != nil)
                if rail {
                    Button { _ = watch.toggle(t, from: p.from, to: p.to) } label: { row }
                        .buttonStyle(.plain)
                        .accessibilityHint(watch.isWatched(f, from: p.from) ? "Tap to stop watching it" : "Tap to be told if its platform changes or it runs late")
                } else {
                    row
                }
            }
            Button(earlier ? "Hide earlier ones" : "Show earlier ones") { withAnimation(DS.quick) { earlier.toggle() } }
                .font(DS.subStrong).foregroundStyle(DS.accentText).frame(minHeight: DS.hit)
            if mode == .train { Text("Tap a train to be told if its platform changes or it runs late.").font(DS.footnote).foregroundStyle(DS.secondary) }
        }
    }
}

// MARK: the bar to your trip, while you look at the map at a change

struct ChangeBarNew: View {
    @EnvironmentObject var trip: TripManager
    let back: () -> Void
    var body: some View {
        Button(action: back) {
            HStack(spacing: DS.s12) {
                Image(systemName: "arrow.triangle.swap").font(.body.weight(.bold)).foregroundStyle(DS.onAccent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Change at \(trip.leg?.to.short ?? "your stop")").font(DS.bodyStrong).foregroundStyle(DS.onAccent).lineLimit(2)
                    if let r = trip.next {
                        Text("\(r.isTrain ? r.name : "Bus \(r.line)") at \(Fmt.hhmm(r.departure))").font(DS.footnote).monospacedDigit().foregroundStyle(DS.onAccent.opacity(0.9))
                    }
                }
                Spacer(minLength: 6)
                Text("Back to your trip").font(DS.footnoteStrong).foregroundStyle(DS.accentText)
                    .padding(.horizontal, 12).frame(minHeight: 36)
                    .background(DS.surface, in: Capsule())
            }
            .padding(.horizontal, DS.s16).frame(minHeight: DS.cta)
            .background(DS.accent, in: RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .padding(.horizontal, DS.edge).padding(.bottom, 4)
        }
        .buttonStyle(DSPressStyle())
        .accessibilityHint("Back to your change")
    }
}
