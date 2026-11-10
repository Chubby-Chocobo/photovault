import Foundation
import PhotoVaultCore
@testable import PhotoVaultEngine
import Testing
@testable import PhotoVaultAppSupport

@Suite struct ImportLocationTextTests {
    func vi<T>(_ body: () -> T) -> T { L10n.$override.withValue(.vi, operation: body) }
    func en<T>(_ body: () -> T) -> T { L10n.$override.withValue(.en, operation: body) }

    let drive = ImportLocation(paths: ["My Drive/Trips/2024", "My Drive/Other"], othersCount: 3, webURL: URL(string: "https://drive.google.com/drive/folders/a"))

    @Test func headlineIsTheFirstPath() {
        #expect(ImportLocationText.headline(drive) == "My Drive/Trips/2024")
    }

    @Test func othersLabelCountsTheRest() {
        vi { #expect(ImportLocationText.othersLabel(drive) == "+3 mục khác") }
        en { #expect(ImportLocationText.othersLabel(drive) == "+3 more") }
        #expect(ImportLocationText.othersLabel(ImportLocation(paths: ["~/x"])) == nil)
    }

    @Test func tooltipListsEveryPathAndTheCount() {
        en {
            #expect(ImportLocationText.tooltip(drive) == "My Drive/Trips/2024\nMy Drive/Other\n+3 more")
            #expect(ImportLocationText.tooltip(ImportLocation(paths: ["~/x"])) == "~/x")
        }
        #expect(ImportLocationText.tooltip(nil) == nil)
    }

    @Test func buttonTitles() {
        vi {
            #expect(ImportLocationText.revealTitle == "Hiện trong Finder")
            #expect(ImportLocationText.openOnWebTitle == "Mở trên web")
        }
        en {
            #expect(ImportLocationText.revealTitle == "Show in Finder")
            #expect(ImportLocationText.openOnWebTitle == "Open on the web")
        }
    }

    @Test func aMacImportMadeBeforeTheFieldDerivesItFromTheBookmark() {
        let derived = ImportLocationText.macLocation(stored: nil, resolvedPath: "/Users/ann/Pictures/2024", home: "/Users/ann")
        #expect(derived?.paths == ["~/Pictures/2024"])
        let stored = ImportLocation(paths: ["~/Old/2024"])
        #expect(ImportLocationText.macLocation(stored: stored, resolvedPath: "/Users/ann/New/2024", home: "/Users/ann") == stored)
        #expect(ImportLocationText.macLocation(stored: nil, resolvedPath: nil, home: "/Users/ann") == nil)
    }

    @Test func importProgressTextsNeverCarryThePath() {
        let item = ImportSnapshot(
            id: .folder(), kind: .googleDrive, account: nil, displayName: "2024", status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), finishedAt: Date(timeIntervalSince1970: 1_800_000_100),
            found: 5, processed: 5, imported: 5, filesUploaded: 5, filesTotal: 5, location: drive)
        let texts = [ImportProgressText.summaryLine(item), ImportProgressText.statusLabel(item), ImportProgressText.progressLine(item),
                     ImportProgressText.menuTitle(folderName: item.displayName), String(describing: item), String(reflecting: item)]
        for text in texts { #expect(!text.contains("Trips")) }
    }

    @Test func aQueuedImportCarriesItsLocation() {
        let location = ImportLocation(paths: ["My Drive/Trips"])
        let item = ImportQueue.snapshot(id: .folder(), kind: .googleDrive, account: "a@b.c", displayName: "Trips", now: Date(), location: location)
        #expect(item.location == location)
        #expect(ImportQueue.snapshot(id: .folder(), kind: .dropbox, account: nil, displayName: "x", now: Date()).location == nil)
    }
}
