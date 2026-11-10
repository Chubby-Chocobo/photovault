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

    @Test func aSignInWithoutTheDrivePermissionSaysWhichBoxToTick() {
        let message = ErrorText.message(for: DestinationError.itemRejected(reason: "drive.file scope not granted"))
        #expect(message.contains("Google Drive"))
        #expect(message.contains("tích"))
        #expect(message != "Lỗi tạm thời. Thử lại sau.")
    }

    @Test func aRejectedAccountTokenPointsAtTheMacClock() {
        for reason in ["id token expired", "id token audience", "id token issuer", "id token malformed", "id token missing"] {
            let message = ErrorText.message(for: DestinationError.itemRejected(reason: reason))
            #expect(message.contains("tài khoản"), "\(reason)")
            #expect(message != "Lỗi tạm thời. Thử lại sau.", "\(reason)")
        }
    }

    @Test func signInFailureLogLinesCarryOnlyTheReasonCode() {
        #expect(SignInFailureLog.line(for: DestinationError.itemRejected(reason: "drive.file scope not granted"))
            == "sign-in failed: itemRejected(drive.file scope not granted)")
        #expect(SignInFailureLog.line(for: DestinationError.server(status: 503)) == "sign-in failed: server(503)")
        // Reasons the app did not write itself never reach the log.
        #expect(SignInFailureLog.line(for: DestinationError.transient(reason: "someone@example.com secret")) == "sign-in failed: transient(other)")
        struct Other: Error {}
        #expect(SignInFailureLog.line(for: Other()) == "sign-in failed: Other")
    }

    @Test func otherErrorTypes() {
        #expect(ErrorText.message(for: DeviceGroupError.duplicateName(existingGroupId: "g")).contains("trùng tên"))
        #expect(ErrorText.message(for: DeviceGroupError.emptyName).contains("trống"))
        #expect(ErrorText.message(for: EngineError.notBaselined).contains("thiết lập"))
        struct Unknown: Error {}
        #expect(ErrorText.message(for: Unknown()).contains("log"))
    }
}

@Test func rootProblemErrorsHaveOwnerMessages() {
    for error in [RootProblemError.notRootProblem, .stillMissing, .stillTrashed, .unsupported] {
        let text = ErrorText.message(for: error)
        #expect(!text.isEmpty && !text.contains("Có lỗi xảy ra"))
    }
}
