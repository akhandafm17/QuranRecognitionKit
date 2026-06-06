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
        continuation.yield(.stateChanged(.preparing))
        do {
            try audioCapture.start { [weak self] samples in
                self?.append(samples: samples)
            }
            startTimer()
            continuation.yield(.stateChanged(.listening))
        } catch let error as RecognitionError {
            continuation.yield(.error(error))
            throw error
        } catch {
            let recognitionError = RecognitionError.microphoneUnavailable(error.localizedDescription)
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
            }
            self.tracker.reset()
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
        }
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

        let mode = tracker.mode
        let windowSeconds = mode == .tracking
            ? configuration.trackingWindowSeconds
            : configuration.discoveryWindowSeconds
        let windowSamples = Int(windowSeconds * 16_000)

        let samples: [Float]? = bufferLock.withLock {
            guard audioBuffer.count >= windowSamples else { return nil }

            if mode == .discovery {
                let newSamples = totalSamplesReceived - samplesReceivedAtLastProcess
                let minimumNewSamples = Int(0.4 * 16_000)
                if newSamples < minimumNewSamples, samplesReceivedAtLastProcess > 0 {
                    return nil
                }
            }

            samplesReceivedAtLastProcess = totalSamplesReceived
            return Array(audioBuffer.suffix(windowSamples))
        }

        guard let samples else { return }

        isProcessing = true
        continuation.yield(.stateChanged(.processing))

        do {
            let transcription = try recognizer.transcribe(samples: samples)
            if !transcription.isEmpty {
                continuation.yield(.transcription(transcription))
                if let verse = tracker.processTranscription(transcription) {
                    continuation.yield(.verseDetected(verse))
                }
            }
            continuation.yield(.stateChanged(.listening))
        } catch let error as RecognitionError {
            continuation.yield(.error(error))
        } catch {
            continuation.yield(.error(.inferenceFailed(error.localizedDescription)))
        }

        isProcessing = false
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
