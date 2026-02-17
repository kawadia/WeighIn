import Foundation
import CryptoKit

@MainActor
protocol LoggingUseCase: AnyObject {
    var logs: [WeightLog] { get }
    var notes: [NoteEntry] { get }
    var settings: AppSettings { get }
    var lastErrorMessage: String? { get set }

    func addWeightLog(
        weight: Double,
        timestamp: Date,
        unit: WeightUnit?,
        noteText: String?,
        source: WeightLogSource
    )
    func addStandaloneNote(text: String, timestamp: Date)
    @discardableResult
    func upsertStandaloneNote(id: String?, text: String, timestamp: Date) -> String?
    func updateWeightLog(_ original: WeightLog, weight: Double, timestamp: Date, noteText: String)
    func deleteWeightLog(_ log: WeightLog)
    func note(for log: WeightLog) -> NoteEntry?
    func convertedWeight(_ log: WeightLog, to unit: WeightUnit) -> Double
}

@MainActor
protocol ChartsUseCase: AnyObject {
    var settings: AppSettings { get }
    func logs(in range: ChartRange) -> [WeightLog]
    func movingAverage(for input: [WeightLog], window: Int) -> [(Date, Double)]
    func convertedWeight(_ log: WeightLog, to unit: WeightUnit) -> Double
    func note(for log: WeightLog) -> NoteEntry?
    func updateWeightLog(_ original: WeightLog, weight: Double, timestamp: Date, noteText: String)
}

@MainActor
protocol SettingsUseCase: AnyObject {
    var settings: AppSettings { get }
    var profile: UserProfile { get }
    var lastErrorMessage: String? { get set }

    var backupInProgress: Bool { get }
    var iCloudBackupEnabled: Bool { get }
    var lastBackupAt: Date? { get }
    var lastBackupError: String? { get }

    func updateSettings(_ updated: AppSettings)
    func updateProfile(_ updated: UserProfile)
    func completeOnboarding(with updatedSettings: AppSettings, profile updatedProfile: UserProfile)

    func setICloudBackupEnabled(_ enabled: Bool)
    func setBackupFolder(_ url: URL)
    func clearBackupFolder()
    func backupFolderDisplayName() -> String?
    func triggerDailyBackupIfNeeded()
    func triggerBackupNow()

    func importCSV(from data: Data)
    func importJSON(from data: Data)
    func importSQLite(from url: URL)
    @discardableResult
    func importAppleHealthZIP(from url: URL) -> AppleHealthImportSummary?
    func exportCSV() -> Data
    func exportJSON() -> Data
    func exportSQLite() -> Data
    func deleteAllData()
}

@MainActor
protocol AnalysisUseCase: AnyObject {
    var lastErrorMessage: String? { get set }
    func exportJSON() -> Data
}

@MainActor
final class AppRepository: ObservableObject, LoggingUseCase, ChartsUseCase, SettingsUseCase, AnalysisUseCase {
    @Published private(set) var logs: [WeightLog] = []
    @Published private(set) var notes: [NoteEntry] = []
    @Published var settings: AppSettings = .default
    @Published var profile: UserProfile = .empty
    @Published var lastErrorMessage: String?
    @Published private(set) var syncInProgress = false
    @Published private(set) var backupInProgress = false
    @Published private(set) var iCloudBackupEnabled = false
    @Published private(set) var backupFolderBookmarkData: Data?
    @Published private(set) var lastBackupAt: Date?
    @Published private(set) var lastBackupError: String?

    private let cloudKitSyncFeatureEnabled: Bool

    private let logStore: any LogStoreGateway
    private let noteStore: any NoteStoreGateway
    private let settingsStore: any SettingsStoreGateway
    private let profileStore: any ProfileStoreGateway
    private let syncStore: any SyncStoreGateway

    private let trendService = TrendService()
    private let logService: LogService
    private let settingsService: SettingsService
    private let importExportService: ImportExportService
    private let backupService: BackupService
    private var syncCoordinator: SyncCoordinator?

