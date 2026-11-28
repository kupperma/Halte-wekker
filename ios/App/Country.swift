import Foundation

/// (0.42.17) Which country a stop is in, and so where its live train data comes from: NS in the Netherlands, iRail (the
/// relay's `/be/…`) in Belgium. A pure rule, the same on Android (`Country.kt`), checked on docs/belgium-vectors.json.
///
/// In this order:
///  1. A station's UIC number in its id decides: 84… the Netherlands, 88… Belgium, any other a third country. DELFI ids
///     carry it (`de-DELFI_000008400319`), SNCB's too (`be-sncb_S8821006`, `be-sncb_8400131`: Breda in SNCB's feed is
///     Dutch).
///  2. A Belgian feed (`be-sncb`, `be-delijn`, `be-stib`, `be-tec`…): Belgium.
///  3. Where it is: inside a rough outline of Belgium (drawn a little inside the Dutch border, so a Dutch stop near it
///     stays Dutch; Baarle's enclaves count as Dutch): Belgium.
///  4. Else the Netherlands (as the app always took it).
/// NS's own station list is asked first wherever a train's data is looked up (`railSource`), so nothing Dutch changes.
enum Country: String, Equatable, Sendable {
    case nl = "NL", be = "BE", other

    /// The 7-digit UIC number of a station in a stop id: a DELFI id's (its last part's digits, without the zeros it's
    /// padded with) or an SNCB id's (`be-sncb_S8821006`, `be-sncb_8812005`). Nil: none.
    static func uic(_ id: String) -> String? {
        if id.contains("DELFI") {
            let tail: String = id.split(separator: "_").last.map(String.init) ?? id
            let digits: String = String(tail.prefix { $0.isASCII && $0.isNumber })
            guard digits.count >= 7 else { return nil }
            let trimmed: String = String(digits.drop { $0 == "0" })
            return trimmed.count == 7 && trimmed.hasPrefix("8") ? trimmed : nil
        }
        guard id.hasPrefix("be-sncb_") else { return nil }
        var rest: Substring = id.dropFirst("be-sncb_".count)
        if rest.hasPrefix("S") { rest = rest.dropFirst() }
        let digits: String = String(rest.prefix { $0.isASCII && $0.isNumber })
        guard digits.count == 7, digits.hasPrefix("8") else { return nil }
        let next: Character? = rest.dropFirst(7).first
        return next == nil || !(next!.isASCII && (next!.isNumber || next!.isLetter)) ? digits : nil
    }

    /// The country of a stop (see the type).
    static func of(id: String, lat: Double?, lon: Double?) -> Country {
        if let u = uic(id) { return u.hasPrefix("84") ? .nl : u.hasPrefix("88") ? .be : .other }
        if id.hasPrefix("be-") { return .be }
        if let la = lat, let lo = lon, inBelgium(lat: la, lon: lo) { return .be }
        return .nl
    }

    /// Is a Transitous trip from a Belgian feed ("20261128_11:36_be-sncb_88…": the dataset after the date and time).
    static func belgianTrip(_ tripId: String) -> Bool {
        let parts = tripId.split(separator: "_", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].count == 8, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return parts[2].hasPrefix("be-")
    }

    /// Every stop in Belgium (none: false): the Dutch rules (check out, student OV, NS's money back) don't apply.
    static func onlyBelgium(_ stops: [(id: String, lat: Double?, lon: Double?)]) -> Bool {
        !stops.isEmpty && stops.allSatisfy { of(id: $0.id, lat: $0.lat, lon: $0.lon) == .be }
    }

    /// Where a train's live data at a station comes from: the NS station's code ("BD"), or "be:<UIC>" / "be:<name>" for
    /// iRail (by name when the UIC is one of the international 8800… codes iRail doesn't know). Nil: neither (a
    /// Belgian bus or tram stop, a third country). `ns` is NS's own lookup (`NSCodes.code(forStopId:name:)`), asked
    /// first, as before, for every stop that isn't plainly Belgian.
    static func railSource(id: String, name: String, lat: Double?, lon: Double?, ns: (String, String) -> String?) -> String? {
        let c: Country = of(id: id, lat: lat, lon: lon)
        if c == .be {
            if let u = uic(id), !u.hasPrefix("8800") { return "be:" + u }
            if id.hasPrefix("be-") && !id.hasPrefix("be-sncb") { return nil }
            let n: String = name.trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? nil : "be:" + n
        }
        if c == .other { return nil }
        return ns(id, name)
    }

    /// The relay's question for a `be:` source: `/be/liveboard?id=8821006` or `?station=Brussel-Zuid`. Nil: not one.
    static func liveboardPath(_ source: String) -> String? {
        guard source.hasPrefix("be:") else { return nil }
        let s: String = String(source.dropFirst(3))
        guard !s.isEmpty else { return nil }
        if s.count == 7, s.allSatisfy({ $0.isASCII && $0.isNumber }) { return "/be/liveboard?id=" + s }
        return "/be/liveboard?station=" + (s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s)
    }

    /// The characters a query value keeps as they are (ASCII letters and digits, "-._~"); every other is escaped.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Belgium, roughly, as (lat, lon): a little inside the Dutch border, generous towards France, Luxembourg and Germany.
    static let outline: [(Double, Double)] = [
        (51.10, 2.53), (51.37, 3.36), (51.27, 3.38), (51.23, 3.45), (51.22, 3.60), (51.20, 3.79), (51.21, 4.00), (51.24, 4.10),
        (51.27, 4.20), (51.33, 4.30), (51.35, 4.38), (51.45, 4.40), (51.475, 4.47), (51.44, 4.55), (51.42, 4.68), (51.43, 4.80),
        (51.40, 4.93), (51.42, 5.04), (51.33, 5.10), (51.28, 5.20), (51.25, 5.32), (51.23, 5.48), (51.255, 5.54), (51.22, 5.58),
        (51.20, 5.75), (51.12, 5.80), (51.00, 5.76), (50.90, 5.68), (50.83, 5.64), (50.78, 5.68), (50.76, 5.68), (50.74, 5.78),
        (50.75, 6.00), (50.62, 6.30), (50.32, 6.42), (50.13, 6.15), (49.80, 5.85), (49.50, 5.82), (49.48, 5.45), (49.70, 5.10),
        (49.90, 4.85), (50.17, 4.88), (49.95, 4.40), (50.00, 4.13), (50.32, 4.02), (50.40, 3.65), (50.55, 3.25), (50.72, 3.05),
        (50.80, 2.85), (50.75, 2.60),
    ]

    /// Inside `outline` (even-odd rule).
    static func inBelgium(lat: Double, lon: Double) -> Bool {
        guard (49.4...51.6).contains(lat), (2.4...6.5).contains(lon) else { return false }
        var inside = false
        var j: Int = outline.count - 1
        for i in outline.indices {
            let (yi, xi) = outline[i]
            let (yj, xj) = outline[j]
            if (yi > lat) != (yj > lat) {
                let x: Double = xj + (lat - yj) / (yi - yj) * (xi - xj)
                if lon < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
