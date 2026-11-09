import Foundation
import Testing
@testable import PhotoVaultCore

struct LocalizationTests {
    @Test func textFollowsThePinnedLanguage() {
        L10n.$override.withValue(.vi) { #expect(tr(vi: "Chờ", en: "Pending") == "Chờ") }
        L10n.$override.withValue(.en) { #expect(tr(vi: "Chờ", en: "Pending") == "Pending") }
    }

    @Test func vietnameseIsTheDefault() {
        #expect(L10n.current == .vi)
        #expect(tr(vi: "Chờ", en: "Pending") == "Chờ")
    }

    @Test func aPinnedLanguageStaysInItsTask() async {
        await L10n.$override.withValue(.en) {
            await withTaskGroup(of: AppLanguage.self) { group in
                group.addTask { L10n.language }
                for await language in group { #expect(language == .en, "child tasks inherit the pin") }
            }
        }
        let outside = await Task.detached { L10n.override }.value
        #expect(outside == nil)
    }

    @Test(arguments: [
        (["vi-VN", "en-US"], AppLanguage.vi), (["vi"], .vi), (["en-US", "vi-VN"], .en), ([], .en), (["fr-FR"], .en),
    ])
    func systemFollowsTheFirstPreferredLanguage(_ preferred: [String], _ expected: AppLanguage) {
        #expect(InterfaceLanguageChoice.system.resolved(preferredLanguages: preferred) == expected)
        #expect(InterfaceLanguageChoice.vi.resolved(preferredLanguages: preferred) == .vi)
        #expect(InterfaceLanguageChoice.en.resolved(preferredLanguages: preferred) == .en)
    }

    @Test func englishPlurals() {
        #expect(L10n.plural(1, one: "1 file", other: "1 files") == "1 file")
        #expect(L10n.plural(0, one: "0 file", other: "0 files") == "0 files")
        #expect(L10n.plural(5, one: "5 file", other: "5 files") == "5 files")
    }

    @Test func destinationFolderNamesIgnoreTheInterfaceLanguage() {
        let layout = DynamicLayout()
        let day = ArchiveDay(year: 2026, month: 11, day: 8)!
        func names(_ language: AppLanguage) -> [String] {
            L10n.$override.withValue(language) {
                let placements = [AssetCategory.camera, .screenshot, .saved].map { Placement(category: $0, day: .day(day), nameStem: "x") }
                    + [Placement(category: .camera, day: .unknown, nameStem: "x")]
                let files = placements.flatMap { layout.folderChain(for: $0, dayPromoted: true, placeName: "Đà Lạt").map(\.displayName) }
                let views = [ViewPath.byDevice(groupKey: "k", groupName: "Sony A7 IV", day: day), .favorites(day: day)]
                    .flatMap { layout.viewFolderChain($0).map(\.displayName) }
                return files + views
            }
        }
        #expect(names(.vi) == names(.en))
        #expect(names(.en).contains("Screenshots") && names(.en).contains("By device") && names(.en).contains("Unknown date"))
    }
}
