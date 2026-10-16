import Foundation
import SpeakCore
import XCTest

final class DesktopSidebarShortcutTests: XCTestCase {
    func testBindings_UseStableDestinationsAndUniqueNativeChords() {
        let bindings = DesktopSidebarShortcut.allCases
        XCTAssertEqual(bindings.map(\.digit), [1, 2, 3, 4, 5, 6, 7, 8, 9, 0])
        XCTAssertEqual(Set(bindings.map(\.rawValue)).count, bindings.count)
        XCTAssertEqual(Set(bindings.map(\.chord)).count, bindings.count)
        XCTAssertEqual(DesktopSidebarShortcut.voiceOutput.rawValue, "voice-output")
        XCTAssertEqual(DesktopSidebarShortcut.postProcessing.rawValue, "post-processing")
        for binding in bindings {
            XCTAssertEqual(binding.chord, "Ctrl+\(binding.digit)")
        }
    }

    func testHintSetting_DefaultStrictBooleanAndExplicitFalseRoundTrip() throws {
        let key = ApplicationPreferenceKey.showSidebarShortcutHints.rawValue
        let defaults = try DesktopConfiguration()
        XCTAssertTrue(DesktopSidebarShortcut.showHintsByDefault)
        XCTAssertTrue(defaults.enabled(key))
        XCTAssertNil(defaults.values[key])
        for enabled in [true, false] {
            let configured = try DesktopConfiguration(values: [key: AnyCodable(.bool(enabled))])
            let restored = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(configured)
            )
            XCTAssertEqual(restored.enabled(key), enabled)
            XCTAssertEqual(restored.values[key], AnyCodable(.bool(enabled)))
        }
        for invalid in [#"null"#, #"0"#, #"1"#, #""false""#, #"[]"#, #"{}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(
                DesktopConfiguration.self, from: Data("{\"\(key)\":\(invalid)}".utf8)
            ))
        }
    }

    func testKindScopedPreferenceTransfer_PreservesFalseAndOnlyExplicitCoverageClears() throws {
        let key = ApplicationPreferenceKey.showSidebarShortcutHints.rawValue
        let original = DataMigrationRecord(id: key, kind: "default", value: AnyCodable(.bool(false)))
        let current = DataMigrationSnapshot(
            manifest: .init(categories: [.settings], scopes: [:]), records: [.settings: [original]]
        )
        for covered in [false, true] {
            let incoming = DataMigrationSnapshot(
                manifest: .init(categories: [.settings], scopes: [
                    "settings": .init(selectedIDs: [covered ? key : "showHUD"], selectedKinds: ["default"])
                ]), records: [.settings: []]
            )
            let result = try DataMigrationPlanner.plan(
                current: current, incoming: incoming, modes: [.settings: .replace], useImported: [],
                digest: { _ in String(repeating: "a", count: 64) }
            )
            XCTAssertEqual(result.records[.settings], covered ? [] : [original])
        }
    }

    func testCanonicalTransfer_RequiresBooleanWithoutReinterpretingOtherShapes() throws {
        let key = ApplicationPreferenceKey.showSidebarShortcutHints.rawValue
        XCTAssertEqual(DataMigrationPreferenceCatalog.definition(for: key)?.kind, .boolean)
        for value in [AnyCodable.JSONValue.bool(true), .bool(false)] {
            try DataMigrationPreferenceCatalog.validate(
                .init(id: key, kind: "default", value: AnyCodable(value)), category: .settings,
                validateJSON: { _ in XCTFail("Boolean must not use the JSON validator") }
            )
        }
        for value in [AnyCodable.JSONValue.int(0), .int(1), .string("false"), .null] {
            XCTAssertThrowsError(try DataMigrationPreferenceCatalog.validate(
                .init(id: key, kind: "default", value: AnyCodable(value)), category: .settings,
                validateJSON: { _ in XCTFail("Boolean must not use the JSON validator") }
            ))
        }
    }
}
