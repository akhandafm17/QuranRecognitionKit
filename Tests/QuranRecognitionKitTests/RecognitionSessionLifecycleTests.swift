import Foundation
import Testing
@testable import QuranRecognitionKit

@Test func configurationDefaultsUseMobileStreamingCadence() {
    let configuration = QuranRecognizer.Configuration()

    #expect(configuration.processingInterval == 0.20)
    #expect(configuration.discoveryWindowSeconds == 3.5)
    #expect(configuration.trackingWindowSeconds == 2.25)
    #expect(configuration.minimumDiscoveryWindowSeconds == 1.75)
    #expect(configuration.minimumTrackingWindowSeconds == 0.90)
    #expect(configuration.discoveryFreshAudioSeconds == 0.30)
    #expect(configuration.trackingFreshAudioSeconds == 0.20)
    #expect(configuration.maximumBufferedSeconds == 6.0)
    #expect(configuration.intraOpThreadCount == 1)
}

@Test func recognitionSessionStartStopLifecycleEmitsStates() async throws {
    let verses = [
        QuranVerseMatchingEngine.VerseEntry(
            surahNumber: 1,
            verseNumber: 1,
            arabicText: "بسم الله الرحمن الرحيم",
            normalizedText: "بسم الله الرحمن الرحيم",
            surahNameArabic: "الفاتحة",
            surahNameEnglish: "Al-Fatihah"
        )
    ]
    let engine = QuranVerseMatchingEngine(verses: verses)
    let tracker = RecitationTracker(matchingEngine: engine)
    let recognizer = QuranRecognizer(modelURL: URL(fileURLWithPath: "/tmp/unused.onnx"))
    let capture = MockAudioCapture()
    let session = QuranRecognitionSession(
        recognizer: recognizer,
        tracker: tracker,
        configuration: QuranRecognizer.Configuration(processingInterval: 0.01),
        audioCapture: capture
    )

    try session.start()
    session.stop()

    var states: [RecognitionState] = []
    for await event in session.events {
        if case .stateChanged(let state) = event {
            states.append(state)
        }
    }

    #expect(capture.didStart)
    #expect(capture.didStop)
    #expect(states.contains(.preparing))
    #expect(states.contains(.listening))
    #expect(states.contains(.stopped))
}

@Test func stalledAudioInputSurfacesSilenceQualityEvent() async throws {
    let verses = [
        QuranVerseMatchingEngine.VerseEntry(
            surahNumber: 1,
            verseNumber: 1,
            arabicText: "بسم الله الرحمن الرحيم",
            normalizedText: "بسم الله الرحمن الرحيم",
            surahNameArabic: "الفاتحة",
            surahNameEnglish: "Al-Fatihah"
        )
    ]
    let engine = QuranVerseMatchingEngine(verses: verses)
    let tracker = RecitationTracker(matchingEngine: engine)
    let recognizer = QuranRecognizer(modelURL: URL(fileURLWithPath: "/tmp/unused.onnx"))
    // Capture starts successfully but never delivers samples, like a stalled
    // input tap (broken route or microphone held by another process).
    let capture = MockAudioCapture()
    let session = QuranRecognitionSession(
        recognizer: recognizer,
        tracker: tracker,
        configuration: QuranRecognizer.Configuration(processingInterval: 0.01),
        audioCapture: capture
    )

    try session.start()

    var sawStallEvent = false
    for await event in session.events {
        if case .audioInput(let quality) = event, quality.status == .silence, !quality.isSpeechLikely {
            sawStallEvent = true
            session.stop()
        }
        if sawStallEvent, case .stateChanged(.stopped) = event {
            break
        }
    }

    #expect(sawStallEvent)
}

private final class MockAudioCapture: AudioCapturing, @unchecked Sendable {
    private(set) var didStart = false
    private(set) var didStop = false

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        didStart = true
    }

    func stop() {
        didStop = true
    }
}
