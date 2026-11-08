import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

struct OnboardingFlowTests {
    @Test func stepsFollowFR01Order() {
        #expect(OnboardingStep.allCases.map(\.rawValue) == Array(1...9))
        #expect(OnboardingStep.allCases == [
            .googleSignIn, .photosPermission, .driveRoot, .archiveTimeZone, .syncMode, .notifications, .nas, .summary, .start,
        ])
    }

    private func ready() -> OnboardingFacts {
        var facts = OnboardingFacts()
        facts.googleSignedIn = true
        facts.photosAuthorization = .authorized
        return facts
    }

    @Test func cannotLeaveSignInWithoutGoogle() {
        var progress = OnboardingProgress()
        do { let accepted = progress.advance(OnboardingFacts()); #expect(!accepted) }
        #expect(progress.step == .googleSignIn)
        do { let accepted = progress.advance(ready()); #expect(accepted) }
        #expect(progress.step == .photosPermission)
    }

    @Test func deniedPhotosStopsTheFlow() {
        var progress = OnboardingProgress()
        var facts = ready()
        _ = progress.advance(facts)
        for status in [PhotosAuthorization.denied, .restricted, .notDetermined, .limited] {
            facts.photosAuthorization = status
            do { let accepted = progress.advance(facts); #expect(!accepted) }
        }
        facts.photosAuthorization = .authorized
        do { let accepted = progress.advance(facts); #expect(accepted) }
        #expect(progress.step == .driveRoot)
    }

    @Test func rootStepNeedsAValidNameAndAResolvedChoice() {
        var progress = OnboardingProgress()
        var facts = ready()
        _ = progress.advance(facts)
        _ = progress.advance(facts)
        facts.rootName = "   "
        do { let accepted = progress.advance(facts); #expect(!accepted) }
        facts.rootName = "Camera Uploads"
        facts.rootChoicePending = true
        do { let accepted = progress.advance(facts); #expect(!accepted) }
        facts.rootChoicePending = false
        do { let accepted = progress.advance(facts); #expect(accepted) }
        #expect(progress.step == .archiveTimeZone)
    }

    @Test func nasIsOptionalButMustBeTestedOnceChosen() {
        var progress = OnboardingProgress()
        var facts = ready()
        while progress.step != .nas { let moved = progress.advance(facts); #expect(moved) }
        #expect(progress.canSkip(facts))
        facts.nasFolderChosen = true
        #expect(!progress.canSkip(facts))
        #expect(!progress.canAdvance(facts))
        facts.nasTestPassed = true
        do { let accepted = progress.advance(facts); #expect(accepted) }
        #expect(progress.step == .summary)
        do { let accepted = progress.advance(facts); #expect(accepted) }
        #expect(progress.step == .start)
        do { let accepted = progress.advance(facts); #expect(!accepted) }
    }

    @Test func backAndJumpStopAfterStart() {
        var progress = OnboardingProgress()
        var facts = ready()
        _ = progress.advance(facts)
        _ = progress.advance(facts)
        do { let accepted = progress.back(facts); #expect(accepted) }
        #expect(progress.step == .photosPermission)
        do { let accepted = progress.jump(to: .driveRoot, facts); #expect(accepted) }
        do { let accepted = progress.jump(to: .syncMode, facts); #expect(!accepted) }
        facts.started = true
        do { let accepted = progress.back(facts); #expect(!accepted) }
        do { let accepted = progress.jump(to: .googleSignIn, facts); #expect(!accepted) }
        var fresh = OnboardingProgress()
        do { let accepted = fresh.back(OnboardingFacts()); #expect(!accepted) }
    }

    @Test func restorePhaseOnlyWhenReusing() {
        #expect(OnboardingPhase.sequence(reusingExistingDestination: false) == [.baseline, .scan, .upload])
        #expect(OnboardingPhase.sequence(reusingExistingDestination: true) == [.baseline, .scan, .restore, .upload])
    }

    @Test func syncModeMapsToScope() {
        let zone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SyncModeChoice.full.scope(timeZone: zone, now: now) == .full)
        #expect(SyncModeChoice.newOnly.scope(timeZone: zone, now: now) == .newOnly)
        let past = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01T00:00Z = 07:00 in Ho Chi Minh
        #expect(SyncModeChoice.since(past).scope(timeZone: zone, now: now) == .since(ArchiveDay(year: 2024, month: 1, day: 1)!))
        #expect(SyncModeChoice.since(now.addingTimeInterval(86400)).scope(timeZone: zone, now: now) == nil)
    }

    @Test func exactFR06NoteIsKept() {
        #expect(SyncModeChoice.newPhotoNote == "Ảnh mới = ảnh xuất hiện trong Photos trên Mac sau thời điểm này, kể cả ảnh cũ import sau")
    }

    @Test func rootNameValidation() {
        #expect(RootNameValidator.validate("Camera Uploads") == nil)
        #expect(RootNameValidator.validate("") == .empty)
        #expect(RootNameValidator.validate(" \n ") == .empty)
        #expect(RootNameValidator.validate("a/b") == .forbiddenCharacter)
        #expect(RootNameValidator.validate("a\u{0007}b") == .forbiddenCharacter)
        #expect(RootNameValidator.validate(String(repeating: "x", count: 201)) == .tooLong)
        #expect(RootNameValidator.normalized("  Ảnh  ") == "Ảnh")
    }

    @Test func timeZoneExampleUsesTheChosenZone() {
        let instant = Date(timeIntervalSince1970: 1_794_180_600) // 2026-11-08T23:30:00Z
        let hcm = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        #expect(ArchiveTimeZoneText.filenameExample(at: instant, in: hcm) == "2026-11-09 06.30.00_IMG_4821.HEIC")
        #expect(ArchiveTimeZoneText.filenameExample(at: instant, in: TimeZone(identifier: "UTC")!) == "2026-11-08 23.30.00_IMG_4821.HEIC")
        #expect(ArchiveTimeZoneText.label(hcm, at: instant) == "Asia/Ho_Chi_Minh (GMT+7)")
        #expect(ArchiveTimeZoneText.label(TimeZone(identifier: "Asia/Kolkata")!, at: instant) == "Asia/Kolkata (GMT+5:30)")
    }

    @Test func timeZoneOptionsStartWithCurrentWithoutDuplicates() {
        let options = ArchiveTimeZoneText.options(including: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(options.first?.identifier == "Asia/Tokyo")
        #expect(Set(options.map(\.identifier)).count == options.count)
    }
}
