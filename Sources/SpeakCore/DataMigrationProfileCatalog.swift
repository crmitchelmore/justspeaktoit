import Foundation

public enum DataMigrationProfileCatalog {
    public static let kind = "profile"
    public static let category = DataMigrationCategory.profiles
    public static let defaultsKey = "dictationProfiles"
    public static let desktopFilename = "profiles.json"

    public static func records(
        data: Data, digest: (Data) throws -> String, checkCancellation: () throws -> Void = {}
    ) throws -> [DataMigrationRecord] {
        try DataMigrationCollectionRecords.records(
            data: data, kind: kind, digest: digest, checkCancellation: checkCancellation
        )
    }

    public static func validate(_ record: DataMigrationRecord, category: DataMigrationCategory) throws {
        guard category == Self.category, record.kind == kind,
              !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.id.count < 1024 else {
            throw DataMigrationError.invalid("Invalid profile record.")
        }
        if let object = record.value.value as? [String: Any], let id = object["id"] as? String, id != record.id {
            throw DataMigrationError.invalid("Mismatched profile identifier.")
        }
        // Decode for the existing acceptance rules; never re-encode the lossy runtime projection.
        _ = try DataMigrationCoding.decode(DictationProfile.self, record.value)
    }
}
