import Foundation

@MainActor
final class LogViewModel: ObservableObject {
    @Published var weightInput: String = ""
    @Published var noteInput: String = ""
    @Published var entryTimestamp: Date = Date()
    @Published var autosaveNotes = true
    @Published var lastAutosaveMessage = ""

    private var autosaveTask: Task<Void, Never>?
    private var autosavedNoteID: String?

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
        autosaveTask?.cancel()
        autosavedNoteID = repository.upsertStandaloneNote(
            id: autosavedNoteID,
            text: noteInput,
            timestamp: Date()
        )
        if !noteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastAutosaveMessage = "Saved \(DateFormatting.shortDateTime.string(from: Date()))"
        }
    }

    func noteChanged(using repository: AppRepository) {
        guard autosaveNotes else { return }
        scheduleAutosave(using: repository)
    }

    func autosaveSettingChanged(using repository: AppRepository) {
        autosaveTask?.cancel()
        if autosaveNotes {
            scheduleAutosave(using: repository)
        }
    }

    private func scheduleAutosave(using repository: AppRepository) {
        autosaveTask?.cancel()
        let trimmed = noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            await MainActor.run {
                self.performAutosave(using: repository)
            }
        }
    }

    private func performAutosave(using repository: AppRepository) {
        let trimmed = noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        autosavedNoteID = repository.upsertStandaloneNote(
            id: autosavedNoteID,
            text: noteInput,
            timestamp: Date()
        )
        lastAutosaveMessage = "Autosaved \(DateFormatting.shortDateTime.string(from: Date()))"
    }

    deinit {
        autosaveTask?.cancel()
    }
}
