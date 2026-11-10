import CryptoKit
import Foundation
import PhotoVaultCore

/// A folder of a local destination read back as the logical folder it stands for (8.15 step 3):
/// `Camera Uploads/2026-11-08 Đà Lạt` is the logical `camera/2026-11-08` with place name `Đà Lạt`.
struct LocalFolderInfo: Sendable, Equatable {
    var logicalPath: String
    var displayName: String
    var day: ArchiveDay?
    var placeName: String?
}

/// Reverses `DynamicLayout` for folders. A folder it does not recognise is not ours: it is ignored.
enum LocalTreeInterpreter {
    static func folder(displayPath: String) -> LocalFolderInfo? {
        let parts = displayPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last, !name.isEmpty, let first = parts.first else { return nil }
        let branch: String
        switch first {
        case DynamicLayout.cameraName: branch = "camera"
        case DynamicLayout.screenshotsName: branch = "screenshot"
        case DynamicLayout.savedName: branch = "saved"
        default: return nil
        }
        if parts.count == 1 { return LocalFolderInfo(logicalPath: branch, displayName: name) }
        guard parts.count == 2 else { return nil }
        if name == DynamicLayout.unknownDateName { return LocalFolderInfo(logicalPath: "\(branch)/unknown", displayName: name) }
        guard name.count >= 10, let day = ArchiveDay(string: String(name.prefix(10))) else { return nil }
        let rest = name.dropFirst(10)
        // Only camera day folders carry a place name.
        guard rest.isEmpty || (branch == "camera" && rest.hasPrefix(" ")) else { return nil }
        let place = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return LocalFolderInfo(
            logicalPath: "\(branch)/\(day.description)", displayName: name, day: branch == "camera" ? day : nil,
            placeName: place.isEmpty ? nil : place)
    }
}

/// What a backup file name says (FR-41): `YYYY-MM-DD HH.mm.ss_<original stem>[ (n)][ (edited)].<ext>`
/// or `undated_<stem>…`.
struct NameFingerprint: Sendable, Equatable {
    /// `YYYY-MM-DD HH.mm.ss` in the archive timezone of the time; nil for undated assets.
    var dateText: String?
    /// The whole name without extension and without the edited marker; this is the placement stem.
    var fullStem: String
    /// Original stem as written, collision suffix included.
    var originalStem: String
    var isEdited: Bool
    var ext: String

    private static let editedSuffix = " (edited)"

    static func parse(_ fileName: String) -> NameFingerprint? {
        let ns = fileName as NSString
        let ext = ns.pathExtension
        var stem = ns.deletingPathExtension
        var edited = false
        if stem.hasSuffix(editedSuffix) {
            edited = true
            stem = String(stem.dropLast(editedSuffix.count))
        }
        if stem.hasPrefix("undated_") {
            let original = String(stem.dropFirst(8))
            return original.isEmpty ? nil : NameFingerprint(dateText: nil, fullStem: stem, originalStem: original, isEdited: edited, ext: ext)
        }
        let chars = Array(stem)
        guard chars.count > 20, chars[19] == "_" else { return nil }
        let date = String(chars[0..<19])
        guard isDateText(date) else { return nil }
        return NameFingerprint(
            dateText: date, fullStem: stem, originalStem: String(chars[20...]), isEdited: edited, ext: ext)
    }

    /// `base (3)` → `base`; nil when there is no collision suffix.
    static func withoutCollisionSuffix(_ stem: String) -> String? {
        guard stem.hasSuffix(")"), let open = stem.lastIndex(of: "("), open > stem.startIndex else { return nil }
        let number = stem[stem.index(after: open)..<stem.index(before: stem.endIndex)]
        guard !number.isEmpty, number.allSatisfy(\.isNumber), stem[stem.index(before: open)] == " " else { return nil }
        return String(stem[..<stem.index(before: open)])
    }

    /// `yyyy-MM-dd HH.mm.ss`
    private static func isDateText(_ text: String) -> Bool {
        let pattern = Array("dddd-dd-dd dd.dd.dd")
        let chars = Array(text)
        guard chars.count == pattern.count else { return false }
        for (c, p) in zip(chars, pattern) {
            if p == "d" ? !(c.isASCII && c.isNumber) : c != p { return false }
        }
        return true
    }

    /// The text a creation date gets in file names written with `timeZone` (FR-41).
    static func dateText(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d.%02d.%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}

/// The part of a JSON sidecar recovery reads (FR-90): identifiers, the fingerprint and the list of
/// resources with their sizes and hashes.
struct SidecarDocument: Decodable, Sendable {
    struct Resource: Decodable, Sendable {
        var type: String
        var originalName: String?
        var backupName: String
        var size: Int64?
        var md5: String?
        var sha256: String?
    }

    struct Camera: Decodable, Sendable, Equatable {
        var make: String?
        var model: String?
        var lens: String?
    }

    var assetKey: String
    var localIdentifier: String?
    var cloudIdentifier: String?
    var creationDate: String?
    var archiveTimezone: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Double?
    var camera: Camera?
    var resources: [Resource]

    /// nil unless `data` is a sidecar of this app.
    static func parse(_ data: Data) -> SidecarDocument? {
        guard let document = try? JSONDecoder().decode(SidecarDocument.self, from: data),
              AssetKey(rawValue: document.assetKey) != nil || document.assetKey.hasPrefix("h:") else { return nil }
        return document
    }

    /// `creationDate` as whole seconds since 1970 (sidecars carry milliseconds).
    var creationEpoch: Int64? {
        guard let creationDate else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: creationDate) ?? ISO8601DateFormatter().date(from: creationDate) else { return nil }
        return Int64(date.timeIntervalSince1970.rounded(.down))
    }
}

extension Data {
    var sha256Hex: String { SHA256.hash(data: self).hexString }
}
