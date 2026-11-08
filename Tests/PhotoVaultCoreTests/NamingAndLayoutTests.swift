import Foundation
import Testing
@testable import PhotoVaultCore
import PhotoVaultTestSupport

@Suite struct NamingAndLayoutTests {
    let tz = TimeZone(identifier: "Asia/Ho_Chi_Minh")!

    @Test(arguments: [
        ("a/b\\c:d*e?f\"g<h>i|j", "a_b_c_d_e_f_g_h_i_j"),
        ("trailing. . ", "trailing"),
        ("tab\there", "tab_here"),
        ("bidi\u{202E}gpj.exe", "bidigpj.exe"),
        ("zero\u{200B}width", "zerowidth"),
        ("", "_"),
    ])
    func sanitizes(input: String, expected: String) {
        #expect(NameSanitizer.sanitize(input) == expected)
    }

    @Test func normalizesToNFC() {
        let decomposed = "Đa\u{0300} La\u{0323}t"
        let result = NameSanitizer.sanitize(decomposed)
        #expect(result == "Đà Lạt")
        #expect(result.unicodeScalars.count == "Đà Lạt".precomposedStringWithCanonicalMapping.unicodeScalars.count)
    }

    @Test func truncatesByBytesAtGraphemeBoundary() {
        let long = String(repeating: "ệ", count: 100)
        let cut = NameSanitizer.sanitize(long, maxBytes: 120)
        #expect(cut.utf8.count <= 120)
        #expect(cut.allSatisfy { $0 == "ệ" })
        let emoji = String(repeating: "👨‍👩‍👧", count: 20)
        let cutEmoji = NameSanitizer.truncate(emoji, maxBytes: 50)
        #expect(cutEmoji.utf8.count <= 50)
        #expect(cutEmoji.allSatisfy { $0 == "👨‍👩‍👧" })
    }

    @Test func buildsDatedStemInArchiveTimezone() {
        let builder = NameStemBuilder(timeZone: tz, utiResolver: FakeUTIResolver())
        let date = ISO8601DateFormatter().date(from: "2026-11-08T07:03:22Z")!
        #expect(builder.baseStem(creationDate: date, primaryFilename: "IMG_4821.HEIC") == "2026-11-08 14.03.22_IMG_4821")
        #expect(builder.baseStem(creationDate: nil, primaryFilename: "IMG_1.JPG") == "undated_IMG_1")
    }

    @Test func collisionSuffixIgnoresCase() {
        let taken: Set<String> = [NameSanitizer.collisionKey("2026-11-08 09.15.40_IMG_0001")]
        #expect(NameStemBuilder.uniqueStem(base: "2026-11-08 09.15.40_img_0001", taken: taken) == "2026-11-08 09.15.40_img_0001 (1)")
        let more = taken.union([NameSanitizer.collisionKey("2026-11-08 09.15.40_IMG_0001 (1)")])
        #expect(NameStemBuilder.uniqueStem(base: "2026-11-08 09.15.40_IMG_0001", taken: more) == "2026-11-08 09.15.40_IMG_0001 (2)")
    }

    @Test func fileNamesPerKind() {
        let builder = NameStemBuilder(timeZone: tz, utiResolver: FakeUTIResolver())
        let stem = "2026-11-08 09.15.40_DSC01234"
        let raw = ResourceRecord(assetKey: .local("A"), type: .alternatePhoto, isRaw: true, originalFilename: "DSC01234.ARW", uti: "com.sony.arw-raw-image")
        let jpg = ResourceRecord(assetKey: .local("A"), type: .photo, originalFilename: "DSC01234.JPG", uti: "public.jpeg")
        let edited = ResourceRecord(assetKey: .local("A"), type: .fullSizePhoto, originalFilename: "FullSizeRender.heic", uti: "public.heic")
        let noExt = ResourceRecord(assetKey: .local("A"), type: .photo, originalFilename: "IMG", uti: "public.heic")
        #expect(builder.fileName(stem: stem, resource: raw) == "\(stem).ARW")
        #expect(builder.fileName(stem: stem, resource: jpg) == "\(stem).JPG")
        #expect(builder.fileName(stem: stem, resource: edited) == "\(stem) (edited).HEIC")
        #expect(builder.fileName(stem: stem, resource: noExt) == "\(stem).HEIC")
        #expect(NameStemBuilder.sidecarName(stem: stem, type: .sidecarXmp) == "\(stem).xmp")
    }

    @Test func layoutCameraMonthAndPromotedDay() {
        let layout = DynamicLayout()
        let day = ArchiveDay(year: 2026, month: 11, day: 8)!
        let p = Placement(category: .camera, day: .day(day), nameStem: "x")
        #expect(layout.folderChain(for: p, dayPromoted: false, placeName: nil).map(\.logicalPath) == ["camera/2026", "camera/2026/11"])
        let promoted = layout.folderChain(for: p, dayPromoted: true, placeName: "Đà Lạt")
        #expect(promoted.last == FolderLevel(logicalPath: "camera/2026/11/2026-11-08", displayName: "2026-11-08 Đà Lạt"))
        #expect(promoted.map(\.displayName) == ["2026", "11", "2026-11-08 Đà Lạt"])
    }

    @Test func layoutScreenshotsSavedAndUnknown() {
        let layout = DynamicLayout()
        let day = ArchiveDay(year: 2026, month: 1, day: 2)!
        let shot = layout.folderChain(for: Placement(category: .screenshot, day: .day(day), nameStem: "x"), dayPromoted: true, placeName: "X")
        #expect(shot.map(\.displayName) == ["Screenshots", "2026", "01"])
        let saved = layout.folderChain(for: Placement(category: .saved, day: .unknown, nameStem: "x"), dayPromoted: false, placeName: nil)
        #expect(saved.map(\.logicalPath) == ["saved", "saved/unknown"])
        #expect(saved.map(\.displayName) == ["Saved", "Unknown date"])
        let cam = layout.folderChain(for: Placement(category: .camera, day: .unknown, nameStem: "x"), dayPromoted: false, placeName: nil)
        #expect(cam.map(\.logicalPath) == ["camera/unknown"])
    }

    @Test func placeNamesAreSanitizedInFolderNames() {
        let day = ArchiveDay(year: 2026, month: 11, day: 8)!
        #expect(DynamicLayout.dayFolderName(day, placeName: "A/B") == "2026-11-08 A_B")
    }

    @Test func viewChains() {
        let layout = DynamicLayout()
        let day = ArchiveDay(year: 2026, month: 11, day: 8)!
        let chain = layout.viewFolderChain(.byDevice(groupKey: "g1", groupName: "Sony A7 IV", day: day))
        #expect(chain.map(\.logicalPath).last == "view/byDevice/g1/2026/11")
        #expect(chain.map(\.displayName) == ["By device", "Sony A7 IV", "2026", "11"])
        let fav = layout.viewFolderChain(.favorites(day: day))
        #expect(fav.map(\.logicalPath) == ["view/favorites", "view/favorites/2026"])
    }
}
