import Foundation
import Testing
@testable import QuranRecognitionKit

@Test func bundledQuranResourceLoadsAllVerses() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    #expect(engine.totalVerses == 6_236)
    #expect(engine.getVerse(surah: 1, verse: 1) != nil)
}

@Test func verseMatchingFindsExactKnownVerse() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let verse = try #require(engine.getVerse(surah: 1, verse: 5))
    let match = try #require(engine.findBestMatch(transcription: verse.normalizedText))

    #expect(match.surahNumber == 1)
    #expect(match.verseNumber == 5)
    #expect(match.score >= 0.99)
}

@Test func surahHintScopesDiscovery() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let verse = try #require(engine.getVerse(surah: 112, verse: 1))
    let match = try #require(engine.findBestMatch(
        transcription: verse.normalizedText,
        surahHint: 112
    ))

    #expect(match.surahNumber == 112)
    #expect(match.verseNumber == 1)
}

@Test func hintedDiscoveryDoesNotCommitUnrelatedGlobalCandidateFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 18)

    #expect(tracker.processTranscription("الم المؤمن") == nil)
    #expect(tracker.processTranscription("الم المؤمن") == nil)

    #expect(tracker.mode == .discovery)
    #expect(tracker.currentSurah == nil)
    #expect(tracker.currentVerse == nil)
}

@Test func hintedDiscoveryFindsAlKahfPhraseFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 18)

    let startedAt = Date()
    let match = try #require(
        tracker.processTranscription("وَيُبَشِّرَ الْمُؤْمِنِينَ الَّذِينَ يَعْمَلُونَ الصَّالِحاتِ")
    )
    let elapsed = Date().timeIntervalSince(startedAt)

    #expect(match.surahNumber == 18)
    #expect(match.verseNumber == 2)
    #expect(elapsed < 1.0)
}

@Test func noisyAlKahfResolvedSpansDoNotSkipMultipleAyahsFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()

    let earlyTracker = RecitationTracker(matchingEngine: engine, surahHint: 18)
    _ = try #require(
        earlyTracker.processTranscription("وَيُبَشِّرَ الْمُؤْمِنِينَ الَّذِينَ يَعْمَلُونَ الصَّالِحاتِ")
    )
    #expect(earlyTracker.currentSurah == 18)
    #expect(earlyTracker.currentVerse == 2)

    #expect(earlyTracker.processTranscription("م يعملون صالحاته") == nil)
    #expect(earlyTracker.currentSurah == 18)
    #expect(earlyTracker.currentVerse == 2)

    let laterTracker = RecitationTracker(matchingEngine: engine, surahHint: 18)
    _ = try #require(laterTracker.processTranscription("فضربنا علي ءاذانهم في الكهف سنين عددا"))
    #expect(laterTracker.currentSurah == 18)
    #expect(laterTracker.currentVerse == 11)

    #expect(laterTracker.processTranscription("والفتنة من الكن فقائل ربنا") == nil)
    #expect(laterTracker.currentSurah == 18)
    #expect(laterTracker.currentVerse == 11)
}

@Test func hintedDiscoveryRejectsNoisyAlKahfFragmentQuicklyFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 18)

    let startedAt = Date()
    #expect(tracker.processTranscription("سَرَنَا عَنَا الْكِتَابَ وَالْ يَت") == nil)
    let elapsed = Date().timeIntervalSince(startedAt)

    #expect(elapsed < 2.0)
    #expect(tracker.mode == .discovery)
}

@Test func fatihahHintedDiscoveryTreatsNoisyBismillahAsOpeningFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)

    let match = try #require(tracker.processTranscription("بس الرحمن الرحيم"))

    #expect(match.surahNumber == 1)
    #expect(match.verseNumber == 1)
    #expect(tracker.currentSurah == 1)
    #expect(tracker.currentVerse == 1)
}

@Test func hintedSurahDiscoveryCanCommitLikelyMatchSooner() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)

    let match = try #require(tracker.processTranscription("بس الرحمن الرحيمية رب العالمين"))

    #expect(match.surahNumber == 1)
    #expect(match.verseNumber == 1)
    #expect(match.ayahEnd == 2)
}

