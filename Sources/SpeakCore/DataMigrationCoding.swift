import Foundation

public enum DataMigrationCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func value<T: Encodable>(_ item: T) throws -> AnyCodable {
        try decoder.decode(AnyCodable.self, from: encoder.encode(item))
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ value: AnyCodable) throws -> T {
        try decoder.decode(type, from: encoder.encode(value))
    }
}
