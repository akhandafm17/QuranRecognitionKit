import Foundation

public final class QuranRecognitionSession: @unchecked Sendable {
    public let events: AsyncStream<RecognitionEvent>

    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private let recognizer: QuranRecognizer
    private let tracker: RecitationTracker
    private let configuration: QuranRecognizer.Configuration
    private let audioCapture: AudioCapturing
    private let processingQueue = DispatchQueue(label: "QuranRecognitionKit.session", qos: .userInitiated)
    private let bufferLock = NSLock()

    private var audioBuffer: [Float] = []
    private var totalSamplesReceived = 0
    private var samplesReceivedAtLastProcess = 0
    private var isProcessing = false
    private var isStopped = false
    private var timer: DispatchSourceTimer?
    private var lastAudioLogSampleCount = 0
    private var processingCycleCount = 0
    private var stalledInputCycles = 0
    private var lastStallCheckSampleCount = 0

    init(
        recognizer: QuranRecognizer,
        tracker: RecitationTracker,
        configuration: QuranRecognizer.Configuration,
        audioCapture: AudioCapturing
    ) {
        self.recognizer = recognizer
        self.tracker = tracker
        self.configuration = configuration
        self.audioCapture = audioCapture

        var streamContinuation: AsyncStream<RecognitionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    deinit {
        timer?.cancel()
        timer = nil
        audioCapture.stop()
        continuation.finish()
    }

    func start() throws {
        recognizer.debugLog("session start()")
        continuation.yield(.stateChanged(.preparing))
        do {
            try audioCapture.start { [weak self] samples in
                self?.append(samples: samples)
            }
            startTimer()
            recognizer.debugLog("session listening")
            continuation.yield(.stateChanged(.listening))
        } catch let error as RecognitionError {
            recognizer.debugLog("session start failed error=\(error)")
            continuation.yield(.error(error))
            throw error
        } catch {
            let recognitionError = RecognitionError.microphoneUnavailable(error.localizedDescription)
            recognizer.debugLog("session start failed error=\(recognitionError)")
            continuation.yield(.error(recognitionError))
            throw recognitionError
        }
    }

    public func stop() {
        processingQueue.async {
            guard !self.isStopped else { return }
            self.isStopped = true
            self.timer?.cancel()
            self.timer = nil
            self.audioCapture.stop()
            self.bufferLock.withLock {
                self.audioBuffer.removeAll(keepingCapacity: true)
                self.totalSamplesReceived = 0
                self.samplesReceivedAtLastProcess = 0
                self.lastAudioLogSampleCount = 0
            }
            self.tracker.reset()
            self.recognizer.debugLog("session stopped")
            self.continuation.yield(.stateChanged(.stopped))
            self.continuation.finish()
        }
    }

    private func append(samples: [Float]) {
        guard !samples.isEmpty else { return }
        let maxSamples = Int(configuration.maximumBufferedSeconds * 16_000)

        bufferLock.withLock {
            audioBuffer.append(contentsOf: samples)
            totalSamplesReceived += samples.count
            if audioBuffer.count > maxSamples {
                audioBuffer.removeFirst(audioBuffer.count - maxSamples)
            }

            if totalSamplesReceived - lastAudioLogSampleCount >= 16_000 {
                lastAudioLogSampleCount = totalSamplesReceived
                let bufferedSeconds = Double(audioBuffer.count) / 16_000.0
                let totalSeconds = Double(totalSamplesReceived) / 16_000.0
                recognizer.debugLog(
                    "audio samples total=\(totalSamplesReceived) totalSeconds=\(String(format: "%.1f", totalSeconds)) bufferedSeconds=\(String(format: "%.1f", bufferedSeconds))"
                )
            }
        }
    }

    /// The microphone delivers buffers continuously while capture is healthy —
    /// even in a silent room the samples keep arriving. Zero new samples
    /// across multiple processing cycles means the input tap has stalled
    /// (broken route, microphone held by another process). Surface that as a
    /// silence quality event so the host app can show feedback instead of an
    /// indefinite "listening" state; AudioCapture's watchdog restarts the
    /// engine in parallel.
    private func reportStalledAudioInputIfNeeded() {
        let totalNow = bufferLock.withLock { totalSamplesReceived }
        if totalNow != lastStallCheckSampleCount {
            lastStallCheckSampleCount = totalNow
            stalledInputCycles = 0
            return
        }

        stalledInputCycles += 1
        let cyclesPerReport = max(1, Int((2.0 / configuration.processingInterval).rounded()))
        guard stalledInputCycles % cyclesPerReport == 0 else { return }

        let stalledSeconds = Double(stalledInputCycles) * configuration.processingInterval
        recognizer.debugLog(
            "no audio input for \(String(format: "%.1f", stalledSeconds))s while listening (capture stalled)"
        )
        continuation.yield(
            .audioInput(
                AudioInputQuality(
                    rms: 0,
                    peak: 0,
                    rmsDecibels: -120,
                    speechFrameRatio: 0,
                    windowSeconds: stalledSeconds,
                    status: .silence,
                    isSpeechLikely: false
                )
            )
        )
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(
            deadline: .now() + configuration.processingInterval,
            repeating: configuration.processingInterval
        )
        timer.setEventHandler { [weak self] in
            self?.processBufferedAudio()
        }
        self.timer = timer
        timer.resume()
    }

    private func processBufferedAudio() {
        guard !isStopped, !isProcessing else { return }
        processingCycleCount += 1
        reportStalledAudioInputIfNeeded()

        let mode = tracker.mode
        let windowSeconds = mode == .tracking
            ? configuration.trackingWindowSeconds
            : configuration.discoveryWindowSeconds
        let minimumWindowSeconds = mode == .tracking
            ? configuration.minimumTrackingWindowSeconds
            : configuration.minimumDiscoveryWindowSeconds
        let windowSamples = Int(windowSeconds * 16_000)
        let minimumWindowSamples = Int(min(windowSeconds, minimumWindowSeconds) * 16_000)

        let samples: [Float]? = bufferLock.withLock {
            guard audioBuffer.count >= minimumWindowSamples else {
                if processingCycleCount % 4 == 0 {
                    recognizer.debugLog(
                        "waiting for audio mode=\(mode) bufferSamples=\(audioBuffer.count) needed=\(minimumWindowSamples)"
                    )
                }
                return nil
            }

            let newSamples = totalSamplesReceived - samplesReceivedAtLastProcess
            let minimumNewSamples = minimumNewSamplesBeforeProcessing(mode: mode)
            if newSamples < minimumNewSamples, samplesReceivedAtLastProcess > 0 {
                if processingCycleCount % 4 == 0 {
                    recognizer.debugLog(
                        "skipping cycle mode=\(mode), newSamples=\(newSamples) minimum=\(minimumNewSamples)"
                    )
                }
                return nil
            }

            samplesReceivedAtLastProcess = totalSamplesReceived
            return Array(audioBuffer.suffix(min(audioBuffer.count, windowSamples)))
        }

        guard let samples else { return }

        let quality = AudioWindowAnalyzer.analyze(
            samples: samples,
            minimumSpeechRMS: configuration.minimumSpeechRMS,
            minimumSpeechPeak: configuration.minimumSpeechPeak,
            minimumSpeechFrameRatio: configuration.minimumSpeechFrameRatio
        )
        continuation.yield(.audioInput(quality))

        recognizer.debugLog(
            "audio quality status=\(quality.status) speechLikely=\(quality.isSpeechLikely) rmsDb=\(String(format: "%.1f", quality.rmsDecibels)) peak=\(String(format: "%.4f", quality.peak)) speechFrames=\(String(format: "%.2f", quality.speechFrameRatio))"
        )

        guard quality.isSpeechLikely else {
            recognizer.debugLog("skipping inference for non-speech audio window")
            return
        }

        isProcessing = true
        recognizer.debugLog(
            "processing mode=\(mode) windowSeconds=\(String(format: "%.1f", windowSeconds)) samples=\(samples.count)"
        )
        continuation.yield(.stateChanged(.processing))

        do {
            let transcription = try recognizer.transcribe(samples: samples)
            if !transcription.isEmpty {
                let detectedVerse = tracker.processTranscription(transcription)
                let shouldPublishTranscription =
                    !configuration.suppressLowInformationTranscriptions ||
                    AudioWindowAnalyzer.shouldPublishTranscription(transcription) ||
                    detectedVerse != nil

                if shouldPublishTranscription {
                    continuation.yield(.transcription(transcription))
                } else {
                    recognizer.debugLog("suppressed low-information transcription from UI")
                }

                if let verse = detectedVerse {
                    recognizer.debugLog("emitting verse \(verse.surahNumber):\(verse.verseNumber) confidence=\(String(format: "%.3f", verse.confidence))")
                    continuation.yield(.verseDetected(verse))
                } else {
                    recognizer.debugLog("no verse emitted for transcription")
                }
            } else {
                recognizer.debugLog("empty transcription")
            }
            continuation.yield(.stateChanged(.listening))
        } catch let error as RecognitionError {
            recognizer.debugLog("processing recognition error=\(error)")
            continuation.yield(.error(error))
        } catch {
            recognizer.debugLog("processing error=\(error)")
            continuation.yield(.error(.inferenceFailed(error.localizedDescription)))
        }

        isProcessing = false
    }

    private func minimumNewSamplesBeforeProcessing(mode: TrackingMode) -> Int {
        let freshAudioSeconds: Double
        switch mode {
        case .discovery:
            freshAudioSeconds = configuration.discoveryFreshAudioSeconds
        case .tracking:
            freshAudioSeconds = configuration.trackingFreshAudioSeconds
        }
        return max(1, Int(freshAudioSeconds * 16_000))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
