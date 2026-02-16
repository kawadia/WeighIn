import Foundation
@testable import WeighIn

enum TestSupport {
    static func makeTempDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weighin-tests-\(UUID().uuidString).sqlite")
    }

    @MainActor
    static func makeRepository(cloudKitSyncFeatureEnabled: Bool = false) throws -> AppRepository {
        let store = try SQLiteStore(databaseURL: makeTempDatabaseURL())
        return AppRepository(
            store: store,
            syncService: nil,
            cloudKitSyncFeatureEnabled: cloudKitSyncFeatureEnabled,
            reminderScheduler: { _, _, _ in }
        )
    }
}
