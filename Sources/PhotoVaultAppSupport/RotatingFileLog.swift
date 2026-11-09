import Foundation
import PhotoVaultCore

/// File log with rotation (NFR-07): `photovault.log` plus `photovault.1.log`...`photovault.4.log`,
/// each up to 5 MB, so at most 25 MB stay on disk: the oldest file is deleted when a new one starts. Messages pass through `LogRedactor`.
public final class RotatingFileLog: LogSink, @unchecked Sendable {
    public static let fileSize = 5 * 1024 * 1024
    public static let fileCount = 5
    static let maxLineLength = 2000
    /// `2026-11-09T13:02:38.512Z`: UTC with milliseconds.
    static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public let directory: URL
    private let maxBytes: Int
    private let fileCount: Int
    private let clock: any Clock
    private let lock = NSLock()
    private var handle: FileHandle?
    private var currentSize = 0

    public init(directory: URL, maxBytes: Int = RotatingFileLog.fileSize, fileCount: Int = RotatingFileLog.fileCount,
                clock: any Clock = SystemClock()) {
        self.directory = directory
        self.maxBytes = max(1024, maxBytes)
        self.fileCount = max(2, fileCount)
        self.clock = clock
    }

    deinit { try? handle?.close() }

    public var currentFile: URL { url(for: 0) }

    func url(for index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "photovault.log" : "photovault.\(index).log")
    }

    public func log(_ level: LogLevel, category: String, _ message: String) {
        let line = Self.format(level: level, category: category, message: LogRedactor.sanitized(message), date: clock.now)
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try open()
            if currentSize > 0, currentSize + data.count > maxBytes { try rotate() }
            try handle?.write(contentsOf: data)
            currentSize += data.count
        } catch {
            // Logging must never take the app down; the os.Logger copy still exists.
            try? handle?.close()
            handle = nil
        }
    }

    /// Flushes and closes the file; the next write reopens it.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    static func format(level: LogLevel, category: String, message: String, date: Date) -> String {
        let flat = message.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let clipped = flat.count > maxLineLength ? String(flat.prefix(maxLineLength)) + "…" : flat
        return "\(date.formatted(timestampStyle)) [\(level.rawValue.uppercased())] \(category): \(clipped)\n"
    }

    private func open() throws {
        guard handle == nil else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = currentFile
        if !fileManager.fileExists(atPath: file.path) {
            guard fileManager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let opened = try FileHandle(forWritingTo: file)
        currentSize = Int(try opened.seekToEnd())
        handle = opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url(for: fileCount - 1))
        for index in stride(from: fileCount - 2, through: 0, by: -1) where fileManager.fileExists(atPath: url(for: index).path) {
            try fileManager.moveItem(at: url(for: index), to: url(for: index + 1))
        }
        try open()
    }
}
