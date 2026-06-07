import Foundation

enum AudioWindowAnalyzer {
    static func analyze(
        samples: [Float],
        sampleRate: Int = 16_000,
        minimumSpeechRMS: Float,
        minimumSpeechPeak: Float,
        minimumSpeechFrameRatio: Double
    ) -> AudioInputQuality {
        guard !samples.isEmpty else {
            return AudioInputQuality(
                rms: 0,
                peak: 0,
                rmsDecibels: -120,
                speechFrameRatio: 0,
                windowSeconds: 0,
                status: .silence,
                isSpeechLikely: false
            )
        }

        var squaredSum: Float = 0
        var peak: Float = 0
        for sample in samples {
            let absolute = abs(sample)
            peak = max(peak, absolute)
            squaredSum += sample * sample
        }

        let rms = sqrt(squaredSum / Float(samples.count))
        let rmsDecibels = 20 * log10(max(rms, 0.000_001))
        let speechFrameRatio = speechFrameRatio(
            samples: samples,
            sampleRate: sampleRate,
            threshold: max(minimumSpeechRMS * 1.75, 0.003)
        )
        let clippedRatio = clippedSampleRatio(samples)
        let isSpeechLikely = rms >= minimumSpeechRMS &&
            peak >= minimumSpeechPeak &&
            speechFrameRatio >= minimumSpeechFrameRatio

        let status: AudioInputStatus
        if clippedRatio >= 0.005 {
            status = .clipped
        } else if rms < minimumSpeechRMS || peak < minimumSpeechPeak {
            status = .silence
        } else if speechFrameRatio < minimumSpeechFrameRatio {
            status = .tooLittleSpeech
        } else {
            status = .speech
        }

        return AudioInputQuality(
            rms: rms,
            peak: peak,
            rmsDecibels: rmsDecibels,
            speechFrameRatio: speechFrameRatio,
            windowSeconds: Double(samples.count) / Double(sampleRate),
            status: status,
            isSpeechLikely: isSpeechLikely
        )
    }

    static func shouldPublishTranscription(_ transcription: String) -> Bool {
        let words = ArabicNormalizer.words(transcription)
        let characterCount = words.reduce(0) { $0 + $1.count }

        if words.count >= 2, characterCount >= 6 {
            return true
        }

        return words.contains { $0.count >= 6 }
    }

    private static func speechFrameRatio(
        samples: [Float],
        sampleRate: Int,
        threshold: Float
    ) -> Double {
        let frameLength = max(Int(Double(sampleRate) * 0.03), 1)
        let hopLength = max(Int(Double(sampleRate) * 0.015), 1)
        guard samples.count >= frameLength else { return 0 }

        var speechFrames = 0
        var totalFrames = 0
        var start = 0
        while start + frameLength <= samples.count {
            var squaredSum: Float = 0
            for index in start..<(start + frameLength) {
                squaredSum += samples[index] * samples[index]
            }
            let frameRMS = sqrt(squaredSum / Float(frameLength))
            if frameRMS >= threshold {
                speechFrames += 1
            }
            totalFrames += 1
            start += hopLength
        }

        guard totalFrames > 0 else { return 0 }
        return Double(speechFrames) / Double(totalFrames)
    }

    private static func clippedSampleRatio(_ samples: [Float]) -> Double {
        let clippedCount = samples.reduce(into: 0) { count, sample in
            if abs(sample) >= 0.98 {
                count += 1
            }
        }
        return Double(clippedCount) / Double(samples.count)
    }
}
