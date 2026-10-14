import Foundation
import SpeakCore

public enum DesktopMigrationBackup {
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
