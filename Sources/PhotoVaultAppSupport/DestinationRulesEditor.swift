import Foundation
import PhotoVaultCore

/// One row of the FR-72 rule editor.
public enum RuleKey: String, CaseIterable, Sendable {
    case camera, screenshot, saved, photo, video, raw, original, edited, sidecarJson, sidecarXmp

    public var label: String {
        switch self {
        case .camera: "Camera"
        case .screenshot: tr(vi: "Ảnh chụp màn hình", en: "Screenshots")
        case .saved: tr(vi: "Lưu từ app", en: "Saved from apps")
        case .photo: tr(vi: "Ảnh (gồm video Live Photo)", en: "Photos (including Live Photo videos)")
        case .video: "Video"
        case .raw: "RAW"
        case .original: tr(vi: "Bản gốc", en: "Originals")
        case .edited: tr(vi: "Bản chỉnh sửa", en: "Edited versions")
        case .sidecarJson: "JSON"
        case .sidecarXmp: "XMP"
        }
    }

    public static var groups: [(title: String, keys: [RuleKey])] {
        [
            ("Category", [.camera, .screenshot, .saved]),
            (tr(vi: "Loại", en: "Type"), [.photo, .video, .raw]),
            (tr(vi: "Phiên bản", en: "Version"), [.original, .edited]),
            ("Sidecar", [.sidecarJson, .sidecarXmp]),
        ]
    }
}

extension DestinationRules {
    public func isOn(_ key: RuleKey) -> Bool {
        switch key {
        case .camera: categories.contains(.camera)
        case .screenshot: categories.contains(.screenshot)
        case .saved: categories.contains(.saved)
        case .photo: includePhotos
        case .video: includeVideos
        case .raw: includeRaw
        case .original: includeOriginals
        case .edited: includeEdited
        case .sidecarJson: sidecarJson
        case .sidecarXmp: sidecarXmp
        }
    }

    public mutating func set(_ key: RuleKey, _ on: Bool) {
        func toggle(_ category: AssetCategory) {
            if on { categories.insert(category) } else { categories.remove(category) }
        }
        switch key {
        case .camera: toggle(.camera)
        case .screenshot: toggle(.screenshot)
        case .saved: toggle(.saved)
        case .photo: includePhotos = on
        case .video: includeVideos = on
        case .raw: includeRaw = on
        case .original: includeOriginals = on
        case .edited: includeEdited = on
        case .sidecarJson: sidecarJson = on
        case .sidecarXmp: sidecarXmp = on
        }
    }

    public var skipLargerThanGB: Int? {
        get { skipLargerThanBytes.map { Int($0 / GlobalSettings.GiB) } }
        set { skipLargerThanBytes = newValue.map { Int64(max(1, $0)) * GlobalSettings.GiB } }
    }
}

/// Destination rules are combined with the global switches by AND (FR-72): a global switch that is
/// off locks the matching row.
public enum RuleEditor {
    public static func ceilingBlocks(_ key: RuleKey, settings: GlobalSettings) -> Bool {
        switch key {
        case .video: !settings.includeVideos
        case .edited: !settings.includeEdited
        case .sidecarJson: !settings.sidecarJsonEnabled
        case .sidecarXmp: !settings.sidecarXmpEnabled
        default: false
        }
    }

    public static func isEffective(_ key: RuleKey, rules: DestinationRules, settings: GlobalSettings) -> Bool {
        rules.isOn(key) && !ceilingBlocks(key, settings: settings)
    }

    /// "Hiệu lực: Camera + Lưu từ app · Ảnh + Video · …".
    public static func effectiveSummary(rules: DestinationRules, settings: GlobalSettings) -> String {
        let parts = RuleKey.groups.map { group -> String in
            let names = group.keys.filter { isEffective($0, rules: rules, settings: settings) }.map(\.label)
            return names.isEmpty ? "—" : names.joined(separator: " + ")
        }
        var text = parts.joined(separator: " · ")
        if let skip = rules.skipLargerThanGB { text += tr(vi: " · bỏ qua > \(skip) GB", en: " · skip > \(skip) GB") }
        return text
    }

    /// Lines of the "Thay đổi chưa áp dụng" preview. `counts` adds "~N asset" where the app knows it.
    public static func changeLines(
        old: DestinationRules, new: DestinationRules, oldScope: ScopeMode, newScope: ScopeMode,
        settings: GlobalSettings, counts: [RuleKey: Int] = [:]
    ) -> [String] {
        var lines: [String] = []
        for key in RuleKey.allCases where old.isOn(key) != new.isOn(key) && !ceilingBlocks(key, settings: settings) {
            let amount = counts[key].map { count -> String in
                let n = VietnameseFormat.integer(count)
                return tr(vi: "~\(n) asset", en: L10n.plural(count, one: "~\(n) asset", other: "~\(n) assets"))
            }
            if new.isOn(key) {
                lines.append(tr(vi: "Bật \(key.label) → xếp hàng thêm", en: "Turn on \(key.label) → queue more") + (amount.map { " \($0)" } ?? ""))
            } else {
                lines.append(
                    tr(vi: "Tắt \(key.label) → huỷ job còn chờ", en: "Turn off \(key.label) → cancel pending jobs")
                        + (amount.map { tr(vi: " của \($0)", en: " for \($0)") } ?? ""))
            }
        }
        if old.skipLargerThanBytes != new.skipLargerThanBytes {
            if let skip = new.skipLargerThanGB {
                lines.append(tr(vi: "Bỏ qua file > \(skip) GB → huỷ job còn chờ của file lớn hơn", en: "Skip files > \(skip) GB → cancel pending jobs for larger files"))
            } else {
                lines.append(tr(vi: "Không bỏ qua file lớn → xếp hàng lại file đã bỏ qua", en: "Stop skipping large files → requeue skipped files"))
            }
        }
        if oldScope != newScope {
            lines.append(tr(vi: "Đổi phạm vi → mở rộng thì xếp hàng thêm, thu hẹp chỉ huỷ phần chưa upload", en: "Change scope → widening queues more, narrowing only cancels what isn't uploaded yet"))
        }
        return lines
    }
}
