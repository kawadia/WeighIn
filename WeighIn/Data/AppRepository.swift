import Foundation

@MainActor
final class AppRepository: ObservableObject {
    @Published private(set) var logs: [WeightLog] = []
    @Published private(set) var notes: [NoteEntry] = []
    @Published var settings: AppSettings = .default
    @Published var profile: UserProfile = .empty
    @Published var lastErrorMessage: String?

    private let store: SQLiteStore

    init(store: SQLiteStore = try! SQLiteStore()) {
        self.store = store
        loadAll()
    }

    func loadAll() {
        do {
            logs = try store.fetchWeightLogs()
            notes = try store.fetchNotes()
            settings = try store.fetchSettings()
            profile = try store.fetchProfile()
            NotificationScheduler.updateDailyReminder(
                enabled: settings.reminderEnabled,
                hour: settings.reminderHour,
                minute: settings.reminderMinute
            )
        } catch {
            lastErrorMessage = "Could not load local data: \(error.localizedDescription)"
        }
    }

    func addWeightLog(
        weight: Double,
        timestamp: Date,
        unit: WeightUnit? = nil,
        noteText: String?,
        source: WeightLogSource
    ) {
        let trimmedNote = noteText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note: NoteEntry? = trimmedNote.isEmpty ? nil : NoteEntry(timestamp: timestamp, text: trimmedNote)
        let finalUnit = unit ?? settings.defaultUnit

        do {
            if let note {
                try store.insert(note)
            }

            let log = WeightLog(
                timestamp: timestamp,
                weight: weight,
                unit: finalUnit,
                source: source,
                noteID: note?.id
            )
            try store.insert(log)
            loadAll()
        } catch {
            lastErrorMessage = "Could not save weight entry: \(error.localizedDescription)"
        }
    }

    func addStandaloneNote(text: String, timestamp: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try store.insert(NoteEntry(timestamp: timestamp, text: trimmed))
            loadAll()
        } catch {
            lastErrorMessage = "Could not save note: \(error.localizedDescription)"
        }
    }

    func updateSettings(_ updated: AppSettings) {
        do {
            try store.upsert(settings: updated)
            settings = updated
            NotificationScheduler.updateDailyReminder(
                enabled: updated.reminderEnabled,
                hour: updated.reminderHour,
                minute: updated.reminderMinute
            )
        } catch {
            lastErrorMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    func updateProfile(_ updated: UserProfile) {
        do {
            try store.upsert(profile: updated)
            profile = updated
        } catch {
            lastErrorMessage = "Could not save profile: \(error.localizedDescription)"
        }
    }

    func importCSV(from data: Data) {
        do {
            let rows = try CSVCodec.parse(data: data)
            for row in rows {
                let note = row.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                addWeightLog(
                    weight: row.weight,
                    timestamp: row.timestamp,
                    unit: row.unit,
                    noteText: note,
                    source: .csv
                )
            }
        } catch {
            lastErrorMessage = "CSV import failed: \(error.localizedDescription)"
        }
    }

    func exportCSV() -> Data {
        let noteMap = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        return CSVCodec.export(logs: logs, notesByID: noteMap)
    }

    func note(for log: WeightLog) -> NoteEntry? {
        guard let noteID = log.noteID else { return nil }
        return notes.first(where: { $0.id == noteID })
    }

    func convertedWeight(_ log: WeightLog, to unit: WeightUnit) -> Double {
        guard log.unit != unit else { return log.weight }

        switch (log.unit, unit) {
        case (.kg, .lbs):
            return log.weight * 2.20462262
        case (.lbs, .kg):
            return log.weight / 2.20462262
        default:
            return log.weight
        }
    }

    func logs(in range: ChartRange) -> [WeightLog] {
        switch range {
        case .all:
            return logs
        default:
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -range.days, to: Date()) else {
                return logs
            }
            return logs.filter { $0.timestamp >= cutoff }
        }
    }

    func movingAverage(for input: [WeightLog], window: Int) -> [(Date, Double)] {
        guard window > 1 else {
            return input.sorted(by: { $0.timestamp < $1.timestamp }).map {
                ($0.timestamp, convertedWeight($0, to: settings.defaultUnit))
            }
        }

        let sorted = input.sorted(by: { $0.timestamp < $1.timestamp })
        guard sorted.count >= window else { return [] }

        var values: [(Date, Double)] = []
        for index in (window - 1)..<sorted.count {
            let group = sorted[(index - window + 1)...index]
            let average = group.map { convertedWeight($0, to: settings.defaultUnit) }.reduce(0, +) / Double(window)
            values.append((sorted[index].timestamp, average))
        }
        return values
    }
}
