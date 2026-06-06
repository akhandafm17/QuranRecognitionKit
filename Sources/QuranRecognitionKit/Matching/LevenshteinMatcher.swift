import Foundation

public enum LevenshteinMatcher {
    public static func distance(_ first: String, _ second: String) -> Int {
        let a = Array(first)
        let b = Array(second)
        let m = a.count
        let n = b.count

        if m == 0 { return n }
        if n == 0 { return m }

        var previous = Array(0...n)
        var current = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            current[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        return previous[n]
    }

    public static func ratio(_ first: String, _ second: String) -> Double {
        if first.isEmpty && second.isEmpty { return 1.0 }
        let maxLength = max(first.count, second.count)
        guard maxLength > 0 else { return 1.0 }
        return 1.0 - (Double(distance(first, second)) / Double(maxLength))
    }

    public static func partialRatio(_ shortText: String, _ longText: String) -> Double {
        if shortText.isEmpty || longText.isEmpty { return 0 }

        var short = shortText
        var long = longText
        if short.count > long.count {
            swap(&short, &long)
        }

        let window = short.count
        guard window > 0 else { return 0 }

        let longChars = Array(long)
        var best = 0.0
        let maxStart = max(0, longChars.count - window)
        for start in 0...maxStart {
            let slice = String(longChars[start..<(start + window)])
            best = max(best, ratio(short, slice))
            if best == 1.0 { break }
        }
        return best
    }

    public static func wordAlignment(
        transcription: String,
        reference: String,
        wordThreshold: Double = 0.7
    ) -> (matched: Int, total: Int) {
        let transcribedWords = ArabicNormalizer.words(transcription)
        let referenceWords = ArabicNormalizer.words(reference)

        if referenceWords.isEmpty { return (0, 0) }
        if transcribedWords.isEmpty { return (0, referenceWords.count) }

        var matched = 0
        var transcriptionIndex = 0

        for referenceWord in referenceWords {
            let searchEnd = min(transcriptionIndex + 3, transcribedWords.count)
            guard transcriptionIndex < searchEnd else { break }

            var bestScore = 0.0
            var bestIndex = -1

            for index in transcriptionIndex..<searchEnd {
                let score = ratio(transcribedWords[index], referenceWord)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }

            if bestScore >= wordThreshold && bestIndex >= 0 {
                matched += 1
                transcriptionIndex = bestIndex + 1
            }
        }

        return (matched, referenceWords.count)
    }
}
