import Testing
@testable import PhotoVaultAppSupport

@Suite struct ImportFolderGuardTests {
    let destinations = [(name: "NAS", path: "/Volumes/NAS/PhotoVault")]
    let container = "/Users/me/Library/Containers/app/Data/Library/Application Support/PhotoVault"

    @Test func foldersThatTouchADestinationOrTheContainerAreRefused() {
        #expect(ImportFolderGuard.conflict(candidate: "/Volumes/NAS/PhotoVault", destinations: destinations, container: container)?.contains("NAS") == true)
        #expect(ImportFolderGuard.conflict(candidate: "/Volumes/NAS", destinations: destinations, container: container) != nil)
        #expect(ImportFolderGuard.conflict(candidate: "/Volumes/NAS/PhotoVault/Camera Uploads", destinations: destinations, container: container) != nil)
        #expect(ImportFolderGuard.conflict(candidate: container + "/staging", destinations: destinations, container: container) != nil)
        #expect(ImportFolderGuard.conflict(candidate: "/Users/me/Library", destinations: destinations, container: container) != nil)
    }

    @Test func otherFoldersAreFine() {
        #expect(ImportFolderGuard.conflict(candidate: "/Users/me/Pictures/Trip", destinations: destinations, container: container) == nil)
        #expect(ImportFolderGuard.conflict(candidate: "/Volumes/NAS2/PhotoVault", destinations: destinations, container: container) == nil)
    }
}