@Test func trackingDoesNotOfferNextSurahBeforeCurrentSurahEnds() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let match = engine.findBestMatchScoped(
        transcription: "ما عليك اليوم",
        currentSurah: 1,
        currentVerse: 3
    )

    #expect(match?.surahNumber != 2)
}

@Test func weakTrackingMismatchesReturnToDiscoveryInsteadOfAdvancingAcrossSurahs() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    let firstMatch = try #require(tracker.processTranscription("الرحمن الرحيم"))
    #expect(firstMatch.surahNumber == 1)
    #expect(firstMatch.verseNumber == 3)

    for _ in 0..<4 {
        _ = tracker.processTranscription("ما عليك اليوم")
    }

    #expect(tracker.mode == .discovery)
    #expect(tracker.currentSurah == nil)
    #expect(tracker.currentVerse == nil)
}

@Test func sameSurahWeakNextAyahFromLogCanAdvance() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("مالك يوم الدين"))
    _ = try #require(tracker.processTranscription("وإياك نستعين"))
    let next = try #require(tracker.processTranscription("فانطنا مستقيمين"))

    #expect(next.surahNumber == 1)
    #expect(next.verseNumber == 6)
}

@Test func noisyFatihahTrackingFragmentDoesNotBlockFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)

    _ = try #require(tracker.processTranscription("اهدنا الصراط المستقيم"))
    #expect(tracker.currentSurah == 1)
    #expect(tracker.currentVerse == 6)

    let startedAt = Date()
    _ = tracker.processTranscription("دعو مستعينهد الصرا")
    let elapsed = Date().timeIntervalSince(startedAt)

    #expect(elapsed < 2.0)
}

@Test func repeatedWeakShortNextAyahFromLogCanAdvance() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("بسم الله الرحمن الرحيم"))
    _ = try #require(tracker.processTranscription("الحمد رب العالمين"))

    #expect(tracker.processTranscription("وَالحُ") == nil)
    let next = try #require(tracker.processTranscription("وَنُورِينَ"))

    #expect(next.surahNumber == 1)
    #expect(next.verseNumber == 3)
}

@Test func completedShortAyahEmitsNextAyahForReaderCue() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("الرحمن الرحيم"))
    let completed = try #require(tracker.processTranscription("الرَّحْمَنِ الرَّحِيمِ"))

    #expect(completed.surahNumber == 1)
    #expect(completed.verseNumber == 4)
    #expect(tracker.currentSurah == 1)
    #expect(tracker.currentVerse == 4)
}

@Test func currentAyahLastWordEmitsNextAyahForReaderCue() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)

    _ = try #require(tracker.processTranscription("بسم الله الرحمن الرحيم"))
    _ = try #require(tracker.processTranscription("الحمد لله رب"))
    let next = try #require(tracker.processTranscription("العالمين"))

    #expect(next.surahNumber == 1)
    #expect(next.verseNumber == 3)
    #expect(tracker.currentSurah == 1)
    #expect(tracker.currentVerse == 3)
}

@Test func longAyahTailPhraseEmitsNextAyahBeforeFinalWord() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 18)

    _ = try #require(
        tracker.processTranscription("وَيُبَشِّرَ الْمُؤْمِنِينَ الَّذِينَ يَعْمَلُونَ الصَّالِحاتِ")
    )
    #expect(tracker.currentSurah == 18)
    #expect(tracker.currentVerse == 2)

    let next = try #require(tracker.processTranscription("إن لهم أجرا"))

    #expect(next.surahNumber == 18)
    #expect(next.verseNumber == 3)
    #expect(tracker.currentSurah == 18)
    #expect(tracker.currentVerse == 3)
}

