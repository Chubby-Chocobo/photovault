import Foundation
import OSLog
import PhotoVaultCore

/// The app's `LogSink`: unified logging (`os.Logger`) and the rotating file log, both fed with the
/// redacted message.
public struct AppLogSink: LogSink {
    public static let subsystem = "com.annh.photovault"

    private let file: RotatingFileLog?

    public init(file: RotatingFileLog?) { self.file = file }

    public func log(_ level: LogLevel, category: String, _ message: String) {
        let safe = LogRedactor.sanitized(message)
        let logger = Logger(subsystem: Self.subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(safe, privacy: .public)")
        case .info: logger.info("\(safe, privacy: .public)")
        case .notice: logger.notice("\(safe, privacy: .public)")
        case .error: logger.error("\(safe, privacy: .public)")
        case .fault: logger.fault("\(safe, privacy: .public)")
        }
        file?.log(level, category: category, safe)
    }
}