    init(
        store: SQLiteStore = try! SQLiteStore(),
        syncService: CloudKitSyncService? = nil,
        cloudKitSyncFeatureEnabled: Bool = false,
        reminderScheduler: @escaping (Bool, Int, Int) -> Void = NotificationScheduler.updateDailyReminder,
        preferences: UserDefaults = .standard
    ) {
        let gateways = store.makeGateways()

        self.cloudKitSyncFeatureEnabled = cloudKitSyncFeatureEnabled
        self.logStore = gateways.logs
        self.noteStore = gateways.notes
        self.settingsStore = gateways.settings
        self.profileStore = gateways.profile
        self.syncStore = gateways.sync

        self.logService = LogService(logStore: gateways.logs, noteStore: gateways.notes)
        self.settingsService = SettingsService(
            settingsStore: gateways.settings,
            profileStore: gateways.profile,
            reminderScheduler: reminderScheduler
        )
        self.importExportService = ImportExportService(
            logStore: gateways.logs,
            noteStore: gateways.notes,
            settingsStore: gateways.settings,
            profileStore: gateways.profile,
            databaseStore: gateways.database,
            cloudKitSyncFeatureEnabled: cloudKitSyncFeatureEnabled
        )
        self.backupService = BackupService(databaseStore: gateways.database, preferences: preferences)

        if cloudKitSyncFeatureEnabled {
            let resolvedSyncService = syncService ?? CloudKitSyncService()
            self.syncCoordinator = SyncCoordinator(
                syncStore: gateways.sync,
                settingsStore: gateways.settings,
                profileStore: gateways.profile,
                syncService: resolvedSyncService,
                currentSettings: { [weak self] in
                    self?.settings ?? .default
                },
                reload: { [weak self] in
                    self?.loadAll()
                }
            )
            self.syncCoordinator?.onProgressChange = { [weak self] inProgress in
                self?.syncInProgress = inProgress
            }
        }

        self.backupService.onStateChange = { [weak self] state, surfacedError in
            guard let self else { return }
            self.applyBackupState(state)
            if let surfacedError {
                self.lastErrorMessage = surfacedError
            }
        }
        applyBackupState(backupService.state)

        loadAll()
        if cloudKitSyncFeatureEnabled {
            queueSyncIfEnabled()
        }
    }

