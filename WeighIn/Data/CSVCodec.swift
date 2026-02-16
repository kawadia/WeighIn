import Foundation

struct CSVImportRow {
    let timestamp: Date
    let weight: Double
    let unit: WeightUnit
    let note: String?
}

enum CSVCodecError: Error {
    case missingRequiredColumns
    case invalidRow(Int)
}

enum CSVCodec {
    static func parse(data: Data) throws -> [CSVImportRow] {
        guard let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let rows = parseRows(content)
        guard let header = rows.first else { return [] }

        let normalized = header.enumerated().reduce(into: [String: Int]()) { result, item in
            result[item.element.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = item.offset
        }

        guard let timestampIndex = normalized["timestamp"] ?? normalized["date"] ?? normalized["datetime"],
              let weightIndex = normalized["weight"] else {
            throw CSVCodecError.missingRequiredColumns
        }

        let unitIndex = normalized["unit"]
        let noteIndex = normalized["note"] ?? normalized["notes"]

        var imported: [CSVImportRow] = []
        for (rowIndex, row) in rows.dropFirst().enumerated() {
            guard row.indices.contains(timestampIndex), row.indices.contains(weightIndex) else {
                continue
            }

            let timestampString = row[timestampIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let weightString = row[weightIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let timestamp = parseDate(timestampString), let weight = Double(weightString) else {
                throw CSVCodecError.invalidRow(rowIndex + 2)
            }

            let unitValue: WeightUnit
            if let unitIndex, row.indices.contains(unitIndex) {
                unitValue = WeightUnit(rawValue: row[unitIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .lbs
            } else {
                unitValue = .lbs
            }

            let noteValue: String?
            if let noteIndex, row.indices.contains(noteIndex) {
                let raw = row[noteIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                noteValue = raw.isEmpty ? nil : raw
            } else {
                noteValue = nil
            }

            imported.append(CSVImportRow(timestamp: timestamp, weight: weight, unit: unitValue, note: noteValue))
        }

        return imported
    }

    static func export(logs: [WeightLog], notesByID: [String: NoteEntry]) -> Data {
        var lines = ["timestamp,weight,unit,source,note"]

        for log in logs.sorted(by: { $0.timestamp < $1.timestamp }) {
            let timestamp = DateFormatting.csvFormatter.string(from: log.timestamp)
            let noteText = log.noteID.flatMap { notesByID[$0]?.text } ?? ""
            let escapedNote = escape(noteText)
            lines.append("\(timestamp),\(log.weight),\(log.unit.rawValue),\(log.source.rawValue),\(escapedNote)")
        }

        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = DateFormatting.csvFormatter.date(from: value) {
            return date
        }

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        if let date = parser.date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func parseRows(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false

        for character in csv {
            switch character {
            case "\"":
                inQuotes.toggle()
            case "," where !inQuotes:
                currentRow.append(currentField)
                currentField = ""
            case "\n" where !inQuotes:
                currentRow.append(currentField)
                rows.append(currentRow)
                currentRow = []
                currentField = ""
            case "\r":
                continue
            default:
                currentField.append(character)
            }
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }

        return rows
    }

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\n") || value.contains("\"") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
