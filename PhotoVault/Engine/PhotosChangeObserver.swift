import Foundation
import Photos
import PhotoVaultAppSupport

/// Photos library changes, debounced 30 to 60 seconds so an import burst becomes one cycle (FR-14).
final class PhotosChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let debouncer: TriggerDebouncer
    private var registered = false
    private let lock = NSLock()

    init(onChange: @escaping @Sendable () async -> Void) {
        debouncer = TriggerDebouncer(quiet: 30, maxWait: 60, fire: onChange)
        super.init()
    }

    /// Registers once Photos access is granted; registering earlier would prompt for access.
    func startIfAuthorized() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        lock.withLock {
            guard !registered else { return }
            PHPhotoLibrary.shared().register(self)
            registered = true
        }
    }

    func stop() {
        lock.withLock {
            guard registered else { return }
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
            registered = false
        }
        Task { await debouncer.cancel() }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { await debouncer.signal() }
    }
}
