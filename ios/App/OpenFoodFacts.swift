import Foundation

struct OFFProduct: Equatable {
    var name: String?
    var proteinPerPack: Double?
}

enum LookupResult: Equatable {
    case found(name: String, proteinPerPack: Double)
    case needsProtein(name: String?)
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
        let fields = "product_name,brands,product_quantity,product_quantity_unit,nutriments"
        return URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json?fields=\(fields)")
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = v as? String {
            return Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        return nil
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
        let pack = ProteinMath.perPack(
            proteinPer100: number(nutriments?["proteins_100g"]),
            quantity: number(product["product_quantity"]),
            unit: text(product["product_quantity_unit"]))
        return OFFProduct(name: name, proteinPerPack: pack)
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
            return .needsProtein(name: product.name)
        }
        // Protein known but no name: still usable, with a generic name.
        return .found(name: product.name ?? fallbackName, proteinPerPack: protein)
    }
}
