import Foundation
import Observation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultDrive

/// State of the nine onboarding steps. The first-start work itself lives on `AppModel`.
@MainActor
@Observable
final class OnboardingModel {
    enum GoogleState { case none, waiting, done }
    enum NotificationState { case notAsked, granted, denied }

    let app: AppModel
    var progress = OnboardingProgress()

    var google: GoogleState = .none
    var identity: GoogleIdentity?
    var signInError: String?
    private var signInGeneration = 0
    /// The sign-in waiting for the browser. Cancelling it stops the loopback listener, so a tab the
    /// owner abandoned cannot finish later and replace (or revoke) a newer sign-in.
    private var signInTask: Task<Void, Never>?

    var photos: PhotosAuthorization

    var rootName = "Camera Uploads"
    var roots: [RootChooser.RemoteItemSummary] = []
    var reuseRootId: String?
    var rootsError: String?

    var timeZone: TimeZone = .current
    var scope: ScopeMode = .full
    var notifications: NotificationState = .notAsked
    var nas: PendingLocalDestination?
    var nasTesting = false

    /// Why Start did nothing: an earlier answer no longer holds.
    var startError: String?

    var libraryCount: Int?
    var driveFreeBytes: Int64?

    init(app: AppModel) {
        self.app = app
        photos = app.env?.photos.authorizationStatus() ?? .notDetermined
        timeZone = app.archiveTimeZone
    }

    var facts: OnboardingFacts {
        var facts = OnboardingFacts()
        facts.googleSignedIn = google == .done
        facts.photosAuthorization = photos
        facts.rootName = reuseRootId == nil ? rootName : (roots.first { $0.id == reuseRootId }?.name ?? rootName)
        facts.nasFolderChosen = nas != nil
        facts.nasTestPassed = nas?.testPassed ?? false
        facts.started = app.firstStart != nil
        return facts
    }

    var step: OnboardingStep { progress.step }
    var canAdvance: Bool { progress.canAdvance(facts) }
    var canSkip: Bool { progress.canSkip(facts) }
    var started: Bool { app.firstStart != nil }

    func advance() {
        if progress.advance(facts) { stepEntered() }
    }

    func back() { _ = progress.back(facts) }

    func canJump(to target: OnboardingStep) -> Bool { progress.canJump(to: target, facts) }

    func jump(to target: OnboardingStep) {
        startError = nil
        _ = progress.jump(to: target, facts)
    }

    private func stepEntered() {
        if progress.step == .summary { Task { await loadSummary() } }
    }

    // MARK: 1. Google

    func signIn() async {
        guard app.googleConfigured else {
            signInError = "Chưa cấu hình Google OAuth: PVGoogleClientID trống. Làm theo \(AppEnvironment.setupReadmeSection) rồi build lại."
            return
        }
        signInGeneration += 1
        let generation = signInGeneration
        google = .waiting
        signInError = nil
        do {
            let signedIn = try await app.signInGoogle()
            guard generation == signInGeneration else {
                // The owner pressed Huỷ while the browser was open: do not keep the credentials.
                try? await app.env?.auth.signOut()
                return
            }
            identity = signedIn
            google = .done
            await loadRoots()
        } catch {
            guard generation == signInGeneration else { return }
            google = .none
            signInError = ErrorText.message(for: error)
        }
    }

    func startSignIn() {
        signInTask?.cancel()
        signInTask = Task { await signIn() }
    }

    func cancelSignIn() {
        signInGeneration += 1
        signInTask?.cancel()
        signInTask = nil
        google = .none
    }

    func useAnotherAccount() async {
        signInGeneration += 1
        try? await app.env?.auth.signOut()
        google = .none
        identity = nil
        roots = []
        reuseRootId = nil
    }

    // MARK: 2. Photos

    func requestPhotos() async {
        photos = await app.env?.photos.requestAuthorization() ?? .denied
    }

    func recheckPhotos() {
        photos = app.env?.photos.authorizationStatus() ?? .notDetermined
    }

    // MARK: 3. Root

    func loadRoots() async {
        rootsError = nil
        do {
            roots = try await app.driveRoots().map { .init(id: $0.remoteId, name: $0.name) }
            reuseRootId = app.hardeningAvailable ? roots.first?.id : nil
        } catch {
            roots = []
            rootsError = ErrorText.message(for: error)
        }
    }

    var rootChoice: RootChoice {
        if let id = reuseRootId, let root = roots.first(where: { $0.id == id }) { return .reuse(rootId: id, name: root.name) }
        return .createNew(name: rootName)
    }

    // MARK: 6. Notifications

    func requestNotifications() async {
        notifications = await app.notificationService.requestAuthorization() ? .granted : .denied
    }

    // MARK: 7. NAS

    func chooseNas() async {
        guard let picked = await app.pickLocalFolder() else { return }
        if picked.isReuse, !app.hardeningAvailable {
            app.showNotice("Dùng lại thư mục cũ cần chức năng khôi phục, chưa khả dụng trong bản build này.", isError: true)
            return
        }
        nas = picked
    }

    func testNas() async {
        guard let current = nas else { return }
        nasTesting = true
        nas = await app.testConnection(current)
        nasTesting = false
    }

    func removeNas() { nas = nil }

    // MARK: 8. Summary

    func loadSummary() async {
        libraryCount = nil
        switch scope {
        case .full: libraryCount = await LibraryCounter.count(since: nil, timeZone: timeZone)
        case .since(let day): libraryCount = await LibraryCounter.count(since: day, timeZone: timeZone)
        case .newOnly: libraryCount = 0
        }
        driveFreeBytes = try? await app.env?.drive.quota()?.availableBytes
        await app.refresh()
    }

    var reusing: Bool {
        if case .reuse = rootChoice { return true }
        return nas?.isReuse ?? false
    }

    var bytesToFree: Int64? { MacDiskState.bytesToFree(freeBytes: app.macFreeBytes, settings: app.persistedSettings) }

    // MARK: 9. Start

    func start() async {
        // The sidebar lets the owner change earlier answers: check the whole plan again.
        if let problem = OnboardingProgress.firstProblem(facts) {
            startError = "Bước \(problem.rawValue) (\(problem.title)) chưa hợp lệ. Quay lại bước đó để sửa trước khi bắt đầu."
            return
        }
        guard let identity else {
            startError = "Chưa đăng nhập Google. Quay lại bước 1."
            return
        }
        startError = nil
        var plan = FirstStartPlan(identity: identity, root: rootChoice, timeZone: timeZone, scope: scope, nas: nas)
        if let current = plan.nas { plan.nas = current }
        await app.performFirstStart(plan)
    }
}