@Test func middlePhraseInLongAyahDoesNotEmitNextAyahEarly() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 18)

    _ = try #require(tracker.processTranscription("قالوا اتخذ الله ولدا"))
    _ = try #require(tracker.processTranscription("ما لهم به من علم"))
    #expect(tracker.currentSurah == 18)
    #expect(tracker.currentVerse == 5)

    #expect(tracker.processTranscription("ولا لآبائهم كبرت كلمة") == nil)
    #expect(tracker.currentSurah == 18)
    #expect(tracker.currentVerse == 5)
}

@Test func stalePreviousAyahAfterAutoAdvanceDoesNotMoveBackwards() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("الرحمن الرحيم"))
    _ = try #require(tracker.processTranscription("الرَّحْمَنِ الرَّحِيمِ"))

    #expect(tracker.processTranscription("الرَّحْمَنِ الرحِيممُ") == nil)
    #expect(tracker.processTranscription("الرَّحْمَنِ الرَّحِيمُ") == nil)
    #expect(tracker.currentSurah == 1)
    #expect(tracker.currentVerse == 4)
}

@Test func fatihahTrackingCatchesUpSequentiallyFromForwardEvidence() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)

    let first = try #require(tracker.processTranscription("بسم الله الرحمن الرحيم"))
    #expect(first.surahNumber == 1)
    #expect(first.verseNumber == 1)

    let second = try #require(tracker.processTranscription("رب العالمين العالمين"))
    #expect(second.surahNumber == 1)
    #expect(second.verseNumber == 2)

    let completedSecond = try #require(tracker.processTranscription("الْحَمْدُ لِلَّهِ رَبِّ الْعَالَمِينَ"))
    #expect(completedSecond.surahNumber == 1)
    #expect(completedSecond.verseNumber == 3)
    #expect(tracker.currentSurah == 1)
    #expect(tracker.currentVerse == 3)

    let fourth = try #require(tracker.processTranscription("اهدنا الصراط المستقيم"))
    #expect(fourth.surahNumber == 1)
    #expect(fourth.verseNumber == 4)

    let fifth = try #require(tracker.processTranscription("اهدنا الصراط المستقيم"))
    #expect(fifth.surahNumber == 1)
    #expect(fifth.verseNumber == 5)

    let sixth = try #require(tracker.processTranscription("اهدنا الصراط المستقيم"))
    #expect(sixth.surahNumber == 1)
    #expect(sixth.verseNumber == 6)

    let seventh = try #require(tracker.processTranscription("صراط الذين أنعمت عليهم"))
    #expect(seventh.surahNumber == 1)
    #expect(seventh.verseNumber == 7)
}

@Test func fatihahTrackingAdvancesThroughNoisySequentialFragmentsFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)

    _ = try #require(tracker.processTranscription("بسم الله الرحمن الرحمن الرحيم"))
    _ = try #require(tracker.processTranscription("بِ رَبِّ الْعَالمِينَ"))
    _ = try #require(tracker.processTranscription("بِ الرَّحْمَِ الرَّحِيِ"))

    let fourth = try #require(tracker.processTranscription("ش الِينَ"))
    #expect(fourth.surahNumber == 1)
    #expect(fourth.verseNumber == 4)

    let fifth = try #require(tracker.processTranscription("قل وإن عنك مست"))
    #expect(fifth.surahNumber == 1)
    #expect(fifth.verseNumber == 5)
}

@Test func discoveryResolvesFatihahSpanStartToContainedAyahFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)

    let verse = try #require(tracker.processTranscription("عبد وإياك فاستعين"))

    #expect(verse.surahNumber == 1)
    #expect(verse.verseNumber == 5)
    #expect(tracker.currentSurah == 1)
    #expect(tracker.currentVerse == 5)
}

@Test func sameSurahHighConfidenceForwardEvidenceCuesNextAyahInsteadOfSkipping() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)

    _ = try #require(tracker.processTranscription("مالك يوم الدين"))
    let fifth = try #require(tracker.processTranscription("اهدنا الصراط المستقم"))

    #expect(fifth.surahNumber == 1)
    #expect(fifth.verseNumber == 5)
    #expect(tracker.currentSurah == 1)
    #expect(tracker.currentVerse == 5)
}