    func loadAll() {
        do {
            logs = try logStore.fetchLogs()
            notes = try noteStore.fetchNotes()

            var loadedSettings = try settingsStore.fetchSettings()
            if !cloudKitSyncFeatureEnabled && loadedSettings.iCloudSyncEnabled {
                loadedSettings.iCloudSyncEnabled = false
                try settingsStore.upsert(settings: loadedSettings)
            }
            settings = loadedSettings
            profile = try profileStore.fetchProfile()

            settingsService.scheduleReminder(for: loadedSettings)
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not load local data"
            )
        }
    }

    func setICloudBackupEnabled(_ enabled: Bool) {
        backupService.setEnabled(enabled)
        applyBackupState(backupService.state)
        if enabled {
            triggerDailyBackupIfNeeded()
        }
    }

    func setBackupFolder(_ url: URL) {
        do {
            try backupService.setFolder(url)
            applyBackupState(backupService.state)
            if iCloudBackupEnabled {
                triggerDailyBackupIfNeeded()
            }
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not save backup folder"
            )
        }
    }

    func clearBackupFolder() {
        backupService.clearFolder()
        applyBackupState(backupService.state)
    }

    func backupFolderDisplayName() -> String? {
        backupService.folderDisplayName()
    }

    func triggerDailyBackupIfNeeded() {
        backupService.triggerDailyIfNeeded()
        applyBackupState(backupService.state)
    }

    func triggerBackupNow() {
        backupService.triggerNow()
        applyBackupState(backupService.state)
    }

    func addWeightLog(
        weight: Double,
        timestamp: Date,
        unit: WeightUnit? = nil,
        noteText: String?,
        source: WeightLogSource
    ) {
        do {
            try logService.addWeightLog(
                weight: weight,
                timestamp: timestamp,
                unit: unit ?? settings.defaultUnit,
                noteText: noteText,
                source: source
            )
            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not save weight entry"
            )
        }
    }

    func addStandaloneNote(text: String, timestamp: Date = Date()) {
        do {
            try logService.addStandaloneNote(text: text, timestamp: timestamp)
            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not save note"
            )
        }
    }

    @discardableResult
    func upsertStandaloneNote(id: String?, text: String, timestamp: Date = Date()) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return id }

        do {
            let noteID = try logService.upsertStandaloneNote(id: id, text: trimmed, timestamp: timestamp)
            loadAll()
            queueSyncIfEnabled()
            return noteID
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not save note"
            )
            return id
        }
    }

    func updateWeightLog(
        _ original: WeightLog,
        weight: Double,
        timestamp: Date,
        noteText: String
    ) {
        do {
            try logService.updateWeightLog(original, weight: weight, timestamp: timestamp, noteText: noteText)
            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not update entry"
            )
        }
    }

    func deleteWeightLog(_ log: WeightLog) {
        do {
            try logService.deleteWeightLog(log)
            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not delete entry"
            )
        }
    }

    func updateSettings(_ updated: AppSettings) {
        do {
            let persisted = settingsService.normalizedSettings(
                updated,
                cloudKitSyncFeatureEnabled: cloudKitSyncFeatureEnabled,
                current: settings
            )
            try settingsService.saveSettings(persisted)
            settings = persisted
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not save settings"
            )
        }
    }

    func completeOnboarding(with updatedSettings: AppSettings, profile updatedProfile: UserProfile) {
        updateSettings(updatedSettings)
        updateProfile(updatedProfile)
    }

    func updateProfile(_ updated: UserProfile) {
        do {
            try settingsService.saveProfile(updated)
            profile = updated
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not save profile"
            )
        }
    }

    func triggerSyncNow() {
        guard cloudKitSyncFeatureEnabled else {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: SyncCoordinator.SyncError.featureDisabled,
                context: "Sync"
            )
            return
        }
        queueSyncIfEnabled(force: true)
    }

    func importCSV(from data: Data) {
        do {
            try importExportService.importCSV(from: data)
            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "CSV import failed"
            )
        }
    }

    func importJSON(from data: Data) {
        do {
            try importExportService.importJSON(from: data, currentSettings: settings)
            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "JSON import failed"
            )
        }
    }

    func importSQLite(from url: URL) {
        do {
            try importExportService.importSQLite(from: url)
            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "SQLite restore failed"
            )
        }
    }

    @discardableResult
    func importAppleHealthZIP(from url: URL) -> AppleHealthImportSummary? {
        do {
            let summary = try importExportService.importAppleHealthZIP(from: url, knownLogIDs: Set(logs.map(\.id)))
            loadAll()
            queueSyncIfEnabled()
            return summary
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Apple Health import failed"
            )
            return nil
        }
    }

    func exportCSV() -> Data {
        importExportService.exportCSV(logs: logs, notes: notes)
    }

    func exportJSON() -> Data {
        do {
            return try importExportService.exportJSON(
                settings: settings,
                profile: profile,
                logs: logs,
                notes: notes
            )
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not export JSON"
            )
            return Data()
        }
    }

    func exportSQLite() -> Data {
        do {
            return try importExportService.exportSQLite()
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not export SQLite"
            )
            return Data()
        }
    }

    func deleteAllData() {
        do {
            try importExportService.deleteAllData()
            loadAll()
        } catch {
            lastErrorMessage = DomainErrorMessageFormatter.message(
                for: error,
                context: "Could not delete all data"
            )
        }
    }

    func note(for log: WeightLog) -> NoteEntry? {
        guard let noteID = log.noteID else { return nil }
        return notes.first(where: { $0.id == noteID })
    }

    func convertedWeight(_ log: WeightLog, to unit: WeightUnit) -> Double {
        trendService.convertedWeight(log, to: unit)
    }

    func logs(in range: ChartRange) -> [WeightLog] {
        trendService.logs(in: logs, range: range, now: Date())
    }

    func movingAverage(for input: [WeightLog], window: Int) -> [(Date, Double)] {
        trendService.movingAverage(for: input, window: window, outputUnit: settings.defaultUnit)
    }

    private func queueSyncIfEnabled(force: Bool = false) {
        guard cloudKitSyncFeatureEnabled else { return }
        syncCoordinator?.queueSyncIfEnabled(force: force)
    }

    private func applyBackupState(_ state: BackupService.State) {
        backupInProgress = state.inProgress
        iCloudBackupEnabled = state.enabled
        backupFolderBookmarkData = state.folderBookmarkData
        lastBackupAt = state.lastBackupAt
        lastBackupError = state.lastBackupError
    }
}

