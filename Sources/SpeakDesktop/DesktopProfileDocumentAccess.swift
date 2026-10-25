import Foundation
import SpeakCore

/// Coordinates profile stores used by one desktop host, including separate
/// editor, backup and restore store values. No suspension is allowed inside.
enum DesktopProfileDocumentAccess {
    private static let lock = NSRecursiveLock()

    static func withMutation<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

struct DesktopProfileRestoreTransaction: Sendable {
    let store: DesktopDictationProfileStore
    let expected: Data?
    let replacement: Data?
}

extension DesktopDictationProfileStore {
    private func restoreDocument(
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Data? {
        try DesktopOwnedAppDataFileReader.readStrict(
            Self.filename, appDirectory: fileURL.deletingLastPathComponent(),
            maximumBytes: DataMigrationArchivePolicy.maximumJSONBytes, checkCancellation: checkCancellation
        ).data
    }

    /// Holds the profile mutation boundary through History's synchronous
    /// admission, writes and rollback. Rechecks also preserve a nonparticipating
    /// writer's newer bytes if one is observed at a checkpoint.
    func withRestoreTransaction<Value>(
        expected: Data?, replacement: Data?,
        checkpoint: @Sendable (DesktopMigrationRestore.Step) throws -> Void,
        operation: ((Bool) throws -> Void) throws -> Value
    ) throws -> Value {
        try DesktopProfileDocumentAccess.withMutation {
            guard try restoreDocument() == expected else { throw DesktopMigrationRestore.StaleProfiles() }
            var written: Data?
            var writtenIdentity: DesktopRecordingAudioSnapshot.Identity?
            do {
                if let replacement {
                    try checkpoint(.profiles)
                    guard try restoreDocument() == expected else { throw DesktopMigrationRestore.StaleProfiles() }
                    try FileManager.default.createDirectory(
                        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try replacement.write(to: fileURL, options: .atomic)
                    written = replacement
                    writtenIdentity = try DesktopOwnedAppDataFileReader.strictSourceIdentity(fileURL)
                }
                let identity = try DesktopOwnedAppDataFileReader.strictSourceIdentity(fileURL)
                return try operation { verifyBytes in
                    // The host mutation lock is the write authority. Metadata
                    // checks catch outside changes between individual writes;
                    // recheck all bytes once at commit rather than rereading a
                    // potentially large profile document for every History row.
                    guard try DesktopOwnedAppDataFileReader.strictSourceIdentity(self.fileURL) == identity else {
                        throw DesktopMigrationRestore.StaleProfiles()
                    }
                    if verifyBytes, try self.restoreDocument() != (replacement ?? expected) {
                        throw DesktopMigrationRestore.StaleProfiles()
                    }
                }
            } catch {
                var failures = (error as? DesktopMigrationRestoreWriteError)?.rollbackFailures ?? []
                let underlying = (error as? DesktopMigrationRestoreWriteError)?.underlying ?? error
                if let written {
                    do {
                        guard try DesktopOwnedAppDataFileReader.strictSourceIdentity(fileURL) == writtenIdentity,
                              try restoreDocument(checkCancellation: {}) == written else {
                            throw DataMigrationError.invalid("newer profiles were preserved")
                        }
                        if let expected {
                            try expected.write(to: fileURL, options: .atomic)
                        } else {
                            try FileManager.default.removeItem(at: fileURL)
                        }
                    } catch {
                        failures.append("app profiles (\(error.localizedDescription))")
                    }
                }
                throw DesktopMigrationRestoreWriteError(underlying: underlying, rollbackFailures: failures)
            }
        }
    }
}
