import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Owner actions of the organization layer (day folders, places, views, device groups).
extension SyncCoordinator {
    /// "Sắp xếp lại": how many days and files would change with the current N (T10).
    public func resortPreview() async throws -> ResortPreview { try await ResortService(env: organization.env).preview() }

    /// Applies the current N to days that are not promoted yet; never demotes.
    @discardableResult
    public func resortApply() async throws -> ResortPreview { try await exclusive { try await ResortService(env: organization.env).apply() } }

    /// "Làm mới địa danh" (FR-106): forgets every geocode and asks again.
    public func refreshPlaceNames() async throws { try await exclusive { try await organization.scheduler.refreshAll() } }

    /// "Dựng lại view": brings the shortcut trees back to the desired state, owner removals included.
    public func rebuildViews() async throws {
        try await exclusive { try await organization.env.store.write { db in try ViewStage.requestRebuild(db) } }
    }

    /// Renames a "By device" group; throws `DeviceGroupError.duplicateName` when the name is taken.
    public func renameDeviceGroup(_ groupId: String, to name: String) async throws {
        try await exclusive { try await DeviceGroupService(env: organization.env).rename(groupId: groupId, to: name) }
    }

    /// Moves a camera model (normalized `MAKE|MODEL` key) into another group.
    public func mergeDeviceModel(_ makeModelKey: String, into groupId: String) async throws {
        try await exclusive { try await DeviceGroupService(env: organization.env).merge(makeModelKey: makeModelKey, into: groupId) }
    }

    /// Re-evaluates sidecars, views and descriptions of every asset (reconciliation, FR-93).
    public func refreshOrganization() async throws { try await exclusive { try await organization.settingsChanged() } }
}
