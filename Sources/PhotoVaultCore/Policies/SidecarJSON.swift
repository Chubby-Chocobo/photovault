import Foundation

/// Minimal JSON value with a deterministic writer: sorted keys, two-space indent, numbers
/// carried as pre-formatted text so formatting never depends on the platform.
enum JSONValue {
    case string(String)
    case number(String)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    static func int<T: BinaryInteger>(_ value: T) -> JSONValue { .number(String(value)) }

    /// Fixed decimals; non-finite values and negative zero become `0`.
    static func fixed(_ value: Double, decimals: Int) -> JSONValue {
        let safe = value.isFinite && value != 0 ? value : 0
        return .number(String(format: "%.\(decimals)f", safe))
    }

    func render() -> String {
        var out = ""
        write(into: &out, indent: 0)
        out += "\n"
        return out
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closePad = String(repeating: "  ", count: indent)
        switch self {
        case .string(let value): out += Self.quote(value)
        case .number(let text): out += text
        case .bool(let value): out += value ? "true" : "false"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                item.write(into: &out, indent: indent + 1)
                out += index < items.count - 1 ? ",\n" : "\n"
            }
            out += closePad + "]"
        case .object(let fields):
            guard !fields.isEmpty else { out += "{}"; return }
            let keys = fields.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            out += "{\n"
            for (index, key) in keys.enumerated() {
                out += pad + Self.quote(key) + ": "
                fields[key]!.write(into: &out, indent: indent + 1)
                out += index < keys.count - 1 ? ",\n" : "\n"
            }
            out += closePad + "}"
        }
    }

    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension SidecarBuilder {
    /// Fixed-format ISO 8601 UTC with milliseconds, e.g. `2025-03-01T08:15:30.250Z`.
    static func utcString(_ date: Date) -> String {
        formatted(date, timeZone: TimeZone(secondsFromGMT: 0)!, pattern: "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
    }

    static func localString(_ date: Date, in timeZone: TimeZone) -> String {
        formatted(date, timeZone: timeZone, pattern: "yyyy-MM-dd'T'HH:mm:ss")
    }

    private static func formatted(_ date: Date, timeZone: TimeZone, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    static func mediaTypeName(_ type: MediaType) -> String {
        switch type {
        case .unknown: "unknown"
        case .image: "image"
        case .video: "video"
        case .audio: "audio"
        }
    }

    static let subtypeNames: [(MediaSubtypes, String)] = [
        (.photoPanorama, "panorama"), (.photoHDR, "hdr"), (.photoScreenshot, "screenshot"), (.photoLive, "live"),
        (.photoDepthEffect, "depthEffect"), (.spatialMedia, "spatial"), (.videoStreamed, "streamed"),
        (.videoHighFrameRate, "highFrameRate"), (.videoTimelapse, "timelapse"),
        (.videoScreenRecording, "screenRecording"), (.videoCinematic, "cinematic"),
    ]

    /// Deterministic JSON sidecar (`<stem>.json`).
    public static func buildJSON(_ input: SidecarInput) -> SidecarFile {
        let asset = input.asset
        var root: [String: JSONValue] = [
            "schemaVersion": .int(input.schemaVersion),
            "assetKey": .string(asset.assetKey.rawValue),
            "localIdentifier": .string(asset.localId),
            "archiveTimezone": .string(input.archiveTimeZone.identifier),
            "mediaType": .string(mediaTypeName(asset.mediaType)),
            "mediaSubtypes": .array(subtypeNames.filter { asset.mediaSubtypes.contains($0.0) }.map { .string($0.1) }),
            "pixelWidth": .int(asset.pixelWidth),
            "pixelHeight": .int(asset.pixelHeight),
            "duration": .fixed(asset.duration, decimals: 3),
            "isFavorite": .bool(asset.isFavorite),
            "isHidden": .bool(asset.isHidden),
            "albums": .array(Set(input.albumTitles).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { .string($0) }),
            "resources": .array(resourcesJSON(input.resources)),
        ]
        if let cloudId = asset.cloudId { root["cloudIdentifier"] = .string(cloudId) }
        if let created = asset.creationDate {
            root["creationDate"] = .string(utcString(created))
            root["archiveLocalDateTime"] = .string(localString(created, in: input.archiveTimeZone))
        }
        if let modified = asset.modificationDate { root["modificationDate"] = .string(utcString(modified)) }
        if let category = asset.category { root["category"] = .string(category.rawValue) }
        if let reason = asset.categoryReason { root["categoryReason"] = .string(reason.rawValue) }
        if let burst = asset.burstIdentifier { root["burstIdentifier"] = .string(burst) }
        if let point = asset.location {
            root["location"] = .object([
                "latitude": .fixed(point.latitude, decimals: 6), "longitude": .fixed(point.longitude, decimals: 6),
            ])
        }
        if let place = input.place { root["place"] = placeJSON(place) }
        if let camera = cameraJSON(asset, deviceName: input.deviceDisplayName) { root["camera"] = camera }
        if let source = input.source { root["source"] = sourceJSON(source) }
        if let extended = input.extendedMetadata {
            if let caption = extended.caption { root["caption"] = .string(caption) }
            root["keywords"] = .array(extended.keywords.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { .string($0) })
        } else {
            root["extendedMetadata"] = .string("unavailable")
        }
        return SidecarFile(data: Data(JSONValue.object(root).render().utf8))
    }

    private static func sourceJSON(_ source: SidecarSource) -> JSONValue {
        var fields: [String: JSONValue] = ["kind": .string(source.kind), "name": .string(source.name), "path": .string(source.path)]
        if let dateSource = source.dateSource { fields["dateSource"] = .string(dateSource.rawValue) }
        return .object(fields)
    }

    private static func placeJSON(_ place: GeoPlace) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if let value = place.isoCountryCode { fields["isoCountryCode"] = .string(value) }
        if let value = place.country { fields["country"] = .string(value) }
        if let value = place.administrativeArea { fields["administrativeArea"] = .string(value) }
        if let value = place.locality { fields["locality"] = .string(value) }
        return .object(fields)
    }

    private static func cameraJSON(_ asset: AssetRecord, deviceName: String?) -> JSONValue? {
        var fields: [String: JSONValue] = [:]
        if let value = asset.cameraMake { fields["make"] = .string(value) }
        if let value = asset.cameraModel { fields["model"] = .string(value) }
        if let value = deviceName { fields["deviceName"] = .string(value) }
        if let value = asset.lensModel { fields["lens"] = .string(value) }
        return fields.isEmpty ? nil : .object(fields)
    }

    private static func resourcesJSON(_ resources: [SidecarResource]) -> [JSONValue] {
        resources.sorted { ($0.type.rawValue, $0.backupName) < ($1.type.rawValue, $1.backupName) }.map { item in
            var fields: [String: JSONValue] = [
                "type": .string(item.type.description), "kind": .string(item.kind.rawValue),
                "originalName": .string(item.originalName), "backupName": .string(item.backupName),
                "state": .string(item.state.rawValue),
            ]
            if let size = item.size { fields["size"] = .int(size) }
            if let md5 = item.md5 { fields["md5"] = .string(md5) }
            if let sha = item.sha256 { fields["sha256"] = .string(sha) }
            return .object(fields)
        }
    }
}
