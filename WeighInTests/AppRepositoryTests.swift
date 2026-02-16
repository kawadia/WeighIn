import XCTest
@testable import WeighIn
import zlib

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

    func testCSVImportIsIdempotentAndCanClearLinkedNote() throws {
        let repository = try TestSupport.makeRepository()
        let csvWithNote = """
        timestamp,weight,unit,note
        2026-02-15T12:00:00Z,201.5,lbs, Had a salty dinner
        """

        repository.importCSV(from: Data(csvWithNote.utf8))
        repository.importCSV(from: Data(csvWithNote.utf8))

        XCTAssertEqual(repository.logs.count, 1)
        XCTAssertEqual(repository.notes.count, 1)

        let importedLog = try XCTUnwrap(repository.logs.first)
        XCTAssertEqual(importedLog.source, .csv)
        XCTAssertEqual(repository.note(for: importedLog)?.text, "Had a salty dinner")
        let deterministicLogID = importedLog.id

        let csvWithoutNote = """
        timestamp,weight,unit,note
        2026-02-15T12:00:00Z,201.5,lbs,
        """
        repository.importCSV(from: Data(csvWithoutNote.utf8))

        XCTAssertEqual(repository.logs.count, 1)
        XCTAssertEqual(repository.notes.count, 0)
        XCTAssertEqual(repository.logs.first?.id, deterministicLogID)
        XCTAssertNil(repository.logs.first?.noteID)
    }

    func testJSONImportIsIdempotentForSamePayload() throws {
        let source = try TestSupport.makeRepository()
        source.addWeightLog(
            weight: 179.8,
            timestamp: Date(timeIntervalSince1970: 1_706_000_000),
            noteText: "Recovered from poor sleep",
            source: .manual
        )

        var sourceSettings = source.settings
        sourceSettings.defaultUnit = .kg
        source.updateSettings(sourceSettings)
        source.updateProfile(
            UserProfile(
                birthday: nil,
                gender: .male,
                heightCentimeters: 182.0,
                avatarPath: nil
            )
        )

        let payload = source.exportJSON()
        let destination = try TestSupport.makeRepository()

        destination.importJSON(from: payload)
        destination.importJSON(from: payload)

        XCTAssertEqual(destination.logs.count, 1)
        XCTAssertEqual(destination.notes.count, 1)
        XCTAssertEqual(destination.settings.defaultUnit, .kg)
        XCTAssertEqual(destination.profile.gender, .male)
        XCTAssertEqual(destination.profile.heightCentimeters, 182.0)
    }

    func testSQLiteExportImportRoundTrip() throws {
        let source = try TestSupport.makeRepository()
        source.addWeightLog(
            weight: 188.2,
            timestamp: Date(timeIntervalSince1970: 1_707_000_000),
            noteText: "Leg day + extra carbs",
            source: .manual
        )
        source.addStandaloneNote(text: "Hydration was lower than usual")

        let sqliteData = source.exportSQLite()
        XCTAssertFalse(sqliteData.isEmpty)

        let importURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weighin-import-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: importURL) }
        try sqliteData.write(to: importURL)

        let destination = try TestSupport.makeRepository()
        destination.importSQLite(from: importURL)

        XCTAssertEqual(destination.logs.count, source.logs.count)
        XCTAssertEqual(destination.notes.count, source.notes.count)
        XCTAssertEqual(destination.logs.first?.weight, source.logs.first?.weight)
    }

    func testSQLiteRestoreMergesWithoutOverwritingExistingConflicts() throws {
        let source = try TestSupport.makeRepository()
        let timestamp = Date(timeIntervalSince1970: 1_710_000_000)
        source.addWeightLog(
            weight: 200.0,
            timestamp: timestamp,
            noteText: "Imported note",
            source: .manual
        )

        guard let exportedLog = source.logs.first else {
            return XCTFail("Expected exported log")
        }

        let sqliteData = source.exportSQLite()
        let importURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weighin-merge-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: importURL) }
        try sqliteData.write(to: importURL)

        let destination = try TestSupport.makeRepository()
        destination.importSQLite(from: importURL)
        guard let existing = destination.logs.first(where: { $0.id == exportedLog.id }) else {
            return XCTFail("Expected preloaded log")
        }
        destination.updateWeightLog(
            existing,
            weight: 222.2,
            timestamp: existing.timestamp,
            noteText: destination.note(for: existing)?.text ?? ""
        )
        destination.importSQLite(from: importURL)

        guard let mergedLog = destination.logs.first(where: { $0.id == exportedLog.id }) else {
            return XCTFail("Expected merged log")
        }

        XCTAssertEqual(mergedLog.weight, 222.2, accuracy: 0.0001)
    }

    func testAppleHealthZIPImportReadsBodyMassAndIsIdempotent() throws {
        let repository = try TestSupport.makeRepository()

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_US">
          <ExportDate value="2026-02-16 13:00:00 -0800"/>
          <Me HKCharacteristicTypeIdentifierDateOfBirth="1980-01-01" HKCharacteristicTypeIdentifierBiologicalSex="HKBiologicalSexMale" HKCharacteristicTypeIdentifierBloodType="HKBloodTypeNotSet" HKCharacteristicTypeIdentifierFitzpatrickSkinType="HKFitzpatrickSkinTypeNotSet" HKCharacteristicTypeIdentifierCardioFitnessMedicationsUse="HKCardioFitnessMedicationsUseUnknown"/>
          <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Health" unit="lb" creationDate="2024-01-02 07:00:00 -0800" startDate="2024-01-02 07:00:00 -0800" endDate="2024-01-02 07:00:00 -0800" value="200.5"/>
          <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Health" unit="lb" creationDate="2024-01-02 07:00:00 -0800" startDate="2024-01-02 07:00:00 -0800" endDate="2024-01-02 07:00:00 -0800" value="200.5"/>
          <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Scale App" unit="kg" creationDate="2024-01-03 08:30:00 +0000" startDate="2024-01-03 08:30:00 +0000" endDate="2024-01-03 08:30:00 +0000" value="90.1"/>
          <Record type="HKQuantityTypeIdentifierBodyMassIndex" sourceName="Health" unit="count" creationDate="2024-01-03 08:30:00 +0000" startDate="2024-01-03 08:30:00 +0000" endDate="2024-01-03 08:30:00 +0000" value="28"/>
        </HealthData>
        """

        let zipData = makeStoredZIP(
            entries: [
                (name: "apple_health_export/export.xml", data: Data(xml.utf8))
            ]
        )
        let zipURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("health-import-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }
        try zipData.write(to: zipURL)

        repository.importAppleHealthZIP(from: zipURL)
        repository.importAppleHealthZIP(from: zipURL)

        XCTAssertEqual(repository.logs.count, 2)
        XCTAssertEqual(repository.notes.count, 0)
        XCTAssertEqual(Set(repository.logs.map(\.source)), [.health])

        let lbsLog = try XCTUnwrap(repository.logs.first(where: { $0.unit == .lbs }))
        XCTAssertEqual(lbsLog.weight, 200.5, accuracy: 0.0001)

        let kgLog = try XCTUnwrap(repository.logs.first(where: { $0.unit == .kg }))
        XCTAssertEqual(kgLog.weight, 90.1, accuracy: 0.0001)
    }

    func testAppleHealthFolderImportReadsBodyMassFromExportXML() throws {
        let repository = try TestSupport.makeRepository()

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_US">
          <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Health" unit="lb" creationDate="2024-02-02 07:00:00 -0800" startDate="2024-02-02 07:00:00 -0800" endDate="2024-02-02 07:00:00 -0800" value="198.4"/>
          <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Scale App" unit="kg" creationDate="2024-02-03 08:30:00 +0000" startDate="2024-02-03 08:30:00 +0000" endDate="2024-02-03 08:30:00 +0000" value="89.3"/>
        </HealthData>
        """

        let rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("health-folder-\(UUID().uuidString)", isDirectory: true)
        let exportDirectory = rootDirectory.appendingPathComponent("apple_health_export", isDirectory: true)
        let exportXMLURL = exportDirectory.appendingPathComponent("export.xml")

        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: exportXMLURL)

        repository.importAppleHealthZIP(from: rootDirectory)

        XCTAssertEqual(repository.logs.count, 2)
        XCTAssertEqual(Set(repository.logs.map(\.source)), [.health])
        XCTAssertNotNil(repository.logs.first(where: { $0.unit == .lbs }))
        XCTAssertNotNil(repository.logs.first(where: { $0.unit == .kg }))
    }
}

