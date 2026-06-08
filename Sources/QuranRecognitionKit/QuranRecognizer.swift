import Foundation

public final class QuranRecognizer: @unchecked Sendable {
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

        public init(
            processingInterval: TimeInterval = 0.75,
            discoveryWindowSeconds: Double = 5.0,
            trackingWindowSeconds: Double = 4.0,
            minimumDiscoveryWindowSeconds: Double = 2.25,
            minimumTrackingWindowSeconds: Double = 2.0,
            maximumBufferedSeconds: Double = 12.0,
            intraOpThreadCount: Int = 2,
            minimumSpeechRMS: Float = 0.0015,
            minimumSpeechPeak: Float = 0.006,
            minimumSpeechFrameRatio: Double = 0.03,
            suppressLowInformationTranscriptions: Bool = true,
            debugLogging: Bool = false
        ) {
            self.processingInterval = processingInterval
            self.discoveryWindowSeconds = discoveryWindowSeconds
            self.trackingWindowSeconds = trackingWindowSeconds
            self.minimumDiscoveryWindowSeconds = minimumDiscoveryWindowSeconds
            self.minimumTrackingWindowSeconds = minimumTrackingWindowSeconds
            self.maximumBufferedSeconds = maximumBufferedSeconds
            self.intraOpThreadCount = intraOpThreadCount
            self.minimumSpeechRMS = minimumSpeechRMS
            self.minimumSpeechPeak = minimumSpeechPeak
            self.minimumSpeechFrameRatio = minimumSpeechFrameRatio
            self.suppressLowInformationTranscriptions = suppressLowInformationTranscriptions
            self.debugLogging = debugLogging
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

    public static func bundled(configuration: Configuration = Configuration()) async throws -> QuranRecognizer {
        let modelURL = try await BundledQuranModel.modelURL()
        return QuranRecognizer(modelURL: modelURL, configuration: configuration)
    }

    public func prepare() async throws {
        if pipelineSnapshot() != nil { return }

        debugLog("prepare() started model=\(modelURL.path)")
        try await withCheckedThrowingContinuation { continuation in
            prepareQueue.async {
                do {
                    let decoder = try CTCDecoder.loadBundled()
                    self.debugLog("loaded vocab count=\(decoder.vocabularyCount) blank=\(decoder.blankTokenId)")
                    let matchingEngine = try QuranVerseMatchingEngine.loadBundled()
                    self.debugLog("loaded quran index verses=\(matchingEngine.totalVerses)")
                    let model = ONNXQuranModel(
                        modelURL: self.modelURL,
                        expectedVocabularySize: decoder.vocabularyCount,
                        intraOpThreadCount: self.configuration.intraOpThreadCount
                    )
                    try model.prepare()
                    self.debugLog("onnx model prepared")

                    let pipeline = Pipeline(
                        melComputer: MelSpectrogramComputer(),
                        model: model,
                        decoder: decoder,
                        matchingEngine: matchingEngine
                    )

                    self.lock.withLock {
                        self.pipeline = pipeline
                    }
                    self.debugLog("prepare() complete")
                    continuation.resume()
                } catch {
                    self.debugLog("prepare() failed error=\(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func startListening(surahHint: Int? = nil) throws -> QuranRecognitionSession {
        let pipeline = try requirePipeline()
        debugLog("startListening(surahHint=\(surahHint.map(String.init) ?? "nil"))")
        let tracker = RecitationTracker(
            matchingEngine: pipeline.matchingEngine,
            surahHint: surahHint,
            debugLogging: configuration.debugLogging
        )
        let session = QuranRecognitionSession(
            recognizer: self,
            tracker: tracker,
            configuration: configuration,
            audioCapture: AudioCapture(debugLogging: configuration.debugLogging)
        )
        try session.start()
        return session
    }

    public func recognize(samples: [Float], surahHint: Int? = nil) async throws -> RecognizedVerse? {
        let pipeline = try requirePipeline()
        let tracker = RecitationTracker(
            matchingEngine: pipeline.matchingEngine,
            surahHint: surahHint,
            debugLogging: configuration.debugLogging
        )
        let transcription = try transcribe(samples: samples)
        return tracker.processTranscription(transcription)
    }

    func transcribe(samples: [Float]) throws -> String {
        let pipeline = try requirePipeline()

        return try inferenceQueue.sync {
            let startedAt = Date()
            debugLog("transcribe() samples=\(samples.count) seconds=\(String(format: "%.2f", Double(samples.count) / 16_000.0))")
            let mel = pipeline.melComputer.compute(samples: samples)
            debugLog("mel frames=\(mel.timeFrameCount) bins=\(mel.melBinCount)")
            guard mel.timeFrameCount > 0 else {
                debugLog("transcribe() skipped empty mel")
                return ""
            }
            let logProbs = try pipeline.model.run(melSpectrogram: mel)
            debugLog("onnx output timeSteps=\(logProbs.timeSteps) vocab=\(logProbs.vocabularySize)")
            let transcription = pipeline.decoder.decode(
                logProbs: logProbs.values,
                timeSteps: logProbs.timeSteps,
                vocabSize: logProbs.vocabularySize
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            debugLog("decoded='\(transcription)' elapsed=\(String(format: "%.3f", elapsed))s")
            return transcription
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

    func debugLog(_ message: String) {
        guard configuration.debugLogging else { return }
        print("[QuranRecognitionKit] \(message)")
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