private struct TrendService {
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

    func logs(in allLogs: [WeightLog], range: ChartRange, now: Date) -> [WeightLog] {
        switch range {
        case .all:
            return allLogs
        default:
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -range.days, to: now) else {
                return allLogs
            }
            return allLogs.filter { $0.timestamp >= cutoff }
        }
    }

    func movingAverage(
        for input: [WeightLog],
        window: Int,
        outputUnit: WeightUnit
    ) -> [(Date, Double)] {
        guard window > 1 else {
            return input.sorted(by: { $0.timestamp < $1.timestamp }).map {
                ($0.timestamp, convertedWeight($0, to: outputUnit))
            }
        }

        let sorted = input.sorted(by: { $0.timestamp < $1.timestamp })
        guard sorted.count >= window else { return [] }

        var values: [(Date, Double)] = []
        for index in (window - 1)..<sorted.count {
            let group = sorted[(index - window + 1)...index]
            let average = group.map { convertedWeight($0, to: outputUnit) }.reduce(0, +) / Double(window)
            values.append((sorted[index].timestamp, average))
        }
        return values
    }
}

private struct LogService {
    let logStore: any LogStoreGateway
    let noteStore: any NoteStoreGateway

    func addWeightLog(
        weight: Double,
        timestamp: Date,
        unit: WeightUnit,
        noteText: String?,
        source: WeightLogSource
    ) throws {
        let trimmedNote = noteText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note: NoteEntry? = trimmedNote.isEmpty ? nil : NoteEntry(timestamp: timestamp, text: trimmedNote)

        if let note {
            try noteStore.insert(note)
        }

        let log = WeightLog(
            timestamp: timestamp,
            weight: weight,
            unit: unit,
            source: source,
            noteID: note?.id
        )
        try logStore.insert(log)
    }

    func addStandaloneNote(text: String, timestamp: Date) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try noteStore.insert(NoteEntry(timestamp: timestamp, text: trimmed))
    }

    @discardableResult
    func upsertStandaloneNote(id: String?, text: String, timestamp: Date) throws -> String {
        if let id {
            try noteStore.update(NoteEntry(id: id, timestamp: timestamp, text: text))
            return id
        }

        let note = NoteEntry(timestamp: timestamp, text: text)
        try noteStore.insert(note)
        return note.id
    }

    func updateWeightLog(
        _ original: WeightLog,
        weight: Double,
        timestamp: Date,
        noteText: String
    ) throws {
        let trimmedNote = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        var noteID = original.noteID

        if let existingNoteID = original.noteID {
            if trimmedNote.isEmpty {
                try noteStore.deleteNote(id: existingNoteID)
                noteID = nil
            } else {
                let note = NoteEntry(id: existingNoteID, timestamp: timestamp, text: trimmedNote)
                try noteStore.update(note)
                noteID = existingNoteID
            }
        } else if !trimmedNote.isEmpty {
            let note = NoteEntry(timestamp: timestamp, text: trimmedNote)
            try noteStore.insert(note)
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
        try logStore.update(updated)
    }

    func deleteWeightLog(_ log: WeightLog) throws {
        if let noteID = log.noteID {
            try noteStore.deleteNote(id: noteID)
        }
        try logStore.deleteLog(id: log.id)
    }
}

private struct SettingsService {
    let settingsStore: any SettingsStoreGateway
    let profileStore: any ProfileStoreGateway
    let reminderScheduler: (Bool, Int, Int) -> Void

    func normalizedSettings(
        _ updated: AppSettings,
        cloudKitSyncFeatureEnabled: Bool,
        current: AppSettings
    ) -> AppSettings {
        var persisted = updated
        if !cloudKitSyncFeatureEnabled {
            persisted.iCloudSyncEnabled = false
        }
        persisted.lastSyncAt = current.lastSyncAt
        persisted.lastSyncError = current.lastSyncError
        return persisted
    }

