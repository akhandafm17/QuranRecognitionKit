import Foundation

public final class QuranVerseMatchingEngine: @unchecked Sendable {
    public struct VerseEntry: Sendable, Equatable {
        public let surahNumber: Int
        public let verseNumber: Int
        public let arabicText: String
        public let normalizedText: String
        public let surahNameArabic: String
        public let surahNameEnglish: String

        var normalizedWords: [String] {
            normalizedText.split(separator: " ").map(String.init)
        }
    }

    struct VerseMatchCandidate: Sendable, Equatable {
        let surahNumber: Int
        let verseNumber: Int
        let ayahEnd: Int?
        let arabicText: String
        let normalizedText: String
        let score: Double
    }

    public let firstMatchThreshold: Double
    public let subsequentMatchThreshold: Double

    private let verseIndex: [VerseEntry]
    private let verseLookup: [VerseKey: VerseEntry]
    private let surahLookup: [Int: [VerseEntry]]

    public var totalVerses: Int { verseIndex.count }

    public init(
        verses: [VerseEntry],
        firstMatchThreshold: Double = 0.75,
        subsequentMatchThreshold: Double = 0.45
    ) {
        self.verseIndex = verses
        self.firstMatchThreshold = firstMatchThreshold
        self.subsequentMatchThreshold = subsequentMatchThreshold

        var verseLookup: [VerseKey: VerseEntry] = [:]
        verseLookup.reserveCapacity(verses.count)
        var surahLookup: [Int: [VerseEntry]] = [:]

        for verse in verses {
            verseLookup[VerseKey(surah: verse.surahNumber, ayah: verse.verseNumber)] = verse
            surahLookup[verse.surahNumber, default: []].append(verse)
        }

        for surah in surahLookup.keys {
            surahLookup[surah]?.sort { $0.verseNumber < $1.verseNumber }
        }

        self.verseLookup = verseLookup
        self.surahLookup = surahLookup
    }

    public static func loadBundled() throws -> QuranVerseMatchingEngine {
        guard let url = Bundle.module.url(forResource: "quran", withExtension: "json") else {
            throw RecognitionError.resourceMissing("quran.json")
        }
        return try load(from: url)
    }

    public static func load(from url: URL) throws -> QuranVerseMatchingEngine {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RecognitionError.resourceMissing(url.lastPathComponent)
        }

