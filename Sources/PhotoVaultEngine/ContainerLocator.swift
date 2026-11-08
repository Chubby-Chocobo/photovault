import Foundation

/// Where the database, staging area, backups and lock live. A signed (sandboxed) build and an
/// unsigned build must never share or split state, so an unsandboxed process refuses to start
/// unless it was launched with `--dev-container`, which selects a separate directory.
public struct ContainerLayout: Sendable, Equatable {
    public var root: URL
    public var isDevContainer: Bool

    public var database: URL { root.appendingPathComponent("photovault.sqlite") }
    public var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    public var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var lock: URL { root.appendingPathComponent(InstanceLock.fileName) }
}

public enum ContainerLocator {
    public static let sandboxVariable = "APP_SANDBOX_CONTAINER_ID"
    public static let devFlag = "--dev-container"

    /// - Parameters:
    ///   - applicationSupport: the user's Application Support directory (inside the container when sandboxed).
    ///   - homeDirectory: the real home directory, used for the dev container.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        applicationSupport: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ContainerLayout {
        if let id = environment[sandboxVariable], !id.isEmpty {
            return ContainerLayout(root: applicationSupport.appendingPathComponent("PhotoVault", isDirectory: true), isDevContainer: false)
        }
        guard arguments.contains(devFlag) else { throw EngineError.unsandboxedBuild }
        let root = homeDirectory.appendingPathComponent("Library/Application Support/PhotoVault-dev", isDirectory: true)
        return ContainerLayout(root: root, isDevContainer: true)
    }

    /// Creates the directories of the layout.
    public static func prepare(_ layout: ContainerLayout) throws {
        for directory in [layout.root, layout.staging, layout.backups, layout.logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
