import Foundation

struct OFFProduct: Equatable {
    var name: String?
    var proteinPerPack: Double?
    /// One slice, piece or portion, when Open Food Facts knows the serving.
    var portion: Portion? = nil
    /// How many of those portions are in a pack, when the pack and the serving are both weighed (1…200).
    var portionsPerPack: Double? = nil
    var energy = Energy()
}

/// kcal in a pack and in one portion, as far as Open Food Facts knows (each 0…5000).
struct Energy: Equatable {
    var perPack: Double? = nil
    var perPortion: Double? = nil
}

enum LookupResult: Equatable {
    case found(name: String, proteinPerPack: Double, portion: Portion? = nil, energy: Energy = Energy())
    /// No believable protein per pack. What else is known still comes along, to keep once the label is typed.
    case needsProtein(name: String?, portion: Portion? = nil, energy: Energy = Energy())
    case offline
}

enum OpenFoodFacts {
    static let userAgent = "Haltewekker/1.0 (iPhone app)"
    static let fallbackName = "Product"

    private static func isDigit(_ u: Unicode.Scalar) -> Bool { u.value >= 0x30 && u.value <= 0x39 }

    /// ASCII digits only, 8...14 long. Checked per scalar: "5" with a combining mark is one Character but not a digit.
    static func isBarcode(_ s: String) -> Bool {
        let scalars = s.unicodeScalars
        guard (8...14).contains(scalars.count) else { return false }
        return scalars.allSatisfy(isDigit)
    }

    /// Only the ASCII digits in `s`, so a pasted "87 10400 …" still works.
    static func digits(in s: String) -> String {
        String(s.unicodeScalars.filter(isDigit).map { Character($0) })
    }

