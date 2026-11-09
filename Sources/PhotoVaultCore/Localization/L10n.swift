import Foundation
import os

/// The interface language for text built anywhere in the app. The app sets `current` at launch and
/// when the owner switches; tests pin a language for one task with `L10n.$override.withValue(.en)`
/// and never change `current`, so parallel tests cannot see each other's language.
public enum L10n {
    private static let storage = OSAllocatedUnfairLock(initialState: AppLanguage.vi)

    /// The process-wide language. Vietnamese until the app applies the owner's choice.
    public static var current: AppLanguage {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// A language pinned for the current task and its child tasks.
    @TaskLocal public static var override: AppLanguage?

    /// The language text is built in right now.
    public static var language: AppLanguage { override ?? current }

    /// The English form of a count: `plural(1, one: "1 file", other: "3 files")`.
    public static func plural(_ count: Int, one: String, other: String) -> String {
        count == 1 ? one : other
    }

    /// `48210` -> `"48.210"` in Vietnamese, `"48,210"` in English.
    public static func integer(_ value: Int) -> String {
        let separator: Character = language == .vi ? "." : ","
        let digits = String(value.magnitude)
        var grouped = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { grouped.append(separator) }
            grouped.append(character)
        }
        return (value < 0 ? "-" : "") + String(grouped.reversed())
    }
}

/// Interface text in both languages; returns the one for `L10n.language`. The Vietnamese side is the
/// original wording of the app.
public func tr(vi: String, en: String) -> String {
    L10n.language == .vi ? vi : en
}
