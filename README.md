# QuranRecognitionKit

Native Swift SDK for offline Quran verse recognition on iOS.

The package is a Swift implementation of the `offline-tarteel` pipeline shape:

1. Capture or provide 16 kHz mono audio.
2. Compute 80-bin NeMo-compatible mel spectrogram features.
3. Run the ONNX FastConformer CTC model with ONNX Runtime.
4. Greedy CTC decode and fuzzy-match the transcript against all 6,236 Quran verses.

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

### Future GitHub Package

After publishing, consumers can add:

```swift
.package(url: "https://github.com/<owner>/QuranRecognitionKit.git", from: "0.1.0")
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

let recognizer = QuranRecognizer(modelURL: modelURL)
try await recognizer.prepare()

let session = try recognizer.startListening(surahHint: nil)

for await event in session.events {
    switch event {
    case .transcription(let text):
        print(text)
    case .verseDetected(let verse):
        print(verse)
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

You can also run a non-streaming manual check with:

```bash
swift run QuranRecognitionManualHarness /path/to/FastConformerQuranCTC.onnx /path/to/audio.wav 1 1
```

## Public API

```swift
public struct RecognizedVerse: Sendable {
    public let surahNumber: Int
    public let verseNumber: Int
    public let ayahEnd: Int?
    public let confidence: Double
    public let arabicText: String
}

public enum RecognitionEvent: Sendable {
    case transcription(String)
    case verseDetected(RecognizedVerse)
    case stateChanged(RecognitionState)
    case error(RecognitionError)
}
```

## Performance Notes

The SDK avoids main-thread inference and audio processing:

- `prepare()` loads resources and ONNX Runtime on a background queue.
- Streaming audio capture appends bounded buffers from the audio callback.
- Inference runs on a serial background queue and reuses the ONNX session.
- Mel computation reuses FFT setup, Hann window, and mel filterbank.
- The audio buffer is capped by `maximumBufferedSeconds`.
- Verse matching scans all verses once, then evaluates multi-verse spans only around the top candidates.

Measured in this implementation pass:

- `swift test` passes on macOS arm64 with 12 tests.
- Exact verse matching test over bundled resources completed in about 4.3 seconds in the test runner.
- Manual end-to-end harness on macOS with `001001.mp3` predicted `1:1` with confidence `0.846`.
- End-to-end ONNX latency was not measured on simulator or physical iPhone in this pass.

Known bottlenecks to profile before release:

- ONNX Runtime CPU latency on simulator and a physical iPhone.
- Mel spectrogram allocation volume for long-running streaming sessions.
- Full-corpus Levenshtein matching cost during discovery.
- Microphone conversion stability during long continuous sessions.

Do not claim perfect performance. Record CPU, memory, and latency on at least one simulator and one physical iPhone before publishing release claims.

## Tests

Run:

```bash
swift test
```

Current tests cover:

- Arabic normalization.
- CTC decoding.
- Levenshtein distance and word alignment.
- Verse matching.
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