        do {
            let records = try JSONDecoder().decode([QuranVerseRecord].self, from: data)
            let verses = records.map { record in
                VerseEntry(
                    surahNumber: record.surah,
                    verseNumber: record.ayah,
                    arabicText: record.textUthmani,
                    normalizedText: ArabicNormalizer.normalize(record.textClean),
                    surahNameArabic: record.surahName,
                    surahNameEnglish: record.surahNameEnglish
                )
            }
            guard verses.count == 6_236 else {
                throw RecognitionError.resourceCorrupt(url.lastPathComponent)
            }
            return QuranVerseMatchingEngine(verses: verses)
        } catch let error as RecognitionError {
            throw error
        } catch {
            throw RecognitionError.resourceCorrupt(url.lastPathComponent)
        }
    }

    public func getVerse(surah: Int, verse: Int) -> VerseEntry? {
        verseLookup[VerseKey(surah: surah, ayah: verse)]
    }

    public func getSurah(number: Int) -> [VerseEntry] {
        surahLookup[number] ?? []
    }

    func findBestMatch(
        transcription: String,
        currentSurah: Int? = nil,
        currentVerse: Int? = nil,
        surahHint: Int? = nil
    ) -> VerseMatchCandidate? {
        if let surahHint,
           let scoped = findBestMatchInSurah(transcription: transcription, surahNumber: surahHint) {
            return scoped
        }

        return findBestMatch(
            transcription: transcription,
            candidates: verseIndex,
            threshold: currentSurah == nil ? firstMatchThreshold : subsequentMatchThreshold,
            currentSurah: currentSurah,
            currentVerse: currentVerse,
            maxSpan: 3
        )
    }

    func findBestMatchInSurah(transcription: String, surahNumber: Int) -> VerseMatchCandidate? {
        let candidates = surahLookup[surahNumber] ?? []
        guard !candidates.isEmpty else { return nil }
        return findBestMatch(
            transcription: transcription,
            candidates: candidates,
            threshold: firstMatchThreshold,
            currentSurah: nil,
            currentVerse: nil,
            maxSpan: 3
        )
    }

    func findBestMatchScoped(
        transcription: String,
        currentSurah: Int,
        currentVerse: Int
    ) -> VerseMatchCandidate? {
        var scoped: [VerseEntry] = []
        scoped.reserveCapacity(8)

        for offset in -3...3 {
            let verseNumber = currentVerse + offset
            guard verseNumber > 0,
                  let entry = getVerse(surah: currentSurah, verse: verseNumber) else {
                continue
            }
            scoped.append(entry)
        }

        if currentSurah < 114, let firstNextSurah = getVerse(surah: currentSurah + 1, verse: 1) {
            scoped.append(firstNextSurah)
        }

        return findBestMatch(
            transcription: transcription,
            candidates: scoped,
            threshold: subsequentMatchThreshold,
            currentSurah: currentSurah,
            currentVerse: currentVerse,
            maxSpan: 3
        )
    }

    private func findBestMatch(
        transcription: String,
        candidates: [VerseEntry],
        threshold: Double,
        currentSurah: Int?,
        currentVerse: Int?,
        maxSpan: Int
    ) -> VerseMatchCandidate? {
        let normalizedTranscription = ArabicNormalizer.normalize(transcription)
        guard !normalizedTranscription.isEmpty else { return nil }

        var scored: [(entry: VerseEntry, score: Double)] = []
        scored.reserveCapacity(candidates.count)

        for entry in candidates {
            var score = LevenshteinMatcher.ratio(normalizedTranscription, entry.normalizedText)
            if normalizedTranscription.count >= 20, score > 0.25 {
                score = max(score, fragmentScore(transcription: normalizedTranscription, reference: entry.normalizedText))
            }
            score = min(score + continuationBonus(for: entry, currentSurah: currentSurah, currentVerse: currentVerse), 1.0)
            scored.append((entry, score))
        }

        scored.sort { $0.score > $1.score }
        guard let first = scored.first else { return nil }

        var best = VerseMatchCandidate(
            surahNumber: first.entry.surahNumber,
            verseNumber: first.entry.verseNumber,
            ayahEnd: nil,
            arabicText: first.entry.arabicText,
            normalizedText: first.entry.normalizedText,
            score: first.score
        )
        var bestScore = first.score

        if maxSpan > 1 {
            let topCount = min(scored.count, 20)
            for index in 0..<topCount {
                let entry = scored[index].entry
                for spanLength in 2...maxSpan {
                    guard let combined = combineVerses(
                        startSurah: entry.surahNumber,
                        startVerse: entry.verseNumber,
                        count: spanLength
                    ) else { continue }

                    var spanScore = LevenshteinMatcher.ratio(
                        normalizedTranscription,
                        combined.normalizedText
                    )
                    spanScore = max(
                        spanScore,
                        fragmentScore(transcription: normalizedTranscription, reference: combined.normalizedText)
                    )
                    spanScore = min(
                        spanScore + continuationBonus(
                            for: entry,
                            currentSurah: currentSurah,
                            currentVerse: currentVerse
                        ),
                        1.0
                    )

                    if spanScore > bestScore {
                        bestScore = spanScore
                        best = VerseMatchCandidate(
                            surahNumber: entry.surahNumber,
                            verseNumber: entry.verseNumber,
                            ayahEnd: entry.verseNumber + spanLength - 1,
                            arabicText: combined.arabicText,
                            normalizedText: combined.normalizedText,
                            score: spanScore
                        )
                    }
                }
            }
        }

        guard bestScore >= threshold else { return nil }
        return best
    }

    private func continuationBonus(
        for entry: VerseEntry,
        currentSurah: Int?,
        currentVerse: Int?
    ) -> Double {
        guard let currentSurah, let currentVerse else { return 0 }

        if entry.surahNumber == currentSurah {
            switch entry.verseNumber {
            case currentVerse + 1: return 0.22
            case currentVerse + 2: return 0.12
            case currentVerse + 3: return 0.06
            default: return 0
            }
        }

        if entry.surahNumber == currentSurah + 1, entry.verseNumber == 1 {
            return 0.22
        }

        return 0
    }

    private func combineVerses(startSurah: Int, startVerse: Int, count: Int) -> (arabicText: String, normalizedText: String)? {
        var arabicParts: [String] = []
        var normalizedParts: [String] = []
        arabicParts.reserveCapacity(count)
        normalizedParts.reserveCapacity(count)

        for offset in 0..<count {
            guard let entry = getVerse(surah: startSurah, verse: startVerse + offset) else {
                return nil
            }
            arabicParts.append(entry.arabicText)
            normalizedParts.append(entry.normalizedText)
        }

        return (arabicParts.joined(separator: " "), normalizedParts.joined(separator: " "))
    }

    private func fragmentScore(transcription: String, reference: String) -> Double {
        let queryWords = transcription.split(separator: " ")
        let referenceWords = reference.split(separator: " ")
        guard queryWords.count >= 4, referenceWords.count >= 2 else { return 0 }

        let full = LevenshteinMatcher.ratio(transcription, reference)
        let partial = LevenshteinMatcher.partialRatio(transcription, reference)
        guard partial > full else { return full }

        let shorterPenalty = min(1.0, Double(referenceWords.count) / Double(max(queryWords.count, 1)))
        return max(full, (0.25 * full) + (0.75 * partial * shorterPenalty))
    }
}

private struct VerseKey: Hashable {
    let surah: Int
    let ayah: Int
}

private struct QuranVerseRecord: Decodable {
    let surah: Int
    let ayah: Int
    let textUthmani: String
    let textClean: String
    let surahName: String
    let surahNameEnglish: String

    enum CodingKeys: String, CodingKey {
        case surah
        case ayah
        case textUthmani = "text_uthmani"
        case textClean = "text_clean"
        case surahName = "surah_name"
        case surahNameEnglish = "surah_name_en"
    }
}
