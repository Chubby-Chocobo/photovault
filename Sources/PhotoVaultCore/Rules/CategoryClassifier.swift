import Foundation

public struct ClassificationResult: Hashable, Sendable {
    public var category: AssetCategory
    public var reason: CategoryReason
    /// `camera` until the header read decides between `camera` and `saved`.
    public var provisional: Bool

    public init(category: AssetCategory, reason: CategoryReason, provisional: Bool) {
        self.category = category
        self.reason = reason
        self.provisional = provisional
    }
}

/// FR-20 heuristic, rules applied in order. Screenshot wins over chat albums (8.10).
public enum CategoryClassifier {
    /// - Parameter headerMetadata: metadata from the primary photo header; nil when not read yet.
    public static func classify(
        mediaType: MediaType, subtypes: MediaSubtypes, hasRaw: Bool, albumTitles: [String],
        settings: GlobalSettings, headerMetadata: CaptureMetadata?
    ) -> ClassificationResult {
        if subtypes.contains(.photoScreenshot) || subtypes.contains(.videoScreenRecording) {
            return ClassificationResult(category: .screenshot, reason: .screenshotSubtype, provisional: false)
        }
        if isInChatAppAlbum(albumTitles, chatApps: settings.chatAppAlbumNames) {
            return ClassificationResult(category: .saved, reason: .chatAppAlbum, provisional: false)
        }
        guard mediaType == .image, !hasRaw, settings.photosWithoutCameraExifAreSaved else {
            return ClassificationResult(category: .camera, reason: .cameraDefault, provisional: false)
        }
        guard let headerMetadata else {
            return ClassificationResult(category: .camera, reason: .pendingHeaderRead, provisional: true)
        }
        return headerMetadata.hasCameraIdentity
            ? ClassificationResult(category: .camera, reason: .cameraDefault, provisional: false)
            : ClassificationResult(category: .saved, reason: .missingCameraExif, provisional: false)
    }

    /// Exact title match, case-insensitive, trimmed; never a substring match (8.10).
    public static func isInChatAppAlbum(_ titles: [String], chatApps: [String]) -> Bool {
        let wanted = Set(chatApps.map(normalize))
        return titles.contains { wanted.contains(normalize($0)) }
    }

    static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }
}
