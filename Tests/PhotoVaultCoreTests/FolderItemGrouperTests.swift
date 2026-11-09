import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct FolderItemGrouperTests {
    func image(_ path: String, raw: Bool = false, id: String? = nil) -> GroupInput {
        GroupInput(relativePath: path, uti: raw ? "com.sony.arw-raw-image" : "public.jpeg", mediaType: .image, isRaw: raw, contentIdentifier: id)
    }

    func video(_ path: String, id: String? = nil) -> GroupInput {
        GroupInput(relativePath: path, uti: "com.apple.quicktime-movie", mediaType: .video, isRaw: false, contentIdentifier: id)
    }

    func types(_ draft: AssetDraft) -> [ResourceType] { draft.members.map(\.type) }

    @Test func rawPlusJpegIsOneAssetWithRawPrimary() throws {
        let drafts = FolderItemGrouper.group([image("DSC1.JPG"), image("DSC1.ARW", raw: true)])
        let draft = try #require(drafts.first)
        #expect(drafts.count == 1 && draft.mediaType == .image)
        #expect(draft.members.first { $0.type == .photo }?.file.relativePath == "DSC1.JPG")
        #expect(draft.members.first { $0.type == .alternatePhoto }?.file.relativePath == "DSC1.ARW")
        #expect(draft.primary.file.relativePath == "DSC1.ARW")
        #expect(!draft.subtypes.contains(.photoLive))
    }

    @Test func liveNeedsMatchingContentIdentifier() throws {
        let live = FolderItemGrouper.group([image("IMG_1.HEIC", id: "ID-1"), video("IMG_1.MOV", id: "ID-1")])
        let draft = try #require(live.first)
        #expect(live.count == 1 && Set(types(draft)) == [.photo, .pairedVideo])
        #expect(draft.subtypes.contains(.photoLive) && draft.mediaType == .image)
        #expect(draft.primary.file.relativePath == "IMG_1.HEIC")

        let noId = FolderItemGrouper.group([image("IMG_2.HEIC"), video("IMG_2.MOV")])
        #expect(noId.count == 2)
        #expect(Set(noId.map { types($0) }) == [[.photo], [.video]])
        let other = FolderItemGrouper.group([image("IMG_3.HEIC", id: "A"), video("IMG_3.MOV", id: "B")])
        #expect(other.count == 2)
    }

    @Test func sameStemImagesStaySeparate() {
        let drafts = FolderItemGrouper.group([image("a.jpg"), GroupInput(relativePath: "a.png", uti: "public.png", mediaType: .image, isRaw: false, contentIdentifier: nil)])
        #expect(drafts.count == 2 && drafts.allSatisfy { types($0) == [.photo] })
    }

    @Test func ignoredSidecarFilesProduceNoAsset() {
        let drafts = FolderItemGrouper.group([image("a.jpg"), image("a.AAE"), image("a.xmp"), image("a.THM"), image("a.json")])
        #expect(drafts.count == 1 && drafts[0].members.count == 1)
        #expect(FolderItemGrouper.isIgnored(relativePath: "x/y.Aae") && !FolderItemGrouper.isIgnored(relativePath: "y.jpg"))
    }

    @Test func stemsAreCaseInsensitiveAndPerDirectory() {
        let same = FolderItemGrouper.group([image("d/img_1.jpg"), image("d/IMG_1.ARW", raw: true)])
        #expect(same.count == 1)
        let split = FolderItemGrouper.group([image("d1/IMG_1.jpg"), image("d2/IMG_1.ARW", raw: true)])
        #expect(split.count == 2)
        #expect(FolderItemGrouper.groupKey(relativePath: "d/IMG_1.jpg") == FolderItemGrouper.groupKey(relativePath: "d/img_1.ARW"))
        #expect(FolderItemGrouper.groupKey(relativePath: "d1/a.jpg") != FolderItemGrouper.groupKey(relativePath: "d2/a.jpg"))
    }

    @Test func singlesAndOrderAreDeterministic() {
        let files = [video("b.mp4"), image("a.jpg")]
        let drafts = FolderItemGrouper.group(files)
        #expect(drafts.map { $0.primary.file.relativePath } == ["a.jpg", "b.mp4"])
        #expect(drafts.map(\.mediaType) == [.image, .video])
        #expect(FolderItemGrouper.group(files.reversed()).map { $0.primary.file.relativePath } == ["a.jpg", "b.mp4"])
    }
}