@Test func strongForwardEvidenceTwoAyahsAheadCuesNextAyahInsteadOfSkippingFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("بسم الله الرحمن الرحيم"))
    _ = try #require(tracker.processTranscription("الحمد رب العالمين"))
    #expect(tracker.currentSurah == 1)
    #expect(tracker.currentVerse == 2)

    // Exact evidence for 1:4 while tracking 1:2 must cue 1:3, never jump straight to 1:4.
    let cued = try #require(tracker.processTranscription("مالك يوم الدين"))
    #expect(cued.surahNumber == 1)
    #expect(cued.verseNumber == 3)
    #expect(tracker.currentVerse == 3)

    // Repeated evidence then advances sequentially to 1:4.
    let fourth = try #require(tracker.processTranscription("مالك يوم الدين"))
    #expect(fourth.surahNumber == 1)
    #expect(fourth.verseNumber == 4)
}

@Test func highConfidenceLaterAyahCatchesUpOneAyahAtATime() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 18)

    _ = try #require(tracker.processTranscription("فضربنا علي ءاذانهم في الكهف سنين عددا"))
    #expect(tracker.currentSurah == 18)
    #expect(tracker.currentVerse == 11)

    let twelfth = try #require(
        tracker.processTranscription("وربطنا علي قلوبهم اذ قاموا فقالوا ربنا رب السموت والارض لن ندعوا من دونهۦ الها لقد قلنا اذا شططا")
    )
    #expect(twelfth.surahNumber == 18)
    #expect(twelfth.verseNumber == 12)

    let thirteenth = try #require(
        tracker.processTranscription("وربطنا علي قلوبهم اذ قاموا فقالوا ربنا رب السموت والارض لن ندعوا من دونهۦ الها لقد قلنا اذا شططا")
    )
    #expect(thirteenth.surahNumber == 18)
    #expect(thirteenth.verseNumber == 13)
}

@Test func spanResolutionPrefersAyahContainingShortFragmentFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let second = try #require(engine.getVerse(surah: 62, verse: 2))
    let third = try #require(engine.getVerse(surah: 62, verse: 3))
    let span = QuranVerseMatchingEngine.VerseMatchCandidate(
        surahNumber: 62,
        verseNumber: 2,
        ayahEnd: 3,
        arabicText: second.arabicText + " " + third.arabicText,
        normalizedText: second.normalizedText + " " + third.normalizedText,
        score: 0.8
    )

    // In the Al-Jumu'ah log, short noisy decodes of ayah 2's opening kept
    // resolving span 62:2-3 to ayah 3 (plain ratios favor the shorter ayah),
    // which was then rejected as a multi-ayah jump and counted as a miss.
    let fragment = second.normalizedWords.prefix(2).joined(separator: " ")
    let resolved = try #require(engine.bestContainedVerse(transcription: fragment, in: span))
    #expect(resolved.verseNumber == 2)
}

@Test func noisyOpeningOfCurrentAyahDoesNotCueNextAyahFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 62)

    let eighth = try #require(engine.getVerse(surah: 62, verse: 8))
    let ninth = try #require(engine.getVerse(surah: 62, verse: 9))
    _ = try #require(tracker.processTranscription(eighth.normalizedText))
    _ = try #require(tracker.processTranscription(ninth.normalizedText))
    #expect(tracker.currentSurah == 62)
    #expect(tracker.currentVerse == 9)

    // In the field log, a garbled decode of ayah 9's opening ('يا ايها المؤمن')
    // advanced the reader to 62:10 while the reciter was just starting ayah 9.
    #expect(tracker.processTranscription("يا ايها المؤمن") == nil)
    #expect(tracker.currentSurah == 62)
    #expect(tracker.currentVerse == 9)
}

