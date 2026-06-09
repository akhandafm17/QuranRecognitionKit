import AVFoundation
import Foundation

protocol AudioCapturing: AnyObject, Sendable {
    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
}

public final class AudioCapture: AudioCapturing, @unchecked Sendable {
    public let sampleRate: Double
    private let debugLogging: Bool

    private let stateLock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var samplesHandler: (@Sendable ([Float]) -> Void)?
    private var watchdog: DispatchSourceTimer?
    private var lastSampleUptime: TimeInterval = 0
    private var engineStartUptime: TimeInterval = 0
    private var restartAttempts = 0
    private let watchdogQueue = DispatchQueue(label: "QuranRecognitionKit.audio-watchdog")

    /// The input tap can go silent even while AVAudioEngine reports running
    /// (stale CoreAudio state, broken route, another process holding the
    /// microphone). After this many seconds without a delivered buffer the
    /// watchdog restarts capture.
    private let silentInputTimeout: TimeInterval = 2.0
    private let maximumAutomaticRestarts = 3

    public init(sampleRate: Double = 16_000, debugLogging: Bool = false) {
        self.sampleRate = sampleRate
        self.debugLogging = debugLogging
    }

    public func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        #if os(iOS)
        debugLog("start() requested")
        try ensureMicrophonePermission()
        try stateLock.withLock {
            samplesHandler = onSamples
            restartAttempts = 0
            stopEngineLocked()
            try startEngineLocked()
        }
        startWatchdog()
        #else
        throw RecognitionError.unsupportedPlatform
        #endif
    }

    public func stop() {
        #if os(iOS)
        debugLog("stop()")
        stopWatchdog()
        stateLock.withLock {
            samplesHandler = nil
            stopEngineLocked()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(iOS)
    /// Must be called while holding `stateLock`.
    private func startEngineLocked() throws {
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
        logRouteDiagnostics(session)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        debugLog("input format sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecognitionError.microphoneUnavailable(
                "Input node reports an empty format (sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount))"
            )
        }

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

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

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
            guard !samples.isEmpty else { return }

            let handler: (@Sendable ([Float]) -> Void)? = self.stateLock.withLock {
                self.lastSampleUptime = ProcessInfo.processInfo.systemUptime
                if self.restartAttempts != 0 {
                    self.restartAttempts = 0
                    self.debugLog("audio input recovered after engine restart")
                }
                return self.samplesHandler
            }
            handler?(samples)
        }

        do {
            try engine.start()
            audioEngine = engine
            let now = ProcessInfo.processInfo.systemUptime
            engineStartUptime = now
            lastSampleUptime = now
            debugLog("audio engine started")
        } catch {
            inputNode.removeTap(onBus: 0)
            debugLog("audio engine failed error=\(error)")
            throw RecognitionError.microphoneUnavailable(error.localizedDescription)
        }
    }

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

    private func logRouteDiagnostics(_ session: AVAudioSession) {
        guard debugLogging else { return }
        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ", ")
        debugLog(
            "input route=[\(inputs.isEmpty ? "none" : inputs)] inputAvailable=\(session.isInputAvailable) sessionSampleRate=\(session.sampleRate)"
        )
    }

    /// Must be called while holding `stateLock`.
    private func stopEngineLocked() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.checkAudioFlow()
        }
        stateLock.withLock { watchdog = timer }
        timer.resume()
    }

    private func stopWatchdog() {
        let timer: DispatchSourceTimer? = stateLock.withLock {
            let current = watchdog
            watchdog = nil
            return current
        }
        timer?.cancel()
    }

    private func checkAudioFlow() {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot: (running: Bool, silentFor: TimeInterval, attempts: Int) = stateLock.withLock {
            guard audioEngine != nil else { return (false, 0, 0) }
            let reference = max(lastSampleUptime, engineStartUptime)
            return (true, now - reference, restartAttempts)
        }
        guard snapshot.running, snapshot.silentFor > silentInputTimeout else { return }

        guard snapshot.attempts < maximumAutomaticRestarts else {
            if Int(snapshot.silentFor) % 5 == 0 {
                debugLog(
                    "audio input still silent after \(snapshot.attempts) restarts; the microphone may be held by another app or the audio route is broken"
                )
            }
            return
        }

        debugLog(
            "no audio from input tap for \(String(format: "%.1f", snapshot.silentFor))s, restarting audio engine (attempt \(snapshot.attempts + 1)/\(maximumAutomaticRestarts))"
        )
        stateLock.withLock {
            restartAttempts += 1
            stopEngineLocked()
            do {
                try startEngineLocked()
            } catch {
                debugLog("audio engine restart failed error=\(error)")
            }
        }
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
