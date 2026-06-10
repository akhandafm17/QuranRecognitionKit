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
    private let evidenceLookup: [String: [VerseEntry]]

    public var totalVerses: Int { verseIndex.count }

    public init(
        verses: [VerseEntry],
        firstMatchThreshold: Double = 0.65,
        subsequentMatchThreshold: Double = 0.45
    ) {
        self.verseIndex = verses
        self.firstMatchThreshold = firstMatchThreshold
        self.subsequentMatchThreshold = subsequentMatchThreshold

        var verseLookup: [VerseKey: VerseEntry] = [:]
        verseLookup.reserveCapacity(verses.count)
        var surahLookup: [Int: [VerseEntry]] = [:]
        var evidenceLookup: [String: [VerseEntry]] = [:]

        for verse in verses {
            verseLookup[VerseKey(surah: verse.surahNumber, ayah: verse.verseNumber)] = verse
            surahLookup[verse.surahNumber, default: []].append(verse)
            for word in Self.makeCandidateEvidenceWords(verse.normalizedText) {
                evidenceLookup[word, default: []].append(verse)
            }
        }

        for surah in surahLookup.keys {
            surahLookup[surah]?.sort { $0.verseNumber < $1.verseNumber }
        }

        self.verseLookup = verseLookup
        self.surahLookup = surahLookup
        self.evidenceLookup = evidenceLookup
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
        surahHint: Int? = nil,
        minimumScore: Double? = nil,
        minimumVerseInSurahHint: Int? = nil,
        exhaustiveSpanSearch: Bool = false,
        allowGlobalFallbackFromSurahHint: Bool = true
    ) -> VerseMatchCandidate? {
        if let surahHint {
            let scoped = findBestMatchInSurah(
                transcription: transcription,
                surahNumber: surahHint,
                minimumScore: minimumScore,
                minimumVerse: minimumVerseInSurahHint,
                exhaustiveSpanSearch: exhaustiveSpanSearch
            )
            if let scoped {
                return scoped
            }
            guard allowGlobalFallbackFromSurahHint else { return nil }
        }

        return findBestMatch(
            transcription: transcription,
            candidates: verseIndex,
            threshold: minimumScore ?? (currentSurah == nil ? firstMatchThreshold : subsequentMatchThreshold),
            currentSurah: currentSurah,
            currentVerse: currentVerse,
            maxSpan: 3,
            exhaustiveSpanSearch: exhaustiveSpanSearch
        )
    }

    func findBestMatchInSurah(
        transcription: String,
        surahNumber: Int,
        minimumScore: Double? = nil,
        minimumVerse: Int? = nil,
        maximumVerse: Int? = nil,
        exhaustiveSpanSearch: Bool = false
    ) -> VerseMatchCandidate? {
        let candidates = (surahLookup[surahNumber] ?? []).filter { entry in
            if let minimumVerse, entry.verseNumber < minimumVerse { return false }
            if let maximumVerse, entry.verseNumber > maximumVerse { return false }
            return true
        }
        guard !candidates.isEmpty else { return nil }
        return findBestMatch(
            transcription: transcription,
            candidates: candidates,
            threshold: minimumScore ?? firstMatchThreshold,
            currentSurah: nil,
            currentVerse: nil,
            maxSpan: 3,
            exhaustiveSpanSearch: exhaustiveSpanSearch
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

        if getVerse(surah: currentSurah, verse: currentVerse + 1) == nil,
           currentSurah < 114,
           let firstNextSurah = getVerse(surah: currentSurah + 1, verse: 1) {
            scoped.append(firstNextSurah)
        }

        return findBestMatch(
            transcription: transcription,
            candidates: scoped,
            threshold: subsequentMatchThreshold,
            currentSurah: currentSurah,
            currentVerse: currentVerse,
            maxSpan: 3,
            exhaustiveSpanSearch: false
        )
    }

    func hasAmbiguousAlternative(
        transcription: String,
        candidate: VerseMatchCandidate,
        scoreTolerance: Double = 0.005
    ) -> Bool {
        guard candidate.ayahEnd == nil else { return false }

        let normalizedTranscription = ArabicNormalizer.normalize(transcription)
        guard !normalizedTranscription.isEmpty else { return false }
        let queryWords = candidateEvidenceWords(normalizedTranscription)
        let alternatives = narrowedCandidates(from: verseIndex, queryWords: queryWords)

        for entry in alternatives {
            guard entry.surahNumber != candidate.surahNumber ||
                    entry.verseNumber != candidate.verseNumber else {
                continue
            }

            let score = scoreEntry(
                normalizedTranscription: normalizedTranscription,
                entry: entry,
                currentSurah: nil,
                currentVerse: nil,
                queryWords: queryWords
            )
            if score >= candidate.score - scoreTolerance {
                return true
            }
        }

        return false
    }

    func bestContainedVerse(
        transcription: String,
        in candidate: VerseMatchCandidate
    ) -> VerseMatchCandidate? {
        guard let ayahEnd = candidate.ayahEnd,
              ayahEnd > candidate.verseNumber else {
            return candidate
        }

        let normalizedTranscription = ArabicNormalizer.normalize(transcription)
        guard !normalizedTranscription.isEmpty else { return candidate }

        var bestEntry: VerseEntry?
        var bestScore = 0.0

        for verseNumber in candidate.verseNumber...ayahEnd {
            guard let entry = getVerse(surah: candidate.surahNumber, verse: verseNumber) else {
                continue
            }

            // Resolving among the span's few contained verses must always use
            // fragment scoring for multi-word fragments: the cheap plain
            // ratio is length-biased toward the shortest contained ayah, and
            // the usual scan gates (length, minimum score) don't apply when
            // picking between two or three candidates.
            var score = LevenshteinMatcher.ratio(normalizedTranscription, entry.normalizedText)
            if normalizedTranscription.split(separator: " ").count >= 2 {
                score = max(
                    score,
                    fragmentScore(transcription: normalizedTranscription, reference: entry.normalizedText)
                )
            }
            if score > bestScore {
                bestScore = score
                bestEntry = entry
            }
        }

        guard let bestEntry else { return candidate }
        return VerseMatchCandidate(
            surahNumber: bestEntry.surahNumber,
            verseNumber: bestEntry.verseNumber,
            ayahEnd: nil,
            arabicText: bestEntry.arabicText,
            normalizedText: bestEntry.normalizedText,
            score: max(bestScore, candidate.score)
        )
    }

    private func findBestMatch(
        transcription: String,
        candidates: [VerseEntry],
        threshold: Double,
        currentSurah: Int?,
        currentVerse: Int?,
        maxSpan: Int,
        exhaustiveSpanSearch: Bool
    ) -> VerseMatchCandidate? {
        let normalizedTranscription = ArabicNormalizer.normalize(transcription)
        guard !normalizedTranscription.isEmpty else { return nil }
        let queryWords = candidateEvidenceWords(normalizedTranscription)
        let searchCandidates = narrowedCandidates(
            from: candidates,
            queryWords: queryWords
        )

        var scored: [(entry: VerseEntry, score: Double)] = []
        scored.reserveCapacity(searchCandidates.count)

        for entry in searchCandidates {
            let score = scoreEntry(
                normalizedTranscription: normalizedTranscription,
                entry: entry,
                currentSurah: currentSurah,
                currentVerse: currentVerse,
                queryWords: queryWords
            )
            scored.append((entry, score))
        }

        scored.sort { $0.score > $1.score }
        var best: VerseMatchCandidate?
        var bestScore = 0.0

        if let first = scored.first {
            best = VerseMatchCandidate(
                surahNumber: first.entry.surahNumber,
                verseNumber: first.entry.verseNumber,
                ayahEnd: nil,
                arabicText: first.entry.arabicText,
                normalizedText: first.entry.normalizedText,
                score: first.score
            )
            bestScore = first.score
        }

        let shouldSearchNeighborSpans = exhaustiveSpanSearch ||
            currentSurah != nil ||
            currentVerse != nil ||
            bestScore < 0.72
        if maxSpan > 1, shouldSearchNeighborSpans {
            let topCount = min(scored.count, 20)
            for entry in spanStartEntries(from: scored, topCount: topCount, maxSpan: maxSpan) {
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
                    let shouldUseFullSpanFragment = exhaustiveSpanSearch ||
                        currentSurah != nil ||
                        currentVerse != nil ||
                        candidates.count > 200
                    if shouldUseFullSpanFragment || shouldUseFragmentScore(
                        baseScore: spanScore,
                        normalizedTranscription: normalizedTranscription,
                        queryWords: queryWords,
                        reference: combined.normalizedText
                    ) {
                        spanScore = max(
                            spanScore,
                            fragmentScore(transcription: normalizedTranscription, reference: combined.normalizedText)
                        )
                    }
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

        let shouldSearchOpeningSpans = exhaustiveSpanSearch ||
            (candidates.count > 200 && currentSurah == nil && currentVerse == nil)
        if shouldSearchOpeningSpans,
           bestScore < threshold,
           maxSpan > 1,
           normalizedTranscription.split(separator: " ").count >= 3 {
            for entry in openingSpanStartEntries(from: candidates) {
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

        guard let best, bestScore >= threshold else { return nil }
        return best
    }

    private func scoreEntry(
        normalizedTranscription: String,
        entry: VerseEntry,
        currentSurah: Int?,
        currentVerse: Int?,
        queryWords: Set<String> = []
    ) -> Double {
        var score = LevenshteinMatcher.ratio(normalizedTranscription, entry.normalizedText)
        // Tracking windows can be as short as one second, so scoped queries are
        // often 2-4 word mid-verse fragments. When we already know which verses
        // we are comparing against (tracking mode), allow partial-ratio scoring
        // for much shorter fragments so they match the current verse instead of
        // accumulating tracking misses.
        let scopedQueryWordCount = normalizedTranscription.split(separator: " ").count
        // The cheap pre-gate (plain ratio > 0.2) can never be met by a short
        // window against a long ayah: a 15-char decode against a 200-char
        // Al-Baqarah verse caps out around 0.1 by length alone, so mid-verse
        // windows of long ayahs were structurally unable to match and piled
        // up tracking misses. Allow fragment scoring whenever the reference
        // is much longer than the query — exactly the case where the plain
        // ratio is meaningless.
        let referenceDwarfsQuery = entry.normalizedText.count > normalizedTranscription.count * 3
        let shouldUseScopedFragment = (currentSurah != nil || currentVerse != nil) &&
            scopedQueryWordCount >= 2 &&
            normalizedTranscription.count >= 8 &&
            (score > 0.2 || referenceDwarfsQuery)
        let shouldUseDiscoveryFragment = normalizedTranscription.count >= 20 &&
            score > 0.25 &&
            shouldUseEntryFragmentScore(
                baseScore: score,
                normalizedTranscription: normalizedTranscription,
                queryWords: queryWords,
                reference: entry.normalizedText
            )
        if shouldUseScopedFragment || shouldUseDiscoveryFragment {
            score = max(score, fragmentScore(transcription: normalizedTranscription, reference: entry.normalizedText))
        }
        return min(score + continuationBonus(for: entry, currentSurah: currentSurah, currentVerse: currentVerse), 1.0)
    }

    private func scoreEntryDirect(
        normalizedTranscription: String,
        entry: VerseEntry
    ) -> Double {
        var score = LevenshteinMatcher.ratio(normalizedTranscription, entry.normalizedText)
        // Plain ratios bias short fragments toward shorter ayahs (a fragment of
        // a long ayah's opening can score higher against the short ayah after
        // it). Use partial-ratio scoring for any multi-word fragment so span
        // resolution picks the ayah that actually contains the words. The
        // cheap pre-gate (> 0.15) is structurally unreachable when the
        // reference dwarfs the query (a 15-char window against a 50-word
        // Al-Kahf ayah plain-ratios near 0.07), so allow fragment scoring in
        // that case too — otherwise every guard comparison goes blind on
        // long ayahs.
        let wordCount = normalizedTranscription.split(separator: " ").count
        let referenceDwarfsQuery = entry.normalizedText.count > normalizedTranscription.count * 3
        if wordCount >= 2, normalizedTranscription.count >= 8, score > 0.15 || referenceDwarfsQuery {
            score = max(score, fragmentScore(transcription: normalizedTranscription, reference: entry.normalizedText))
        }
        return min(score, 1.0)
    }

    /// Scores a transcription directly against one specific verse, without
    /// continuation bonuses. Used by the tracker to check whether the current
    /// ayah explains a window at least as well as a proposed continuation.
    /// Unlike span resolution, guard comparisons also fragment-score very
    /// short two-word decodes like "ان يعلم" (7 chars), because the plain
    /// ratio fallback wrongly favors shorter forward ayahs for them.
    func directVerseScore(transcription: String, surah: Int, verse: Int) -> Double {
        guard let entry = getVerse(surah: surah, verse: verse) else { return 0 }
        let normalized = ArabicNormalizer.normalize(transcription)
        guard !normalized.isEmpty else { return 0 }
        var score = scoreEntryDirect(normalizedTranscription: normalized, entry: entry)
        let wordCount = normalized.split(separator: " ").count
        if wordCount >= 2, normalized.count >= 6, normalized.count < 8, score > 0.15 {
            score = max(score, fragmentScore(transcription: normalized, reference: entry.normalizedText))
        }
        return min(score, 1.0)
    }

    private func spanStartEntries(
        from scored: [(entry: VerseEntry, score: Double)],
        topCount: Int,
        maxSpan: Int
    ) -> [VerseEntry] {
        var entries: [VerseEntry] = []
        var seen = Set<VerseKey>()

        for index in 0..<topCount {
            let entry = scored[index].entry
            for backtrack in 0..<maxSpan {
                let verseNumber = entry.verseNumber - backtrack
                guard verseNumber > 0,
                      let startEntry = getVerse(surah: entry.surahNumber, verse: verseNumber) else {
                    continue
                }
                let key = VerseKey(surah: startEntry.surahNumber, ayah: startEntry.verseNumber)
                if seen.insert(key).inserted {
                    entries.append(startEntry)
                }
            }
        }

        return entries
    }

    private func openingSpanStartEntries(from candidates: [VerseEntry]) -> [VerseEntry] {
        var entries: [VerseEntry] = []
        var seenSurahs = Set<Int>()

        for entry in candidates where seenSurahs.insert(entry.surahNumber).inserted {
            if let firstVerse = getVerse(surah: entry.surahNumber, verse: 1) {
                entries.append(firstVerse)
            }
        }

        return entries
    }

    private func narrowedCandidates(from candidates: [VerseEntry], queryWords: Set<String>) -> [VerseEntry] {
        guard candidates.count > 24, queryWords.count >= 2 else {
            return candidates
        }

        var narrowed: [VerseEntry] = []
        narrowed.reserveCapacity(min(candidates.count, 64))
        let candidateKeys = Set(candidates.map { VerseKey(surah: $0.surahNumber, ayah: $0.verseNumber) })
        var seen = Set<VerseKey>()

        for word in queryWords {
            guard let entries = evidenceLookup[word] else { continue }
            for entry in entries {
                let key = VerseKey(surah: entry.surahNumber, ayah: entry.verseNumber)
                guard candidateKeys.contains(key), seen.insert(key).inserted else {
                    continue
                }
                narrowed.append(entry)
            }
        }

        if narrowed.isEmpty, candidates.count <= 200 {
            narrowed = candidates.filter {
                hasCandidateWordEvidence(queryWords: queryWords, reference: $0.normalizedText)
            }
        }

        return narrowed.isEmpty ? candidates : narrowed
    }

    private func shouldUseFragmentScore(
        baseScore: Double,
        normalizedTranscription: String,
        queryWords: Set<String>,
        reference: String
    ) -> Bool {
        guard normalizedTranscription.split(separator: " ").count >= 3 else { return false }
        if baseScore >= 0.34 {
            return true
        }
        guard queryWords.count >= 2 else { return false }
        return hasCandidateWordEvidence(queryWords: queryWords, reference: reference)
    }

    private func shouldUseEntryFragmentScore(
        baseScore: Double,
        normalizedTranscription: String,
        queryWords: Set<String>,
        reference: String
    ) -> Bool {
        guard normalizedTranscription.split(separator: " ").count >= 3 else { return false }
        if baseScore >= 0.45 {
            return true
        }
        return candidateWordEvidenceHitCount(queryWords: queryWords, reference: reference) >= 2
    }

    private func candidateEvidenceWords(_ normalizedText: String) -> Set<String> {
        Self.makeCandidateEvidenceWords(normalizedText)
    }

    private static func makeCandidateEvidenceWords(_ normalizedText: String) -> Set<String> {
        let stopWords: Set<String> = [
            "هذا", "هذه", "ذلك", "تلك", "الذي", "الذين", "التي",
            "وما", "وهو", "وهي", "ومن", "وفي", "وال", "على", "علي",
            "الى", "الي", "في", "من", "ما", "لا", "لم", "لن", "ان"
        ]

        return Set(
            normalizedText
                .split(separator: " ")
                .map(String.init)
                .filter { word in
                    word.count >= 4 && !stopWords.contains(word)
                }
                .map(Self.evidenceStem)
                .filter { $0.count >= 3 }
        )
    }

    private func hasCandidateWordEvidence(queryWords: Set<String>, reference: String) -> Bool {
        candidateWordEvidenceHitCount(queryWords: queryWords, reference: reference) > 0
    }

    private func candidateWordEvidenceHitCount(queryWords: Set<String>, reference: String) -> Int {
        guard !queryWords.isEmpty else { return 0 }
        var remainingQueryWords = queryWords

        for rawReferenceWord in reference.split(separator: " ").map(String.init) where rawReferenceWord.count >= 4 {
            let referenceWord = Self.evidenceStem(rawReferenceWord)
            guard referenceWord.count >= 3 else { continue }
            if remainingQueryWords.remove(referenceWord) != nil {
                if remainingQueryWords.isEmpty {
                    break
                }
                continue
            }

            for queryWord in Array(remainingQueryWords) {
                let fullScore = LevenshteinMatcher.ratio(queryWord, referenceWord)
                if fullScore >= 0.72 {
                    remainingQueryWords.remove(queryWord)
                    break
                }
            }
        }

        return queryWords.count - remainingQueryWords.count
    }

    private static func evidenceStem(_ word: String) -> String {
        var result = word

        if result.hasPrefix("وال"), result.count > 4 {
            result.removeFirst(3)
        } else if result.hasPrefix("فال"), result.count > 4 {
            result.removeFirst(3)
        } else if result.hasPrefix("ال"), result.count > 3 {
            result.removeFirst(2)
        } else if let first = result.first,
                  ["و", "ف", "ب", "ل", "ي", "ت", "ن"].contains(first),
                  result.count > 4 {
            result.removeFirst()
        }

        for suffix in ["ين", "ون", "ان", "وا", "هم", "كم", "نا", "ها", "ه"] {
            if result.hasSuffix(suffix), result.count - suffix.count >= 3 {
                result.removeLast(suffix.count)
                break
            }
        }

        return result
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
            default: return 0
            }
        }

        if entry.surahNumber == currentSurah + 1,
           entry.verseNumber == 1,
           getVerse(surah: currentSurah, verse: currentVerse + 1) == nil {
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
        guard queryWords.count >= 2, referenceWords.count >= 2 else { return 0 }

        let full = LevenshteinMatcher.ratio(transcription, reference)
        // Partial-ratio sliding exists for SHORT fragments inside longer
        // references. When both sides are long (e.g. a full-verse discovery
        // window against a multi-ayah span) it costs O(slides * n^2) and a
        // long query is no longer a "fragment" — the plain ratio is the
        // right measure. Without this cap, global discovery of a long ayah
        // like 2:255 spends minutes inside partialRatio.
        guard min(transcription.count, reference.count) <= 100 else { return full }
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
