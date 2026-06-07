import Testing
@testable import QuranRecognitionKit

@Test func arabicNormalizationStripsMarksAndNormalizesLetters() {
    let text = "إِيَّاكَ نَعْبُدُ وَإِيَّاكَ نَسْتَعِينُ"
    #expect(ArabicNormalizer.normalize(text) == "اياك نعبد واياك نستعين")
}

@Test func arabicNormalizationCollapsesWhitespaceAndBom() {
    let text = "\u{FEFF}  بِسْمِ   ٱللَّهِ  "
    #expect(ArabicNormalizer.normalize(text) == "بسم الله")
}

@Test func arabicNormalizationStripsPunctuation() {
    #expect(ArabicNormalizer.normalize("ما عليك اليوم؟") == "ما عليك اليوم")
}
