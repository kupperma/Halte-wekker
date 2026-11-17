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
    /// Its times as the no-catch-up rules take them.
    var times: StopTimes {
        StopTimes(arrival: arrival, departure: departure, scheduled: scheduled, scheduledArrival: scheduledArrival, scheduledDeparture: scheduledDeparture)
    }
}

extension LiveTrip {
    /// A late bus, coach or tram without catching up (`LiveTimes.noCatchUp`): what to draw it by, and what the matcher
    /// judges it by. As it is for a train (`isTrain` when its mode isn't known), or without live times.
    func noCatchUp(asOf: Date, isTrain: Bool) -> LiveTrip {
        guard live, LiveTimes.carriesDelay(mode: mode, isTrain: isTrain) else { return self }
        let given = stops.map(\.times)
        let fixed = LiveTimes.noCatchUp(given, asOf: asOf)
        guard fixed != given else { return self }
        let moved = zip(stops, fixed).map { s, t in
            LiveTrip.Stop(name: s.name, coordinate: s.coordinate, arrival: t.arrival, departure: t.departure, scheduled: s.scheduled,
                          scheduledArrival: s.scheduledArrival, scheduledDeparture: s.scheduledDeparture)
        }
        var out = LiveTrip(line: line, headsign: headsign, live: live, stops: moved, path: path, mode: mode)
        out.num = num
        return out
    }
}

extension Transit {
    /// The live map's pieces with late buses, coaches and trams not catching up (`LiveTimes.noCatchUp(trips:)`), in
    /// the order given.
    static func noCatchUp(_ segs: [VehicleSegment], asOf: Date) -> [VehicleSegment] {
        let given = segs.map { s in
            TripPiece(trip: s.tripId, carries: LiveTimes.carriesDelay(mode: s.mode, isTrain: s.isTrain), live: s.realTime,
                      times: PieceTimes(departure: s.departure, arrival: s.arrival, scheduledDeparture: s.scheduledDeparture, scheduledArrival: s.scheduledArrival),
                      stops: "\(s.fromName)|\(s.toName)")
        }
        let fixed = LiveTimes.noCatchUp(trips: given, asOf: asOf)
        return zip(segs, zip(given, fixed)).map { s, gf in
            guard gf.1 != gf.0.times else { return s }
            return VehicleSegment(tripId: s.tripId, line: s.line, isTrain: s.isTrain, fromName: s.fromName, toName: s.toName,
                                  departure: gf.1.departure, arrival: gf.1.arrival, path: s.path, realTime: s.realTime,
                                  toLat: s.toLat, toLon: s.toLon, scheduledDeparture: s.scheduledDeparture, scheduledArrival: s.scheduledArrival,
                                  mode: s.mode)
        }
    }
}
