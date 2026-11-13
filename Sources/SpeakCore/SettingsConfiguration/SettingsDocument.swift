import Foundation

/// One problem with a raw configuration, at a JSON path such as
/// `settings.ttsSpeed`.
public struct SettingsIssue: Codable, Hashable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String {
        self.path.isEmpty ? self.message : "\(self.path): \(self.message)"
    }
}

/// A raw configuration that could not be read; every issue found is listed.
public struct SettingsDocumentError: Error, Equatable, Sendable {
    public let issues: [SettingsIssue]

    public init(issues: [SettingsIssue]) {
        self.issues = issues
    }
}

/// The versioned raw-configuration document:
///
/// ```json
/// {"schemaVersion": 1, "platform": "macOS",
///  "settings": {"ttsSpeed": 1.2}, "apiKeys": {"openai": {"isSet": true}}}
/// ```
///
/// `settings` may hold any subset of keys; a missing key means "unchanged".
/// `apiKeys` only ever reports whether a credential is stored. Secrets are never
/// written, and the section is ignored when a document is applied.
public struct SettingsDocument: Equatable, Sendable {
    public typealias JSONValue = AnyCodable.JSONValue

    public static let topLevelKeys: Set<String> = ["schemaVersion", "platform", "settings", "apiKeys"]

    public var schemaVersion: Int
    public var platform: String?
    public var settings: [String: JSONValue]
    /// Credential identifier to whether it is stored.
    public var apiKeys: [String: Bool]

    public init(
        schemaVersion: Int = SettingsSchema.version,
        platform: String? = "macOS",
        settings: [String: JSONValue],
        apiKeys: [String: Bool] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.platform = platform
        self.settings = settings
        self.apiKeys = apiKeys
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "schemaVersion": .int(self.schemaVersion),
            "settings": .object(self.settings),
            "apiKeys": .object(self.apiKeys.mapValues { .object(["isSet": .bool($0)]) })
        ]
        if let platform { object["platform"] = .string(platform) }
        return .object(object)
    }

    /// Pretty-printed JSON with sorted keys, so exports diff cleanly.
    public func encodedJSON() throws -> Data {
        try Self.encode(self.jsonValue)
    }

    public static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(AnyCodable(value))
    }

    /// Reads a document, reporting every structural problem at once. Setting
    /// values are not checked here; `SettingsValidator` does that.
    public static func parse(_ data: Data) -> Result<SettingsDocument, SettingsDocumentError> {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(AnyCodable.self, from: data).storage
        } catch {
            return .failure(.init(issues: [.init(path: "", message: "Not valid JSON: \(Self.reason(error))")]))
        }
        return self.parse(root)
    }

    public static func parse(_ root: JSONValue) -> Result<SettingsDocument, SettingsDocumentError> {
        guard case .object(let object) = root else {
            return .failure(.init(issues: [.init(path: "", message: "Expected a JSON object.")]))
        }
        var issues: [SettingsIssue] = []
        for key in object.keys.sorted() where !Self.topLevelKeys.contains(key) {
            issues.append(.init(path: key, message: "Unknown top-level key."))
        }

        var version = SettingsSchema.version
        switch object["schemaVersion"] {
        case .int(let value)?:
            version = value
            if value > SettingsSchema.version {
                issues.append(.init(
                    path: "schemaVersion",
                    message: "Version \(value) is newer than this app supports (\(SettingsSchema.version)). "
                        + "Update the app first."))
            } else if value < 1 {
                issues.append(.init(path: "schemaVersion", message: "Must be 1 or later."))
            }
        case nil:
            issues.append(.init(path: "schemaVersion", message: "Required."))
        default:
            issues.append(.init(path: "schemaVersion", message: "Expected an integer."))
        }

        var platform: String?
        switch object["platform"] {
        case .string(let value)?: platform = value
        case nil, .null?: platform = nil
        default: issues.append(.init(path: "platform", message: "Expected a string."))
        }

        var settings: [String: JSONValue] = [:]
        switch object["settings"] {
        case .object(let value)?: settings = value
        case nil: break
        default: issues.append(.init(path: "settings", message: "Expected an object."))
        }

        var apiKeys: [String: Bool] = [:]
        switch object["apiKeys"] {
        case .object(let value)?:
            for (id, entry) in value {
                if case .object(let fields) = entry, fields.count == 1, case .bool(let isSet)? = fields["isSet"] {
                    apiKeys[id] = isSet
                } else {
                    issues.append(.init(
                        path: "apiKeys.\(id)",
                        message: "Only {\"isSet\": true|false} is allowed; secrets are never imported."))
                }
            }
        case nil: break
        default: issues.append(.init(path: "apiKeys", message: "Expected an object."))
        }

        guard issues.isEmpty else { return .failure(.init(issues: issues)) }
        return .success(.init(schemaVersion: version, platform: platform, settings: settings, apiKeys: apiKeys))
    }

    /// The document narrowed to `keys` and/or settings starting with `prefix`.
    public func filtered(keys: [String]?, prefix: String?) -> SettingsDocument {
        var copy = self
        copy.settings = Self.filter(self.settings, keys: keys, prefix: prefix)
        return copy
    }

    public static func filter<Value>(_ values: [String: Value], keys: [String]?, prefix: String?) -> [String: Value] {
        let wanted = keys.map(Set.init)
        return values.filter { key, _ in
            (wanted?.contains(key) ?? true) && (prefix.map { key.hasPrefix($0) } ?? true)
        }
    }

    private static func reason(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let context) = error {
            let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return underlying ?? context.debugDescription
        }
        return String(describing: error)
    }
}
