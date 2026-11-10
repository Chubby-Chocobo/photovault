import PhotoVaultCore
import Testing
@testable import PhotoVaultEngine

/// Reading day folders back from a destination (recovery) uses the same shapes `DynamicLayout` writes.
@Suite struct DayFolderRecoveryParsingTests {
    @Test func aLocalCameraDayFolderIsReadBackWithItsPlaceName() throws {
        let info = try #require(LocalTreeInterpreter.folder(displayPath: "Camera Uploads/2026-11-08 Đà Lạt"))
        #expect(info.logicalPath == "camera/2026-11-08")
        #expect(info.day == ArchiveDay(year: 2026, month: 11, day: 8))
        #expect(info.placeName == "Đà Lạt")
        let plain = try #require(LocalTreeInterpreter.folder(displayPath: "Camera Uploads/2026-11-08"))
        #expect(plain.logicalPath == "camera/2026-11-08" && plain.placeName == nil)
    }

    @Test func branchAndOtherDayFoldersAreReadBack() throws {
        #expect(LocalTreeInterpreter.folder(displayPath: "Camera Uploads")?.logicalPath == "camera")
        #expect(LocalTreeInterpreter.folder(displayPath: "Camera Uploads/Unknown date")?.logicalPath == "camera/unknown")
        #expect(LocalTreeInterpreter.folder(displayPath: "Screenshots/2026-11-08")?.logicalPath == "screenshot/2026-11-08")
        #expect(LocalTreeInterpreter.folder(displayPath: "Saved/2026-11-08")?.logicalPath == "saved/2026-11-08")
        #expect(LocalTreeInterpreter.folder(displayPath: "Holiday photos") == nil, "not ours")
    }

    @Test func aDriveDayFolderYieldsItsDayAndPlace() {
        let (day, slot, place) = RemoteInventoryLoader.dayFolder(logical: "camera/2026-11-08", name: "2026-11-08 Đà Lạt")
        #expect(day == ArchiveDay(year: 2026, month: 11, day: 8) && slot == nil && place == "Đà Lạt")
        #expect(RemoteInventoryLoader.dayFolder(logical: "camera/2026-11-08", name: "2026-11-08").2 == nil)
        #expect(RemoteInventoryLoader.dayFolder(logical: "screenshot/2026-11-08", name: "2026-11-08").0 == nil)
    }

    @Test func aDriveSlotFolderYieldsItsDaySlotAndPlace() {
        let (day, slot, place) = RemoteInventoryLoader.dayFolder(logical: "camera/2026-11-08@p0123456789ab", name: "2026-11-08 Ninh Bình")
        #expect(day == ArchiveDay(year: 2026, month: 11, day: 8))
        #expect(slot == "p0123456789ab" && place == "Ninh Bình")
    }

    @Test func aMalformedSlotIsNotADayFolder() {
        #expect(RemoteInventoryLoader.dayFolder(logical: "camera/2026-11-08@bad", name: "2026-11-08 X").0 == nil)
        #expect(RemoteInventoryLoader.dayFolder(logical: "camera/2026-11-08@p12", name: "2026-11-08 X").0 == nil)
    }
}
