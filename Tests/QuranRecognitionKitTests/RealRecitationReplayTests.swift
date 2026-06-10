import Foundation
import Testing
@testable import QuranRecognitionKit

/// Replays real recitations through the real tracker. Each fixture was
/// produced by running the bundled ONNX model over the audio with the exact
/// streaming window policy the session uses (0.2s cadence, 2.0s tracking /
/// 3.5s discovery suffix windows over an 8s rolling buffer), so each row
/// carries the decode the session would have processed in either mode at
/// that timestamp.
///
/// Fixtures: a 12-minute studio Al-Baqarah recitation (2:1-2:59) and three
/// phone-microphone recordings by the app's developer — a short-surah chain
/// with surah transitions (112 -> 113 -> 114), Surah Al-A'la, and a
/// memorization-style Al-Kahf 1-20 with a verse repeated three times,
/// coughing, and re-said words.
///
/// This is the closest thing to an end-to-end field test that runs in CI:
/// real reciters, real acoustic model output, real tracker.
private struct RecitationWindow: Decodable {
    let t: Double
    /// Decode of the discovery-sized window at this timestamp ("" if the
    /// buffer had not reached the discovery minimum yet).
    let d: String
    /// Decode of the tracking-sized window at this timestamp.
    let k: String
}

private struct ReplayOutcome {
    var emissions: [(verse: RecognizedVerse, isRecoveryCommit: Bool, t: Double)] = []
    var discoveryReturns = 0

    /// Compact emission trace for diagnosing replay failures from CI output.
    var trace: String {
        emissions
            .map { "\(String(format: "%.1f", $0.t))s \($0.verse.surahNumber):\($0.verse.verseNumber)\($0.isRecoveryCommit ? "R" : "")" }
            .joined(separator: " | ")
    }
}

private func loadFixture(_ name: String) throws -> [RecitationWindow] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
    return try JSONDecoder().decode([RecitationWindow].self, from: Data(contentsOf: url))
}

private func replay(fixture name: String, surahHint: Int) throws -> ReplayOutcome {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: surahHint)
    let windows = try loadFixture(name)

    var outcome = ReplayOutcome()
    var wasTracking = false
    for window in windows {
        let wasDiscovery = tracker.mode == .discovery
        let text = tracker.mode == .tracking ? window.k : window.d
        guard !text.isEmpty else { continue }
        if let verse = tracker.processTranscription(text) {
            outcome.emissions.append((verse, wasDiscovery, window.t))
        }
        switch tracker.mode {
        case .tracking:
            wasTracking = true
        case .discovery:
            if wasTracking {
                outcome.discoveryReturns += 1
                wasTracking = false
            }
        }
    }
    return outcome
}

/// Core ordering guarantees over a replay: the reader never leaves the
/// expected surah sequence, never moves backwards, and never skips more
/// than one ayah per tracking emission. A recovery commit right after a
/// tracking loss may catch up by a few ayahs (the reciter kept going during
/// the loss), bounded by the tracker's near-recovery window.
private func expectOrderedFollowing(
    _ outcome: ReplayOutcome,
    surahOrder: [Int]
) {
    var highestBySurah: [Int: Int] = [:]
    var surahIndex = 0
    for (emission, isRecoveryCommit, _) in outcome.emissions {
        guard let index = surahOrder.firstIndex(of: emission.surahNumber) else {
            Issue.record("left expected surahs at \(emission.surahNumber):\(emission.verseNumber)")
            continue
        }
        #expect(index >= surahIndex, "went back to surah \(emission.surahNumber) after surah \(surahOrder[surahIndex])")
        surahIndex = max(surahIndex, index)

        let highest = highestBySurah[emission.surahNumber] ?? 0
        if highest > 0 {
            #expect(
                emission.verseNumber >= highest,
                "moved backwards to \(emission.surahNumber):\(emission.verseNumber) after verse \(highest)"
            )
            let allowedStep = isRecoveryCommit ? 6 : 1
            #expect(
                emission.verseNumber <= highest + allowedStep,
                "skipped from \(emission.surahNumber):\(highest) to \(emission.verseNumber) (recovery=\(isRecoveryCommit))"
            )
        }
        highestBySurah[emission.surahNumber] = max(highest, emission.verseNumber)
    }
}

