import Foundation
import SpeakCore

public enum DesktopMigrationBackup {
    public struct Selection: Equatable, Sendable {
        public let includeAudio: Bool
        public let includeProfiles: Bool

        public init(includeAudio: Bool, includeProfiles: Bool = false) {
            self.includeAudio = includeAudio
            self.includeProfiles = includeProfiles
        }

        public init(nativeFlags: Int) throws {
            guard (0...3).contains(nativeFlags) else {
                throw DataMigrationError.invalid("The backup category selection is invalid.")
            }
            self.init(includeAudio: nativeFlags & 1 != 0, includeProfiles: nativeFlags & 2 != 0)
        }

        public var description: String {
            if includeProfiles {
                return includeAudio ? "History, recording audio and app profiles" : "History text and app profiles"
            }
            return includeAudio ? "History and recording audio" : "History text"
        }
    }

    public struct Adapter: Sendable {
        let digests: LocalModelDigestProvider
        let archive: @Sendable (DataMigrationSnapshot) throws -> URL
        let publish: @Sendable (URL, URL) throws -> Void

        /// `archive` returns export.zip in a new, exclusively owned private
        /// migration-export-<UUID> directory belonging only to this operation.
        public init(
            digests: LocalModelDigestProvider,
            archive: @escaping @Sendable (DataMigrationSnapshot) throws -> URL,
            publish: @escaping @Sendable (URL, URL) throws -> Void
        ) {
            self.digests = digests
            self.archive = archive
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
