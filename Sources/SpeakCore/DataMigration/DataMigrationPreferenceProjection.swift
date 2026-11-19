import Foundation

/// A partial preference projection, not a complete backup or a capability declaration.
public struct DataMigrationPreferenceProjection: Sendable {
    public enum Reason: Equatable, Sendable {
        case retainedValue, unknownPreference, excludedPreference, nativeOnly, shadowed, requiresJSONValidator
    }

    public struct Notice: Equatable, Sendable {
        public let path: String
        public let reason: Reason

        public init(path: String, reason: Reason) {
            self.path = path
            self.reason = reason
        }
    }

    public let records: [DataMigrationCategory: [DataMigrationRecord]]
    public var notices: [Notice]

    public static func project(
        _ values: [String: AnyCodable], categories: Set<DataMigrationCategory>,
        authoritativeKeys: Set<String> = [],
        validateJSON: ((DataMigrationRecord) throws -> Void)? = nil
    ) throws -> Self {
        let allowed: Set<DataMigrationCategory> = [.settings, .vocabulary, .connections]
        guard categories.isSubset(of: allowed) else {
            throw DataMigrationError.invalid("Preference projection accepts only settings, vocabulary and connections.")
        }
        var records = Dictionary(uniqueKeysWithValues: categories.map { ($0, [DataMigrationRecord]()) })
        var notices: [Notice] = []
        for key in values.keys.sorted() {
            guard let definition = DataMigrationPreferenceCatalog.definition(for: key) else {
                let excluded = ApplicationPreferenceKey(rawValue: key) != nil
                notices.append(.init(path: "configuration.\(key)",
                                     reason: excluded ? .excludedPreference : .unknownPreference))
                continue
            }
            guard allowed.contains(definition.category) else {
                notices.append(.init(path: "configuration.\(key)", reason: .excludedPreference))
                continue
            }
            guard categories.contains(definition.category), let value = values[key] else { continue }
            let record = DataMigrationRecord(id: key, kind: definition.recordKind, value: value)
            if try requiresValidator(record, definition: definition, validateJSON: validateJSON) {
                notices.append(.init(path: "configuration.\(key)", reason: .requiresJSONValidator))
                continue
            }
            try DataMigrationPreferenceCatalog.validate(record, category: definition.category) { record in
                if record.id == ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue {
                    _ = try DataMigrationCoding.decode([String: String].self, record.value)
                } else if let validateJSON {
                    try validateJSON(record)
                } else {
                    throw DataMigrationError.invalid("A typed JSON preference validator is required.")
                }
            }
            records[definition.category, default: []].append(record)
            if !authoritativeKeys.contains(key) {
                notices.append(.init(path: "configuration.\(key)", reason: .retainedValue))
            }
        }
        return Self(records: records, notices: notices)
    }

    private static func requiresValidator(
        _ record: DataMigrationRecord, definition: DataMigrationPreferenceCatalog.Definition,
        validateJSON: ((DataMigrationRecord) throws -> Void)?
    ) throws -> Bool {
        guard definition.kind == .json else { return false }
        switch record.value.storage {
        case .object, .array: break
        default: throw DataMigrationError.invalid("A structured JSON preference is required for \(record.id).")
        }
        return record.id != ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue && validateJSON == nil
    }
}
