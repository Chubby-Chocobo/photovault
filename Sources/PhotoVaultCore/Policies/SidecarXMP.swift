import Foundation

/// The one XML escaper for XMP text (FR-92). Strips Unicode format characters (bidi overrides,
/// zero-width) and characters illegal in XML 1.0, then escapes the five markup characters.
enum XMLEscaper {
    static func escape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            guard isAllowed(scalar) else { continue }
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD: return true
        case 0..<0x20, 0x7F...0x9F, 0xFFFE, 0xFFFF: return false
        default: return scalar.properties.generalCategory != .format
        }
    }
}

extension SidecarBuilder {
    /// Deterministic XMP packet (`<stem>.xmp`): rating, description, keywords, hierarchy and
    /// location names only; never dates, GPS or EXIF.
    public static func buildXMP(_ input: SidecarInput) -> SidecarFile {
        let asset = input.asset
        var properties: [String] = []
        if asset.isFavorite { properties.append("   <xmp:Rating>5</xmp:Rating>") }
        if let caption = input.extendedMetadata?.caption, !caption.isEmpty {
            properties.append("""
               <dc:description>
                <rdf:Alt>
                 <rdf:li xml:lang="x-default">\(XMLEscaper.escape(caption))</rdf:li>
                </rdf:Alt>
               </dc:description>
            """)
        }
        let keywords = (input.extendedMetadata?.keywords ?? []).filter { !XMLEscaper.escape($0).isEmpty }
        if !keywords.isEmpty { properties.append(bag("dc:subject", sortedUnique(keywords))) }

        var hierarchy = sortedUnique(input.albumTitles).filter(hasContent).map { "PhotoVault|Album|" + segment($0) }
        if let category = asset.category { hierarchy.append("PhotoVault|Category|" + segment(category.rawValue)) }
        if !hierarchy.isEmpty { properties.append(bag("lr:hierarchicalSubject", hierarchy)) }

        if let place = input.place {
            for (name, value) in [("photoshop:City", place.locality), ("photoshop:State", place.administrativeArea),
                                  ("photoshop:Country", place.country)] {
                if let value, !XMLEscaper.escape(value).isEmpty {
                    properties.append("   <\(name)>\(XMLEscaper.escape(value))</\(name)>")
                }
            }
        }

        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PhotoVault">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
        \(properties.joined(separator: "\n"))
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>

        """
        return SidecarFile(data: Data(xml.utf8))
    }

    /// A hierarchy segment: `|` would split the path, so it becomes `/`; markup is escaped later.
    private static func segment(_ title: String) -> String {
        title.replacingOccurrences(of: "|", with: "/")
    }

    private static func hasContent(_ value: String) -> Bool { !XMLEscaper.escape(value).isEmpty }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Set(values).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func bag(_ name: String, _ items: [String]) -> String {
        let entries = items.map { "     <rdf:li>\(XMLEscaper.escape($0))</rdf:li>" }.joined(separator: "\n")
        return "   <\(name)>\n    <rdf:Bag>\n\(entries)\n    </rdf:Bag>\n   </\(name)>"
    }
}
