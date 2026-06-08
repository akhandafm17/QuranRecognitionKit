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

The SDK bundles the zipped ONNX model, `vocab.json`, and `quran.json` through `Bundle.module`.

## Requirements

- Swift 6.2 or newer.
- iOS 17 or newer.
- Xcode with a Swift 6.2 toolchain or newer for app integration.
- Microphone permission if you use live recognition through `startListening`.

QuranRecognitionKit depends on Microsoft's `onnxruntime-swift-package-manager` package. Swift Package Manager resolves this dependency automatically.

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

In Xcode:

1. Choose `File > Add Package Dependencies`.
2. Enter `https://github.com/akhandafm17/QuranRecognitionKit.git`.
3. Select version `0.1.8` or newer.
4. Add the `QuranRecognitionKit` product to the app target.

In a Swift package manifest:

```swift
.package(url: "https://github.com/akhandafm17/QuranRecognitionKit.git", from: "0.1.8")
```

The package requires iOS 17 or newer.

## App Permissions

Live recognition uses the device microphone. Add a microphone usage description to the host app's `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is used to recognize Quran recitation on device.</string>
```

The SDK configures an `AVAudioSession` for recording when `startListening` is called. If your app also plays audio, coordinate calls to your own audio session setup with recognition start and stop.

`ModelDownloader` uses `URLSession`. If your model URL is not HTTPS, configure App Transport Security in the host app.

## Bundled Model

QuranRecognitionKit includes a bundled zipped ONNX model. For the common path, create a ready-to-use recognizer from the bundled model:

```swift
let recognizer = try await QuranRecognizer.bundled()
try await recognizer.prepare()
```

On first use, the SDK extracts and verifies the bundled model into the app cache directory. Later calls reuse the extracted model if the checksum still matches.

The bundled archive is about 96 MB, and the extracted ONNX model is about 126 MB. This makes the Swift package larger, but keeps integration ready-to-go and fully offline after installation.

The expected audio input for direct recognition is 16 kHz mono `Float` PCM samples. Live recognition captures microphone input and converts it internally before inference.

## Custom Model

You can still pass your own compatible ONNX model URL:

```swift
let recognizer = QuranRecognizer(modelURL: modelURL)
try await recognizer.prepare()
```

The model must produce CTC logits for the same vocabulary bundled in `vocab.json`. If the model vocabulary size does not match, `prepare()` throws `RecognitionError.vocabModelMismatch`.

If you use `ModelDownloader`, an expected SHA-256 is required.

```swift
let downloader = ModelDownloader()
let localModelURL = try await downloader.download(
    from: modelArchiveURL,
    expectedSHA256: expectedChecksum,
    destinationURL: destinationURL
) { progress in
    print("Download progress: \(progress)")
}
```

`ModelDownloader` verifies and stores bytes. It does not unzip archives; extract compressed model files in the host app before passing the ONNX URL to `QuranRecognizer`.

## Usage

### Live Recognition

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

let recognizer = try await QuranRecognizer.bundled(configuration: configuration)
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

### One-Shot Recognition

Use `recognize(samples:surahHint:)` when you already have 16 kHz mono `Float` samples:

```swift
let recognizer = QuranRecognizer(modelURL: modelURL)
try await recognizer.prepare()

if let verse = try await recognizer.recognize(samples: samples, surahHint: 1) {
    print("\(verse.surahNumber):\(verse.verseNumber)")
}
```

### Manual Harness

You can also run a non-streaming manual check with:

```bash
swift run QuranRecognitionManualHarness /path/to/FastConformerQuranCTC.onnx /path/to/audio.wav 1 1
```

## Public API

### Recognizer

```swift
public final class QuranRecognizer: @unchecked Sendable {
    public init(modelURL: URL, configuration: Configuration = Configuration())
    public static func bundled(configuration: Configuration = Configuration()) async throws -> QuranRecognizer

    public func prepare() async throws
    public func startListening(surahHint: Int? = nil) throws -> QuranRecognitionSession
    public func recognize(samples: [Float], surahHint: Int? = nil) async throws -> RecognizedVerse?
}
```

Call `prepare()` once before recognition. It loads bundled resources, creates the ONNX Runtime session, and validates the model against the bundled vocabulary.

### Bundled Model

```swift
public enum BundledQuranModel {
    public static let archiveFileName: String
    public static let modelFileName: String

