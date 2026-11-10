import Foundation
import Testing
@testable import PhotoVaultAppSupport
import PhotoVaultCore

@Suite struct ImportLocationShortenerTests {
    func short(_ path: String, _ budget: Int) -> String { ImportLocationShortener.shorten(path, budget: budget) }

    @Test func aShortPathIsUnchanged() {
        #expect(short("~/Pictures/2024", 60) == "~/Pictures/2024")
        #expect(short("/", 5) == "/")
        #expect(short("~", 1) == "~")
    }

    @Test func aLongChainKeepsRootAndLastAndAsManyParentsAsFit() {
        #expect(short("My Drive/Trips/Europe/Summer/Day 2", 24) == "My Drive/…/Summer/Day 2")
        #expect(short("My Drive/Trips/Europe/Summer/Day 2", 18) == "My Drive/…/Day 2")
        #expect(short("~/Pictures/Trips/Đà Lạt 2023/Ngày 2", 27) == "~/…/Đà Lạt 2023/Ngày 2")
    }

    @Test func rootsAreKept() {
        #expect(short("/Volumes/NAS/Photos/Trips/Europe/2024", 26) == "/Volumes/NAS/…/Europe/2024")
        #expect(short("/Volumes/NAS/Photos/Trips/Europe/2024", 20) == "/Volumes/NAS/…/2024")
        #expect(short("/Camera Uploads/Trips/Europe/2024", 13) == "/…/2024")
        #expect(short("Shared with me/Holiday/Day 1/Raw", 24) == "Shared with me/…/Raw")
    }

    @Test func aVeryLongLastNameIsMiddleTruncatedKeepingItsStartAndEnd() {
        let last = "Chuyến đi Đà Lạt cùng gia đình vào tháng 12 năm 2023"
        let result = short("~/Pictures/\(last)", 46)
        #expect(result.hasPrefix("~/…/Chuyến đi"))
        #expect(result.hasSuffix("năm 2023"))
        #expect(result.contains("…"))
        #expect(result.count <= 46)
    }

    @Test func aSingleComponentIsTruncatedInTheMiddleToo() {
        let result = short(String(repeating: "a", count: 30) + String(repeating: "z", count: 30), 20)
        #expect(result.count <= 20)
        #expect(result.hasPrefix("aaa") && result.hasSuffix("zzz") && result.contains("…"))
    }

    @Test func graphemeClustersAreNeverSplit() {
        let decomposed = "Ngay\u{0302} đẹp ✈️ 👨‍👩‍👧‍👦 שלום עולם " + String(repeating: "é", count: 40)
        for budget in 8...40 {
            let result = short("~/x/\(decomposed)", budget)
            // Every character of the result must come whole from the input.
            let allowed = Set(decomposed.map { $0 } + Array("~/…x"))
            #expect(result.allSatisfy { allowed.contains($0) }, "budget \(budget): \(result)")
        }
    }

    @Test func variantsGetShorterAndDifferAndEndWithTheLast() {
        let variants = ImportLocationShortener.variants("My Drive/Trips/Europe/Summer/Day 2", budgets: [80, 60, 24, 18])
        #expect(variants == ["My Drive/Trips/Europe/Summer/Day 2", "My Drive/…/Summer/Day 2", "My Drive/…/Day 2"])
    }

    @Test func theOthersLabelSurvivesShortening() {
        let location = ImportLocation(paths: ["My Drive/Trips/Europe/Summer/Day 2", "My Drive/Other"], othersCount: 4)
        let shown = L10n.$override.withValue(.vi) { ImportLocationText.display(location, budget: 18) }
        #expect(shown.path == "My Drive/…/Day 2")
        #expect(shown.others == "+4 mục khác")
    }

    @Test func copyTitle() {
        L10n.$override.withValue(.en) { #expect(ImportLocationText.copyTitle == "Copy path") }
    }
}
