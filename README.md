# QuranRecognitionKit

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fakhandafm17%2FQuranRecognitionKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/akhandafm17/QuranRecognitionKit)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fakhandafm17%2FQuranRecognitionKit%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/akhandafm17/QuranRecognitionKit)

Native Swift SDK for offline Quran verse recognition on iOS.

The package is a Swift implementation of the `offline-tarteel` pipeline shape:

1. Capture or provide 16 kHz mono audio.
2. Compute 80-bin NeMo-compatible mel spectrogram features.
3. Run the ONNX FastConformer CTC model with ONNX Runtime.
4. Greedy CTC decode and fuzzy-match the transcript against all 6,236 Quran verses.
5. Track recitation progress across verses and recover into discovery when the user starts another surah.

The SDK does not bundle the ONNX model. It bundles only `vocab.json` and `quran.json` through `Bundle.module`.

## Installation

### Local Package

In Xcode:

1. Open the app project.
2. Choose `File > Add Package Dependencies`.
3. Choose `Add Local`.
4. Select this package directory.
5. Add the `QuranRecognitionKit` product to the app target.

Then import it:

```swift
import QuranRecognitionKit
```

### GitHub Package

Consumers can add:

```swift
.package(url: "https://github.com/akhandafm17/QuranRecognitionKit.git", from: "0.1.0")
```

The package requires iOS 17 or newer.

## Model Setup

Pass a local ONNX model URL to the recognizer:

```swift
let recognizer = QuranRecognizer(modelURL: modelURL)
try await recognizer.prepare()
```

The model is intentionally not included in the Swift package because it is large. The Dhikr Unlock app currently downloads `FastConformerQuranCTC.onnx.zip`, verifies SHA-256, extracts `FastConformerQuranCTC.onnx`, and passes that file URL to the SDK.

Known local checksums for the current app artifact:

```text
FastConformerQuranCTC.onnx.zip
624de98303964a97880070134311c24d3e42f26ddd9d54efe9219d7ad429befd

FastConformerQuranCTC.onnx
7e7f9aaccbf0f7d12104ebfee9a99625195454a359821139a777f389ec928b50
```

If you use `ModelDownloader`, an expected SHA-256 is required.

## Usage

```swift
import QuranRecognitionKit

let configuration = QuranRecognizer.Configuration(
    processingInterval: 0.75,
    discoveryWindowSeconds: 5.0,
    trackingWindowSeconds: 4.0,
    maximumBufferedSeconds: 12.0,
    intraOpThreadCount: 2,
    minimumSpeechRMS: 0.0015,
    minimumSpeechPeak: 0.006,
    minimumSpeechFrameRatio: 0.03,
    suppressLowInformationTranscriptions: true,
    debugLogging: false
)

let recognizer = QuranRecognizer(modelURL: modelURL, configuration: configuration)
try await recognizer.prepare()

let session = try recognizer.startListening(surahHint: 1)

for await event in session.events {
    switch event {
    case .audioInput(let quality):
        if !quality.isSpeechLikely {
            print("Waiting for clear recitation: \(quality.status)")
        }
    case .transcription(let text):
        // Intended for live UI. Low-information fragments are suppressed by default.
        print(text)
    case .verseDetected(let verse):
        print("Detected \(verse.surahNumber):\(verse.verseNumber)")
    case .stateChanged(let state):
        print(state)
    case .error(let error):
        print(error)
    }
}
```

Stop safely:

```swift
session.stop()
```

Pass the current surah number as `surahHint` when recognition starts from a Quran reader. Discovery will prefer that surah first, which improves startup speed and reduces false jumps for the common case where the user recites from the displayed surah.

You can also run a non-streaming manual check with:

```bash
swift run QuranRecognitionManualHarness /path/to/FastConformerQuranCTC.onnx /path/to/audio.wav 1 1
```

## Public API

