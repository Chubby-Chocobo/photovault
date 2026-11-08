import Foundation
import PhotoVaultCore

/// One row of the FR-72 rule editor.
public enum RuleKey: String, CaseIterable, Sendable {
    case camera, screenshot, saved, photo, video, raw, original, edited, sidecarJson, sidecarXmp

    public var label: String {
        switch self {
        case .camera: "Camera"
        case .screenshot: "Ảnh chụp màn hình"
        case .saved: "Lưu từ app"
        case .photo: "Ảnh (gồm video Live Photo)"
        case .video: "Video"
        case .raw: "RAW"
        case .original: "Bản gốc"
        case .edited: "Bản chỉnh sửa"
        case .sidecarJson: "JSON"
        case .sidecarXmp: "XMP"
        }
    }

    public static let groups: [(title: String, keys: [RuleKey])] = [
        ("Category", [.camera, .screenshot, .saved]),
        ("Loại", [.photo, .video, .raw]),
        ("Phiên bản", [.original, .edited]),
        ("Sidecar", [.sidecarJson, .sidecarXmp]),
    ]
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
        if let skip = rules.skipLargerThanGB { text += " · bỏ qua > \(skip) GB" }
        return text
    }

    /// Lines of the "Thay đổi chưa áp dụng" preview. `counts` adds "~N asset" where the app knows it.
    public static func changeLines(
        old: DestinationRules, new: DestinationRules, oldScope: ScopeMode, newScope: ScopeMode,
        settings: GlobalSettings, counts: [RuleKey: Int] = [:]
    ) -> [String] {
        var lines: [String] = []
        for key in RuleKey.allCases where old.isOn(key) != new.isOn(key) && !ceilingBlocks(key, settings: settings) {
            let amount = counts[key].map { "~" + VietnameseFormat.integer($0) + " asset" }
            if new.isOn(key) {
                lines.append("Bật \(key.label) → xếp hàng thêm" + (amount.map { " \($0)" } ?? ""))
            } else {
                lines.append("Tắt \(key.label) → huỷ job còn chờ" + (amount.map { " của \($0)" } ?? ""))
            }
        }
        if old.skipLargerThanBytes != new.skipLargerThanBytes {
            if let skip = new.skipLargerThanGB {
                lines.append("Bỏ qua file > \(skip) GB → huỷ job còn chờ của file lớn hơn")
            } else {
                lines.append("Không bỏ qua file lớn → xếp hàng lại file đã bỏ qua")
            }
        }
        if oldScope != newScope {
            lines.append("Đổi phạm vi → mở rộng thì xếp hàng thêm, thu hẹp chỉ huỷ phần chưa upload")
        }
        return lines
    }
}
