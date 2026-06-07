import AVFoundation
import Foundation

protocol AudioCapturing: AnyObject, Sendable {
    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
}

public final class AudioCapture: AudioCapturing, @unchecked Sendable {
    public let sampleRate: Double
    private let debugLogging: Bool
    private var audioEngine: AVAudioEngine?

    public init(sampleRate: Double = 16_000, debugLogging: Bool = false) {
        self.sampleRate = sampleRate
        self.debugLogging = debugLogging
    }

    public func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        #if os(iOS)
        debugLog("start() requested")
        try ensureMicrophonePermission()
        stopEngine()

        let session = AVAudioSession.sharedInstance()
        do {
            try configureAudioSession(session, mode: .measurement)
            debugLog("audio session active category=playAndRecord mode=measurement")
        } catch {
            debugLog("measurement audio session failed error=\(error), retrying default mode")
            do {
                try configureAudioSession(session, mode: .default)
                debugLog("audio session active category=playAndRecord mode=default")
            } catch {
                debugLog("audio session failed error=\(error)")
                throw RecognitionError.microphoneUnavailable(error.localizedDescription)
            }
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        debugLog("input format sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecognitionError.microphoneUnavailable("Could not create 16 kHz mono format")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecognitionError.microphoneUnavailable("Could not create audio converter")
        }

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            let targetFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate)
            guard targetFrameCount > 0,
                  let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCount) else {
                return
            }

            var conversionError: NSError?
            var didProvideBuffer = false
            let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
                guard !didProvideBuffer else {
                    outputStatus.pointee = .noDataNow
                    return nil
                }
                didProvideBuffer = true
                outputStatus.pointee = .haveData
                return buffer
            }

            guard status != .error,
                  conversionError == nil,
                  let channelData = converted.floatChannelData else {
                return
            }

            let samples = Array(
                UnsafeBufferPointer(
                    start: channelData[0],
                    count: Int(converted.frameLength)
                )
            )
            onSamples(samples)
        }

        do {
            try engine.start()
            audioEngine = engine
            debugLog("audio engine started")
        } catch {
            inputNode.removeTap(onBus: 0)
            debugLog("audio engine failed error=\(error)")
            throw RecognitionError.microphoneUnavailable(error.localizedDescription)
        }
        #else
        throw RecognitionError.unsupportedPlatform
        #endif
    }

    public func stop() {
        #if os(iOS)
        debugLog("stop()")
        stopEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(iOS)
    private func configureAudioSession(
        _ session: AVAudioSession,
        mode: AVAudioSession.Mode
    ) throws {
        try session.setCategory(
            .playAndRecord,
            mode: mode,
            options: [.allowBluetooth, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func stopEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    private func ensureMicrophonePermission() throws {
        let session = AVAudioSession.sharedInstance()

        switch session.recordPermission {
        case .granted:
            debugLog("microphone permission already granted")
            return
        case .denied:
            debugLog("microphone permission denied")
            throw RecognitionError.microphonePermissionDenied
        case .undetermined:
            debugLog("requesting microphone permission")
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            session.requestRecordPermission { allowed in
                granted = allowed
                semaphore.signal()
            }
            semaphore.wait()
            debugLog("microphone permission response granted=\(granted)")
            guard granted else { throw RecognitionError.microphonePermissionDenied }
        @unknown default:
            throw RecognitionError.microphonePermissionDenied
        }
    }
    #endif

    private func debugLog(_ message: String) {
        guard debugLogging else { return }
        print("[QuranRecognitionKit.AudioCapture] \(message)")
    }
}
