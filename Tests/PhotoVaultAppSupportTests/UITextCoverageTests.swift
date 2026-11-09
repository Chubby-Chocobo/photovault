import Foundation
import Testing

/// Interface text is written as `tr(vi: "…", en: "…")`. A Vietnamese string literal anywhere else in
/// UI code would show Vietnamese in the English interface, so this scan fails on one. A line ending in
/// `// l10n: verbatim` is exempt (a language's own name, a letter used for search folding).
struct UITextCoverageTests {
    static let scannedFolders = ["PhotoVault", "Sources/PhotoVaultAppSupport", "Sources/PhotoVaultEngine"]

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Until every UI string is a pair, run it on demand with `PV_L10N_SCAN=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PV_L10N_SCAN"] == "1"))
    func noVietnameseLiteralOutsideATranslationPair() throws {
        var offenders: [String] = []
        for folder in Self.scannedFolders {
            let base = Self.repositoryRoot.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                let relative = url.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
                offenders += UntranslatedLiteralScanner.offenders(in: source).map { "\(relative):\($0.line): \($0.text)" }
            }
        }
        #expect(offenders.isEmpty, "Vietnamese text outside tr(vi:en:):\n\(offenders.joined(separator: "\n"))")
    }

    @Test func theScannerFindsBareLiteralsOnly() {
        let source = #"""
        let a = tr(vi: "Chờ \(n ?? "không")", en: "Pending")
        let b = "Đang chạy"
        // "Bình luận" in a comment
        let c = "Tiếng Việt" // l10n: verbatim
        let d = tr(vi:
            "Xuống dòng", en: "Next line")
        let e = "plain ASCII"
        /* "khối bình luận" */ let f = "Lỗi"
        """#
        let found = UntranslatedLiteralScanner.offenders(in: source)
        #expect(found.map(\.line) == [2, 8])
        #expect(found.map(\.text) == ["Đang chạy", "Lỗi"])
    }
}

/// A small Swift lexer: finds top-level string literals (nested ones inside interpolations belong to
/// their enclosing literal), skips comments, and reports literals with Vietnamese letters that are
/// not the argument of `vi:`.
enum UntranslatedLiteralScanner {
    struct Offender: Equatable { var line: Int; var text: String }

    static func offenders(in source: String) -> [Offender] {
        let chars = Array(source)
        let lines = source.components(separatedBy: "\n")
        var result: [Offender] = []
        var i = 0
        var line = 1
        var previousToken = ""  // the last non-space code before a literal, to see `vi:`
        func exempt(_ line: Int) -> Bool { line - 1 < lines.count && lines[line - 1].hasSuffix("// l10n: verbatim") }
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { line += 1; i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { if chars[i] == "\n" { line += 1 }; i += 1 }
                i += 2
                continue
            }
            if c == "\"" {
                let startLine = line
                let (text, end, newlines) = readLiteral(chars, from: i)
                let covered = previousToken.hasSuffix("vi:")
                if !covered, containsVietnamese(text), !exempt(startLine) {
                    result.append(Offender(line: startLine, text: text))
                }
                line += newlines
                i = end
                previousToken = "\""
                continue
            }
            if !c.isWhitespace { previousToken = String((previousToken + String(c)).suffix(8)) }
            i += 1
        }
        return result
    }

    /// Reads a literal starting at `start` (a quote); returns its text, the index after it and the
    /// newlines it spans. Handles `"""`, escapes and nested literals in `\( … )`.
    private static func readLiteral(_ chars: [Character], from start: Int) -> (String, Int, Int) {
        let multiline = start + 2 < chars.count && chars[start + 1] == "\"" && chars[start + 2] == "\""
        var i = start + (multiline ? 3 : 1)
        var text = ""
        var newlines = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { newlines += 1 }
            if c == "\\", i + 1 < chars.count {
                if chars[i + 1] == "(" {
                    var depth = 1
                    i += 2
                    while i < chars.count, depth > 0 {
                        if chars[i] == "\"" {
                            let (nested, end, inner) = readLiteral(chars, from: i)
                            text += nested
                            newlines += inner
                            i = end
                            continue
                        }
                        if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1 } else if chars[i] == "\n" { newlines += 1 }
                        i += 1
                    }
                    continue
                }
                text.append(chars[i + 1])
                i += 2
                continue
            }
            if multiline {
                if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" { return (text, i + 3, newlines) }
            } else if c == "\"" {
                return (text, i + 1, newlines)
            }
            text.append(c)
            i += 1
        }
        return (text, i, newlines)
    }

    private static let vietnameseLetters = Set("àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ")

    static func containsVietnamese(_ text: String) -> Bool {
        text.lowercased().contains { vietnameseLetters.contains($0) }
    }
}
