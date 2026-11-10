import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct ImportLocationPathTests {
    @Test func homeBecomesTilde() {
        #expect(ImportLocationPath.mac("/Users/ann/Pictures/Trips/2024", home: "/Users/ann") == "~/Pictures/Trips/2024")
        #expect(ImportLocationPath.mac("/Users/ann", home: "/Users/ann") == "~")
        #expect(ImportLocationPath.mac("/Users/ann/x", home: "/Users/ann/") == "~/x")
    }

    @Test func otherPathsStayAsTheyAre() {
        #expect(ImportLocationPath.mac("/Volumes/NAS/Photos/2024", home: "/Users/ann") == "/Volumes/NAS/Photos/2024")
        #expect(ImportLocationPath.mac("/Users/annabel/Pictures", home: "/Users/ann") == "/Users/annabel/Pictures")
        #expect(ImportLocationPath.mac("/tmp/x", home: "") == "/tmp/x")
    }

    @Test func dropboxRootAndFolders() {
        #expect(ImportLocationPath.dropbox("") == "/")
        #expect(ImportLocationPath.dropbox("/Camera Uploads/2024") == "/Camera Uploads/2024")
    }

    @Test func dropboxWebLink() {
        #expect(ImportLocationPath.dropboxWebURL("")?.absoluteString == "https://www.dropbox.com/home")
        #expect(ImportLocationPath.dropboxWebURL("/Camera Uploads/Chuyến đi")?.absoluteString
            == "https://www.dropbox.com/home/Camera%20Uploads/Chuy%E1%BA%BFn%20%C4%91i")
    }

    @Test func driveFolderLink() {
        #expect(ImportLocationPath.driveFolderURL(id: "abc_-1")?.absoluteString == "https://drive.google.com/drive/folders/abc_-1")
        #expect(ImportLocationPath.driveFolderURL(id: "a/b") == nil)
        #expect(ImportLocationPath.driveFolderURL(id: "") == nil)
    }
}

@Suite struct ImportLocationTests {
    @Test func oldConfigJsonDecodesWithoutLocation() throws {
        let json = #"{"bookmark":"AQID","account":"a@b.c","remoteItems":["x"]}"#
        let config = try JSONDecoder().decode(SourceConfig.self, from: Data(json.utf8))
        #expect(config.locationPaths == nil)
        #expect(config.locationURL == nil)
        #expect(config.account == "a@b.c")
    }

    @Test func locationRoundTrips() throws {
        let config = SourceConfig(remoteItems: ["a", "b"], locationPaths: ["My Drive/X"], locationURL: "https://drive.google.com/drive/folders/a")
        let back = try JSONDecoder().decode(SourceConfig.self, from: JSONEncoder().encode(config))
        #expect(back == config)
    }

    @Test func macFolderUsesStoredPath() {
        let config = SourceConfig(locationPaths: ["~/Pictures/2024"])
        let location = ImportLocation.make(kind: .localFolder, config: config)
        #expect(location?.paths == ["~/Pictures/2024"])
        #expect(location?.othersCount == 0)
        #expect(location?.webURL == nil)
    }

    @Test func macFolderWithoutStoredPathHasNone() {
        #expect(ImportLocation.make(kind: .localFolder, config: SourceConfig(bookmark: Data([1]))) == nil)
    }

    @Test func dropboxDerivesFromTheRootItem() {
        let folder = ImportLocation.make(kind: .dropbox, config: SourceConfig(remoteItems: ["/Camera Uploads/2024"]))
        #expect(folder?.paths == ["/Camera Uploads/2024"])
        #expect(folder?.webURL?.absoluteString == "https://www.dropbox.com/home/Camera%20Uploads/2024")
        let whole = ImportLocation.make(kind: .dropbox, config: SourceConfig(remoteItems: [""]))
        #expect(whole?.paths == ["/"])
        #expect(whole?.webURL?.absoluteString == "https://www.dropbox.com/home")
        #expect(ImportLocation.make(kind: .dropbox, config: SourceConfig()) == nil)
    }

    @Test func driveShowsFirstPathAndCountsTheRest() {
        let config = SourceConfig(
            remoteItems: ["a", "b", "c", "d"], locationPaths: ["My Drive/A", "My Drive/B"],
            locationURL: "https://drive.google.com/drive/folders/a")
        let location = ImportLocation.make(kind: .googleDrive, config: config)
        #expect(location?.paths == ["My Drive/A", "My Drive/B"])
        #expect(location?.othersCount == 3)
        #expect(location?.webURL?.absoluteString == "https://drive.google.com/drive/folders/a")
    }

    @Test func driveWithoutStoredPathHasNone() {
        #expect(ImportLocation.make(kind: .googleDrive, config: SourceConfig(remoteItems: ["a"])) == nil)
    }

    @Test func linksOnlyPointToTheProviderOwnHosts() {
        let config = SourceConfig(remoteItems: ["a"], locationPaths: ["My Drive/A"], locationURL: "https://evil.example/x")
        #expect(ImportLocation.make(kind: .googleDrive, config: config)?.webURL == nil)
    }

    @Test func descriptionsNeverContainPathsNamesOrAccounts() {
        let config = SourceConfig(
            bookmark: Data([1, 2]), account: "owner@example.com", remoteItems: ["/Secret Trip"],
            locationPaths: ["~/Private/Secret Trip"], locationURL: "https://drive.google.com/drive/folders/zzz")
        let record = SourceRecord(id: .folder(), kind: .localFolder, mode: .oneTime, displayName: "Secret Trip", config: config,
                                  status: .scanning, createdAt: Date())
        let location = ImportLocation.make(kind: .googleDrive, config: config)
        let dumps = [String(describing: config), String(reflecting: config), "\(config)", String(describing: location as Any), String(reflecting: location as Any)]
        for text in dumps {
            #expect(!text.contains("Private"))
            #expect(!text.contains("Secret"))
            #expect(!text.contains("owner@example.com"))
            #expect(!text.contains("zzz"))
        }
        #expect(!String(describing: record).contains("Private"))
    }
}