@Test func midVerseFragmentDoesNotCueNextAyahViaForwardSpanFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 68)

    let opening = try #require(engine.getVerse(surah: 68, verse: 1))
    _ = try #require(tracker.processTranscription(opening.normalizedText))
    #expect(tracker.currentVerse == 1)

    // Al-Qalam log: 'النور والقلم' (a garbled mid-ayah-1 fragment) matched a
    // bonus-inflated forward span and cued ayah 2 while the reciter was
    // still inside ayah 1.
    #expect(tracker.processTranscription("النور والقلم") == nil)
    #expect(tracker.currentSurah == 68)
    #expect(tracker.currentVerse == 1)
}

@Test func garbledStartOfCurrentAyahDoesNotAdvanceFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 68)

    let fifteenth = try #require(engine.getVerse(surah: 68, verse: 15))
    _ = try #require(tracker.processTranscription(fifteenth.normalizedText))
    #expect(tracker.currentVerse == 15)

    // Al-Qalam log: 'عليه أليةقى' (garbled middle of ayah 15) advanced the
    // reader to 68:16 with wordEvidence=false while the reciter was mid-ayah.
    _ = tracker.processTranscription("عليه أليةقى")
    #expect(tracker.currentSurah == 68)
    #expect(tracker.currentVerse == 15)

    // Real evidence for ayah 16 must still advance promptly.
    let sixteenth = try #require(engine.getVerse(surah: 68, verse: 16))
    let advanced = try #require(tracker.processTranscription(sixteenth.normalizedText))
    #expect(advanced.verseNumber == 16)
}

@Test func sharedEndingStemWithPreviousAyahDoesNotAdvanceFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 68)

    let twentieth = try #require(engine.getVerse(surah: 68, verse: 20))
    let twentyFirst = try #require(engine.getVerse(surah: 68, verse: 21))
    _ = try #require(tracker.processTranscription(twentieth.normalizedText))
    _ = try #require(tracker.processTranscription(twentyFirst.normalizedText))
    #expect(tracker.currentVerse == 21)

    // Al-Qalam log: while the reciter repeated ayah 20 ('فأصبحت كالصريم'),
    // the garbled decode 'سصبح كالصرير' hit ayah 21's ending stem (مصبحين
    // shares the صبح stem with أصبحت) and falsely advanced to 68:22.
    #expect(tracker.processTranscription("سصبح كالصرير") == nil)
    #expect(tracker.currentSurah == 68)
    #expect(tracker.currentVerse == 21)
}

@Test func trackingCanSwitchSurahOnHighConfidenceGlobalMatchFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)

    _ = try #require(tracker.processTranscription("بسم الله الرحمن الرحيم"))
    _ = try #require(tracker.processTranscription("بِ رَبِّ الْعَالمِينَ"))
    _ = try #require(tracker.processTranscription("بِ الرَّحْمَِ الرَّحِيِ"))

    #expect(tracker.processTranscription("بسم الله الرحمن الرحيم") == nil)

    let switched = try #require(tracker.processTranscription("قُلْ أَعُوذُ بِرَبِّ النَّاسِ"))
    #expect(switched.surahNumber == 114)
    #expect(switched.verseNumber == 1)
}

@Test func endOfSurahSwitchesToDistinctiveNewSurahOpeningWithoutMissDelay() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)

    _ = try #require(tracker.processTranscription("اهدنا الصراط المستقيم"))
    _ = try #require(tracker.processTranscription("صراط الذين انعمت عليهم غير المغضوب عليهم ولا الضالين"))

    let switched = try #require(tracker.processTranscription("ن والقلم وما يسطرون"))

    #expect(switched.surahNumber == 68)
    #expect(switched.verseNumber == 1)
    #expect(tracker.currentSurah == 68)
    #expect(tracker.currentVerse == 1)
}

@Test func lowInformationTrackingNoiseDoesNotLoseCurrentVerse() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("الرحمن الرحيم"))

    for transcription in ["أ", "و", "ل", "شر", "لا", "الم", "أ", "و"] {
        #expect(tracker.processTranscription(transcription) == nil)
    }

    #expect(tracker.mode == .tracking)
    #expect(tracker.currentSurah == 1)
    #expect(tracker.currentVerse == 3)
}

