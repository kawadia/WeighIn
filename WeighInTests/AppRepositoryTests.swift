import XCTest
@testable import WeighIn

@MainActor
final class AppRepositoryTests: XCTestCase {
    func testAddWeightLogCreatesLinkedTrimmedNote() throws {
        let repository = try TestSupport.makeRepository()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        repository.addWeightLog(
            weight: 182.4,
            timestamp: timestamp,
            noteText: "  Fasted morning  ",
            source: .manual
        )

        XCTAssertEqual(repository.logs.count, 1)
        XCTAssertEqual(repository.notes.count, 1)

        guard let log = repository.logs.first else {
            return XCTFail("Expected a saved log")
        }

        XCTAssertEqual(log.weight, 182.4, accuracy: 0.0001)
        XCTAssertEqual(log.source, .manual)
        XCTAssertNotNil(log.noteID)
        XCTAssertEqual(repository.note(for: log)?.text, "Fasted morning")
    }

    func testUpdateWeightLogCreatesUpdatesThenRemovesNote() throws {
        let repository = try TestSupport.makeRepository()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        repository.addWeightLog(
            weight: 180.0,
            timestamp: timestamp,
            noteText: nil,
            source: .manual
        )

        guard let original = repository.logs.first else {
            return XCTFail("Expected a saved log")
        }

        repository.updateWeightLog(
            original,
            weight: 180.0,
            timestamp: timestamp,
            noteText: " first "
        )

        guard let withNote = repository.logs.first else {
            return XCTFail("Expected updated log")
        }

        XCTAssertEqual(repository.notes.count, 1)
        XCTAssertEqual(repository.note(for: withNote)?.text, "first")
        XCTAssertNotNil(withNote.noteID)

        repository.updateWeightLog(
            withNote,
            weight: 181.0,
            timestamp: timestamp.addingTimeInterval(60),
            noteText: "second"
        )

        guard let updatedNoteLog = repository.logs.first else {
            return XCTFail("Expected second update")
        }

        XCTAssertEqual(repository.notes.count, 1)
        XCTAssertEqual(repository.note(for: updatedNoteLog)?.text, "second")

        repository.updateWeightLog(
            updatedNoteLog,
            weight: 182.0,
            timestamp: timestamp.addingTimeInterval(120),
            noteText: "   "
        )

        XCTAssertEqual(repository.notes.count, 0)
        XCTAssertNil(repository.logs.first?.noteID)
    }

    func testDeleteWeightLogRemovesLinkedNote() throws {
        let repository = try TestSupport.makeRepository()

        repository.addWeightLog(
            weight: 175.0,
            timestamp: Date(),
            noteText: "Test note",
            source: .manual
        )

        guard let log = repository.logs.first else {
            return XCTFail("Expected a saved log")
        }

        repository.deleteWeightLog(log)

        XCTAssertEqual(repository.logs.count, 0)
        XCTAssertEqual(repository.notes.count, 0)
    }

    func testChartsCalculationsFilterConvertAndAverage() throws {
        let repository = try TestSupport.makeRepository()

        repository.addWeightLog(
            weight: 210.0,
            timestamp: Date().addingTimeInterval(-45 * 24 * 60 * 60),
            noteText: nil,
            source: .manual
        )
        repository.addWeightLog(
            weight: 200.0,
            timestamp: Date(),
            noteText: nil,
            source: .manual
        )

        XCTAssertEqual(repository.logs(in: .all).count, 2)
        XCTAssertEqual(repository.logs(in: .month).count, 1)

        let kgLog = WeightLog(
            timestamp: Date(),
            weight: 100.0,
            unit: .kg,
            source: .manual
        )
        XCTAssertEqual(repository.convertedWeight(kgLog, to: .lbs), 220.462262, accuracy: 0.0001)

        repository.settings.defaultUnit = .lbs
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let t2 = Date(timeIntervalSince1970: 3_000)
        let movingAverage = repository.movingAverage(
            for: [
                WeightLog(timestamp: t1, weight: 200.0, unit: .lbs, source: .manual),
                WeightLog(timestamp: t0, weight: 100.0, unit: .kg, source: .manual),
                WeightLog(timestamp: t2, weight: 90.0, unit: .kg, source: .manual)
            ],
            window: 2
        )

        XCTAssertEqual(movingAverage.count, 2)
        XCTAssertEqual(movingAverage[0].0, t1)
        XCTAssertEqual(movingAverage[0].1, 210.231131, accuracy: 0.001)
        XCTAssertEqual(movingAverage[1].0, t2)
        XCTAssertEqual(movingAverage[1].1, 199.208018, accuracy: 0.001)
    }

    func testSettingsAndProfilePersistenceForOnboarding() throws {
        let repository = try TestSupport.makeRepository()
        var updatedSettings = repository.settings
        updatedSettings.defaultUnit = .kg

        repository.updateSettings(updatedSettings)
        XCTAssertEqual(repository.settings.defaultUnit, .kg)

        var onboardingSettings = repository.settings
        onboardingSettings.hasCompletedOnboarding = true
        onboardingSettings.reminderEnabled = false

        let birthday = Date(timeIntervalSince1970: 900_000_000)
        let profile = UserProfile(
            birthday: birthday,
            gender: .female,
            heightCentimeters: 170.0,
            avatarPath: "avatar.png"
        )
        repository.completeOnboarding(with: onboardingSettings, profile: profile)

        XCTAssertTrue(repository.settings.hasCompletedOnboarding)
        XCTAssertFalse(repository.settings.reminderEnabled)
        XCTAssertEqual(repository.profile.gender, .female)
        XCTAssertEqual(repository.profile.heightCentimeters, 170.0)
        XCTAssertEqual(repository.profile.avatarPath, "avatar.png")
        XCTAssertEqual(repository.profile.birthday, birthday)
    }
}
