import Testing
@testable import QuranRecognitionKit

@Test func bundledVocabularyResourceLoads() throws {
    let decoder = try CTCDecoder.loadBundled()
    #expect(decoder.vocabularyCount > 1_000)
    #expect(decoder.blankTokenId == decoder.vocabularyCount - 1)
}
