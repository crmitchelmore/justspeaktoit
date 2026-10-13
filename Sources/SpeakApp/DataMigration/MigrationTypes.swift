import CryptoKit
import Foundation
import SpeakCore

typealias MigrationCategory = DataMigrationCategory
typealias MigrationMode = DataMigrationMode
typealias MigrationScope = DataMigrationScope
typealias MigrationRecord = DataMigrationRecord
typealias MigrationManifest = DataMigrationManifest
typealias MigrationSnapshot = DataMigrationSnapshot
typealias MigrationError = DataMigrationError

struct MigrationConflict: Identifiable {
    let category: MigrationCategory
    let existing: MigrationRecord
    let imported: MigrationRecord
    var id: String { category.rawValue + ":" + imported.identity }
    var title: String { imported.id }
    func summary(_ record: MigrationRecord) -> String {
        if category == .credentials {
            return "Saved credential (hidden)"
        }
        return String((String(data: (try? MigrationCoding.encoder.encode(record.value)) ?? Data(),
                              encoding: .utf8) ?? "Value").prefix(350))
    }
}

enum MigrationCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    static func value<T: Encodable>(_ item: T) throws -> AnyCodable {
        try decoder.decode(AnyCodable.self, from: encoder.encode(item))
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: AnyCodable) throws -> T {
        try decoder.decode(type, from: encoder.encode(value))
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func variantID(id: String, revision: String) -> String {
        let hex = digest(Data((id + ":" + revision).utf8))
        let chars = Array(hex.prefix(32))
        return [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]),
                String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-").uppercased()
    }
}
