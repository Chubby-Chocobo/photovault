import Foundation

/// What a running transfer does with one file.
public enum TransferKind: Sendable, Equatable {
    /// Photos exports the resource to staging.
    case exportFromPhotos
    /// An import source (Mac folder, Dropbox, Google Drive) delivers the file.
    case download(SourceKind)
    /// Bytes go to a remote destination (Google Drive).
    case upload
    /// Bytes are written to a local or network folder.
    case copy
}

/// A file being transferred right now. In-memory only: it is shown on this Mac and never persisted,
/// logged, notified or written to a file, so its description redacts the names.
public struct TransferProgress: Sendable, Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public var id: UUID
    public var kind: TransferKind
    /// The file's original name. Shown in the app only.
    public var fileName: String
    /// Display name of the destination for an upload or copy. Shown in the app only.
    public var destinationName: String?
    public var bytesDone: Int64
    /// Nil when the total is not known; only the bytes done are shown then.
    public var bytesTotal: Int64?
    public var startedAt: Date

    public init(id: UUID = UUID(), kind: TransferKind, fileName: String, destinationName: String? = nil,
                bytesDone: Int64 = 0, bytesTotal: Int64? = nil, startedAt: Date) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.destinationName = destinationName
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.startedAt = startedAt
    }

    /// 0...1, nil when the total is unknown.
    public var fraction: Double? {
        guard let bytesTotal, bytesTotal > 0 else { return nil }
        return min(1, max(0, Double(bytesDone) / Double(bytesTotal)))
    }

    public var description: String { "TransferProgress(\(kind), <redacted>, bytes: \(bytesDone))" }
    public var debugDescription: String { description }
}

/// Where a transport reports the bytes it has moved so far for one file. Cheap to call from any
/// thread; the receiver throttles. Equal only to itself, so requests that carry one stay `Hashable`.
public struct TransferSink: Sendable, Hashable {
    private let token = UUID()
    private let handler: @Sendable (Int64) -> Void

    public init(_ handler: @escaping @Sendable (Int64) -> Void) { self.handler = handler }

    /// Cumulative bytes done for this file.
    public func report(_ bytesDone: Int64) { handler(bytesDone) }

    public static func == (lhs: TransferSink, rhs: TransferSink) -> Bool { lhs.token == rhs.token }
    public func hash(into hasher: inout Hasher) { hasher.combine(token) }
}
