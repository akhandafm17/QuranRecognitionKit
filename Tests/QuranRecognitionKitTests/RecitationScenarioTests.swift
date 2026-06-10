import Foundation
import Testing
@testable import QuranRecognitionKit

// Scenario tests that simulate full recitation sessions against the real
// bundled Quran index. Each scenario feeds tracker windows the way the
// streaming session would (per-verse windows, rolling windows that span ayah
// boundaries, short fragments, or noisy decodes) and asserts the two core
// product guarantees:
//
// 1. Accuracy: the reader never moves backwards and never skips ahead by more
//    than one ayah per emission.
// 2. Latency: clean recitation is detected on the same window it is heard,
//    and per-window processing stays fast.

// MARK: - Helpers

private func loadEntries(
    _ engine: QuranVerseMatchingEngine,
    surah: Int,
    through lastVerse: Int
) throws -> [QuranVerseMatchingEngine.VerseEntry] {
    try (1...lastVerse).map { verse in
        try #require(engine.getVerse(surah: surah, verse: verse))
    }
}

/// One clean window per ayah, like a reciter pausing between verses.
private func fullVerseWindows(_ entries: [QuranVerseMatchingEngine.VerseEntry]) -> [String] {
    entries.map(\.normalizedText)
}

/// Rolling windows that overlap ayah boundaries, like the streaming session's
/// suffix-aligned audio buffer (end of ayah N + start of ayah N+1).
private func boundarySpanningWindows(_ entries: [QuranVerseMatchingEngine.VerseEntry]) -> [String] {
    var windows = [entries[0].normalizedText]
    for index in 0..<(entries.count - 1) {
        let tail = entries[index].normalizedWords.suffix(3)
        let head = entries[index + 1].normalizedWords.prefix(3)
        windows.append((tail + head).joined(separator: " "))
    }
    return windows
}

/// Short 3-word chunks, like the transcripts produced by short tracking windows.
private func fragmentedWindows(_ entries: [QuranVerseMatchingEngine.VerseEntry]) -> [String] {
    entries.flatMap { entry -> [String] in
        let words = entry.normalizedWords
        var chunks: [String] = []
        var start = 0
        while start < words.count {
            let end = min(start + 3, words.count)
            chunks.append(words[start..<end].joined(separator: " "))
            start = end
        }
        return chunks
    }
}

/// Deterministically degraded windows, like weak CTC decodes from a quiet or
/// fast reciter: every third word loses its final letter and each ayah is
/// split into two halves.
private func noisyWindows(_ entries: [QuranVerseMatchingEngine.VerseEntry]) -> [String] {
    entries.flatMap { entry -> [String] in
        let clipped = entry.normalizedWords.enumerated().map { index, word -> String in
            (index % 3 == 1 && word.count > 3) ? String(word.dropLast()) : word
        }
        let midpoint = max(2, clipped.count / 2)
        let firstHalf = clipped.prefix(midpoint).joined(separator: " ")
        let secondHalf = clipped.suffix(max(2, clipped.count - midpoint + 1)).joined(separator: " ")
        return [firstHalf, secondHalf]
    }
}

private func runScenario(
    engine: QuranVerseMatchingEngine,
    surah: Int,
    windows: [String]
) -> [RecognizedVerse] {
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: surah)
    var emissions: [RecognizedVerse] = []
    for window in windows {
        if let verse = tracker.processTranscription(window) {
            emissions.append(verse)
        }
    }
    return emissions
}

/// Core accuracy property: emissions stay in the expected surah, never move
/// backwards, and never skip more than one ayah at a time.
private func expectSequential(_ emissions: [RecognizedVerse], surah: Int) {
    var highest = 0
    for emission in emissions {
        #expect(emission.surahNumber == surah, "unexpected surah switch to \(emission.surahNumber):\(emission.verseNumber)")
        if highest > 0 {
            #expect(emission.verseNumber >= highest, "moved backwards to \(emission.verseNumber) after \(highest)")
            #expect(emission.verseNumber <= highest + 1, "skipped from \(highest) to \(emission.verseNumber)")
        }
        highest = max(highest, emission.verseNumber)
    }
}

// MARK: - Accuracy: clean recitation across different surahs

