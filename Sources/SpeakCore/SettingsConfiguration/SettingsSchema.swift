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

/// A host that implements the raw configuration. The raw value is the
/// document's `platform` and the name automation reports.
public enum SettingsSchemaPlatform: String, CaseIterable, Codable, Sendable {
    case macOS
    case iOS
    case windows
    case linux
    case android

    public var searchPlatform: SettingsSearchPlatforms {
        switch self {
        case .macOS: return .macOS
        case .iOS: return .iOS
        case .windows: return .windows
        case .linux: return .linux
        case .android: return .android
        }
    }

    /// Windows and Linux share one settings model, so documents move between
    /// them without a cross-platform warning.
    public func sharesSettings(with other: SettingsSchemaPlatform) -> Bool {
        self == other || (self.isDesktop && other.isDesktop)
    }

    var isDesktop: Bool { self == .windows || self == .linux }
}

/// The versioned raw-configuration schema.
///
/// One definition, in SpeakCore, describes every persisted setting a host's raw
/// editor and the `get_configuration`/`set_configuration` automation tools read
/// and write. Each platform has its own field list over the shared keys; hosts
/// bind those keys to their own settings model and prove, with coverage tests,
/// that every persisted setting has an entry here.
public enum SettingsSchema {
    /// Bumped when a document written by this version could be misread by an
    /// older one. Newer documents are refused rather than half-applied.
    public static let version = 1

    /// The Mac's fields; see `fields(for:)` for other platforms.
    public static let fields: [SettingsSchemaField] = macOSFields

    public static func fields(for platform: SettingsSchemaPlatform) -> [SettingsSchemaField] {
        switch platform {
        case .macOS: return macOSFields
        case .windows, .linux: return desktopFields
        case .iOS: return iOSFields
        case .android: return androidFields
        }
    }

    private static let fieldsByPlatform: [SettingsSchemaPlatform: [String: SettingsSchemaField]] = Dictionary(
        uniqueKeysWithValues: SettingsSchemaPlatform.allCases.map { platform in
            (platform, Dictionary(fields(for: platform).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }))
        }
    )

    public static func field(forKey key: String) -> SettingsSchemaField? {
        field(forKey: key, platform: .macOS)
    }

    public static func field(forKey key: String, platform: SettingsSchemaPlatform) -> SettingsSchemaField? {
        fieldsByPlatform[platform]?[key]
    }

    public static var keys: [String] { fields.map(\.key) }

    public static func keys(for platform: SettingsSchemaPlatform) -> [String] {
        fields(for: platform).map(\.key)
    }

    /// Setting keys the search catalogue lists for any host. A key here without a
    /// schema field belongs to another platform's settings model; documents keep
    /// it so a configuration moved between platforms loses nothing.
    public static let catalogueKeys: Set<String> = Set(SettingsSearchCatalog.entries.flatMap(\.settingKeys))

    /// Every key some platform's settings model owns: the search catalogue's
    /// keys plus each platform's schema. A document key outside this set is a typo.
    public static let knownKeys: Set<String> = catalogueKeys.union(
        SettingsSchemaPlatform.allCases.flatMap { keys(for: $0) }
    )

    /// The hosts that show `key`: every search entry listing it, plus every
    /// platform whose schema has it. Keys neither lists default to the Mac.
    public static func platforms(forKey key: String) -> SettingsSearchPlatforms {
        var platforms = SettingsSearchCatalog.entries
            .filter { $0.settingKeys.contains(key) }
            .reduce(into: SettingsSearchPlatforms()) { $0.formUnion($1.platforms) }
        for platform in SettingsSchemaPlatform.allCases where fieldsByPlatform[platform]?[key] != nil {
            platforms.formUnion(platform.searchPlatform)
        }
        return platforms.isEmpty ? .macOS : platforms
    }

    public static func platformNames(_ platforms: SettingsSearchPlatforms) -> [String] {
        SettingsSchemaPlatform.allCases.filter { platforms.contains($0.searchPlatform) }.map(\.rawValue)
    }

    /// Fields as automation describes them, keyed by setting.
    public static func describe(keys: [String]? = nil) -> [String: AnyCodable.JSONValue] {
        describe(keys: keys, platform: .macOS)
    }

    public static func describe(keys: [String]?, platform: SettingsSchemaPlatform) -> [String: AnyCodable.JSONValue] {
        let selected = keys.map { Set($0) }
        return fields(for: platform).reduce(into: [:]) { result, field in
            guard selected?.contains(field.key) ?? true else { return }
            result[field.key] = field.schemaDescription
        }
    }
}
