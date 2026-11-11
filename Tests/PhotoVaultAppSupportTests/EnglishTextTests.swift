import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport
@testable import PhotoVaultEngine

/// Representative English output of each AppSupport text builder. The language is pinned per test with
/// the task-local override; `L10n.current` is never touched.
struct EnglishTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func english<T>(_ body: () -> T) -> T { L10n.$override.withValue(.en, operation: body) }

    @Test func statusLabelsAndReasons() {
        english {
            #expect(StatusText.presentation(for: .active).label == "Active")
            #expect(StatusText.presentation(for: .paused(.userPaused)).label == "Paused (by you)")
            #expect(StatusText.presentation(for: .paused(.rootTrashed)).label == "Paused · root folder is in Trash")
            #expect(StatusText.presentation(for: .unavailable(.offline)).label == "Unavailable · offline")
            #expect(StatusText.presentation(for: .error(.reauthRequired)).label == "Error · sign-in required")
            #expect(StatusText.scopeText(.full) == "Entire library")
            #expect(StatusText.scopeText(.newOnly) == "New photos only")
            #expect(StatusText.scopeText(.since(ArchiveDay(year: 2024, month: 1, day: 1)!)) == "From 01/01/2024")
        }
    }

    @Test func errorBranches() {
        english {
            #expect(ErrorText.message(for: DestinationError.rateLimited(retryAfter: nil)) == "Google is limiting the request rate. Try again in a few minutes.")
            #expect(ErrorText.message(for: DestinationError.rootTrashed) == "The folder at the destination is in Trash.")
            #expect(ErrorText.message(for: DestinationError.transient(reason: "sign-in timed out")) == "Sign-in timed out. Try again.")
            #expect(ErrorText.message(for: DestinationError.transient(reason: "odd")) == "Temporary error. Try again later.")
            #expect(ErrorText.message(for: DeviceGroupError.emptyName) == "The group name can't be empty.")
            #expect(ErrorText.message(for: EngineError.alreadyRunning) == "PhotoVault is already running.")
            #expect(ErrorText.message(for: RootProblemError.stillTrashed) == "The root folder is still in Trash.")
            struct Unknown: Error {}
            #expect(ErrorText.message(for: Unknown()) == "Something went wrong. See the log for details.")
        }
    }

    @Test func onboardingFlowText() {
        english {
            #expect(OnboardingStep.googleSignIn.title == "Sign in to Google")
            #expect(OnboardingStep.nas.title == "NAS (optional)")
            #expect(OnboardingPhase.scan.title == "Scan library metadata")
            #expect(OnboardingPhase.scan.detail == "No files are exported during the scan.")
            #expect(RootNameValidator.Issue.tooLong.message == "The folder name can be at most 200 characters.")
            #expect(SyncModeChoice.newPhotoNote.hasPrefix("New photos = photos that appear in Photos"))
        }
    }

    @Test func overallStatus() {
        let destination = DestinationSnapshot(
            id: DestinationID(rawValue: "gdrive")!, displayName: "Google Drive", status: .active, pending: 0, deferred: 0, skipped: 0,
            missingRemote: 0, lastSuccessAt: now.addingTimeInterval(-120))
        func snapshot(_ overall: EngineSnapshot.Overall, _ destinations: [DestinationSnapshot]) -> EngineSnapshot {
            EngineSnapshot(
                overall: overall, scanState: .complete, destinations: destinations, backfillDoneAssets: 0, backfillTotalAssets: 0,
                bytesUploaded: 0, etaSeconds: nil, pending: 0, deferred: 0, skipped: 0, missingRemote: 0, updatedAt: now)
        }
        english {
            let paused = OverallStatusText.make(snapshot: snapshot(.paused, []), disk: .ok, settings: GlobalSettings(), now: now)
            #expect(paused.title == "All paused")
            let idle = OverallStatusText.make(
                snapshot: snapshot(.idle, [destination]), disk: .ok, settings: GlobalSettings(), now: now, calendar: calendar)
            #expect(idle.title == "Synced")
            #expect(idle.subtitle == "1 destination · last sync 2 min ago")
            #expect(idle.subtitleLine == FittedLine(lead: idle.subtitle))
            let decision = DestinationSnapshot(
                id: DestinationID(rawValue: "gdrive")!, displayName: "Google Drive", status: .paused(.rootTrashed), pending: 0,
                deferred: 0, skipped: 0, missingRemote: 0, lastSuccessAt: nil)
            let others = [decision, destination, destination, destination]
            let result = OverallStatusText.make(snapshot: snapshot(.idle, others), disk: .ok, settings: GlobalSettings(), now: now)
            #expect(result.title == "Your decision is needed")
            #expect(result.subtitle == "Google Drive paused · 3 other destinations still running")
        }
    }

    @Test func progressText() {
        english {
            #expect(ProgressText.eta(seconds: nil) == "Estimating…")
            #expect(ProgressText.eta(seconds: 30) == "About 1 minute left")
            #expect(ProgressText.eta(seconds: 600) == "About 10 minutes left")
            #expect(ProgressText.eta(seconds: 3 * 3600) == "About 3 hours left")
            #expect(ProgressText.eta(seconds: 86400) == "About 1 day left")
            #expect(ProgressText.rateCaption(remainingAssets: 12_200, etaSeconds: 86400 * 2) == "Estimate by asset count: ~6,100 assets/day")
        }
    }

    @Test func relativeTime() {
        english {
            #expect(RelativeTimeText.ago(nil, now: now) == "Never")
            #expect(RelativeTimeText.ago(now.addingTimeInterval(-10), now: now) == "just now")
            #expect(RelativeTimeText.ago(now.addingTimeInterval(-300), now: now, calendar: calendar) == "5 min ago")
            #expect(RelativeTimeText.ago(now.addingTimeInterval(-7200), now: now, calendar: calendar) == "today 06:00")
            #expect(RelativeTimeText.ago(now.addingTimeInterval(-86400), now: now, calendar: calendar) == "yesterday 08:00")
            #expect(RelativeTimeText.dayHeading(now, now: now, calendar: calendar) == "Today")
            #expect(RelativeTimeText.dayHeading(now.addingTimeInterval(-86400), now: now, calendar: calendar) == "Yesterday")
            #expect(RelativeTimeText.dayHeading(now.addingTimeInterval(-3 * 86400), now: now, calendar: calendar) == "Tuesday, 12 Jan 2027")
        }
    }

    @Test func notifications() {
        english {
            let missing = NotificationContent.make(.integrityMissing, destinationName: "NAS", count: 1_500)
            #expect(missing.title == "1,500 files missing on NAS")
            let one = NotificationContent.make(.checksumMismatch, destinationName: nil, count: 1)
            #expect(one.title == "Checksum mismatch on destination")
            #expect(one.body == "1 file at the destination has a checksum mismatch. Open Recent activity to see details.")
            #expect(NotificationContent.make(.syncStalled, destinationName: nil).title == "Sync has not worked for over 24 hours")
            #expect(NotificationKind.destinationOfflineLong.summary == "NAS offline for over 7 days")
        }
    }

    @Test func integrityNotice() {
        english {
            #expect(IntegrityNoticeText.make(missing: 0, mismatched: 0, skippedNames: []) == "Check finished: no files missing and no checksum mismatches.")
            #expect(
                IntegrityNoticeText.make(missing: 1, mismatched: 1_200, skippedNames: ["NAS"])
                    == "Check finished: 1 file missing, 1,200 files with a checksum mismatch. See the menu bar. Couldn't check NAS because the destination can't be reached yet.")
        }
    }

    @Test func settingsForm() {
        english {
            #expect(SettingsIssue.rateNotPositive.message == "The export rate must be greater than 0 GB/hour.")
            #expect(SettingsIssue.invalidHomeCountry.message == "The home country code must be 2 letters.")
        }
    }

    @Test func rulesEditor() {
        english {
            #expect(RuleKey.screenshot.label == "Screenshots")
            #expect(RuleKey.groups.map(\.title) == ["Category", "Type", "Version", "Sidecar"])
            var old = DestinationRules()
            var new = old
            old.set(.raw, false)
            new.set(.raw, true)
            let lines = RuleEditor.changeLines(
                old: old, new: new, oldScope: .full, newScope: .newOnly, settings: GlobalSettings(), counts: [.raw: 1_234])
            #expect(lines.first == "Turn on RAW → queue more ~1,234 assets")
            #expect(lines.last == "Change scope → widening queues more, narrowing only cancels what isn't uploaded yet")
        }
    }

    @Test func activityPresentation() {
        english {
            #expect(ActivityFilter.missing.label == "Missing file")
            #expect(ActivityPresenter.kindLabel(.statusChanged) == "Status")
            let event = ActivityEvent(id: 1, at: now, kind: .notice, message: "x")
            let groups = ActivityPresenter.groups(
                [event], filter: .all, query: "", destinationNames: [:], now: now, calendar: calendar)
            #expect(groups.first?.heading == "Today")
            #expect(groups.first?.rows.first?.kindLabel == "Notice")
        }
    }

    @Test func destinationNesting() {
        english {
            #expect(DestinationNesting.message(name: "NAS", relation: .same) == "This folder is already the destination “NAS”.")
            #expect(DestinationNesting.message(name: "NAS", relation: .inside).hasPrefix("This folder is inside the destination “NAS”."))
        }
    }

    @Test func destinationNamesStayLiteral() {
        let vi = L10n.$override.withValue(.vi) { OnboardingFacts().rootName }
        let en = L10n.$override.withValue(.en) { OnboardingFacts().rootName }
        #expect(vi == "PhotoVault")
        #expect(en == vi)
    }

    @Test func vietnameseStaysDefault() {
        L10n.$override.withValue(.vi) {
            #expect(StatusText.presentation(for: .active).label == "Đang hoạt động")
            #expect(ProgressText.eta(seconds: 600) == "Còn khoảng 10 phút")
        }
    }
}
