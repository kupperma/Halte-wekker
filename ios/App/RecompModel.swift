import Foundation

/// One weigh-in or waist measurement on a recomp day.
struct Measure: Codable, Equatable {
    var day: DayKey
    var value: Double
}

enum AdviceKind: String, Codable {
    case eatLess, eatMore
}

/// Advice that stays on screen until the person taps "adjusted" (or three weeks pass).
struct PendingAdvice: Codable, Equatable {
    var kind: AdviceKind
    /// A Monday.
    var shownOn: DayKey
}

struct CheckState: Codable, Equatable {
    var pending: PendingAdvice? = nil
    var baseline: DayKey? = nil
}

/// Coding key by name, so a custom decoder can read every property with `decodeIfPresent`.
private struct RecompKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension CheckState {
    /// Missing keys decode to their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RecompKey.self)
        pending = try c.decodeIfPresent(PendingAdvice.self, forKey: RecompKey("pending"))
        baseline = try c.decodeIfPresent(DayKey.self, forKey: RecompKey("baseline"))
    }
}

// MARK: - Stored data

struct ProteinSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var unit: String
    var units: String
    var gramsPerUnit: Double
    var step: Double
    var barcode: String? = nil
    var kcalPerUnit: Double = 0
}

/// A logged amount. It keeps its own grams-per-unit and labels, so editing or deleting a source later changes nothing here.
struct ProteinEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var at: Date
    var name: String
    var unit: String
    var units: String
    var amount: Double
    var gramsPerUnit: Double
    /// Kept from when it was logged, like the grams.
    var kcalPerUnit: Double = 0
    var grams: Double { amount * gramsPerUnit }
    var kcal: Double { amount * kcalPerUnit }

    /// "Add kcal": food that isn't a source, logged as its kcal (`amount`) with no protein.
    var isOtherFood: Bool { unit == ProteinEntry.kcalUnit && gramsPerUnit == 0 }
    static let kcalUnit = "kcal"
    static let otherFood = "Other food"
}

struct Habit: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
}

struct KnownProduct: Codable, Equatable {
    var name: String
    var proteinPerPack: Double
    /// "slice", "piece", "portion" or "bar", once the pack is counted by portion.
    var portionName: String? = nil
    /// Grams of protein in one of those.
    var proteinPerPortion: Double? = nil
    var kcalPerPack: Double? = nil
    /// From Open Food Facts' serving. Without it, a portion's kcal is its share of the pack's.
    var kcalPerPortion: Double? = nil

    /// One portion, when both its name and a believable protein are known.
    var portion: Portion? { Portion(name: portionName, protein: proteinPerPortion) }

    /// kcal in a pack, when known and believable (0…5000).
    var packKcal: Double? { KcalMath.sane(kcalPerPack) }

    /// kcal in one portion: as stored, else the portion's share of the pack (by its protein).
    var portionKcal: Double? {
        guard let portion else { return nil }
        if let k = KcalMath.sane(kcalPerPortion) { return k }
        guard let pack = packKcal, proteinPerPack > 0, proteinPerPack.isFinite else { return nil }
        return KcalMath.sane(pack * portion.protein / proteinPerPack)
    }
}

/// One slice, piece or portion of a scanned product, and the protein in it.
struct Portion: Equatable {
    let name: String
    let protein: Double

    /// "slices"
    var units: String { PortionName.plural(name) }

    /// What one portion can sensibly hold, in grams of protein. Outside it the numbers are wrong.
    static let proteinRange: ClosedRange<Double> = 0.1...300
    /// How many portions a pack can sensibly hold.
    static let perPackRange: ClosedRange<Double> = 1...200

    /// nil without a name, or with a protein that isn't finite and inside `proteinRange`.
    init?(name: String?, protein: Double?) {
        guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty,
              let g = protein, g.isFinite, Portion.proteinRange.contains(g) else { return nil }
        self.name = n
        self.protein = g
    }

    /// A pack counted by hand: `count` portions (1…200) share its protein.
    static func split(pack: Double, into count: Int, name: String) -> Portion? {
        guard pack.isFinite, pack > 0, perPackRange.contains(Double(count)) else { return nil }
        return Portion(name: name, protein: pack / Double(count))
    }

    /// Clearly less than the whole pack. A "portion" of about the whole pack (a single yoghurt) is just the pack.
    func isPart(of pack: Double) -> Bool {
        pack.isFinite && protein < pack * 0.9
    }
}

/// What a portion of a scanned product is called, always in English.
enum PortionName {
    static let portion = "portion"
    /// To pick from when counting a pack by hand, the most used first.
    static let choices = ["slice", "piece", "portion"]

