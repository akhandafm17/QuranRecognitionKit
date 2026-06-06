import Foundation
import OnnxRuntimeBindings

struct CTCLogProbs: Sendable, Equatable {
    let values: [Float]
    let timeSteps: Int
    let vocabularySize: Int
}

public final class ONNXQuranModel: @unchecked Sendable {
    public let modelURL: URL

    private let expectedVocabularySize: Int?
    private let inputAudioName: String
    private let inputLengthName: String
    private let outputLogProbsName: String
    private let intraOpThreadCount: Int

    private var env: ORTEnv?
    private var session: ORTSession?

    public init(
        modelURL: URL,
        expectedVocabularySize: Int? = nil,
        inputAudioName: String = "audio_signal",
        inputLengthName: String = "length",
        outputLogProbsName: String = "logprobs",
        intraOpThreadCount: Int = 2
    ) {
        self.modelURL = modelURL
        self.expectedVocabularySize = expectedVocabularySize
        self.inputAudioName = inputAudioName
        self.inputLengthName = inputLengthName
        self.outputLogProbsName = outputLogProbsName
        self.intraOpThreadCount = intraOpThreadCount
    }

    public static func validateModelFile(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw RecognitionError.modelMissing(url.path)
        }

        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0 else {
            throw RecognitionError.modelCorrupt("File is empty")
        }
    }

    public func prepare() throws {
        guard session == nil else { return }
        try Self.validateModelFile(at: modelURL)

        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(Int32(intraOpThreadCount))

            self.session = try ORTSession(
                env: env,
                modelPath: modelURL.path,
                sessionOptions: options
            )
            self.env = env
        } catch {
            throw RecognitionError.modelCorrupt(error.localizedDescription)
        }
    }

    func run(melSpectrogram: MelSpectrogram) throws -> CTCLogProbs {
        guard let session else {
            throw RecognitionError.notPrepared
        }
        guard melSpectrogram.timeFrameCount > 0 else {
            return CTCLogProbs(values: [], timeSteps: 0, vocabularySize: expectedVocabularySize ?? 0)
        }

        do {
            let audioData = melSpectrogram.features.withUnsafeBufferPointer { buffer in
                NSMutableData(
                    bytes: buffer.baseAddress,
                    length: melSpectrogram.features.count * MemoryLayout<Float>.size
                )
            }

            let audioTensor = try ORTValue(
                tensorData: audioData,
                elementType: .float,
                shape: [
                    1,
                    NSNumber(value: melSpectrogram.melBinCount),
                    NSNumber(value: melSpectrogram.timeFrameCount)
                ]
            )

            var lengthValue = Int64(melSpectrogram.timeFrameCount)
            let lengthData = NSMutableData(bytes: &lengthValue, length: MemoryLayout<Int64>.size)
            let lengthTensor = try ORTValue(
                tensorData: lengthData,
                elementType: .int64,
                shape: [1]
            )

            let outputs = try session.run(
                withInputs: [
                    inputAudioName: audioTensor,
                    inputLengthName: lengthTensor
                ],
                outputNames: Set([outputLogProbsName]),
                runOptions: nil
            )

            guard let output = outputs[outputLogProbsName] else {
                throw RecognitionError.inferenceFailed("Missing output \(outputLogProbsName)")
            }

            let shape = try output.tensorTypeAndShapeInfo().shape.map { $0.intValue }
            guard shape.count == 2 || shape.count == 3 else {
                throw RecognitionError.inferenceFailed("Unexpected output shape \(shape)")
            }

            let timeSteps: Int
            let vocabularySize: Int
            if shape.count == 3 {
                timeSteps = shape[1]
                vocabularySize = shape[2]
            } else {
                timeSteps = shape[0]
                vocabularySize = shape[1]
            }

            if let expectedVocabularySize, expectedVocabularySize != vocabularySize {
                throw RecognitionError.vocabModelMismatch(
                    expected: expectedVocabularySize,
                    actual: vocabularySize
                )
            }

            let data = try output.tensorData() as Data
            let expectedFloatCount = timeSteps * vocabularySize
            let actualFloatCount = data.count / MemoryLayout<Float>.size
            guard actualFloatCount >= expectedFloatCount else {
                throw RecognitionError.inferenceFailed("Output tensor is smaller than expected")
            }

            let floats: [Float] = data.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Float.self).prefix(expectedFloatCount))
            }

            return CTCLogProbs(values: floats, timeSteps: timeSteps, vocabularySize: vocabularySize)
        } catch let error as RecognitionError {
            throw error
        } catch {
            throw RecognitionError.inferenceFailed(error.localizedDescription)
        }
    }
}
