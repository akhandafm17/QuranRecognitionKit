# Contributing

## Local Checks

Run the package test suite:

```bash
swift test
```

Run the generic iOS package build:

```bash
xcodebuild -scheme QuranRecognitionKit-Package -destination 'generic/platform=iOS' build
```

Run the manual harness with a compatible ONNX model and local audio sample:

```bash
swift run QuranRecognitionManualHarness /path/to/FastConformerQuranCTC.onnx /path/to/audio.wav 1 1
```

## Release Checklist

- Confirm `swift test` passes.
- Confirm the generic iOS package build passes.
- Validate a real model and audio sample with the manual harness.
- Test live recognition on at least one physical iPhone.
- Record CPU, memory, and recognition latency before making performance claims.
- Confirm the README install version matches the newest release tag.
- Confirm `LICENSE` is present before publishing.

## Profiling Notes

Profile these areas before release claims:

- ONNX Runtime CPU latency on simulator and physical iPhone.
- Mel spectrogram allocation volume during long streaming sessions.
- Microphone conversion stability during continuous listening.
- Real-world recitation quality across devices, rooms, reciters, and microphone positions.
