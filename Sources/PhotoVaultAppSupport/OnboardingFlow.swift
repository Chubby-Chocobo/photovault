import Foundation
import PhotoVaultCore

/// The nine onboarding steps in the order FR-01 prescribes.
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case googleSignIn = 1, photosPermission, driveRoot, archiveTimeZone, syncMode, notifications, nas, summary, start

    public var title: String {
        switch self {
        case .googleSignIn: tr(vi: "Đăng nhập Google", en: "Sign in to Google")
        case .photosPermission: tr(vi: "Quyền Photos", en: "Photos access")
        case .driveRoot: tr(vi: "Thư mục gốc Drive", en: "Drive root folder")
        case .archiveTimeZone: tr(vi: "Múi giờ lưu trữ", en: "Archive time zone")
        case .syncMode: "Sync mode"
        case .notifications: tr(vi: "Thông báo", en: "Notifications")
        case .nas: tr(vi: "NAS (tuỳ chọn)", en: "NAS (optional)")
        case .summary: tr(vi: "Tóm tắt", en: "Summary")
        case .start: tr(vi: "Bắt đầu", en: "Start")
        }
    }
}

/// What the wizard knows about the owner's progress; the view model fills it in.
public struct OnboardingFacts: Equatable, Sendable {
    public var googleSignedIn = false
    public var photosAuthorization: PhotosAuthorization = .notDetermined
    public var rootName = "Camera Uploads"
    /// An earlier PhotoVault root exists and the owner still has to choose reuse or new.
    public var rootChoicePending = false
    public var nasFolderChosen = false
    public var nasTestPassed = false
    public var started = false

    public init() {}
}

/// Step state machine: forward only after the step's requirement holds, back until Start is pressed.
public struct OnboardingProgress: Equatable, Sendable {
    public private(set) var step: OnboardingStep = .googleSignIn
    public private(set) var furthest: OnboardingStep = .googleSignIn

    public init() {}

    public func canAdvance(_ facts: OnboardingFacts) -> Bool { Self.isSatisfied(step, facts) }

    /// Whether the requirement of `step` holds for the current facts (Start itself never "passes").
    public static func isSatisfied(_ step: OnboardingStep, _ facts: OnboardingFacts) -> Bool {
        switch step {
        case .googleSignIn: return facts.googleSignedIn
        case .photosPermission: return facts.photosAuthorization.allowsReading
        case .driveRoot: return RootNameValidator.validate(facts.rootName) == nil && !facts.rootChoicePending
        case .nas: return !facts.nasFolderChosen || facts.nasTestPassed
        case .start: return false
        case .archiveTimeZone, .syncMode, .notifications, .summary: return true
        }
    }

    /// The first step before `target` whose requirement no longer holds, if any.
    public static func firstUnsatisfied(before target: OnboardingStep, _ facts: OnboardingFacts) -> OnboardingStep? {
        OnboardingStep.allCases.first { $0 < target && !isSatisfied($0, facts) }
    }

    /// Start re-validates the whole plan: the first broken step, nil when everything holds.
    public static func firstProblem(_ facts: OnboardingFacts) -> OnboardingStep? { firstUnsatisfied(before: .start, facts) }

    /// The optional NAS step offers "Bỏ qua" while no folder is chosen.
    public func canSkip(_ facts: OnboardingFacts) -> Bool { step == .nas && !facts.nasFolderChosen }

    @discardableResult
    public mutating func advance(_ facts: OnboardingFacts) -> Bool {
        guard canAdvance(facts), let next = OnboardingStep(rawValue: step.rawValue + 1) else { return false }
        step = next
        furthest = max(furthest, next) 
        return true
    }

    @discardableResult
    public mutating func back(_ facts: OnboardingFacts) -> Bool {
        guard !facts.started, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return false }
        step = previous
        return true
    }

    /// Sidebar jump: only to steps already reached, not after Start, and forward only while every
    /// earlier step's requirement still holds (the owner may have changed an answer since).
    public func canJump(to target: OnboardingStep, _ facts: OnboardingFacts) -> Bool {
        guard !facts.started, target <= furthest else { return false }
        return target <= step || Self.firstUnsatisfied(before: target, facts) == nil
    }

    @discardableResult
    public mutating func jump(to target: OnboardingStep, _ facts: OnboardingFacts) -> Bool {
        guard canJump(to: target, facts) else { return false }
        step = target
        return true
    }
}