    func saveSettings(_ settings: AppSettings) throws {
        try settingsStore.upsert(settings: settings)
        scheduleReminder(for: settings)
    }

    func saveProfile(_ profile: UserProfile) throws {
        try profileStore.upsert(profile: profile)
    }

    func scheduleReminder(for settings: AppSettings) {
        reminderScheduler(settings.reminderEnabled, settings.reminderHour, settings.reminderMinute)
    }
}

private struct ImportExportService {
    enum ImportExportError: LocalizedError {
        case csv(Error)
        case json(Error)
        case sqlite(Error)
        case appleHealth(Error)
        case export(Error)

        var errorDescription: String? {
            switch self {
            case .csv(let error),
                    .json(let error),
                    .sqlite(let error),
                    .appleHealth(let error),
                    .export(let error):
                return error.localizedDescription
            }
        }
    }

    let logStore: any LogStoreGateway
    let noteStore: any NoteStoreGateway
    let settingsStore: any SettingsStoreGateway
    let profileStore: any ProfileStoreGateway
    let databaseStore: any DatabaseStoreGateway
    let cloudKitSyncFeatureEnabled: Bool

    func importCSV(from data: Data) throws {
        do {
            let rows = try CSVCodec.parse(data: data)
            for row in rows {
                let normalizedNote = row.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let key = csvRowKey(timestamp: row.timestamp, weight: row.weight, unit: row.unit)
                let deterministicNoteID = "csv-note-\(key)"

                let noteID: String?
                if normalizedNote.isEmpty {
                    try? noteStore.deleteNote(id: deterministicNoteID)
                    noteID = nil
                } else {
                    try noteStore.insert(NoteEntry(id: deterministicNoteID, timestamp: row.timestamp, text: normalizedNote))
                    noteID = deterministicNoteID
                }

                let log = WeightLog(
                    id: "csv-log-\(key)",
                    timestamp: row.timestamp,
                    weight: row.weight,
                    unit: row.unit,
                    source: .csv,
                    noteID: noteID
                )
                try logStore.insert(log)
            }
        } catch {
            throw ImportExportError.csv(error)
        }
    }

    func importJSON(from data: Data, currentSettings: AppSettings) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let payload = try decoder.decode(ExportPayload.self, from: data)
            for note in payload.notes {
                try noteStore.insert(note)
            }

            for log in payload.logs {
                try logStore.insert(log)
            }

