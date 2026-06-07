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

@Test func completedShortAyahEmitsAutoAdvancedNextAyah() throws {
    let engine = try QuranVerseMatchingEngine.loadBundled()
    let tracker = RecitationTracker(matchingEngine: engine)

    _ = try #require(tracker.processTranscription("الرحمن الرحيم"))
    let next = try #require(tracker.processTranscription("الرَّحْمَنِ الرَّحِيمِ"))

    #expect(next.surahNumber == 1)
    #expect(next.verseNumber == 4)
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
