import Foundation

/// Potentially sensitive byte evidence, never validated application or full-category backup authority.
public enum DesktopNativeSourceDocument {
    public enum Platform: String, CaseIterable, Sendable {
        case windows, linux
    }

    public enum Source: String, CaseIterable, Sendable {
        case desktopVocabularyPreferences

        public var path: String { metadata.path }
        public var root: String { metadata.root }
        public var provenance: String { metadata.provenance }

        private var metadata: DesktopNativeSourceMetadata {
            switch self {
            case .desktopVocabularyPreferences:
                return .init(path: "vocabulary.json", root: "desktopApplicationData",
                             provenance: "nativeVocabularyPreferences")
            }
        }
    }

    public struct Evidence: Equatable, Sendable {
        public let platform: Platform
        public let source: Source
        /// Nil is absence; any nonnil data, including empty or malformed bytes, is presence.
        public let rawBytes: Data?
        public var identity: String { "native-source/\(platform.rawValue)/\(source.path)" }
        public var isCompleteCategory: Bool { false }
        public var hasApplyOrBackupAuthority: Bool { false }
    }

    public struct Projection: Sendable {
        public let evidence: [Evidence]
        public let records: [DataMigrationRecord]
        public var scope: DataMigrationScope { .init(selectedIDs: Set(evidence.map(\.identity))) }
        public var selectedKinds: Set<String> { [DesktopNativeSourceDocumentCodec.recordKind] }
        public var isCompleteCategory: Bool { false }
        public var hasApplyOrBackupAuthority: Bool { false }
    }
}

private struct DesktopNativeSourceMetadata {
    let path: String
    let root: String
    let provenance: String
}
