import Foundation

public final class QuranRecognizer: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var processingInterval: TimeInterval
        public var discoveryWindowSeconds: Double
        public var trackingWindowSeconds: Double
        public var maximumBufferedSeconds: Double
        public var intraOpThreadCount: Int

        public init(
            processingInterval: TimeInterval = 0.35,
            discoveryWindowSeconds: Double = 2.0,
            trackingWindowSeconds: Double = 0.75,
            maximumBufferedSeconds: Double = 10.0,
            intraOpThreadCount: Int = 2
        ) {
            self.processingInterval = processingInterval
            self.discoveryWindowSeconds = discoveryWindowSeconds
            self.trackingWindowSeconds = trackingWindowSeconds
            self.maximumBufferedSeconds = maximumBufferedSeconds
            self.intraOpThreadCount = intraOpThreadCount
        }
    }

    public let modelURL: URL
    public let configuration: Configuration

    private let prepareQueue = DispatchQueue(label: "QuranRecognitionKit.prepare", qos: .userInitiated)
    private let inferenceQueue = DispatchQueue(label: "QuranRecognitionKit.inference", qos: .userInitiated)
    private let lock = NSLock()
    private var pipeline: Pipeline?

    public init(modelURL: URL, configuration: Configuration = Configuration()) {
        self.modelURL = modelURL
        self.configuration = configuration
    }

    public func prepare() async throws {
        if pipelineSnapshot() != nil { return }

        try await withCheckedThrowingContinuation { continuation in
            prepareQueue.async {
                do {
                    let decoder = try CTCDecoder.loadBundled()
                    let matchingEngine = try QuranVerseMatchingEngine.loadBundled()
                    let model = ONNXQuranModel(
                        modelURL: self.modelURL,
                        expectedVocabularySize: decoder.vocabularyCount,
                        intraOpThreadCount: self.configuration.intraOpThreadCount
                    )
                    try model.prepare()

                    let pipeline = Pipeline(
                        melComputer: MelSpectrogramComputer(),
                        model: model,
                        decoder: decoder,
                        matchingEngine: matchingEngine
                    )

                    self.lock.withLock {
                        self.pipeline = pipeline
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func startListening(surahHint: Int? = nil) throws -> QuranRecognitionSession {
        let pipeline = try requirePipeline()
        let tracker = RecitationTracker(matchingEngine: pipeline.matchingEngine, surahHint: surahHint)
        let session = QuranRecognitionSession(
            recognizer: self,
            tracker: tracker,
            configuration: configuration,
            audioCapture: AudioCapture()
        )
        try session.start()
        return session
    }

    public func recognize(samples: [Float], surahHint: Int? = nil) async throws -> RecognizedVerse? {
        let pipeline = try requirePipeline()
        let tracker = RecitationTracker(matchingEngine: pipeline.matchingEngine, surahHint: surahHint)
        let transcription = try transcribe(samples: samples)
        _ = tracker.processTranscription(transcription)
        return tracker.processTranscription(transcription)
    }

    func transcribe(samples: [Float]) throws -> String {
        let pipeline = try requirePipeline()

        return try inferenceQueue.sync {
            let mel = pipeline.melComputer.compute(samples: samples)
            guard mel.timeFrameCount > 0 else { return "" }
            let logProbs = try pipeline.model.run(melSpectrogram: mel)
            return pipeline.decoder.decode(
                logProbs: logProbs.values,
                timeSteps: logProbs.timeSteps,
                vocabSize: logProbs.vocabularySize
            )
        }
    }

    private func requirePipeline() throws -> Pipeline {
        guard let pipeline = pipelineSnapshot() else {
            throw RecognitionError.notPrepared
        }
        return pipeline
    }

    private func pipelineSnapshot() -> Pipeline? {
        lock.withLock { pipeline }
    }
}

private struct Pipeline {
    let melComputer: MelSpectrogramComputer
    let model: ONNXQuranModel
    let decoder: CTCDecoder
    let matchingEngine: QuranVerseMatchingEngine
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