    /// "slices": the name with an "s"; "portions" without a name.
    static func plural(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "portions" : n + "s"
    }

    /// "Scheiben" → "slice", "stuk" → "piece", "Portie" → "portion", "Riegel" → "bar". nil for any other word.
    static func english(_ word: String) -> String? {
        words[word.lowercased()]
    }

    private static let words: [String: String] = {
        var w: [String: String] = [:]
        for s in ["slice", "slices", "scheibe", "scheiben", "scheibchen", "plak", "plakje", "plakjes", "plakken",
                  "snee", "sneetje", "sneetjes", "sneden", "tranche", "tranches"] { w[s] = "slice" }
        for s in ["piece", "pieces", "stuk", "stuks", "stukje", "stukjes", "stück", "stueck", "stk"] { w[s] = "piece" }
        for s in ["portion", "portions", "portionen", "portie", "porties"] { w[s] = "portion" }
        for s in ["bar", "bars", "riegel", "reep", "reepje", "repen"] { w[s] = "bar" }
        return w
    }()
}

enum RecompDefaults {
    static let sources: [ProteinSource] = [
        ProteinSource(name: "Kwark", unit: "tub", units: "tubs", gramsPerUnit: 42, step: 0.25, kcalPerUnit: 280),
        ProteinSource(name: "Eggs", unit: "egg", units: "eggs", gramsPerUnit: 6.5, step: 1, kcalPerUnit: 72),
        ProteinSource(name: "Milk", unit: "glass", units: "glasses", gramsPerUnit: 8, step: 1, kcalPerUnit: 115),
        ProteinSource(name: "Tuna", unit: "can", units: "cans", gramsPerUnit: 25, step: 1, kcalPerUnit: 130),
        ProteinSource(name: "Chicken", unit: "portion", units: "portions", gramsPerUnit: 27, step: 1, kcalPerUnit: 250),
        ProteinSource(name: "Beans & lentils", unit: "can", units: "cans", gramsPerUnit: 18, step: 0.5, kcalPerUnit: 250),
        ProteinSource(name: "Whey", unit: "scoop", units: "scoops", gramsPerUnit: 22, step: 1, kcalPerUnit: 120),
    ]
    /// kcal per unit of a default source ("Kwark" per 500 g tub: 280), by name and unit; 0 for any other.
    static func kcalPerUnit(name: String, unit: String) -> Double {
        sources.first { $0.name.lowercased() == name.lowercased() && $0.unit.lowercased() == unit.lowercased() }?
            .kcalPerUnit ?? 0
    }

    static let habits: [Habit] = [
        Habit(title: "Only zero drinks"),
        Habit(title: "Half the plate veg"),
        Habit(title: "Oil and sauce measured"),
        Habit(title: "Nothing straight from the bag"),
        Habit(title: "One planned treat"),
    ]
}

struct RecompData: Codable, Equatable {
    var goal: Double = 160
    var sources: [ProteinSource] = RecompDefaults.sources
    var habits: [Habit] = RecompDefaults.habits
    var entries: [ProteinEntry] = []
    var habitsDone: [DayKey: [UUID]] = [:]
    var weights: [Measure] = []
    var waists: [Measure] = []
    var waistSkippedOn: DayKey? = nil
    var check = CheckState()
    var products: [String: KnownProduct] = [:]   // barcode → product
    var calories = CalorieSettings()
    static let maxSources = 7, maxHabits = 5
}

/// The daily kcal limit and its notice.
struct CalorieSettings: Codable, Equatable {
    /// The limit as last set by hand (or moved ±200 by the weekly check)…
    var anchorLimit: Double = KcalMath.defaultLimit
    /// …and the week average at that moment. nil until there is one; the first one there is then.
    var anchorWeight: Double? = nil
    /// The limit moves 15 kcal per kg the week average is off `anchorWeight`.
    var followsWeight = true
    var notify = true
    /// The day the notice went out: once a day at most.
    var notifiedOn: DayKey? = nil
}

// MARK: - Tolerant decoding (a missing key decodes to its default, never throws)

extension ProteinSource {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RecompKey.self)
        id = try c.decodeIfPresent(UUID.self, forKey: RecompKey("id")) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: RecompKey("name")) ?? ""
        unit = try c.decodeIfPresent(String.self, forKey: RecompKey("unit")) ?? ""
        units = try c.decodeIfPresent(String.self, forKey: RecompKey("units")) ?? ""
        gramsPerUnit = try c.decodeIfPresent(Double.self, forKey: RecompKey("gramsPerUnit")) ?? 0
        step = try c.decodeIfPresent(Double.self, forKey: RecompKey("step")) ?? 1
        barcode = try c.decodeIfPresent(String.self, forKey: RecompKey("barcode"))
        // Added in 0.17.1: a default source gets its default, any other 0.
        kcalPerUnit = (try? c.decodeIfPresent(Double.self, forKey: RecompKey("kcalPerUnit")))
            ?? RecompDefaults.kcalPerUnit(name: name, unit: unit)
    }
}

