import AppKit
import Foundation
import Observation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import PhotoVaultStore

/// UI state and actions of the whole app. Views read it; every mutation goes through a method here
/// so the engine and the database are touched in one place.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case needsOnboarding
        case running
    }

    static let shared = AppModel()

    init() {
        setInterfaceLanguage(Self.storedInterfaceLanguage(), save: false)
    }

    /// What the owner picked, and the language it resolves to; views key their content on `language`
    /// so a switch re-renders them.
    var interfaceLanguage: InterfaceLanguageChoice = .vi
    var language: AppLanguage = .vi
    var phase: Phase = .launching
    var env: AppEnvironment?
    var snapshot: EngineSnapshot?
    var destinations: [DestinationRecord] = []
    var persistedSettings = GlobalSettings()
    /// The Settings form edits this copy; it is saved once it validates.
    var settings = GlobalSettings()
    var settingsIssues: [SettingsIssue] = []
    var archiveTimeZone = TimeZone.current
    var activity: [ActivityEvent] = []
    var decisions: [OwnerDecisionItem] = []
    var snoozedDecisions: Set<String> = []
    var macFreeBytes: Int64 = 0
    var photosAuthorization: PhotosAuthorization = .notDetermined
    var lastIntegrityCheck: Date?
    /// Progress of the first start after onboarding; nil until the owner presses Start.
    var firstStart: FirstStartState?
    /// One short message for the user (success or failure); views show it as a banner.
    var notice: Notice?
    /// A factory reset is signing out or relaunching; its button stays disabled.
    var factoryResetInProgress = false
    var windowRequest: WindowRequest?
    var settingsTab: SettingsTab = .general
    var hardening: (any HardeningCommands)?
    /// Set before `bootstrap()`: builds the engine adapter for `HardeningCommands`.
    @ObservationIgnored var hardeningFactory: (@MainActor (AppEnvironment) -> any HardeningCommands)?

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    /// Account changes whose staged sign-in is neither applied nor cancelled yet.
    @ObservationIgnored var openAccountChanges: Set<UUID> = []
    @ObservationIgnored var settingsCommitsInFlight = 0
    @ObservationIgnored let activityAssertion = ActivityAssertion()
    @ObservationIgnored let notificationService = NotificationService()
    @ObservationIgnored var runtime: Runtime?
    /// Status of every import at the last snapshot, to notice the moment one finishes.
    @ObservationIgnored var importStatuses: [SourceID: SourceStatus] = [:]

    /// Things that run only while the engine is live.
    struct Runtime {
        var workspace: WorkspaceMonitor
        var photosObserver: PhotosChangeObserver
        var scheduler: SyncScheduler
        var snapshotTask: Task<Void, Never>
        var pollTask: Task<Void, Never>
    }

    // MARK: Derived state

    var destinationNames: [DestinationID: String] {
        Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0.displayName) })
    }

    var driveRecord: DestinationRecord? { destinations.first { $0.id == .googleDrive } }
    var localRecords: [DestinationRecord] { destinations.filter { $0.kind == .localFolder } }
    var accountEmail: String? { driveRecord?.accountEmail }
    var isPausedAll: Bool { snapshot?.overall == .paused }

    /// Drive waits for the owner to sign in again: the grant expired or was revoked, or they signed out.
    var driveNeedsSignIn: Bool {
        driveRecord?.status == .paused(.reauthRequired) || driveRecord?.status == .paused(.signedOut)
    }

    var diskState: MacDiskState { MacDiskState.classify(freeBytes: macFreeBytes, settings: persistedSettings) }

    var visibleDecisions: [OwnerDecisionItem] { decisions.filter { !snoozedDecisions.contains($0.id) } }

    func showNotice(_ text: String, isError: Bool = false) {
        notice = Notice(text: text, isError: isError)
    }

    func showError(_ error: any Error) {
        let text = (error as? RecoveryCommandError)?.message ?? ErrorText.message(for: error)
        notice = Notice(text: text, isError: true)
        env?.log.log(.error, category: "ui", "action failed: \(type(of: error))")
    }

    // MARK: Launch

    /// Builds the environment and brings the engine up, or ends the process with an explanation.
    func bootstrap() async {
        guard phase == .launching else { return }
        let environment: AppEnvironment
        do {
            environment = try AppEnvironment.make()
        } catch let failure as LaunchFailure {
            Self.presentFatal(failure)
            return
        } catch {
            Self.presentFatal(.other(error.localizedDescription))
            return
        }
        env = environment
        hardening = hardeningFactory?(environment)
            ?? EngineHardeningCommands(coordinator: environment.coordinator, store: environment.store, log: environment.log)
        notificationService.configure()
        environment.log.log(.info, category: "launch", "container ready, dev=\(environment.layout.isDevContainer)")
        await refresh()
        await clearStaleAccountChangePause()
        let baselined = (try? await environment.store.read { db in try AppQueries.baselineTaken(db) }) ?? false
        if baselined {
            await goLive()
        } else {
            phase = .needsOnboarding
            windowRequest = .onboarding
        }
    }

    /// Recovery, monitors, first cycle. Called at launch with a baseline, and by onboarding after Start.
    func goLive() async {
        guard let env, runtime == nil else { return }
        await env.coordinator.registerSources(env.folderSources)
        do {
            let summary = try await env.coordinator.start()
            env.log.log(.info, category: "launch", "startup recovery finished: \(summary)")
        } catch {
            env.log.log(.error, category: "launch", "startup recovery failed: \(type(of: error))")
            showError(error)
        }
        phase = .running
        startRuntime(env)
        requestSync(.launch)
        await reconcileLoginItem()
    }

    private func startRuntime(_ env: AppEnvironment) {
        let trigger: @Sendable (SyncTrigger) -> Void = { [weak self] value in
            Task { @MainActor in self?.requestSync(value) }
        }
        env.system.start(onTrigger: trigger)
        let workspace = WorkspaceMonitor(onTrigger: trigger)
        workspace.start()
        let observer = PhotosChangeObserver { [weak self] in
            await MainActor.run { self?.requestSync(.photosChanged) }
        }
        observer.startIfAuthorized()
        let scheduler = SyncScheduler(
            onTrigger: { [weak self] in self?.requestSync($0) },
            needsAvailabilityRecheck: { [weak self] in
                self?.destinations.contains { record in
                    if record.kind == .localFolder, case .unavailable = record.status { return true }
                    return false
                } ?? false
            },
            needsDiskRecheck: { [weak self] in self.map { $0.diskState != .ok } ?? false })
        scheduler.start()
        let snapshots = Task { [weak self] in
            for await value in await env.coordinator.snapshots() {
                guard let self else { return }
                self.snapshot = value
                await self.noteImportProgress(value)
                await self.refresh()
            }
        }
        let poll = Task { [weak self] in
            // A cycle publishes only at its start and end; polling keeps the progress bar moving during a
            // long backfill. Idle, nothing moves, so nothing is polled (NFR-03).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                guard self.snapshot?.overall == .syncing else { continue }
                await self.refreshSnapshot()
            }
        }
        runtime = Runtime(workspace: workspace, photosObserver: observer, scheduler: scheduler, snapshotTask: snapshots, pollTask: poll)
    }

    func shutdown() {
        runtime?.snapshotTask.cancel()
        runtime?.pollTask.cancel()
        runtime?.scheduler.stop()
        runtime?.workspace.stop()
        runtime?.photosObserver.stop()
        env?.system.stop()
        env?.dailyCapFile.flush()
        env?.fileLog.close()
    }

    private static func presentFatal(_ failure: LaunchFailure) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.alertTitle
        alert.informativeText = failure.alertText
        alert.addButton(withTitle: tr(vi: "Thoát", en: "Quit"))
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: Refresh

    /// Reloads the cheap state the screens show: destinations, disk, permissions, decisions.
    func refresh() async {
        guard let env else { return }
        do {
            let records = try await env.store.read { db in try DestinationRepository.fetchAll(db) }
            let integrity = try await env.store.read { db in try AppQueries.lastIntegrityCheck(db) }
            destinations = records
            lastIntegrityCheck = integrity
        } catch {
            env.log.log(.error, category: "ui", "refresh failed: \(type(of: error))")
        }
        let current = await env.settings.snapshot()
        archiveTimeZone = current.timeZone
        // Never replace an edit that is still being saved or has not validated yet.
        if settingsCommitsInFlight == 0, settings == persistedSettings {
            persistedSettings = current.settings
            settings = current.settings
        }
        macFreeBytes = (try? env.disk.capacity(of: env.layout.root).available) ?? macFreeBytes
        photosAuthorization = env.photos.authorizationStatus()
        decisions = await collectDecisions()
        if phase == .running { await evaluateNotifications() }
    }

    func refreshSnapshot() async {
        guard let env, phase == .running else { return }
        let current = await env.coordinator.currentSnapshot()
        snapshot = current
        await noteImportProgress(current)
        await refresh()
    }

    func refreshActivity() async {
        guard let env else { return }
        do {
            activity = try await env.store.read { db in try ActivityRepository.recent(db) }
        } catch {
            env.log.log(.error, category: "ui", "activity load failed: \(type(of: error))")
        }
    }

    /// Engine decisions plus the ones implied by destination status, so a trashed root is never invisible.
    private func collectDecisions() async -> [OwnerDecisionItem] {
        var items = await hardening?.pendingOwnerDecisions() ?? []
        let known = Set(items.map(\.destinationId))
        for record in destinations where !known.contains(record.id) {
            let name = record.config.driveRootName ?? record.displayName
            switch record.status {
            case .paused(.rootTrashed):
                items.append(OwnerDecisionItem(destinationId: record.id, destinationName: record.displayName, kind: .rootTrashed(rootName: name)))
            case .paused(.rootMissing):
                items.append(OwnerDecisionItem(destinationId: record.id, destinationName: record.displayName, kind: .rootMissing(rootName: name)))
            default: break
            }
        }
        return items
    }

    // MARK: Sync

    func requestSync(_ trigger: SyncTrigger) {
        guard phase == .running, let env else { return }
        Task { [weak self] in
            env.log.log(.info, category: "cycle", "requested trigger=\(trigger.rawValue)")
            self?.activityAssertion.begin()
            let outcome = await env.coordinator.run(trigger: trigger)
            self?.activityAssertion.end()
            if trigger == .launch || trigger == .timer {
                let backups = env.backups
                let store = env.store
                // VACUUM INTO holds the database writer for a while: never on the main thread.
                await Task.detached(priority: .utility) { _ = try? backups.backupIfDue(store, now: Date()) }.value
            }
            guard let self else { return }
            if case .blocked(.photosUnauthorized) = outcome { self.photosAuthorization = env.photos.authorizationStatus() }
            self.runtime?.photosObserver.startIfAuthorized()
            await self.refreshSnapshot()
        }
    }
}
