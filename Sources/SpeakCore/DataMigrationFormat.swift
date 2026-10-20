import Foundation

public enum DataMigrationFormat {
    public static let identifier = "JustSpeakToIt"
    public static let version = 2
    public static let minimumReadableVersion = 1
}

public enum DataMigrationCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case settings, history, recordings, credentials, profiles, vocabulary, connections, models

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .settings: return "Settings & shortcuts"
        case .history: return "History text & speech usage"
        case .recordings: return "Recordings"
        case .credentials: return "API keys & credentials"
        case .profiles: return "Dictation profiles"
        case .vocabulary: return "Vocabulary, pronunciation & corrections"
        case .connections: return "Connections"
        case .models: return "Model references"
        }
    }

    public static var defaults: Set<Self> { Set(allCases).subtracting([.credentials]) }
}

public enum DataMigrationMode: String, CaseIterable, Identifiable, Sendable {
    case skip, merge, replace

    public var id: String { rawValue }
}

public struct DataMigrationScope: Codable, Equatable, Sendable {
    public var start: Date?
    public var end: Date?
    public var selectedIDs: Set<String>?
    public var selectedKinds: Set<String>?

    public init(start: Date? = nil, end: Date? = nil, selectedIDs: Set<String>? = nil) {
        self.init(start: start, end: end, selectedIDs: selectedIDs, selectedKinds: nil)
    }

    public init(
        start: Date? = nil, end: Date? = nil, selectedIDs: Set<String>? = nil, selectedKinds: Set<String>?
    ) {
        self.start = start
        self.end = end
        self.selectedIDs = selectedIDs
        self.selectedKinds = selectedKinds
    }

    public func contains(id: String, date: Date?) -> Bool { contains(id: id, date: date, kind: nil) }

    public func contains(id: String, date: Date?, kind: String?) -> Bool {
        if let selectedKinds {
            guard let kind, selectedKinds.contains(kind) else { return false }
        }
        if let selectedIDs, !selectedIDs.contains(id) { return false }
        if let start {
            guard let date else { return false }
            if date < start { return false }
        }
        if let end {
            guard let date else { return false }
            if date >= end { return false }
        }
        return true
    }

    public func contains(kind: String) -> Bool { selectedKinds?.contains(kind) ?? true }

    public func contains(id: String, kind: String) -> Bool {
        contains(kind: kind) && (selectedIDs?.contains(id) ?? true)
    }

    public var isComplete: Bool { start == nil && end == nil && selectedIDs == nil && selectedKinds == nil }
}

public struct DataMigrationRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var value: AnyCodable
    public var date: Date?
    public var file: String?
    public var digest: String?
    public var revision: String?

    public var identity: String { kind + ":" + id }

    public init(
        id: String, kind: String, value: AnyCodable, date: Date? = nil, file: String? = nil,
        digest: String? = nil, revision: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.date = date
        self.file = file
        self.digest = digest
        self.revision = revision
    }
}

public struct DataMigrationManifest: Codable, Sendable {
    public var format: String
    public var version: Int
    public var createdAt: Date
    public var categories: [DataMigrationCategory]
    public var scopes: [String: DataMigrationScope]

    public init(
        format: String = DataMigrationFormat.identifier, version: Int = DataMigrationFormat.version,
        createdAt: Date = Date(), categories: [DataMigrationCategory], scopes: [String: DataMigrationScope]
    ) {
        self.format = format
        self.version = version
        self.createdAt = createdAt
        self.categories = categories
        self.scopes = scopes
    }
}

public struct DataMigrationSnapshot: Sendable {
    public var manifest: DataMigrationManifest
    public var records: [DataMigrationCategory: [DataMigrationRecord]]
    public var files: [String: URL]
    public var notices: [String]
    public var directory: URL?

    public init(
        manifest: DataMigrationManifest, records: [DataMigrationCategory: [DataMigrationRecord]],
        files: [String: URL] = [:], notices: [String] = [], directory: URL? = nil
    ) {
        self.manifest = manifest
        self.records = records
        self.files = files
        self.notices = notices
        self.directory = directory
    }
}

public enum DataMigrationError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}