```swift
public enum RecognitionState: Sendable, Equatable {
    case idle
    case preparing
    case listening
    case processing
    case stopped
}

public struct RecognizedVerse: Sendable {
    public let surahNumber: Int
    public let verseNumber: Int
    public let ayahEnd: Int?
    public let confidence: Double
    public let arabicText: String
}

public enum AudioInputStatus: Sendable, Equatable {
    case silence
    case tooLittleSpeech
    case speech
    case clipped
}

public struct AudioInputQuality: Sendable {
    public let rms: Float
    public let peak: Float
    public let rmsDecibels: Float
    public let speechFrameRatio: Double
    public let windowSeconds: Double
    public let status: AudioInputStatus
    public let isSpeechLikely: Bool
}

public enum RecognitionEvent: Sendable {
    case audioInput(AudioInputQuality)
    case transcription(String)
    case verseDetected(RecognizedVerse)
    case stateChanged(RecognitionState)
    case error(RecognitionError)
}
```

### Configuration

```swift
extension QuranRecognizer {
    public struct Configuration: Sendable, Equatable {
        public var processingInterval: TimeInterval
        public var discoveryWindowSeconds: Double
        public var trackingWindowSeconds: Double
        public var maximumBufferedSeconds: Double
        public var intraOpThreadCount: Int
        public var minimumSpeechRMS: Float
        public var minimumSpeechPeak: Float
        public var minimumSpeechFrameRatio: Double
        public var suppressLowInformationTranscriptions: Bool
        public var debugLogging: Bool
    }
}
```

The default streaming setup uses longer rolling windows for stability:

- Discovery: 5 seconds.
- Tracking: 4 seconds.
- Fresh audio gate: 1.5 seconds in discovery, 1.25 seconds in tracking.
- Audio quality gate: skips silence, very weak speech, and clipped windows before ONNX inference.
- Transcript quality gate: suppresses short fragments such as single letters from the public `.transcription` event by default.

## Performance Notes

The SDK avoids main-thread inference and audio processing:

- `prepare()` loads resources and ONNX Runtime on a background queue.
- Streaming audio capture appends bounded buffers from the audio callback.
- Inference runs on a serial background queue and reuses the ONNX session.
- Mel computation reuses FFT setup, Hann window, and mel filterbank.
- The audio buffer is capped by `maximumBufferedSeconds`.
- Low-speech audio windows are skipped before ONNX inference.
- Verse matching uses an evidence index and bounded span search instead of scanning every possible span.
- Tracking mode searches locally around the current verse before returning to global discovery.

Measured in this implementation pass:

- `swift test` passes on macOS arm64 with 33 tests.
- The test suite covers hinted discovery, same-surah tracking, low-information noise, near-end recovery, post-completion surah switching, ambiguous candidate rejection, and audio-window quality analysis.
- App-side iOS generic builds passed with this local package integrated.

Known bottlenecks to profile before release:

- ONNX Runtime CPU latency on simulator and a physical iPhone.
- Mel spectrogram allocation volume for long-running streaming sessions.
- Microphone conversion stability during long continuous sessions.
- Real-world recitation quality across devices, rooms, reciters, and microphone positions.

Do not claim perfect performance. Record CPU, memory, and latency on at least one simulator and one physical iPhone before publishing release claims.

## Tests

Run:

```bash
swift test
```

Current tests cover:

- Audio quality gating and low-information transcript suppression.
- Arabic normalization.
- CTC decoding.
- Levenshtein distance and word alignment.
- Verse matching.
- Recitation tracking, surah hints, post-completion discovery, and recovery.
- Resource loading.
- Model path validation.
- Recognition session start/stop lifecycle with a mock capture source.

The manual harness is the integration path for real model + audio validation.

## Attribution And License Review

This package uses `offline-tarteel` as a reference implementation:

- Reference repo: https://github.com/yazinsai/offline-tarteel
- Referenced resources: `data/vocab.json`, `data/quran.json`
- Referenced pipeline notes: 16 kHz mono audio, 80-bin NeMo mel features, ONNX CTC logprobs, greedy CTC decode, fuzzy Quran verse matching.

Publication caveats:

- The checked `offline-tarteel` clone did not include a root `LICENSE` file. Review and obtain permission or replace resources before public distribution.
- ONNX Runtime Swift Package Manager is MIT-licensed: https://github.com/microsoft/onnxruntime-swift-package-manager
- The NVIDIA FastConformer model referenced by `offline-tarteel` is listed there as CC-BY-4.0. Verify the model license and attribution requirements for the exact ONNX artifact you distribute.
- Quran text/source licensing must be reviewed for the bundled `quran.json` before publishing.
- Do not publish the package with a model binary unless its redistribution terms are confirmed.
