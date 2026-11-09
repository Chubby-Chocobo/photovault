import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine

/// Day folders, views, device groups and place names (spec 8.7, FR-103, FR-104, FR-106).
extension AppModel {
    func resortPreview() async -> ResortPreview? {
        guard let env else { return nil }
        do { return try await env.coordinator.resortPreview() } catch {
            showError(error)
            return nil
        }
    }

    func resortApply() async {
        guard let env else { return }
        do {
            let result = try await env.coordinator.resortApply()
            requestSync(.manual)
            showNotice(tr(
                vi: "Đã xếp hàng chuyển \(VietnameseFormat.integer(result.files)) file của \(VietnameseFormat.integer(result.days)) ngày.",
                en: "Queued \(L10n.plural(result.files, one: "1 file", other: "\(VietnameseFormat.integer(result.files)) files")) from \(L10n.plural(result.days, one: "1 day", other: "\(VietnameseFormat.integer(result.days)) days")) to move."))
        } catch {
            showError(error)
        }
    }

    func rebuildViews() async {
        guard let env else { return }
        do {
            try await env.coordinator.rebuildViews()
            requestSync(.manual)
            showNotice(tr(vi: "Đã yêu cầu dựng lại view.", en: "Requested a rebuild of the views."))
        } catch {
            showError(error)
        }
    }

    func refreshPlaceNames() async {
        guard let env else { return }
        do {
            try await env.coordinator.refreshPlaceNames()
            requestSync(.manual)
            showNotice(tr(vi: "Đang tra lại địa danh ở nền.", en: "Looking up place names again in the background."))
        } catch {
            showError(error)
        }
    }

    /// Returns false when the name clashes (the caller offers a merge, FR-104).
    func renameDeviceGroup(_ groupId: String, to name: String) async -> DeviceGroupError? {
        guard let env else { return nil }
        do {
            try await env.coordinator.renameDeviceGroup(groupId, to: name)
            requestSync(.manual)
            return nil
        } catch let error as DeviceGroupError {
            return error
        } catch {
            showError(error)
            return nil
        }
    }

    func mergeDeviceModels(_ models: [String], into groupId: String) async {
        guard let env else { return }
        do {
            for key in models { try await env.coordinator.mergeDeviceModel(key, into: groupId) }
            requestSync(.manual)
            showNotice(tr(vi: "Đã gộp nhóm thiết bị.", en: "Merged the device groups."))
        } catch {
            showError(error)
        }
    }

    // MARK: Read models

    func deviceGroups() async -> [AppQueries.DeviceGroupInfo] {
        guard let env else { return [] }
        return (try? await env.store.read { db in try AppQueries.deviceGroups(db) }) ?? []
    }

    func geocodeProgress() async -> AppQueries.GeocodeProgress? {
        guard let env else { return nil }
        return try? await env.store.read { db in try AppQueries.geocodeProgress(db) }
    }

    func viewCounts() async -> AppQueries.ViewCounts? {
        guard let env else { return nil }
        return try? await env.store.read { db in try AppQueries.viewCounts(db) }
    }

    func ruleCounts() async -> [RuleKey: Int] {
        guard let env else { return [:] }
        return (try? await env.store.read { db in try AppQueries.ruleCounts(db) }) ?? [:]
    }
}