@Test(arguments: [
    (surah: 1, lastVerse: 7),    // Al-Fatihah: short opening surah
    (surah: 18, lastVerse: 6),   // Al-Kahf: long narrative verses
    (surah: 67, lastVerse: 8),   // Al-Mulk: medium verses (real log case)
    (surah: 112, lastVerse: 4),  // Al-Ikhlas: very short verses
    (surah: 114, lastVerse: 6),  // An-Nas: short verses with repeated ending word
])
func cleanRecitationFollowsEveryVerseWithOneWindowLatency(
    _ scenario: (surah: Int, lastVerse: Int)
) throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let entries = try loadEntries(engine, surah: scenario.surah, through: scenario.lastVerse)
    let emissions = runScenario(
        engine: engine,
        surah: scenario.surah,
        windows: fullVerseWindows(entries)
    )

    // One emission per window: the reader follows on the same window the
    // verse is recited, with no missed and no duplicated verses.
    #expect(emissions.map(\.verseNumber) == Array(1...scenario.lastVerse))
    expectSequential(emissions, surah: scenario.surah)
}

// MARK: - Accuracy: rolling windows that span ayah boundaries

@Test(arguments: [
    (surah: 1, lastVerse: 7),
    (surah: 67, lastVerse: 5),
])
func boundarySpanningWindowsCueNextAyahWithoutSkipping(
    _ scenario: (surah: Int, lastVerse: Int)
) throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let entries = try loadEntries(engine, surah: scenario.surah, through: scenario.lastVerse)
    let emissions = runScenario(
        engine: engine,
        surah: scenario.surah,
        windows: boundarySpanningWindows(entries)
    )

    #expect(emissions.map(\.verseNumber) == Array(1...scenario.lastVerse))
    expectSequential(emissions, surah: scenario.surah)
}

// MARK: - Accuracy: short fragmented tracking windows

@Test(arguments: [
    (surah: 1, lastVerse: 7),
    (surah: 67, lastVerse: 4),
])
func fragmentedTrackingWindowsNeverSkipOrRegress(
    _ scenario: (surah: Int, lastVerse: Int)
) throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let entries = try loadEntries(engine, surah: scenario.surah, through: scenario.lastVerse)
    let emissions = runScenario(
        engine: engine,
        surah: scenario.surah,
        windows: fragmentedWindows(entries)
    )

    expectSequential(emissions, surah: scenario.surah)
    // Fragments are lossy, so not every ayah has to be detected, but the
    // session must make real forward progress without ever jumping.
    let highest = emissions.map(\.verseNumber).max() ?? 0
    #expect(highest >= scenario.lastVerse / 2, "only reached \(highest) of \(scenario.lastVerse)")
}

// MARK: - Accuracy: noisy decodes from a weak recitation

@Test(arguments: [
    (surah: 18, lastVerse: 5),
    (surah: 67, lastVerse: 5),
])
func noisyRecitationNeverJumpsAcrossAyahs(
    _ scenario: (surah: Int, lastVerse: Int)
) throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let entries = try loadEntries(engine, surah: scenario.surah, through: scenario.lastVerse)
    let emissions = runScenario(
        engine: engine,
        surah: scenario.surah,
        windows: noisyWindows(entries)
    )

    expectSequential(emissions, surah: scenario.surah)
    #expect(!emissions.isEmpty, "noisy recitation was never detected at all")
}

// MARK: - Accuracy: repeated verse (memorization style) and surah transition

@Test func repeatingAVerseCuesNextAyahOnceAndNeverRegresses() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)
    let second = try #require(engine.getVerse(surah: 1, verse: 2))

    _ = try #require(tracker.processTranscription("بسم الله الرحمن الرحيم"))
    let advanced = try #require(tracker.processTranscription(second.normalizedText))
    #expect(advanced.verseNumber == 2)

    // Full coverage of the current ayah cues the next phrase once...
    let cued = try #require(tracker.processTranscription(second.normalizedText))
    #expect(cued.verseNumber == 3)

    // ...and further repeats are treated as stale, never moving backwards.
    #expect(tracker.processTranscription(second.normalizedText) == nil)
    #expect(tracker.processTranscription(second.normalizedText) == nil)
    #expect(tracker.currentVerse == 3)
}

