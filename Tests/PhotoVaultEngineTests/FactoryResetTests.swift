import Foundation
import Testing
@testable import PhotoVaultEngine

@Suite struct FactoryResetTests {
    private func layout() throws -> ContainerLayout {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
        let layout = ContainerLayout(root: root, isDevContainer: true)
        try ContainerLocator.prepare(layout)
        for name in ["photovault.sqlite", "photovault.sqlite-wal", "photovault.sqlite-shm", FactoryReset.dailyCapFileName, InstanceLock.fileName] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        try Data("y".utf8).write(to: layout.staging.appendingPathComponent("staged.bin"))
        try Data("z".utf8).write(to: layout.logs.appendingPathComponent("photovault.log"))
        return layout
    }

    private func names(_ layout: ContainerLayout) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: layout.root.path).sorted()
    }

    @Test func nothingHappensWithoutARequest() throws {
        let layout = try layout()
        let before = try names(layout)
        #expect(try FactoryReset.applyIfRequested(layout) == false)
        #expect(try names(layout) == before)
    }

    @Test func aRequestedResetKeepsOnlyTheLockAndTheDailyCap() throws {
        let layout = try layout()
        try FactoryReset.request(layout)
        #expect(FactoryReset.isRequested(layout))
        #expect(try FactoryReset.applyIfRequested(layout))
        #expect(try names(layout) == [FactoryReset.dailyCapFileName, InstanceLock.fileName].sorted())
        #expect(!FactoryReset.isRequested(layout))
        try ContainerLocator.prepare(layout)
        #expect(FileManager.default.fileExists(atPath: layout.staging.path), "folders come back for the fresh start")
    }

    @Test func aFailedWipeKeepsTheMarkerForTheNextLaunch() throws {
        let layout = try layout()
        try FactoryReset.request(layout)
        let locked = layout.root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data().write(to: locked.appendingPathComponent("inner"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        #expect(throws: (any Error).self) { try FactoryReset.applyIfRequested(layout) }
        #expect(FactoryReset.isRequested(layout))
    }
}
