import Foundation

/// Coverage of preservation-only source records, never category or native replacement authority.
public struct DesktopNativeConfigurationCoverage: Sendable, Equatable {
    public let keys: Set<String>
    public var category: DataMigrationCategory { .settings }
    public var recordKind: String { DesktopNativeConfigurationArchiveCodec.recordKind }
    public var keysByKind: [String: Set<String>] { [recordKind: keys] }
    public var selectionScope: DataMigrationScope { .init(selectedIDs: keys) }
    public var permitsReplacement: Bool { false }
    public var isCompleteCategory: Bool { false }
}

/// Validated archive transport only. No native importer, apply route or retained store is provided.
public struct DesktopNativeConfigurationArchive: Sendable {
    public let records: [DataMigrationRecord]
    public let entries: [DesktopNativeConfigurationCapture.Entry]
    public let coverage: DesktopNativeConfigurationCoverage
    public let unresolvedPaths: [String]
}
