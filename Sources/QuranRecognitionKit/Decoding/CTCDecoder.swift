import Foundation

public struct CTCDecoder: Sendable {
    private let vocab: [Int: String]
    private let blankId: Int

    public var vocabularyCount: Int { vocab.count }
    public var blankTokenId: Int { blankId }

    public init(vocab: [Int: String], blankId: Int? = nil) {
        self.vocab = vocab
        if let blankId {
            self.blankId = blankId
        } else if let explicitBlank = vocab.first(where: { $0.value == "<blank>" })?.key {
            self.blankId = explicitBlank
        } else {
            self.blankId = vocab.keys.max() ?? 0
        }
    }

    public static func loadBundled() throws -> CTCDecoder {
        guard let url = Bundle.module.url(forResource: "vocab", withExtension: "json") else {
            throw RecognitionError.resourceMissing("vocab.json")
        }
        return try load(from: url)
    }

    public static func load(from url: URL) throws -> CTCDecoder {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RecognitionError.resourceMissing(url.lastPathComponent)
        }

        do {
            let raw = try JSONDecoder().decode([String: String].self, from: data)
            var vocab: [Int: String] = [:]
            vocab.reserveCapacity(raw.count)
            for (key, value) in raw {
                guard let id = Int(key) else {
                    throw RecognitionError.resourceCorrupt(url.lastPathComponent)
                }
                vocab[id] = value
            }
            return CTCDecoder(vocab: vocab)
        } catch let error as RecognitionError {
            throw error
        } catch {
            throw RecognitionError.resourceCorrupt(url.lastPathComponent)
        }
    }

    public func decode(logProbs: [[Float]]) -> String {
        guard let first = logProbs.first else { return "" }
        var flat = [Float]()
        flat.reserveCapacity(logProbs.count * first.count)
        for row in logProbs {
            flat.append(contentsOf: row)
        }
        return decode(logProbs: flat, timeSteps: logProbs.count, vocabSize: first.count)
    }

    public func decode(logProbs: [Float], timeSteps: Int, vocabSize: Int) -> String {
        guard timeSteps > 0, vocabSize > 0, logProbs.count >= timeSteps * vocabSize else {
            return ""
        }

        var tokenIds: [Int] = []
        tokenIds.reserveCapacity(timeSteps)

        for time in 0..<timeSteps {
            let rowStart = time * vocabSize
            var maxIndex = 0
            var maxValue = logProbs[rowStart]

            for token in 1..<vocabSize {
                let value = logProbs[rowStart + token]
                if value > maxValue {
                    maxValue = value
                    maxIndex = token
                }
            }
            tokenIds.append(maxIndex)
        }

        var collapsed: [Int] = []
        collapsed.reserveCapacity(tokenIds.count)
        var previous = -1
        for id in tokenIds where id != previous {
            if id != blankId {
                collapsed.append(id)
            }
            previous = id
        }

        return detokenize(collapsed)
    }

    private func detokenize(_ tokenIds: [Int]) -> String {
        var result = ""
        for id in tokenIds {
            guard let token = vocab[id], token != "<blank>" else { continue }
            result += token.replacingOccurrences(of: "\u{2581}", with: " ")
        }
        return result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
