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

    private let requiredConsecutiveDiscovery = 2
    private let requiredConsecutiveJump = 2
    private let hintedDiscoveryThreshold = 0.58
    private let hintedImmediateDiscoveryThreshold = 0.60
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
        recoveryMinimumVerse = nil
        surahHint = nil
    }

    func processTranscription(_ transcription: String) -> RecognizedVerse? {
        debugLog("process mode=\(mode) hint=\(surahHint.map(String.init) ?? "nil") completedSurah=\(completedSurahBeforeDiscovery.map(String.init) ?? "nil") text='\(transcription)'")
        let match: QuranVerseMatchingEngine.VerseMatchCandidate?

        switch mode {
        case .discovery:
            match = matchingEngine.findBestMatch(
                transcription: transcription,
                currentSurah: currentSurah,
                currentVerse: currentVerse,
                surahHint: surahHint,
                minimumScore: discoveryAcceptanceThreshold,
                minimumVerseInSurahHint: minimumVerseInSurahHint,
                exhaustiveSpanSearch: shouldUseExhaustiveSpanSearch
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
            let effectiveMatch = resolveDiscoverySpan(match, transcription: transcription)
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

    private var minimumVerseInSurahHint: Int? {
        guard surahHint == recoverySurah else { return nil }
        return recoveryMinimumVerse
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

        return match.verseNumber >= recoveryMinimumVerse
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
            debugLog("high-confidence same-surah jump to \(effectiveMatch.surahNumber):\(effectiveMatch.verseNumber)")
            return advance(to: effectiveMatch)
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
        return advance(to: effectiveMatch)
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
            recoveryMinimumVerse = nil
        } else {
            completedSurahBeforeDiscovery = nil
            surahHint = lostSurah
            recoverySurah = lostSurah
            recoveryMinimumVerse = lostVerse
        }

        guard let rediscovery = matchingEngine.findBestMatch(
            transcription: transcription,
            surahHint: surahHint,
            minimumScore: discoveryAcceptanceThreshold,
            minimumVerseInSurahHint: minimumVerseInSurahHint,
            exhaustiveSpanSearch: shouldUseExhaustiveSpanSearch
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
        guard finalScore >= 0.72 else { return nil }

        let previousFinalScore: Double
        if referenceStems.count >= 2 {
            previousFinalScore = bestStemScore(
                for: referenceStems[referenceStems.count - 2],
                in: queryStems
            )
        } else {
            previousFinalScore = 0
        }

        return min(0.95, max(0.70, (0.75 * finalScore) + (0.20 * previousFinalScore)))
    }

    private func isBismillahPhrase(_ transcription: String) -> Bool {
        let words = ArabicNormalizer.words(transcription)
        let stems = Set(words.map(evidenceStem))
        return (words.contains("بسم") || words.contains("اسم")) &&
            words.contains("الله") &&
            stems.contains("رحيم")
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
