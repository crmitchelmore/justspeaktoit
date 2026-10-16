import Foundation
import SpeakCore
import SpeakHotKeys

@MainActor
enum MigrationPreferenceSchema {
    static var booleans: Set<String> { DataMigrationPreferenceCatalog.keys(ofKind: .boolean) }
    static var numbers: Set<String> { DataMigrationPreferenceCatalog.keys(ofKind: .number) }
    static var arrays: Set<String> { DataMigrationPreferenceCatalog.keys(ofKind: .stringArray) }
    static var json: Set<String> { DataMigrationPreferenceCatalog.keys(ofKind: .json) }

    static func validate(_ record: MigrationRecord) throws {
        guard let category = DataMigrationPreferenceCatalog.category(for: record.id) else {
            throw MigrationError.invalid("Unknown setting")
        }
        try DataMigrationPreferenceCatalog.validate(record, category: category, validateJSON: validateJSON)
    }

    private static func validateJSON(_ record: MigrationRecord) throws {
        switch record.id {
        case ApplicationPreferenceKey.selectedHotKey.rawValue:
            _ = try MigrationCoding.decode(HotKey.self, record.value)
        case "customShortcutBindings":
            _ = try MigrationCoding.decode([ShortcutAction: KeyBinding].self, record.value)
        case ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue:
            _ = try MigrationCoding.decode([String: String].self, record.value)
        default:
            throw MigrationError.invalid("Unknown JSON setting")
        }
    }
}
