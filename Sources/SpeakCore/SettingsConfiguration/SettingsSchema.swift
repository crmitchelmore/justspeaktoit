import Foundation

/// The JSON shape a raw configuration value takes.
public enum SettingsValueKind: String, Codable, CaseIterable, Sendable {
    case boolean
    case integer
    case number
    case string
    /// A string, or `null` for "not set".
    case optionalString
    case stringArray
    /// An object whose values are all strings.
    case stringMap
    /// A string drawn from `allowedValues`.
    case enumeration
    /// A structured value the raw editor shows but never writes.
    case object
}

/// The shared catalogue a model identifier must come from.
public enum SettingsModelCatalogue: String, Codable, CaseIterable, Sendable {
    case liveTranscription
    case batchTranscription
    case localTranscription
    case postProcessing
    /// A post-processing model, or an empty string for "use the default".
    case livePolish
}

/// One persisted setting in the raw configuration: its key, value type, default,
/// constraints and where it applies.
///
/// `key` is the settings-model property name, the same name
/// `SettingsSearchEntry.settingKeys` lists, so the search catalogue and the raw
/// configuration describe one set of settings.
public struct SettingsSchemaField: Hashable, Sendable {
    public let key: String
    public let kind: SettingsValueKind
    public let summary: String
    /// The value a fresh install has, or nil when it depends on the device (for
    /// example the recordings folder or the preferred speech engine).
    public let defaultValue: AnyCodable.JSONValue?
    public let allowedValues: [String]?
    public let range: ClosedRange<Double>?
    public let modelCatalogue: SettingsModelCatalogue?
    /// Shown by the raw editor and automation, but only changeable in the app's
    /// own Settings, because it grants access, records consent or needs a picker.
    public let isReadOnly: Bool
    /// Whether the value is a secret. Secrets are never exported; the schema
    /// keeps the flag so a future secret-bearing field cannot slip in unnoticed.
    public let isSensitive: Bool

    public init(
        key: String,
        kind: SettingsValueKind,
        summary: String,
        defaultValue: AnyCodable.JSONValue?,
        allowedValues: [String]? = nil,
        range: ClosedRange<Double>? = nil,
        modelCatalogue: SettingsModelCatalogue? = nil,
        isReadOnly: Bool = false,
        isSensitive: Bool = false
    ) {
        self.key = key
        self.kind = kind
        self.summary = summary
        self.defaultValue = defaultValue
        self.allowedValues = allowedValues
        self.range = range
        self.modelCatalogue = modelCatalogue
        self.isReadOnly = isReadOnly
        self.isSensitive = isSensitive
    }

    /// The hosts whose settings UI shows this setting, from the search catalogue.
    public var platforms: SettingsSearchPlatforms {
        SettingsSchema.platforms(forKey: self.key)
    }

    /// The field as automation and the raw editor describe it.
    public var schemaDescription: AnyCodable.JSONValue {
        var info: [String: AnyCodable.JSONValue] = [
            "type": .string(self.kind.rawValue),
            "description": .string(self.summary),
            "platforms": .array(SettingsSchema.platformNames(self.platforms).map { .string($0) }),
            "readOnly": .bool(self.isReadOnly),
            "sensitive": .bool(self.isSensitive)
        ]
        if let defaultValue { info["default"] = defaultValue }
        if let allowedValues { info["allowedValues"] = .array(allowedValues.map { .string($0) }) }
        if let range {
            info["minimum"] = .double(range.lowerBound)
            info["maximum"] = .double(range.upperBound)
        }
        if let modelCatalogue { info["modelCatalogue"] = .string(modelCatalogue.rawValue) }
        return .object(info)
    }
}

/// The versioned raw-configuration schema.
///
/// One definition, in SpeakCore, describes every persisted setting a host's raw
/// editor and the `get_configuration`/`set_configuration` automation tools read
/// and write. Hosts bind these keys to their own settings model and prove, with
/// coverage tests, that every persisted setting has an entry here.
public enum SettingsSchema {
    /// Bumped when a document written by this version could be misread by an
    /// older one. Newer documents are refused rather than half-applied.
    public static let version = 1

    public static let fields: [SettingsSchemaField] = macOSFields

    private static let fieldsByKey: [String: SettingsSchemaField] = Dictionary(
        fields.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }
    )

    public static func field(forKey key: String) -> SettingsSchemaField? {
        fieldsByKey[key]
    }

    public static var keys: [String] { fields.map(\.key) }

    /// Setting keys the search catalogue lists for any host. A key here without a
    /// schema field belongs to another platform's settings model; documents keep
    /// it so a configuration moved between platforms loses nothing.
    public static let catalogueKeys: Set<String> = Set(SettingsSearchCatalog.entries.flatMap(\.settingKeys))

    /// The hosts that show `key`, from every search entry listing it. Keys the
    /// catalogue does not list default to the Mac, the only host that implements
    /// this schema so far.
    public static func platforms(forKey key: String) -> SettingsSearchPlatforms {
        let platforms = SettingsSearchCatalog.entries
            .filter { $0.settingKeys.contains(key) }
            .reduce(into: SettingsSearchPlatforms()) { $0.formUnion($1.platforms) }
        return platforms.isEmpty ? .macOS : platforms
    }

    public static func platformNames(_ platforms: SettingsSearchPlatforms) -> [String] {
        let names: [(SettingsSearchPlatforms, String)] = [
            (.macOS, "macOS"), (.iOS, "iOS"), (.windows, "windows"), (.linux, "linux"), (.android, "android")
        ]
        return names.filter { platforms.contains($0.0) }.map(\.1)
    }

    /// Fields as automation describes them, keyed by setting.
    public static func describe(keys: [String]? = nil) -> [String: AnyCodable.JSONValue] {
        let selected = keys.map { Set($0) }
        return fields.reduce(into: [:]) { result, field in
            guard selected?.contains(field.key) ?? true else { return }
            result[field.key] = field.schemaDescription
        }
    }
}
