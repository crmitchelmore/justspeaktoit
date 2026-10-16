import Foundation
import SpeakCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension DesktopMigrationArchive {
    /// Hosts create a private, exclusively owned leaf before any bytes are
    /// written. Creation failures must not leave owned staging behind.
    public struct Storage: Sendable {
        let createDirectory: @Sendable (URL) throws -> Void
        let createFile: @Sendable (URL) throws -> Void

        public init(
            createDirectory: @escaping @Sendable (URL) throws -> Void,
            createFile: @escaping @Sendable (URL) throws -> Void
        ) {
            self.createDirectory = createDirectory
            self.createFile = createFile
        }

        static func resolve(_ supplied: Storage?) throws -> Storage {
            if let supplied { return supplied }
            #if os(Windows)
            throw DataMigrationError.invalid("Migration staging requires the native Windows file-security adapter.")
            #else
            return Storage(
                createDirectory: {
                    guard $0.path.withCString({ mkdir($0, 0o700) }) == 0 else {
                        let code = errno
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                                      userInfo: [NSFilePathErrorKey: $0.path])
                    }
                },
                createFile: {
                    try Data().write(to: $0, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: $0.path)
                }
            )
            #endif
        }
    }
}
