import Foundation
import SpeakCore

public enum DesktopMigrationBackup {
    /// Native flags: 1 audio, 2 app profiles, 4 settings, vocabulary, connections
    /// and model references, 8 API keys (an explicit opt-in).
    public struct Selection: Equatable, Sendable {
        public let includeAudio: Bool
        public let includeProfiles: Bool
        public let includeConfiguration: Bool
        public let includeCredentials: Bool

        public init(
            includeAudio: Bool, includeProfiles: Bool = false, includeConfiguration: Bool = false,
            includeCredentials: Bool = false
        ) {
            self.includeAudio = includeAudio
            self.includeProfiles = includeProfiles
            self.includeConfiguration = includeConfiguration
            self.includeCredentials = includeCredentials
        }

        public init(nativeFlags: Int) throws {
            guard (0...15).contains(nativeFlags) else {
                throw DataMigrationError.invalid("The backup category selection is invalid.")
            }
            self.init(
                includeAudio: nativeFlags & 1 != 0, includeProfiles: nativeFlags & 2 != 0,
                includeConfiguration: nativeFlags & 4 != 0, includeCredentials: nativeFlags & 8 != 0
            )
        }

        public var description: String {
            var parts = includeAudio ? ["History", "recording audio"] : ["History text"]
            if includeProfiles { parts.append("app profiles") }
            if includeConfiguration { parts.append(contentsOf: ["settings", "vocabulary"]) }
            if includeCredentials { parts.append("API keys") }
            guard let last = parts.popLast() else { return "" }
            return parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last
        }
    }

    /// Host-owned parts of a full backup. Records are already projected to the
    /// shared format; vocabulary and API keys are read on the export worker.
    /// What one backup holds besides History.
    public struct Contents: Sendable {
        let includeAudio: Bool
        let profiles: DesktopDictationProfileStore?
        let configuration: Configuration?

        public init(includeAudio: Bool, profiles: DesktopDictationProfileStore?, configuration: Configuration? = nil) {
            self.includeAudio = includeAudio
            self.profiles = profiles
            self.configuration = configuration
        }
    }

    public struct Configuration: Sendable {
        let records: [DataMigrationCategory: [DataMigrationRecord]]
        let notices: [String]
        let vocabularyDirectory: URL?
        let credentials: (@Sendable () throws -> [DataMigrationRecord])?

        public init(
            records: [DataMigrationCategory: [DataMigrationRecord]], notices: [String] = [],
            vocabularyDirectory: URL? = nil, credentials: (@Sendable () throws -> [DataMigrationRecord])? = nil
        ) {
            self.records = records
            self.notices = notices
            self.vocabularyDirectory = vocabularyDirectory
            self.credentials = credentials
        }
    }

    public struct Adapter: Sendable {
        let digests: LocalModelDigestProvider
        let archive: @Sendable (DataMigrationSnapshot, Bool) throws -> URL
        let publish: @Sendable (URL, URL) throws -> Void

        /// `archive` returns export.zip in a new, exclusively owned private
        /// migration-export-<UUID> directory belonging only to this operation.
        /// This producer cannot write API keys.
        public init(
            digests: LocalModelDigestProvider,
            archive: @escaping @Sendable (DataMigrationSnapshot) throws -> URL,
            publish: @escaping @Sendable (URL, URL) throws -> Void
        ) {
            self.init(digests: digests, archiveWithCredentials: { snapshot, includeCredentials in
                guard !includeCredentials else {
                    throw DataMigrationError.invalid("This backup producer cannot include API keys.")
                }
                return try archive(snapshot)
            }, publish: publish)
        }

        /// The Bool is the explicit API-key opt-in the archive writer must enforce.
        public init(
            digests: LocalModelDigestProvider,
            archiveWithCredentials: @escaping @Sendable (DataMigrationSnapshot, Bool) throws -> URL,
            publish: @escaping @Sendable (URL, URL) throws -> Void
        ) {
            self.digests = digests
            self.archive = archiveWithCredentials
            self.publish = publish
        }
    }

    public enum Outcome: Equatable, Sendable {
        case saved
        case savedWithWarning(String)
        case cancelled
        case failed(String)

        func addingCleanupFailure(_ message: String) -> Self {
            let cleanup = "Private backup staging could not be removed: \(message)"
            switch self {
            case .saved: return .savedWithWarning(cleanup)
            case let .savedWithWarning(warning): return .savedWithWarning(warning + " " + cleanup)
            case .cancelled: return .failed("Backup cancelled. " + cleanup)
            case let .failed(failure): return .failed(failure + " " + cleanup)
            }
        }
    }
}
