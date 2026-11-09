# 0022 Interface languages: Vietnamese and English as inline text pairs, switched live

- **Status:** Accepted
- **Spec refs:** issue #11; FR-82 and FR-106 (place-name language, unchanged); FR-40 (destination layout, unchanged)
- **Review trigger:** a third interface language, or the owner wanting one language setting for both the interface and place names

## Context

Issue #11 asks for the interface in Vietnamese and English with a way to switch. The interface was written in Vietnamese. A plan audit tested two assumptions on the build toolchain (Swift 6.3, Xcode 26):

- `swift test` copies a String Catalog (`.xcstrings`) into the module bundle without compiling it, so package catalogs never resolve in package tests or CI. Only `xcodebuild` compiles them.
- The app holds a non-blocking single-instance lock (`InstanceLock`). A "restart to apply" flow starts the new instance while the old one still holds the lock, so it can end with no instance running.

## Decision

- **Text pairs in code.** Every interface string is `tr(vi: "…", en: "…")` (`Sources/PhotoVaultCore/Localization/L10n.swift`). The Vietnamese side is the original wording, byte for byte. English counts use `L10n.plural` with the raw count.
- **One language value.** `L10n.current` (default Vietnamese) is set by the app at launch and when the owner switches; `L10n.$override` (a task-local) pins a language inside a test, so parallel tests never see each other's language.
- **Live switch.** Settings → General → Interface language: System, Tiếng Việt, English. The choice is stored in `UserDefaults` (`PVInterfaceLanguage`), needed before the database opens. Windows and the menu re-render at once. "System" means Vietnamese when the Mac's first preferred language is Vietnamese, else English.
- **Never localized:** anything written to destinations (root and view folder names, `Screenshots`, `Saved`, day and place folders, sidecars), the place-name language (its own setting, because changing it renames folders on every destination), logs.
- **Guard:** `UITextCoverageTests` fails on a Vietnamese string literal in `PhotoVault/`, `Sources/PhotoVaultAppSupport/` or `Sources/PhotoVaultEngine/` that is not the `vi:` argument of a pair (a line ending `// l10n: verbatim` is exempt).

## Alternatives

- String Catalogs in the app target and `.strings` files in the packages: two mechanisms, keys maintained by hand in the packages, and a missing key silently shows the source language.
- English as the source language: every literal changes, and a key missed in the catalog shows English to a Vietnamese user with no check able to catch it.
- Restart to switch: fights the instance lock (above).

## Consequences

- A translation cannot go missing, and the Vietnamese interface stays exactly as it was.
- `VietnameseFormat` keeps its name; its digit grouping follows the interface language (`1.234` / `1,234`).
- Activity events are written in the language active when they happen; older events keep theirs.
- The Photos permission text in `Info.plist` holds both languages, because macOS shows it before the app picks one.
- Adding a third language means touching every pair; revisit this decision then.
