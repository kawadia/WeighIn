import Foundation

struct AppleHealthBodyMassRow: Equatable {
    let timestamp: Date
    let weight: Double
    let unit: WeightUnit
    let sourceName: String
}

enum AppleHealthImportParser {
    private static let supportedRecordType = "HKQuantityTypeIdentifierBodyMass"

    static func parseBodyMassRows(fromExportAt url: URL) throws -> [AppleHealthBodyMassRow] {
        let xmlData = try extractExportXMLData(from: url)
        let parser = AppleHealthBodyMassXMLParser()
        return try parser.parse(data: xmlData)
    }

    private static func extractExportXMLData(from url: URL) throws -> Data {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true {
            return try extractExportXML(fromDirectory: url)
        }
        return try ZIPExportExtractor.extractExportXML(from: url)
    }

    private static func extractExportXML(fromDirectory directoryURL: URL) throws -> Data {
        let directPath = directoryURL.appendingPathComponent("export.xml")
        if FileManager.default.fileExists(atPath: directPath.path) {
            return try Data(contentsOf: directPath)
        }

        let nestedPath = directoryURL
            .appendingPathComponent("apple_health_export")
            .appendingPathComponent("export.xml")
        if FileManager.default.fileExists(atPath: nestedPath.path) {
            return try Data(contentsOf: nestedPath)
        }

        if let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent.lowercased() == "export.xml" else { continue }
                let fileValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if fileValues?.isRegularFile == true {
                    return try Data(contentsOf: fileURL)
                }
            }
        }

        throw ZIPExportExtractor.ExtractorError.missingExportXML
    }

    private final class AppleHealthBodyMassXMLParser: NSObject, XMLParserDelegate {
        private var rows: [AppleHealthBodyMassRow] = []

        private lazy var dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            return formatter
        }()

        func parse(data: Data) throws -> [AppleHealthBodyMassRow] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldResolveExternalEntities = false
            parser.shouldProcessNamespaces = false

            guard parser.parse() else {
                throw parser.parserError
                    ?? ZIPExportExtractor.ExtractorError.invalidArchive("Could not parse Apple Health export XML")
            }
            return rows
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName == "Record" else { return }
            guard attributeDict["type"] == AppleHealthImportParser.supportedRecordType else { return }

            guard let valueString = attributeDict["value"],
                  let value = Double(valueString),
                  value > 0,
                  let dateString = attributeDict["startDate"],
                  let timestamp = dateFormatter.date(from: dateString),
                  let unit = parseUnit(attributeDict["unit"]) else {
                return
            }

            let sourceName = attributeDict["sourceName"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(
                AppleHealthBodyMassRow(
                    timestamp: timestamp,
                    weight: value,
                    unit: unit,
                    sourceName: sourceName?.isEmpty == false ? sourceName! : "Health"
                )
            )
        }

        private func parseUnit(_ value: String?) -> WeightUnit? {
            guard let value else { return nil }
            switch value.lowercased() {
            case "lb", "lbs", "pound", "pounds":
                return .lbs
            case "kg", "kgs", "kilogram", "kilograms":
                return .kg
            default:
                return nil
            }
        }
    }
}