@Test func nearEndRecoveryDoesNotJumpOnGenericBismillah() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 1)

    let first = try #require(tracker.processTranscription("اهدنا الصراط المستقيم"))
    #expect(first.surahNumber == 1)
    #expect(first.verseNumber == 6)

    for _ in 0..<4 {
        #expect(tracker.processTranscription("كتاب الحكمة والمؤمنين") == nil)
    }

    #expect(tracker.mode == .discovery)
    #expect(tracker.surahHint == nil)
    #expect(tracker.processTranscription("بسم الرحمن الرحيمه") == nil)

    let recovered = try #require(tracker.processTranscription("صراط الذين انعمت عليهم غير المغضوب عليهم ولا الضالين"))
    #expect(recovered.surahNumber == 1)
    #expect(recovered.verseNumber == 7)
}

@Test func shortTrackingFragmentMatchesCurrentVerseInsteadOfMissingFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 67)

    let opening = try #require(engine.getVerse(surah: 67, verse: 1))
    _ = try #require(tracker.processTranscription(opening.normalizedText))
    #expect(tracker.currentSurah == 67)
    #expect(tracker.currentVerse == 1)

    // Short tracking windows often decode 2-3 word mid-verse fragments
    // (e.g. 'تبارك الذي'). They must update coverage on the current verse,
    // not accumulate tracking misses until tracking is lost.
    let fragment = opening.normalizedWords.prefix(3).joined(separator: " ")
    _ = tracker.processTranscription(fragment)

    #expect(tracker.mode == .tracking)
    #expect(tracker.currentSurah == 67)
    #expect(tracker.currentVerse == 1)
    #expect(tracker.wordsCovered >= 2)
}

@Test func recoverySpanCoveringMinimumVerseRecommitsWithoutDelayFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 67)

    let first = try #require(engine.getVerse(surah: 67, verse: 1))
    let second = try #require(engine.getVerse(surah: 67, verse: 2))
    _ = try #require(tracker.processTranscription(first.normalizedText))
    _ = try #require(tracker.processTranscription(second.normalizedText))
    #expect(tracker.currentVerse == 2)

    for _ in 0..<4 {
        _ = tracker.processTranscription("نهايةدرس")
    }
    #expect(tracker.mode == .discovery)

    // Recovery audio frequently spans the previous ayah's tail and the lost
    // ayah's start. A span 67:1-2 must re-commit at the recovery minimum (2)
    // instead of being rejected as a stale verse-1 candidate.
    let probe = (first.normalizedWords.suffix(4) + second.normalizedWords.prefix(4))
        .joined(separator: " ")
    let recovered = try #require(tracker.processTranscription(probe))

    #expect(recovered.surahNumber == 67)
    #expect(recovered.verseNumber == 2)
    #expect(tracker.currentSurah == 67)
    #expect(tracker.currentVerse == 2)
}

@Test func sameVerseSpanAdvancesOneAyah() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("بسم الله الرحمن الرحيم"))
    let next = try #require(tracker.processTranscription("بسم الله الرحمن الرحيم الحمد لله رب العالمين"))

    #expect(next.surahNumber == 1)
    #expect(next.verseNumber == 2)
}

@Test func discoveryFindsPartialNewSurahPhraseFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let match = try #require(engine.findBestMatch(
        transcription: "سبحوا لله ما في السم والأ"
    ))

    #expect(match.surahNumber != 1)
    #expect(match.verseNumber == 1)
}

@Test func postCompletionDiscoveryCanSwitchToLaterNewSurahVerse() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("اهدنا الصراط المستقيم"))
    _ = try #require(tracker.processTranscription("صراط الذين انعمت عليهم غير المغضوب عليهم ولا الضالين"))

    for _ in 0..<2 {
        _ = tracker.processTranscription("كتاب الحكمة والمؤمنين")
    }

    #expect(tracker.processTranscription("سبح لله ما في السماوات وما في") == nil)
    let switched = try #require(tracker.processTranscription("وَيُعَلِّبَهُمُ الْْمِتَالَ وَالْحِكْمَ وَإِنْ كَانُوا يُؤْمِِنِينَ"))

    #expect(switched.surahNumber == 62)
    #expect(switched.verseNumber == 2)
}

