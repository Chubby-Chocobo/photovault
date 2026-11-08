import Testing
import Foundation
@testable import PhotoVaultCore

@Suite struct ErrorClassifierHTTPTests {
    @Test(arguments: ["dailyLimitExceeded", "sharingRateLimitExceeded", "rateLimitExceeded", "userRateLimitExceeded"])
    func quotaStyle403ReasonsAreRateLimits(reason: String) {
        #expect(ErrorClassifier.destinationError(httpStatus: 403, reason: reason, retryAfter: 7) == .rateLimited(retryAfter: 7))
    }

    @Test func storageQuota403IsQuotaExceeded() {
        #expect(ErrorClassifier.destinationError(httpStatus: 403, reason: "storageQuotaExceeded") == .quotaExceeded)
    }

    @Test func otherForbiddenReasonsStayItemRejectedWithTheReason() {
        #expect(ErrorClassifier.destinationError(httpStatus: 403, reason: "insufficientPermissions")
            == .itemRejected(reason: "http 403 insufficientPermissions"))
        #expect(ErrorClassifier.destinationError(httpStatus: 403, reason: nil) == .itemRejected(reason: "http 403"))
    }
}

@Suite struct ErrorClassifierErrnoTests {
    @Test func permissionIsItemLevelBelowRootAndBookmarkAtRoot() {
        for code in [EACCES, EPERM] {
            let below = ErrorClassifier.destinationError(errno: code)
            #expect(below == .itemRejected(reason: "permission"))
            #expect(ErrorClassifier.classify(below) == .itemLevel)
            #expect(ErrorClassifier.destinationError(errno: code, atRoot: true) == .bookmarkInvalid)
        }
    }

    @Test func readOnlyFilesystemPausesTheDestination() {
        let error = ErrorClassifier.destinationError(errno: EROFS)
        #expect(ErrorClassifier.classify(error) == .destinationLevel(.unavailable(.offline)))
    }

    @Test func tooLargeAndInvalidNameArePermanent() {
        for code in [EFBIG, EILSEQ, ENAMETOOLONG] {
            #expect(ErrorClassifier.classify(ErrorClassifier.destinationError(errno: code)) == .permanent(.permanentError))
        }
        #expect(ErrorClassifier.classify(.itemRejected(reason: "other")) == .itemLevel)
    }

    @Test func descriptorExhaustionIsTransient() {
        for code in [EMFILE, ENFILE] {
            #expect(ErrorClassifier.classify(ErrorClassifier.destinationError(errno: code)) == .transient)
        }
    }
}
