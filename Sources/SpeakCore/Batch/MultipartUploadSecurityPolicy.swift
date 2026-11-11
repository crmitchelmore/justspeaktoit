import Foundation

extension SharedMultipartUploadStaging {
    /// A platform adapter must secure the directory before any scan or write,
    /// and create an empty private file or throw. Windows supplies native ACL
    /// enforcement; it deliberately has no POSIX or unprotected default.
    public struct SecurityPolicy: Sendable {
        let prepareDirectory: @Sendable (URL, FileManager) throws -> Void
        let createFile: @Sendable (URL, FileManager) throws -> Bool

        public init(
            prepareDirectory: @escaping @Sendable (URL, FileManager) throws -> Void,
            createFile: @escaping @Sendable (URL, FileManager) throws -> Bool
        ) {
            self.prepareDirectory = prepareDirectory
            self.createFile = createFile
        }

        #if !os(Windows)
        /// Retains the established 0700 directory / 0600 file policy, including
        /// repairing loose permissions on an existing staging directory.
        public static let posix = SecurityPolicy(
            prepareDirectory: { directory, manager in
                try manager.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            },
            createFile: { url, manager in
                manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
        )
        #endif
    }

    public enum Event: Sendable {
        case purged(filename: String)
        case removalFailed(filename: String, message: String)
        case directoryPreparationFailed(message: String)
    }
}
