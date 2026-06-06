import Accelerate
import Foundation

public struct MelSpectrogram: Sendable, Equatable {
    public let features: [Float]
    public let melBinCount: Int
    public let timeFrameCount: Int
}

public final class MelSpectrogramComputer {
    public let sampleRate: Int
    public let nFFT: Int
    public let hopLength: Int
    public let windowLength: Int
    public let melBinCount: Int

    private let frequencyBinCount: Int
    private let fftHalfCount: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let melFilterbank: [[Float]]
    private let hannWindow: [Float]
    private var ditherState: UInt64 = 0x1234_5678_90AB_CDEF

    public init(
        sampleRate: Int = 16_000,
        nFFT: Int = 512,
        hopLength: Int = 160,
        windowLength: Int = 400,
        melBinCount: Int = 80
    ) {
        self.sampleRate = sampleRate
        self.nFFT = nFFT
        self.hopLength = hopLength
        self.windowLength = windowLength
        self.melBinCount = melBinCount
        self.frequencyBinCount = nFFT / 2 + 1
        self.fftHalfCount = nFFT / 2
        self.log2n = vDSP_Length(log2(Float(nFFT)))
        self.fftSetup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
        self.melFilterbank = Self.createMelFilterbank(
            melBinCount: melBinCount,
            nFFT: nFFT,
            sampleRate: sampleRate,
            minimumFrequency: 0,
            maximumFrequency: Float(sampleRate / 2)
        )
        self.hannWindow = Self.createPeriodicHannWindow(size: windowLength)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    public func compute(samples: [Float], dither: Float = 1e-5, preemphasis: Float = 0.97) -> MelSpectrogram {
        guard samples.count >= windowLength else {
            return MelSpectrogram(features: [], melBinCount: melBinCount, timeFrameCount: 0)
        }

        var audio = [Float](repeating: 0, count: samples.count)
        for index in samples.indices {
            audio[index] = samples[index] + nextDither(amplitude: dither)
        }

        var emphasized = [Float](repeating: 0, count: audio.count)
        emphasized[0] = audio[0]
        if audio.count > 1 {
            for index in 1..<audio.count {
                emphasized[index] = audio[index] - preemphasis * audio[index - 1]
            }
        }

        let frameCount = (emphasized.count - windowLength) / hopLength + 1
        guard frameCount > 0 else {
            return MelSpectrogram(features: [], melBinCount: melBinCount, timeFrameCount: 0)
        }

        var features = [Float](repeating: 0, count: melBinCount * frameCount)
        var realPart = [Float](repeating: 0, count: fftHalfCount)
        var imaginaryPart = [Float](repeating: 0, count: fftHalfCount)
        var frame = [Float](repeating: 0, count: nFFT)
        var power = [Float](repeating: 0, count: frequencyBinCount)

        for frameIndex in 0..<frameCount {
            for index in frame.indices {
                frame[index] = 0
            }

            let start = frameIndex * hopLength
            for sampleIndex in 0..<windowLength {
                frame[sampleIndex] = emphasized[start + sampleIndex] * hannWindow[sampleIndex]
            }

            realPart.withUnsafeMutableBufferPointer { realBuffer in
                imaginaryPart.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(
                        realp: realBuffer.baseAddress!,
                        imagp: imaginaryBuffer.baseAddress!
                    )

                    frame.withUnsafeBufferPointer { frameBuffer in
                        frameBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftHalfCount) { complexPointer in
                            vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(fftHalfCount))
                        }
                    }

                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                    let scale: Float = 1.0 / Float(2 * nFFT)
                    let dc = realBuffer[0] * scale
                    let nyquist = imaginaryBuffer[0] * scale
                    power[0] = dc * dc
                    power[fftHalfCount] = nyquist * nyquist

                    if fftHalfCount > 1 {
                        for bin in 1..<fftHalfCount {
                            let re = realBuffer[bin] * scale
                            let im = imaginaryBuffer[bin] * scale
                            power[bin] = re * re + im * im
                        }
                    }
                }
            }

            for mel in 0..<melBinCount {
                var sum: Float = 0
                vDSP_dotpr(
                    melFilterbank[mel],
                    1,
                    power,
                    1,
                    &sum,
                    vDSP_Length(frequencyBinCount)
                )
                features[mel * frameCount + frameIndex] = log(sum + 1e-5)
            }
        }

        normalizePerFeature(&features, frameCount: frameCount)
        return MelSpectrogram(features: features, melBinCount: melBinCount, timeFrameCount: frameCount)
    }

    private func normalizePerFeature(_ features: inout [Float], frameCount: Int) {
        guard frameCount > 0 else { return }

        for mel in 0..<melBinCount {
            let offset = mel * frameCount
            let range = offset..<(offset + frameCount)
            var mean: Float = 0
            features.withUnsafeBufferPointer { buffer in
                vDSP_meanv(
                    buffer.baseAddress!.advanced(by: offset),
                    1,
                    &mean,
                    vDSP_Length(frameCount)
                )
            }

            var variance: Float = 0
            for index in range {
                let diff = features[index] - mean
                variance += diff * diff
            }
            variance /= Float(frameCount)
            let standardDeviation = max(sqrt(variance), 1e-10)

            for index in range {
                features[index] = (features[index] - mean) / standardDeviation
            }
        }
    }

    private func nextDither(amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        ditherState = 2_862_933_555_777_941_757 &* ditherState &+ 3_037_000_493
        let unit = Float((ditherState >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF)
        return (unit * 2 - 1) * amplitude
    }

    private static func createMelFilterbank(
        melBinCount: Int,
        nFFT: Int,
        sampleRate: Int,
        minimumFrequency: Float,
        maximumFrequency: Float
    ) -> [[Float]] {
        let frequencyBinCount = nFFT / 2 + 1
        let minMel = hzToMel(minimumFrequency)
        let maxMel = hzToMel(maximumFrequency)
        let melPoints = (0..<(melBinCount + 2)).map { index in
            minMel + (Float(index) / Float(melBinCount + 1)) * (maxMel - minMel)
        }
        let hzPoints = melPoints.map(melToHz)
        let fftFrequencies = (0..<frequencyBinCount).map { bin in
            Float(bin) * Float(sampleRate) / Float(nFFT)
        }

        var filterbank = [[Float]](
            repeating: [Float](repeating: 0, count: frequencyBinCount),
            count: melBinCount
        )

        for mel in 0..<melBinCount {
            let left = hzPoints[mel]
            let center = hzPoints[mel + 1]
            let right = hzPoints[mel + 2]
            let slaneyNorm = 2.0 / max(right - left, Float.ulpOfOne)

            for bin in 0..<frequencyBinCount {
                let frequency = fftFrequencies[bin]
                let weight: Float

                if frequency < left || frequency > right {
                    weight = 0
                } else if frequency <= center {
                    weight = (frequency - left) / max(center - left, Float.ulpOfOne)
                } else {
                    weight = (right - frequency) / max(right - center, Float.ulpOfOne)
                }

                filterbank[mel][bin] = max(weight, 0) * slaneyNorm
            }
        }

        return filterbank
    }

    private static func hzToMel(_ hz: Float) -> Float {
        2595.0 * log10(1.0 + hz / 700.0)
    }

    private static func melToHz(_ mel: Float) -> Float {
        700.0 * (pow(10.0, mel / 2595.0) - 1.0)
    }

    private static func createPeriodicHannWindow(size: Int) -> [Float] {
        guard size > 0 else { return [] }
        return (0..<size).map { index in
            0.5 - 0.5 * cos((2.0 * Float.pi * Float(index)) / Float(size))
        }
    }
}
