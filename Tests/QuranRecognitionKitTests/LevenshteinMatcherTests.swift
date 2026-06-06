import Testing
@testable import QuranRecognitionKit

@Test func levenshteinDistanceAndRatioAreStable() {
    #expect(LevenshteinMatcher.distance("kitten", "sitting") == 3)
    #expect(LevenshteinMatcher.ratio("abc", "abc") == 1.0)
    #expect(LevenshteinMatcher.ratio("", "abc") == 0.0)
}

@Test func wordAlignmentCountsForwardMatches() {
    let alignment = LevenshteinMatcher.wordAlignment(
        transcription: "اياك نعبد واياك",
        reference: "اياك نعبد واياك نستعين"
    )

    #expect(alignment.matched == 3)
    #expect(alignment.total == 4)
}
