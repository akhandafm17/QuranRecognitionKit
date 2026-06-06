import Foundation

public struct RecognizedVerse: Sendable, Equatable {
    public let surahNumber: Int
    public let verseNumber: Int
    public let ayahEnd: Int?
    public let confidence: Double
    public let arabicText: String

    public init(
        surahNumber: Int,
        verseNumber: Int,
        ayahEnd: Int? = nil,
        confidence: Double,
        arabicText: String
    ) {
        self.surahNumber = surahNumber
        self.verseNumber = verseNumber
        self.ayahEnd = ayahEnd
        self.confidence = min(max(confidence, 0), 1)
        self.arabicText = arabicText
    }
}
