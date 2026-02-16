import Foundation
import SQLite3

final class SQLiteStore {
    enum StoreError: Error {
        case openFailed(String)
        case executionFailed(String)
        case preparationFailed(String)
    }

    private enum RowSyncState: String {
        case pending
        case synced
        case error
    }

    private let databaseURL: URL
    private let db: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL = SQLiteStore.defaultDatabaseURL()) throws {
        self.databaseURL = databaseURL
        let fileManager = FileManager.default
        let directory = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var pointer: OpaquePointer?
        if sqlite3_open(databaseURL.path, &pointer) != SQLITE_OK {
            let message = pointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(pointer)
            throw StoreError.openFailed(message)
        }

        guard let pointer else {
            throw StoreError.openFailed("Unable to allocate database pointer")
        }

        db = pointer
        try execute("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    static func defaultDatabaseURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return root.appendingPathComponent("WeighIn", isDirectory: true)
            .appendingPathComponent("weighin.sqlite")
    }

    func databaseFileURL() -> URL {
        databaseURL
    }

    func exportDatabaseData() throws -> Data {
        let temporaryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weighin-export-\(UUID().uuidString).sqlite")

        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        var destinationDB: OpaquePointer?
        guard sqlite3_open(temporaryURL.path, &destinationDB) == SQLITE_OK else {
            let message = destinationDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(destinationDB)
            throw StoreError.openFailed(message)
        }

        guard let destinationDB else {
            throw StoreError.openFailed("Unable to allocate export database pointer")
        }

        defer {
            sqlite3_close(destinationDB)
        }

        try backup(from: db, to: destinationDB)
        return try Data(contentsOf: temporaryURL)
    }

    func importDatabase(from sourceURL: URL) throws {
        var sourceDB: OpaquePointer?
        guard sqlite3_open_v2(sourceURL.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = sourceDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(sourceDB)
            throw StoreError.openFailed(message)
        }

        guard let sourceDB else {
            throw StoreError.openFailed("Unable to allocate import database pointer")
        }

        defer {
            sqlite3_close(sourceDB)
        }

        try backup(from: sourceDB, to: db)
        try execute("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    func mergeDatabaseWithoutOverwriting(from sourceURL: URL) throws {
        let escapedPath = sourceURL.path.replacingOccurrences(of: "'", with: "''")
        try execute("ATTACH DATABASE '\(escapedPath)' AS imported;")
        defer {
            try? execute("DETACH DATABASE imported;")
        }

        try execute(
            """
            INSERT INTO notes (id, timestamp, text, created_at, updated_at, is_deleted, sync_state)
            SELECT imported_notes.id,
                   imported_notes.timestamp,
                   imported_notes.text,
                   imported_notes.created_at,
                   imported_notes.updated_at,
                   imported_notes.is_deleted,
                   imported_notes.sync_state
            FROM imported.notes AS imported_notes
            WHERE imported_notes.is_deleted = 0
              AND NOT EXISTS (
                SELECT 1
                FROM notes AS local_notes
                WHERE local_notes.id = imported_notes.id
              );
            """
        )

        try execute(
            """
            INSERT INTO weight_logs (id, timestamp, weight, unit, source, note_id, created_at, updated_at, is_deleted, sync_state)
            SELECT imported_logs.id,
                   imported_logs.timestamp,
                   imported_logs.weight,
                   imported_logs.unit,
                   imported_logs.source,
                   CASE
                       WHEN imported_logs.note_id IS NULL THEN NULL
                       WHEN EXISTS (
                           SELECT 1
                           FROM notes AS note_reference
                           WHERE note_reference.id = imported_logs.note_id
                             AND note_reference.is_deleted = 0
                       ) THEN imported_logs.note_id
                       ELSE NULL
                   END,
                   imported_logs.created_at,
                   imported_logs.updated_at,
                   imported_logs.is_deleted,
                   imported_logs.sync_state
            FROM imported.weight_logs AS imported_logs
            WHERE imported_logs.is_deleted = 0
              AND NOT EXISTS (
                SELECT 1
                FROM weight_logs AS local_logs
                WHERE local_logs.id = imported_logs.id
              );
            """
        )
    }

    static func createDatabaseSnapshot(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        var sourceDB: OpaquePointer?
        guard sqlite3_open_v2(sourceURL.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = sourceDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(sourceDB)
            throw StoreError.openFailed(message)
        }
        guard let sourceDB else {
            throw StoreError.openFailed("Unable to allocate source database pointer")
        }
        defer {
            sqlite3_close(sourceDB)
        }

        var destinationDB: OpaquePointer?
        guard sqlite3_open(destinationURL.path, &destinationDB) == SQLITE_OK else {
            let message = destinationDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(destinationDB)
            throw StoreError.openFailed(message)
        }
        guard let destinationDB else {
            throw StoreError.openFailed("Unable to allocate destination database pointer")
        }
        defer {
            sqlite3_close(destinationDB)
        }

        guard let backupHandle = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            throw StoreError.executionFailed(String(cString: sqlite3_errmsg(destinationDB)))
        }
        defer {
            sqlite3_backup_finish(backupHandle)
        }

        let stepResult = sqlite3_backup_step(backupHandle, -1)
        guard stepResult == SQLITE_DONE else {
            throw StoreError.executionFailed(String(cString: sqlite3_errmsg(destinationDB)))
        }
    }

    func fetchWeightLogs() throws -> [WeightLog] {
        try query(
            sql: """
            SELECT id, timestamp, weight, unit, source, note_id
            FROM weight_logs
            WHERE is_deleted = 0
            ORDER BY timestamp DESC;
            """
        ) { statement in
            let id = string(from: statement, index: 0)
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let weight = sqlite3_column_double(statement, 2)
            let unit = WeightUnit(rawValue: string(from: statement, index: 3)) ?? .lbs
            let source = WeightLogSource(rawValue: string(from: statement, index: 4)) ?? .manual
            let noteID = optionalString(from: statement, index: 5)
            return WeightLog(id: id, timestamp: timestamp, weight: weight, unit: unit, source: source, noteID: noteID)
        }
    }

    func fetchNotes() throws -> [NoteEntry] {
        try query(
            sql: """
            SELECT id, timestamp, text
            FROM notes
            WHERE is_deleted = 0
            ORDER BY timestamp DESC;
            """
        ) { statement in
            NoteEntry(
                id: string(from: statement, index: 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                text: string(from: statement, index: 2)
            )
        }
    }

    func fetchPendingNoteRecords() throws -> [SyncNoteRecord] {
        try query(
            sql: """
            SELECT id, timestamp, text, created_at, updated_at, is_deleted
            FROM notes
            WHERE sync_state = ?
            ORDER BY updated_at ASC;
            """,
            bindings: [.text(RowSyncState.pending.rawValue)]
        ) { statement in
            SyncNoteRecord(
                id: string(from: statement, index: 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                text: string(from: statement, index: 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                isDeleted: sqlite3_column_int(statement, 5) == 1
            )
        }
    }

    func fetchPendingWeightRecords() throws -> [SyncWeightRecord] {
        try query(
            sql: """
            SELECT id, timestamp, weight, unit, source, note_id, created_at, updated_at, is_deleted
            FROM weight_logs
            WHERE sync_state = ?
            ORDER BY updated_at ASC;
            """,
            bindings: [.text(RowSyncState.pending.rawValue)]
        ) { statement in
            SyncWeightRecord(
                id: string(from: statement, index: 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                weight: sqlite3_column_double(statement, 2),
                unitRawValue: string(from: statement, index: 3),
                sourceRawValue: string(from: statement, index: 4),
                noteID: optionalString(from: statement, index: 5),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                isDeleted: sqlite3_column_int(statement, 8) == 1
            )
        }
    }

    func insert(_ note: NoteEntry) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            INSERT INTO notes (id, timestamp, text, created_at, updated_at, is_deleted, sync_state)
            VALUES (?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT(id) DO UPDATE SET
            timestamp = excluded.timestamp,
            text = excluded.text,
            updated_at = excluded.updated_at,
            is_deleted = 0,
            sync_state = excluded.sync_state;
            """,
            bindings: [
                .text(note.id),
                .double(note.timestamp.timeIntervalSince1970),
                .text(note.text),
                .double(now),
                .double(now),
                .text(RowSyncState.pending.rawValue)
            ]
        )
    }

    func update(_ note: NoteEntry) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            UPDATE notes
            SET timestamp = ?,
                text = ?,
                updated_at = ?,
                is_deleted = 0,
                sync_state = ?
            WHERE id = ?;
            """,
            bindings: [
                .double(note.timestamp.timeIntervalSince1970),
                .text(note.text),
                .double(now),
                .text(RowSyncState.pending.rawValue),
                .text(note.id)
            ]
        )
    }

    func insert(_ log: WeightLog) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            INSERT INTO weight_logs (id, timestamp, weight, unit, source, note_id, created_at, updated_at, is_deleted, sync_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT(id) DO UPDATE SET
            timestamp = excluded.timestamp,
            weight = excluded.weight,
            unit = excluded.unit,
            source = excluded.source,
            note_id = excluded.note_id,
            updated_at = excluded.updated_at,
            is_deleted = 0,
            sync_state = excluded.sync_state;
            """,
            bindings: [
                .text(log.id),
                .double(log.timestamp.timeIntervalSince1970),
                .double(log.weight),
                .text(log.unit.rawValue),
                .text(log.source.rawValue),
                log.noteID.map(SQLiteValue.text) ?? .null,
                .double(now),
                .double(now),
                .text(RowSyncState.pending.rawValue)
            ]
        )
    }

    func update(_ log: WeightLog) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            UPDATE weight_logs
            SET timestamp = ?,
                weight = ?,
                unit = ?,
                source = ?,
                note_id = ?,
                updated_at = ?,
                is_deleted = 0,
                sync_state = ?
            WHERE id = ?;
            """,
            bindings: [
                .double(log.timestamp.timeIntervalSince1970),
                .double(log.weight),
                .text(log.unit.rawValue),
                .text(log.source.rawValue),
                log.noteID.map(SQLiteValue.text) ?? .null,
                .double(now),
                .text(RowSyncState.pending.rawValue),
                .text(log.id)
            ]
        )
    }

    func deleteWeightLog(id: String) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            UPDATE weight_logs
            SET is_deleted = 1,
                updated_at = ?,
                sync_state = ?
            WHERE id = ?;
            """,
            bindings: [
                .double(now),
                .text(RowSyncState.pending.rawValue),
                .text(id)
            ]
        )
    }

    func deleteNote(id: String) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            UPDATE notes
            SET is_deleted = 1,
                updated_at = ?,
                sync_state = ?
            WHERE id = ?;
            """,
            bindings: [
                .double(now),
                .text(RowSyncState.pending.rawValue),
                .text(id)
            ]
        )
    }

    func markNoteRecordsSynced(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            try execute(
                """
                UPDATE notes
                SET sync_state = ?
                WHERE id = ?;
                """,
                bindings: [
                    .text(RowSyncState.synced.rawValue),
                    .text(id)
                ]
            )
        }
    }

    func markWeightRecordsSynced(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            try execute(
                """
                UPDATE weight_logs
                SET sync_state = ?
                WHERE id = ?;
                """,
                bindings: [
                    .text(RowSyncState.synced.rawValue),
                    .text(id)
                ]
            )
        }
    }

    func applyRemotePullPayload(_ payload: SyncPullPayload) throws {
        for note in payload.notes {
            try applyRemote(note: note)
        }

        for log in payload.weightLogs {
            try applyRemote(log: log)
        }

        if let profile = payload.profile {
            try applyRemote(profile: profile)
        }

        if let settings = payload.settings {
            try applyRemote(settings: settings)
        }
    }

    func fetchSettings() throws -> AppSettings {
        let settings: [AppSettings] = try query(
            sql: """
            SELECT default_unit,
                   reminder_enabled,
                   reminder_hour,
                   reminder_minute,
                   has_completed_onboarding,
                   icloud_sync_enabled,
                   last_sync_at,
                   last_sync_error
            FROM app_settings
            WHERE id = 1;
            """
        ) { statement in
            let lastSyncAt: Date?
            if sqlite3_column_type(statement, 6) == SQLITE_NULL {
                lastSyncAt = nil
            } else {
                lastSyncAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            }

            return AppSettings(
                defaultUnit: WeightUnit(rawValue: string(from: statement, index: 0)) ?? .lbs,
                reminderEnabled: sqlite3_column_int(statement, 1) == 1,
                reminderHour: Int(sqlite3_column_int(statement, 2)),
                reminderMinute: Int(sqlite3_column_int(statement, 3)),
                hasCompletedOnboarding: sqlite3_column_int(statement, 4) == 1,
                iCloudSyncEnabled: sqlite3_column_int(statement, 5) == 1,
                lastSyncAt: lastSyncAt,
                lastSyncError: optionalString(from: statement, index: 7)
            )
        }

        return settings.first ?? .default
    }

    func fetchSyncSettingsRecord() throws -> SyncSettingsRecord {
        let records: [SyncSettingsRecord] = try query(
            sql: """
            SELECT default_unit, reminder_enabled, reminder_hour, reminder_minute, has_completed_onboarding, updated_at
            FROM app_settings
            WHERE id = 1;
            """
        ) { statement in
            SyncSettingsRecord(
                defaultUnitRawValue: string(from: statement, index: 0),
                reminderEnabled: sqlite3_column_int(statement, 1) == 1,
                reminderHour: Int(sqlite3_column_int(statement, 2)),
                reminderMinute: Int(sqlite3_column_int(statement, 3)),
                onboardingCompleted: sqlite3_column_int(statement, 4) == 1,
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            )
        }

        if let first = records.first {
            return first
        }

        return SyncSettingsRecord(
            defaultUnitRawValue: WeightUnit.lbs.rawValue,
            reminderEnabled: true,
            reminderHour: 7,
            reminderMinute: 0,
            onboardingCompleted: false,
            updatedAt: Date()
        )
    }

    func upsert(settings: AppSettings) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            INSERT INTO app_settings (
                id,
                default_unit,
                reminder_enabled,
                reminder_hour,
                reminder_minute,
                has_completed_onboarding,
                icloud_sync_enabled,
                last_sync_at,
                last_sync_error,
                updated_at
            )
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                default_unit = excluded.default_unit,
                reminder_enabled = excluded.reminder_enabled,
                reminder_hour = excluded.reminder_hour,
                reminder_minute = excluded.reminder_minute,
                has_completed_onboarding = excluded.has_completed_onboarding,
                icloud_sync_enabled = excluded.icloud_sync_enabled,
                last_sync_at = excluded.last_sync_at,
                last_sync_error = excluded.last_sync_error,
                updated_at = excluded.updated_at;
            """,
            bindings: [
                .text(settings.defaultUnit.rawValue),
                .int(settings.reminderEnabled ? 1 : 0),
                .int(Int64(settings.reminderHour)),
                .int(Int64(settings.reminderMinute)),
                .int(settings.hasCompletedOnboarding ? 1 : 0),
                .int(settings.iCloudSyncEnabled ? 1 : 0),
                settings.lastSyncAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                settings.lastSyncError.map(SQLiteValue.text) ?? .null,
                .double(now)
            ]
        )
    }

    func updateSyncStatus(lastSyncAt: Date?, lastSyncError: String?) throws {
        try execute(
            """
            UPDATE app_settings
            SET last_sync_at = ?,
                last_sync_error = ?
            WHERE id = 1;
            """,
            bindings: [
                lastSyncAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                lastSyncError.map(SQLiteValue.text) ?? .null
            ]
        )
    }

    func fetchProfile() throws -> UserProfile {
        let profiles: [UserProfile] = try query(
            sql: """
            SELECT birthday, gender, height_cm, avatar_path
            FROM user_profile
            WHERE id = 1;
            """
        ) { statement in
            let birthdayValue = sqlite3_column_type(statement, 0) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let gender = Gender(rawValue: string(from: statement, index: 1)) ?? .undisclosed
            let heightValue = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 2)
            let avatarPath = optionalString(from: statement, index: 3)
            return UserProfile(
                birthday: birthdayValue,
                gender: gender,
                heightCentimeters: heightValue,
                avatarPath: avatarPath
            )
        }

        return profiles.first ?? .empty
    }

    func fetchSyncProfileRecord() throws -> SyncProfileRecord {
        let profiles: [SyncProfileRecord] = try query(
            sql: """
            SELECT birthday, gender, height_cm, avatar_path, updated_at
            FROM user_profile
            WHERE id = 1;
            """
        ) { statement in
            let birthdayValue = sqlite3_column_type(statement, 0) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let heightValue = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 2)
            return SyncProfileRecord(
                birthday: birthdayValue,
                genderRawValue: string(from: statement, index: 1),
                heightCentimeters: heightValue,
                avatarPath: optionalString(from: statement, index: 3),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            )
        }

        if let first = profiles.first {
            return first
        }

        return SyncProfileRecord(
            birthday: nil,
            genderRawValue: Gender.undisclosed.rawValue,
            heightCentimeters: nil,
            avatarPath: nil,
            updatedAt: Date()
        )
    }

    func upsert(profile: UserProfile) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            INSERT INTO user_profile (id, birthday, gender, height_cm, avatar_path, updated_at)
            VALUES (1, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                birthday = excluded.birthday,
                gender = excluded.gender,
                height_cm = excluded.height_cm,
                avatar_path = excluded.avatar_path,
                updated_at = excluded.updated_at;
            """,
            bindings: [
                profile.birthday.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(profile.gender.rawValue),
                profile.heightCentimeters.map(SQLiteValue.double) ?? .null,
                profile.avatarPath.map(SQLiteValue.text) ?? .null,
                .double(now)
            ]
        )
    }

    private func applyRemote(note: SyncNoteRecord) throws {
        try execute(
            """
            INSERT INTO notes (id, timestamp, text, created_at, updated_at, is_deleted, sync_state)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                timestamp = excluded.timestamp,
                text = excluded.text,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                is_deleted = excluded.is_deleted,
                sync_state = excluded.sync_state
            WHERE excluded.updated_at >= notes.updated_at;
            """,
            bindings: [
                .text(note.id),
                .double(note.timestamp.timeIntervalSince1970),
                .text(note.text),
                .double(note.createdAt.timeIntervalSince1970),
                .double(note.updatedAt.timeIntervalSince1970),
                .int(note.isDeleted ? 1 : 0),
                .text(RowSyncState.synced.rawValue)
            ]
        )
    }

    private func applyRemote(log: SyncWeightRecord) throws {
        try execute(
            """
            INSERT INTO weight_logs (id, timestamp, weight, unit, source, note_id, created_at, updated_at, is_deleted, sync_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                timestamp = excluded.timestamp,
                weight = excluded.weight,
                unit = excluded.unit,
                source = excluded.source,
                note_id = excluded.note_id,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                is_deleted = excluded.is_deleted,
                sync_state = excluded.sync_state
            WHERE excluded.updated_at >= weight_logs.updated_at;
            """,
            bindings: [
                .text(log.id),
                .double(log.timestamp.timeIntervalSince1970),
                .double(log.weight),
                .text(log.unitRawValue),
                .text(log.sourceRawValue),
                log.noteID.map(SQLiteValue.text) ?? .null,
                .double(log.createdAt.timeIntervalSince1970),
                .double(log.updatedAt.timeIntervalSince1970),
                .int(log.isDeleted ? 1 : 0),
                .text(RowSyncState.synced.rawValue)
            ]
        )
    }

    private func applyRemote(profile: SyncProfileRecord) throws {
        try execute(
            """
            UPDATE user_profile
            SET birthday = ?,
                gender = ?,
                height_cm = ?,
                avatar_path = ?,
                updated_at = ?
            WHERE id = 1
              AND updated_at <= ?;
            """,
            bindings: [
                profile.birthday.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(profile.genderRawValue),
                profile.heightCentimeters.map(SQLiteValue.double) ?? .null,
                profile.avatarPath.map(SQLiteValue.text) ?? .null,
                .double(profile.updatedAt.timeIntervalSince1970),
                .double(profile.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    private func applyRemote(settings: SyncSettingsRecord) throws {
        try execute(
            """
            UPDATE app_settings
            SET default_unit = ?,
                reminder_enabled = ?,
                reminder_hour = ?,
                reminder_minute = ?,
                has_completed_onboarding = ?,
                updated_at = ?
            WHERE id = 1
              AND updated_at <= ?;
            """,
            bindings: [
                .text(settings.defaultUnitRawValue),
                .int(settings.reminderEnabled ? 1 : 0),
                .int(Int64(settings.reminderHour)),
                .int(Int64(settings.reminderMinute)),
                .int(settings.onboardingCompleted ? 1 : 0),
                .double(settings.updatedAt.timeIntervalSince1970),
                .double(settings.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS notes (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                text TEXT NOT NULL,
                created_at REAL NOT NULL DEFAULT (strftime('%s','now')),
                updated_at REAL NOT NULL DEFAULT (strftime('%s','now')),
                is_deleted INTEGER NOT NULL DEFAULT 0,
                sync_state TEXT NOT NULL DEFAULT 'pending'
            );
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS weight_logs (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                weight REAL NOT NULL,
                unit TEXT NOT NULL,
                source TEXT NOT NULL,
                note_id TEXT,
                created_at REAL NOT NULL DEFAULT (strftime('%s','now')),
                updated_at REAL NOT NULL DEFAULT (strftime('%s','now')),
                is_deleted INTEGER NOT NULL DEFAULT 0,
                sync_state TEXT NOT NULL DEFAULT 'pending',
                FOREIGN KEY(note_id) REFERENCES notes(id) ON DELETE SET NULL
            );
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS app_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                default_unit TEXT NOT NULL,
                reminder_enabled INTEGER NOT NULL,
                reminder_hour INTEGER NOT NULL,
                reminder_minute INTEGER NOT NULL,
                has_completed_onboarding INTEGER NOT NULL DEFAULT 0,
                icloud_sync_enabled INTEGER NOT NULL DEFAULT 0,
                last_sync_at REAL,
                last_sync_error TEXT,
                updated_at REAL NOT NULL DEFAULT (strftime('%s','now'))
            );
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS user_profile (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                birthday REAL,
                gender TEXT NOT NULL,
                height_cm REAL,
                avatar_path TEXT,
                updated_at REAL NOT NULL DEFAULT (strftime('%s','now'))
            );
            """
        )

        try ensureColumn(table: "notes", name: "created_at", definition: "REAL")
        try ensureColumn(table: "notes", name: "updated_at", definition: "REAL")
        try ensureColumn(table: "notes", name: "is_deleted", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "notes", name: "sync_state", definition: "TEXT NOT NULL DEFAULT 'pending'")

        try ensureColumn(table: "weight_logs", name: "created_at", definition: "REAL")
        try ensureColumn(table: "weight_logs", name: "updated_at", definition: "REAL")
        try ensureColumn(table: "weight_logs", name: "is_deleted", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "weight_logs", name: "sync_state", definition: "TEXT NOT NULL DEFAULT 'pending'")

        try ensureColumn(table: "app_settings", name: "has_completed_onboarding", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "app_settings", name: "icloud_sync_enabled", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "app_settings", name: "last_sync_at", definition: "REAL")
        try ensureColumn(table: "app_settings", name: "last_sync_error", definition: "TEXT")
        try ensureColumn(table: "app_settings", name: "updated_at", definition: "REAL")

        try ensureColumn(table: "user_profile", name: "updated_at", definition: "REAL")

        try execute(
            """
            UPDATE notes
            SET created_at = COALESCE(created_at, timestamp),
                updated_at = COALESCE(updated_at, timestamp),
                is_deleted = COALESCE(is_deleted, 0),
                sync_state = COALESCE(sync_state, 'pending');
            """
        )

        try execute(
            """
            UPDATE weight_logs
            SET created_at = COALESCE(created_at, timestamp),
                updated_at = COALESCE(updated_at, timestamp),
                is_deleted = COALESCE(is_deleted, 0),
                sync_state = COALESCE(sync_state, 'pending');
            """
        )

        try execute(
            """
            INSERT OR IGNORE INTO app_settings (
                id,
                default_unit,
                reminder_enabled,
                reminder_hour,
                reminder_minute,
                has_completed_onboarding,
                icloud_sync_enabled,
                last_sync_at,
                last_sync_error,
                updated_at
            )
            VALUES (1, 'lbs', 1, 7, 0, 0, 0, NULL, NULL, strftime('%s','now'));
            """
        )

        try execute(
            """
            UPDATE app_settings
            SET updated_at = COALESCE(updated_at, strftime('%s','now'))
            WHERE id = 1;
            """
        )

        try execute(
            """
            INSERT OR IGNORE INTO user_profile (id, birthday, gender, height_cm, avatar_path, updated_at)
            VALUES (1, NULL, 'undisclosed', NULL, NULL, strftime('%s','now'));
            """
        )

        try execute(
            """
            UPDATE user_profile
            SET updated_at = COALESCE(updated_at, strftime('%s','now'))
            WHERE id = 1;
            """
        )
    }

    private func ensureColumn(table: String, name: String, definition: String) throws {
        guard try !columnExists(name: name, in: table) else {
            return
        }

        try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(definition);")
    }

    private func columnExists(name: String, in table: String) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.preparationFailed(String(cString: sqlite3_errmsg(db)))
        }

        defer {
            sqlite3_finalize(statement)
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: pointer) == name {
                return true
            }
        }

        return false
    }

    private func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.preparationFailed(String(cString: sqlite3_errmsg(db)))
        }

        defer {
            sqlite3_finalize(statement)
        }

        try bind(bindings, to: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(sql: String, bindings: [SQLiteValue] = [], map: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.preparationFailed(String(cString: sqlite3_errmsg(db)))
        }

        defer {
            sqlite3_finalize(statement)
        }

        try bind(bindings, to: statement)

        var rows: [T] = []
        guard let statement else { return rows }

        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(map(statement))
        }
        return rows
    }

    private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (index, value) in bindings.enumerated() {
            let column = Int32(index + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, column)
            case .text(let string):
                sqlite3_bind_text(statement, column, string, -1, transient)
            case .double(let number):
                sqlite3_bind_double(statement, column, number)
            case .int(let number):
                sqlite3_bind_int64(statement, column, number)
            }
        }
    }

    private func string(from statement: OpaquePointer, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalString(from statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return string(from: statement, index: index)
    }

    private func backup(from source: OpaquePointer, to destination: OpaquePointer) throws {
        guard let backupHandle = sqlite3_backup_init(destination, "main", source, "main") else {
            throw StoreError.executionFailed(String(cString: sqlite3_errmsg(destination)))
        }

        defer {
            sqlite3_backup_finish(backupHandle)
        }

        let stepResult = sqlite3_backup_step(backupHandle, -1)
        guard stepResult == SQLITE_DONE else {
            throw StoreError.executionFailed(String(cString: sqlite3_errmsg(destination)))
        }
    }
}

private enum SQLiteValue {
    case null
    case text(String)
    case double(Double)
    case int(Int64)
}
