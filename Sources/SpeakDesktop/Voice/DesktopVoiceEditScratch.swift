import CRecordingFileSupport
import Foundation

/// The caller prepares a private app-owned directory before opening it.
/// The native lease excludes other owners, including other instances in this
/// process. Retain it until every recording/provider worker has really ended.
/// Cleanup never recursively removes a directory or accepts arbitrary names.
public final class DesktopVoiceEditScratch: @unchecked Sendable {
    public let directory: URL
    private let owner: OpaquePointer

    public init(preparedDirectory: URL) throws {
        guard preparedDirectory.isFileURL, !preparedDirectory.path.utf8.contains(0),
              preparedDirectory.host?.isEmpty != false,
              preparedDirectory.query == nil, preparedDirectory.fragment == nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var owner: OpaquePointer?
        let status = try preparedDirectory.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
            return jsti_scratch_open(path, &owner)
        }
        try Self.check(status)
        guard let owner else { throw CocoaError(.fileWriteUnknown) }
        self.owner = owner
        directory = preparedDirectory
        try removeAbandonedRuns()
    }

    deinit {
        let status = jsti_scratch_close(owner)
        if status != 0 {
            FileHandle.standardError.write(Data("Private voice-edit ownership release failed (\(status)).\n".utf8))
        }
    }

    public func createRun(_ id: UUID) throws -> URL {
        try Self.check(id.uuidString.withCString { jsti_scratch_create(owner, $0) })
        return directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func removeRun(_ id: UUID) throws {
        try Self.check(id.uuidString.withCString { jsti_scratch_remove(owner, $0) })
    }

    private func removeAbandonedRuns() throws {
        for entry in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  id.uuidString == entry.lastPathComponent else { continue }
            try removeRun(id)
        }
    }

    private static func check(_ status: UInt32) throws {
        guard status == 0 else {
            throw NSError(domain: "JSTIVoiceEditScratch", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey:
                    "Private voice-edit audio ownership or cleanup was refused (native error \(status))."
            ])
        }
    }
}
