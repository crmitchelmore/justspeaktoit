import Foundation
import SpeakCore

enum DesktopMigrationStaging {
    static func requireLocalFile(_ file: URL) throws {
        guard file.isFileURL, file.host == nil || file.host == "" || file.host == "localhost",
              !file.path.contains("\0"), !file.absoluteString.lowercased().contains("%00") else {
            throw DataMigrationError.invalid("Migration requires a local file URL without NUL characters.")
        }
    }

    /// The trusted producer must exclusively create and protect this directory.
    /// Its naming contract alone never establishes ownership of arbitrary input.
    static func directory(_ directory: URL, prefix: String) throws -> URL {
        try requireLocalFile(directory)
        let name = directory.lastPathComponent
        guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else {
            throw DataMigrationError.invalid("The archive producer returned an invalid owned staging path.")
        }
        return directory
    }
}
