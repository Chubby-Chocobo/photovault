import AppKit
import Foundation
import PhotoVaultCore
import PhotoVaultEngine

/// Menu bar actions (FR-60).
extension AppModel {
    func syncNow() { requestSync(.manual) }

    func pauseAll() {
        guard let env else { return }
        Task {
            await env.coordinator.pauseAll()
            await refreshSnapshot()
        }
    }

    func resumeAll() {
        guard let env else { return }
        Task {
            await env.coordinator.resumeAll()
            requestSync(.manual)
        }
    }

    func togglePause(_ record: DestinationRecord) {
        guard let env else { return }
        let paused = record.status == .paused(.userPaused)
        Task {
            do {
                if paused {
                    try await env.coordinator.resume(destination: record.id)
                    requestSync(.manual)
                } else {
                    try await env.coordinator.pause(destination: record.id)
                }
                await refreshSnapshot()
            } catch {
                showError(error)
            }
        }
    }

    /// Whether the pause button of a row should offer "Tiếp tục".
    func isOwnerPaused(_ record: DestinationRecord) -> Bool { record.status == .paused(.userPaused) }

    func openGoogleDrive() {
        guard let rootId = driveRecord?.config.driveRootId, let url = DriveRootService.webURL(rootId: rootId) else {
            showNotice(tr(vi: "Chưa có thư mục gốc trên Drive.", en: "There is no root folder on Drive yet."), isError: true)
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Reveals a local destination's folder in Finder; the bookmark gives the current location.
    func revealInFinder(_ record: DestinationRecord) {
        let failure = tr(
            vi: "Không mở được thư mục. Hãy chọn lại thư mục trong Settings › Đích.",
            en: "Could not open the folder. Choose the folder again in Settings › Destinations.")
        guard let bookmark = record.config.bookmark else {
            showNotice(failure, isError: true)
            return
        }
        Task {
            // Resolving can block on a slow volume: keep it off the main thread.
            let url = await Task.detached(priority: .userInitiated) { FolderPicker.resolvedURL(bookmark: bookmark) }.value
            guard let url else {
                showNotice(failure, isError: true)
                return
            }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            NSWorkspace.shared.open(url)
        }
    }

    /// Where `RotatingFileLog` writes, for the log window.
    var logDirectory: URL? { env?.layout.logs }

    func revealLog() {
        guard let env else { return }
        NSWorkspace.shared.open(env.layout.logs)
    }

    func openSystemSettings(_ pane: SystemSettingsPane) {
        NSWorkspace.shared.open(pane.url)
    }

    func open(_ request: WindowRequest) {
        NSApp.activate(ignoringOtherApps: true)
        if case .settings(let tab) = request { settingsTab = tab }
        windowRequest = request
    }

    /// The window for a relaunch of the running app: onboarding until it is done, then Settings.
    func openOnReopen() {
        switch phase {
        case .launching: return
        case .needsOnboarding: open(.onboarding)
        case .running: open(.settings(settingsTab))
        }
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }
}

enum SystemSettingsPane {
    case photosPrivacy, notifications, storage

    var url: URL {
        switch self {
        case .photosPrivacy: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!
        case .notifications: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        case .storage: URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
        }
    }
}