extension OnboardingStep: Comparable {
    public static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Phases listed on the last step (FR-01 step 9, FR-15, FR-10, FR-51).
public enum OnboardingPhase: String, CaseIterable, Sendable {
    case baseline, scan, restore, upload

    public var title: String {
        switch self {
        case .baseline: tr(vi: "Chốt mốc thời gian (baseline)", en: "Set the baseline (cut-off time)")
        case .scan: tr(vi: "Quét metadata thư viện", en: "Scan library metadata")
        case .restore: tr(vi: "Khôi phục trạng thái từ đích", en: "Restore state from the destination")
        case .upload: tr(vi: "Bắt đầu upload", en: "Start uploading")
        }
    }

    public var detail: String {
        switch self {
        case .baseline: tr(vi: "Từ lúc này, ảnh vào Photos được tính là “ảnh mới”.", en: "From now on, photos added to Photos count as “new photos”.")
        case .scan: tr(vi: "Không export file nào trong lúc quét.", en: "No files are exported during the scan.")
        case .restore: tr(vi: "Đích chưa nhận upload trong lúc này.", en: "The destination doesn't receive uploads during this phase.")
        case .upload: tr(vi: "Ảnh mới trước, sau đó backfill mới nhất trước.", en: "New photos first, then backfill newest first.")
        }
    }

    /// The restore phase appears only when an existing Drive root or NAS folder is reused.
    public static func sequence(reusingExistingDestination: Bool) -> [OnboardingPhase] {
        reusingExistingDestination ? [.baseline, .scan, .restore, .upload] : [.baseline, .scan, .upload]
    }
}

/// Sync mode choice of FR-06 as the wizard collects it.
public enum SyncModeChoice: Equatable, Sendable {
    case full
    case since(Date)
    case newOnly

    /// Converts to the stored scope; `since` is read in the archive timezone. Nil for a date in the future.
    public func scope(timeZone: TimeZone, now: Date) -> ScopeMode? {
        switch self {
        case .full: return .full
        case .newOnly: return .newOnly
        case .since(let date):
            guard date <= now else { return nil }
            return .since(ArchiveDay(date: date, timeZone: timeZone))
        }
    }

    /// The exact FR-06 note shown under the options.
    public static var newPhotoNote: String {
        tr(
            vi: "Ảnh mới = ảnh xuất hiện trong Photos trên Mac sau thời điểm này, kể cả ảnh cũ import sau",
            en: "New photos = photos that appear in Photos on this Mac after this moment, including old photos imported later")
    }
}

public enum RootNameValidator {
    public enum Issue: Equatable, Sendable {
        case empty, tooLong, forbiddenCharacter
        public var message: String {
            switch self {
            case .empty: tr(vi: "Tên thư mục không được để trống.", en: "The folder name can't be empty.")
            case .tooLong: tr(vi: "Tên thư mục tối đa 200 ký tự.", en: "The folder name can be at most 200 characters.")
            case .forbiddenCharacter: tr(vi: "Tên thư mục không được chứa dấu / hoặc ký tự điều khiển.", en: "The folder name can't contain / or control characters.")
            }
        }
    }

    public static func validate(_ name: String) -> Issue? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > 200 { return .tooLong }
        if trimmed.contains("/") || trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .forbiddenCharacter
        }
        return nil
    }

    public static func normalized(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Archive timezone picker content (FR-07) with the live filename example.
public enum ArchiveTimeZoneText {
    public static let commonIdentifiers = [
        "Asia/Ho_Chi_Minh", "Asia/Bangkok", "Asia/Tokyo", "Asia/Singapore", "Europe/Berlin", "Europe/London",
        "America/New_York", "America/Los_Angeles", "Australia/Sydney", "UTC",
    ]

    /// Always includes the system zone first, then the common ones without duplicates.
    public static func options(including current: TimeZone) -> [TimeZone] {
        var seen = Set<String>()
        return ([current.identifier] + commonIdentifiers).compactMap { id in
            seen.insert(id).inserted ? TimeZone(identifier: id) : nil
        }
    }

    /// "Asia/Ho_Chi_Minh (GMT+7)".
    public static func label(_ zone: TimeZone, at date: Date = Date()) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) % 3600 / 60
        let offset = minutes == 0 ? "\(hours)" : String(format: "%d:%02d", hours, minutes)
        return "\(zone.identifier) (GMT\(sign)\(offset))"
    }

    /// File name of a photo taken at `instant`, as it would be named in `zone`.
    public static func filenameExample(at instant: Date, in zone: TimeZone, stem: String = "IMG_4821.HEIC") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: instant) + "_" + stem
    }
}
