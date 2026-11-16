import CoreLocation
import Foundation

// The app's CoreLocation and Transitous values as the matcher's plain ones (`VehicleMatch.swift` stays Foundation-only).

extension GeoPoint {
    init(_ c: CLLocationCoordinate2D) {
        self.init(lat: c.latitude, lon: c.longitude)
    }
}

extension Fix {
    /// A GPS fix at its own time. An unknown accuracy, speed or course stays negative, as CoreLocation gives it.
    init(_ l: CLLocation) {
        self.init(t: l.timestamp, p: GeoPoint(l.coordinate), accuracy: l.horizontalAccuracy, speed: l.speed, course: l.course)
    }
}

extension MapPiece {
    /// A piece from the live map, with trains under their short label ("IC", "SPR") as everywhere else.
    init(_ s: VehicleSegment) {
        self.init(tripId: s.tripId, line: s.isTrain ? Transit.trainLabel(s.line) : s.line, isTrain: s.isTrain, realTime: s.realTime,
                  piece: TimedPiece(departure: s.departure, arrival: s.arrival, path: s.path.map { GeoPoint($0) }))
    }
}

extension VehicleTrack {
    /// A trip's own stops and road as a track: a piece per pair of stops, from when it leaves the first (its departure)
    /// to when it gets to the next (its arrival), along its road between them. Live when the trip's times are. Nil when
    /// no pair of stops gives a piece (no times, or no road between them).
    init?(tripId: String, line: String, isTrain: Bool, trip: LiveTrip) {
        var pieces: [TimedPiece] = []
        for i in trip.stops.indices.dropLast() {
            guard let departure = trip.departure(i), let arrival = trip.arrival(i + 1) else { continue }
            let road = trip.road(from: trip.metres(ofStop: i), to: trip.metres(ofStop: i + 1))
            guard road.count >= 2 else { continue }
            pieces.append(TimedPiece(departure: departure, arrival: arrival, path: road.map { GeoPoint($0) }))
        }
        guard !pieces.isEmpty else { return nil }
        self.init(tripId: tripId, line: line, isTrain: isTrain, realTime: trip.live, pieces: pieces)
    }
}

extension LiveTrip.Stop {
    /// Its times as the no-catch-up rules take them (`scheduled` for a stop that has only that).
    var times: StopTimes {
        StopTimes(arrival: arrival, departure: departure,
                  scheduledArrival: scheduledArrival ?? (scheduledDeparture == nil ? scheduled : nil), scheduledDeparture: scheduledDeparture)
    }
}

extension LiveTrip {
    /// A late bus without catching up (`LiveTimes.noCatchUp`): what to draw it by, and what the matcher judges it by.
    /// As it is for a train, or without live times; the same trip when nothing changes.
    func noCatchUp(asOf: Date, isTrain: Bool) -> LiveTrip {
        guard !isTrain, live else { return self }
        let given = stops.map(\.times)
        let fixed = LiveTimes.noCatchUp(given, asOf: asOf)
        guard fixed != given else { return self }
        let moved = zip(stops, fixed).map { s, t in
            LiveTrip.Stop(name: s.name, coordinate: s.coordinate, arrival: t.arrival, departure: t.departure, scheduled: s.scheduled,
                          scheduledArrival: s.scheduledArrival, scheduledDeparture: s.scheduledDeparture)
        }
        return LiveTrip(line: line, headsign: headsign, live: live, stops: moved, path: path)
    }
}

extension Transit {
    /// The live map's pieces with late buses not catching up (`LiveTimes.noCatchUp(pieces:)`), trip by trip, in the
    /// order given. Trains, trips without live times and pieces without timetable times stay as they are.
    static func noCatchUp(_ segs: [VehicleSegment], asOf: Date) -> [VehicleSegment] {
        var out = segs
        let byTrip = Dictionary(grouping: segs.indices.filter { !segs[$0].isTrain }, by: { segs[$0].tripId })
        for (_, idx) in byTrip {
            guard idx.contains(where: { segs[$0].realTime }),
                  idx.allSatisfy({ segs[$0].scheduledDeparture != nil && segs[$0].scheduledArrival != nil }) else { continue }
            // each piece once (one that comes twice counts once, as the matcher has it), in departure order
            var given: [PieceTimes] = [], slot: [Int: Int] = [:], seen: [String: Int] = [:]
            for i in idx.sorted(by: { segs[$0].departure != segs[$1].departure ? segs[$0].departure < segs[$1].departure : $0 < $1 }) {
                let s = segs[i]
                let key = "\(s.departure.timeIntervalSince1970)|\(s.arrival.timeIntervalSince1970)|\(s.fromName)|\(s.toName)"
                if let k = seen[key] { slot[i] = k; continue }
                seen[key] = given.count; slot[i] = given.count
                given.append(PieceTimes(departure: s.departure, arrival: s.arrival,
                                        scheduledDeparture: s.scheduledDeparture, scheduledArrival: s.scheduledArrival))
            }
            let fixed = LiveTimes.noCatchUp(pieces: given, asOf: asOf)
            for (i, k) in slot where fixed[k] != given[k] {
                let s = segs[i], t = fixed[k]
                out[i] = VehicleSegment(tripId: s.tripId, line: s.line, isTrain: s.isTrain, fromName: s.fromName, toName: s.toName,
                                        departure: t.departure, arrival: t.arrival, path: s.path, realTime: s.realTime,
                                        toLat: s.toLat, toLon: s.toLon, scheduledDeparture: s.scheduledDeparture, scheduledArrival: s.scheduledArrival)
            }
        }
        return out
    }
}