// Members of the serialized performance-sensitive suite: replays are the
// heaviest tests and must not starve wall-clock latency assertions.
extension PerformanceSensitiveTests {

@Test func realBaqarahRecitationIsFollowedSequentially() throws {
    let outcome = try replay(fixture: "baqarah_recitation_windows", surahHint: 2)
    print("REPLAY TRACE baqarah: \(outcome.trace)")
    expectOrderedFollowing(outcome, surahOrder: [2])

    let highest = outcome.emissions.map(\.verse.verseNumber).max() ?? 0
    #expect(highest >= 52, "only reached 2:\(highest) of 2:59 by the end of the segment")
    #expect(highest <= 61, "ran ahead to 2:\(highest), past the recited 2:59")

    // Loss-rate quality bar, set from measurement: this fixture currently
    // produces ~46 brief tracking losses over 12 minutes of long ayahs, all
    // of which recover at the correct verse (the ordering assertions prove
    // no skip/jump/regression ever escapes). The bound exists to catch
    // regressions that meaningfully worsen loss behavior; ratchet it down
    // as decode quality and tracking improve.
    #expect(outcome.discoveryReturns <= 60, "lost tracking \(outcome.discoveryReturns) times over the segment")
}

/// Developer phone recording: Al-Ikhlas -> Al-Falaq -> An-Nas recited
/// continuously. Exercises surah transitions, which the Al-Baqarah fixture
/// never reaches.
@Test func developerRecordingShortSurahChainFollowsAcrossSurahs() throws {
    let outcome = try replay(fixture: "recording_chain_112_114", surahHint: 112)
    print("REPLAY TRACE chain: \(outcome.trace)")
    expectOrderedFollowing(outcome, surahOrder: [112, 113, 114])

    let lastNas = outcome.emissions
        .filter { $0.verse.surahNumber == 114 }
        .map(\.verse.verseNumber)
        .max() ?? 0
    #expect(lastNas >= 4, "never followed into An-Nas past 114:\(lastNas)")
    #expect(outcome.discoveryReturns <= 10, "lost tracking \(outcome.discoveryReturns) times in a 47s chain")
}

/// Developer phone recording: Surah Al-A'la (87), the surah from the
/// original field logs.
@Test func developerRecordingAlAlaIsFollowedSequentially() throws {
    let outcome = try replay(fixture: "recording_alala_87", surahHint: 87)
    print("REPLAY TRACE alala: \(outcome.trace)")
    expectOrderedFollowing(outcome, surahOrder: [87])

    let highest = outcome.emissions.map(\.verse.verseNumber).max() ?? 0
    #expect(highest >= 15, "only reached 87:\(highest) of the recited 87:17+")
    #expect(highest <= 19, "ran ahead to 87:\(highest)")
    #expect(outcome.discoveryReturns <= 12, "lost tracking \(outcome.discoveryReturns) times in a 57s recitation")
}

/// Developer phone recording: Al-Kahf 1-20 memorization-style — verse 3
/// recited three times, coughing, and words re-said. The messiest realistic
/// input: long ayahs (17-19 run 30-50 words) plus deliberate repetition.
@Test func developerRecordingMessyAlKahfNeverJumpsAndReachesTheEnd() throws {
    let outcome = try replay(fixture: "recording_kahf_18", surahHint: 18)
    print("REPLAY TRACE kahf: \(outcome.trace)")
    expectOrderedFollowing(outcome, surahOrder: [18])

    let highest = outcome.emissions.map(\.verse.verseNumber).max() ?? 0
    #expect(highest >= 17, "only reached 18:\(highest) of the recited 18:20")
    // Measured residual, documented as a ratchet: during the 50-word 18:19
    // (a full minute of audio) the tracker drifts up to +3 ahead through
    // single fuzzy-word coverage seeds — the bounded worst case of the
    // weak-advance/coverage mechanism. Ordering guarantees still hold and
    // recovery pulls the reader back; tighten as matching improves.
    #expect(highest <= 23, "ran ahead to 18:\(highest)")
    #expect(outcome.discoveryReturns <= 45, "lost tracking \(outcome.discoveryReturns) times over 4 minutes")
}

}