    public static func modelURL() async throws -> URL
    public static func removeExtractedModel() throws
}
```

`modelURL()` extracts and verifies the bundled model if needed, then returns the local extracted ONNX file URL. `removeExtractedModel()` removes the cached extracted model so it can be recreated from the bundled archive.

### Session

```swift
public final class QuranRecognitionSession: @unchecked Sendable {
    public let events: AsyncStream<RecognitionEvent>
    public func stop()
}
```

`events` yields microphone quality updates, decoded transcripts, verse detections, state changes, and errors. Call `stop()` when the user leaves the recognition flow or disables listening.

### Events And Results

```swift
public enum RecognitionState: Sendable, Equatable {
    case idle
    case preparing
    case listening
    case processing
    case stopped
}

public struct RecognizedVerse: Sendable, Equatable {
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

public struct AudioInputQuality: Sendable, Equatable {
    public let rms: Float
    public let peak: Float
    public let rmsDecibels: Float
    public let speechFrameRatio: Double
    public let windowSeconds: Double
    public let status: AudioInputStatus
    public let isSpeechLikely: Bool
}

public enum RecognitionEvent: Sendable, Equatable {
    case audioInput(AudioInputQuality)
    case transcription(String)
    case verseDetected(RecognizedVerse)
    case stateChanged(RecognitionState)
    case error(RecognitionError)
}
```

`ayahEnd` is set when the matcher identifies a span that covers multiple ayahs. For single-ayah detections it is `nil`.

### Model Downloader

```swift
public actor ModelDownloader {
    public init()

    public func download(
        from sourceURL: URL,
        expectedSHA256: String,
        destinationURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL
}
```

`ModelDownloader` streams a remote file to disk and verifies SHA-256 before replacing the destination file.

### Errors

```swift
public enum RecognitionError: Error, Sendable, Equatable {
    case resourceMissing(String)
    case resourceCorrupt(String)
    case modelMissing(String)
    case modelCorrupt(String)
    case vocabModelMismatch(expected: Int, actual: Int)
    case microphonePermissionDenied
    case microphoneUnavailable(String)
    case unsupportedPlatform
    case invalidAudioSampleRate(expected: Double, actual: Double)
    case inferenceFailed(String)
    case downloadFailed(String)
    case downloadChecksumMismatch(expected: String, actual: String)
    case notPrepared
    case alreadyStopped
}
```

### Configuration

```swift
extension QuranRecognizer {
    public struct Configuration: Sendable, Equatable {
        public var processingInterval: TimeInterval
        public var discoveryWindowSeconds: Double
        public var trackingWindowSeconds: Double
        public var minimumDiscoveryWindowSeconds: Double
        public var minimumTrackingWindowSeconds: Double
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
- First inference gate: 2.25 seconds in discovery, 2 seconds in tracking.
- Fresh audio gate after the first inference: 1.5 seconds in discovery, 1.25 seconds in tracking.
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

Current validation:

- `swift test` passes on macOS arm64 with 33 tests.
- The test suite covers hinted discovery, same-surah tracking, low-information noise, near-end recovery, post-completion surah switching, ambiguous candidate rejection, and audio-window quality analysis.
- Generic iOS package builds pass with `xcodebuild -scheme QuranRecognitionKit-Package -destination 'generic/platform=iOS' build`.
- App-side iOS generic builds passed with this package integrated.

For release profiling and maintainer checks, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Troubleshooting

### `RecognitionError.notPrepared`

Call `try await recognizer.prepare()` before `startListening` or `recognize(samples:)`.

### `RecognitionError.modelMissing` Or `modelCorrupt`

For the bundled model path, call `BundledQuranModel.removeExtractedModel()` and try again. For custom models, verify the local model URL points to an existing, non-empty `.onnx` file.

### `RecognitionError.vocabModelMismatch`

The ONNX model output vocabulary does not match the bundled `vocab.json`. Use a model exported for the same tokenizer/vocabulary as this SDK.

### Microphone Permission Errors

Make sure the host app includes `NSMicrophoneUsageDescription`. On device, also check iOS Settings if the user previously denied microphone access.

### No Verse Is Detected

Check these first:

- The model URL is correct and `prepare()` succeeded.
- The device microphone is receiving clear speech.
- The app is not feeding silence, clipped audio, or the wrong sample rate to one-shot recognition.
- `surahHint` matches the current reader context when the user is likely reciting the displayed surah.
- `debugLogging: true` is enabled while diagnosing recognition quality.

### Xcode Cannot Find The Package Product

In the host app, remove and re-add the package dependency, then choose `File > Packages > Reset Package Caches`. Confirm the app target links the `QuranRecognitionKit` product.

### Swift Package Index Still Shows Old Compatibility

Swift Package Index and shields.io cache build and badge results. After pushing a fix or tag, wait for SPI to rescan the package and rebuild the compatibility matrix.

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

## License

QuranRecognitionKit source code is available under the MIT license. See [LICENSE](LICENSE).

The bundled model has separate upstream attribution and license terms. See [MODEL_NOTICE.md](MODEL_NOTICE.md).
