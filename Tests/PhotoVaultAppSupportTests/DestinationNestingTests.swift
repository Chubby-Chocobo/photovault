import Testing
@testable import PhotoVaultAppSupport

struct DestinationNestingTests {
    @Test func detectsNestingInBothDirections() {
        #expect(DestinationNesting.relation(of: "/Volumes/NAS/Photos/2024", to: "/Volumes/NAS/Photos") == .inside)
        #expect(DestinationNesting.relation(of: "/Volumes/NAS", to: "/Volumes/NAS/Photos") == .contains)
        #expect(DestinationNesting.relation(of: "/Volumes/NAS/Photos/", to: "/Volumes/NAS/Photos") == .same)
        #expect(DestinationNesting.relation(of: "/Volumes/NAS/Photos2", to: "/Volumes/NAS/Photos") == nil)
        #expect(DestinationNesting.relation(of: "/Volumes/Other", to: "/Volumes/NAS") == nil)
        #expect(DestinationNesting.relation(of: "/", to: "/Volumes/NAS") == .contains)
    }

    @Test func conflictNamesTheExistingDestination() {
        let existing = [(name: "NAS", path: "/Volumes/NAS/Photos"), (name: "USB", path: "/Volumes/USB")]
        let hit = DestinationNesting.conflict(candidate: "/Volumes/USB/backup", existing: existing)
        #expect(hit?.name == "USB" && hit?.relation == .inside)
        #expect(DestinationNesting.conflict(candidate: "/Volumes/New", existing: existing) == nil)
        #expect(DestinationNesting.message(name: "USB", relation: .inside).contains("USB"))
    }
}
