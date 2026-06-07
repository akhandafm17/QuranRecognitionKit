import Foundation

public enum RecognitionState: Sendable, Equatable {
    case idle
    case preparing
    case listening
    case processing
    case stopped
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

    public init(
        rms: Float,
        peak: Float,
        rmsDecibels: Float,
        speechFrameRatio: Double,
        windowSeconds: Double,
        status: AudioInputStatus,
        isSpeechLikely: Bool
    ) {
        self.rms = rms
        self.peak = peak
        self.rmsDecibels = rmsDecibels
        self.speechFrameRatio = speechFrameRatio
        self.windowSeconds = windowSeconds
        self.status = status
        self.isSpeechLikely = isSpeechLikely
    }
}

public enum RecognitionError: Error, Sendable, Equatable, CustomStringConvertible {
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

    public var description: String {
        switch self {
        case .resourceMissing(let name):
            return "Missing SDK resource: \(name)"
        case .resourceCorrupt(let name):
            return "Corrupt SDK resource: \(name)"
        case .modelMissing(let path):
            return "Model not found: \(path)"
        case .modelCorrupt(let reason):
            return "Model could not be loaded: \(reason)"
        case .vocabModelMismatch(let expected, let actual):
            return "Model vocabulary size \(actual) does not match vocab size \(expected)"
        case .microphonePermissionDenied:
            return "Microphone permission was denied"
        case .microphoneUnavailable(let reason):
            return "Microphone unavailable: \(reason)"
        case .unsupportedPlatform:
            return "Microphone capture is unsupported on this platform"
        case .invalidAudioSampleRate(let expected, let actual):
            return "Expected \(expected) Hz mono audio, got \(actual) Hz"
        case .inferenceFailed(let reason):
            return "ONNX inference failed: \(reason)"
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        case .downloadChecksumMismatch(let expected, let actual):
            return "Downloaded model checksum mismatch. Expected \(expected), got \(actual)"
        case .notPrepared:
            return "QuranRecognizer.prepare() must complete before starting recognition"
        case .alreadyStopped:
            return "Recognition session is already stopped"
        }
    }
}

public enum RecognitionEvent: Sendable, Equatable {
    case audioInput(AudioInputQuality)
    case transcription(String)
    case verseDetected(RecognizedVerse)
    case stateChanged(RecognitionState)
    case error(RecognitionError)
}
