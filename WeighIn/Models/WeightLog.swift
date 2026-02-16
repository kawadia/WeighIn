import Foundation

enum WeightUnit: String, CaseIterable, Codable {
    case lbs
    case kg

    var label: String {
        switch self {
        case .lbs: return "lbs"
        case .kg: return "kg"
        }
    }
}

enum WeightLogSource: String, Codable {
    case manual
    case past
    case csv
    case health
}

struct WeightLog: Identifiable, Codable, Hashable {
    let id: String
    let timestamp: Date
    let weight: Double
    let unit: WeightUnit
    let source: WeightLogSource
    let noteID: String?

    init(
        id: String = UUID().uuidString,
        timestamp: Date,
        weight: Double,
        unit: WeightUnit,
        source: WeightLogSource,
        noteID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.weight = weight
        self.unit = unit
        self.source = source
        self.noteID = noteID
    }
}
