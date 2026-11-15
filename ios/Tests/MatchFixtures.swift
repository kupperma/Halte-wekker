import Foundation

/// The matching tests' world: a straight east-west railway at latitude 51.59 (longitude 4.70 to about 4.80, 6.9 km),
/// roads beside it, and fixes every 2 s at 20 m accuracy.
enum Fx {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// `m` metres east of the railway's start, `north` metres north of it.
    static func east(_ m: Double, north: Double = 0) -> GeoPoint {
        GeoPoint(lat: 51.59 + north / 110_540, lon: 4.70 + m / (111_320 * cos(51.59 * .pi / 180)))
    }

    /// 3 points: a path with a shape.
    static let railway = [east(0), east(3000), east(6900)]

    /// The railway shifted north.
    static func road(north: Double) -> [GeoPoint] {
        [east(0, north: north), east(3000, north: north), east(6900, north: north)]
    }

    /// Fix k: at `start` + k·`every`, at east(`m0` + `speed`·k·`every`, north).
    static func fixes(from m0: Double, speed: Double, count: Int, every: Double = 2, north: Double = 0,
                      accuracy: Double = 20, course: Double = 90, start: Date = t0) -> [Fix] {
        (0..<count).map { k in
            let dt = Double(k) * every
            return Fix(t: start.addingTimeInterval(dt), p: east(m0 + speed * dt, north: north),
                       accuracy: accuracy, speed: speed, course: course)
        }
    }

    /// One piece over the whole path, timed so that it is `m0` metres along at `start` and goes `speed` m/s.
    static func track(_ id: String, line: String = "IC", train: Bool = true, live: Bool = true,
                      path: [GeoPoint], at m0: Double, speed: Double, start: Date = t0) -> VehicleTrack {
        let length = Geo.length(path), v = max(speed, 0.001)
        let piece = TimedPiece(departure: start.addingTimeInterval(-m0 / v), arrival: start.addingTimeInterval((length - m0) / v), path: path)
        return VehicleTrack(tripId: id, line: line, isTrain: train, realTime: live, pieces: [piece])
    }

    /// The cost, if it passed.
    static func ok(_ j: [Judgement], _ id: String) -> Double? {
        guard let r = j.first(where: { $0.id == id })?.result, case .success(let c) = r else { return nil }
        return c
    }

    /// The reject, if it failed.
    static func why(_ j: [Judgement], _ id: String) -> Reject? {
        guard let r = j.first(where: { $0.id == id })?.result, case .failure(let e) = r else { return nil }
        return e
    }
}
