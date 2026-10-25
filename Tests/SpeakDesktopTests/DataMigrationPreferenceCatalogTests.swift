import Foundation
import SpeakCore
import XCTest

final class DataMigrationPreferenceCatalogTests: XCTestCase {
    private func record(_ key: String, _ value: AnyCodable.JSONValue, kind: String = "default") -> DataMigrationRecord {
        .init(id: key, kind: kind, value: AnyCodable(value))
    }

    private func validate(_ record: DataMigrationRecord, category: DataMigrationCategory = .settings) throws {
        try DataMigrationPreferenceCatalog.validate(record, category: category) { _ in
            XCTFail("Scalar validation must not delegate to a platform JSON validator.")
        }
    }

    func testCanonicalKeys_PreserveInventoryOrderAndUniquePersistedNames() {
        let keys = ApplicationPreferenceKey.allCases.map(\.rawValue)
        XCTAssertEqual(keys.count, 93)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(keys.first, "appearance")
        XCTAssertEqual(keys.last, "analyticsEnabled")
        for key in keys { XCTAssertEqual(ApplicationPreferenceKey(rawValue: key)?.rawValue, key) }
    }

    func testDefinitions_CoverEveryPortableKeyWithoutDuplicateOrImplicitTypeFallback() {
        let definitions = DataMigrationPreferenceCatalog.definitions
        XCTAssertEqual(definitions.count, 98)
        XCTAssertEqual(Set(definitions.map(\.key)).count, definitions.count)
        let excluded: Set<ApplicationPreferenceKey> = [.trackedKeyIdentifiers, .transcriptionKeywordsLastReconciled]
        for key in ApplicationPreferenceKey.allCases {
            XCTAssertEqual(DataMigrationPreferenceCatalog.definition(for: key.rawValue) == nil, excluded.contains(key))
        }
        XCTAssertNil(DataMigrationPreferenceCatalog.definition(for: "speakDeviceId"))
        XCTAssertNil(DataMigrationPreferenceCatalog.definition(for: "unknownPreference"))
    }

    func testEveryDefinition_HasAnExecutableAcceptanceShapeAndExplicitJSONDelegation() throws {
        for definition in DataMigrationPreferenceCatalog.definitions {
            let value: AnyCodable.JSONValue
            switch definition.kind {
            case .boolean: value = .bool(true)
            case .number: value = .int(1)
            case .text: value = .string("synthetic value")
            case .stringArray: value = .array([.string("synthetic value")])
            case .stringDictionary: value = .object(["synthetic": .string("value")])
            case .json: value = .object(["synthetic": .string("platform-validated JSON")])
            }
            let item = record(definition.key, value, kind: definition.recordKind)
            var delegated = false
            try DataMigrationPreferenceCatalog.validate(item, category: definition.category) { incoming in
                delegated = true
                XCTAssertEqual(incoming, item)
            }
            XCTAssertEqual(delegated, definition.kind == .json, definition.key)
        }
    }

    func testBooleanSettings_PreviouslyRejectedByMacSchemaAcceptOnlyBooleans() throws {
        for key in [
            "paidAccessRoutingEnabled", "simpleModelChoices",
            "pasteRemoteTranscriptsAtCursor", "cancelRecordingOnEscape"
        ] {
            XCTAssertEqual(DataMigrationPreferenceCatalog.definition(for: key)?.kind, .boolean)
            try validate(record(key, .bool(true)))
            try validate(record(key, .bool(false)))
            XCTAssertThrowsError(try validate(record(key, .int(1))))
            XCTAssertThrowsError(try validate(record(key, .string("true"))))
        }
    }

