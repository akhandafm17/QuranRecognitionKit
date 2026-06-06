import Foundation

enum TrackingMode: Sendable, Equatable {
    case discovery
    case tracking
}

final class RecitationTracker: @unchecked Sendable {
    private let matchingEngine: QuranVerseMatchingEngine

    private(set) var mode: TrackingMode = .discovery
    private(set) var currentSurah: Int?
    private(set) var currentVerse: Int?
    private(set) var wordsCovered: Int = 0
    private(set) var totalWordsInVerse: Int = 0

    var surahHint: Int?

    private var pendingSurah: Int?
    private var pendingVerse: Int?
    private var consecutiveCount = 0

    private let requiredConsecutiveDiscovery = 2
    private let requiredConsecutiveJump = 2
    private let autoAdvanceCoverage = 0.80
    private let jumpThreshold = 0.85

    init(matchingEngine: QuranVerseMatchingEngine, surahHint: Int? = nil) {
        self.matchingEngine = matchingEngine
        self.surahHint = surahHint
    }

    func reset() {
        mode = .discovery
        currentSurah = nil
        currentVerse = nil
        wordsCovered = 0
        totalWordsInVerse = 0
        pendingSurah = nil
        pendingVerse = nil
        consecutiveCount = 0
        surahHint = nil
    }

    func processTranscription(_ transcription: String) -> RecognizedVerse? {
        let match: QuranVerseMatchingEngine.VerseMatchCandidate?

        switch mode {
        case .discovery:
            match = matchingEngine.findBestMatch(
                transcription: transcription,
                currentSurah: currentSurah,
                currentVerse: currentVerse,
                surahHint: surahHint
            )
        case .tracking:
            if let currentSurah, let currentVerse {
                match = matchingEngine.findBestMatchScoped(
                    transcription: transcription,
                    currentSurah: currentSurah,
                    currentVerse: currentVerse
                )
            } else {
                match = matchingEngine.findBestMatch(transcription: transcription)
            }
        }

        guard let match else { return nil }

        switch mode {
        case .discovery:
            return handleDiscoveryMatch(match)
        case .tracking:
            return handleTrackingMatch(match, transcription: transcription)
        }
    }

    private func handleDiscoveryMatch(_ match: QuranVerseMatchingEngine.VerseMatchCandidate) -> RecognizedVerse? {
        guard match.score >= matchingEngine.firstMatchThreshold else {
            pendingSurah = nil
            pendingVerse = nil
            consecutiveCount = 0
            return nil
        }

        if match.surahNumber == pendingSurah && match.verseNumber == pendingVerse {
            consecutiveCount += 1
        } else {
            pendingSurah = match.surahNumber
            pendingVerse = match.verseNumber
            consecutiveCount = 1
        }

        guard consecutiveCount >= requiredConsecutiveDiscovery else { return nil }

        currentSurah = match.surahNumber
        currentVerse = match.verseNumber
        pendingSurah = nil
        pendingVerse = nil
        consecutiveCount = 0
        wordsCovered = 0
        totalWordsInVerse = matchingEngine
            .getVerse(surah: match.surahNumber, verse: match.verseNumber)?
            .normalizedWords
            .count ?? 0
        mode = .tracking

        return recognizedVerse(from: match)
    }

    private func handleTrackingMatch(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> RecognizedVerse? {
        guard let currentSurah, let currentVerse else {
            mode = .discovery
            return nil
        }

        if match.surahNumber == currentSurah && match.verseNumber == currentVerse {
            updateWordCoverage(transcription: transcription, surah: currentSurah, verse: currentVerse)
            pendingSurah = nil
            pendingVerse = nil
            consecutiveCount = 0
            return nil
        }

        if isImmediateContinuation(match, currentSurah: currentSurah, currentVerse: currentVerse) {
            return advance(to: match)
        }

        guard match.score >= jumpThreshold else { return nil }

        if match.surahNumber == pendingSurah && match.verseNumber == pendingVerse {
            consecutiveCount += 1
        } else {
            pendingSurah = match.surahNumber
            pendingVerse = match.verseNumber
            consecutiveCount = 1
        }

        guard consecutiveCount >= requiredConsecutiveJump else { return nil }
        return advance(to: match)
    }

    private func isImmediateContinuation(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        currentSurah: Int,
        currentVerse: Int
    ) -> Bool {
        if match.surahNumber == currentSurah, match.verseNumber == currentVerse + 1 {
            return true
        }
        return match.surahNumber == currentSurah + 1 && match.verseNumber == 1
    }

    private func updateWordCoverage(transcription: String, surah: Int, verse: Int) {
        guard let entry = matchingEngine.getVerse(surah: surah, verse: verse) else { return }
        let alignment = LevenshteinMatcher.wordAlignment(
            transcription: transcription,
            reference: entry.normalizedText
        )
        wordsCovered = alignment.matched
        totalWordsInVerse = alignment.total

        guard alignment.total > 0 else { return }
        let coverage = Double(alignment.matched) / Double(alignment.total)
        guard coverage >= autoAdvanceCoverage,
              let nextEntry = matchingEngine.getVerse(surah: surah, verse: verse + 1) else {
            return
        }

        currentSurah = nextEntry.surahNumber
        currentVerse = nextEntry.verseNumber
        wordsCovered = 0
        totalWordsInVerse = nextEntry.normalizedWords.count
    }

    private func advance(to match: QuranVerseMatchingEngine.VerseMatchCandidate) -> RecognizedVerse {
        currentSurah = match.surahNumber
        currentVerse = match.verseNumber
        pendingSurah = nil
        pendingVerse = nil
        consecutiveCount = 0
        wordsCovered = 0
        totalWordsInVerse = matchingEngine
            .getVerse(surah: match.surahNumber, verse: match.verseNumber)?
            .normalizedWords
            .count ?? 0
        return recognizedVerse(from: match)
    }

    private func recognizedVerse(from match: QuranVerseMatchingEngine.VerseMatchCandidate) -> RecognizedVerse {
        RecognizedVerse(
            surahNumber: match.surahNumber,
            verseNumber: match.verseNumber,
            ayahEnd: match.ayahEnd,
            confidence: match.score,
            arabicText: match.arabicText
        )
    }
}