@Test func postCompletionDiscoveryFindsAlQalamOpeningSpanFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("اهدنا الصراط المستقيم"))
    _ = try #require(tracker.processTranscription("صراط الذين انعمت عليهم غير المغضوب عليهم ولا الضالين"))

    for _ in 0..<2 {
        _ = tracker.processTranscription("كتاب الحكمة والمؤمنين")
    }

    let switched = try #require(tracker.processTranscription("وال وما ينطرون وما أنت ب"))

    #expect(switched.surahNumber == 68)
    #expect(switched.verseNumber == 1)
    #expect(switched.ayahEnd == 2)
}

@Test func nearEndTrackingLossAllowsNewSurahDiscoveryWhenLastAyahWasMissed() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("إياك نعبد وإياك نستعين"))
    _ = try #require(tracker.processTranscription("واياكعينه اهدنا الصراط المستقيم"))

    for _ in 0..<4 {
        _ = tracker.processTranscription("وعد الكتاب والون")
    }

    #expect(tracker.mode == .discovery)
    #expect(tracker.surahHint == nil)

    let switched = try #require(tracker.processTranscription("وال وما ينطرون وما أنت ب"))

    #expect(switched.surahNumber == 68)
    #expect(switched.verseNumber == 1)
    #expect(switched.ayahEnd == 2)
}

@Test func nearEndLowInformationNoiseAllowsNewSurahDiscoveryWhenLastAyahWasMissed() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("إياك نعبد وإياك نستعين"))
    _ = try #require(tracker.processTranscription("واياكعينه اهدنا الصراط المستقيم"))

    for transcription in ["أ", "و", "شر", "يس", "وت", "تن"] {
        #expect(tracker.processTranscription(transcription) == nil)
    }

    #expect(tracker.mode == .discovery)
    #expect(tracker.surahHint == nil)

    let switched = try #require(tracker.processTranscription("وال وما ينطرون وما أنت ب"))

    #expect(switched.surahNumber == 68)
    #expect(switched.verseNumber == 1)
    #expect(switched.ayahEnd == 2)
}

@Test func postCompletionDiscoveryFindsAlQalamMiddleSpanFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("اهدنا الصراط المستقيم"))
    _ = try #require(tracker.processTranscription("صراط الذين انعمت عليهم غير المغضوب عليهم ولا الضالين"))

    for _ in 0..<2 {
        _ = tracker.processTranscription("كتاب الحكمة والمؤمنين")
    }

    let switched = try #require(tracker.processTranscription("أَجَلًا غَيْرَ مَمْْنُونٍ وَإِنَّكَ لَعَلَى خُلُقٍ عَظِيمٍ"))

    #expect(switched.surahNumber == 68)
    #expect(switched.verseNumber == 3)
    #expect(switched.ayahEnd == 4)
}

@Test func ambiguousPostCompletionPhraseDoesNotJumpToWrongSurah() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("اهدنا الصراط المستقيم"))
    _ = try #require(tracker.processTranscription("صراط الذين انعمت عليهم غير المغضوب عليهم ولا الضالين"))

    for _ in 0..<2 {
        _ = tracker.processTranscription("كتاب الحكمة والمؤمنين")
    }

    #expect(tracker.processTranscription("سبيله وهو أعلم بالمهتدين") == nil)
    #expect(tracker.mode == .discovery)
}

// MARK: - Surah 87 (Al-A'la) log regressions

private func driveTracker(
    _ tracker: RecitationTracker,
    engine: QuranVerseMatchingEngine,
    surah: Int,
    through lastVerse: Int
) throws {
    for verse in 1...lastVerse {
        let entry = try #require(engine.getVerse(surah: surah, verse: verse))
        _ = try #require(tracker.processTranscription(entry.normalizedText))
    }
    #expect(tracker.currentVerse == lastVerse)
}

