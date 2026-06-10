import Foundation

enum TrackingMode: Sendable, Equatable {
    case discovery
    case tracking
}

private enum LowConfidenceContinuationDecision {
    case accepted(RecognizedVerse)
    case pending
    case rejected
}

final class RecitationTracker: @unchecked Sendable {
    private let matchingEngine: QuranVerseMatchingEngine
    private let debugLogging: Bool

    private(set) var mode: TrackingMode = .discovery
    private(set) var currentSurah: Int?
    private(set) var currentVerse: Int?
    private(set) var wordsCovered: Int = 0
    private(set) var totalWordsInVerse: Int = 0

    var surahHint: Int?

    private var pendingSurah: Int?
    private var pendingVerse: Int?
    private var consecutiveCount = 0
    private var pendingLowConfidenceSurah: Int?
    private var pendingLowConfidenceVerse: Int?
    private var consecutiveLowConfidenceContinuationCount = 0
    private var missedTrackingCount = 0
    private var lowInformationTrackingCount = 0
    private var completedSurahBeforeDiscovery: Int?
    private var recoverySurah: Int?
    private var recoveryMinimumVerse: Int?
    /// Caches the last far recovery candidate rejected by the (expensive)
    /// distinctiveness check, so persisting audio does not re-pay the
    /// whole-mushaf ambiguity scan on every overlapping window.
    private var lastRejectedFarRecovery: (surah: Int, verse: Int, score: Double)?

    private let requiredConsecutiveDiscovery = 2
    private let requiredConsecutiveJump = 2
    private let hintedDiscoveryThreshold = 0.58
    private let hintedImmediateDiscoveryThreshold = 0.60
    /// During recovery the reciter realistically advances only a few ayahs
    /// past the loss point; commits further ahead need distinctive evidence.
    private let maximumImmediateRecoveryAdvance = 6
    private let farRecoveryScoreThreshold = 0.75
    private let farRecoveryAmbiguityTolerance = 0.08
    /// Weak-evidence advances (noisy continuation, forward-span fallback)
    /// must be backed by a bonus-free direct score against the forward ayah
    /// of at least this much. Below it, the window is garbage that happens to
    /// rank candidates by chance (Al-Baqarah replay: garbage windows scored
    /// 0.25-0.30 against everything and still advanced on relative margins).
    private let weakAdvanceDirectScoreFloor = 0.32
    private let postCompletionDiscoveryThreshold = 0.60
    private let postCompletionOpeningImmediateThreshold = 0.80
    private let immediateDiscoveryThreshold = 0.85
    private let immediateContinuationThreshold = 0.55
    private let probableImmediateContinuationThreshold = 0.60
    private let probableSpanContinuationThreshold = 0.54
    private let trackingGlobalSwitchThreshold = 0.82
    private let trackingGlobalSwitchMargin = 0.18
    private let lowConfidenceShortVerseContinuationThreshold = 0.45
    private let requiredLowConfidenceShortVerseContinuations = 2
    private let maximumWordsForLowConfidenceShortVerse = 2
    private let minimumLowConfidenceContinuationCharacters = 4
    private let autoAdvanceCoverage = 0.80
    private let jumpThreshold = 0.85
    private let maximumMissedTrackingCount = 4
    private let maximumMissedTrackingCountAfterCompletedSurah = 2
    private let maximumLowInformationTrackingCountNearSurahEnd = 6

    init(matchingEngine: QuranVerseMatchingEngine, surahHint: Int? = nil, debugLogging: Bool = false) {
        self.matchingEngine = matchingEngine
        self.surahHint = surahHint
        self.debugLogging = debugLogging
    }

    func reset() {
        mode = .discovery
        currentSurah = nil
        currentVerse = nil
        wordsCovered = 0
        totalWordsInVerse = 0
        pendingSurah = nil
        pendingVerse = nil
        consecutiveCount = 0
        resetLowConfidenceContinuation()
        missedTrackingCount = 0
        lowInformationTrackingCount = 0
        completedSurahBeforeDiscovery = nil
        recoverySurah = nil
        lastRejectedFarRecovery = nil
        recoveryMinimumVerse = nil
        surahHint = nil
    }

    func processTranscription(_ transcription: String) -> RecognizedVerse? {
        debugLog("process mode=\(mode) hint=\(surahHint.map(String.init) ?? "nil") completedSurah=\(completedSurahBeforeDiscovery.map(String.init) ?? "nil") text='\(transcription)'")
        let match: QuranVerseMatchingEngine.VerseMatchCandidate?

        switch mode {
        case .discovery:
            guard hasUsefulDiscoveryContent(transcription) else {
                debugLog("skipping low-information discovery transcription")
                return nil
            }
            match = nearRecoveryMatch(transcription: transcription) ?? matchingEngine.findBestMatch(
                transcription: transcription,
                currentSurah: currentSurah,
                currentVerse: currentVerse,
                surahHint: surahHint,
                minimumScore: discoveryAcceptanceThreshold,
                minimumVerseInSurahHint: minimumVerseInSurahHint,
                exhaustiveSpanSearch: shouldUseExhaustiveSpanSearch,
                allowGlobalFallbackFromSurahHint: shouldAllowGlobalDiscoveryFallback
            )
        case .tracking:
            if let currentSurah, let currentVerse {
                let scopedMatch = matchingEngine.findBestMatchScoped(
                    transcription: transcription,
                    currentSurah: currentSurah,
                    currentVerse: currentVerse
                )
                if let globalSwitch = trackingGlobalSwitchCandidate(
                    transcription: transcription,
                    scopedMatch: scopedMatch,
                    currentSurah: currentSurah,
                    currentVerse: currentVerse
                ) {
                    debugLog(
                        "global switch candidate \(globalSwitch.surahNumber):\(globalSwitch.verseNumber) score=\(String(format: "%.3f", globalSwitch.score)) scoped=\(scopedMatch.map { "\($0.surahNumber):\($0.verseNumber) \($0.score)" } ?? "nil")"
                    )
                    return handleTrackingGlobalSwitch(globalSwitch)
                }
                match = scopedMatch
            } else {
                match = matchingEngine.findBestMatch(transcription: transcription)
            }
        }

        switch mode {
        case .discovery:
            guard let match else {
                debugLog("no candidate matched")
                return nil
            }
            let effectiveMatch = resolveDiscoveryMatch(match, transcription: transcription)
            debugLog(
                "candidate \(match.surahNumber):\(match.verseNumber) score=\(String(format: "%.3f", match.score)) ayahEnd=\(match.ayahEnd.map(String.init) ?? "nil")"
            )
            return handleDiscoveryMatch(effectiveMatch, transcription: transcription)
        case .tracking:
            guard let match else {
                if let advancedVerse = advanceAfterCurrentVerseEnding(transcription: transcription) {
                    return advancedVerse
                }
                debugLog("no scoped candidate matched")
                return handleTrackingMiss(transcription: transcription)
            }
            debugLog(
                "candidate \(match.surahNumber):\(match.verseNumber) score=\(String(format: "%.3f", match.score)) ayahEnd=\(match.ayahEnd.map(String.init) ?? "nil")"
            )
            return handleTrackingMatch(match, transcription: transcription)
        }
    }

