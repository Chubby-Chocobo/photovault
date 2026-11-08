import AppKit
import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultDrive
import PhotoVaultEngine
import PhotoVaultLocal
import PhotoVaultPhotos
import PhotoVaultStore

/// Why the app cannot start. Each case ends in an alert and a quit.
enum LaunchFailure: Error {
    /// An unsandboxed build without `--dev-container` would split state from the signed build (spec 8.2).
    case unsandboxed
    /// Another process holds the container lock (FR-54).
    case alreadyRunning
    case other(String)

    var alertTitle: String {
        switch self {
        case .unsandboxed: "PhotoVault cần chạy với --dev-container"
        case .alreadyRunning: "PhotoVault đang chạy"
        case .other: "PhotoVault không thể khởi động"
        }
    }

    var alertText: String {
        switch self {
        case .unsandboxed:
            "Bản này không chạy trong sandbox nên dùng chung dữ liệu với bản đã ký sẽ làm hỏng trạng thái. Chạy lại với đối số --dev-container để dùng thư mục dữ liệu riêng (PhotoVault-dev), hoặc build bản đã ký."
        case .alreadyRunning:
            "Một bản PhotoVault khác đang dùng cùng thư mục dữ liệu. Tìm biểu tượng PhotoVault trên menu bar."
        case .other(let message): message
        }
    }
}

/// Composition root: everything the app shares, built once at launch (spec 8.2, FR-54).
struct AppEnvironment: Sendable {
    let layout: ContainerLayout
    let instanceLock: InstanceLock
    let store: Store
    let settings: SettingsStore
    let registry: DestinationRegistry
    let coordinator: SyncCoordinator
    let photos: PhotoKitSource
    /// Always exists; it joins the registry when a Drive destination row does.
    let drive: GoogleDriveDestination
    let auth: GoogleAuthSession
    let googleConfigured: Bool
    let fileLog: RotatingFileLog
    let log: AppLogSink
    let system: SystemMonitor
    let disk: VolumeDiskSpaceProvider
    let backups: DatabaseBackup
    let notificationLedger: NotificationLedgerFile

    static let setupReadmeSection = "README › Google Cloud setup"

    static func make(
        arguments: [String] = CommandLine.arguments, bundle: Bundle = .main
    ) throws -> AppEnvironment {
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LaunchFailure.other("Không tìm thấy thư mục Application Support.")
        }
        let layout: ContainerLayout
        do {
            layout = try ContainerLocator.resolve(arguments: arguments, applicationSupport: applicationSupport)
            try ContainerLocator.prepare(layout)
        } catch EngineError.unsandboxedBuild {
            throw LaunchFailure.unsandboxed
        } catch {
            throw LaunchFailure.other("Không tạo được thư mục dữ liệu: \(error.localizedDescription)")
        }

        let lock: InstanceLock
        do {
            lock = try InstanceLock.acquire(containerDirectory: layout.root)
        } catch InstanceLock.LockError.alreadyRunning {
            throw LaunchFailure.alreadyRunning
        } catch {
            throw LaunchFailure.other("Không khoá được thư mục dữ liệu: \(error.localizedDescription)")
        }

        let fileLog = RotatingFileLog(directory: layout.logs)
        let log = AppLogSink(file: fileLog)
        let backups = DatabaseBackup(directory: layout.backups)
        let store: Store
        let settings: SettingsStore
        do {
            store = try Store.open(at: layout.database, backups: backups)
            settings = try SettingsStore(store: store)
        } catch {
            log.log(.fault, category: "launch", "database could not be opened: \(type(of: error))")
            throw LaunchFailure.other("Không mở được cơ sở dữ liệu. Chi tiết nằm trong thư mục log.")
        }

        let clientID = (bundle.object(forInfoDictionaryKey: "PVGoogleClientID") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let clientSecret = (bundle.object(forInfoDictionaryKey: "PVGoogleClientSecret") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let transport = LoggingHTTPTransport(wrapping: URLSessionTransport(), log: log)
        let oauth = OAuthClient(
            config: OAuthConfig(clientID: clientID, clientSecret: clientSecret.isEmpty ? nil : clientSecret),
            transport: transport,
            openURL: { url in await MainActor.run { NSWorkspace.shared.open(url) } })
        let auth = GoogleAuthSession(oauth: oauth, keychain: SystemKeychainStore(), log: log)

        let records: [DestinationRecord]
        do {
            records = try store.read { db in try DestinationRepository.fetchAll(db) }
        } catch {
            throw LaunchFailure.other("Không đọc được danh sách đích: \(error.localizedDescription)")
        }
        let driveRecord = records.first { $0.id == .googleDrive }
        let drive = GoogleDriveDestination(
            transport: transport, auth: auth, rootId: driveRecord?.config.driveRootId, log: log)
        let disk = VolumeDiskSpaceProvider()
        var live: [any Destination] = []
        if driveRecord != nil { live.append(drive) }
        for record in records where record.kind == .localFolder {
            if let local = DestinationBuilder.local(record: record, store: store, disk: disk, log: log) {
                live.append(local)
            } else {
                log.log(.error, category: "launch", "destination \(record.id) has no folder bookmark")
            }
        }
        let registry = DestinationRegistry(live)

        let system = SystemMonitor()
        let photos = PhotoKitSource()
        let environment = EngineEnvironment(
            store: store, photos: photos, destinations: registry, metadataReader: ImageIOMetadataReader(),
            utiResolver: UTTypeResolver(), disk: disk, system: system, log: log, stagingDirectory: layout.staging,
            containerDirectory: layout.root, settings: settings, geocoder: CLGeocoderReverseGeocoder())
        return AppEnvironment(
            layout: layout, instanceLock: lock, store: store, settings: settings, registry: registry,
            coordinator: SyncCoordinator(env: environment), photos: photos, drive: drive, auth: auth,
            googleConfigured: !clientID.isEmpty, fileLog: fileLog, log: log, system: system, disk: disk, backups: backups,
            notificationLedger: NotificationLedgerFile(url: layout.root.appendingPathComponent("notification-ledger.json")))
    }
}

/// Builds `LocalFolderDestination`s from stored rows and fresh folder picks.
enum DestinationBuilder {
    static func local(record: DestinationRecord, store: Store, disk: VolumeDiskSpaceProvider, log: AppLogSink) -> LocalFolderDestination? {
        guard record.kind == .localFolder, let bookmark = record.config.bookmark else { return nil }
        return local(id: record.id, bookmark: bookmark, store: store, disk: disk, log: log)
    }

    static func local(id: DestinationID, bookmark: Data, store: Store, disk: VolumeDiskSpaceProvider, log: AppLogSink) -> LocalFolderDestination {
        let root = SecurityScopedBookmarkRoot(bookmark: bookmark) { fresh in
            // A stale bookmark was re-created while resolving: persist it so the next launch uses the new one.
            Task {
                do {
                    try await store.write { db in
                        guard var record = try DestinationRepository.fetch(db, id: id) else { return }
                        record.config.bookmark = fresh
                        try DestinationRepository.save(db, record)
                    }
                } catch {
                    log.log(.error, category: "destination", "could not persist refreshed bookmark for \(id)")
                }
            }
        }
        return LocalFolderDestination(id: id, root: root, disk: disk, log: log)
    }
}

extension DestinationRecord: @retroactive Identifiable {}
