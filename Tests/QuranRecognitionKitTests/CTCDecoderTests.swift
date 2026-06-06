import Testing
@testable import QuranRecognitionKit

@Test func greedyCTCDecodingCollapsesRepeatsAndRemovesBlank() {
    let decoder = CTCDecoder(vocab: [
        0: "ا",
        1: "ل",
        2: "\u{2581}له",
        3: "<blank>"
    ])

    let rows: [[Float]] = [
        [10, 0, 0, 0],
        [9, 0, 0, 0],
        [0, 0, 0, 8],
        [0, 10, 0, 0],
        [0, 9, 0, 0],
        [0, 0, 10, 0]
    ]

    #expect(decoder.decode(logProbs: rows) == "ال له")
}
