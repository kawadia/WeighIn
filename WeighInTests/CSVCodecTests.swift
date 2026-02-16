import XCTest
@testable import WeighIn

final class CSVCodecTests: XCTestCase {
    func testParseReadsTimestampWeightUnitAndNote() throws {
        let csv = """
        timestamp,weight,unit,note
        2025-01-02T12:34:56Z,181.2,kg,  Slept well
        """

        let rows = try CSVCodec.parse(data: Data(csv.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].weight, 181.2, accuracy: 0.0001)
        XCTAssertEqual(rows[0].unit, .kg)
        XCTAssertEqual(rows[0].note, "Slept well")
    }

    func testParseThrowsForMissingRequiredColumns() {
        let csv = """
        unit,note
        kg,test
        """

        XCTAssertThrowsError(try CSVCodec.parse(data: Data(csv.utf8))) { error in
            guard case CSVCodecError.missingRequiredColumns = error else {
                return XCTFail("Expected missingRequiredColumns, got \(error)")
            }
        }
    }

    func testParseThrowsForInvalidRows() {
        let csv = """
        timestamp,weight
        nope,180
        """

        XCTAssertThrowsError(try CSVCodec.parse(data: Data(csv.utf8))) { error in
            guard case let CSVCodecError.invalidRow(line) = error else {
                return XCTFail("Expected invalidRow, got \(error)")
            }
            XCTAssertEqual(line, 2)
        }
    }

    func testExportEscapesCommaAndQuotesInNotes() throws {
        let note = NoteEntry(
            id: "note-1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            text: "Felt \"great\", post-run"
        )
        let log = WeightLog(
            id: "log-1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            weight: 180.1,
            unit: .lbs,
            source: .manual,
            noteID: "note-1"
        )

        let data = CSVCodec.export(logs: [log], notesByID: [note.id: note])
        let output = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(output.contains("timestamp,weight,unit,source,note"))
        XCTAssertTrue(output.contains("\"Felt \"\"great\"\", post-run\""))
    }
}