@Test func shortMidVerseFragmentOfLongAyahDoesNotCueNextAyahFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 87)
    try driveTracker(tracker, engine: engine, surah: 87, through: 7)

    // Al-A'la log: the short decode 'إن يعلم' (mid 87:7 '... إنه يعلم الجهر
    // وما يخفى') resolved a forward span 87:8-9 and prematurely cued 87:8.
    // A 7-char fragment must score against the long current ayah with
    // fragment matching, not a length-biased plain ratio.
    #expect(tracker.processTranscription("ان يعلم") == nil)
    #expect(tracker.currentVerse == 7)

    // Real evidence of ayah 8 still advances immediately.
    let eighth = try #require(engine.getVerse(surah: 87, verse: 8))
    let advanced = try #require(tracker.processTranscription(eighth.normalizedText))
    #expect(advanced.verseNumber == 8)
}

@Test func garbledPreviousAyahTailDoesNotAdvanceNoisyContinuationFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 87)
    try driveTracker(tracker, engine: engine, surah: 87, through: 9)

    // Al-A'la log: 'يس قلب يسرى' was a garbled decode of 87:8 ('ونيسرك
    // لليسرى') lingering in the rolling window, yet it fuzzily matched a
    // forward span and advanced the reader to 87:10 prematurely.
    #expect(tracker.processTranscription("يس قلب يسرى") == nil)
    #expect(tracker.currentVerse == 9)
}

@Test func garbageDecodeDoesNotAdvanceViaForwardSpanFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 87)
    try driveTracker(tracker, engine: engine, surah: 87, through: 10)

    // Al-A'la log: 'ساعتين ذكرى سنكر' (garbage around 87:9-10) resolved a
    // span 87:11-12 and cued 87:11 while the reciter was still on 87:10.
    #expect(tracker.processTranscription("ساعتين ذكرى سنكر") == nil)
    #expect(tracker.currentVerse == 10)
}

@Test func recoveryAfterLossInLongSurahDoesNotCommitFarAheadOnGenericPhrases() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 2)
    try driveTracker(tracker, engine: engine, surah: 2, through: 4)

    // Force a tracking loss at 2:4.
    for _ in 0..<4 {
        _ = tracker.processTranscription("نهايةدرس مجهولة كلمات")
    }
    #expect(tracker.mode == .discovery)

    // Al-Baqarah replay: after a loss near 2:4, generic windows (from the
    // 2:5 region audio) fuzzily matched verses deep in the surah and the
    // hinted recovery committed there (observed 2:4 -> 2:244 in the replay
    // fixture). Short, weak, or ambiguous evidence must never recover far
    // ahead of the loss point.
    for generic in ["من ربهم وهداه", "ال العالمين", "اولئك هم المفلحون", "ان الله سميع عليم"] {
        _ = tracker.processTranscription(generic)
        if tracker.mode == .tracking {
            #expect(tracker.currentSurah == 2)
            let verse = try #require(tracker.currentVerse)
            #expect(verse <= 10, "far recovery commit at 2:\(verse) from generic '\(generic)'")
        }
    }

    // Distinct evidence of the verse right after the loss point still
    // recovers promptly.
    let fifth = try #require(engine.getVerse(surah: 2, verse: 5))
    _ = tracker.processTranscription(fifth.normalizedText)
    #expect(tracker.mode == .tracking)
    #expect(tracker.currentSurah == 2)
    let recovered = try #require(tracker.currentVerse)
    #expect((4...6).contains(recovered), "recovered at 2:\(recovered) instead of near 2:4")
}

@Test func noisyNextAyahEvidenceStillAdvancesPromptlyFromLog() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine, surahHint: 87)
    try driveTracker(tracker, engine: engine, surah: 87, through: 4)

    // Al-A'la log: 'وسوات أحوى' (noisy 87:5 'فجعله غثاء أحوى') advanced the
    // reader promptly. The staleness guards must only block windows that the
    // current or previous ayah explains better, never real forward evidence.
    let advanced = try #require(tracker.processTranscription("وسوات احوى"))
    #expect(advanced.surahNumber == 87)
    #expect(advanced.verseNumber == 5)
}
