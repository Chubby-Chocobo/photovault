import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct DeviceNameResolverTests {
    @Test func normalizesKey() {
        #expect(DeviceNameResolver.key(make: "  Canon ", model: "Canon   EOS  R5\n") == "CANON|CANON EOS R5")
        #expect(DeviceNameResolver.key(make: nil, model: "X") == "|X")
    }

    @Test func groupIdIsDeterministicSixteenHex() {
        let id = DeviceNameResolver.groupId(forKey: "SONY|ILCE-7M4")
        #expect(id.count == 16 && id.allSatisfy(\.isHexDigit))
        #expect(id == DeviceNameResolver.groupId(forKey: "SONY|ILCE-7M4"))
        #expect(id != DeviceNameResolver.groupId(forKey: "SONY|ILCE-7M3"))
    }

    @Test(arguments: [
        ("Canon", "Canon EOS R5", "Canon EOS R5"),
        ("Apple", "iPhone 15 Pro", "Apple iPhone 15 Pro"),
        ("SONY", "ILCE-9", "Sony ILCE-9"),
        ("NIKON CORPORATION", "NIKON Z 5", "Nikon Z 5"),
        ("LEICA CAMERA AG", "LEICA M11", "Leica M11"),
        ("FUJIFILM", "X-T5", "Fujifilm X-T5"),
        ("DJI", "FC9999", "DJI FC9999"),
        ("Acme Corp", "Acme Corp Pro", "Acme Corp Pro"),
        ("Acme", "Acmeter 3", "Acme Acmeter 3"),
        ("", "Solo Model", "Solo Model"),
        ("Canon", "", "Canon"),
    ])
    func defaultNames(make: String, model: String, expected: String) {
        #expect(DeviceNameResolver.defaultName(make: make, model: model) == expected)
    }

    @Test func tableOverridesDefault() {
        let resolver = DeviceNameResolver(table: ["sony|ilce-7m4": "Sony A7 IV"])
        #expect(resolver.displayName(make: "SONY", model: "ILCE-7M4") == "Sony A7 IV")
        #expect(resolver.displayName(make: " Sony", model: " ilce-7m4 ") == "Sony A7 IV")
        #expect(resolver.displayName(make: "SONY", model: "ILCE-9") == "Sony ILCE-9")
    }

    @Test func bundledTableLoads() {
        let table = DeviceNameResolver.bundled.table
        #expect(table.count >= 13)
        #expect(DeviceNameResolver.bundled.displayName(make: "SONY", model: "ILCE-7M4") == "Sony A7 IV")
        #expect(DeviceNameResolver.bundled.displayName(make: "NIKON CORPORATION", model: "NIKON Z 6_2") == "Nikon Z6 II")
        for (key, name) in table {
            #expect(key == key.uppercased() && key.contains("|") && !name.isEmpty)
        }
    }
}
