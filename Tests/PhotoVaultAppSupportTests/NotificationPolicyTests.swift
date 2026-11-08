import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

struct NotificationThrottleTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let drive = DestinationID.googleDrive
    private let nas = DestinationID.local()

    @Test func secondSendInsideTwelveHoursIsBlocked() {
        var throttle = NotificationThrottle()
        do { let accepted = throttle.admit(.reauthRequired, destination: drive, now: t0); #expect(accepted) }
        do { let accepted = throttle.admit(.reauthRequired, destination: drive, now: t0.addingTimeInterval(3600)); #expect(!accepted) }
        do { let accepted = throttle.admit(.reauthRequired, destination: drive, now: t0.addingTimeInterval(12 * 3600 - 1)); #expect(!accepted) }
    }

    @Test func sendsAgainAtTwelveHours() {
        var throttle = NotificationThrottle()
        _ = throttle.admit(.reauthRequired, destination: drive, now: t0)
        do { let accepted = throttle.admit(.reauthRequired, destination: drive, now: t0.addingTimeInterval(12 * 3600)); #expect(accepted) }
    }

    @Test func kindsAndDestinationsAreIndependent() {
        var throttle = NotificationThrottle()
        do { let accepted = throttle.admit(.destinationFull, destination: drive, now: t0); #expect(accepted) }
        do { let accepted = throttle.admit(.destinationFull, destination: nas, now: t0); #expect(accepted) }
        do { let accepted = throttle.admit(.folderTrashedOrMissing, destination: drive, now: t0); #expect(accepted) }
        do { let accepted = throttle.admit(.syncStalled, destination: nil, now: t0); #expect(accepted) }
        do { let accepted = throttle.admit(.syncStalled, destination: nil, now: t0.addingTimeInterval(60)); #expect(!accepted) }
    }

    @Test func blockedAttemptDoesNotExtendTheWindow() {
        var throttle = NotificationThrottle()
        _ = throttle.admit(.bookmarkInvalid, destination: nas, now: t0)
        _ = throttle.admit(.bookmarkInvalid, destination: nas, now: t0.addingTimeInterval(11 * 3600))
        do { let accepted = throttle.admit(.bookmarkInvalid, destination: nas, now: t0.addingTimeInterval(12 * 3600 + 1)); #expect(accepted) }
    }

    @Test func clockMovingBackwardsDoesNotMuteForever() {
        var throttle = NotificationThrottle()
        _ = throttle.admit(.syncStalled, destination: nil, now: t0)
        do { let accepted = throttle.admit(.syncStalled, destination: nil, now: t0.addingTimeInterval(-100)); #expect(accepted) }
    }

    @Test func ledgerSurvivesRoundTripThroughFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pv-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = NotificationLedgerFile(url: directory.appendingPathComponent("ledger.json"))
        #expect(file.load() == NotificationThrottle())
        var throttle = NotificationThrottle()
        _ = throttle.admit(.reauthRequired, destination: drive, now: t0)
        try file.save(throttle)
        var loaded = file.load()
        do { let accepted = loaded.admit(.reauthRequired, destination: drive, now: t0.addingTimeInterval(60)); #expect(!accepted) }
    }

    @Test func corruptLedgerStartsFresh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pv-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        try Data("not json".utf8).write(to: url)
        #expect(NotificationLedgerFile(url: url).load() == NotificationThrottle())
    }
}

struct NotificationEvaluatorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let drive = DestinationID.googleDrive
    private let nas = DestinationID.local()

    private func input(
        onboarded: Bool = true, photos: PhotosAuthorization = .authorized, paused: Bool = false,
        destinations: [NotificationInputs.Destination] = [], diskFullSince: Date? = nil, lastSync: Date? = nil,
        missing: [DestinationID: Int] = [:], mismatches: [DestinationID: Int] = [:]
    ) -> NotificationInputs {
        NotificationInputs(
            onboardingComplete: onboarded, photosAuthorization: photos, syncPausedByOwner: paused, destinations: destinations,
            macDiskFullSince: diskFullSince, lastSuccessfulSyncAt: lastSync, missingFiles: missing, checksumMismatches: mismatches)
    }

    private func dest(_ id: DestinationID, _ status: DestinationStatus, since: TimeInterval = 0) -> NotificationInputs.Destination {
        .init(id: id, name: id == .googleDrive ? "Google Drive" : "NAS", status: status, statusSince: now.addingTimeInterval(-since))
    }

    private func kinds(_ input: NotificationInputs) -> [NotificationKind] { NotificationEvaluator.due(input, now: now).map(\.kind) }

    @Test func nothingBeforeOnboardingFinishes() {
        #expect(kinds(input(onboarded: false, photos: .denied, destinations: [dest(drive, .paused(.reauthRequired))])).isEmpty)
    }

    @Test func photosPermissionLost() {
        #expect(kinds(input(photos: .denied)) == [.photosPermissionLost])
        #expect(kinds(input(photos: .restricted)) == [.photosPermissionLost])
        #expect(kinds(input(photos: .notDetermined)).isEmpty)
    }

    @Test func statusReasonsMapToKinds() {
        #expect(kinds(input(destinations: [dest(drive, .paused(.reauthRequired))])) == [.reauthRequired])
        #expect(kinds(input(destinations: [dest(drive, .paused(.full))])) == [.destinationFull])
        #expect(kinds(input(destinations: [dest(drive, .paused(.rootTrashed))])) == [.folderTrashedOrMissing])
        #expect(kinds(input(destinations: [dest(drive, .paused(.rootMissing))])) == [.folderTrashedOrMissing])
        #expect(kinds(input(destinations: [dest(drive, .paused(.folderTrashed))])) == [.folderTrashedOrMissing])
        #expect(kinds(input(destinations: [dest(nas, .unavailable(.bookmarkInvalid))])) == [.bookmarkInvalid])
        #expect(kinds(input(destinations: [dest(drive, .paused(.userPaused))])).isEmpty)
    }

    @Test func offlineNeedsMoreThanSevenDays() {
        let day: TimeInterval = 86400
        #expect(kinds(input(destinations: [dest(nas, .unavailable(.offline), since: 7 * day - 60)])).isEmpty)
        #expect(kinds(input(destinations: [dest(nas, .unavailable(.offline), since: 7 * day + 60)])) == [.destinationOfflineLong])
    }

    @Test func briefOfflineStaysQuiet() {
        #expect(kinds(input(destinations: [dest(nas, .unavailable(.offline), since: 3600)])).isEmpty)
    }

    @Test func driveOfflineNeverUsesTheNasRule() {
        #expect(kinds(input(destinations: [dest(drive, .unavailable(.offline), since: 30 * 86400)])).isEmpty)
    }

    @Test func integrityAndChecksumCarryCounts() {
        let due = NotificationEvaluator.due(input(destinations: [dest(nas, .active)], missing: [nas: 27], mismatches: [nas: 2]), now: now)
        #expect(due.map(\.kind) == [.integrityMissing, .checksumMismatch])
        #expect(due[0].title.contains("27"))
        #expect(due[0].destination == nas)
        #expect(kinds(input(destinations: [dest(nas, .active)], missing: [nas: 0])).isEmpty)
    }

    @Test func macDiskFullAfterTwentyFourHours() {
        #expect(kinds(input(diskFullSince: now.addingTimeInterval(-23 * 3600))).isEmpty)
        #expect(kinds(input(diskFullSince: now.addingTimeInterval(-25 * 3600))) == [.macDiskFullLong])
    }

    @Test func syncStalledNeedsAnActiveDestinationAndNoOwnerPause() {
        let old = now.addingTimeInterval(-25 * 3600)
        let active = [dest(drive, .active)]
        #expect(kinds(input(destinations: active, lastSync: old)) == [.syncStalled])
        #expect(kinds(input(destinations: active, lastSync: now.addingTimeInterval(-23 * 3600))).isEmpty)
        #expect(kinds(input(paused: true, destinations: active, lastSync: old)).isEmpty)
        #expect(kinds(input(destinations: [dest(drive, .paused(.userPaused))], lastSync: old)).isEmpty)
        #expect(kinds(input(destinations: active, lastSync: nil)).isEmpty)
        #expect(kinds(input(photos: .denied, destinations: active, lastSync: old)) == [.photosPermissionLost])
    }

    @Test func planSendsOncePerWindowAcrossEvaluations() {
        var throttle = NotificationThrottle()
        let state = input(destinations: [dest(drive, .paused(.reauthRequired))])
        #expect(NotificationEvaluator.plan(state, throttle: &throttle, now: now).count == 1)
        #expect(NotificationEvaluator.plan(state, throttle: &throttle, now: now.addingTimeInterval(600)).isEmpty)
        #expect(NotificationEvaluator.plan(state, throttle: &throttle, now: now.addingTimeInterval(13 * 3600)).count == 1)
    }

    @Test func everyKindHasContentWithoutPaths() {
        for kind in NotificationKind.allCases {
            let content = NotificationContent.make(kind, destinationName: "NAS", count: 5)
            #expect(!content.title.isEmpty && !content.body.isEmpty)
            #expect(LogRedactor.inspect(content.title + content.body) == .clean)
            #expect(!kind.summary.isEmpty)
        }
        #expect(NotificationKind.allCases.count == 10)
    }
}
