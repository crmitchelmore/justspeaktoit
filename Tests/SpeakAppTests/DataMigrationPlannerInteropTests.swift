import Foundation
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
import XCTest
@testable import SpeakApp

@MainActor
final class DataMigrationPlannerInteropTests: XCTestCase {
    func testCanonicalPreferenceKeys_PreserveMacAliasAndPreviouslyRejectedBooleanSettings() throws {
        XCTAssertEqual(AppSettings.DefaultsKey.allCases, ApplicationPreferenceKey.allCases)
        let constructor: (String) -> AppSettings.DefaultsKey? = AppSettings.DefaultsKey.init(rawValue:)
        XCTAssertEqual(constructor("appearance"), ApplicationPreferenceKey.appearance)
        XCTAssertNil(constructor("speakDeviceId"))
        XCTAssertEqual(MigrationCatalog.settingKeys, DataMigrationPreferenceCatalog.keys(in: .settings))
        XCTAssertEqual(MigrationCatalog.vocabularyKeys, DataMigrationPreferenceCatalog.keys(in: .vocabulary))
        for key in ["paidAccessRoutingEnabled", "simpleModelChoices", "pasteRemoteTranscriptsAtCursor"] {
            let valid = MigrationRecord(id: key, kind: "default", value: AnyCodable(.bool(true)))
            XCTAssertNoThrow(try MigrationCatalog.validate(valid, category: .settings))
            let invalid = MigrationRecord(id: key, kind: "default", value: AnyCodable(.string("true")))
            XCTAssertThrowsError(try MigrationCatalog.validate(invalid, category: .settings))
        }
    }

    func testSharedPlanner_UsesExistingMacVariantIdentifiersAndFailsUnencodableValues() throws {
        let original = MigrationRecord(id: "session", kind: "history", value: AnyCodable(.string("Original")))
        let changed = MigrationRecord(
            id: "session", kind: "history", value: AnyCodable(.string("Changed")), revision: "changed"
        )
        let manifest = MigrationManifest(categories: [.history], scopes: [:])
        let current = MigrationSnapshot(manifest: manifest, records: [.history: [original]])
        let incoming = MigrationSnapshot(manifest: manifest, records: [.history: [changed]])
        let result = try MigrationPlanner.plan(
            current: current, incoming: incoming, modes: [.history: .merge], useImported: []
        )
        XCTAssertEqual(result.records[.history]?.last?.id, MigrationPlannerFixtures.changedID)
        XCTAssertEqual(
            result.records[.history]?.last?.id, MigrationCoding.variantID(id: "session", revision: "changed")
        )
        let digests = try XCTUnwrap(LocalModelDigestProvider.platformDefault)
        let desktop = try DesktopMigrationPlanner.plan(
            current: current, incoming: incoming, modes: [.history: .merge], useImported: [], digests: digests
        )
        XCTAssertEqual(desktop.records, result.records)
        let invalid = MigrationRecord(id: "session", kind: "history", value: AnyCodable(.double(.nan)))
        XCTAssertThrowsError(try MigrationPlanner.plan(
            current: current, incoming: .init(manifest: manifest, records: [.history: [invalid]]),
            modes: [.history: .merge], useImported: []
        ))
    }
}
