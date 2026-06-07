@preconcurrency import AVFoundation
import Foundation
import QuranRecognitionKit

@main
struct QuranRecognitionManualHarness {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            print("Usage: QuranRecognitionManualHarness <model.onnx> <audio.wav-or-m4a> [expected-surah] [expected-ayah]")
            return
        }

        let modelURL = URL(fileURLWithPath: arguments[1])
        let audioURL = URL(fileURLWithPath: arguments[2])
        let expectedSurah = arguments.count > 3 ? Int(arguments[3]) : nil
        let expectedAyah = arguments.count > 4 ? Int(arguments[4]) : nil

        do {
            let samples = try loadAudioAs16kMonoFloat(url: audioURL)
            let recognizer = QuranRecognizer(modelURL: modelURL)
            try await recognizer.prepare()

            guard let verse = try await recognizer.recognize(samples: samples, surahHint: expectedSurah) else {
                print("No verse detected")
                return
            }

            print("predicted_surah=\(verse.surahNumber)")
            print("predicted_ayah=\(verse.verseNumber)")
            if let ayahEnd = verse.ayahEnd {
                print("predicted_ayah_end=\(ayahEnd)")
            }
            print("confidence=\(String(format: "%.3f", verse.confidence))")

            if let expectedSurah, let expectedAyah {
                let matched = expectedSurah == verse.surahNumber && expectedAyah == verse.verseNumber
                print("expected=\(expectedSurah):\(expectedAyah)")
                print("matched=\(matched)")
            }
        } catch {
            print("error=\(error)")
        }
    }

    private static func loadAudioAs16kMonoFloat(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw RecognitionError.microphoneUnavailable("Could not allocate source audio buffer")
        }
        try file.read(into: sourceBuffer)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecognitionError.microphoneUnavailable("Could not create target audio format")
        }

        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            throw RecognitionError.microphoneUnavailable("Could not create audio converter")
        }

        let ratio = 16_000 / sourceBuffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            throw RecognitionError.microphoneUnavailable("Could not allocate target audio buffer")
        }

        let provider = AudioInputProvider(buffer: sourceBuffer)
        var error: NSError?
        converter.convert(to: targetBuffer, error: &error) { _, status in
            provider.nextBuffer(status: status)
        }

        if let error {
            throw RecognitionError.microphoneUnavailable(error.localizedDescription)
        }

        guard let channelData = targetBuffer.floatChannelData else { return [] }
        return Array(
            UnsafeBufferPointer(
                start: channelData[0],
                count: Int(targetBuffer.frameLength)
            )
        )
    }
}

private final class AudioInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if didProvideInput {
            status.pointee = .noDataNow
            return nil
        }
        didProvideInput = true
        status.pointee = .haveData
        return buffer
    }
}
