import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct SidecarBuilderTests {
    let tz = PolicyFixtures.vietnam

    func input(
        albums: [String] = ["Dalat 2025", "Family"], favorite: Bool = true, extended: SidecarExtendedMetadata? = nil,
        place: GeoPlace? = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lâm Đồng", locality: "Đà Lạt"),
        resources: [SidecarResource]? = nil
    ) -> SidecarInput {
        var asset = PolicyFixtures.asset("l:ABC", make: "SONY", model: "ILCE-7M4", favorite: favorite, location: GeoPoint(latitude: 11.940412, longitude: 108.458312))
        asset.duration = 12.3456
        asset.pixelWidth = 6000
        asset.pixelHeight = 4000
        asset.cloudId = "cloud-1"
        asset.lensModel = "FE 24-70mm"
        asset.modificationDate = Date(timeIntervalSince1970: 1_740_800_000)
        let defaults = [
            SidecarResource(type: .photo, kind: .original, originalName: "DSC001.ARW", backupName: "2025-03-01 15.35.30_DSC001.ARW", size: 100, md5: "m", sha256: "s", state: .done),
            SidecarResource(type: .fullSizePhoto, kind: .edited, originalName: "DSC001.JPG", backupName: "2025-03-01 15.35.30_DSC001-edited.JPG", size: 50, state: .pending),
        ]
        return SidecarInput(asset: asset, albumTitles: albums, place: place, deviceDisplayName: "Sony A7 IV",
                            resources: resources ?? defaults, archiveTimeZone: tz, extendedMetadata: extended)
    }

    func jsonObject(_ file: SidecarFile) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: file.data) as? [String: Any])
    }

    @Test func jsonIsByteIdenticalAcrossRunsAndAlbumOrder() {
        let first = SidecarBuilder.buildJSON(input())
        #expect(first == SidecarBuilder.buildJSON(input()))
        #expect(first == SidecarBuilder.buildJSON(input(albums: ["Family", "Dalat 2025", "Family"])))
        let reversed = input().resources.reversed()
        #expect(first == SidecarBuilder.buildJSON(input(resources: Array(reversed))))
        #expect(first.sha256.count == 64 && first.md5.count == 32)
    }

    @Test func xmpIsByteIdenticalAcrossRunsAndAlbumOrder() {
        let first = SidecarBuilder.buildXMP(input())
        #expect(first == SidecarBuilder.buildXMP(input()))
        #expect(first == SidecarBuilder.buildXMP(input(albums: ["Family", "Dalat 2025"])))
    }

    @Test func jsonFieldsAndFixedFormats() throws {
        let file = SidecarBuilder.buildJSON(input())
        let text = String(decoding: file.data, as: UTF8.self)
        #expect(text.contains("\"latitude\": 11.940412"))
        #expect(text.contains("\"duration\": 12.346"))
        #expect(text.contains("\"creationDate\": \"2025-03-01T00:55:30.250Z\""))
        #expect(text.contains("\"archiveLocalDateTime\": \"2025-03-01T07:55:30\""))
        #expect(text.contains("\"extendedMetadata\": \"unavailable\""))
        let object = try jsonObject(file)
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["assetKey"] as? String == "l:ABC")
        #expect(object["cloudIdentifier"] as? String == "cloud-1")
        #expect(object["archiveTimezone"] as? String == "Asia/Ho_Chi_Minh")
        #expect(object["category"] as? String == "camera")
        #expect(object["albums"] as? [String] == ["Dalat 2025", "Family"])
        let camera = try #require(object["camera"] as? [String: Any])
        #expect(camera["deviceName"] as? String == "Sony A7 IV")
        #expect(camera["lens"] as? String == "FE 24-70mm")
        let place = try #require(object["place"] as? [String: Any])
        #expect(place["locality"] as? String == "Đà Lạt")
    }

    @Test func keysAreSortedAndNoGenerationTime() {
        let text = String(decoding: SidecarBuilder.buildJSON(input()).data, as: UTF8.self)
        let keys = ["albums", "archiveLocalDateTime", "assetKey", "camera", "category", "creationDate", "schemaVersion"]
        let positions = keys.compactMap { text.range(of: "\"\($0)\":")?.lowerBound }
        #expect(positions.count == keys.count && positions == positions.sorted())
        #expect(!text.contains("generat"))
    }

    @Test func resourcesListThisDestinationOnly() throws {
        let object = try jsonObject(SidecarBuilder.buildJSON(input()))
        let resources = try #require(object["resources"] as? [[String: Any]])
        #expect(resources.count == 2)
        #expect(resources[0]["type"] as? String == "photo")
        #expect(resources[0]["kind"] as? String == "original")
        #expect(resources[0]["originalName"] as? String == "DSC001.ARW")
        #expect(resources[0]["backupName"] as? String == "2025-03-01 15.35.30_DSC001.ARW")
        #expect(resources[0]["size"] as? Int == 100)
        #expect(resources[0]["md5"] as? String == "m")
        #expect(resources[0]["sha256"] as? String == "s")
        #expect(resources[0]["state"] as? String == "done")
        #expect(resources[1]["md5"] == nil)
        #expect(resources[1]["state"] as? String == "pending")
    }

    @Test func extendedMetadataPresentReplacesUnavailableMarker() throws {
        let extended = SidecarExtendedMetadata(caption: "Sương mù", keywords: ["b", "a"])
        let object = try jsonObject(SidecarBuilder.buildJSON(input(extended: extended)))
        #expect(object["extendedMetadata"] == nil)
        #expect(object["caption"] as? String == "Sương mù")
        #expect(object["keywords"] as? [String] == ["a", "b"])
    }

    @Test func jsonEscapesControlCharacters() throws {
        let object = try jsonObject(SidecarBuilder.buildJSON(input(albums: ["a\"b\\c\n\u{1}"])))
        #expect(object["albums"] as? [String] == ["a\"b\\c\n\u{1}"])
    }

    @Test func nonFiniteDurationBecomesZero() {
        var value = input()
        value.asset.duration = .nan
        #expect(String(decoding: SidecarBuilder.buildJSON(value).data, as: UTF8.self).contains("\"duration\": 0.000"))
    }

    // MARK: XMP

    final class Collector: NSObject, XMLParserDelegate {
        var elements: [String] = []
        var text: [String: [String]] = [:]
        private var current = ""
        private var buffer = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            elements.append(name)
            current = name
            buffer = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == current, !trimmed.isEmpty { text[name, default: []].append(trimmed) }
            buffer = ""
            current = ""
        }
    }

    func parse(_ file: SidecarFile) throws -> Collector {
        let collector = Collector()
        let parser = XMLParser(data: file.data)
        parser.shouldProcessNamespaces = false
        parser.delegate = collector
        #expect(parser.parse(), "XMP must be well-formed: \(String(describing: parser.parserError))")
        return collector
    }

    @Test func xmpIsWellFormedWithExpectedStructure() throws {
        let extended = SidecarExtendedMetadata(caption: "Caption", keywords: ["k2", "k1"])
        let parsed = try parse(SidecarBuilder.buildXMP(input(extended: extended)))
        #expect(parsed.elements.first == "x:xmpmeta")
        #expect(parsed.text["xmp:Rating"] == ["5"])
        #expect(parsed.text["rdf:li"]?.contains("Caption") == true)
        #expect(parsed.text["rdf:li"]?.contains("k1") == true)
        #expect(parsed.text["rdf:li"]?.contains("PhotoVault|Album|Dalat 2025") == true)
        #expect(parsed.text["rdf:li"]?.contains("PhotoVault|Category|camera") == true)
        #expect(parsed.text["photoshop:City"] == ["Đà Lạt"])
        #expect(parsed.text["photoshop:State"] == ["Lâm Đồng"])
        #expect(parsed.text["photoshop:Country"] == ["Việt Nam"])
    }

    @Test func xmpNeverWritesDatesGpsOrExif() {
        let text = String(decoding: SidecarBuilder.buildXMP(input(extended: SidecarExtendedMetadata(caption: "c"))).data, as: UTF8.self)
        for forbidden in ["exif:", "tiff:", "GPS", "xmp:CreateDate", "xmp:ModifyDate", "photoshop:DateCreated", "11.94", "108.45", "2025-03"] {
            #expect(!text.contains(forbidden), "unexpected \(forbidden)")
        }
    }

    @Test func xmpOmitsOptionalPropertiesWhenAbsent() {
        let text = String(decoding: SidecarBuilder.buildXMP(input(albums: [], favorite: false, place: nil)).data, as: UTF8.self)
        #expect(!text.contains("xmp:Rating"))
        #expect(!text.contains("dc:description"))
        #expect(!text.contains("dc:subject"))
        #expect(!text.contains("photoshop:"))
        #expect(!text.contains("PhotoVault|Album"))
        #expect(text.contains("PhotoVault|Category|camera"))
    }

    @Test func xmpEscapesMarkupAndStripsBidiControls() throws {
        let title = "Tom & <Jerry> \"q\" 'a' a|b\u{202E}gpj\u{200B}"
        let extended = SidecarExtendedMetadata(caption: "x < y & z", keywords: ["k&k"])
        let file = SidecarBuilder.buildXMP(input(albums: [title], extended: extended))
        let text = String(decoding: file.data, as: UTF8.self)
        #expect(text.contains("PhotoVault|Album|Tom &amp; &lt;Jerry&gt; &quot;q&quot; &apos;a&apos; a/bgpj"))
        #expect(text.contains("x &lt; y &amp; z"))
        #expect(!text.contains("\u{202E}") && !text.contains("\u{200B}"))
        let parsed = try parse(file)
        #expect(parsed.text["rdf:li"]?.contains("PhotoVault|Album|Tom & <Jerry> \"q\" 'a' a/bgpj") == true)
        #expect(parsed.text["rdf:li"]?.contains("k&k") == true)
    }

    @Test func pipeInsideHierarchySegmentBecomesSlash() {
        let text = String(decoding: SidecarBuilder.buildXMP(input(albums: ["A|B|C"])).data, as: UTF8.self)
        #expect(text.contains("<rdf:li>PhotoVault|Album|A/B/C</rdf:li>"))
    }

    @Test func escaperDropsInvalidXmlCharacters() {
        #expect(XMLEscaper.escape("a\u{0}b\u{8}c\u{FFFE}d\u{7F}e\tf") == "abcde\tf")
        #expect(XMLEscaper.escape("\u{202A}\u{202C}\u{2066}x\u{FEFF}") == "x")
    }

    @Test func xmpDoesNotDependOnJsonInputOnlyFields() {
        var other = input()
        other.resources = []
        other.deviceDisplayName = "Another name"
        #expect(SidecarBuilder.buildXMP(input()) == SidecarBuilder.buildXMP(other))
    }
}
