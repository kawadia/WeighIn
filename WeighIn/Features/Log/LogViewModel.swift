import Foundation

@MainActor
final class LogViewModel: ObservableObject {
    @Published var weightInput: String = ""
    @Published var noteInput: String = ""
    @Published var entryTimestamp: Date = Date()
    @Published var lastSaveMessage = ""

    private var lastSavedNoteID: String?

    var parsedWeight: Double? {
        Double(weightInput)
    }

    func handleKey(_ key: String) {
        switch key {
        case "⌫":
            guard !weightInput.isEmpty else { return }
            weightInput.removeLast()
        case ".":
            guard !weightInput.contains(".") else { return }
            weightInput = weightInput.isEmpty ? "0." : weightInput + "."
        default:
            guard weightInput.count < 7 else { return }
            if key == "0", weightInput == "0" {
                return
            }
            if weightInput == "0" {
                weightInput = key
            } else {
                weightInput.append(key)
            }
        }
    }

    func saveCurrentWeight(using repository: AppRepository) {
        guard let weight = parsedWeight, weight > 0 else { return }
        repository.addWeightLog(
            weight: weight,
            timestamp: entryTimestamp,
            noteText: nil,
            source: .manual
        )
        weightInput = ""
        entryTimestamp = Date()
    }

    func saveNoteNow(using repository: AppRepository) {
        lastSavedNoteID = repository.upsertStandaloneNote(
            id: lastSavedNoteID,
            text: noteInput,
            timestamp: Date()
        )
        if !noteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastSaveMessage = "Saved \(DateFormatting.shortDateTime.string(from: Date()))"
        }
    }
}