    /// nil for anything that isn't a barcode.
    static func url(for barcode: String) -> URL? {
        guard isBarcode(barcode) else { return nil }
        let fields = "product_name,brands,product_quantity,product_quantity_unit,serving_size,serving_quantity,nutriments"
        return URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json?fields=\(fields)")
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = v as? String {
            return Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    /// A number from 0 up and finite, or nil.
    private static func nonNegative(_ v: Any?) -> Double? {
        guard let n = number(v), n.isFinite, n >= 0 else { return nil }
        return n
    }

    /// kcal from a nutriment: "energy-kcal_…", else "energy_…" (kJ) ÷ 4.184.
    private static func kcal(_ nutriments: [String: Any]?, _ suffix: String) -> Double? {
        nonNegative(nutriments?["energy-kcal_" + suffix]) ?? nonNegative(nutriments?["energy_" + suffix]).map { $0 / 4.184 }
    }

    /// A number above 0 and finite, or nil: "", "0", "inf" and the like are missing.
    private static func positive(_ v: Any?) -> Double? {
        guard let n = number(v), n.isFinite, n > 0 else { return nil }
        return n
    }

    private static func text(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// `t` begins with the word `w`, ignoring case: "AH Magere kwark" begins with "ah", "Ahornsirup" doesn't begin with "AH".
    private static func startsWith(_ t: String, word w: String) -> Bool {
        guard let r = t.range(of: w, options: [.caseInsensitive, .anchored]) else { return false }
        guard r.upperBound < t.endIndex else { return true }
        let next = t[r.upperBound]
        return !(next.isLetter || next.isNumber)
    }

    /// nil when status != 1 or the JSON is bad.
    static func parse(_ data: Data) -> OFFProduct? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              number(root["status"]) == 1,
              let product = root["product"] as? [String: Any] else { return nil }

        let brand = text(product["brands"])?
            .split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let title = text(product["product_name"])
        let name: String?
        switch (brand, title) {
        case let (b?, t?): name = startsWith(t, word: b) ? t : "\(b) \(t)"     // "AH" + "AH Magere kwark" once
        case let (b?, nil): name = b
        case let (nil, t?): name = t
        default: name = nil
        }

        let nutriments = product["nutriments"] as? [String: Any]
        let per100 = positive(nutriments?["proteins_100g"])
        let quantity = positive(product["product_quantity"])
        let unit = text(product["product_quantity_unit"])
        var pack = ProteinMath.perPack(proteinPer100: per100, quantity: quantity, unit: unit)

        // One serving: "2 Scheiben (25 g)" is two slices of 12,5 g, so one slice is half of it.
        let served = serving(text(product["serving_size"]))
        let servingGrams = positive(product["serving_quantity"])
        let servingProtein = positive(nutriments?["proteins_serving"])
            ?? servingGrams.flatMap { g in per100.map { $0 * g / 100 } }
        var portion = Portion(name: served.name, protein: servingProtein.map { $0 / served.count })

        let packGrams = quantity.map { ["kg", "l"].contains(unit?.lowercased() ?? "") ? $0 * 1000 : $0 }
        var portionsPerPack: Double?
        if let pg = packGrams, let g = servingGrams {
            let n = pg / (g / served.count)
            if n.isFinite, Portion.perPackRange.contains(n) { portionsPerPack = n }
        }
        // No protein per 100 g, but per serving: the pack is its portions.
        if pack == nil, let p = portion, let n = portionsPerPack {
            let g = p.protein * n
            if g.isFinite, ProteinMath.packRange.contains(g) { pack = g }
        }
        // A portion that is about the whole pack (or more) is no help: count by the pack.
        if let p = portion, let whole = pack, !p.isPart(of: whole) { portion = nil }

        // Calories the same way: per 100 g (or kJ), per serving, the pack from its portions when needed.
        let kcal100 = kcal(nutriments, "100g")
        let kcalServing = kcal(nutriments, "serving") ?? servingGrams.flatMap { g in kcal100.map { $0 * g / 100 } }
        let kcalPortion = portion == nil ? nil : KcalMath.sane(kcalServing.map { $0 / served.count })
        var kcalPack = packGrams.flatMap { g in kcal100.map { $0 * g / 100 } }
        if kcalPack == nil, let k = kcalPortion, let n = portionsPerPack { kcalPack = k * n }
        let energy = Energy(perPack: KcalMath.sane(kcalPack), perPortion: kcalPortion)

        return OFFProduct(name: name, proteinPerPack: pack, portion: portion, portionsPerPack: portionsPerPack,
                          energy: energy)
    }

    /// What one serving is called, in English, and how many of those it is: "2 Scheiben (25 g)" → ("slice", 2),
    /// "1 stuk" → ("piece", 1), "30 g (1 Scheibe)" → ("slice", 1). "40 g", "1 Becher" or nothing → ("portion", 1).
    static func serving(_ text: String?) -> (name: String, count: Double) {
        let fallback = (name: PortionName.portion, count: 1.0)
        guard let t = text, !t.isEmpty else { return fallback }
        // The words before the bracket, then the ones in it.
        var parts = [t[..<(t.firstIndex(of: "(") ?? t.endIndex)]]
        if let open = t.firstIndex(of: "(") {
            let inside = t[t.index(after: open)...]
            parts.append(inside[..<(inside.firstIndex(of: ")") ?? inside.endIndex)])
        }
        for part in parts {
            var words = tokens(String(part))[...]
            var count = 1.0
            if let first = words.first, let n = Double(first) {
                count = n
                words = words.dropFirst()
            }
            // A whole count from 1 to 50, then a word it knows ("g" or "Becher" isn't one).
            guard let word = words.first, let name = PortionName.english(word),
                  count.isFinite, count >= 1, count <= 50, count == count.rounded() else { continue }
            return (name, count)
        }
        return fallback
    }

    /// Runs of ASCII digits (a "," read as ".") and runs of letters: "2Scheiben (12,5g)" → ["2", "Scheiben", "12.5", "g"].
    private static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inNumber = false
        for ch in s {
            let digit = ch.isASCII && (ch.isNumber || ch == "." || ch == ",")
            guard digit || ch.isLetter else {
                if !current.isEmpty { out.append(current) }
                current = ""
                continue
            }
            if !current.isEmpty, digit != inNumber {
                out.append(current)
                current = ""
            }
            current.append(ch == "," ? "." : ch)
            inNumber = digit
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func lookup(_ barcode: String,
                       fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) async -> LookupResult {
        guard let url = url(for: barcode) else { return .needsProtein(name: nil) }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            return .offline
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .needsProtein(name: nil)
        }
        guard let product = parse(data) else { return .needsProtein(name: nil) }
        // perPack already leaves out a pack that can't be (infinite, 0, or over 1 kg of protein); checked again here.
        guard let protein = product.proteinPerPack, protein.isFinite, ProteinMath.packRange.contains(protein) else {
            return .needsProtein(name: product.name, portion: product.portion, energy: product.energy)
        }
        // Protein known but no name: still usable, with a generic name.
        return .found(name: product.name ?? fallbackName, proteinPerPack: protein, portion: product.portion,
                      energy: product.energy)
    }
}
