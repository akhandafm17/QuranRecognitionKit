import Foundation
import Testing
@testable import QuranRecognitionKit

@Test func bundledQuranModelExtractsToLocalONNXFile() async throws {
    let modelURL = try await BundledQuranModel.modelURL()
    let secondURL = try await BundledQuranModel.modelURL()

    #expect(modelURL == secondURL)
    #expect(modelURL.lastPathComponent == BundledQuranModel.modelFileName)
    #expect(FileManager.default.fileExists(atPath: modelURL.path))

    let fileSize = try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    #expect(fileSize > 100_000_000)
}