@Test func completingShortSurahThenStartingNextSurahSwitchesCleanly() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 112)
    let entries = try loadEntries(engine, surah: 112, through: 4)

    for entry in entries {
        _ = try #require(tracker.processTranscription(entry.normalizedText))
    }
    #expect(tracker.currentSurah == 112)
    #expect(tracker.currentVerse == 4)

    // Reciting Al-Falaq's distinctive opening right after finishing Al-Ikhlas
    // must switch surahs without waiting for tracking misses.
    let falaq = try #require(engine.getVerse(surah: 113, verse: 1))
    let switched = try #require(tracker.processTranscription(falaq.normalizedText))
    #expect(switched.surahNumber == 113)
    #expect(switched.verseNumber == 1)
}

// MARK: - Latency

/// Wall-clock latency assertions and the heavy fixture-replay tests share a
/// serialized suite: Swift Testing runs tests in parallel by default, and a
/// latency measurement taken while another test replays 12 minutes of audio
/// decodes measures CPU starvation, not the engine (observed 125s for a 2s
/// bound on a fully loaded machine).
@Suite(.serialized) struct PerformanceSensitiveTests {

    /// `swift test` compiles unoptimized; the Levenshtein scans are 10-50x
    /// slower than the release builds apps ship with (on-device field logs
    /// show ~0.1s per window for the whole pipeline). Latency bounds are
    /// release-realistic numbers scaled by this allowance under debug.
    #if DEBUG
    static let latencyAllowance = 8.0
    #else
    static let latencyAllowance = 1.0
    #endif


    @Test(arguments: [1, 18, 23, 67, 112, 114])
    func hintedDiscoveryCommitsFirstVerseOnFirstWindow(surah: Int) throws {
        let engine = try QuranVerseMatchingEngine.loadBundled()
        let tracker = RecitationTracker(matchingEngine: engine, surahHint: surah)
        let verse = try #require(engine.getVerse(surah: surah, verse: 1))

        let startedAt = Date()
        let match = try #require(tracker.processTranscription(verse.normalizedText))
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(match.surahNumber == surah)
        #expect(match.verseNumber == 1)
        #expect(elapsed < 2.0 * Self.latencyAllowance, "hinted discovery took \(elapsed)s for surah \(surah)")
    }

    @Test func unhintedGlobalDiscoveryStaysFastAcrossTheMushaf() throws {
        let engine = try QuranVerseMatchingEngine.loadBundled()
        let targets = [(2, 255), (18, 10), (36, 9), (55, 26), (67, 1), (112, 1)]

        for (surah, verseNumber) in targets {
            let verse = try #require(engine.getVerse(surah: surah, verse: verseNumber))
            let startedAt = Date()
            let match = try #require(engine.findBestMatch(transcription: verse.normalizedText))
            let elapsed = Date().timeIntervalSince(startedAt)

            // Identical verse texts exist in multiple surahs, so compare text.
            #expect(match.normalizedText == verse.normalizedText, "wrong match for \(surah):\(verseNumber)")
            #expect(elapsed < 4.0 * Self.latencyAllowance, "global discovery took \(elapsed)s for \(surah):\(verseNumber)")
        }
    }

    @Test func scopedTrackingWindowsProcessQuickly() throws {
        let engine = try QuranVerseMatchingEngine.loadBundled()
        let tracker = RecitationTracker(matchingEngine: engine, surahHint: 67)
        let entries = try loadEntries(engine, surah: 67, through: 4)
        _ = try #require(tracker.processTranscription(entries[0].normalizedText))

        let windows = fragmentedWindows(Array(entries.dropFirst()))
        var total: TimeInterval = 0
        for window in windows {
            let startedAt = Date()
            _ = tracker.processTranscription(window)
            let elapsed = Date().timeIntervalSince(startedAt)
            total += elapsed
            #expect(elapsed < 1.0 * Self.latencyAllowance, "scoped window took \(elapsed)s")
        }

        let average = total / Double(windows.count)
        #expect(average < 0.5 * Self.latencyAllowance, "average scoped window took \(average)s")
    }
}
