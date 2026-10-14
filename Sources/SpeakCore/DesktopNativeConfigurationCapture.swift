/// Pure, explicitly selected source data. No Codable/archive carrier or retention claim is provided.
public struct DesktopNativeConfigurationCapture: Sendable, Equatable {
    public enum Platform: String, Sendable { case windows, linux }
    public enum Provenance: String, Sendable { case nativeSettings, legacyConfiguration }

    public struct Entry: Sendable, Equatable {
        public let field: DesktopNativeConfigurationField
        public let platform: Platform
        public let provenance: Provenance
        public let value: AnyCodable?
        public var sourcePath: String { field.rawValue }
        public var isPresent: Bool { value != nil }
    }

    public let entries: [Entry]
    public let unresolvedPaths: [String]
    public let platform: Platform

    public static func capture(
        _ sources: [String: AnyCodable], platform: Platform, selectedFields: Set<String> = []
    ) throws -> Self {
        let fields = try selectedFields.sorted().map { path in
            guard let field = DesktopNativeConfigurationField(rawValue: path) else {
                throw DataMigrationError.invalid("Unclassified native configuration capture selection: \(path).")
            }
            return field
        }
        let entries = try fields.map { field in
            let value = sources[field.rawValue]
            if let value { try field.validate(value, platform: platform) }
            return Entry(field: field, platform: platform, provenance: field.provenance, value: value)
        }
        let unresolved = sources.keys.sorted().filter {
            DesktopNativeConfigurationField(rawValue: $0) == nil || !selectedFields.contains($0)
        }
        return Self(entries: entries, unresolvedPaths: unresolved, platform: platform)
    }
}
