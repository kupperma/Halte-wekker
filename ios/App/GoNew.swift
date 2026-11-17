import CoreLocation
import SwiftUI

/// Fastest trip in the new look (0.20, phase 2): the map with your way, one big card with when to leave and what to
/// take, the watching, the other ways, and "I'm on it". It does all the old `GoView` does, over the same `GoStore`.
struct GoViewNew: View {
    @EnvironmentObject var go: GoStore
    @EnvironmentObject var trip: TripManager
    @EnvironmentObject var live: LiveStore
    @EnvironmentObject var ns: NSStore
    @State private var walkTo: WalkTarget?
    @State private var liveTrack: LiveTrackTarget?
    @State private var showSteady = false
    @State private var choosing = false
    @State private var mapFocus = 0                 // the Go to card's On the map: the map shows the stop and the walk
    @State private var walkMetres: Double?          // the walk to the stop on foot, from the map
    @ScaledMetric(relativeTo: .largeTitle) private var big: CGFloat = 52

    var body: some View {
        GeometryReader { g in
            let bar: CGFloat = 56                                   // the buttons along the top
            let foot: CGFloat = 84                                  // the button along the bottom
            let window = max(200, (g.size.height - bar) * 0.40)     // the map you see above the cards
            ZStack(alignment: .top) {
                GoMap(ride: go.arrived ? nil : go.best?.first, here: go.here,
                      top: g.safeAreaInsets.top + bar, bottom: g.safeAreaInsets.top + bar + window, saved: go.asOf != nil, newLook: true,
                      focus: mapFocus, onWalk: { walkMetres = $0 })
                    .ignoresSafeArea()
                // (the map takes your hand in its window (0.20.1): the cards scroll below it, not over it)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DS.s12) {
                        content
                    }
                    .padding(.horizontal, DS.edge).padding(.top, 10).padding(.bottom, foot + 16)
                }
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 12)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                        Color.clear.frame(height: foot - 18)
                    }
                }
                .padding(.top, bar + window - 16)
                VStack(spacing: 0) {
                    topBar.frame(height: bar)
                    Spacer(minLength: 0)
                    bottom
                }
            }
        }
        .background(DS.page.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sheet(item: $walkTo) { WalkMapSheetNew(target: $0).presentationDetents([.large]) }
        .sheet(item: $liveTrack) { LiveBusSheet(target: $0, newLook: true).presentationDetents([.large]) }
        .sheet(isPresented: $showSteady) { SteadySheetNew().presentationDetents([.large]) }
        .sheet(isPresented: $choosing) {
            DestinationSheetNew { d in live.go(to: d); go.retarget(d.place) }
        }
    }

    private var destWord: String { go.dest.short }
    /// It's on the ride you chose in Plan (not the fastest it picked itself).
    private var onChosen: Bool { go.chosen.map { $0.first.tripId == go.best?.first.tripId } ?? false }
    /// The big card's heading: "Fastest way to Breda", "For your 09:00 class", "The one you chose · to Eindhoven".
    private var heading: String {
        let to: String = goingHome ? "home" : "to \(destWord)"
        if onChosen { return "The one you chose · " + (go.deadlineLabel.map { "for \($0)" } ?? to) }
        if let l = go.deadlineLabel { return "For \(l)" }
        return "Fastest way \(to)"
    }
    /// Home is Veghel, unless you picked somewhere yourself.
    private var goingHome: Bool { go.dest == .veghel && live.custom == nil }

    // MARK: top

    private var topBar: some View {
        HStack(spacing: DS.s8) {
            DSRoundButton(icon: "chevron.left", label: "Back to the map. This stops the watching.") {
                withAnimation(.easeInOut(duration: 0.35)) { go.close() }
            }
            Spacer(minLength: 4)
            Menu {
                Button { to(.toSchool) } label: { Label("To school (BUas)", systemImage: "graduationcap.fill") }
                Button { to(.home) } label: { Label("Home (Veghel)", systemImage: "house.fill") }
                if !live.recents.isEmpty {
                    Section("Recent") {
                        ForEach(live.recents) { d in
                            Button { live.go(to: d); go.retarget(d.place) } label: { Label(d.name, systemImage: "mappin") }
                        }
                    }
                }
                Button { choosing = true } label: { Label("Somewhere else…", systemImage: "magnifyingglass") }
            } label: {
                HStack(spacing: 6) {
                    Text(goingHome ? "Home" : "To \(destWord)").font(DS.subStrong).lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .foregroundStyle(DS.text)
                .padding(.horizontal, 16).frame(minHeight: DS.hit)
                .background(DS.surface, in: Capsule())
                .dsFloat()
            }
            .accessibilityLabel("Where you’re going: \(destWord). Tap to change.")
            HStack(spacing: 6) {
                Circle().fill(go.demo ? DS.warning : go.watching ? DS.accent : DS.secondary).frame(width: 8, height: 8)
                Text(go.demo ? "Demo" : go.watching ? "Watching" : "Stopped").font(DS.footnoteStrong)
            }
            .foregroundStyle(DS.text)
            .padding(.horizontal, 12).frame(minHeight: DS.hit)
            .background(DS.surface, in: Capsule())
            .dsFloat()
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, DS.edge)
    }

    private func to(_ d: Direction) {
        live.go(to: nil)
        if trip.direction != d { withAnimation(.easeInOut(duration: 0.6)) { trip.pick(d) } }
        go.retarget(d == .toSchool ? .buas : .veghel)
    }

    // MARK: what's on it

    @ViewBuilder private var content: some View {
        if go.arrived {
            message(icon: "checkmark.circle.fill", title: "You’re at \(destWord)", text: "Nothing to catch: you’re there. It stopped watching.")
        } else if let t = go.best {
            if t.first.fromId != "onboard" { goToCard(t) }
            heroCard(t)
            watchingCard(t)
            if !go.others.isEmpty { compareCard(t) }
        } else if go.movingUnknown {
            message(icon: "tram.fill", title: "You’re going fast",
                    text: "On a train or bus? It’s finding which one, to plan from there. In a car, it plans once you stop.", spinner: true)
        } else if go.slow {
            message(icon: "wifi.exclamationmark", title: "Slow connection",
                    text: "Still getting the trips to \(destWord). It shows them as soon as they’re in.", spinner: true)
        } else if go.lookingOnBoard {
            message(icon: "bus.fill", title: "Are you on a bus or train?",
                    text: "Checking how you’re moving. If you’re on one, it plans from there: stay on, or where to change.", spinner: true)
        } else {
            message(icon: go.error == nil ? "location.magnifyingglass" : "exclamationmark.triangle.fill",
                    title: go.error == nil ? "Finding your fastest way" : "Nothing found yet",
                    text: go.error ?? "From where you are to \(destWord): every bus and train, live.", spinner: go.error == nil)
        }
        if !go.watching && !go.arrived {
            DSQuietButton(title: "Watch again", icon: "bell.badge", full: true) { go.again() }
        }
    }

    private func message(icon: String, title: String, text: String, spinner: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            HStack(spacing: 10) {
                if spinner { ProgressView().tint(DS.accentText) } else { Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(DS.accentText) }
                Text(title).font(DS.title).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
            }
            Text(text).font(DS.callout).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: the big card: when to leave, what to take

    private func heroCard(_ t: DoorTrip) -> some View {
        let f = t.first
        let info = f.isTrain ? ns.rail(f) : nil
        let st = RideText.status(f, info, saved: go.asOf != nil)      // (the saved answer doesn't say "On time")
        let track = info?.track ?? f.platform ?? ""
        let aboard = go.onBoard?.tripId == f.tripId && f.fromId == "onboard"
        let fromLine = aboard ? "Stay on until \(Fmt.place(f.toStop))" : "From \(Fmt.place(f.fromStop))" + (track.isEmpty ? "" : " · platform \(track)")
        let toName = Fmt.place(f.headsign.isEmpty ? f.toStop : f.headsign)
        let changes = t.rides.count > 1 ? " · \(t.rides.count - 1) change\(t.rides.count > 2 ? "s" : "")" : ""
        return VStack(alignment: .leading, spacing: DS.s12) {
            Text(heading)
                .font(DS.subStrong).foregroundStyle(DS.secondary).accessibilityAddTraits(.isHeader)
            // the one big number: when to set off (from the saved answer: just the time)
            TimelineView(.periodic(from: .now, by: 15)) { tl in
                let c: RideAhead.Countdown = go.asOf != nil && !aboard
                    ? .init(value: Fmt.hhmm(t.start), unit: "leave by", spoken: "Leave by \(Fmt.hhmm(t.start))")
                    : RideAhead.leave(start: t.start, aboard: aboard, now: tl.date)
                let soon = !aboard && t.start <= tl.date.addingTimeInterval(60)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if c.unit == "leave by" { Text(c.unit).font(DS.body).foregroundStyle(DS.secondary) }
                    else if !aboard && !soon { Text("Leave in").font(DS.body).foregroundStyle(DS.secondary) }
                    Text(c.value).font(DS.hero(min(big, 68))).monospacedDigit()
                        .foregroundStyle(soon ? DS.warning : DS.text)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(c.spoken)
            }
            Text("\(destWord) at \(Fmt.hhmm(t.end))" + (go.asOf.map { " · \(Snapshots.asOf($0)) · checking again…" } ?? " · \(Fmt.rideText(Double(Fmt.mins(t.end.timeIntervalSinceNow))))\(changes)"))
                .font(DS.callout).monospacedDigit().foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            // on board (planned from the bus or train you're on): what you're on, as before. Otherwise the Go to card
            // above says where to go, which one, how it runs and the walk (0.20.4).
            if f.fromId == "onboard" {
                Rectangle().fill(DS.divider).frame(height: 1)
                // what to take
                HStack(alignment: .center, spacing: DS.s12) {
                    DSLinePill(line: f.isTrain ? Transit.trainLabel(f.line) : f.line, train: f.isTrain)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(aboard ? "You’re on the" : "Take the") \(GoStore.what(f))").font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(2)
                        Text("to \(toName)").font(DS.sub).foregroundStyle(DS.text).lineLimit(1).minimumScaleFactor(0.8)
                        Text(fromLine).font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        if aboard {
                            Text("off at").font(DS.footnote).foregroundStyle(DS.secondary)
                            Text(Fmt.hhmm(f.arrival)).font(DS.bigNumber).monospacedDigit().foregroundStyle(DS.text)
                        } else {
                            Text(Fmt.hhmm(f.cancelled ? f.scheduledDeparture : f.departure)).font(DS.bigNumber).monospacedDigit().foregroundStyle(DS.text)
                                .strikethrough(f.cancelled)
                            if go.asOf == nil {             // (no countdown from the saved answer)
                                TimelineView(.periodic(from: .now, by: 15)) { tl in
                                    let m = Int((f.departure.timeIntervalSince(tl.date) / 60).rounded(.down))
                                    Text(m <= 0 ? "now" : "in \(m) min").font(DS.footnoteStrong).monospacedDigit().foregroundStyle(m <= 2 ? DS.warning : DS.secondary)
                                }
                            }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                // how it's running, and its whole route
                HStack(spacing: DS.s8) {
                    if aboard {
                        ProgressView().controlSize(.small).tint(DS.accentText)
                        Text("Making sure it’s this one: then your trip starts by itself.").font(DS.footnote).foregroundStyle(DS.text)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Circle().fill(st.warn ? DS.warning : st.ok ? DS.accent : DS.secondary).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(st.text).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(st.warn ? DS.warning : st.ok ? DS.accentText : DS.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    DSQuietButton(title: "Its route", icon: "point.topleft.down.to.point.bottomright.curvepath") {
                        liveTrack = LiveTrackTarget(tripId: f.tripId, line: f.line, headsign: f.headsign.isEmpty ? Fmt.place(f.toStop) : f.headsign,
                                                    stopName: f.fromStop, time: f.departure, rail: f.isTrain)
                    }
                    .accessibilityLabel("Its whole route, live")
                }
            }
            if let h = go.hurry {
                DSNote(icon: "figure.run", text: "Hurry: \(h.meters) m to the stop and it leaves in \(h.minutes) min. A brisk walk makes it."
                       + (go.others.first.map { " If not: \(GoStore.what($0.first)) at \(Fmt.hhmm($0.first.departure)), \(destWord) \(Fmt.hhmm($0.end))." } ?? ""))
            }
            if go.overdue {
                let alt = go.others.first
                DSNote(icon: "clock.badge.exclamationmark", text: "Due at \(Fmt.hhmm(f.departure)) and not seen leaving: it may be running late. Wait for this \(GoStore.what(f))"
                       + (alt.map { ", or take \(GoStore.what($0.first)) at \(Fmt.hhmm($0.first.departure)) (\(destWord) \(Fmt.hhmm($0.end)))." } ?? "."))
            }
            changeNote(t)
            Rectangle().fill(DS.divider).frame(height: 1)
            DSHeader(title: "Your trip")
            TripLine(trip: t, others: go.others, dest: destWord, newLook: true, rails: rails(t)) { r in
                liveTrack = LiveTrackTarget(tripId: r.tripId, line: r.line, headsign: r.headsign.isEmpty ? Fmt.place(r.toStop) : r.headsign,
                                            stopName: r.fromStop, time: r.departure, rail: r.isTrain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    /// A change you could well miss (with what it's been like, and a safer way if there is one), or why it picked one
    /// that leaves a bit earlier: a change you'll make. (As the old screen says it.)
    @ViewBuilder private func changeNote(_ t: DoorTrip) -> some View {
        if let w = Risk.weakest(t) {
            let a = t.rides[w.index - 1], n = t.rides[w.index]
            let story = DelayBook.shared.story(line: a.line, stop: a.toStop, at: a.scheduledArrival, slack: w.slack)
            let safer = go.others.filter { Risk.penalty($0) < Risk.penalty(t) - 2 }.min { $0.end < $1.end }
            // a slow bus (its speed rank B or C) wants more room: say so first
            let slow = Risk.feederGrade(a).flatMap { g in ChangeRoom.extra(afterGrade: g) > 0 ? g : nil }
            let why = slow.map { "this \(a.line) is \($0)-rank, slow on this stretch, so a change after it wants \(Int(ChangeRoom.needed(afterGrade: $0))) min" }
                ?? story.map { "the \(a.line) here was \($0)" } ?? (a.isTrain ? "trains are sometimes a few minutes late" : "buses are often a few minutes late")
            let then = safer.map { o in
                let same = Int(o.end.timeIntervalSince1970 / 60) == Int(t.end.timeIntervalSince1970 / 60)
                return " Safer: \(GoStore.what(o.first)) at \(Fmt.hhmm(o.first.departure))" + (same ? ", there at the same time." : ", there \(Fmt.hhmm(o.end)).")
            } ?? ""
            DSNote(icon: "exclamationmark.triangle.fill",
                   text: "Tight change at \(Fmt.place(n.fromStop)): \(max(0, Int(w.slack.rounded()))) min from the \(GoStore.what(a)) to the \(GoStore.what(n)), and \(why).\(then)")
        } else if let quick = go.others.filter({ $0.end < t.end && Risk.penalty($0) > Risk.penalty(t) + 2 }).min(by: { $0.end < $1.end }),
                  let w = Risk.weakest(quick) {
            let at = Fmt.place(quick.rides[w.index].fromStop)
            let mine = t.rides.indices.dropFirst().first { Fmt.place(t.rides[$0].fromStop) == at }
            let room = mine.map { i in max(0, Int((t.rides[i].departure.timeIntervalSince(t.rides[i - 1].arrival) / 60 - Double(t.rides[i].walkBefore)).rounded())) }
            DSNote(icon: "checkmark.shield.fill", tint: DS.accentText,
                   text: "A safe change: \(room.map { "\($0) min" } ?? "time") at \(at), not \(max(0, Int(w.slack.rounded()))) min with the \(GoStore.what(quick.first)) at \(Fmt.hhmm(quick.first.departure)) (there \(Fmt.hhmm(quick.end)) if it all goes right).")
        }
    }

    /// NS's word on the trip's trains (their platform now), by ride.
    private func rails(_ t: DoorTrip) -> [String: RailInfo] {
        var out: [String: RailInfo] = [:]
        for r in t.rides where r.isTrain { if let i = ns.rail(r) { out[r.id] = i } }
        return out
    }

    /// The Go to card (0.20.4): where to go for the first ride, which one it is, the walk there, Walk there (the turns)
    /// and On the map; at the stop, the wait.
    private func goToCard(_ t: DoorTrip) -> some View {
        let f = t.first
        let saved = go.asOf != nil
        let stop: CLLocationCoordinate2D? = f.fromLat.flatMap { a in f.fromLon.map { CLLocationCoordinate2D(latitude: a, longitude: $0) } }
        // (from the saved answer: just the way there, without "Leave by … (in 5 min)")
        let target: WalkTarget? = stop.map { s in
            WalkTarget(name: Fmt.place(f.fromStop), lat: s.latitude, lon: s.longitude, rail: f.isTrain,
                       catchText: saved ? nil : "the \(GoStore.what(f)) at \(Fmt.hhmm(f.departure))", leaves: saved ? nil : f.departure)
        }
        var walk: (() -> Void)? = nil
        if let tg = target { walk = { walkTo = tg } }
        return GoToCard(ride: f, info: f.isTrain ? ns.rail(f) : nil, stop: stop, here: go.here, walkMetres: walkMetres,
                        leaveBy: f.walkBefore > 0 ? t.start : nil, saved: saved,
                        hereNote: "You can see it coming on the map. It notices by itself when you get on.",
                        walk: walk,
                        onMap: { mapFocus += 1 },
                        route: {
                            liveTrack = LiveTrackTarget(tripId: f.tripId, line: f.line, headsign: f.headsign.isEmpty ? Fmt.place(f.toStop) : f.headsign,
                                                        stopName: f.fromStop, time: f.departure, rail: f.isTrain)
                        })
    }

    // MARK: it watches for you

    private func watchingCard(_ t: DoorTrip) -> some View {
        // (the saved answer isn't watched: nothing is told about it until the live one is in)
        let checking = go.watching && go.asOf != nil
        return VStack(alignment: .leading, spacing: DS.s8) {
            HStack(spacing: 10) {
                Image(systemName: checking ? "arrow.triangle.2.circlepath" : go.watching ? "bell.and.waves.left.and.right.fill" : "bell.slash.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(go.watching && !checking ? DS.accentText : DS.secondary)
                    .symbolEffect(.pulse, isActive: go.watching)
                    .accessibilityHidden(true)
                Text(checking ? "Checking for live times…" : go.watching ? "Watching the \(GoStore.what(t.first)) for you" : "Not watching any more")
                    .font(DS.headline).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            }
            if let v = go.seen {
                Label("Looks like you’re on the \(v.title)… checking.", systemImage: v.isTrain ? "tram.fill" : "bus.fill")
                    .font(DS.subStrong).foregroundStyle(DS.accentText)
            }
            if go.watching && !checking {
                Text(onChosen
                     ? "You get a notification if it runs late or leaves early. It stays with the one you chose: something faster is only noted here. Once you’re on board, your trip starts by itself."
                     : "You get a notification if it runs late or leaves early, or if something faster comes up: then it watches that one instead. Once you’re on board, your trip starts by itself.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(go.notes) { n in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Fmt.hhmm(n.at)).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.accentText)
                    Text(n.text).font(DS.sub).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if let a = go.asOf {
                Text("\(Snapshots.asOf(a)) · checking again…").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
            } else if let u = go.updated {
                Text("Checked at \(Fmt.hhmm(u)). It stops when you leave this screen.").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    // MARK: the other ways

    /// The other ways beside the fastest: when you'd leave, what you take, how long door to door, when you're there,
    /// and how much later than the fastest.
    private func compareCard(_ best: DoorTrip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.s8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Other ways").font(DS.headline).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
                    Text(go.asOf.map { Snapshots.asOf($0) } ?? "If you take another one").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                }
                Spacer(minLength: 4)
                DSQuietButton(title: "How steady", icon: "gauge.with.dots.needle.33percent") { showSteady = true }
                    .accessibilityLabel("How steady the lines are now")
            }
            .padding(.bottom, DS.s8)
            compareRow(best, best)
            ForEach(go.others) { o in compareRow(o, best) }
        }
        .dsCard()
    }

    private func compareRow(_ o: DoorTrip, _ best: DoorTrip) -> some View {
        let fastest = o.id == best.id
        // (on the one you chose: the others against it, sooner ones too)
        let later = onChosen ? ChosenRide.against(chosenEnd: best.end, o.end, isChosen: fastest) : RideAhead.later(than: best.end, o.end, fastest: fastest)
        let changes = o.rides.count - 1
        let tight = Risk.weakest(o)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: DS.s8) {
                Text(Fmt.hhmm(o.start)).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(DS.secondary).accessibilityHidden(true)
                Text(Fmt.hhmm(o.end)).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                Text(Fmt.rideText(o.end.timeIntervalSince(o.start) / 60)).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                Spacer(minLength: 4)
                Text(later).font(DS.footnoteStrong).monospacedDigit()
                    .foregroundStyle(fastest ? DS.onAccent : later == "same time" || later.hasSuffix("sooner") ? DS.text : DS.warning)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(fastest ? AnyShapeStyle(DS.accent) : AnyShapeStyle(DS.surface3), in: Capsule())
            }
            HStack(spacing: 4) {
                ForEach(Array(o.rides.enumerated()), id: \.offset) { _, r in
                    DSLinePill(line: r.isTrain ? Transit.trainLabel(r.line) : r.line, train: r.isTrain)
                }
                Text("from \(Fmt.place(o.first.fromStop))\(changes > 0 ? " · \(changes) change\(changes > 1 ? "s" : "")" : "")")
                    .font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(2)
                if let w = tight {
                    Text("tight: \(max(0, Int(w.slack.rounded()))) min").font(DS.footnoteStrong).monospacedDigit().foregroundStyle(DS.warning).fixedSize()
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Leave \(Fmt.hhmm(o.start)), \(GoStore.what(o.first)) from \(Fmt.place(o.first.fromStop))\(changes > 0 ? ", \(changes) change\(changes > 1 ? "s" : "")" : ""), there \(Fmt.hhmm(o.end)), \(later)\(tight.map { ", tight change of \(max(0, Int($0.slack.rounded()))) minutes" } ?? "")")
    }

    // MARK: bottom

    @ViewBuilder private var bottom: some View {
        Group {
            if go.arrived || go.best == nil {
                DSPrimaryButton(title: "Back to the map", icon: "map") { withAnimation(.easeInOut(duration: 0.35)) { go.close() } }
            } else if let t = go.best, RoutePlan.from(t) != nil {
                DSPrimaryButton(title: "I’m on it · start now", icon: t.first.isTrain ? "tram.fill" : "bus.fill") { go.startByHand(t) }
                    .accessibilityHint("Only if it hasn’t noticed by itself that you’re on board.")
            }
        }
        .padding(.horizontal, DS.edge).padding(.bottom, 6)
    }
}
