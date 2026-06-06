import Foundation
import Testing
@testable import QuranRecognitionKit

@Test func modelValidationRejectsMissingAndEmptyFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let missingURL = directory.appendingPathComponent("missing.onnx")
    #expect(throws: RecognitionError.self) {
        try ONNXQuranModel.validateModelFile(at: missingURL)
    }

    let emptyURL = directory.appendingPathComponent("empty.onnx")
    FileManager.default.createFile(atPath: emptyURL.path, contents: Data())
    #expect(throws: RecognitionError.self) {
        try ONNXQuranModel.validateModelFile(at: emptyURL)
    }
}

@Test func modelValidationAcceptsNonEmptyLocalFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).onnx")
    try Data([1, 2, 3, 4]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    try ONNXQuranModel.validateModelFile(at: url)
}