    private func handleDiscoveryMatch(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> RecognizedVerse? {
        guard shouldAcceptRecoveryMatch(match, transcription: transcription) else {
            pendingSurah = nil
            pendingVerse = nil
            consecutiveCount = 0
            debugLog(
                "rejecting stale recovery candidate \(match.surahNumber):\(match.verseNumber) below minimum \(recoveryMinimumVerse ?? 0)"
            )
            return nil
        }

        let match = recoveryAdjustedMatch(match)

        // A recovery commit far ahead of the loss point is almost always a
        // generic phrase artifact: long surahs repeat phrases ("اولئك هم
        // المفلحون", "ان الله سميع عليم", ...) that score highly against
        // verses hundreds of ayahs away. The reciter is near the loss point,
        // so a far commit needs distinctive, unambiguous evidence.
        if let recoverySurah,
           let recoveryMinimumVerse,
           match.surahNumber == recoverySurah,
           match.verseNumber > recoveryMinimumVerse + maximumImmediateRecoveryAdvance {
            if let rejected = lastRejectedFarRecovery,
               rejected.surah == match.surahNumber,
               rejected.verse == match.verseNumber,
               match.score <= rejected.score + 0.02 {
                pendingSurah = nil
                pendingVerse = nil
                consecutiveCount = 0
                debugLog(
                    "rejecting previously rejected far recovery candidate \(match.surahNumber):\(match.verseNumber)"
                )
                return nil
            }
            guard isDistinctiveFarRecoveryCandidate(match, transcription: transcription) else {
                lastRejectedFarRecovery = (match.surahNumber, match.verseNumber, match.score)
                pendingSurah = nil
                pendingVerse = nil
                consecutiveCount = 0
                debugLog(
                    "rejecting far recovery candidate \(match.surahNumber):\(match.verseNumber) — generic or ambiguous evidence while recovering near \(recoverySurah):\(recoveryMinimumVerse)"
                )
                return nil
            }
        }

        let threshold = discoveryAcceptanceThreshold
        guard match.score >= threshold else {
            pendingSurah = nil
            pendingVerse = nil
            consecutiveCount = 0
            return nil
        }

        if match.surahNumber == pendingSurah && match.verseNumber == pendingVerse {
            consecutiveCount += 1
        } else {
            pendingSurah = match.surahNumber
            pendingVerse = match.verseNumber
            consecutiveCount = 1
        }

        debugLog("discovery pending \(match.surahNumber):\(match.verseNumber) consecutive=\(consecutiveCount)/\(requiredConsecutiveDiscovery)")

        if isGenericPostCompletionOpening(match, transcription: transcription) {
            debugLog("post-completion opening is generic bismillah, waiting for clearer evidence")
            return nil
        }

        if isAmbiguousPostCompletionSwitch(match, transcription: transcription) {
            debugLog("post-completion candidate is ambiguous, waiting for clearer evidence")
            return nil
        }

        let isImmediateHighConfidence = match.score >= immediateDiscoveryThreshold
        let isImmediateHintedSurah = surahHint == match.surahNumber &&
            match.score >= hintedImmediateDiscoveryThreshold
        let isImmediatePostCompletionSurahSwitch = shouldCommitPostCompletionSwitch(match)
        guard consecutiveCount >= requiredConsecutiveDiscovery ||
                isImmediateHighConfidence ||
                isImmediateHintedSurah ||
                isImmediatePostCompletionSurahSwitch else {
            return nil
        }
        if consecutiveCount < requiredConsecutiveDiscovery {
            if isImmediateHighConfidence {
                debugLog("high-confidence discovery commit without second confirmation")
            } else if isImmediateHintedSurah {
                debugLog("hinted-surah discovery commit without second confirmation")
            } else if isImmediatePostCompletionSurahSwitch {
                debugLog("post-completion surah switch commit without second confirmation")
            }
        }

        currentSurah = match.surahNumber
        currentVerse = match.verseNumber
        pendingSurah = nil
        pendingVerse = nil
        consecutiveCount = 0
        resetLowConfidenceContinuation()
        missedTrackingCount = 0
        lowInformationTrackingCount = 0
        surahHint = nil
        completedSurahBeforeDiscovery = nil
        recoverySurah = nil
        lastRejectedFarRecovery = nil
        recoveryMinimumVerse = nil
        wordsCovered = 0
        totalWordsInVerse = matchingEngine
            .getVerse(surah: match.surahNumber, verse: match.verseNumber)?
            .normalizedWords
            .count ?? 0
        mode = .tracking
        debugLog("discovery committed \(match.surahNumber):\(match.verseNumber), switching to tracking")

        return recognizedVerse(from: match)
    }

    private var discoveryAcceptanceThreshold: Double {
        if surahHint != nil {
            return hintedDiscoveryThreshold
        }
        if completedSurahBeforeDiscovery != nil {
            return postCompletionDiscoveryThreshold
        }
        return matchingEngine.firstMatchThreshold
    }

    private var shouldUseExhaustiveSpanSearch: Bool {
        completedSurahBeforeDiscovery != nil
    }

    private var shouldAllowGlobalDiscoveryFallback: Bool {
        surahHint == nil || completedSurahBeforeDiscovery != nil
    }

    private var minimumVerseInSurahHint: Int? {
        guard surahHint == recoverySurah else { return nil }
        return recoveryMinimumVerse
    }

    /// During recovery, the reciter is almost certainly within a few ayahs
    /// of the loss point. Search that window first: it is both the right
    /// locality prior and far cheaper than scanning the whole surah (and the
    /// far-candidate ambiguity scan) on every discovery window.
    private func nearRecoveryMatch(
        transcription: String
    ) -> QuranVerseMatchingEngine.VerseMatchCandidate? {
        guard let recoverySurah,
              let recoveryMinimumVerse,
              surahHint == recoverySurah else {
            return nil
        }
        return matchingEngine.findBestMatchInSurah(
            transcription: transcription,
            surahNumber: recoverySurah,
            minimumScore: discoveryAcceptanceThreshold,
            minimumVerse: recoveryMinimumVerse,
            maximumVerse: recoveryMinimumVerse + maximumImmediateRecoveryAdvance,
            exhaustiveSpanSearch: false
        )
    }

    private func shouldAcceptRecoveryMatch(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> Bool {
        guard let recoverySurah,
              let recoveryMinimumVerse else {
            return true
        }

        guard match.surahNumber == recoverySurah else {
            return isReliableCrossSurahSwitch(
                match,
                transcription: transcription,
                minimumScore: trackingGlobalSwitchThreshold
            )
        }

        // Recovery audio frequently spans the tail of the previous ayah and the
        // start of the ayah we lost (e.g. span 1-2 while recovering at verse 2).
        // Accept the candidate when any part of the span reaches the minimum;
        // recoveryAdjustedMatch then commits at the minimum verse.
        return (match.ayahEnd ?? match.verseNumber) >= recoveryMinimumVerse
    }

    /// A far recovery candidate is only trustworthy when the window carries
    /// enough words to be specific, scores strongly, and no other verse in
    /// the mushaf explains the window nearly as well. Generic repeated
    /// phrases fail the ambiguity check because they match many verses.
    private func isDistinctiveFarRecoveryCandidate(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> Bool {
        guard ArabicNormalizer.words(transcription).count >= 4,
              match.score >= farRecoveryScoreThreshold else {
            return false
        }
        // hasAmbiguousAlternative skips span candidates, so check the span's
        // anchor verse instead of letting far spans through unexamined.
        let anchor = QuranVerseMatchingEngine.VerseMatchCandidate(
            surahNumber: match.surahNumber,
            verseNumber: match.verseNumber,
            ayahEnd: nil,
            arabicText: match.arabicText,
            normalizedText: match.normalizedText,
            score: match.score
        )
        return !matchingEngine.hasAmbiguousAlternative(
            transcription: transcription,
            candidate: anchor,
            scoreTolerance: farRecoveryAmbiguityTolerance
        )
    }

    private func recoveryAdjustedMatch(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate
    ) -> QuranVerseMatchingEngine.VerseMatchCandidate {
        guard let recoverySurah,
              let recoveryMinimumVerse,
              match.surahNumber == recoverySurah,
              match.verseNumber < recoveryMinimumVerse,
              let spanEnd = match.ayahEnd,
              spanEnd >= recoveryMinimumVerse,
              let entry = matchingEngine.getVerse(surah: recoverySurah, verse: recoveryMinimumVerse) else {
            return match
        }

        debugLog(
            "clamping recovery span \(match.surahNumber):\(match.verseNumber)-\(spanEnd) to minimum verse \(recoveryMinimumVerse)"
        )
        return QuranVerseMatchingEngine.VerseMatchCandidate(
            surahNumber: entry.surahNumber,
            verseNumber: entry.verseNumber,
            ayahEnd: nil,
            arabicText: entry.arabicText,
            normalizedText: entry.normalizedText,
            score: match.score
        )
    }

    private func shouldCommitPostCompletionSwitch(_ match: QuranVerseMatchingEngine.VerseMatchCandidate) -> Bool {
        guard let completedSurahBeforeDiscovery,
              match.surahNumber != completedSurahBeforeDiscovery else {
            return false
        }

        if match.verseNumber > 1 {
            return match.score >= postCompletionDiscoveryThreshold
        }

        if match.ayahEnd != nil {
            return match.score >= postCompletionDiscoveryThreshold
        }

        return match.score >= postCompletionOpeningImmediateThreshold
    }

    private func isAmbiguousPostCompletionSwitch(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> Bool {
        guard let completedSurahBeforeDiscovery,
              match.surahNumber != completedSurahBeforeDiscovery else {
            return false
        }

        if match.ayahEnd != nil, match.verseNumber > 1 {
            return distinctivePostCompletionHitCount(
                referenceText: match.normalizedText,
                transcription: transcription
            ) < 1
        }

        return matchingEngine.hasAmbiguousAlternative(
            transcription: transcription,
            candidate: match
        )
    }

    private func isGenericPostCompletionOpening(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> Bool {
        guard let completedSurahBeforeDiscovery,
              match.surahNumber != completedSurahBeforeDiscovery,
              match.verseNumber == 1 else {
            return false
        }

        let bismillahStems: Set<String> = ["بسم", "اسم", "الله", "رحمن", "رحيم"]
        let contentStems = ArabicNormalizer.words(transcription)
            .map(evidenceStem)
            .filter { $0.count >= 3 && !bismillahStems.contains($0) }

        return contentStems.isEmpty
    }

    private func handleTrackingMatch(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> RecognizedVerse? {
        guard let currentSurah, let currentVerse else {
            mode = .discovery
            return nil
        }

        if let advancedVerse = advanceAfterCurrentVerseEnding(transcription: transcription) {
            return advancedVerse
        }

        if let spanEnd = match.ayahEnd,
           match.surahNumber == currentSurah,
           match.verseNumber <= currentVerse,
           spanEnd > currentVerse,
           let nextEntry = matchingEngine.getVerse(surah: currentSurah, verse: currentVerse + 1) {
            if hasVerseWordEvidence(entry: nextEntry, transcription: transcription) {
                debugLog("span continuation \(match.verseNumber)-\(spanEnd), advancing to \(nextEntry.surahNumber):\(nextEntry.verseNumber)")
                return advance(to: nextEntry, confidence: match.score)
            }
            debugLog("span continuation \(match.verseNumber)-\(spanEnd) rejected without next-ayah word evidence")
        }

        let effectiveMatch = resolveTrackingSpan(match, transcription: transcription)

        if effectiveMatch.surahNumber == currentSurah && effectiveMatch.verseNumber == currentVerse {
            let autoAdvancedVerse = updateWordCoverage(transcription: transcription, surah: currentSurah, verse: currentVerse)
            pendingSurah = nil
            pendingVerse = nil
            consecutiveCount = 0
            resetLowConfidenceContinuation()
            missedTrackingCount = 0
            lowInformationTrackingCount = 0
            if let autoAdvancedVerse {
                return autoAdvancedVerse
            }
            debugLog("same verse \(currentSurah):\(currentVerse), words=\(wordsCovered)/\(totalWordsInVerse)")
            return nil
        }

        if effectiveMatch.surahNumber == currentSurah && effectiveMatch.verseNumber < currentVerse {
            pendingSurah = nil
            pendingVerse = nil
            consecutiveCount = 0
            resetLowConfidenceContinuation()
            missedTrackingCount = 0
            lowInformationTrackingCount = 0
            debugLog("ignoring stale previous verse \(effectiveMatch.surahNumber):\(effectiveMatch.verseNumber) while tracking \(currentSurah):\(currentVerse)")
            return nil
        }

        if isResolvedForwardSpanContinuation(
            originalMatch: match,
            resolvedMatch: effectiveMatch,
            currentSurah: currentSurah,
            currentVerse: currentVerse
        ) {
            let isImmediateMatch = isImmediateContinuation(
                effectiveMatch,
                currentSurah: currentSurah,
                currentVerse: currentVerse
            )
            guard isImmediateMatch || isHighConfidenceSameSurahForwardJump(
                effectiveMatch,
                currentSurah: currentSurah,
                currentVerse: currentVerse,
                transcription: transcription
            ) else {
                // A span anchored at the current or next ayah is still solid
                // sequential evidence even when the noisy fragment resolves
                // deeper into the span (resolution can be wrong on short
                // decodes). Cue exactly one ayah forward instead of counting
                // a miss — unless the current ayah explains the window just
                // as well, which means the reciter has not moved yet.
                let currentVerseScore = matchingEngine.directVerseScore(
                    transcription: transcription,
                    surah: currentSurah,
                    verse: currentVerse
                )
                // Span scores carry continuation bonuses, so judge forward
                // movement on bonus-free direct scores against the next ayah
                // and the resolved ayah instead of the inflated span score.
                let forwardVerseScore = max(
                    matchingEngine.directVerseScore(
                        transcription: transcription,
                        surah: currentSurah,
                        verse: currentVerse + 1
                    ),
                    matchingEngine.directVerseScore(
                        transcription: transcription,
                        surah: effectiveMatch.surahNumber,
                        verse: effectiveMatch.verseNumber
                    )
                )
                let cuedVerseText = matchingEngine
                    .getVerse(surah: currentSurah, verse: currentVerse + 1)?
                    .normalizedText ?? ""
                let currentVerseText = matchingEngine
                    .getVerse(surah: currentSurah, verse: currentVerse)?
                    .normalizedText ?? ""
                // The forward ayah must clearly explain the window better
                // than the current one (margin), or the window must carry a
                // word that belongs to the cued ayah and not the current one.
                let hasMargin = currentVerseScore + 0.05 < forwardVerseScore
                let hasDistinctWord = !cuedVerseText.isEmpty && hasDistinctTargetWordEvidence(
                    transcription: transcription,
                    targetText: cuedVerseText,
                    currentText: currentVerseText
                )
                if match.verseNumber <= currentVerse + 1,
                   effectiveMatch.score >= probableSpanContinuationThreshold,
                   hasUsefulContinuationContent(transcription),
                   forwardVerseScore >= weakAdvanceDirectScoreFloor,
                   hasMargin || hasDistinctWord,
                   !isStalePreviousAyahAudio(
                       transcription: transcription,
                       currentSurah: currentSurah,
                       currentVerse: currentVerse,
                       forwardScore: forwardVerseScore,
                       targetText: cuedVerseText
                   ),
                   !hasStrongerCrossSurahAlternative(transcription: transcription, localMatch: effectiveMatch) {
                    resetLowConfidenceContinuation()
                    return advanceOneAyahToward(
                        effectiveMatch,
                        currentSurah: currentSurah,
                        currentVerse: currentVerse,
                        reason: "forward span anchored at next ayah"
                    )
                }
                debugLog(
                    "resolved span continuation rejected multi-ayah target \(effectiveMatch.surahNumber):\(effectiveMatch.verseNumber) score=\(String(format: "%.3f", effectiveMatch.score))"
                )
                return handleTrackingMiss(transcription: transcription)
            }

            if !isImmediateMatch {
                resetLowConfidenceContinuation()
                return advanceOneAyahToward(
                    effectiveMatch,
                    currentSurah: currentSurah,
                    currentVerse: currentVerse,
                    reason: "resolved span forward evidence"
                )
            }

            let hasWordEvidence = hasContinuationWordEvidence(match: effectiveMatch, transcription: transcription)
            let hasStrongSingleEvidence = hasStrongSingleContinuationEvidence(
                referenceText: effectiveMatch.normalizedText,
                transcription: transcription
            )
            let primaryAccepted = effectiveMatch.score >= immediateContinuationThreshold &&
                (hasWordEvidence || hasStrongSingleEvidence)
            let accepted = primaryAccepted || shouldAcceptNoisySequentialContinuationIfNeeded(
                primaryAccepted: primaryAccepted,
                match: effectiveMatch,
                transcription: transcription,
                threshold: probableSpanContinuationThreshold
            )
            guard accepted else {
                debugLog(
                    "resolved span continuation rejected score=\(String(format: "%.3f", effectiveMatch.score)) threshold=\(immediateContinuationThreshold)"
                )
                return handleTrackingMiss(transcription: transcription)
            }

            resetLowConfidenceContinuation()
            debugLog("resolved span continuation to \(effectiveMatch.surahNumber):\(effectiveMatch.verseNumber) wordEvidence=\(hasWordEvidence)")
            return advance(to: effectiveMatch)
        }

        if isImmediateContinuation(effectiveMatch, currentSurah: currentSurah, currentVerse: currentVerse) {
            let hasWordEvidence = hasContinuationWordEvidence(match: effectiveMatch, transcription: transcription)
            let hasStrongSingleEvidence = hasStrongSingleContinuationEvidence(
                referenceText: effectiveMatch.normalizedText,
                transcription: transcription
            )
            let primaryAccepted = effectiveMatch.score >= immediateContinuationThreshold &&
                (hasWordEvidence || hasStrongSingleEvidence)
            let accepted = primaryAccepted || shouldAcceptNoisySequentialContinuationIfNeeded(
                primaryAccepted: primaryAccepted,
                match: effectiveMatch,
                transcription: transcription,
                threshold: probableImmediateContinuationThreshold
            )
            guard accepted else {
                debugLog(
                    "immediate continuation rejected score=\(String(format: "%.3f", effectiveMatch.score)) threshold=\(immediateContinuationThreshold)"
                )
                switch registerLowConfidenceShortVerseContinuation(match: effectiveMatch, transcription: transcription) {
                case .accepted(let verse):
                    return verse
                case .pending:
                    return nil
                case .rejected:
                    return handleTrackingMiss(transcription: transcription)
                }
            }

            resetLowConfidenceContinuation()
            debugLog("immediate continuation to \(effectiveMatch.surahNumber):\(effectiveMatch.verseNumber) wordEvidence=\(hasWordEvidence)")
            return advance(to: effectiveMatch)
        }

        if isHighConfidenceSameSurahForwardJump(
            effectiveMatch,
            currentSurah: currentSurah,
            currentVerse: currentVerse,
            transcription: transcription
        ) {
            resetLowConfidenceContinuation()
            return advanceOneAyahToward(
                effectiveMatch,
                currentSurah: currentSurah,
                currentVerse: currentVerse,
                reason: "high-confidence same-surah forward evidence"
            )
        }

        guard effectiveMatch.score >= jumpThreshold else {
            resetLowConfidenceContinuation()
            debugLog("candidate below jump threshold score=\(String(format: "%.3f", effectiveMatch.score)) threshold=\(jumpThreshold)")
            return handleTrackingMiss(transcription: transcription)
        }

        if effectiveMatch.surahNumber == pendingSurah && effectiveMatch.verseNumber == pendingVerse {
            consecutiveCount += 1
        } else {
            pendingSurah = effectiveMatch.surahNumber
            pendingVerse = effectiveMatch.verseNumber
            consecutiveCount = 1
        }

        debugLog("jump pending \(effectiveMatch.surahNumber):\(effectiveMatch.verseNumber) consecutive=\(consecutiveCount)/\(requiredConsecutiveJump)")
        guard consecutiveCount >= requiredConsecutiveJump else { return nil }
        if shouldAdvanceSequentiallyToward(effectiveMatch, currentSurah: currentSurah, currentVerse: currentVerse) {
            return advanceOneAyahToward(
                effectiveMatch,
                currentSurah: currentSurah,
                currentVerse: currentVerse,
                reason: "confirmed same-surah forward candidate"
            )
        }
        return advance(to: effectiveMatch)
    }

    private func resolveDiscoveryMatch(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> QuranVerseMatchingEngine.VerseMatchCandidate {
        if let openingMatch = resolveFatihahOpeningMatch(match, transcription: transcription) {
            return openingMatch
        }

        return resolveDiscoverySpan(match, transcription: transcription)
    }

    private func resolveFatihahOpeningMatch(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> QuranVerseMatchingEngine.VerseMatchCandidate? {
        guard surahHint == 1,
              match.surahNumber == 1,
              match.verseNumber != 1,
              match.ayahEnd == nil,
              isLooseBismillahOpening(transcription),
              let opening = matchingEngine.getVerse(surah: 1, verse: 1) else {
            return nil
        }

        debugLog("resolved noisy Fatihah bismillah opening \(match.surahNumber):\(match.verseNumber) to 1:1")
        return QuranVerseMatchingEngine.VerseMatchCandidate(
            surahNumber: 1,
            verseNumber: 1,
            ayahEnd: nil,
            arabicText: opening.arabicText,
            normalizedText: opening.normalizedText,
            score: max(match.score, hintedImmediateDiscoveryThreshold)
        )
    }

    private func resolveDiscoverySpan(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> QuranVerseMatchingEngine.VerseMatchCandidate {
        guard let ayahEnd = match.ayahEnd,
              ayahEnd > match.verseNumber else {
            return match
        }

        guard match.verseNumber > 1 else {
            return match
        }

        if let startEntry = matchingEngine.getVerse(surah: match.surahNumber, verse: match.verseNumber),
           hasReferenceWordEvidence(referenceText: startEntry.normalizedText, transcription: transcription) ||
            hasStrongSingleContinuationEvidence(referenceText: startEntry.normalizedText, transcription: transcription) {
            return match
        }

        guard let resolved = matchingEngine.bestContainedVerse(
            transcription: transcription,
            in: match
        ) else {
            return match
        }

        guard resolved.verseNumber != match.verseNumber || resolved.ayahEnd != match.ayahEnd else {
            return match
        }

        debugLog(
            "resolved discovery span \(match.surahNumber):\(match.verseNumber)-\(ayahEnd) to \(resolved.surahNumber):\(resolved.verseNumber) score=\(String(format: "%.3f", resolved.score))"
        )
        return resolved
    }

    private func resolveTrackingSpan(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> QuranVerseMatchingEngine.VerseMatchCandidate {
        guard let ayahEnd = match.ayahEnd,
              ayahEnd > match.verseNumber,
              let currentSurah,
              match.surahNumber == currentSurah else {
            return match
        }

        guard let resolved = matchingEngine.bestContainedVerse(
            transcription: transcription,
            in: match
        ) else {
            return match
        }

        guard resolved.verseNumber != match.verseNumber || resolved.ayahEnd != match.ayahEnd else {
            return match
        }

        debugLog(
            "resolved span \(match.surahNumber):\(match.verseNumber)-\(ayahEnd) to \(resolved.surahNumber):\(resolved.verseNumber) score=\(String(format: "%.3f", resolved.score))"
        )
        return resolved
    }

    private func isResolvedForwardSpanContinuation(
        originalMatch: QuranVerseMatchingEngine.VerseMatchCandidate,
        resolvedMatch: QuranVerseMatchingEngine.VerseMatchCandidate,
        currentSurah: Int,
        currentVerse: Int
    ) -> Bool {
        guard originalMatch.ayahEnd != nil,
              resolvedMatch.surahNumber == currentSurah,
              resolvedMatch.verseNumber > currentVerse,
              resolvedMatch.verseNumber <= currentVerse + 3 else {
            return false
        }

        if originalMatch.verseNumber <= currentVerse,
           let spanEnd = originalMatch.ayahEnd,
           spanEnd > currentVerse {
            return true
        }

        return originalMatch.verseNumber == currentVerse + 1
    }

    private func trackingGlobalSwitchCandidate(
        transcription: String,
        scopedMatch: QuranVerseMatchingEngine.VerseMatchCandidate?,
        currentSurah: Int,
        currentVerse: Int
    ) -> QuranVerseMatchingEngine.VerseMatchCandidate? {
        let isAtSurahEnd = isAtEndOfSurah(surah: currentSurah, verse: currentVerse)
        let minimumScore = isAtSurahEnd ? 0.70 : trackingGlobalSwitchThreshold

        guard shouldConsiderGlobalSwitch(
            scopedMatch: scopedMatch,
            currentSurah: currentSurah,
            currentVerse: currentVerse
        ),
              hasUsefulGlobalSwitchContent(transcription) else {
            return nil
        }

        guard let globalMatch = matchingEngine.findBestMatch(
            transcription: transcription,
            minimumScore: minimumScore,
            exhaustiveSpanSearch: false
        ) else {
            return nil
        }

        guard globalMatch.surahNumber != currentSurah else { return nil }
        guard isReliableCrossSurahSwitch(
            globalMatch,
            transcription: transcription,
            minimumScore: minimumScore
        ) else { return nil }

        let requiredMargin = isAtSurahEnd ? 0.05 : trackingGlobalSwitchMargin
        if let scopedMatch,
           globalMatch.score < 0.97,
           globalMatch.score < scopedMatch.score + requiredMargin {
            return nil
        }

        if globalMatch.score < 0.97,
           matchingEngine.hasAmbiguousAlternative(
            transcription: transcription,
            candidate: globalMatch,
            scoreTolerance: 0.03
           ) {
            return nil
        }

        return globalMatch
    }

    private func isReliableCrossSurahSwitch(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String,
        minimumScore: Double
    ) -> Bool {
        guard match.score >= minimumScore else { return false }
        guard !isGenericOpeningOrPraisePhrase(transcription) else { return false }
        guard match.verseNumber == 1 || match.score >= 0.97 else { return false }
        return distinctiveEvidenceHitCount(
            referenceText: match.normalizedText,
            transcription: transcription
        ) >= 2
    }

    private func shouldConsiderGlobalSwitch(
        scopedMatch: QuranVerseMatchingEngine.VerseMatchCandidate?,
        currentSurah: Int,
        currentVerse: Int
    ) -> Bool {
        guard let scopedMatch else { return true }

        if scopedMatch.surahNumber != currentSurah {
            return true
        }

        if scopedMatch.verseNumber < currentVerse,
           !isAtEndOfSurah(surah: currentSurah, verse: currentVerse) {
            return false
        }

        if scopedMatch.verseNumber == currentVerse {
            return false
        }

        if scopedMatch.verseNumber == currentVerse + 1,
           scopedMatch.score >= probableImmediateContinuationThreshold {
            return false
        }

        return scopedMatch.score < immediateContinuationThreshold
    }

    private func handleTrackingGlobalSwitch(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate
    ) -> RecognizedVerse {
        currentSurah = match.surahNumber
        currentVerse = match.verseNumber
        pendingSurah = nil
        pendingVerse = nil
        consecutiveCount = 0
        resetLowConfidenceContinuation()
        missedTrackingCount = 0
        lowInformationTrackingCount = 0
        completedSurahBeforeDiscovery = nil
        recoverySurah = nil
        lastRejectedFarRecovery = nil
        recoveryMinimumVerse = nil
        surahHint = nil
        totalWordsInVerse = matchingEngine
            .getVerse(surah: match.surahNumber, verse: match.verseNumber)?
            .normalizedWords
            .count ?? 0
        wordsCovered = 0
        mode = .tracking
        debugLog("global switch committed \(match.surahNumber):\(match.verseNumber)")
        return recognizedVerse(from: match)
    }

    private func isImmediateContinuation(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        currentSurah: Int,
        currentVerse: Int
    ) -> Bool {
        if match.surahNumber == currentSurah, match.verseNumber == currentVerse + 1 {
            return true
        }
        return false
    }

    private func isHighConfidenceSameSurahForwardJump(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        currentSurah: Int,
        currentVerse: Int,
        transcription: String
    ) -> Bool {
        guard match.surahNumber == currentSurah,
              match.verseNumber > currentVerse + 1,
              match.verseNumber <= currentVerse + 3,
              match.score >= 0.92 else {
            return false
        }

        return hasContinuationWordEvidence(match: match, transcription: transcription) ||
            hasStrongSingleContinuationEvidence(referenceText: match.normalizedText, transcription: transcription)
    }

    private func shouldAdvanceSequentiallyToward(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        currentSurah: Int,
        currentVerse: Int
    ) -> Bool {
        match.surahNumber == currentSurah && match.verseNumber > currentVerse + 1
    }

    private func advanceOneAyahToward(
        _ match: QuranVerseMatchingEngine.VerseMatchCandidate,
        currentSurah: Int,
        currentVerse: Int,
        reason: String
    ) -> RecognizedVerse {
        guard shouldAdvanceSequentiallyToward(match, currentSurah: currentSurah, currentVerse: currentVerse),
              let nextEntry = matchingEngine.getVerse(surah: currentSurah, verse: currentVerse + 1) else {
            return advance(to: match)
        }

        debugLog("\(reason) target \(match.surahNumber):\(match.verseNumber), cueing next ayah \(nextEntry.surahNumber):\(nextEntry.verseNumber)")
        return advance(to: nextEntry, confidence: match.score)
    }

    private func shouldAcceptNoisySequentialContinuationIfNeeded(
        primaryAccepted: Bool,
        match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String,
        threshold: Double
    ) -> Bool {
        guard !primaryAccepted else { return false }
        return shouldAcceptNoisySequentialContinuation(
            match: match,
            transcription: transcription,
            threshold: threshold
        )
    }

    private func shouldAcceptNoisySequentialContinuation(
        match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String,
        threshold: Double
    ) -> Bool {
        guard match.score >= threshold,
              hasUsefulContinuationContent(transcription) else {
            return false
        }

        // The reciter often pauses or repeats while *starting* the current
        // ayah, and its opening words can fuzzily match a forward candidate.
        // match.score can also carry a +0.22 continuation bonus, so compare
        // bonus-free direct scores: only advance when the target ayah
        // explains the window clearly better than the current ayah.
        if let currentSurah, let currentVerse {
            let currentVerseScore = matchingEngine.directVerseScore(
                transcription: transcription,
                surah: currentSurah,
                verse: currentVerse
            )
            let targetVerseScore = matchingEngine.directVerseScore(
                transcription: transcription,
                surah: match.surahNumber,
                verse: match.verseNumber
            )
            let currentVerseText = matchingEngine
                .getVerse(surah: currentSurah, verse: currentVerse)?
                .normalizedText ?? ""
            let targetVerseText = matchingEngine
                .getVerse(surah: match.surahNumber, verse: match.verseNumber)?
                .normalizedText ?? ""
            if targetVerseScore < weakAdvanceDirectScoreFloor {
                debugLog(
                    "rejecting noisy continuation \(match.surahNumber):\(match.verseNumber) because target ayah does not explain window (target=\(String(format: "%.3f", targetVerseScore)))"
                )
                return false
            }
            let hasDistinctWord = !targetVerseText.isEmpty && hasDistinctTargetWordEvidence(
                transcription: transcription,
                targetText: targetVerseText,
                currentText: currentVerseText
            )
            if currentVerseScore + 0.05 >= targetVerseScore, !hasDistinctWord {
                debugLog(
                    "rejecting noisy continuation \(match.surahNumber):\(match.verseNumber) because current ayah explains window (current=\(String(format: "%.3f", currentVerseScore)) target=\(String(format: "%.3f", targetVerseScore)))"
                )
                return false
            }
            if isStalePreviousAyahAudio(
                transcription: transcription,
                currentSurah: currentSurah,
                currentVerse: currentVerse,
                forwardScore: targetVerseScore,
                targetText: targetVerseText
            ) {
                debugLog(
                    "rejecting noisy continuation \(match.surahNumber):\(match.verseNumber) because window matches previous ayah better"
                )
                return false
            }
        }

        guard !hasStrongerCrossSurahAlternative(transcription: transcription, localMatch: match) else {
            debugLog(
                "rejecting noisy continuation \(match.surahNumber):\(match.verseNumber) because a cross-surah alternative is stronger"
            )
            return false
        }

        debugLog(
            "accepting probable noisy continuation \(match.surahNumber):\(match.verseNumber) score=\(String(format: "%.3f", match.score))"
        )
        return true
    }

    /// Tail audio from the ayah behind the current one can fuzzily match a
    /// forward candidate while the reciter has not actually moved (e.g. a
    /// garbled window of 87:7's tail matching 87:9 while tracking 87:8).
    /// When the previous ayah explains the window clearly better than the
    /// proposed forward target, the audio is stale and must not advance.
    private func isStalePreviousAyahAudio(
        transcription: String,
        currentSurah: Int,
        currentVerse: Int,
        forwardScore: Double,
        targetText: String?
    ) -> Bool {
        guard currentVerse > 1,
              let previousEntry = matchingEngine.getVerse(surah: currentSurah, verse: currentVerse - 1) else {
            return false
        }
        // When the previous ayah textually contains the target's content
        // (e.g. Al-Fatihah's بسم الله الرحمن الرحيم contains الرحمن الرحيم),
        // a higher previous-ayah score is expected and proves nothing about
        // staleness; locality favors forward movement there.
        if let targetText,
           !targetText.isEmpty,
           LevenshteinMatcher.partialRatio(targetText, previousEntry.normalizedText) >= 0.85 {
            return false
        }
        let previousVerseScore = matchingEngine.directVerseScore(
            transcription: transcription,
            surah: currentSurah,
            verse: currentVerse - 1
        )
        return previousVerseScore > forwardScore + 0.05
    }

    /// True when the window contains a word that clearly belongs to the
    /// target ayah and not to the current one (fuzzy match, because Quranic
    /// orthography differs from decoder output: العالمين vs العلمين).
    private func hasDistinctTargetWordEvidence(
        transcription: String,
        targetText: String,
        currentText: String
    ) -> Bool {
        let transcribedWords = ArabicNormalizer.words(transcription)
        guard !transcribedWords.isEmpty else { return false }
        let currentWords = currentText.split(separator: " ").map(String.init)

        for targetWord in targetText.split(separator: " ").map(String.init) where targetWord.count >= 4 {
            let inWindow = transcribedWords.contains { LevenshteinMatcher.ratio($0, targetWord) >= 0.85 }
            guard inWindow else { continue }
            let inCurrent = currentWords.contains { LevenshteinMatcher.ratio($0, targetWord) >= 0.85 }
            if !inCurrent {
                return true
            }
        }
        return false
    }

    private func hasStrongerCrossSurahAlternative(
        transcription: String,
        localMatch: QuranVerseMatchingEngine.VerseMatchCandidate
    ) -> Bool {
        guard let currentSurah,
              let globalMatch = matchingEngine.findBestMatch(
                transcription: transcription,
                minimumScore: localMatch.score + 0.08,
                exhaustiveSpanSearch: true
              ) else {
            return false
        }

        return globalMatch.surahNumber != currentSurah
    }

    private func hasUsefulContinuationContent(_ transcription: String) -> Bool {
        let words = ArabicNormalizer.words(transcription)
        let characterCount = words.reduce(0) { $0 + $1.count }
        return words.count >= 2 && characterCount >= 5
    }

    private func hasUsefulGlobalSwitchContent(_ transcription: String) -> Bool {
        let words = ArabicNormalizer.words(transcription)
        let characterCount = words.reduce(0) { $0 + $1.count }
        return words.count >= 3 && characterCount >= 10
    }

    private func isGenericOpeningOrPraisePhrase(_ transcription: String) -> Bool {
        let genericStems: Set<String> = ["بسم", "اسم", "الله", "رحمن", "رحيم", "حمد", "رب", "عالم"]
        let contentStems = ArabicNormalizer.words(transcription)
            .map(evidenceStem)
            .filter { $0.count >= 3 }

        guard !contentStems.isEmpty else { return true }
        return contentStems.allSatisfy { genericStems.contains($0) }
    }

    private func distinctiveEvidenceHitCount(
        referenceText: String,
        transcription: String
    ) -> Int {
        let queryStems = Set(
            ArabicNormalizer.words(transcription)
                .map(evidenceStem)
                .filter { $0.count >= 3 }
        )
        let referenceStems = ArabicNormalizer.words(referenceText)
            .map(evidenceStem)
            .filter { $0.count >= 3 }

        var hits = 0
        for queryStem in queryStems {
            if referenceStems.contains(queryStem) {
                hits += 1
                continue
            }

            if referenceStems.contains(where: { LevenshteinMatcher.ratio(queryStem, $0) >= 0.78 }) {
                hits += 1
            }
        }
        return hits
    }

    private func distinctivePostCompletionHitCount(
        referenceText: String,
        transcription: String
    ) -> Int {
        let genericStems: Set<String> = [
            "الله", "لله", "سماوات", "سماء", "ارض", "رب", "رحمن", "رحيم",
            "هذا", "هذه", "ذلك", "تلك", "الذي", "الذين", "التي", "وما",
            "وهو", "وهي", "ومن", "وفي", "وال", "على", "علي", "الى", "الي",
            "في", "من", "ما", "لا", "لم", "لن", "ان", "كان", "لقد"
        ]
        let queryStems = Set(
            ArabicNormalizer.words(transcription)
                .map(evidenceStem)
                .filter { $0.count >= 3 && !genericStems.contains($0) }
        )
        let referenceStems = ArabicNormalizer.words(referenceText)
            .map(evidenceStem)
            .filter { $0.count >= 3 && !genericStems.contains($0) }

        var hits = 0
        for queryStem in queryStems {
            if referenceStems.contains(queryStem) {
                hits += 1
                continue
            }

            if referenceStems.contains(where: { LevenshteinMatcher.ratio(queryStem, $0) >= 0.78 }) {
                hits += 1
            }
        }
        return hits
    }

    private func hasContinuationWordEvidence(
        match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> Bool {
        hasReferenceWordEvidence(referenceText: match.normalizedText, transcription: transcription)
    }

    private func hasVerseWordEvidence(
        entry: QuranVerseMatchingEngine.VerseEntry,
        transcription: String
    ) -> Bool {
        hasReferenceWordEvidence(referenceText: entry.normalizedText, transcription: transcription)
    }

    private func hasReferenceWordEvidence(
        referenceText: String,
        transcription: String
    ) -> Bool {
        distinctiveEvidenceHitCount(
            referenceText: referenceText,
            transcription: transcription
        ) >= 2
    }

    private func hasStrongSingleContinuationEvidence(
        referenceText: String,
        transcription: String
    ) -> Bool {
        let queryStems = ArabicNormalizer.words(transcription)
            .map(evidenceStem)
            .filter { $0.count >= 5 }
        let referenceStems = ArabicNormalizer.words(referenceText)
            .map(evidenceStem)
            .filter { $0.count >= 5 }

        guard !queryStems.isEmpty, !referenceStems.isEmpty else { return false }

        for queryStem in queryStems {
            if referenceStems.contains(queryStem) {
                return true
            }

            if referenceStems.contains(where: { LevenshteinMatcher.ratio(queryStem, $0) >= 0.78 }) {
                return true
            }
        }

        return false
    }

    private func evidenceStem(_ word: String) -> String {
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

    private func registerLowConfidenceShortVerseContinuation(
        match: QuranVerseMatchingEngine.VerseMatchCandidate,
        transcription: String
    ) -> LowConfidenceContinuationDecision {
        let normalizedTranscription = ArabicNormalizer.normalize(transcription)
        guard normalizedTranscription.count >= minimumLowConfidenceContinuationCharacters,
              match.score >= lowConfidenceShortVerseContinuationThreshold,
              let entry = matchingEngine.getVerse(surah: match.surahNumber, verse: match.verseNumber),
              entry.normalizedWords.count <= maximumWordsForLowConfidenceShortVerse else {
            resetLowConfidenceContinuation()
            return .rejected
        }

        if match.surahNumber == pendingLowConfidenceSurah && match.verseNumber == pendingLowConfidenceVerse {
            consecutiveLowConfidenceContinuationCount += 1
        } else {
            pendingLowConfidenceSurah = match.surahNumber
            pendingLowConfidenceVerse = match.verseNumber
            consecutiveLowConfidenceContinuationCount = 1
        }

        debugLog(
            "low-confidence short continuation pending \(match.surahNumber):\(match.verseNumber) consecutive=\(consecutiveLowConfidenceContinuationCount)/\(requiredLowConfidenceShortVerseContinuations)"
        )

        guard consecutiveLowConfidenceContinuationCount >= requiredLowConfidenceShortVerseContinuations else {
            return .pending
        }

        resetLowConfidenceContinuation()
        debugLog("accepting repeated low-confidence short continuation to \(match.surahNumber):\(match.verseNumber)")
        return .accepted(advance(to: match))
    }

    private func resetLowConfidenceContinuation() {
        pendingLowConfidenceSurah = nil
        pendingLowConfidenceVerse = nil
        consecutiveLowConfidenceContinuationCount = 0
    }

    private func handleTrackingMiss(transcription: String) -> RecognizedVerse? {
        guard shouldCountTrackingMiss(transcription) else {
            if shouldLeaveNearEndTrackingAfterLowInformation() {
                return returnToDiscoveryAfterTrackingLoss(
                    lostSurah: currentSurah,
                    lostVerse: currentVerse,
                    assumeCompletedSurah: true,
                    transcription: transcription
                )
            }
            debugLog("ignoring low-information tracking miss")
            return nil
        }

        let lostSurah = currentSurah
        let lostVerse = currentVerse
        let wasAtEndOfSurah = isAtEndOfSurah(surah: lostSurah, verse: lostVerse)
        let shouldAssumeCompletedSurah = wasAtEndOfSurah || isNearEndOfSurah(surah: lostSurah, verse: lostVerse)
        let maximumMisses = wasAtEndOfSurah
            ? maximumMissedTrackingCountAfterCompletedSurah
            : maximumMissedTrackingCount

        missedTrackingCount += 1
        lowInformationTrackingCount = 0
        debugLog("tracking miss \(missedTrackingCount)/\(maximumMisses)")

        guard missedTrackingCount >= maximumMisses else { return nil }

        return returnToDiscoveryAfterTrackingLoss(
            lostSurah: lostSurah,
            lostVerse: lostVerse,
            assumeCompletedSurah: shouldAssumeCompletedSurah,
            transcription: transcription
        )
    }

    private func returnToDiscoveryAfterTrackingLoss(
        lostSurah: Int?,
        lostVerse: Int?,
        assumeCompletedSurah: Bool,
        transcription: String
    ) -> RecognizedVerse? {
        debugLog("tracking lost, returning to discovery")
        mode = .discovery
        currentSurah = nil
        currentVerse = nil
        wordsCovered = 0
        totalWordsInVerse = 0
        pendingSurah = nil
        pendingVerse = nil
        consecutiveCount = 0
        resetLowConfidenceContinuation()
        missedTrackingCount = 0
        lowInformationTrackingCount = 0
        if assumeCompletedSurah {
            completedSurahBeforeDiscovery = lostSurah
            surahHint = nil
            recoverySurah = nil
            lastRejectedFarRecovery = nil
            recoveryMinimumVerse = nil
        } else {
            completedSurahBeforeDiscovery = nil
            surahHint = lostSurah
            recoverySurah = lostSurah
            lastRejectedFarRecovery = nil
            recoveryMinimumVerse = lostVerse
        }

        guard let rediscovery = nearRecoveryMatch(transcription: transcription) ?? matchingEngine.findBestMatch(
            transcription: transcription,
            surahHint: surahHint,
            minimumScore: discoveryAcceptanceThreshold,
            minimumVerseInSurahHint: minimumVerseInSurahHint,
            exhaustiveSpanSearch: shouldUseExhaustiveSpanSearch,
            allowGlobalFallbackFromSurahHint: shouldAllowGlobalDiscoveryFallback
        ) else {
            debugLog("rediscovery found no global candidate")
            return nil
        }
        debugLog(
            "rediscovery candidate \(rediscovery.surahNumber):\(rediscovery.verseNumber) score=\(String(format: "%.3f", rediscovery.score))"
        )
        return handleDiscoveryMatch(rediscovery, transcription: transcription)
    }

    private func shouldLeaveNearEndTrackingAfterLowInformation() -> Bool {
        guard isNearEndOfSurah(surah: currentSurah, verse: currentVerse) else {
            lowInformationTrackingCount = 0
            return false
        }

        lowInformationTrackingCount += 1
        debugLog("low-information near-end tracking miss \(lowInformationTrackingCount)/\(maximumLowInformationTrackingCountNearSurahEnd)")
        return lowInformationTrackingCount >= maximumLowInformationTrackingCountNearSurahEnd
    }

    private func isAtEndOfSurah(surah: Int?, verse: Int?) -> Bool {
        surah.flatMap { surah in
            verse.map { verse in
                matchingEngine.getVerse(surah: surah, verse: verse + 1) == nil
            }
        } ?? false
    }

    private func isNearEndOfSurah(surah: Int?, verse: Int?) -> Bool {
        guard let surah, let verse else { return false }
        return matchingEngine.getVerse(surah: surah, verse: verse + 2) == nil
    }

    private func shouldCountTrackingMiss(_ transcription: String) -> Bool {
        hasUsefulDiscoveryContent(transcription)
    }

    private func hasUsefulDiscoveryContent(_ transcription: String) -> Bool {
        let words = ArabicNormalizer.words(transcription)
        let characterCount = words.reduce(0) { $0 + $1.count }

        if words.count >= 2, characterCount >= 6 {
            return true
        }

        return words.contains { $0.count >= 6 }
    }

    private func updateWordCoverage(transcription: String, surah: Int, verse: Int) -> RecognizedVerse? {
        guard let entry = matchingEngine.getVerse(surah: surah, verse: verse) else { return nil }
        let alignment = LevenshteinMatcher.wordAlignment(
            transcription: transcription,
            reference: entry.normalizedText
        )
        wordsCovered = alignment.matched
        totalWordsInVerse = alignment.total

        guard alignment.total > 0 else { return nil }
        let coverage = Double(alignment.matched) / Double(alignment.total)
        debugLog("coverage \(surah):\(verse) \(alignment.matched)/\(alignment.total) = \(String(format: "%.2f", coverage))")
        let endingConfidence = currentVerseEndingConfidence(transcription: transcription, entry: entry)
        guard (coverage >= autoAdvanceCoverage || endingConfidence != nil),
              let nextEntry = matchingEngine.getVerse(surah: surah, verse: verse + 1) else {
            return nil
        }

        let confidence = max(coverage, endingConfidence ?? 0)
        debugLog("completed \(entry.surahNumber):\(entry.verseNumber), showing next phrase \(nextEntry.surahNumber):\(nextEntry.verseNumber)")
        return advance(to: nextEntry, confidence: confidence)
    }

    private func advanceAfterCurrentVerseEnding(transcription: String) -> RecognizedVerse? {
        guard let currentSurah,
              let currentVerse,
              let entry = matchingEngine.getVerse(surah: currentSurah, verse: currentVerse),
              let nextEntry = matchingEngine.getVerse(surah: currentSurah, verse: currentVerse + 1),
              let confidence = currentVerseEndingConfidence(transcription: transcription, entry: entry) else {
            return nil
        }

        // Adjacent ayahs can share stems (e.g. أصبحت in one ayah and مصبحين
        // ending the next). When the window still matches the previous ayah
        // clearly better than the current one, the ending-stem hit is stale
        // audio from the previous ayah, not a completed current ayah.
        if currentVerse > 1 {
            let currentVerseScore = matchingEngine.directVerseScore(
                transcription: transcription,
                surah: currentSurah,
                verse: currentVerse
            )
            let previousVerseScore = matchingEngine.directVerseScore(
                transcription: transcription,
                surah: currentSurah,
                verse: currentVerse - 1
            )
            if previousVerseScore > currentVerseScore + 0.1 {
                debugLog(
                    "ignoring ending stem for \(entry.surahNumber):\(entry.verseNumber); window matches previous ayah better (prev=\(String(format: "%.3f", previousVerseScore)) current=\(String(format: "%.3f", currentVerseScore)))"
                )
                return nil
            }
        }

        debugLog("detected ending word for \(entry.surahNumber):\(entry.verseNumber), showing next phrase \(nextEntry.surahNumber):\(nextEntry.verseNumber)")
        return advance(to: nextEntry, confidence: confidence)
    }

    private func currentVerseEndingConfidence(
        transcription: String,
        entry: QuranVerseMatchingEngine.VerseEntry
    ) -> Double? {
        let queryStems = ArabicNormalizer.words(transcription)
            .map(evidenceStem)
            .filter { $0.count >= 3 }
        let referenceStems = entry.normalizedWords
            .map(evidenceStem)
            .filter { $0.count >= 3 }

        guard !queryStems.isEmpty,
              let finalStem = referenceStems.last else {
            return nil
        }
        guard !isBismillahPhrase(transcription) || entry.normalizedWords.contains("بسم") else {
            return nil
        }

        let finalScore = bestStemScore(for: finalStem, in: queryStems)
        let previousFinalScore: Double
        if referenceStems.count >= 2 {
            previousFinalScore = bestStemScore(
                for: referenceStems[referenceStems.count - 2],
                in: queryStems
            )
        } else {
            previousFinalScore = 0
        }

        if finalScore >= 0.72 {
            return min(0.95, max(0.70, (0.75 * finalScore) + (0.20 * previousFinalScore)))
        }

        return nearEndingTailConfidence(queryStems: queryStems, referenceStems: referenceStems)
    }

    private func nearEndingTailConfidence(queryStems: [String], referenceStems: [String]) -> Double? {
        guard referenceStems.count >= 5 else { return nil }

        let penultimateStem = referenceStems[referenceStems.count - 2]
        let penultimateScore = bestStemScore(for: penultimateStem, in: queryStems)
        guard penultimateScore >= 0.82 else { return nil }

        let tailStems = referenceStems.suffix(4)
        var tailHits = 0
        var tailScoreTotal = 0.0
        for stem in tailStems {
            let score = bestStemScore(for: stem, in: queryStems)
            if score >= 0.76 {
                tailHits += 1
                tailScoreTotal += score
            }
        }

        guard tailHits >= 2 else { return nil }
        let averageTailScore = tailScoreTotal / Double(tailHits)
        return min(0.90, max(0.72, (0.65 * penultimateScore) + (0.20 * averageTailScore)))
    }

    private func isBismillahPhrase(_ transcription: String) -> Bool {
        let words = ArabicNormalizer.words(transcription)
        let stems = Set(words.map(evidenceStem))
        return (words.contains("بسم") || words.contains("اسم")) &&
            words.contains("الله") &&
            stems.contains("رحيم")
    }

    private func isLooseBismillahOpening(_ transcription: String) -> Bool {
        let words = ArabicNormalizer.words(transcription)
        let stems = words.map(evidenceStem)
        let hasOpeningCue = words.contains("بسم") ||
            words.contains("بس") ||
            words.contains("اسم")
        guard hasOpeningCue else { return false }

        let hasRahman = stems.contains { LevenshteinMatcher.ratio($0, "رحمن") >= 0.78 }
        let hasRahim = stems.contains { LevenshteinMatcher.ratio($0, "رحيم") >= 0.78 }
        let hasAllah = words.contains("الله")
        return hasRahim && (hasRahman || hasAllah)
    }

    private func bestStemScore(for referenceStem: String, in queryStems: [String]) -> Double {
        var bestScore = 0.0
        for queryStem in queryStems {
            bestScore = max(bestScore, LevenshteinMatcher.ratio(queryStem, referenceStem))
            if bestScore >= 1.0 { break }
        }
        return bestScore
    }

    private func advance(to match: QuranVerseMatchingEngine.VerseMatchCandidate) -> RecognizedVerse {
        guard let entry = matchingEngine.getVerse(surah: match.surahNumber, verse: match.verseNumber) else {
            currentSurah = match.surahNumber
            currentVerse = match.verseNumber
            pendingSurah = nil
            pendingVerse = nil
            consecutiveCount = 0
            resetLowConfidenceContinuation()
            missedTrackingCount = 0
            lowInformationTrackingCount = 0
            wordsCovered = 0
            totalWordsInVerse = 0
            debugLog("advanced to \(match.surahNumber):\(match.verseNumber)")
            return recognizedVerse(from: match)
        }

        return advance(to: entry, confidence: match.score)
    }

    private func advance(to entry: QuranVerseMatchingEngine.VerseEntry, confidence: Double) -> RecognizedVerse {
        currentSurah = entry.surahNumber
        currentVerse = entry.verseNumber
        pendingSurah = nil
        pendingVerse = nil
        consecutiveCount = 0
        resetLowConfidenceContinuation()
        missedTrackingCount = 0
        lowInformationTrackingCount = 0
        wordsCovered = 0
        totalWordsInVerse = entry.normalizedWords.count
        debugLog("advanced to \(entry.surahNumber):\(entry.verseNumber)")
        return RecognizedVerse(
            surahNumber: entry.surahNumber,
            verseNumber: entry.verseNumber,
            ayahEnd: nil,
            confidence: confidence,
            arabicText: entry.arabicText
        )
    }

    private func recognizedVerse(from match: QuranVerseMatchingEngine.VerseMatchCandidate) -> RecognizedVerse {
        RecognizedVerse(
            surahNumber: match.surahNumber,
            verseNumber: match.verseNumber,
            ayahEnd: match.ayahEnd,
            confidence: match.score,
            arabicText: match.arabicText
        )
    }

    private func debugLog(_ message: String) {
        guard debugLogging else { return }
        print("[QuranRecognitionKit.Tracker] \(message)")
    }
}
