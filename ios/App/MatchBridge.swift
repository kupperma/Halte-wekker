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
