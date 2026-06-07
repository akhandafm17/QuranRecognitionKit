import Compression
import CryptoKit
import Foundation

public enum BundledQuranModel {
    public static let archiveFileName = "FastConformerQuranCTC.onnx.zip"
    public static let modelFileName = "FastConformerQuranCTC.onnx"

    private static let archiveResourceName = "FastConformerQuranCTC.onnx"
    private static let archiveResourceExtension = "zip"
    private static let archiveSHA256 = "624de98303964a97880070134311c24d3e42f26ddd9d54efe9219d7ad429befd"
    private static let modelSHA256 = "7e7f9aaccbf0f7d12104ebfee9a99625195454a359821139a777f389ec928b50"
    private static let extractionQueue = DispatchQueue(label: "QuranRecognitionKit.bundledModel", qos: .utility)

    public static func modelURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            extractionQueue.async {
                do {
                    continuation.resume(returning: try extractIfNeeded())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func removeExtractedModel() throws {
        let directory = try extractionDirectory()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static func extractIfNeeded() throws -> URL {
        let fileManager = FileManager.default
        let directory = try extractionDirectory()
        let modelURL = directory.appendingPathComponent(modelFileName)

        if fileManager.fileExists(atPath: modelURL.path),
           (try? sha256(of: modelURL)) == modelSHA256 {
            return modelURL
        }

        if fileManager.fileExists(atPath: modelURL.path) {
            try fileManager.removeItem(at: modelURL)
        }

        guard let archiveURL = Bundle.module.url(
            forResource: archiveResourceName,
            withExtension: archiveResourceExtension
        ) else {
            throw RecognitionError.resourceMissing(archiveFileName)
        }

        guard try sha256(of: archiveURL) == archiveSHA256 else {
            throw RecognitionError.resourceCorrupt(archiveFileName)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let stagingDirectory = directory.appendingPathComponent("Extraction", isDirectory: true)
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try fileManager.removeItem(at: stagingDirectory)
        }
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
        }

        try extractZipArchive(at: archiveURL, to: stagingDirectory)

        let extractedURL = stagingDirectory.appendingPathComponent(modelFileName)
        guard fileManager.fileExists(atPath: extractedURL.path) else {
            throw RecognitionError.modelCorrupt("Bundled archive does not contain \(modelFileName)")
        }
        guard try sha256(of: extractedURL) == modelSHA256 else {
            throw RecognitionError.modelCorrupt("Bundled model checksum mismatch")
        }

        if fileManager.fileExists(atPath: modelURL.path) {
            try fileManager.removeItem(at: modelURL)
        }
        try fileManager.moveItem(at: extractedURL, to: modelURL)
        return modelURL
    }

    private static func extractionDirectory() throws -> URL {
        try FileManager.default
            .url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("QuranRecognitionKit", isDirectory: true)
            .appendingPathComponent("BundledModel", isDirectory: true)
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func extractZipArchive(at zipURL: URL, to destinationDirectory: URL) throws {
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        let fileManager = FileManager.default
        var offset = 0
        var extractedFiles = 0

        while offset + 30 <= data.count {
            guard data[offset] == 0x50,
                  data[offset + 1] == 0x4B,
                  data[offset + 2] == 0x03,
                  data[offset + 3] == 0x04 else {
                break
            }

            let compressionMethod = littleEndianUInt16(data, offset + 8)
            let compressedSize = Int(littleEndianUInt32(data, offset + 18))
            let uncompressedSize = Int(littleEndianUInt32(data, offset + 22))
            let nameLength = Int(littleEndianUInt16(data, offset + 26))
            let extraLength = Int(littleEndianUInt16(data, offset + 28))

            let nameStart = offset + 30
            guard nameStart + nameLength <= data.count else {
                throw RecognitionError.modelCorrupt("Invalid bundled model archive")
            }

            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            guard !name.isEmpty, !name.contains(".."), !name.hasPrefix("/") else {
                throw RecognitionError.modelCorrupt("Unsafe file path in bundled model archive")
            }

            let dataStart = nameStart + nameLength + extraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else {
                throw RecognitionError.modelCorrupt("Invalid bundled model archive")
            }

            let destinationURL = destinationDirectory.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                switch compressionMethod {
                case 0:
                    try data.subdata(in: dataStart..<dataEnd).write(to: destinationURL)
                case 8:
                    let decompressed = try decompressDeflate(
                        data,
                        range: dataStart..<dataEnd,
                        expectedSize: uncompressedSize
                    )
                    try decompressed.write(to: destinationURL)
                default:
                    throw RecognitionError.modelCorrupt("Unsupported ZIP compression method \(compressionMethod)")
                }
                extractedFiles += 1
            }

            offset = dataEnd
        }

        guard extractedFiles > 0 else {
            throw RecognitionError.modelCorrupt("Bundled model archive is empty")
        }
    }

    private static func decompressDeflate(
        _ data: Data,
        range: Range<Int>,
        expectedSize: Int
    ) throws -> Data {
        let bufferSize = max(expectedSize, data.count * 2)
        var destinationBuffer = [UInt8](repeating: 0, count: bufferSize)

        let decompressedSize = data.withUnsafeBytes { sourcePointer -> Int in
            guard let sourceBase = sourcePointer.baseAddress else { return 0 }
            return compression_decode_buffer(
                &destinationBuffer,
                bufferSize,
                sourceBase.advanced(by: range.lowerBound).assumingMemoryBound(to: UInt8.self),
                range.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else {
            throw RecognitionError.modelCorrupt("Could not decompress bundled model archive")
        }

        return Data(destinationBuffer.prefix(decompressedSize))
    }

    private static func littleEndianUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }
}
