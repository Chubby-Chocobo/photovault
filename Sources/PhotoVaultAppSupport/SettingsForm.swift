import Foundation
import PhotoVaultCore

public enum SettingsIssue: Equatable, Sendable {
    case criticalNotBelowLow
    case dayThresholdOutOfRange
    case rateNotPositive
    case stagingNotPositive
    case integrityIntervalOutOfRange
    case unsupportedPlaceLanguage
    case invalidHomeCountry

    public var message: String {
        switch self {
        case .criticalNotBelowLow: "Ngưỡng nguy cấp phải nhỏ hơn ngưỡng thấp."
        case .dayThresholdOutOfRange: "Ngưỡng thư mục ngày phải từ 2 đến 200 ảnh."
        case .rateNotPositive: "Tốc độ export phải lớn hơn 0 GB/giờ."
        case .stagingNotPositive: "Giới hạn staging phải lớn hơn 0 GB."
        case .integrityIntervalOutOfRange: "Chu kỳ kiểm tra toàn vẹn phải từ 1 đến 365 ngày."
        case .unsupportedPlaceLanguage: "Ngôn ngữ địa danh chỉ hỗ trợ tiếng Việt hoặc English."
        case .invalidHomeCountry: "Mã quốc gia nhà phải gồm 2 chữ cái."
        }
    }
}

/// The Settings form works on whole gigabytes; these views convert to the byte fields of `GlobalSettings`.
extension GlobalSettings {
    public var backfillGBPerHour: Int {
        get { Int(backfillBytesPerHour / Self.GiB) }
        set { backfillBytesPerHour = Int64(max(0, newValue)) * Self.GiB }
    }

    public var lowWatermarkGB: Int {
        get { Int(lowWatermarkBytes / Self.GiB) }
        set { lowWatermarkBytes = Int64(max(0, newValue)) * Self.GiB }
    }

    public var criticalWatermarkGB: Int {
        get { Int(criticalWatermarkBytes / Self.GiB) }
        set { criticalWatermarkBytes = Int64(max(0, newValue)) * Self.GiB }
    }

    public var stagingSoftLimitGB: Int {
        get { Int(stagingSoftLimitBytes / Self.GiB) }
        set { stagingSoftLimitBytes = Int64(max(0, newValue)) * Self.GiB }
    }
}

public enum SettingsValidator {
    public static let dayThresholdRange = 2...200
    public static let integrityDaysRange = 1...365

    public static func validate(_ settings: GlobalSettings) -> [SettingsIssue] {
        var issues: [SettingsIssue] = []
        if settings.criticalWatermarkBytes >= settings.lowWatermarkBytes { issues.append(.criticalNotBelowLow) }
        if !dayThresholdRange.contains(settings.dayFolderThreshold) { issues.append(.dayThresholdOutOfRange) }
        if settings.backfillBytesPerHour <= 0 { issues.append(.rateNotPositive) }
        if settings.stagingSoftLimitBytes <= 0 { issues.append(.stagingNotPositive) }
        if !integrityDaysRange.contains(settings.integrityCheckIntervalDays) { issues.append(.integrityIntervalOutOfRange) }
        if !["vi", "en"].contains(settings.placeNameLanguage) { issues.append(.unsupportedPlaceLanguage) }
        let country = settings.homeCountryCode
        if country.count != 2 || !country.allSatisfy({ $0.isASCII && $0.isLetter }) { issues.append(.invalidHomeCountry) }
        return issues
    }

    /// True when the change affects which assets go where, so the engine must recompute (FR-19).
    /// Pure operating knobs (rate, watermarks, power, network, integrity interval, launch at login) do not.
    public static func needsEngineRecompute(from old: GlobalSettings, to new: GlobalSettings) -> Bool {
        var a = old
        var b = new
        for settings in [\GlobalSettings.backfillBytesPerHour, \.lowWatermarkBytes, \.criticalWatermarkBytes, \.stagingSoftLimitBytes] {
            a[keyPath: settings] = 0
            b[keyPath: settings] = 0
        }
        for flag in [\GlobalSettings.backfillOnlyOnACPower, \.allUploadsOnlyOnACPower, \.pauseOnExpensiveNetwork, \.launchAtLogin] {
            a[keyPath: flag] = false
            b[keyPath: flag] = false
        }
        a.integrityCheckIntervalDays = 0
        b.integrityCheckIntervalDays = 0
        return a != b
    }

    /// Adds a chat-app album name; false for blank or duplicate names (case-insensitive, FR-20).
    public static func addingAlbum(_ name: String, to albums: inout [String]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !albums.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        albums.append(trimmed)
        return true
    }
}