extension ProteinEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RecompKey.self)
        id = try c.decodeIfPresent(UUID.self, forKey: RecompKey("id")) ?? UUID()
        at = try c.decodeIfPresent(Date.self, forKey: RecompKey("at")) ?? Date(timeIntervalSince1970: 0)
        name = try c.decodeIfPresent(String.self, forKey: RecompKey("name")) ?? ""
        unit = try c.decodeIfPresent(String.self, forKey: RecompKey("unit")) ?? ""
        units = try c.decodeIfPresent(String.self, forKey: RecompKey("units")) ?? ""
        amount = try c.decodeIfPresent(Double.self, forKey: RecompKey("amount")) ?? 0
        gramsPerUnit = try c.decodeIfPresent(Double.self, forKey: RecompKey("gramsPerUnit")) ?? 0
        // Logged before 0.17.1: what a default source has, so this morning's eggs still count.
        kcalPerUnit = (try? c.decodeIfPresent(Double.self, forKey: RecompKey("kcalPerUnit")))
            ?? RecompDefaults.kcalPerUnit(name: name, unit: unit)
    }
}

extension Habit {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RecompKey.self)
        id = try c.decodeIfPresent(UUID.self, forKey: RecompKey("id")) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: RecompKey("title")) ?? ""
    }
}

extension KnownProduct {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RecompKey.self)
        name = try c.decodeIfPresent(String.self, forKey: RecompKey("name")) ?? ""
        proteinPerPack = try c.decodeIfPresent(Double.self, forKey: RecompKey("proteinPerPack")) ?? 0
        // Added in 0.17.1. Missing, or not what's expected: no portion, and everything else still loads.
        portionName = try? c.decodeIfPresent(String.self, forKey: RecompKey("portionName"))
        proteinPerPortion = try? c.decodeIfPresent(Double.self, forKey: RecompKey("proteinPerPortion"))
        kcalPerPack = try? c.decodeIfPresent(Double.self, forKey: RecompKey("kcalPerPack"))
        kcalPerPortion = try? c.decodeIfPresent(Double.self, forKey: RecompKey("kcalPerPortion"))
    }
}

extension CalorieSettings {
    /// Missing keys (or ones of the wrong type) decode to their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RecompKey.self)
        anchorLimit = (try? c.decodeIfPresent(Double.self, forKey: RecompKey("anchorLimit")))
            .map(KcalMath.clampLimit) ?? KcalMath.defaultLimit
        anchorWeight = try? c.decodeIfPresent(Double.self, forKey: RecompKey("anchorWeight"))
        followsWeight = (try? c.decodeIfPresent(Bool.self, forKey: RecompKey("followsWeight"))) ?? true
        notify = (try? c.decodeIfPresent(Bool.self, forKey: RecompKey("notify"))) ?? true
        notifiedOn = try? c.decodeIfPresent(DayKey.self, forKey: RecompKey("notifiedOn"))
    }
}

extension RecompData {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RecompKey.self)
        goal = try c.decodeIfPresent(Double.self, forKey: RecompKey("goal")) ?? 160
        sources = try c.decodeIfPresent([ProteinSource].self, forKey: RecompKey("sources")) ?? RecompDefaults.sources
        habits = try c.decodeIfPresent([Habit].self, forKey: RecompKey("habits")) ?? RecompDefaults.habits
        entries = try c.decodeIfPresent([ProteinEntry].self, forKey: RecompKey("entries")) ?? []
        habitsDone = try c.decodeIfPresent([DayKey: [UUID]].self, forKey: RecompKey("habitsDone")) ?? [:]
        weights = try c.decodeIfPresent([Measure].self, forKey: RecompKey("weights")) ?? []
        waists = try c.decodeIfPresent([Measure].self, forKey: RecompKey("waists")) ?? []
        waistSkippedOn = try c.decodeIfPresent(DayKey.self, forKey: RecompKey("waistSkippedOn"))
        check = try c.decodeIfPresent(CheckState.self, forKey: RecompKey("check")) ?? CheckState()
        products = try c.decodeIfPresent([String: KnownProduct].self, forKey: RecompKey("products")) ?? [:]
        calories = (try? c.decodeIfPresent(CalorieSettings.self, forKey: RecompKey("calories"))) ?? CalorieSettings()
    }
}
