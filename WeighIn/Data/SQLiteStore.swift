import Foundation
import SQLite3

final class SQLiteStore {
    enum StoreError: Error {
        case openFailed(String)
        case executionFailed(String)
        case preparationFailed(String)
    }

    private let db: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL = SQLiteStore.defaultDatabaseURL()) throws {
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

    func fetchWeightLogs() throws -> [WeightLog] {
        try query(
            sql: """
            SELECT id, timestamp, weight, unit, source, note_id
            FROM weight_logs
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

    func insert(_ note: NoteEntry) throws {
        try execute(
            """
            INSERT OR REPLACE INTO notes (id, timestamp, text)
            VALUES (?, ?, ?);
            """,
            bindings: [
                .text(note.id),
                .double(note.timestamp.timeIntervalSince1970),
                .text(note.text)
            ]
        )
    }

    func insert(_ log: WeightLog) throws {
        try execute(
            """
            INSERT OR REPLACE INTO weight_logs (id, timestamp, weight, unit, source, note_id)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(log.id),
                .double(log.timestamp.timeIntervalSince1970),
                .double(log.weight),
                .text(log.unit.rawValue),
                .text(log.source.rawValue),
                log.noteID.map(SQLiteValue.text) ?? .null
            ]
        )
    }

    func fetchSettings() throws -> AppSettings {
        let settings: [AppSettings] = try query(
            sql: """
            SELECT default_unit, reminder_enabled, reminder_hour, reminder_minute
            FROM app_settings
            WHERE id = 1;
            """
        ) { statement in
            AppSettings(
                defaultUnit: WeightUnit(rawValue: string(from: statement, index: 0)) ?? .lbs,
                reminderEnabled: sqlite3_column_int(statement, 1) == 1,
                reminderHour: Int(sqlite3_column_int(statement, 2)),
                reminderMinute: Int(sqlite3_column_int(statement, 3))
            )
        }

        return settings.first ?? .default
    }

    func upsert(settings: AppSettings) throws {
        try execute(
            """
            INSERT INTO app_settings (id, default_unit, reminder_enabled, reminder_hour, reminder_minute)
            VALUES (1, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
            default_unit = excluded.default_unit,
            reminder_enabled = excluded.reminder_enabled,
            reminder_hour = excluded.reminder_hour,
            reminder_minute = excluded.reminder_minute;
            """,
            bindings: [
                .text(settings.defaultUnit.rawValue),
                .int(settings.reminderEnabled ? 1 : 0),
                .int(Int64(settings.reminderHour)),
                .int(Int64(settings.reminderMinute))
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
            let birthdayValue = sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let gender = Gender(rawValue: string(from: statement, index: 1)) ?? .undisclosed
            let heightValue = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)
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

    func upsert(profile: UserProfile) throws {
        try execute(
            """
            INSERT INTO user_profile (id, birthday, gender, height_cm, avatar_path)
            VALUES (1, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
            birthday = excluded.birthday,
            gender = excluded.gender,
            height_cm = excluded.height_cm,
            avatar_path = excluded.avatar_path;
            """,
            bindings: [
                profile.birthday.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(profile.gender.rawValue),
                profile.heightCentimeters.map(SQLiteValue.double) ?? .null,
                profile.avatarPath.map(SQLiteValue.text) ?? .null
            ]
        )
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS notes (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                text TEXT NOT NULL
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
                reminder_minute INTEGER NOT NULL
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
                avatar_path TEXT
            );
            """
        )

        try execute(
            """
            INSERT OR IGNORE INTO app_settings (id, default_unit, reminder_enabled, reminder_hour, reminder_minute)
            VALUES (1, 'lbs', 1, 7, 0);
            """
        )

        try execute(
            """
            INSERT OR IGNORE INTO user_profile (id, birthday, gender, height_cm, avatar_path)
            VALUES (1, NULL, 'undisclosed', NULL, NULL);
            """
        )
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
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(map(statement!))
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
}

private enum SQLiteValue {
    case null
    case text(String)
    case double(Double)
    case int(Int64)
}
