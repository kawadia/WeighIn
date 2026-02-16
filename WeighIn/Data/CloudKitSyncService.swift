import CloudKit
import Foundation

actor CloudKitSyncService {
    enum SyncError: LocalizedError {
        case accountUnavailable(CKAccountStatus)

        var errorDescription: String? {
            switch self {
            case .accountUnavailable(let status):
                switch status {
                case .couldNotDetermine:
                    return "Could not determine iCloud account status."
                case .available:
                    return nil
                case .restricted:
                    return "iCloud is restricted on this device."
                case .noAccount:
                    return "No iCloud account is signed in."
                case .temporarilyUnavailable:
                    return "iCloud is temporarily unavailable."
                @unknown default:
                    return "iCloud account is unavailable."
                }
            }
        }
    }

    private enum Constants {
        static let zoneName = "WeightReflectZone"

        static let noteRecordType = "Note"
        static let weightRecordType = "WeightLog"
        static let profileRecordType = "UserProfile"
        static let settingsRecordType = "AppSettings"

        static let profileRecordName = "profile_primary"
        static let settingsRecordName = "settings_primary"
    }

    private let container = CKContainer.default()
    private let zoneID = CKRecordZone.ID(zoneName: Constants.zoneName, ownerName: CKCurrentUserDefaultName)

    private var database: CKDatabase {
        container.privateCloudDatabase
    }

    func sync(snapshot: SyncSnapshot) async throws -> SyncResult {
        try await ensureAccountAvailable()
        try await ensureZoneExists()

        let recordsToSave = buildRecords(for: snapshot)
        let savedRecords = try await save(records: recordsToSave)
        let pullPayload = try await pullChanges(since: snapshot.lastSyncAt)

        let savedRecordNames = Set(savedRecords.map { $0.recordID.recordName })
        let syncedNoteIDs = snapshot.pendingNotes.map(\.id).filter { savedRecordNames.contains($0) }
        let syncedWeightIDs = snapshot.pendingWeightLogs.map(\.id).filter { savedRecordNames.contains($0) }

        return SyncResult(
            syncedNoteIDs: syncedNoteIDs,
            syncedWeightIDs: syncedWeightIDs,
            pullPayload: pullPayload,
            syncedAt: Date()
        )
    }

    private func ensureAccountAvailable() async throws {
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKAccountStatus, Error>) in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: status)
            }
        }

        guard status == .available else {
            throw SyncError.accountUnavailable(status)
        }
    }

    private func ensureZoneExists() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
        operation.qualityOfService = .utility

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }

    private func buildRecords(for snapshot: SyncSnapshot) -> [CKRecord] {
        var records: [CKRecord] = []
        records.reserveCapacity(snapshot.pendingNotes.count + snapshot.pendingWeightLogs.count + 2)

        for note in snapshot.pendingNotes {
            let recordID = CKRecord.ID(recordName: note.id, zoneID: zoneID)
            let record = CKRecord(recordType: Constants.noteRecordType, recordID: recordID)
            record["timestamp"] = note.timestamp as CKRecordValue
            record["text"] = note.text as CKRecordValue
            record["createdAt"] = note.createdAt as CKRecordValue
            record["updatedAt"] = note.updatedAt as CKRecordValue
            record["isDeleted"] = NSNumber(value: note.isDeleted)
            records.append(record)
        }

        for log in snapshot.pendingWeightLogs {
            let recordID = CKRecord.ID(recordName: log.id, zoneID: zoneID)
            let record = CKRecord(recordType: Constants.weightRecordType, recordID: recordID)
            record["timestamp"] = log.timestamp as CKRecordValue
            record["weight"] = NSNumber(value: log.weight)
            record["unit"] = log.unitRawValue as CKRecordValue
            record["source"] = log.sourceRawValue as CKRecordValue
            record["noteID"] = log.noteID as CKRecordValue?
            record["createdAt"] = log.createdAt as CKRecordValue
            record["updatedAt"] = log.updatedAt as CKRecordValue
            record["isDeleted"] = NSNumber(value: log.isDeleted)
            records.append(record)
        }

        let profileID = CKRecord.ID(recordName: Constants.profileRecordName, zoneID: zoneID)
        let profileRecord = CKRecord(recordType: Constants.profileRecordType, recordID: profileID)
        profileRecord["birthday"] = snapshot.profile.birthday as CKRecordValue?
        profileRecord["gender"] = snapshot.profile.genderRawValue as CKRecordValue
        profileRecord["heightCm"] = snapshot.profile.heightCentimeters.map { NSNumber(value: $0) }
        profileRecord["avatarPath"] = snapshot.profile.avatarPath as CKRecordValue?
        profileRecord["updatedAt"] = snapshot.profile.updatedAt as CKRecordValue
        records.append(profileRecord)

        let settingsID = CKRecord.ID(recordName: Constants.settingsRecordName, zoneID: zoneID)
        let settingsRecord = CKRecord(recordType: Constants.settingsRecordType, recordID: settingsID)
        settingsRecord["defaultUnit"] = snapshot.settings.defaultUnitRawValue as CKRecordValue
        settingsRecord["reminderEnabled"] = NSNumber(value: snapshot.settings.reminderEnabled)
        settingsRecord["reminderHour"] = NSNumber(value: snapshot.settings.reminderHour)
        settingsRecord["reminderMinute"] = NSNumber(value: snapshot.settings.reminderMinute)
        settingsRecord["onboardingCompleted"] = NSNumber(value: snapshot.settings.onboardingCompleted)
        settingsRecord["updatedAt"] = snapshot.settings.updatedAt as CKRecordValue
        records.append(settingsRecord)

        return records
    }

    private func save(records: [CKRecord]) async throws -> [CKRecord] {
        guard !records.isEmpty else { return [] }

        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.qualityOfService = .utility

        return try await withCheckedThrowingContinuation { continuation in
            var savedRecordsByID: [CKRecord.ID: CKRecord] = [:]

            operation.perRecordSaveBlock = { recordID, result in
                if case .success(let record) = result {
                    savedRecordsByID[recordID] = record
                }
            }

            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: Array(savedRecordsByID.values))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }

    private func pullChanges(since date: Date?) async throws -> SyncPullPayload {
        let noteRecords = try await fetchRecords(recordType: Constants.noteRecordType, updatedAfter: date)
        let weightRecords = try await fetchRecords(recordType: Constants.weightRecordType, updatedAfter: date)
        let profileRecords = try await fetchRecords(recordType: Constants.profileRecordType, updatedAfter: date)
        let settingsRecords = try await fetchRecords(recordType: Constants.settingsRecordType, updatedAfter: date)

        let notes = noteRecords.map { record in
            SyncNoteRecord(
                id: record.recordID.recordName,
                timestamp: dateValue("timestamp", in: record),
                text: stringValue("text", in: record, defaultValue: ""),
                createdAt: dateValue("createdAt", in: record),
                updatedAt: dateValue("updatedAt", in: record),
                isDeleted: boolValue("isDeleted", in: record)
            )
        }

        let weights = weightRecords.map { record in
            SyncWeightRecord(
                id: record.recordID.recordName,
                timestamp: dateValue("timestamp", in: record),
                weight: doubleValue("weight", in: record),
                unitRawValue: stringValue("unit", in: record, defaultValue: WeightUnit.lbs.rawValue),
                sourceRawValue: stringValue("source", in: record, defaultValue: WeightLogSource.manual.rawValue),
                noteID: record["noteID"] as? String,
                createdAt: dateValue("createdAt", in: record),
                updatedAt: dateValue("updatedAt", in: record),
                isDeleted: boolValue("isDeleted", in: record)
            )
        }

        let profile = profileRecords.max(by: { dateValue("updatedAt", in: $0, defaultValue: .distantPast) < dateValue("updatedAt", in: $1, defaultValue: .distantPast) }).map { record in
            SyncProfileRecord(
                birthday: record["birthday"] as? Date,
                genderRawValue: stringValue("gender", in: record, defaultValue: Gender.undisclosed.rawValue),
                heightCentimeters: optionalDoubleValue("heightCm", in: record),
                avatarPath: record["avatarPath"] as? String,
                updatedAt: dateValue("updatedAt", in: record)
            )
        }

        let settings = settingsRecords.max(by: { dateValue("updatedAt", in: $0, defaultValue: .distantPast) < dateValue("updatedAt", in: $1, defaultValue: .distantPast) }).map { record in
            SyncSettingsRecord(
                defaultUnitRawValue: stringValue("defaultUnit", in: record, defaultValue: WeightUnit.lbs.rawValue),
                reminderEnabled: boolValue("reminderEnabled", in: record, defaultValue: true),
                reminderHour: intValue("reminderHour", in: record, defaultValue: 7),
                reminderMinute: intValue("reminderMinute", in: record, defaultValue: 0),
                onboardingCompleted: boolValue("onboardingCompleted", in: record),
                updatedAt: dateValue("updatedAt", in: record)
            )
        }

        return SyncPullPayload(notes: notes, weightLogs: weights, profile: profile, settings: settings)
    }

    private func fetchRecords(recordType: String, updatedAfter: Date?) async throws -> [CKRecord] {
        let predicate: NSPredicate
        if let updatedAfter {
            predicate = NSPredicate(format: "updatedAt > %@", updatedAfter as NSDate)
        } else {
            predicate = NSPredicate(value: true)
        }

        var fetchedRecords: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let operation: CKQueryOperation
            if let cursor {
                operation = CKQueryOperation(cursor: cursor)
            } else {
                let query = CKQuery(recordType: recordType, predicate: predicate)
                operation = CKQueryOperation(query: query)
            }

            operation.zoneID = zoneID
            operation.resultsLimit = 200
            operation.qualityOfService = .utility

            let page = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([CKRecord], CKQueryOperation.Cursor?), Error>) in
                var pageRecords: [CKRecord] = []

                operation.recordMatchedBlock = { _, result in
                    if case .success(let record) = result {
                        pageRecords.append(record)
                    }
                }

                operation.queryResultBlock = { result in
                    switch result {
                    case .success(let nextCursor):
                        continuation.resume(returning: (pageRecords, nextCursor))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                database.add(operation)
            }

            fetchedRecords.append(contentsOf: page.0)
            cursor = page.1
        } while cursor != nil

        return fetchedRecords
    }

    private func stringValue(_ key: String, in record: CKRecord, defaultValue: String) -> String {
        (record[key] as? String) ?? defaultValue
    }

    private func intValue(_ key: String, in record: CKRecord, defaultValue: Int) -> Int {
        if let number = record[key] as? NSNumber {
            return number.intValue
        }
        return defaultValue
    }

    private func doubleValue(_ key: String, in record: CKRecord, defaultValue: Double = 0) -> Double {
        if let number = record[key] as? NSNumber {
            return number.doubleValue
        }
        return defaultValue
    }

    private func optionalDoubleValue(_ key: String, in record: CKRecord) -> Double? {
        (record[key] as? NSNumber)?.doubleValue
    }

    private func boolValue(_ key: String, in record: CKRecord, defaultValue: Bool = false) -> Bool {
        if let number = record[key] as? NSNumber {
            return number.boolValue
        }
        return defaultValue
    }

    private func dateValue(_ key: String, in record: CKRecord, defaultValue: Date = Date()) -> Date {
        (record[key] as? Date) ?? defaultValue
    }
}
