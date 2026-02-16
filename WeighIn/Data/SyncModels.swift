import Foundation

struct SyncNoteRecord: Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let text: String
    let createdAt: Date
    let updatedAt: Date
    let isDeleted: Bool
}

struct SyncWeightRecord: Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let weight: Double
    let unitRawValue: String
    let sourceRawValue: String
    let noteID: String?
    let createdAt: Date
    let updatedAt: Date
    let isDeleted: Bool
}

struct SyncProfileRecord: Sendable {
    let birthday: Date?
    let genderRawValue: String
    let heightCentimeters: Double?
    let avatarPath: String?
    let updatedAt: Date
}

struct SyncSettingsRecord: Sendable {
    let defaultUnitRawValue: String
    let reminderEnabled: Bool
    let reminderHour: Int
    let reminderMinute: Int
    let onboardingCompleted: Bool
    let updatedAt: Date
}

struct SyncSnapshot: Sendable {
    let pendingNotes: [SyncNoteRecord]
    let pendingWeightLogs: [SyncWeightRecord]
    let profile: SyncProfileRecord
    let settings: SyncSettingsRecord
    let lastSyncAt: Date?
}

struct SyncPullPayload: Sendable {
    let notes: [SyncNoteRecord]
    let weightLogs: [SyncWeightRecord]
    let profile: SyncProfileRecord?
    let settings: SyncSettingsRecord?
}

struct SyncResult: Sendable {
    let syncedNoteIDs: [String]
    let syncedWeightIDs: [String]
    let pullPayload: SyncPullPayload
    let syncedAt: Date
}