            let importedSettings = AppSettings(
                defaultUnit: payload.settings.defaultUnit,
                reminderEnabled: payload.settings.reminderEnabled,
                reminderHour: payload.settings.reminderHour,
                reminderMinute: payload.settings.reminderMinute,
                hasCompletedOnboarding: payload.settings.hasCompletedOnboarding,
                iCloudSyncEnabled: cloudKitSyncFeatureEnabled ? payload.settings.iCloudSyncEnabled : false,
                lastSyncAt: currentSettings.lastSyncAt,
                lastSyncError: currentSettings.lastSyncError
            )
            try settingsStore.upsert(settings: importedSettings)
            try profileStore.upsert(profile: payload.profile)
        } catch {
            throw ImportExportError.json(error)
        }
    }

    func importSQLite(from url: URL) throws {
        do {
            try databaseStore.mergeDatabaseWithoutOverwriting(from: url)
        } catch {
            throw ImportExportError.sqlite(error)
        }
    }

    func importAppleHealthZIP(from url: URL, knownLogIDs: Set<String>) throws -> AppleHealthImportSummary {
        do {
            let rows = try AppleHealthImportParser.parseBodyMassRows(fromExportAt: url)
            var seenRowIDs: Set<String> = []
            var mutableKnownIDs = knownLogIDs
            var newRecords = 0

            for row in rows {
                let key = healthRowKey(
                    timestamp: row.timestamp,
                    weight: row.weight,
                    unit: row.unit,
                    sourceName: row.sourceName
                )
                guard seenRowIDs.insert(key).inserted else { continue }

                let log = WeightLog(
                    id: "health-log-\(key)",
                    timestamp: row.timestamp,
                    weight: row.weight,
                    unit: row.unit,
                    source: .health,
                    noteID: nil
                )
                if mutableKnownIDs.insert(log.id).inserted {
                    newRecords += 1
                }
                try logStore.insert(log)
            }

            return AppleHealthImportSummary(
                processedRecords: seenRowIDs.count,
                newRecords: newRecords
            )
        } catch {
            throw ImportExportError.appleHealth(error)
        }
    }

    func exportCSV(logs: [WeightLog], notes: [NoteEntry]) -> Data {
        let noteMap = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        return CSVCodec.export(logs: logs, notesByID: noteMap)
    }

    func exportJSON(
        settings: AppSettings,
        profile: UserProfile,
        logs: [WeightLog],
        notes: [NoteEntry]
    ) throws -> Data {
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
            throw ImportExportError.export(error)
        }
    }

    func exportSQLite() throws -> Data {
        do {
            return try databaseStore.exportDatabaseData()
        } catch {
            throw ImportExportError.export(error)
        }
    }

    func deleteAllData() throws {
        try databaseStore.deleteAllData()
    }

    private func csvRowKey(timestamp: Date, weight: Double, unit: WeightUnit) -> String {
        let millis = Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
        let weightString = String(format: "%.6f", weight)
        let canonical = "\(millis)|\(weightString)|\(unit.rawValue)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func healthRowKey(timestamp: Date, weight: Double, unit: WeightUnit, sourceName: String) -> String {
        let millis = Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
        let weightString = String(format: "%.6f", weight)
        let canonical = "\(millis)|\(weightString)|\(unit.rawValue)|\(sourceName.lowercased())"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
private final class BackupService {
    struct State {
        var inProgress: Bool = false
        var enabled: Bool = false
        var folderBookmarkData: Data?
        var lastBackupAt: Date?
        var lastBackupError: String?
    }

    private enum BackupPreferencesKey {
        static let enabled = "backup.enabled"
        static let folderBookmarkData = "backup.folderBookmarkData"
        static let lastBackupAt = "backup.lastBackupAt"
        static let lastBackupError = "backup.lastBackupError"
    }

    let databaseStore: any DatabaseStoreGateway
    let preferences: UserDefaults

    private(set) var state: State
    var onStateChange: ((State, String?) -> Void)?

    private var backupTask: Task<Void, Never>?

    init(databaseStore: any DatabaseStoreGateway, preferences: UserDefaults) {
        self.databaseStore = databaseStore
        self.preferences = preferences
        self.state = State(
            inProgress: false,
            enabled: preferences.bool(forKey: BackupPreferencesKey.enabled),
            folderBookmarkData: preferences.data(forKey: BackupPreferencesKey.folderBookmarkData),
            lastBackupAt: preferences.object(forKey: BackupPreferencesKey.lastBackupAt) as? Date,
            lastBackupError: preferences.string(forKey: BackupPreferencesKey.lastBackupError)
        )
    }

    func setEnabled(_ enabled: Bool) {
        state.enabled = enabled
        preferences.set(enabled, forKey: BackupPreferencesKey.enabled)
        publishState()
    }

    func setFolder(_ url: URL) throws {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let bookmarkData = try url.bookmarkData(
            options: bookmarkCreationOptions(),
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        state.folderBookmarkData = bookmarkData
        state.lastBackupError = nil

        preferences.set(bookmarkData, forKey: BackupPreferencesKey.folderBookmarkData)
        preferences.removeObject(forKey: BackupPreferencesKey.lastBackupError)

        publishState()
    }

    func clearFolder() {
        state.folderBookmarkData = nil
        preferences.removeObject(forKey: BackupPreferencesKey.folderBookmarkData)
        publishState()
    }

    func folderDisplayName() -> String? {
        guard let bookmarkData = state.folderBookmarkData else { return nil }

        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: bookmarkResolutionOptions(),
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }

        return url.lastPathComponent
    }

    func triggerDailyIfNeeded() {
        guard state.enabled else { return }
        guard backupTask == nil else { return }
        guard let bookmarkData = state.folderBookmarkData else { return }
        guard shouldRunDailyBackup(now: Date(), lastBackupAt: state.lastBackupAt) else { return }

        runBackup(bookmarkData: bookmarkData)
    }

    func triggerNow() {
        guard !state.inProgress else { return }

        guard state.enabled else {
            state.lastBackupError = "Enable iCloud Drive backup first."
            preferences.set(state.lastBackupError, forKey: BackupPreferencesKey.lastBackupError)
            publishState()
            return
        }

        guard let bookmarkData = state.folderBookmarkData else {
            state.lastBackupError = "Choose an iCloud Drive folder for backups first."
            preferences.set(state.lastBackupError, forKey: BackupPreferencesKey.lastBackupError)
            publishState()
            return
        }

        runBackup(bookmarkData: bookmarkData)
    }

    private func runBackup(bookmarkData: Data) {
        guard backupTask == nil else { return }

        state.inProgress = true
        publishState()

        let databaseURL = databaseStore.databaseFileURL()
        backupTask = Task(priority: .utility) { [weak self] in
            let result: Result<Date, Error> = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Date, Error>, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        returning: ICloudDriveBackupWorker.backupSQLiteSnapshot(
                            databaseURL: databaseURL,
                            folderBookmarkData: bookmarkData
                        )
                    )
                }
            }

            guard let self else { return }
            self.backupTask = nil
            self.state.inProgress = false

            switch result {
            case .success(let completedAt):
                self.state.lastBackupAt = completedAt
                self.state.lastBackupError = nil
                self.preferences.set(completedAt, forKey: BackupPreferencesKey.lastBackupAt)
                self.preferences.removeObject(forKey: BackupPreferencesKey.lastBackupError)
                self.publishState()
            case .failure(let error):
                self.state.lastBackupError = error.localizedDescription
                self.preferences.set(error.localizedDescription, forKey: BackupPreferencesKey.lastBackupError)
                self.publishState(surfacedError: "Backup failed: \(error.localizedDescription)")
            }
        }
    }

    private func shouldRunDailyBackup(now: Date, lastBackupAt: Date?) -> Bool {
        guard let lastBackupAt else { return true }
        let startOfToday = Calendar.current.startOfDay(for: now)
        return lastBackupAt < startOfToday
    }

    private func publishState(surfacedError: String? = nil) {
        onStateChange?(state, surfacedError)
    }
}

