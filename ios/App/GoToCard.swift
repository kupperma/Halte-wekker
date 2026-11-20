import CoreLocation
import MapKit
import SwiftUI

/// The "Go to" card (0.20.4): where to stand for the ride you have to catch, big ("Platform 5", "Stop U", or the stop's
/// name), which one it is (its line, where it goes, when, how late), the walk there, and Walk there / On the map. At the
/// stop (within about 60 m) it says you're there and how long the wait is. On Fastest trip and at a change. The words
/// come from `StopLabel`.
struct GoToCard: View {
    let ride: Ride
    var info: RailInfo? = nil
    /// Where it leaves from (nil: not known).
    var stop: CLLocationCoordinate2D? = nil
    var here: CLLocation? = nil
    /// The walk's length on foot, when the map has it.
    var walkMetres: Double? = nil
    /// No map to say it: find the walk's length here.
    var findWalk = false
    var leaveBy: Date? = nil
    /// From the saved answer: no countdown, no "on time".
    var saved = false
    /// Where it goes when it has no headsign.
    var toward: String? = nil
    /// A quiet line at the bottom ("It starts by itself once you're on board.").
    var footer: String? = nil
    /// At the stop: a quiet line under the wait.
    var hereNote: String? = nil
    /// 0.24.5: the time its GPS says it can be at the stop at the soonest, when that's clearly later than the ride's own
    /// (the map's `onLater`): the later of the two is shown, and its delay.
    var later: Date? = nil
    var walk: (() -> Void)? = nil
    var onMap: (() -> Void)? = nil
    var route: (() -> Void)? = nil
    @ScaledMetric(relativeTo: .title) private var bigSize: CGFloat = 32
    @State private var found: Double?

    private var kind: StopLabel.Kind { StopLabel.kind(isTrain: ride.isTrain, line: ride.line) }
    private var place: StopLabel.Where {
        StopLabel.make(kind: kind, stop: ride.fromStop, track: StopLabel.clean(info?.track) ?? ride.platform,
                       planned: StopLabel.clean(info?.plannedTrack) ?? ride.plannedPlatform)
    }
    private var vehicle: String { StopLabel.vehicle(kind: kind, line: ride.line, name: ride.name) }
    private var rideText: String {
        StopLabel.ride(vehicle, toward: ride.headsign.isEmpty ? (toward ?? Fmt.place(ride.toStop)) : Fmt.place(ride.headsign))
    }
    private var cancelled: Bool { ride.cancelled || info?.cancelled == true }
    /// When it leaves: the ride's time, or the later one its GPS allows.
    private var departure: Date { later.map { max($0, ride.departure) } ?? ride.departure }
    private var byGPS: Bool { departure > ride.departure }
    private var time: String { Fmt.hhmm(cancelled ? ride.scheduledDeparture : departure) }
    private var delay: (text: String, spoken: String, warn: Bool)? {
        let minutes = byGPS ? Int((departure.timeIntervalSince(ride.scheduledDeparture) / 60).rounded()) : ride.delay
        guard let d = StopLabel.delay(minutes, live: ride.live || byGPS, cancelled: cancelled) else { return nil }
        return saved && !d.warn ? nil : d              // (the saved answer doesn't say "on time")
    }
    private var away: Double? {
        guard let h = here, let s = stop else { return nil }
        return h.distance(from: CLLocation(latitude: s.latitude, longitude: s.longitude))
    }
    private var isHere: Bool { StopLabel.isHere(metres: away, walkMinutes: ride.walkBefore) }
    private var leaveText: String? { leaveBy.map(Fmt.hhmm) }

