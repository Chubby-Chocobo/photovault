import Foundation

/// Which resources of an asset go to a destination (FR-21, FR-72). Global settings are a ceiling.
public enum ResourcePlanner {
    /// Resource types that are never uploaded (FR-21).
    public static let neverUploaded: Set<ResourceType> = [.adjustmentData, .adjustmentBasePhoto, .adjustmentBasePairedVideo,
                                                          .adjustmentBaseVideo, .photoProxy, .audio]

    /// Primary resource (spec §3): RAW of a RAW+JPEG pair, otherwise `.photo` or `.video`.
    public static func primary(of resources: [ResourceDescriptor]) -> ResourceDescriptor? {
        let photoOriginals = resources.filter { $0.type == .photo || $0.type == .alternatePhoto }
        if photoOriginals.count > 1, let raw = photoOriginals.first(where: \.isRaw) { return raw }
        return resources.first { $0.type == .photo } ?? resources.first { $0.type == .video }
            ?? photoOriginals.first ?? resources.first { !neverUploaded.contains($0.type) }
    }

    /// Resource types to upload to a destination with `rules`.
    public static func plannedTypes(for resources: [ResourceDescriptor], mediaType: MediaType,
                                    settings: GlobalSettings, rules: DestinationRules) -> [ResourceType] {
        resources.filter { isPlanned($0, mediaType: mediaType, settings: settings, rules: rules) }
            .map(\.type).sorted()
    }

    static func isPlanned(_ r: ResourceDescriptor, mediaType: MediaType, settings: GlobalSettings, rules: DestinationRules) -> Bool {
        let videosAllowed = settings.includeVideos && rules.includeVideos
        let editedAllowed = settings.includeEdited && rules.includeEdited
        switch r.type {
        case .photo, .alternatePhoto:
            guard rules.includeOriginals else { return false }
            return r.isRaw ? rules.includeRaw : rules.includePhotos
        case .pairedVideo:
            return rules.includeOriginals && rules.includePhotos
        case .video:
            return rules.includeOriginals && videosAllowed && mediaType == .video
        case .fullSizePhoto, .fullSizePairedVideo:
            return editedAllowed && rules.includePhotos
        case .fullSizeVideo:
            return editedAllowed && videosAllowed
        default:
            return false
        }
    }

    /// Sidecar types for the destination (FR-90); none when no resource is planned.
    public static func plannedSidecars(settings: GlobalSettings, rules: DestinationRules, hasPlannedResources: Bool) -> [ResourceType] {
        guard hasPlannedResources else { return [] }
        var types: [ResourceType] = []
        if settings.sidecarJsonEnabled, rules.sidecarJson { types.append(.sidecarJson) }
        if settings.sidecarXmpEnabled, rules.sidecarXmp { types.append(.sidecarXmp) }
        return types
    }

    /// Shortcut target (FR-101): the primary resource as Drive receives it (RAW only if Drive
    /// takes RAW, else the JPEG of the pair).
    public static func viewTarget(of resources: [ResourceDescriptor], planned: [ResourceType]) -> ResourceType? {
        let plannedSet = Set(planned)
        if let p = primary(of: resources), plannedSet.contains(p.type) { return p.type }
        for type in [ResourceType.photo, .alternatePhoto, .video] where plannedSet.contains(type) { return type }
        return nil
    }
}