private func makeStoredZIP(entries: [(name: String, data: Data)]) -> Data {
    var archive = Data()
    var centralDirectory = Data()
    var entryMetas: [(nameData: Data, data: Data, crc: UInt32, offset: UInt32)] = []

    for entry in entries {
        let nameData = Data(entry.name.utf8)
        let crc = entry.data.withUnsafeBytes { rawBuffer -> UInt32 in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return 0 }
            return UInt32(crc32(0, base, uInt(rawBuffer.count)))
        }
        let localOffset = UInt32(archive.count)
        entryMetas.append((nameData: nameData, data: entry.data, crc: crc, offset: localOffset))

        appendUInt32LE(0x04034B50, to: &archive)
        appendUInt16LE(20, to: &archive)
        appendUInt16LE(0, to: &archive)
        appendUInt16LE(0, to: &archive)
        appendUInt16LE(0, to: &archive)
        appendUInt16LE(0, to: &archive)
        appendUInt32LE(crc, to: &archive)
        appendUInt32LE(UInt32(entry.data.count), to: &archive)
        appendUInt32LE(UInt32(entry.data.count), to: &archive)
        appendUInt16LE(UInt16(nameData.count), to: &archive)
        appendUInt16LE(0, to: &archive)
        archive.append(nameData)
        archive.append(entry.data)
    }

    let centralDirectoryOffset = UInt32(archive.count)
    for entry in entryMetas {
        appendUInt32LE(0x02014B50, to: &centralDirectory)
        appendUInt16LE(20, to: &centralDirectory)
        appendUInt16LE(20, to: &centralDirectory)
        appendUInt16LE(0, to: &centralDirectory)
        appendUInt16LE(0, to: &centralDirectory)
        appendUInt16LE(0, to: &centralDirectory)
        appendUInt16LE(0, to: &centralDirectory)
        appendUInt32LE(entry.crc, to: &centralDirectory)
        appendUInt32LE(UInt32(entry.data.count), to: &centralDirectory)
        appendUInt32LE(UInt32(entry.data.count), to: &centralDirectory)
        appendUInt16LE(UInt16(entry.nameData.count), to: &centralDirectory)
        appendUInt16LE(0, to: &centralDirectory)
        appendUInt16LE(0, to: &centralDirectory)
        appendUInt16LE(0, to: &centralDirectory)
        appendUInt16LE(0, to: &centralDirectory)
        appendUInt32LE(0, to: &centralDirectory)
        appendUInt32LE(entry.offset, to: &centralDirectory)
        centralDirectory.append(entry.nameData)
    }

    archive.append(centralDirectory)

    appendUInt32LE(0x06054B50, to: &archive)
    appendUInt16LE(0, to: &archive)
    appendUInt16LE(0, to: &archive)
    appendUInt16LE(UInt16(entries.count), to: &archive)
    appendUInt16LE(UInt16(entries.count), to: &archive)
    appendUInt32LE(UInt32(centralDirectory.count), to: &archive)
    appendUInt32LE(centralDirectoryOffset, to: &archive)
    appendUInt16LE(0, to: &archive)

    return archive
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
}
