import Foundation
import CryptoKit
import zlib

@MainActor
final class AppRepository: ObservableObject {
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

    private let store: SQLiteStore
    private let syncService: CloudKitSyncService?
    private let cloudKitSyncFeatureEnabled: Bool
    private let reminderScheduler: (Bool, Int, Int) -> Void
    private let preferences: UserDefaults
    private var shouldRunSyncAgain = false
    private var forceNextSync = false
    private var backupTask: Task<Void, Never>?

    private enum BackupPreferencesKey {
        static let enabled = "backup.enabled"
        static let folderBookmarkData = "backup.folderBookmarkData"
        static let lastBackupAt = "backup.lastBackupAt"
        static let lastBackupError = "backup.lastBackupError"
    }

    init(
        store: SQLiteStore = try! SQLiteStore(),
        syncService: CloudKitSyncService? = nil,
        cloudKitSyncFeatureEnabled: Bool = false,
        reminderScheduler: @escaping (Bool, Int, Int) -> Void = NotificationScheduler.updateDailyReminder,
        preferences: UserDefaults = .standard
    ) {
        self.store = store
        self.cloudKitSyncFeatureEnabled = cloudKitSyncFeatureEnabled
        self.reminderScheduler = reminderScheduler
        self.preferences = preferences
        if cloudKitSyncFeatureEnabled {
            self.syncService = syncService ?? CloudKitSyncService()
        } else {
            self.syncService = nil
        }
        loadBackupPreferences()
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
            reminderScheduler(
                settings.reminderEnabled,
                settings.reminderHour,
                settings.reminderMinute
            )
        } catch {
            lastErrorMessage = "Could not load local data: \(error.localizedDescription)"
        }
    }

    func setICloudBackupEnabled(_ enabled: Bool) {
        iCloudBackupEnabled = enabled
        preferences.set(enabled, forKey: BackupPreferencesKey.enabled)
        if enabled {
            triggerDailyBackupIfNeeded()
        }
    }

    func setBackupFolder(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: bookmarkCreationOptions(),
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            backupFolderBookmarkData = bookmarkData
            lastBackupError = nil
            preferences.set(bookmarkData, forKey: BackupPreferencesKey.folderBookmarkData)
            preferences.removeObject(forKey: BackupPreferencesKey.lastBackupError)

            if iCloudBackupEnabled {
                triggerDailyBackupIfNeeded()
            }
        } catch {
            lastErrorMessage = "Could not save backup folder: \(error.localizedDescription)"
        }
    }

    func clearBackupFolder() {
        backupFolderBookmarkData = nil
        preferences.removeObject(forKey: BackupPreferencesKey.folderBookmarkData)
    }

    func backupFolderDisplayName() -> String? {
        guard let bookmarkData = backupFolderBookmarkData else { return nil }
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

    func triggerDailyBackupIfNeeded() {
        guard iCloudBackupEnabled else { return }
        guard backupTask == nil else { return }
        guard let bookmarkData = backupFolderBookmarkData else { return }
        guard shouldRunDailyBackup(now: Date(), lastBackupAt: lastBackupAt) else { return }
        runBackup(bookmarkData: bookmarkData)
    }

    func triggerBackupNow() {
        guard !backupInProgress else { return }
        guard iCloudBackupEnabled else {
            lastBackupError = "Enable iCloud Drive backup first."
            preferences.set(lastBackupError, forKey: BackupPreferencesKey.lastBackupError)
            return
        }
        guard let bookmarkData = backupFolderBookmarkData else {
            lastBackupError = "Choose an iCloud Drive folder for backups first."
            preferences.set(lastBackupError, forKey: BackupPreferencesKey.lastBackupError)
            return
        }
        runBackup(bookmarkData: bookmarkData)
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
            reminderScheduler(
                persisted.reminderEnabled,
                persisted.reminderHour,
                persisted.reminderMinute
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
                let normalizedNote = row.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let key = csvRowKey(timestamp: row.timestamp, weight: row.weight, unit: row.unit)
                let deterministicNoteID = "csv-note-\(key)"

                let noteID: String?
                if normalizedNote.isEmpty {
                    try? store.deleteNote(id: deterministicNoteID)
                    noteID = nil
                } else {
                    try store.insert(NoteEntry(id: deterministicNoteID, timestamp: row.timestamp, text: normalizedNote))
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
                try store.insert(log)
            }
            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = "CSV import failed: \(error.localizedDescription)"
        }
    }

    func importJSON(from data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let payload = try decoder.decode(ExportPayload.self, from: data)
            for note in payload.notes {
                try store.insert(note)
            }

            for log in payload.logs {
                try store.insert(log)
            }

            let importedSettings = AppSettings(
                defaultUnit: payload.settings.defaultUnit,
                reminderEnabled: payload.settings.reminderEnabled,
                reminderHour: payload.settings.reminderHour,
                reminderMinute: payload.settings.reminderMinute,
                hasCompletedOnboarding: payload.settings.hasCompletedOnboarding,
                iCloudSyncEnabled: cloudKitSyncFeatureEnabled ? payload.settings.iCloudSyncEnabled : false,
                lastSyncAt: settings.lastSyncAt,
                lastSyncError: settings.lastSyncError
            )
            try store.upsert(settings: importedSettings)
            try store.upsert(profile: payload.profile)

            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = "JSON import failed: \(error.localizedDescription)"
        }
    }

    func importSQLite(from url: URL) {
        do {
            try store.mergeDatabaseWithoutOverwriting(from: url)
            loadAll()
            queueSyncIfEnabled()
        } catch {
            lastErrorMessage = "SQLite restore failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func importAppleHealthZIP(from url: URL) -> AppleHealthImportSummary? {
        do {
            let rows = try AppleHealthImport.parseBodyMassRows(fromExportAt: url)
            var seenRowIDs: Set<String> = []
            var knownLogIDs = Set(logs.map(\.id))
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
                if knownLogIDs.insert(log.id).inserted {
                    newRecords += 1
                }
                try store.insert(log)
            }

            loadAll()
            queueSyncIfEnabled()
            return AppleHealthImportSummary(
                processedRecords: seenRowIDs.count,
                newRecords: newRecords
            )
        } catch {
            lastErrorMessage = "Apple Health import failed: \(error.localizedDescription)"
            return nil
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

    func exportSQLite() -> Data {
        do {
            return try store.exportDatabaseData()
        } catch {
            lastErrorMessage = "Could not export SQLite: \(error.localizedDescription)"
            return Data()
        }
    }

    func deleteAllData() {
        do {
            try store.deleteAllData()
            loadAll()
        } catch {
            lastErrorMessage = "Could not delete all data: \(error.localizedDescription)"
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

    private func loadBackupPreferences() {
        iCloudBackupEnabled = preferences.bool(forKey: BackupPreferencesKey.enabled)
        backupFolderBookmarkData = preferences.data(forKey: BackupPreferencesKey.folderBookmarkData)
        lastBackupAt = preferences.object(forKey: BackupPreferencesKey.lastBackupAt) as? Date
        lastBackupError = preferences.string(forKey: BackupPreferencesKey.lastBackupError)
    }

    private func shouldRunDailyBackup(now: Date, lastBackupAt: Date?) -> Bool {
        guard let lastBackupAt else { return true }
        let startOfToday = Calendar.current.startOfDay(for: now)
        return lastBackupAt < startOfToday
    }

    private func runBackup(bookmarkData: Data) {
        guard backupTask == nil else { return }
        backupInProgress = true

        let databaseURL = store.databaseFileURL()
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
            self.backupInProgress = false

            switch result {
            case .success(let completedAt):
                self.lastBackupAt = completedAt
                self.lastBackupError = nil
                self.preferences.set(completedAt, forKey: BackupPreferencesKey.lastBackupAt)
                self.preferences.removeObject(forKey: BackupPreferencesKey.lastBackupError)
            case .failure(let error):
                self.lastBackupError = error.localizedDescription
                self.preferences.set(error.localizedDescription, forKey: BackupPreferencesKey.lastBackupError)
                self.lastErrorMessage = "Backup failed: \(error.localizedDescription)"
            }
        }
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

private struct AppleHealthBodyMassRow {
    let timestamp: Date
    let weight: Double
    let unit: WeightUnit
    let sourceName: String
}

private enum AppleHealthImport {
    private static let supportedRecordType = "HKQuantityTypeIdentifierBodyMass"

    static func parseBodyMassRows(fromExportAt url: URL) throws -> [AppleHealthBodyMassRow] {
        let xmlData = try extractExportXMLData(from: url)
        let parser = AppleHealthBodyMassXMLParser()
        return try parser.parse(data: xmlData)
    }

    private static func extractExportXMLData(from url: URL) throws -> Data {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true {
            return try extractExportXML(fromDirectory: url)
        }
        return try ZIPExportExtractor.extractExportXML(from: url)
    }

    private static func extractExportXML(fromDirectory directoryURL: URL) throws -> Data {
        let directPath = directoryURL.appendingPathComponent("export.xml")
        if FileManager.default.fileExists(atPath: directPath.path) {
            return try Data(contentsOf: directPath)
        }

        let nestedPath = directoryURL
            .appendingPathComponent("apple_health_export")
            .appendingPathComponent("export.xml")
        if FileManager.default.fileExists(atPath: nestedPath.path) {
            return try Data(contentsOf: nestedPath)
        }

        if let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent.lowercased() == "export.xml" else { continue }
                let fileValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if fileValues?.isRegularFile == true {
                    return try Data(contentsOf: fileURL)
                }
            }
        }

        throw ZIPExportExtractor.ExtractorError.missingExportXML
    }

    private final class AppleHealthBodyMassXMLParser: NSObject, XMLParserDelegate {
        private var rows: [AppleHealthBodyMassRow] = []

        private lazy var dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            return formatter
        }()

        func parse(data: Data) throws -> [AppleHealthBodyMassRow] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldResolveExternalEntities = false
            parser.shouldProcessNamespaces = false

            guard parser.parse() else {
                throw parser.parserError ?? ZIPExportExtractor.ExtractorError.invalidArchive("Could not parse Apple Health export XML")
            }
            return rows
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName == "Record" else { return }
            guard attributeDict["type"] == AppleHealthImport.supportedRecordType else { return }

            guard let valueString = attributeDict["value"],
                  let value = Double(valueString),
                  value > 0,
                  let dateString = attributeDict["startDate"],
                  let timestamp = dateFormatter.date(from: dateString),
                  let unit = parseUnit(attributeDict["unit"]) else {
                return
            }

            let sourceName = attributeDict["sourceName"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(
                AppleHealthBodyMassRow(
                    timestamp: timestamp,
                    weight: value,
                    unit: unit,
                    sourceName: sourceName?.isEmpty == false ? sourceName! : "Health"
                )
            )
        }

        private func parseUnit(_ value: String?) -> WeightUnit? {
            guard let value else { return nil }
            switch value.lowercased() {
            case "lb", "lbs", "pound", "pounds":
                return .lbs
            case "kg", "kgs", "kilogram", "kilograms":
                return .kg
            default:
                return nil
            }
        }
    }
}

private enum ZIPExportExtractor {
    struct CentralDirectoryEntry {
        let fileName: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    enum ExtractorError: LocalizedError {
        case invalidArchive(String)
        case missingExportXML
        case unsupportedCompression(UInt16)
        case decompressionFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidArchive(let message):
                return message
            case .missingExportXML:
                return "Could not find export.xml inside the Apple Health ZIP."
            case .unsupportedCompression(let method):
                return "Unsupported ZIP compression method: \(method)."
            case .decompressionFailed(let status):
                return "Could not decompress Apple Health export (zlib status \(status))."
            }
        }
    }

    private static let localFileHeaderSignature: UInt32 = 0x04034B50
    private static let centralDirectorySignature: UInt32 = 0x02014B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054B50

    static func extractExportXML(from archiveURL: URL) throws -> Data {
        let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let eocdOffset = try locateEndOfCentralDirectory(in: archiveData)
        let centralDirectorySize = Int(try readUInt32LE(from: archiveData, at: eocdOffset + 12))
        let centralDirectoryOffset = Int(try readUInt32LE(from: archiveData, at: eocdOffset + 16))
        let centralDirectoryEnd = centralDirectoryOffset + centralDirectorySize

        guard centralDirectoryOffset >= 0,
              centralDirectoryEnd <= archiveData.count else {
            throw ExtractorError.invalidArchive("Invalid central directory range in ZIP.")
        }

        var cursor = centralDirectoryOffset
        var exportEntry: CentralDirectoryEntry?

        while cursor < centralDirectoryEnd {
            let signature = try readUInt32LE(from: archiveData, at: cursor)
            guard signature == centralDirectorySignature else {
                throw ExtractorError.invalidArchive("Invalid central directory record signature.")
            }

            let compressionMethod = try readUInt16LE(from: archiveData, at: cursor + 10)
            let compressedSize = try readUInt32LE(from: archiveData, at: cursor + 20)
            let uncompressedSize = try readUInt32LE(from: archiveData, at: cursor + 24)
            let fileNameLength = Int(try readUInt16LE(from: archiveData, at: cursor + 28))
            let extraLength = Int(try readUInt16LE(from: archiveData, at: cursor + 30))
            let commentLength = Int(try readUInt16LE(from: archiveData, at: cursor + 32))
            let localHeaderOffset = try readUInt32LE(from: archiveData, at: cursor + 42)

            let fileNameStart = cursor + 46
            let fileNameEnd = fileNameStart + fileNameLength
            guard fileNameEnd <= archiveData.count else {
                throw ExtractorError.invalidArchive("Invalid central directory file name range.")
            }

            let nameData = archiveData.subdata(in: fileNameStart..<fileNameEnd)
            let fileName = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            if fileName == "export.xml" || fileName.hasSuffix("/export.xml") {
                exportEntry = CentralDirectoryEntry(
                    fileName: fileName,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
                break
            }

            cursor = fileNameEnd + extraLength + commentLength
        }

        guard let entry = exportEntry else {
            throw ExtractorError.missingExportXML
        }

        return try extract(entry: entry, from: archiveData)
    }

    private static func extract(entry: CentralDirectoryEntry, from archiveData: Data) throws -> Data {
        let localOffset = Int(entry.localHeaderOffset)
        let localSignature = try readUInt32LE(from: archiveData, at: localOffset)
        guard localSignature == localFileHeaderSignature else {
            throw ExtractorError.invalidArchive("Invalid local file header signature for \(entry.fileName).")
        }

        let localFileNameLength = Int(try readUInt16LE(from: archiveData, at: localOffset + 26))
        let localExtraLength = Int(try readUInt16LE(from: archiveData, at: localOffset + 28))
        let compressedStart = localOffset + 30 + localFileNameLength + localExtraLength
        let compressedEnd = compressedStart + Int(entry.compressedSize)
        guard compressedStart >= 0, compressedEnd <= archiveData.count else {
            throw ExtractorError.invalidArchive("Compressed payload range is invalid for \(entry.fileName).")
        }

        let compressedData = archiveData.subdata(in: compressedStart..<compressedEnd)
        let result: Data
        switch entry.compressionMethod {
        case 0:
            result = compressedData
        case 8:
            result = try inflateRawDeflate(compressedData)
        default:
            throw ExtractorError.unsupportedCompression(entry.compressionMethod)
        }

        if entry.uncompressedSize != 0 && result.count != Int(entry.uncompressedSize) {
            throw ExtractorError.invalidArchive("Unexpected export.xml size after decompression.")
        }

        return result
    }

    private static func locateEndOfCentralDirectory(in data: Data) throws -> Int {
        guard data.count >= 22 else {
            throw ExtractorError.invalidArchive("ZIP is too small to contain End of Central Directory.")
        }

        let maxSearchLength = min(data.count, 22 + 65_535)
        let lowerBound = data.count - maxSearchLength
        var cursor = data.count - 22

        while cursor >= lowerBound {
            if try readUInt32LE(from: data, at: cursor) == endOfCentralDirectorySignature {
                return cursor
            }
            cursor -= 1
        }

        throw ExtractorError.invalidArchive("Could not locate End of Central Directory in ZIP.")
    }

    private static func inflateRawDeflate(_ compressedData: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ExtractorError.decompressionFailed(initStatus)
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data()
        output.reserveCapacity(max(compressedData.count * 2, 32 * 1024))

        let chunkSize = 64 * 1024
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)

        return try compressedData.withUnsafeBytes { rawBuffer -> Data in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else {
                return Data()
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress)
            stream.avail_in = uInt(rawBuffer.count)

            while true {
                let status = outBuffer.withUnsafeMutableBytes { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(outBuffer, count: produced)
                }

                if status == Z_STREAM_END {
                    break
                }

                guard status == Z_OK else {
                    throw ExtractorError.decompressionFailed(status)
                }
            }

            return output
        }
    }

    private static func readUInt16LE(from data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw ExtractorError.invalidArchive("Unexpected end of ZIP while reading UInt16.")
        }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(from data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw ExtractorError.invalidArchive("Unexpected end of ZIP while reading UInt32.")
        }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
