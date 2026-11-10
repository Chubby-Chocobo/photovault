import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct LensViewRulesTests {
    let day = ArchiveDay(year: 2025, month: 3, day: 1)!

    private func asset(lens: String?, category: AssetCategory? = .camera, deleted: Bool = false) -> AssetRecord {
        var record = PolicyFixtures.asset("l:L", category: category, make: "Apple", model: "iPhone 15 Pro", deleted: deleted)
        record.lensModel = lens
        return record
    }

    @Test func appleBackCameraNamesLoseTheCameraWords() {
        #expect(LensNameResolver.name(for: "iPhone 15 Pro back triple camera 6.86mm f/1.78") == "iPhone 15 Pro 6.86mm f/1.78")
        #expect(LensNameResolver.name(for: "iPhone 12 back camera 4.2mm f/1.6") == "iPhone 12 4.2mm f/1.6")
        #expect(LensNameResolver.name(for: "iPhone 15 Pro back dual wide camera 5.7mm f/1.6") == "iPhone 15 Pro 5.7mm f/1.6")
    }

    @Test func appleFrontCameraKeepsFront() {
        #expect(LensNameResolver.name(for: "iPhone 15 Pro front camera 2.69mm f/1.9") == "iPhone 15 Pro front 2.69mm f/1.9")
    }

    @Test func otherLensesAreOnlyTidied() {
        #expect(LensNameResolver.name(for: "  FE 24-70mm   F2.8 GM \n") == "FE 24-70mm F2.8 GM")
        #expect(LensNameResolver.name(for: "Wide") == "Wide")
    }

    @Test func blankLensHasNoName() {
        #expect(LensNameResolver.name(for: nil) == nil)
        #expect(LensNameResolver.name(for: " \t ") == nil)
    }

    @Test func variantsShareOneKey() {
        #expect(LensNameResolver.key(for: "FE 24-70mm F2.8 GM") == LensNameResolver.key(for: " fe  24-70MM f2.8 gm "))
        #expect(LensNameResolver.key(for: "FE 24-70mm F2.8 GM") != LensNameResolver.key(for: "FE 50mm F1.8"))
        #expect(LensNameResolver.key(for: "iPhone 15 Pro back triple camera 6.86mm f/1.78")
                == LensNameResolver.key(for: "iPhone 15 Pro  back  camera 6.86mm f/1.78"))
    }

    @Test func pathUsesNormalisedNameAndKey() throws {
        let path = try #require(ViewRules.path(for: asset(lens: "iPhone 15 Pro back triple camera 6.86mm f/1.78"), in: .byLens, context: ViewContext()))
        #expect(path == .byLens(groupKey: LensNameResolver.key(for: "iPhone 15 Pro 6.86mm f/1.78")!, lensName: "iPhone 15 Pro 6.86mm f/1.78", day: day))
        #expect(path.view == .byLens)
    }

    @Test func membershipNeedsCameraCategoryAndLens() {
        #expect(ViewRules.path(for: asset(lens: nil), in: .byLens, context: ViewContext()) == nil)
        #expect(ViewRules.path(for: asset(lens: "  "), in: .byLens, context: ViewContext()) == nil)
        #expect(ViewRules.path(for: asset(lens: "Wide", category: .saved), in: .byLens, context: ViewContext()) == nil)
        #expect(ViewRules.path(for: asset(lens: "Wide", deleted: true), in: .byLens, context: ViewContext()) != nil, "a deleted photo keeps its shortcut")
        #expect(ViewRules.paths(for: asset(lens: "Wide"), context: ViewContext()).contains { $0.view == .byLens })
    }

    @Test func layoutChainIsViewLensDay() {
        let chain = DynamicLayout().viewFolderChain(.byLens(groupKey: "k1", lensName: "FE 24-70mm F2.8/GM", day: day))
        #expect(chain.map(\.displayName) == ["By lens", "FE 24-70mm F2.8_GM", "2025-03-01"])
        #expect(chain.map(\.logicalPath) == ["view/byLens", "view/byLens/k1", "view/byLens/k1/2025-03-01"])
    }

    @Test func settingIsOffByDefault() {
        #expect(GlobalSettings().viewByLensEnabled == false)
    }
}
