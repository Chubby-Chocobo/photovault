import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct SplitDayLayoutTests {
    let layout = DynamicLayout()
    let day = ArchiveDay(year: 2026, month: 11, day: 8)!
    let slot = "p0123456789ab"

    @Test(arguments: [nil, "Đà Lạt"] as [String?])
    func nilSlotMatchesTheSlotlessChain(name: String?) {
        let placements = [
            Placement(category: .camera, day: .day(day), nameStem: "x"),
            Placement(category: .camera, day: .unknown, nameStem: "x"),
            Placement(category: .screenshot, day: .day(day), nameStem: "x"),
            Placement(category: .saved, day: .unknown, nameStem: "x"),
        ]
        for placement in placements {
            #expect(layout.folderChain(for: placement, placeName: name, slot: nil) == layout.folderChain(for: placement, placeName: name))
        }
    }

    @Test func slotGivesSiblingPathAndPlaceDisplayName() {
        let chain = layout.folderChain(for: Placement(category: .camera, day: .day(day), nameStem: "x"), placeName: "Ninh Bình", slot: slot)
        #expect(chain == [
            FolderLevel(logicalPath: "camera", displayName: "Camera Uploads"),
            FolderLevel(logicalPath: "camera/2026-11-08@p0123456789ab", displayName: "2026-11-08 Ninh Bình"),
        ])
        let bare = layout.folderChain(for: Placement(category: .camera, day: .day(day), nameStem: "x"), placeName: nil, slot: slot)
        #expect(bare.last?.displayName == "2026-11-08")
    }

    @Test func screenshotSavedAndUnknownIgnoreTheSlot() {
        for placement in [
            Placement(category: .screenshot, day: .day(day), nameStem: "x"),
            Placement(category: .saved, day: .day(day), nameStem: "x"),
            Placement(category: .camera, day: .unknown, nameStem: "x"),
        ] {
            #expect(layout.folderChain(for: placement, placeName: "X", slot: slot) == layout.folderChain(for: placement, placeName: "X"))
        }
    }

    @Test func slotPathIsNotADay() {
        #expect(DynamicLayout.slotLogicalPath(day: day, slot: slot) == "camera/2026-11-08@p0123456789ab")
        #expect(ArchiveDay(string: "2026-11-08@p0123456789ab") == nil)
    }

    @Test func parseCameraDayRoundTripsAndRejectsMalformedSlots() {
        let plain = DynamicLayout.parseCameraDay("camera/2026-11-08")
        #expect(plain?.day == day && plain?.slot == nil)
        let slotted = DynamicLayout.parseCameraDay(DynamicLayout.slotLogicalPath(day: day, slot: slot))
        #expect(slotted?.day == day && slotted?.slot == slot)
        let recovered = DynamicLayout.parseCameraDay("camera/2026-11-08@rabcdef012345678")
        #expect(recovered?.slot == "rabcdef012345678")
        for bad in ["camera/2026-11-08@x", "camera/2026-11-08@p12", "camera/2026-11-08@", "camera/2026-11-08@pXYZ456789abc",
                    "camera/2026-11-08@P0123456789ab", "screenshot/2026-11-08", "camera/2026-11-08/x", "camera/unknown"] {
            #expect(DynamicLayout.parseCameraDay(bad) == nil, "\(bad)")
        }
    }
}
