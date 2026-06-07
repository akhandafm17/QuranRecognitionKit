import Foundation
import Testing
@testable import QuranRecognitionKit

@Test func audioWindowAnalyzerRejectsSilence() {
    let quality = AudioWindowAnalyzer.analyze(
        samples: [Float](repeating: 0, count: 16_000),
        minimumSpeechRMS: 0.0015,
        minimumSpeechPeak: 0.006,
        minimumSpeechFrameRatio: 0.03
    )

    #expect(quality.status == AudioInputStatus.silence)
    #expect(!quality.isSpeechLikely)
}

@Test func audioWindowAnalyzerAcceptsSpeechLikeSignal() {
    let samples: [Float] = (0..<16_000).map { index in
        let phase = 2.0 * Double.pi * 220.0 * Double(index) / 16_000.0
        return Float(sin(phase)) * 0.04
    }

    let quality = AudioWindowAnalyzer.analyze(
        samples: samples,
        minimumSpeechRMS: 0.0015,
        minimumSpeechPeak: 0.006,
        minimumSpeechFrameRatio: 0.03
    )

    #expect(quality.status == AudioInputStatus.speech)
    #expect(quality.isSpeechLikely)
}

@Test func transcriptQualitySuppressesLowInformationFragments() {
    #expect(!AudioWindowAnalyzer.shouldPublishTranscription("أ"))
    #expect(!AudioWindowAnalyzer.shouldPublishTranscription("شر"))
    #expect(AudioWindowAnalyzer.shouldPublishTranscription("اهدنا الصراط المستقيم"))
}
