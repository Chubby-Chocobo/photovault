import Foundation
import PhotoVaultCore
import UniformTypeIdentifiers

/// `UTIResolver` backed by `UTType`.
public struct UTTypeResolver: UTIResolver {
    public init() {}

    public func isRaw(_ uti: String) -> Bool {
        guard let type = UTType(uti) else { return false }
        return type.conforms(to: .rawImage)
    }

    public func preferredExtension(for uti: String) -> String? {
        UTType(uti)?.preferredFilenameExtension
    }
}
