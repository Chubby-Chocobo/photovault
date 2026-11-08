import Foundation

/// Destination configuration stored as `config_json`.
public struct DestinationConfig: Hashable, Codable, Sendable {
    /// Drive: root folder ID and name.
    public var driveRootId: String?
    public var driveRootName: String?
    /// Local: app-scoped security-scoped bookmark.
    public var bookmark: Data?
    /// Local: last resolved path, for display only.
    public var displayPath: String?
    /// Local: id written to `.photovault/destination.json` (FR-74).
    public var localMarkerId: String?

    public init(driveRootId: String? = nil, driveRootName: String? = nil, bookmark: Data? = nil,
                displayPath: String? = nil, localMarkerId: String? = nil) {
        self.driveRootId = driveRootId
        self.driveRootName = driveRootName
        self.bookmark = bookmark
        self.displayPath = displayPath
        self.localMarkerId = localMarkerId
    }
}

/// Row of `destination` (spec 8.2).
public struct DestinationRecord: Hashable, Codable, Sendable {
    public var id: DestinationID
    public var kind: DestinationKind
    public var displayName: String
    public var status: DestinationStatus
    /// When the current status began (FR-61 duration notifications).
    public var statusSince: Date
    public var scope: ScopeMode
    /// Content present before this moment counts as "old" for `newOnly`/`since` (8.8, FR-71).
    public var baselineAt: Date?
    public var rules: DestinationRules
    public var config: DestinationConfig
    public var accountId: String?
    public var accountEmail: String?
    /// Set by every recovery trigger; uploads to this destination wait until FR-51 clears it.
    public var recoveryRequired: Bool
    public var lastSuccessAt: Date?
    public var createdAt: Date

    public init(
        id: DestinationID, displayName: String, status: DestinationStatus = .active, statusSince: Date,
        scope: ScopeMode = .full, baselineAt: Date? = nil, rules: DestinationRules = .everything,
        config: DestinationConfig = DestinationConfig(), accountId: String? = nil, accountEmail: String? = nil,
        recoveryRequired: Bool = false, lastSuccessAt: Date? = nil, createdAt: Date
    ) {
        self.id = id
        self.kind = id.kind
        self.displayName = displayName
        self.status = status
        self.statusSince = statusSince
        self.scope = scope
        self.baselineAt = baselineAt
        self.rules = rules
        self.config = config
        self.accountId = accountId
        self.accountEmail = accountEmail
        self.recoveryRequired = recoveryRequired
        self.lastSuccessAt = lastSuccessAt
        self.createdAt = createdAt
    }

    /// Uploads may run: active and not waiting for recovery.
    public var acceptsUploads: Bool { status.isActive && !recoveryRequired }
}
