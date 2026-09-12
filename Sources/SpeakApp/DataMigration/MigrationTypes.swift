import CryptoKit
import Foundation
import SpeakCore

enum MigrationCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case settings, history, recordings, credentials, profiles, vocabulary, connections, models
    var id: String { rawValue }
    var title: String {
        switch self {
        case .settings: return "Settings & shortcuts"
        case .history: return "History text & speech usage"
        case .recordings: return "Recordings"
        case .credentials: return "API keys & credentials"
        case .profiles: return "Dictation profiles"
        case .vocabulary: return "Vocabulary, pronunciation & corrections"
        case .connections: return "Connections"
        case .models: return "Model references"
        }
    }
    static var defaults: Set<Self> { Set(allCases).subtracting([.credentials]) }
}

enum MigrationMode: String, CaseIterable, Identifiable, Sendable {
    case skip, merge, replace
    var id: String { rawValue }
}

struct MigrationScope: Codable, Equatable, Sendable {
    var start: Date?
    var end: Date?
    var selectedIDs: Set<String>?
    func contains(id: String, date: Date?) -> Bool {
        if let selectedIDs, !selectedIDs.contains(id) {
            return false
        }
        if let start, date == nil || date! < start {
            return false
        }
        if let end, date == nil || date! >= end {
            return false
        }
        return true
    }
    var isComplete: Bool { start == nil && end == nil && selectedIDs == nil }
}

struct MigrationRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String
    var value: AnyCodable
    var date: Date?
    var file: String?
    var digest: String?
    var revision: String?
    var identity: String { kind + ":" + id }
}

struct MigrationManifest: Codable, Sendable {
    var format = "JustSpeakToIt"
    var version = 1
    var createdAt = Date()
    var categories: [MigrationCategory]
    var scopes: [String: MigrationScope]
}

struct MigrationSnapshot: Sendable {
    var manifest: MigrationManifest
    var records: [MigrationCategory: [MigrationRecord]]
    var files: [String: URL] = [:]
    var notices: [String] = []
    var directory: URL?
}

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

enum MigrationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
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
