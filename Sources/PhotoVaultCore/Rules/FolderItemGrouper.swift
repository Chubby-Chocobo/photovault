import Foundation

/// One file of a folder, as the grouper sees it.
public struct GroupInput: Hashable, Sendable {
    public var relativePath: String
    public var uti: String
    public var mediaType: MediaType
    public var isRaw: Bool
    /// Apple content identifier read from the file, when it has one.
    public var contentIdentifier: String?

    public init(relativePath: String, uti: String, mediaType: MediaType, isRaw: Bool, contentIdentifier: String? = nil) {
        self.relativePath = relativePath
        self.uti = uti
        self.mediaType = mediaType
        self.isRaw = isRaw
        self.contentIdentifier = contentIdentifier
    }

    public var originalFilename: String { relativePath.split(separator: "/").last.map(String.init) ?? relativePath }
}

/// A file with the resource type it takes inside its asset.
public struct DraftMember: Hashable, Sendable {
    public var file: GroupInput
    public var type: ResourceType

    public var descriptor: ResourceDescriptor {
        ResourceDescriptor(type: type, uti: file.uti, originalFilename: file.originalFilename, isRaw: file.isRaw)
    }
}

/// The files that become one asset.
public struct AssetDraft: Hashable, Sendable {
    public var members: [DraftMember]
    public var mediaType: MediaType
    public var subtypes: MediaSubtypes

    public var descriptors: [ResourceDescriptor] { members.map(\.descriptor) }

    /// The member whose bytes name the asset (spec §3: the RAW of a RAW+JPEG pair).
    public var primary: DraftMember {
        let wanted = ResourcePlanner.primary(of: descriptors)?.type
        return members.first { $0.type == wanted } ?? members[0]
    }
}

/// Turns the files of a folder into asset drafts the way Photos stores them (pure).
public enum FolderItemGrouper {
    /// Sidecar files that belong to a photo but are not photos, and iCloud placeholders of files that were never downloaded.
    public static let ignoredExtensions: Set<String> = ["aae", "xmp", "thm", "json", "icloud"]

    public static func isIgnored(relativePath: String) -> Bool {
        ignoredExtensions.contains((relativePath as NSString).pathExtension.lowercased())
    }

    /// Directory + lowercased stem, NFC: files with the same key are candidates for one asset.
    public static func groupKey(relativePath: String) -> String {
        let nfc = relativePath.precomposedStringWithCanonicalMapping as NSString
        let stem = (nfc.lastPathComponent as NSString).deletingPathExtension.lowercased()
        let directory = nfc.deletingLastPathComponent
        return directory.isEmpty ? stem : directory + "/" + stem
    }

    public static func group(_ files: [GroupInput]) -> [AssetDraft] {
        let kept = files.filter { !isIgnored(relativePath: $0.relativePath) }
        let buckets = Dictionary(grouping: kept) { groupKey(relativePath: $0.relativePath) }
        var drafts: [AssetDraft] = []
        for key in buckets.keys.sorted(by: utf8Less) {
            drafts += assets(in: buckets[key]!.sorted { utf8Less($0.relativePath, $1.relativePath) })
        }
        return drafts.sorted { utf8Less($0.primary.file.relativePath, $1.primary.file.relativePath) }
    }

    private static func assets(in files: [GroupInput]) -> [AssetDraft] {
        let raws = files.filter { $0.mediaType == .image && $0.isRaw }
        let images = files.filter { $0.mediaType == .image && !$0.isRaw }
        var videos = files.filter { $0.mediaType == .video }
        var singles: [GroupInput] = []
        var result: [AssetDraft] = []

        if raws.count == 1, images.count == 1 {
            result.append(AssetDraft(members: [DraftMember(file: images[0], type: .photo), DraftMember(file: raws[0], type: .alternatePhoto)],
                                     mediaType: .image, subtypes: []))
        } else {
            singles += raws
            for image in images {
                if let id = image.contentIdentifier, let index = videos.firstIndex(where: { $0.contentIdentifier == id }) {
                    let video = videos.remove(at: index)
                    result.append(AssetDraft(members: [DraftMember(file: image, type: .photo), DraftMember(file: video, type: .pairedVideo)],
                                             mediaType: .image, subtypes: .photoLive))
                } else {
                    singles.append(image)
                }
            }
        }
        singles += videos
        result += singles.map { file in
            AssetDraft(members: [DraftMember(file: file, type: file.mediaType == .video ? .video : .photo)],
                       mediaType: file.mediaType, subtypes: [])
        }
        return result
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.lexicographicallyPrecedes(rhs.utf8) }
}
