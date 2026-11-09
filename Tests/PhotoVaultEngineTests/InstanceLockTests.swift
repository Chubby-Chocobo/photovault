import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

@Suite struct InstanceLockTests {
    @Test func t41SecondInstanceIsRefused() throws {
        let dir = try TestFiles.temporaryDirectory("lock")
        let first = try InstanceLock.acquire(containerDirectory: dir)
        #expect(throws: InstanceLock.LockError.alreadyRunning) { try InstanceLock.acquire(containerDirectory: dir) }
        first.release()
        let again = try InstanceLock.acquire(containerDirectory: dir)
        again.release()
    }

    @Test func lockIsReleasedWhenTheHolderGoesAway() throws {
        let dir = try TestFiles.temporaryDirectory("lock")
        do {
            let held = try InstanceLock.acquire(containerDirectory: dir)
            _ = held
        }
        let next = try InstanceLock.acquire(containerDirectory: dir)
        next.release()
    }

    @Test func differentContainersDoNotConflict() throws {
        let a = try InstanceLock.acquire(containerDirectory: try TestFiles.temporaryDirectory("lock"))
        let b = try InstanceLock.acquire(containerDirectory: try TestFiles.temporaryDirectory("lock"))
        a.release()
        b.release()
    }

    @Test func sandboxedBuildUsesApplicationSupportInsideTheContainer() throws {
        let support = URL(fileURLWithPath: "/tmp/Container/Library/Application Support")
        let layout = try ContainerLocator.resolve(
            environment: ["APP_SANDBOX_CONTAINER_ID": "app.photovault"], arguments: ["PhotoVault"], applicationSupport: support)
        #expect(layout.root.path == "/tmp/Container/Library/Application Support/PhotoVault")
        #expect(!layout.isDevContainer)
        #expect(layout.lock.lastPathComponent == "photovault.lock")
        #expect(layout.staging.deletingLastPathComponent() == layout.root)
    }

    @Test func unsandboxedBuildRefusesWithoutTheDevFlag() {
        #expect(throws: EngineError.unsandboxedBuild) {
            try ContainerLocator.resolve(environment: [:], arguments: ["PhotoVault"], applicationSupport: URL(fileURLWithPath: "/tmp/x"))
        }
        #expect(throws: EngineError.unsandboxedBuild) {
            try ContainerLocator.resolve(environment: ["APP_SANDBOX_CONTAINER_ID": ""], arguments: [], applicationSupport: URL(fileURLWithPath: "/tmp/x"))
        }
    }

    @Test func devFlagSelectsASeparateDirectory() throws {
        let home = URL(fileURLWithPath: "/Users/someone")
        let layout = try ContainerLocator.resolve(
            environment: [:], arguments: ["PhotoVault", "--dev-container"], applicationSupport: URL(fileURLWithPath: "/ignored"), homeDirectory: home)
        #expect(layout.root.path == "/Users/someone/Library/Application Support/PhotoVault-dev")
        #expect(layout.isDevContainer)
        let sandboxed = try ContainerLocator.resolve(
            environment: ["APP_SANDBOX_CONTAINER_ID": "x"], arguments: ["--dev-container"], applicationSupport: URL(fileURLWithPath: "/a"))
        #expect(!sandboxed.isDevContainer, "a sandboxed build never uses the dev directory")
    }

    @Test func prepareCreatesTheLayout() throws {
        let base = try TestFiles.temporaryDirectory("layout")
        let layout = ContainerLayout(root: base.appendingPathComponent("PV"), isDevContainer: true)
        try ContainerLocator.prepare(layout)
        for dir in [layout.root, layout.staging, layout.backups, layout.logs] {
            #expect(FileManager.default.fileExists(atPath: dir.path))
        }
    }
}
