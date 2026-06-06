import Testing
@testable import QuranRecognitionKit

@Test func bundledQuranResourceLoadsAllVerses() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    #expect(engine.totalVerses == 6_236)
    #expect(engine.getVerse(surah: 1, verse: 1) != nil)
}

@Test func verseMatchingFindsExactKnownVerse() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let verse = try #require(engine.getVerse(surah: 1, verse: 5))
    let match = try #require(engine.findBestMatch(transcription: verse.normalizedText))

    #expect(match.surahNumber == 1)
    #expect(match.verseNumber == 5)
    #expect(match.score >= 0.99)
}

@Test func surahHintScopesDiscovery() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let verse = try #require(engine.getVerse(surah: 112, verse: 1))
    let match = try #require(engine.findBestMatch(
        transcription: verse.normalizedText,
        surahHint: 112
    ))

    #expect(match.surahNumber == 112)
    #expect(match.verseNumber == 1)
}