    func testClassification_PreservesVocabularyConnectionsAndCredentialBoundaries() {
        XCTAssertEqual(DataMigrationPreferenceCatalog.keys(in: .vocabulary), [
            "transcriptionKeywords", "assemblyAIKeyterms", "recoveredTranscriptionKeywords",
            "assemblyAIIgnoredPronunciationTerms", "ttsPronunciationDictionary"
        ])
        XCTAssertEqual(
            DataMigrationPreferenceCatalog.keys(in: .connections), ["enableSendToMac", "enableAutomationServer"]
        )
        XCTAssertEqual(DataMigrationPreferenceCatalog.keys(in: .credentials),
                       ["speakTransportPairingCode", "speakTransportPairedDevices"])
        XCTAssertNil(DataMigrationPreferenceCatalog.category(for: "trackedKeyIdentifiers"))
        XCTAssertNil(DataMigrationPreferenceCatalog.category(for: "transcriptionKeywordsLastReconciled"))
        XCTAssertFalse(DataMigrationPreferenceCatalog.keys(in: .settings).contains("speakTransportPairingCode"))
    }

    func testAuxiliaryKeys_PreserveConsentAndRememberedSelectionTypes() throws {
        for key in ["hasCompletedOnboarding", "hasAnsweredAnalyticsConsent"] {
            try validate(record(key, .bool(false)))
            XCTAssertThrowsError(try validate(record(key, .string("false"))))
        }
        for key in ["rememberedOnDeviceLiveTranscriptionModel", "rememberedRemoteLiveTranscriptionModel"] {
            try validate(record(key, .string("synthetic model")))
            XCTAssertThrowsError(try validate(record(key, .bool(true))))
        }
    }

    func testNumericBounds_PreserveExactMacLimitsAndPitchOnlyNegativeAllowance() throws {
        let valid: [AnyCodable.JSONValue] = [.int(0), .int(1_000_000), .double(1_000_000)]
        for value in valid {
            try validate(record("ttsSpeed", value))
        }
        try validate(record("ttsPitch", .double(-1_000_000)))
        let invalid: [AnyCodable.JSONValue] = [
            .int(-1), .double(1_000_000.0001), .double(.nan), .double(.infinity), .bool(true), .string("1")
        ]
        for value in invalid {
            XCTAssertThrowsError(try validate(record("ttsSpeed", value)))
        }
        XCTAssertThrowsError(try validate(record("ttsPitch", .double(-1_000_000.0001))))
    }

    func testStringCollections_RejectMixedElementsAndPreserveEmptyValues() throws {
        try validate(record("ttsFavoriteVoices", .array([])))
        try validate(record("ttsFavoriteVoices", .array([.string("voice")])))
        XCTAssertThrowsError(try validate(record("ttsFavoriteVoices", .array([.string("voice"), .int(1)]))))
        try validate(record("speakTransportPairedDevices", .object([:])), category: .credentials)
        try validate(record("speakTransportPairedDevices", .object(["device": .string("synthetic")])),
                     category: .credentials)
        XCTAssertThrowsError(try validate(record("speakTransportPairedDevices", .object(["device": .bool(true)])),
                                         category: .credentials))
    }

    func testWrongCategoryKindAndUnknownKeys_FailBeforeJSONOrScalarApplication() {
        XCTAssertThrowsError(try validate(record("runAtLogin", .bool(true)), category: .credentials))
        XCTAssertThrowsError(try validate(record("speakTransportPairingCode", .string("synthetic"))))
        XCTAssertThrowsError(try validate(record("runAtLogin", .bool(true), kind: "secret")))
        XCTAssertThrowsError(try validate(record("runAtLogin", .bool(true), kind: "jsonDefault")))
        XCTAssertThrowsError(try validate(record("speakDeviceId", .string("foreign device"))))
    }

    func testJSONPreferences_RequirePlatformValidatorAndPropagateItsFailure() {
        let item = record("selectedHotKey", .object([:]), kind: "jsonDefault")
        XCTAssertThrowsError(try DataMigrationPreferenceCatalog.validate(item, category: .settings) { _ in
            throw DataMigrationError.invalid("Synthetic invalid platform shortcut")
        })
        XCTAssertThrowsError(try DataMigrationPreferenceCatalog.validate(
            record("selectedHotKey", .object([:]), kind: "default"), category: .settings
        ) { _ in XCTFail("Wrong-kind JSON must be rejected before delegation.") })
    }
}
