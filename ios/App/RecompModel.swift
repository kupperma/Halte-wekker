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

// MARK: - Stored data

struct ProteinSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var unit: String
    var units: String
    var gramsPerUnit: Double
    var step: Double
    var barcode: String? = nil
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
    var grams: Double { amount * gramsPerUnit }
}

struct Habit: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
}

struct KnownProduct: Codable, Equatable {
    var name: String
    var proteinPerPack: Double
}

enum RecompDefaults {
    static let sources: [ProteinSource] = [
        ProteinSource(name: "Kwark", unit: "tub", units: "tubs", gramsPerUnit: 42, step: 0.25),
        ProteinSource(name: "Eggs", unit: "egg", units: "eggs", gramsPerUnit: 6.5, step: 1),
        ProteinSource(name: "Milk", unit: "glass", units: "glasses", gramsPerUnit: 8, step: 1),
        ProteinSource(name: "Tuna", unit: "can", units: "cans", gramsPerUnit: 25, step: 1),
        ProteinSource(name: "Chicken", unit: "portion", units: "portions", gramsPerUnit: 27, step: 1),
        ProteinSource(name: "Beans & lentils", unit: "can", units: "cans", gramsPerUnit: 18, step: 0.5),
        ProteinSource(name: "Whey", unit: "scoop", units: "scoops", gramsPerUnit: 22, step: 1),
    ]
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
    static let maxSources = 7, maxHabits = 5
}
