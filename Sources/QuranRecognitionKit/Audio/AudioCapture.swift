import AVFoundation
import Foundation

protocol AudioCapturing: AnyObject, Sendable {
    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
}

public final class AudioCapture: AudioCapturing, @unchecked Sendable {
    public let sampleRate: Double
    private var audioEngine: AVAudioEngine?

    public init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
    }

    public func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        #if os(iOS)
        try ensureMicrophonePermission()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw RecognitionError.microphoneUnavailable(error.localizedDescription)
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

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
            let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
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
        } catch {
            inputNode.removeTap(onBus: 0)
            throw RecognitionError.microphoneUnavailable(error.localizedDescription)
        }
        #else
        throw RecognitionError.unsupportedPlatform
        #endif
    }

    public func stop() {
        #if os(iOS)
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(iOS)
    private func ensureMicrophonePermission() throws {
        let session = AVAudioSession.sharedInstance()

        switch session.recordPermission {
        case .granted:
            return
        case .denied:
            throw RecognitionError.microphonePermissionDenied
        case .undetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            session.requestRecordPermission { allowed in
                granted = allowed
                semaphore.signal()
            }
            semaphore.wait()
            guard granted else { throw RecognitionError.microphonePermissionDenied }
        @unknown default:
            throw RecognitionError.microphonePermissionDenied
        }
    }
    #endif
}
