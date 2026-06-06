import CryptoKit
import Foundation

public actor ModelDownloader {
    public init() {}

    public func download(
        from sourceURL: URL,
        expectedSHA256: String,
        destinationURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard !expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecognitionError.downloadFailed("SHA-256 verification is required")
        }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(from: sourceURL)
        } catch {
            throw RecognitionError.downloadFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RecognitionError.downloadFailed("Unexpected HTTP response")
        }

        let fileManager = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let temporaryURL = parent.appendingPathComponent("\(destinationURL.lastPathComponent).download")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        fileManager.createFile(atPath: temporaryURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        var downloadedBytes: Int64 = 0
        let totalBytes = httpResponse.expectedContentLength

        do {
            for try await byte in bytes {
                var mutableByte = byte
                let data = Data(bytes: &mutableByte, count: 1)
                try handle.write(contentsOf: data)
                hasher.update(data: data)
                downloadedBytes += 1

                if totalBytes > 0, downloadedBytes % 65_536 == 0 {
                    progress?(Double(downloadedBytes) / Double(totalBytes))
                }
            }
        } catch {
            throw RecognitionError.downloadFailed(error.localizedDescription)
        }

        progress?(1)

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let expected = expectedSHA256.lowercased()
        guard digest == expected else {
            try? fileManager.removeItem(at: temporaryURL)
            throw RecognitionError.downloadChecksumMismatch(expected: expected, actual: digest)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }
}
