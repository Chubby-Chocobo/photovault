import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport
@testable import PhotoVaultEngine

struct ErrorTextTests {
    @Test func destinationErrorsHaveMessages() {
        let errors: [DestinationError] = [
            .unauthorized, .reauthRequired, .rateLimited(retryAfter: nil), .server(status: 500), .offline, .noSpace,
            .quotaExceeded, .dailyCapReached, .bookmarkInvalid, .folderMissing(logicalPath: "a"), .folderTrashed(logicalPath: "a"),
            .rootMissing, .rootTrashed, .alreadyExists(remoteId: "x"), .sessionExpired, .notFound,
            .checksumMismatch(expected: "a", actual: "b"), .foreignFile, .foreignModified, .viewsNotPermitted,
            .itemRejected(reason: "x"), .transient(reason: "y"),
        ]
        for error in errors { #expect(!ErrorText.message(for: error).isEmpty) }
    }

    @Test func messagesNeverEchoPathsOrReasons() {
        let text = ErrorText.message(for: DestinationError.folderMissing(logicalPath: "2025/07/IMG_1.HEIC"))
        #expect(!text.contains("IMG_1"))
        #expect(ErrorText.message(for: DestinationError.transient(reason: "secret-token-xyz")) == "Lỗi tạm thời. Thử lại sau.")
    }

    @Test func signInFailuresAreRecognised() {
        #expect(ErrorText.message(for: DestinationError.transient(reason: "sign-in timed out")) == "Hết thời gian chờ đăng nhập. Thử lại.")
        #expect(ErrorText.message(for: DestinationError.transient(reason: "sign-in cancelled")) == "Đã huỷ đăng nhập.")
        #expect(ErrorText.message(for: DestinationError.transient(reason: "browser could not be opened")).contains("trình duyệt"))
    }

    @Test func otherErrorTypes() {
        #expect(ErrorText.message(for: DeviceGroupError.duplicateName(existingGroupId: "g")).contains("trùng tên"))
        #expect(ErrorText.message(for: DeviceGroupError.emptyName).contains("trống"))
        #expect(ErrorText.message(for: EngineError.notBaselined).contains("thiết lập"))
        struct Unknown: Error {}
        #expect(ErrorText.message(for: Unknown()).contains("log"))
    }
}
