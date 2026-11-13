import Foundation
import SpeakCore

/// The portable preferences file Export writes and Import reads: version 1,
/// at most `maximumBytes`, and never keys, device paths or native hotkeys.
package struct DesktopConfigurationDocument: Codable {
    package static let maximumBytes = 1_048_576
    package var version = 1
    package let preferences: DesktopConfiguration

    /// Reads a regular file of at most `maximumBytes`, refusing a file that
    /// grows past the limit while it is read or has another version.
    static func read(from path: String) throws -> DesktopConfigurationDocument {
        let source = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
            throw DesktopConfigurationError.tooLarge
        }
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try file.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw DesktopConfigurationError.tooLarge }
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: data)
        guard document.version == 1 else { throw DesktopConfigurationError.unsupportedVersion }
        return document
    }

    /// Writes the document atomically as sorted, readable JSON.
    func write(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw DesktopConfigurationError.tooLarge }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
