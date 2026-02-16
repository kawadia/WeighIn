import XCTest
@testable import WeighIn

@MainActor
final class LogViewModelTests: XCTestCase {
    func testHandleKeyBuildsAndEditsInput() {
        let model = LogViewModel()

        model.handleKey("0")
        model.handleKey("0")
        XCTAssertEqual(model.weightInput, "0")

        model.handleKey("5")
        XCTAssertEqual(model.weightInput, "5")

        model.handleKey(".")
        model.handleKey(".")
        model.handleKey("2")
        XCTAssertEqual(model.weightInput, "5.2")

        model.handleKey("⌫")
        XCTAssertEqual(model.weightInput, "5.")
    }

    func testSaveCurrentWeightAddsLogAndResetsInput() throws {
        let repository = try TestSupport.makeRepository()
        let model = LogViewModel()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_100)

        model.weightInput = "182.4"
        model.entryTimestamp = timestamp
        model.saveCurrentWeight(using: repository)

        XCTAssertEqual(model.weightInput, "")
        XCTAssertEqual(repository.logs.count, 1)
        XCTAssertEqual(repository.logs.first?.weight, 182.4)
        XCTAssertEqual(repository.logs.first?.source, .manual)
        XCTAssertEqual(repository.logs.first?.timestamp, timestamp)
    }

    func testSaveUnifiedEntrySavesWeightAndReflectionTogether() throws {
        let repository = try TestSupport.makeRepository()
        let model = LogViewModel()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_200)

        model.weightInput = "190.1"
        model.noteInput = "Hard workout + better sleep"
        model.entryTimestamp = timestamp
        model.saveUnifiedEntry(using: repository)

        XCTAssertEqual(repository.logs.count, 1)
        XCTAssertEqual(repository.notes.count, 1)
        XCTAssertEqual(repository.logs.first?.weight, 190.1)
        XCTAssertEqual(repository.logs.first?.timestamp, timestamp)
        XCTAssertEqual(repository.note(for: repository.logs[0])?.text, "Hard workout + better sleep")
        XCTAssertEqual(model.weightInput, "")
        XCTAssertEqual(model.noteInput, "")
    }

    func testSaveUnifiedEntryWithoutWeightShowsValidationMessage() throws {
        let repository = try TestSupport.makeRepository()
        let model = LogViewModel()

        model.noteInput = "note only"
        model.saveUnifiedEntry(using: repository)

        XCTAssertEqual(repository.logs.count, 0)
        XCTAssertTrue(model.lastSaveMessage.contains("weight"))
    }

    func testSaveNoteNowUpsertsSameNoteID() throws {
        let repository = try TestSupport.makeRepository()
        let model = LogViewModel()

        model.noteInput = "  First note  "
        model.saveNoteNow(using: repository)

        XCTAssertEqual(repository.notes.count, 1)
        XCTAssertEqual(repository.notes.first?.text, "First note")
        let firstNoteID = repository.notes.first?.id

        model.noteInput = "Updated note"
        model.saveNoteNow(using: repository)

        XCTAssertEqual(repository.notes.count, 1)
        XCTAssertEqual(repository.notes.first?.id, firstNoteID)
        XCTAssertEqual(repository.notes.first?.text, "Updated note")
        XCTAssertFalse(model.lastSaveMessage.isEmpty)
    }
}