    var body: some View {
        let atStop = isHere
        VStack(alignment: .leading, spacing: DS.s12) {
            summary(here: atStop)
            buttons(here: atStop)
            if let route {
                Button(action: route) {
                    HStack(spacing: 4) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.footnote.weight(.semibold))
                        Text("Its route").font(DS.subStrong)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(DS.accentText)
                    .frame(minHeight: DS.hit).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Its whole route, live")
            }
            StudentFareLine(rides: [ride])               // (0.36) with a student travel product
            if let footer {
                Text(footer).font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .task(id: "\(ride.id)|\(self.here != nil)") {      // (again once where you are is known)
            guard findWalk, walkMetres == nil, let s = stop, (away ?? 0) > 60 else { return }
            found = await Self.walkLength(to: s)
        }
    }

    // MARK: the words (a tap on them: On the map)

    @ViewBuilder private func summary(here: Bool) -> some View {
        let w = place
        let spoken = StopLabel.spoken(w, here: here, ride: rideText, time: time, delay: delay?.spoken,
                                      walk: StopLabel.walkSpoken(minutes: ride.walkBefore, leaveBy: leaveText))
        if let onMap {
            Button(action: onMap) { words(w, here: here).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(spoken)
                .accessibilityHint("Shows the stop and your walk on the map")
        } else {
            words(w, here: here)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    private func words(_ w: StopLabel.Where, here: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(here ? "YOU’RE HERE" : "GO TO").font(DS.caption).tracking(1.2)
                    .foregroundStyle(here ? DS.accentText : DS.secondary)
                Text(w.big).font(.system(size: bigSize, weight: .bold)).foregroundStyle(DS.text)
                    .lineLimit(3).minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                if let u = w.under {
                    Text(u).font(DS.callout).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let u = w.unknownNote {
                    Text(u).font(DS.footnote).foregroundStyle(DS.secondary)
                }
                if let c = w.changeNote {
                    Label(c, systemImage: "exclamationmark.triangle.fill").font(DS.subStrong).foregroundStyle(DS.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Rectangle().fill(DS.divider).frame(height: 1)
            // which one: its line, where it goes, when, how late
            HStack(alignment: .center, spacing: DS.s12) {
                DSLinePill(line: ride.isTrain ? Transit.trainLabel(ride.line) : ride.line, train: ride.isTrain)
                Text(rideText).font(DS.bodyStrong).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(time).font(DS.bigNumber).monospacedDigit().foregroundStyle(DS.text).strikethrough(cancelled)
                    HStack(spacing: 6) {
                        if let d = delay {
                            Text(d.text).font(DS.footnoteStrong).monospacedDigit().foregroundStyle(d.warn ? DS.warning : DS.accentText)
                        } else if !ride.live && !saved {
                            Text("timetable").font(DS.footnote).foregroundStyle(DS.secondary)      // (no live times for it)
                        }
                        if !saved && !cancelled && !here {
                            TimelineView(.periodic(from: .now, by: 15)) { tl in
                                let m = Int((departure.timeIntervalSince(tl.date) / 60).rounded(.down))
                                Text(m <= 0 ? "now" : "in \(m) min").font(DS.footnoteStrong).monospacedDigit()
                                    .foregroundStyle(m <= 2 ? DS.warning : DS.secondary)
                            }
                        }
                    }
                }
            }
            // the walk there, or the wait
            if here {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.fill").font(.title3.weight(.semibold)).foregroundStyle(DS.accentText).frame(width: 28)
                        if saved || cancelled {
                            Text("Waiting for \(vehicle) · at \(time)").font(DS.calloutStrong).monospacedDigit().foregroundStyle(DS.text)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            TimelineView(.periodic(from: .now, by: 15)) { tl in
                                Text(StopLabel.waiting(vehicle, minutes: Int((departure.timeIntervalSince(tl.date) / 60).rounded(.down))))
                                    .font(DS.calloutStrong).monospacedDigit().foregroundStyle(DS.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if let hereNote {
                        Text(hereNote).font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 38)
                    }
                }
            } else if let line = StopLabel.walk(minutes: ride.walkBefore, metres: walkMetres ?? found, leaveBy: leaveText) {
                HStack(spacing: 10) {
                    Image(systemName: "figure.walk").font(.title3.weight(.semibold)).foregroundStyle(DS.accentText).frame(width: 28)
                    Text(line).font(DS.calloutStrong).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Walk there, On the map

    @ViewBuilder private func buttons(here: Bool) -> some View {
        if (!here && walk != nil) || onMap != nil {
            // side by side, or one above the other at large text
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.s8) { buttonList(here: here) }
                VStack(spacing: DS.s8) { buttonList(here: here) }
            }
        }
    }

    @ViewBuilder private func buttonList(here: Bool) -> some View {
        if !here, let walk {
            DSPrimaryButton(title: "Walk there", icon: "figure.walk", action: walk)
                .accessibilityHint("The walk to it, turn by turn")
        }
        if let onMap {
            Button(action: onMap) {
                HStack(spacing: 8) {
                    Image(systemName: "map").font(.body.weight(.semibold))
                    Text("On the map").font(DS.bodyStrong).lineLimit(1).minimumScaleFactor(0.8)
                }
                .padding(.horizontal, DS.s16)
                .foregroundStyle(DS.accentText)
                .frame(maxWidth: .infinity, minHeight: DS.cta)
                .background(DS.surface3, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(DSPressStyle())
            .accessibilityHint("Shows the stop and your walk on the map")
        }
    }

    /// Where a ride leaves from: its stop, else the place its leg starts.
    static func leavesFrom(_ r: Ride, or p: Place) -> CLLocationCoordinate2D {
        if let a = r.fromLat, let o = r.fromLon { return CLLocationCoordinate2D(latitude: a, longitude: o) }
        return p.coordinate
    }

    /// How far it is on foot from where you are (no map to ask).
    private static func walkLength(to s: CLLocationCoordinate2D) async -> Double? {
        let req = MKDirections.Request()
        req.source = MKMapItem.forCurrentLocation()
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: s))
        req.transportType = .walking
        return try? await MKDirections(request: req).calculate().routes.first?.distance
    }
}
