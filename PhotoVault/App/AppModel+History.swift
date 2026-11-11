import AppKit
import Foundation
import GRDB
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import PhotoVaultStore
import UniformTypeIdentifiers

/// Actions of the History window. File names stay in the window and in a CSV the owner saves; the log gets
/// counts and error types only.
extension AppModel {
    /// Reads the database on GRDB's reader, off the main thread; nil before the engine is up.
    func historyRead<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T? {
        guard let store = env?.store else { return nil }
        do {
            return try await store.read(body)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The window shows that the read failed; the log gets the error type, never what was being read.
            env?.log.log(.error, category: "history", "read failed type=\(type(of: error))")
            throw error
        }
    }

    /// "Thử lại" on files: the owner's retry transitions only, then a sync.
    func retryHistoryFiles(_ jobs: [JobIdentity]) async {
        guard let env, !jobs.isEmpty else { return }
        await retried { try await env.coordinator.retryFiles(jobs) }
    }

    func retryFailedFiles(ofRun runId: Int64) async {
        guard let env else { return }
        await retried { try await env.coordinator.retryFailedFiles(ofRun: runId) }
    }

    func retryFailedUploads(ofImport sourceId: SourceID) async {
        guard let env else { return }
        await retried { try await env.coordinator.retryFailedUploads(ofImport: sourceId) }
    }

    private func retried(_ command: () async throws -> Int) async {
        do {
            let count = try await command()
            showNotice(count == 0
                ? tr(vi: "Không có file lỗi nào để thử lại.", en: "There are no failed files to retry.")
                : tr(vi: "Đã đưa \(L10n.integer(count)) file vào hàng chờ upload.",
                     en: L10n.plural(count, one: "1 file is queued to upload again.", other: "\(L10n.integer(count)) files are queued to upload again.")))
            if count > 0 { requestSync(.manual) }
        } catch {
            env?.log.log(.error, category: "history", "retry failed type=\(type(of: error))")
            showError(error)
        }
    }

    /// "Mở trên Drive" or "Hiện trong Finder" for a file that is at the destination.
    func revealBackedUpFile(destination id: DestinationID, remoteId: String) {
        guard let record = destinations.first(where: { $0.id == id }) else { return }
        if record.kind == .googleDrive {
            guard let url = HistoryLinks.driveFile(remoteId: remoteId) else { return }
            NSWorkspace.shared.open(url)
            return
        }
        guard let bookmark = record.config.bookmark else { return }
        Task {
            let root = await Task.detached(priority: .userInitiated) { FolderPicker.resolvedURL(bookmark: bookmark) }.value
            guard let root, let file = HistoryLinks.localFile(root: root, relativePath: remoteId) else {
                showNotice(tr(vi: "Không mở được thư mục của đích này.", en: "Could not open this destination's folder."), isError: true)
                return
            }
            let accessing = root.startAccessingSecurityScopedResource()
            defer { if accessing { root.stopAccessingSecurityScopedResource() } }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    /// Asks where to save, then writes the CSV off the main thread: the header, then page after page of lines from
    /// `next` (given the cursor of the previous page) until it hands back no cursor. Nothing is written unless the
    /// owner picks a file.
    func exportHistoryCSV<Cursor: Sendable>(
        suggestedName: String, header: String, next: @Sendable @escaping (Cursor?) async throws -> (lines: [String], cursor: Cursor?)
    ) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await Task.detached(priority: .userInitiated) {
                guard FileManager.default.createFile(atPath: url.path, contents: Data((HistoryCSV.byteOrderMark + header).utf8)) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                var cursor: Cursor?
                repeat {
                    let page = try await next(cursor)
                    try handle.write(contentsOf: Data(page.lines.joined().utf8))
                    cursor = page.cursor
                } while cursor != nil
            }.value
            showNotice(tr(vi: "Đã lưu file CSV.", en: "The CSV file was saved."))
        } catch {
            env?.log.log(.error, category: "history", "csv export failed type=\(type(of: error))")
            showNotice(tr(vi: "Không lưu được file CSV.", en: "The CSV file could not be saved."), isError: true)
        }
    }
}
