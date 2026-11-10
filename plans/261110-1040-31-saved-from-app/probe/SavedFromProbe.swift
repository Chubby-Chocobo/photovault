// Spike probe for issue #31 (saved-from-app). Read-only. Prints one line per asset with
// COUNTS-ONLY style fields: no file names, no paths, no Software text. Shapes of file names are
// reduced to a pattern (digits -> 9, letters -> a/A) so the owner can compare families.
//
// Run (owner, unsandboxed, Terminal needs Photos access):
//   swiftc -O saved_from_probe.swift -o /tmp/saved_from_probe && /tmp/saved_from_probe 200
// Output: one TSV-like line per asset, plus a summary by shape family.
import Foundation
import Photos
import ImageIO

let limit = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 200 : 200

func shape(_ name: String) -> String {
    var out = ""
    for ch in name {
        if ch.isNumber { out += "9" } else if ch.isLetter { out += ch.isUppercase ? "A" : "a" } else { out.append(ch) }
    }
    // collapse runs so IMG_9999.JPG and IMG_1234.JPG share a shape
    var collapsed = ""
    var last: Character? = nil
    for ch in out where ch != last || (ch != "9" && ch != "A" && ch != "a") {
        collapsed.append(ch); last = ch
    }
    return collapsed
}

func versionClass(_ s: String?) -> String {
    guard let s, !s.isEmpty else { return "absent" }
    let isVersion = s.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil
    return isVersion ? "version-like" : "text"
}

func requestPhotoData(_ resource: PHAssetResource) -> Data? {
    let opts = PHAssetResourceRequestOptions()
    opts.isNetworkAccessAllowed = false  // local bytes only: never triggers an iCloud download
    var data = Data()
    var ok = false
    let sem = DispatchSemaphore(value: 0)
    PHAssetResourceManager.default().requestData(for: resource, options: opts,
        dataReceivedHandler: { data.append($0) },
        completionHandler: { error in ok = error == nil; sem.signal() })
    sem.wait()
    return ok ? data : nil
}

let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
if auth != .authorized {
    let s = DispatchSemaphore(value: 0)
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in s.signal() }
    s.wait()
}

let opts = PHFetchOptions()
opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
opts.fetchLimit = limit
let assets = PHAsset.fetchAssets(with: .image, options: opts)

var families: [String: Int] = [:]
print("idx\tmediaSubtypes\tresources\tphotoShape\tmake\tmodel\tsoftware\tuserComment\tdaysAddedMinusCreated\tbuckets")
assets.enumerateObjects { asset, index, _ in
    let resources = PHAssetResource.assetResources(for: asset)
    let photo = resources.first { $0.type == .photo }
    var make = "-", model = "-", software = "absent", comment = "-"
    if let photo, let data = requestPhotoData(photo),
       let src = CGImageSourceCreateWithData(data as CFData, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        make = (tiff?[kCGImagePropertyTIFFMake] as? String).map { $0.isEmpty ? "empty" : "present" } ?? "absent"
        model = (tiff?[kCGImagePropertyTIFFModel] as? String).map { $0.isEmpty ? "empty" : "present" } ?? "absent"
        software = versionClass(tiff?[kCGImagePropertyTIFFSoftware] as? String)
        comment = (exif?[kCGImagePropertyExifUserComment] as? String).map { _ in "present" } ?? "absent"
    }
    var delta = "n/a"
    if #available(macOS 26.0, *), let created = asset.creationDate {
        delta = String(Int(asset.addedDate.timeIntervalSince(created) / 86_400))
    }
    let name = photo?.originalFilename ?? ""
    let photoShape = name.isEmpty ? "none" : shape(name)
    let family = "\(photoShape)|make=\(make)|model=\(model)|sw=\(software)"
    families[family, default: 0] += 1
    print("\(index)\t\(asset.mediaSubtypes.rawValue)\t\(resources.count)\t\(photoShape)\t\(make)\t\(model)\t\(software)\t\(comment)\t\(delta)\t\(family)")
}

print("\n# summary by family (shape | make | model | software) -> count")
for (k, v) in families.sorted(by: { $0.value > $1.value }) { print("\(v)\t\(k)") }
