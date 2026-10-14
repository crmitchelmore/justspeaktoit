import Foundation
import SpeakCore
import XCTest

final class DataMigrationPreferenceProjectionTests: XCTestCase {
    private let categories: Set<DataMigrationCategory> = [.settings, .vocabulary, .connections]

    func testEmptyProjection_DoesNotInventDefaults() throws {
        let result = try DataMigrationPreferenceProjection.project([:], categories: categories)
        XCTAssertEqual(Set(result.records.keys), categories)
        XCTAssertTrue(result.records.values.allSatisfy(\.isEmpty))
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testCanonicalDefinitions_DetermineEveryRecordCategoryAndKind() throws {
        var values: [String: AnyCodable] = [:]
        let definitions = DataMigrationPreferenceCatalog.definitions.filter { categories.contains($0.category) }
        for definition in definitions {
            let value: AnyCodable.JSONValue
            switch definition.kind {
            case .boolean: value = .bool(false)
            case .number: value = .int(0)
            case .text: value = .string("")
            case .stringArray: value = .array([.string("word")])
            case .stringDictionary: value = .object(["word": .string("replacement")])
            case .json: value = .object([:])
            }
            values[definition.key] = AnyCodable(value)
        }
        var validated: Set<String> = []
        let result = try DataMigrationPreferenceProjection.project(values, categories: categories) {
            validated.insert($0.id)
        }
        XCTAssertEqual(result.records.values.flatMap { $0 }.count, definitions.count)
        for definition in definitions {
            let record = try XCTUnwrap(result.records[definition.category]?.first { $0.id == definition.key })
            XCTAssertEqual(record.kind, definition.recordKind)
            XCTAssertEqual(record.value, values[definition.key])
        }
        XCTAssertEqual(validated, ["selectedHotKey", "customShortcutBindings"])
        XCTAssertEqual(result.notices.count, definitions.count)
    }

    func testSelectedCategories_IncludeOnlyTheirOwnValues() throws {
        let values: [String: AnyCodable] = [
            "showHUD": AnyCodable(.bool(false)), "transcriptionKeywords": AnyCodable(.string("term")),
            "enableAutomationServer": AnyCodable(.bool(false))
        ]
        for category in categories {
            let result = try DataMigrationPreferenceProjection.project(values, categories: [category])
            XCTAssertEqual(Set(result.records.keys), [category])
            XCTAssertEqual(result.records[category]?.count, 1)
            let record = try XCTUnwrap(result.records[category]?.first)
            XCTAssertEqual(DataMigrationPreferenceCatalog.category(for: record.id), category)
        }
        let empty = try DataMigrationPreferenceProjection.project(values, categories: [])
        XCTAssertTrue(empty.records.isEmpty)
    }

    func testCredentialsAndCollectionCategories_AreRejected() {
        for category in DataMigrationCategory.allCases where !categories.contains(category) {
            XCTAssertThrowsError(try DataMigrationPreferenceProjection.project([:], categories: [category]))
        }
    }

    func testUnknownExcludedAndCredentialValues_AreNamedButNeverDumped() throws {
        let values: [String: AnyCodable] = [
            "future": AnyCodable(.object(["private": .string("never publish")])),
            "trackedKeyIdentifiers": AnyCodable(.array([])),
            "transcriptionKeywordsLastReconciled": AnyCodable(.string("internal")),
            "speakTransportPairingCode": AnyCodable(.string("private"))
        ]
        let result = try DataMigrationPreferenceProjection.project(values, categories: categories)
        XCTAssertTrue(result.records.values.allSatisfy(\.isEmpty))
        XCTAssertEqual(result.notices, [
            .init(path: "configuration.future", reason: .unknownPreference),
            .init(path: "configuration.speakTransportPairingCode", reason: .excludedPreference),
            .init(path: "configuration.trackedKeyIdentifiers", reason: .excludedPreference),
            .init(path: "configuration.transcriptionKeywordsLastReconciled", reason: .excludedPreference)
        ])
    }

    func testSelectedInvalidScalars_FailRatherThanCoercingOrDropping() {
        let invalid: [(String, AnyCodable.JSONValue)] = [
            ("showHUD", .int(1)), ("ttsSpeed", .string("1")), ("ttsPitch", .double(.nan)),
            ("ttsSpeed", .double(.infinity)), ("silenceDuration", .int(-1)),
            ("ttsSpeed", .int(1_000_001)), ("appearance", .int(2)),
            ("ttsFavoriteVoices", .array([.int(1)])), ("showHUD", .null)
        ]
        for (key, value) in invalid {
            XCTAssertThrowsError(try DataMigrationPreferenceProjection.project(
                [key: AnyCodable(value)], categories: categories
            ), key)
        }
    }

    func testUnselectedInvalidScalars_AreNotReadAsSelectedSettings() throws {
        let result = try DataMigrationPreferenceProjection.project(
            ["ttsSpeed": AnyCodable(.string("invalid"))], categories: [.vocabulary]
        )
        XCTAssertEqual(result.records[.vocabulary], [])
    }

    func testFalseZeroEmptyAndNegativePitch_AreExplicitNotAbsent() throws {
        let values: [String: AnyCodable] = [
            "showHUD": AnyCodable(.bool(false)), "silenceDuration": AnyCodable(.int(0)),
            "preferredLocale": AnyCodable(.string("")), "ttsPitch": AnyCodable(.int(-3))
        ]
        let result = try DataMigrationPreferenceProjection.project(
            values, categories: [.settings], authoritativeKeys: Set(values.keys)
        )
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try XCTUnwrap(result.records[.settings]).map {
            ($0.id, $0.value)
        }), values)
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testPronunciationDictionary_UsesStructuredJSONDefault() throws {
        let value = AnyCodable(.object(["term": .string("pronunciation")]))
        let result = try DataMigrationPreferenceProjection.project(
            ["ttsPronunciationDictionary": value], categories: [.vocabulary]
        )
        let record = try XCTUnwrap(result.records[.vocabulary]?.first)
        XCTAssertEqual(record.kind, "jsonDefault")
        XCTAssertEqual(try DataMigrationCoding.decode([String: String].self, record.value),
                       ["term": "pronunciation"])
        XCTAssertThrowsError(try DataMigrationPreferenceProjection.project(
            ["ttsPronunciationDictionary": AnyCodable(.object(["term": .int(1)]))], categories: [.vocabulary]
        ))
    }