@MainActor
private final class SyncCoordinator {
    enum SyncError: LocalizedError {
        case featureDisabled

        var errorDescription: String? {
            switch self {
            case .featureDisabled:
                return "iCloud sync is disabled in this build."
            }
        }
    }

    let syncStore: any SyncStoreGateway
    let settingsStore: any SettingsStoreGateway
    let profileStore: any ProfileStoreGateway
    let syncService: CloudKitSyncService
    let currentSettings: () -> AppSettings
    let reload: () -> Void

    var onProgressChange: ((Bool) -> Void)?

    private var syncInProgress = false
    private var shouldRunSyncAgain = false
    private var forceNextSync = false

    init(
        syncStore: any SyncStoreGateway,
        settingsStore: any SettingsStoreGateway,
        profileStore: any ProfileStoreGateway,
        syncService: CloudKitSyncService,
        currentSettings: @escaping () -> AppSettings,
        reload: @escaping () -> Void
    ) {
        self.syncStore = syncStore
        self.settingsStore = settingsStore
        self.profileStore = profileStore
        self.syncService = syncService
        self.currentSettings = currentSettings
        self.reload = reload
    }

    func queueSyncIfEnabled(force: Bool = false) {
        guard currentSettings().iCloudSyncEnabled else { return }

        if syncInProgress {
            shouldRunSyncAgain = true
            forceNextSync = forceNextSync || force
            return
        }

        syncInProgress = true
        onProgressChange?(true)
        shouldRunSyncAgain = false
        forceNextSync = force

        Task { [weak self] in
            await self?.runSyncLoop()
        }
    }

