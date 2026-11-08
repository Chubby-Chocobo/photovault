import Testing
@testable import PhotoVaultAppSupport

struct IntegrityNoticeTextTests {
    @Test func cleanCheckSaysNothingIsWrong() {
        #expect(IntegrityNoticeText.make(missing: 0, mismatched: 0, skippedNames: [])
            == "Kiểm tra xong: không thiếu file nào và không file nào lệch checksum.")
    }

    @Test func countsAreReportedSeparately() {
        let text = IntegrityNoticeText.make(missing: 1200, mismatched: 3, skippedNames: [])
        #expect(text == "Kiểm tra xong: thiếu 1.200 file, 3 file lệch checksum. Xem trong menu bar.")
    }

    @Test func onlyMismatchesDoNotClaimMissingFiles() {
        let text = IntegrityNoticeText.make(missing: 0, mismatched: 3, skippedNames: [])
        #expect(!text.contains("thiếu"))
        #expect(text.contains("3 file lệch checksum"))
    }

    @Test func skippedDestinationsAreNamed() {
        let text = IntegrityNoticeText.make(missing: 2, mismatched: 0, skippedNames: ["NAS", "Ổ ngoài"])
        #expect(text.contains("thiếu 2 file"))
        #expect(text.contains("Chưa kiểm tra được NAS, Ổ ngoài"))
    }

    @Test func onlySkippedIsNotReportedAsClean() {
        let text = IntegrityNoticeText.make(missing: 0, mismatched: 0, skippedNames: ["NAS"])
        #expect(!text.contains("không thiếu file nào"))
        #expect(text.contains("Chưa kiểm tra được NAS"))
    }
}