    func testEncodedJSONString_IsNeverAcceptedAsJSONDefault() {
        for key in ["ttsPronunciationDictionary", "selectedHotKey", "customShortcutBindings"] {
            XCTAssertThrowsError(try DataMigrationPreferenceProjection.project(
                [key: AnyCodable(.string("{}"))], categories: categories
            ))
        }
    }

    func testAppleJSON_RequiresExplicitTypedValidatorAndPropagatesFailure() throws {
        let values = ["selectedHotKey": AnyCodable(.object(["fnKey": .object([:])]))]
        let unvalidated = try DataMigrationPreferenceProjection.project(values, categories: [.settings])
        XCTAssertEqual(unvalidated.records[.settings], [])
        XCTAssertEqual(unvalidated.notices, [
            .init(path: "configuration.selectedHotKey", reason: .requiresJSONValidator)
        ])
        let validated = try DataMigrationPreferenceProjection.project(values, categories: [.settings]) { record in
            XCTAssertEqual(record.kind, "jsonDefault")
            XCTAssertEqual(record.value, values["selectedHotKey"])
        }
        XCTAssertEqual(validated.records[.settings]?.first?.value, values["selectedHotKey"])
        XCTAssertThrowsError(try DataMigrationPreferenceProjection.project(values, categories: [.settings]) { _ in
            throw DataMigrationError.invalid("Rejected by typed validator.")
        })
    }
}
