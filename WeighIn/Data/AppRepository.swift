import Foundation

@MainActor
final class AppRepository: ObservableObject {
    @Published private(set) var logs: [WeightLog] = []
    @Published private(set) var notes: [NoteEntry] = []
    @Published var settings: AppSettings = .default
    @Published var profile: UserProfile = .empty
    @Published var lastErrorMessage: String?
    @Published private(set) var syncInProgress = false

    private let store: SQLiteStore
    private let syncService: CloudKitSyncService?
    private let cloudKitSyncFeatureEnabled: Bool
    private var shouldRunSyncAgain = false
    private var forceNextSync = false

    init(
        store: SQLiteStore = try! SQLiteStore(),
        syncService: CloudKitSyncService? = nil,
        cloudKitSyncFeatureEnabled: Bool = false
    ) {
        self.store = store
        self.cloudKitSyncFeatureEnabled = cloudKitSyncFeatureEnabled
        if cloudKitSyncFeatureEnabled {
            self.syncService = syncService ?? CloudKitSyncService()
        } else {
            self.syncService = nil
        }
        loadAll()
        if cloudKitSyncFeatureEnabled {
            queueSyncIfEnabled()
        }
    }

    func loadAll() {
        do {
            logs = try store.fetchWeightLogs()
            notes = try store.fetchNotes()
            settings = try store.fetchSettings()
            if !cloudKitSyncFeatureEnabled && settings.iCloudSyncEnabled {
                settings.iCloudSyncEnabled = false
                try store.upsert(settings: settings)
            }
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
            queueSyncIfEnabled()
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
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = "Could not save note: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func upsertStandaloneNote(id: String?, text: String, timestamp: Date = Date()) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return id }

        do {
            if let id {
                try store.update(NoteEntry(id: id, timestamp: timestamp, text: trimmed))
                loadAll()
                queueSyncIfEnabled()
                return id
            }

            let note = NoteEntry(timestamp: timestamp, text: trimmed)
            try store.insert(note)
            loadAll()
            queueSyncIfEnabled()
            return note.id
        } catch {
            lastErrorMessage = "Could not save note: \(error.localizedDescription)"
            return id
        }
    }

    func updateWeightLog(
        _ original: WeightLog,
        weight: Double,
        timestamp: Date,
        noteText: String
    ) {
        let trimmedNote = noteText.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            var noteID = original.noteID

            if let existingNoteID = original.noteID {
                if trimmedNote.isEmpty {
                    try store.deleteNote(id: existingNoteID)
                    noteID = nil
                } else {
                    let note = NoteEntry(id: existingNoteID, timestamp: timestamp, text: trimmedNote)
                    try store.update(note)
                    noteID = existingNoteID
                }
            } else if !trimmedNote.isEmpty {
                let note = NoteEntry(timestamp: timestamp, text: trimmedNote)
                try store.insert(note)
                noteID = note.id
            }

            let updated = WeightLog(
                id: original.id,
                timestamp: timestamp,
                weight: weight,
                unit: original.unit,
                source: original.source,
                noteID: noteID
            )
            try store.update(updated)
            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = "Could not update entry: \(error.localizedDescription)"
        }
    }

    func deleteWeightLog(_ log: WeightLog) {
        do {
            if let noteID = log.noteID {
                try store.deleteNote(id: noteID)
            }
            try store.deleteWeightLog(id: log.id)
            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = "Could not delete entry: \(error.localizedDescription)"
        }
    }

    func updateSettings(_ updated: AppSettings) {
        var persisted = updated
        if !cloudKitSyncFeatureEnabled {
            persisted.iCloudSyncEnabled = false
        }

        do {
            try store.upsert(settings: persisted)
            settings = persisted
            NotificationScheduler.updateDailyReminder(
                enabled: persisted.reminderEnabled,
                hour: persisted.reminderHour,
                minute: persisted.reminderMinute
            )
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    func completeOnboarding(with updatedSettings: AppSettings, profile updatedProfile: UserProfile) {
        updateSettings(updatedSettings)
        updateProfile(updatedProfile)
    }

    func updateProfile(_ updated: UserProfile) {
        do {
            try store.upsert(profile: updated)
            profile = updated
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = "Could not save profile: \(error.localizedDescription)"
        }
    }

    func triggerSyncNow() {
        guard cloudKitSyncFeatureEnabled else {
            lastErrorMessage = "iCloud sync is disabled in this build."
            return
        }
        queueSyncIfEnabled(force: true)
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

    func exportJSON() -> Data {
        let payload = ExportPayload(
            exportedAt: Date(),
            settings: settings,
            profile: profile,
            logs: logs.sorted(by: { $0.timestamp < $1.timestamp }),
            notes: notes.sorted(by: { $0.timestamp < $1.timestamp })
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            return try encoder.encode(payload)
        } catch {
            lastErrorMessage = "Could not export JSON: \(error.localizedDescription)"
            return Data()
        }
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

    private func queueSyncIfEnabled(force: Bool = false) {
        guard cloudKitSyncFeatureEnabled else { return }
        guard settings.iCloudSyncEnabled else { return }

        if syncInProgress {
            shouldRunSyncAgain = true
            forceNextSync = forceNextSync || force
            return
        }

        syncInProgress = true
        shouldRunSyncAgain = false
        forceNextSync = force

        Task { [weak self] in
            await self?.runSyncLoop()
        }
    }

    private func runSyncLoop() async {
        defer { syncInProgress = false }

        guard let syncService else { return }

        var firstPass = true
        while settings.iCloudSyncEnabled {
            let forceThisPass = forceNextSync
            forceNextSync = false

            if !firstPass && !shouldRunSyncAgain {
                break
            }

            shouldRunSyncAgain = false
            firstPass = false

            do {
                let snapshot = try buildSyncSnapshot()
                if !forceThisPass,
                   snapshot.pendingNotes.isEmpty,
                   snapshot.pendingWeightLogs.isEmpty,
                   snapshot.lastSyncAt != nil {
                    break
                }

                let result = try await syncService.sync(snapshot: snapshot)
                try store.markNoteRecordsSynced(ids: result.syncedNoteIDs)
                try store.markWeightRecordsSynced(ids: result.syncedWeightIDs)
                try store.applyRemotePullPayload(result.pullPayload)
                try store.updateSyncStatus(lastSyncAt: result.syncedAt, lastSyncError: nil)
                loadAll()
            } catch {
                let message = syncErrorMessage(error)
                try? store.updateSyncStatus(lastSyncAt: settings.lastSyncAt, lastSyncError: message)
                loadAll()
                break
            }
        }
    }

    private func buildSyncSnapshot() throws -> SyncSnapshot {
        let currentSettings = try store.fetchSettings()
        return SyncSnapshot(
            pendingNotes: try store.fetchPendingNoteRecords(),
            pendingWeightLogs: try store.fetchPendingWeightRecords(),
            profile: try store.fetchSyncProfileRecord(),
            settings: try store.fetchSyncSettingsRecord(),
            lastSyncAt: currentSettings.lastSyncAt
        )
    }

    private func syncErrorMessage(_ error: Error) -> String {
        if let syncError = error as? CloudKitSyncService.SyncError,
           let description = syncError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

private struct ExportPayload: Codable {
    let exportedAt: Date
    let settings: AppSettings
    let profile: UserProfile
    let logs: [WeightLog]
    let notes: [NoteEntry]
}