    private func runSyncLoop() async {
        defer {
            syncInProgress = false
            onProgressChange?(false)
        }

        var firstPass = true
        while currentSettings().iCloudSyncEnabled {
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
                try syncStore.markNoteRecordsSynced(ids: result.syncedNoteIDs)
                try syncStore.markWeightRecordsSynced(ids: result.syncedWeightIDs)
                try syncStore.applyRemotePullPayload(result.pullPayload)
                try settingsStore.updateSyncStatus(lastSyncAt: result.syncedAt, lastSyncError: nil)
                reload()
            } catch {
                let message = syncErrorMessage(error)
                try? settingsStore.updateSyncStatus(lastSyncAt: currentSettings().lastSyncAt, lastSyncError: message)
                reload()
                break
            }
        }
    }

    private func buildSyncSnapshot() throws -> SyncSnapshot {
        let current = try settingsStore.fetchSettings()
        return SyncSnapshot(
            pendingNotes: try syncStore.fetchPendingNoteRecords(),
            pendingWeightLogs: try syncStore.fetchPendingWeightRecords(),
            profile: try profileStore.fetchSyncProfileRecord(),
            settings: try settingsStore.fetchSyncSettingsRecord(),
            lastSyncAt: current.lastSyncAt
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

private enum ICloudDriveBackupWorker {
    enum BackupError: LocalizedError {
        case missingSecurityScope
        case staleFolderBookmark

        var errorDescription: String? {
            switch self {
            case .missingSecurityScope:
                return "The selected iCloud Drive folder is not accessible anymore."
            case .staleFolderBookmark:
                return "The selected backup folder reference is stale. Please choose the folder again."
            }
        }
    }

    static func backupSQLiteSnapshot(databaseURL: URL, folderBookmarkData: Data) -> Result<Date, Error> {
        do {
            var isStale = false
            let folderURL = try URL(
                resolvingBookmarkData: folderBookmarkData,
                options: bookmarkResolutionOptions(),
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                throw BackupError.staleFolderBookmark
            }

            let hasAccess = folderURL.startAccessingSecurityScopedResource()
            guard hasAccess else {
                throw BackupError.missingSecurityScope
            }
            defer {
                folderURL.stopAccessingSecurityScopedResource()
            }

            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

            let timestamp = Date()
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = "yyyy-MM-dd"

            let datedBackupURL = folderURL.appendingPathComponent(
                "weighin-backup-\(dateFormatter.string(from: timestamp)).sqlite"
            )
            let latestBackupURL = folderURL.appendingPathComponent("weighin-backup-latest.sqlite")
            let temporarySnapshotURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("weighin-snapshot-\(UUID().uuidString).sqlite")

            defer {
                try? FileManager.default.removeItem(at: temporarySnapshotURL)
            }

            try SQLiteStore.createDatabaseSnapshot(from: databaseURL, to: temporarySnapshotURL)

            if FileManager.default.fileExists(atPath: datedBackupURL.path) {
                try FileManager.default.removeItem(at: datedBackupURL)
            }
            try FileManager.default.copyItem(at: temporarySnapshotURL, to: datedBackupURL)

            if FileManager.default.fileExists(atPath: latestBackupURL.path) {
                try FileManager.default.removeItem(at: latestBackupURL)
            }
            try FileManager.default.copyItem(at: temporarySnapshotURL, to: latestBackupURL)

            return .success(timestamp)
        } catch {
            return .failure(error)
        }
    }
}

private enum DomainErrorMessageFormatter {
    static func message(for error: Error, context: String) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return "\(context): \(description)"
        }

        return "\(context): \(error.localizedDescription)"
    }
}

private struct ExportPayload: Codable {
    let exportedAt: Date
    let settings: AppSettings
    let profile: UserProfile
    let logs: [WeightLog]
    let notes: [NoteEntry]
}

struct AppleHealthImportSummary: Equatable {
    let processedRecords: Int
    let newRecords: Int
}

private func bookmarkCreationOptions() -> URL.BookmarkCreationOptions {
#if os(macOS)
    return [.withSecurityScope]
#else
    return []
#endif
}

private func bookmarkResolutionOptions() -> URL.BookmarkResolutionOptions {
#if os(macOS)
    return [.withSecurityScope]
#else
    return []
#endif
}
