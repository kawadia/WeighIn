import Foundation
import zlib

enum ZIPExportExtractor {
    struct CentralDirectoryEntry {
        let fileName: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    enum ExtractorError: LocalizedError {
        case invalidArchive(String)
        case missingExportXML
        case unsupportedCompression(UInt16)
        case decompressionFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidArchive(let message):
                return message
            case .missingExportXML:
                return "Could not find export.xml inside the Apple Health ZIP."
            case .unsupportedCompression(let method):
                return "Unsupported ZIP compression method: \(method)."
            case .decompressionFailed(let status):
                return "Could not decompress Apple Health export (zlib status \(status))."
            }
        }
    }

    private static let localFileHeaderSignature: UInt32 = 0x04034B50
    private static let centralDirectorySignature: UInt32 = 0x02014B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054B50

    static func extractExportXML(from archiveURL: URL) throws -> Data {
        let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let eocdOffset = try locateEndOfCentralDirectory(in: archiveData)
        let centralDirectorySize = Int(try readUInt32LE(from: archiveData, at: eocdOffset + 12))
        let centralDirectoryOffset = Int(try readUInt32LE(from: archiveData, at: eocdOffset + 16))
        let centralDirectoryEnd = centralDirectoryOffset + centralDirectorySize

        guard centralDirectoryOffset >= 0,
              centralDirectoryEnd <= archiveData.count else {
            throw ExtractorError.invalidArchive("Invalid central directory range in ZIP.")
        }

        var cursor = centralDirectoryOffset
        var exportEntry: CentralDirectoryEntry?

        while cursor < centralDirectoryEnd {
            let signature = try readUInt32LE(from: archiveData, at: cursor)
            guard signature == centralDirectorySignature else {
                throw ExtractorError.invalidArchive("Invalid central directory record signature.")
            }

            let compressionMethod = try readUInt16LE(from: archiveData, at: cursor + 10)
            let compressedSize = try readUInt32LE(from: archiveData, at: cursor + 20)
            let uncompressedSize = try readUInt32LE(from: archiveData, at: cursor + 24)
            let fileNameLength = Int(try readUInt16LE(from: archiveData, at: cursor + 28))
            let extraLength = Int(try readUInt16LE(from: archiveData, at: cursor + 30))
            let commentLength = Int(try readUInt16LE(from: archiveData, at: cursor + 32))
            let localHeaderOffset = try readUInt32LE(from: archiveData, at: cursor + 42)

            let fileNameStart = cursor + 46
            let fileNameEnd = fileNameStart + fileNameLength
            guard fileNameEnd <= archiveData.count else {
                throw ExtractorError.invalidArchive("Invalid central directory file name range.")
            }

            let nameData = archiveData.subdata(in: fileNameStart..<fileNameEnd)
            let fileName = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            if fileName == "export.xml" || fileName.hasSuffix("/export.xml") {
                exportEntry = CentralDirectoryEntry(
                    fileName: fileName,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
                break
            }

            cursor = fileNameEnd + extraLength + commentLength
        }

        guard let entry = exportEntry else {
            throw ExtractorError.missingExportXML
        }

        return try extract(entry: entry, from: archiveData)
    }

    private static func extract(entry: CentralDirectoryEntry, from archiveData: Data) throws -> Data {
        let localOffset = Int(entry.localHeaderOffset)
        let localSignature = try readUInt32LE(from: archiveData, at: localOffset)
        guard localSignature == localFileHeaderSignature else {
            throw ExtractorError.invalidArchive("Invalid local file header signature for \(entry.fileName).")
        }

        let localFileNameLength = Int(try readUInt16LE(from: archiveData, at: localOffset + 26))
        let localExtraLength = Int(try readUInt16LE(from: archiveData, at: localOffset + 28))
        let compressedStart = localOffset + 30 + localFileNameLength + localExtraLength
        let compressedEnd = compressedStart + Int(entry.compressedSize)
        guard compressedStart >= 0, compressedEnd <= archiveData.count else {
            throw ExtractorError.invalidArchive("Compressed payload range is invalid for \(entry.fileName).")
        }

        let compressedData = archiveData.subdata(in: compressedStart..<compressedEnd)
        let result: Data
        switch entry.compressionMethod {
        case 0:
            result = compressedData
        case 8:
            result = try inflateRawDeflate(compressedData)
        default:
            throw ExtractorError.unsupportedCompression(entry.compressionMethod)
        }

        if entry.uncompressedSize != 0 && result.count != Int(entry.uncompressedSize) {
            throw ExtractorError.invalidArchive("Unexpected export.xml size after decompression.")
        }

        return result
    }

    private static func locateEndOfCentralDirectory(in data: Data) throws -> Int {
        guard data.count >= 22 else {
            throw ExtractorError.invalidArchive("ZIP is too small to contain End of Central Directory.")
        }

        let maxSearchLength = min(data.count, 22 + 65_535)
        let lowerBound = data.count - maxSearchLength
        var cursor = data.count - 22

        while cursor >= lowerBound {
            if try readUInt32LE(from: data, at: cursor) == endOfCentralDirectorySignature {
                return cursor
            }
            cursor -= 1
        }

        throw ExtractorError.invalidArchive("Could not locate End of Central Directory in ZIP.")
    }

    private static func inflateRawDeflate(_ compressedData: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ExtractorError.decompressionFailed(initStatus)
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data()
        output.reserveCapacity(max(compressedData.count * 2, 32 * 1024))

        let chunkSize = 64 * 1024
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)

        return try compressedData.withUnsafeBytes { rawBuffer -> Data in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else {
                return Data()
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress)
            stream.avail_in = uInt(rawBuffer.count)

            while true {
                let status = outBuffer.withUnsafeMutableBytes { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(outBuffer, count: produced)
                }

                if status == Z_STREAM_END {
                    break
                }

                guard status == Z_OK else {
                    throw ExtractorError.decompressionFailed(status)
                }
            }

            return output
        }
    }

    private static func readUInt16LE(from data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw ExtractorError.invalidArchive("Unexpected end of ZIP while reading UInt16.")
        }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(from data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw ExtractorError.invalidArchive("Unexpected end of ZIP while reading UInt32.")
        }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
