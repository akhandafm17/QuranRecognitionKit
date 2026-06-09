import Foundation
import Testing
@testable import QuranRecognitionKit

/// Replays a real Surah Al-Baqarah recitation (first 12 minutes, verses
/// 2:1-2:59) through the real tracker. The fixture was produced by running
/// the bundled ONNX model over the audio with the exact streaming window
/// policy the session uses (0.2s cadence, 2.0s tracking / 3.5s discovery
/// suffix windows over an 8s rolling buffer), so each row carries the decode
/// the session would have processed in either mode at that timestamp.
///
/// This is the closest thing to an end-to-end field test that runs in CI:
/// real reciter, real acoustic model output, real tracker.
private struct RecitationWindow: Decodable {
    let t: Double
    /// Decode of the discovery-sized window at this timestamp ("" if the
    /// buffer had not reached the discovery minimum yet).
    let d: String
    /// Decode of the tracking-sized window at this timestamp.
    let k: String
}

private func loadRecitationFixture() throws -> [RecitationWindow] {
    let url = try #require(
        Bundle.module.url(forResource: "baqarah_recitation_windows", withExtension: "json")
    )
    return try JSONDecoder().decode([RecitationWindow].self, from: Data(contentsOf: url))
}

@Test func realBaqarahRecitationIsFollowedSequentially() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 2)
    let windows = try loadRecitationFixture()

    var emissions: [RecognizedVerse] = []
    var discoveryReturns = 0
    var wasTracking = false

    for window in windows {
        let text = tracker.mode == .tracking ? window.k : window.d
        guard !text.isEmpty else { continue }
        if let verse = tracker.processTranscription(text) {
            emissions.append(verse)
        }
        switch tracker.mode {
        case .tracking:
            wasTracking = true
        case .discovery:
            if wasTracking {
                discoveryReturns += 1
                wasTracking = false
            }
        }
    }

    // The reciter covers 2:1 through 2:59 in this segment, strictly in order.
    // Core guarantees: stay in Al-Baqarah, never move backwards, never skip
    // more than one ayah per emission, and actually keep up.
    var highest = 0
    for emission in emissions {
        #expect(emission.surahNumber == 2, "left Al-Baqarah at \(emission.surahNumber):\(emission.verseNumber)")
        if highest > 0 {
            #expect(emission.verseNumber >= highest, "moved backwards to \(emission.verseNumber) after \(highest)")
            #expect(emission.verseNumber <= highest + 1, "skipped from \(highest) to \(emission.verseNumber)")
        }
        highest = max(highest, emission.verseNumber)
    }

    #expect(highest >= 52, "only reached 2:\(highest) of 2:59 by the end of the segment")
    #expect(highest <= 61, "ran ahead to 2:\(highest), past the recited 2:59")

    // Occasional recovery through discovery is acceptable on a 12-minute
    // stream, but constant tracking loss is not.
    #expect(discoveryReturns <= 20, "lost tracking \(discoveryReturns) times over the segment")
}
