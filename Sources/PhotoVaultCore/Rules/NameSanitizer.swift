import Foundation

/// File and folder name normalization (FR-42), applied to every name component the app writes:
/// file stems, place names, device-group names.
public enum NameSanitizer {
    public static let maxStemBytes = 120
    public static let maxComponentBytes = 240
    static let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

    /// NFC, forbidden and control characters → `_`, format/bidi characters removed, trailing dots
    /// and spaces removed, truncated to `maxBytes` UTF-8 bytes at a grapheme boundary.
    public static func sanitize(_ input: String, maxBytes: Int = maxComponentBytes) -> String {
        var out = ""
        for scalar in input.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .format:
                continue
            case .control, .lineSeparator, .paragraphSeparator:
                out.unicodeScalars.append("_")
            default:
                if forbidden.contains(Character(scalar)) { out.unicodeScalars.append("_") } else { out.unicodeScalars.append(scalar) }
            }
        }
        out = truncate(out.precomposedStringWithCanonicalMapping, maxBytes: maxBytes)
        while let last = out.last, last == "." || last == " " { out.removeLast() }
        return out.isEmpty ? "_" : out
    }

    /// Longest prefix of whole grapheme clusters that fits in `maxBytes` UTF-8 bytes.
    public static func truncate(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var result = ""
        var used = 0
        for character in value {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        return result
    }

    /// Key used for name collision detection: lowercased NFC.
    public static func collisionKey(_ stem: String) -> String {
        stem.precomposedStringWithCanonicalMapping.lowercased()
    }
}
