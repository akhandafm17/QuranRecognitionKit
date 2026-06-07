import Foundation

public enum ArabicNormalizer {
    private static let normalizationMap: [UInt32: UInt32] = [
        0x0622: 0x0627,
        0x0623: 0x0627,
        0x0625: 0x0627,
        0x0671: 0x0627,
        0x0629: 0x0647,
        0x0649: 0x064A
    ]

    public static func normalize(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0xFEFF || isArabicDiacriticOrTatweel(value) {
                continue
            }
            if isSeparatorOrPunctuation(scalar) {
                result.append(" ")
                continue
            }

            if let mapped = normalizationMap[value], let normalizedScalar = UnicodeScalar(mapped) {
                result.unicodeScalars.append(normalizedScalar)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }

        return result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func words(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    private static func isArabicDiacriticOrTatweel(_ value: UInt32) -> Bool {
        switch value {
        case 0x0610...0x061A,
             0x064B...0x065F,
             0x0670,
             0x06D6...0x06DC,
             0x06DF...0x06E4,
             0x06E7...0x06E8,
             0x06EA...0x06ED,
             0x0640:
            return true
        default:
            return false
        }
    }

    private static func isSeparatorOrPunctuation(_ scalar: UnicodeScalar) -> Bool {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return true
        }
        if CharacterSet.punctuationCharacters.contains(scalar) ||
            CharacterSet.symbols.contains(scalar) {
            return true
        }
        return false
    }
}
