import Foundation
import XCTest
import SpeakCore

final class DataMigrationFormatTests: XCTestCase {
    func testCategoriesAndModes_PreserveExistingMacCatalogueAndCredentialOptIn() {
        XCTAssertEqual(DataMigrationCategory.allCases.map(\.rawValue), [
            "settings", "history", "recordings", "credentials", "profiles", "vocabulary", "connections", "models"
        ])
        XCTAssertEqual(DataMigrationCategory.defaults, Set(DataMigrationCategory.allCases).subtracting([.credentials]))
        XCTAssertEqual(DataMigrationMode.allCases.map(\.rawValue), ["skip", "merge", "replace"])
    }

    func testManifest_PreservesExistingMacJSONKeysAndFormat() throws {
        let date = Date(timeIntervalSince1970: 0)
        let manifest = DataMigrationManifest(createdAt: date, categories: [.history, .recordings], scopes: [:])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["format", "version", "createdAt", "categories", "scopes"])
        XCTAssertEqual(object["format"] as? String, "JustSpeakToIt")
        XCTAssertEqual(object["version"] as? Int, DataMigrationFormat.version)
        XCTAssertEqual(object["createdAt"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(object["categories"] as? [String], ["history", "recordings"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DataMigrationManifest.self, from: data)
        XCTAssertEqual(restored.createdAt, date)
        XCTAssertEqual(restored.categories, manifest.categories)
    }

    func testRecord_PreservesPayloadAndOptionalWireFields() throws {
        let record = DataMigrationRecord(
            id: "fixture", kind: "audio", value: AnyCodable(.string("value")), date: Date(timeIntervalSince1970: 0),
            file: "recordings/fixture.wav", digest: "digest", revision: "revision"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "kind", "value", "date", "file", "digest", "revision"])
        XCTAssertEqual(object["date"] as? String, "1970-01-01T00:00:00Z")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(DataMigrationRecord.self, from: data), record)
        XCTAssertEqual(record.identity, "audio:fixture")
        let minimal = DataMigrationRecord(id: "fixture", kind: "default", value: AnyCodable(.string("value")))
        let minimalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(minimal)) as? [String: Any]
        )
        XCTAssertEqual(Set(minimalObject.keys), ["id", "kind", "value"])
        XCTAssertNotEqual(record.identity, minimal.identity)
    }

    func testScope_PreservesInclusiveStartExclusiveEndAndMissingDateRules() {
        let start = Date(timeIntervalSince1970: 10)
        let end = Date(timeIntervalSince1970: 20)
        let scope = DataMigrationScope(start: start, end: end, selectedIDs: ["selected"])
        XCTAssertTrue(scope.contains(id: "selected", date: start))
        XCTAssertTrue(scope.contains(id: "selected", date: end.addingTimeInterval(-1)))
        XCTAssertFalse(scope.contains(id: "selected", date: start.addingTimeInterval(-1)))
        XCTAssertFalse(scope.contains(id: "selected", date: end))
        XCTAssertFalse(scope.contains(id: "selected", date: nil))
        XCTAssertFalse(scope.contains(id: "other", date: start))
        XCTAssertFalse(scope.isComplete)
        XCTAssertTrue(DataMigrationScope().contains(id: "any", date: nil))
        XCTAssertTrue(DataMigrationScope().isComplete)
        XCTAssertFalse(DataMigrationScope(selectedIDs: []).isComplete)
    }

    func testConstructors_PreserveFullMemberwiseFunctionReferenceContracts() {
        let makeScope: (Date?, Date?, Set<String>?) -> DataMigrationScope = DataMigrationScope.init
        let makeRecord: (
            String, String, AnyCodable, Date?, String?, String?, String?
        ) -> DataMigrationRecord = DataMigrationRecord.init
        let makeManifest: (
            String, Int, Date, [DataMigrationCategory], [String: DataMigrationScope]
        ) -> DataMigrationManifest = DataMigrationManifest.init
        let makeSnapshot: (
            DataMigrationManifest, [DataMigrationCategory: [DataMigrationRecord]], [String: URL], [String], URL?
        ) -> DataMigrationSnapshot = DataMigrationSnapshot.init
        let scope = makeScope(nil, nil, nil)
        let record = makeRecord("fixture", "default", AnyCodable(.bool(true)), nil, nil, nil, nil)
        let manifest = makeManifest(
            DataMigrationFormat.identifier, DataMigrationFormat.version, Date(), [.settings], ["settings": scope]
        )
        let snapshot = makeSnapshot(manifest, [.settings: [record]], [:], [], nil)
        XCTAssertEqual(snapshot.records[.settings], [record])
        XCTAssertTrue(scope.isComplete)
    }
}
