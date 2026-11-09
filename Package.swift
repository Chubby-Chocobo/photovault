// swift-tools-version:6.1
import PackageDescription

let strictSwift: [SwiftSetting] = [
]

let package = Package(
    name: "PhotoVault",
    defaultLocalization: "vi",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotoVaultCore", targets: ["PhotoVaultCore"]),
        .library(name: "PhotoVaultStore", targets: ["PhotoVaultStore"]),
        .library(name: "PhotoVaultPhotos", targets: ["PhotoVaultPhotos"]),
        .library(name: "PhotoVaultDrive", targets: ["PhotoVaultDrive"]),
        .library(name: "PhotoVaultLocal", targets: ["PhotoVaultLocal"]),
        .library(name: "PhotoVaultEngine", targets: ["PhotoVaultEngine"]),
        .library(name: "PhotoVaultAppSupport", targets: ["PhotoVaultAppSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
    ],
    targets: [
        .target(
            name: "PhotoVaultCore",
            resources: [.process("Resources")],
            swiftSettings: strictSwift
        ),
        .target(
            name: "PhotoVaultStore",
            dependencies: ["PhotoVaultCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strictSwift
        ),
        .target(name: "PhotoVaultPhotos", dependencies: ["PhotoVaultCore"], swiftSettings: strictSwift),
        .target(name: "PhotoVaultDrive", dependencies: ["PhotoVaultCore"], swiftSettings: strictSwift),
        .target(name: "PhotoVaultLocal", dependencies: ["PhotoVaultCore"], swiftSettings: strictSwift),
        .target(
            name: "PhotoVaultEngine",
            dependencies: ["PhotoVaultCore", "PhotoVaultStore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strictSwift
        ),
        .target(
            name: "PhotoVaultAppSupport",
            dependencies: ["PhotoVaultCore", "PhotoVaultEngine"],
            swiftSettings: strictSwift
        ),
        .target(name: "PhotoVaultTestSupport", dependencies: ["PhotoVaultCore"], swiftSettings: strictSwift),

        .testTarget(name: "PhotoVaultCoreTests", dependencies: ["PhotoVaultCore", "PhotoVaultTestSupport"], swiftSettings: strictSwift),
        .testTarget(name: "PhotoVaultStoreTests", dependencies: ["PhotoVaultStore", "PhotoVaultTestSupport"], swiftSettings: strictSwift),
        .testTarget(
            name: "PhotoVaultPhotosTests", dependencies: ["PhotoVaultPhotos", "PhotoVaultTestSupport"],
            resources: [.copy("Fixtures/RawHeaders")], swiftSettings: strictSwift
        ),
        .testTarget(name: "PhotoVaultDriveTests", dependencies: ["PhotoVaultDrive", "PhotoVaultTestSupport"], swiftSettings: strictSwift),
        .testTarget(name: "PhotoVaultLocalTests", dependencies: ["PhotoVaultLocal", "PhotoVaultTestSupport"], swiftSettings: strictSwift),
        .testTarget(
            name: "PhotoVaultEngineTests",
            dependencies: ["PhotoVaultEngine", "PhotoVaultStore", "PhotoVaultLocal", "PhotoVaultTestSupport"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "PhotoVaultAppSupportTests",
            dependencies: ["PhotoVaultAppSupport", "PhotoVaultTestSupport"],
            swiftSettings: strictSwift
        ),
    ],
    swiftLanguageModes: [.v6]
)
