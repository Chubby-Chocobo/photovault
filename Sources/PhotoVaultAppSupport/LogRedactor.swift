import Foundation

/// Last line of defense for logs (NFR-06, NFR-07): a message that looks like it carries a token,
/// a session URL, a file name, a path, coordinates or an e-mail address is replaced entirely.
/// Callers are expected to log asset keys and job IDs only; this catches mistakes.
public enum LogRedactor {
    public enum Verdict: Equatable, Sendable {
        case clean
        case withheld(reason: String)
    }

    private static let patterns: [(name: String, expression: NSRegularExpression)] = {
        let sources: [(String, String)] = [
            ("access token", #"ya29\.[A-Za-z0-9_\-]{10,}"#),
            ("refresh token", #"\b1//[A-Za-z0-9_\-]{20,}"#),
            ("client secret", #"GOCSPX-[A-Za-z0-9_\-]+"#),
            ("bearer token", #"(?i)\bbearer\s+[A-Za-z0-9._\-]{8,}"#),
            ("jwt", #"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]*"#),
            ("session url", #"(?i)upload_id=|uploadType=resumable|googleapis\.com/upload"#),
            ("path", #"(?:file://|/Users/|/Volumes/|/private/|~/)"#),
            ("file name", #"(?i)\.(?:heic|heif|jpe?g|png|gif|tiff?|webp|dng|arw|cr[23]|nef|raf|orf|rw2|mov|mp4|m4v|aae|xmp)\b"#),
            ("coordinates", #"-?\d{1,3}\.\d{4,}\s*[,;]\s*-?\d{1,3}\.\d{4,}"#),
            ("e-mail", #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
        ]
        return sources.compactMap { name, source in
            (try? NSRegularExpression(pattern: source)).map { (name, $0) }
        }
    }()

    public static func inspect(_ message: String) -> Verdict {
        let range = NSRange(message.startIndex..., in: message)
        for (name, expression) in patterns where expression.firstMatch(in: message, options: [], range: range) != nil {
            return .withheld(reason: name)
        }
        return .clean
    }

    /// The text that is safe to write.
    public static func sanitized(_ message: String) -> String {
        switch inspect(message) {
        case .clean: message
        case .withheld(let reason): "[message withheld: contains \(reason)]"
        }
    }
}
